'use strict';
const fs=require('node:fs'),path=require('node:path');
const {StringDecoder}=require('node:string_decoder');
const {Worker,isMainThread,parentPort,workerData}=require('node:worker_threads');
const {execFile}=require('node:child_process');
// Only versions whose local rollout event shape has been checked are accepted.
// The desktop app may update its bundled CLI independently of this pet.
const SUPPORTED=['0.162.0-alpha.17.2','0.163.0-alpha.10.2'];
const ID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const text=value=>String(value||'').replace(/[\x00-\x1f\x7f]/g,' ').replace(/\s+/g,' ').trim().slice(0,160);
const norm=value=>path.resolve(value).toLowerCase();
function scope(config){
 if(config.schema!==1||!ID.test(config.thread_id)||!path.isAbsolute(config.project_root)||!path.isAbsolute(config.sessions_root)||!path.isAbsolute(config.rollout))throw Error('Invalid explicit binding');
 const relative=path.relative(config.sessions_root,config.rollout);
 if(relative.startsWith('..')||path.isAbsolute(relative)||!path.basename(config.rollout).endsWith('-'+config.thread_id+'.jsonl'))throw Error('Rollout outside explicit session scope');
 if(!SUPPORTED.includes(config.cli_version))throw Error('Unsupported Codex version');
 return {...config,title:text(config.title)||'Codex任务'};
}
class Reducer{
 constructor(config){this.config=scope(config);this.verified=false;this.lastLifecycle=-Infinity;this.seen=new Set();this.total=null;this.usageAt=-Infinity;this.baseline=null;this.s={schema:1,thread_id:config.thread_id,status:'unknown',turn_id:null,title:this.config.title,progress:'正在核对Codex状态',event_utc:null,revision:0,source:'project_scoped_local_rollout',waiting_supported:false,usage:null};}
 snapshot(){return {...this.s,scope_verified:this.verified};}
 unknown(reason){this.s={...this.s,status:'unknown',progress:text(reason),revision:this.s.revision+1};}
 consume(line){
  // Gate before JSON parsing. Exclude all response_items, reasoning, prompts,
  // tool arguments/results and compaction. Only public commentary/final text is eligible.
  if(!/^\{"timestamp":"[^"]+",(?:"ordinal":\d+,)?"type":"(?:session_meta|event_msg)","payload":/.test(line))return false;
  const meta=line.includes('"type":"session_meta"'),kind=line.match(/"payload":\{"type":"([^"]+)"/)?.[1];
  if(!meta&&!['task_started','task_complete','turn_aborted','item_completed','token_count'].includes(kind))return false;
  if(kind==='item_completed'&&!/"item":\{(?:"id":"[^"]*",)?"type":"AgentMessage"/.test(line))return false;
  if(kind==='item_completed'&&!/"phase":"(?:commentary|final)"/.test(line))return false;
  let o;try{o=JSON.parse(line);}catch{return false;}const p=o.payload,time=Date.parse(o.timestamp);
  if(meta){
   if(p.id!==this.config.thread_id||norm(p.cwd)!==norm(this.config.project_root))throw Error('Thread/project mismatch');
   this.verified=true;return false;
  }
  if(!this.verified)throw Error('No verified session metadata');
  if(kind==='token_count'){
   const attribution=p.turn_attribution;if(attribution&&(attribution.parent_turn_id||attribution.initiating_agent_path))return false;
   if(!Number.isFinite(time)||time<this.usageAt||p.thread_id&&p.thread_id!==this.config.thread_id||p.turn_id&&p.turn_id!==this.s.turn_id)return false;
   const total=p.info?.total_token_usage?.total_tokens;if(!Number.isSafeInteger(total)||total<0)return false;
   if(this.total!==null&&total<this.total){this.baseline=null;this.s.usage=null;}
   this.total=total;this.usageAt=time;
   if(['active','completed','failed','interrupted'].includes(this.s.status)&&this.baseline!==null&&time>=this.lastLifecycle){this.s.usage={total_tokens:total-this.baseline,source:'thread_cumulative_delta',final:this.s.status!=='active'};this.s.revision++;return true;}return false;
  }
  if(!Number.isFinite(time)||!ID.test(p.turn_id||''))return false;
  if(p.thread_id&&p.thread_id!==this.config.thread_id)return false;
  if(kind==='task_started'){
   const a=p.turn_attribution;
   if(a&&(a.parent_turn_id||a.initiating_agent_path||a.root_turn_id!==p.turn_id))return false;
  }
  const key=kind+':'+p.turn_id+':'+(p.item?.id||o.timestamp);
  if(this.seen.has(key))return false;this.seen.add(key);if(this.seen.size>256)this.seen.delete(this.seen.values().next().value);
  if(kind==='item_completed'){
   if(p.turn_id!==this.s.turn_id||this.s.status!=='active'||!['commentary','final'].includes(p.item.phase))return false;
   if(time<this.lastLifecycle)return false;
   const content=p.item.content;
   const value=typeof content==='string'?content:Array.isArray(content)?content.filter(c=>c.type==='Text'&&typeof c.text==='string').map(c=>c.text).join(' '):'';
   if(!value)return false;
   // A final message alone is not a completed turn; wait for task_complete.
   this.s.progress=text(value);this.s.event_utc=o.timestamp;this.s.revision++;return true;
  }
  if(time<this.lastLifecycle)return false;
  if(kind==='task_started'){
   if(p.turn_id===this.s.turn_id)return false;
   this.baseline=this.total;
   this.s={...this.s,status:'active',turn_id:p.turn_id,progress:'Codex正在执行本轮任务',event_utc:o.timestamp,revision:this.s.revision+1,usage:null};
  }else{
   if(p.turn_id!==this.s.turn_id||this.s.status!=='active')return false;
   const status=kind==='turn_aborted'?'interrupted':p.error?'failed':'completed';
   this.s={...this.s,status,event_utc:o.timestamp,revision:this.s.revision+1,usage:this.s.usage?{...this.s.usage,final:true}:null,progress:status==='completed'?'Codex本轮回复已结束':status==='failed'?'Codex本轮执行遇到错误':'Codex本轮任务已中断'};
  }
  this.lastLifecycle=time;return true;
 }
}
// Streaming byte tailer: bounded memory even for very large transcripts/lines.
// Run in a worker so initial historical replay cannot stall Electron input.
class Tailer{
 constructor(config,onSnapshot){this.config=scope(config);this.reducer=new Reducer(config);this.onSnapshot=onSnapshot;this.offset=0;this.pending='';this.skipping=false;this.decoder=new StringDecoder('utf8');this.fd=null;this.signature=null;this.initial=true;this.lastSent=-1;this.bytesRead=0;}
 reset(){if(this.fd!==null)fs.closeSync(this.fd);this.fd=null;this.offset=0;this.pending='';this.skipping=false;this.decoder=new StringDecoder('utf8');this.reducer=new Reducer(this.config);this.initial=true;}
 step(){
  let st;try{st=fs.statSync(this.config.rollout);}catch(e){this.reducer.unknown('Codex事件记录暂不可用');this.publish(false);return false;}
  const sig=st.dev+':'+st.ino;if(this.signature!==sig||st.size<this.offset){this.reset();this.signature=sig;}
  if(this.fd===null)this.fd=fs.openSync(this.config.rollout,'r');
  if(this.initial&&this.offset===0&&st.size>8*1024*1024){
   // Verify the immutable session header, then join the bounded recent tail.
   // Multi-GB chats must not wait for a full historical replay before task sync.
   const header=Buffer.allocUnsafe(512*1024),n=fs.readSync(this.fd,header,0,header.length,0);
   const first=header.subarray(0,n).toString('utf8').split('\n')[0];
   this.reducer.consume(first);
   this.offset=st.size-8*1024*1024;
   this.skipping=true;
  }
  const buffer=Buffer.allocUnsafe(Math.min(256*1024,st.size-this.offset));
  if(buffer.length){const n=fs.readSync(this.fd,buffer,0,buffer.length,this.offset);this.offset+=n;this.bytesRead+=n;this.lines(this.decoder.write(buffer.subarray(0,n)));}
  const caughtUp=this.offset>=st.size;
  if(caughtUp){this.publish(!this.initial);this.initial=false;}
  return !caughtUp;
 }
 lines(chunk){
  for(const piece of chunk.split(/(?<=\n)/)){
   if(!this.skipping)this.pending+=piece;
   if(this.pending.length>128*1024){this.pending='';this.skipping=true;}
   if(piece.endsWith('\n')){if(!this.skipping)this.reducer.consume(this.pending.trimEnd());this.pending='';this.skipping=false;}
  }
 }
 publish(live){const s=this.reducer.snapshot();if(s.revision===this.lastSent)return;this.lastSent=s.revision;this.onSnapshot({...s,live,reading_history:this.initial,observed_utc:new Date().toISOString(),reader_bytes:this.bytesRead});}
 close(){if(this.fd!==null)fs.closeSync(this.fd);this.fd=null;}
}
function start(config,onSnapshot,onError=()=>{}){
 scope(config);const worker=new Worker(__filename,{workerData:{config}});let stopped=false;
 worker.on('message',m=>{if(stopped)return;if(m.error)onError(new Error(m.error));else onSnapshot(m);});
 worker.on('error',e=>{if(!stopped)onError(e);});
 return {stop(){if(stopped)return;stopped=true;worker.postMessage({stop:true});},worker};
}
function command(exe,args){
 const env={...process.env};if(exe.toLowerCase().endsWith('/powershell.exe')){for(const k of Object.keys(env))if(k.toLowerCase()==='psmodulepath')delete env[k];env.PSModulePath='C:/Windows/System32/WindowsPowerShell/v1.0/Modules';}
 return new Promise((resolve,reject)=>execFile(exe,args,{env,windowsHide:true,timeout:8000,maxBuffer:65536},(e,out)=>e?reject(e):resolve(out.trim())));
}
if(!isMainThread){
 let timer,stopped=false,ready=false,backend=null,backendSeen=false,connectionLost=false,checking=false,lastCheck=0,lastCatalog=0,tailer,lowPower=false;
 const c=scope(workerData.config);
 const catalog=new (require('./task-catalog.cjs').Catalog)(c);
 const packet=s=>{const tasks=catalog.list(s,backend);return {...s,title:catalog.primaryTitle||s.title,tasks,notification_mode:true};};
 const deliver=s=>{
  if(stopped||!ready||backend===null||connectionLost)return;
  const value=packet(s),stale=s.status==='active'&&tailer.reducer.lastLifecycle<backend.created;
  // A long-running turn can begin before the bounded 8 MiB tail. Recover
  // only the explicitly bound thread from the recent, read-only task index.
  if((s.status==='unknown'||stale)&&tailer.reducer.verified){
   const current=value.tasks.find(t=>t.thread_id===c.thread_id&&t.status==='active'&&t.live);
   const eventTime=Date.parse(current?.event_utc||'');
   if(current&&Number.isFinite(eventTime)&&eventTime>=backend.created&&Date.now()-eventTime<10*60*1000){
    parentPort.postMessage({...value,status:'active',turn_id:current.turn_id,activity:current.activity,progress:current.progress,event_utc:current.event_utc,usage:current.usage||s.usage,live:true});
    return;
   }
  }
  parentPort.postMessage(stale?{...value,status:'unknown',progress:'等待当前Codex后端的新任务事件',live:false}:value);
 };
 tailer=new Tailer(c,deliver);
 const unavailable=reason=>parentPort.postMessage(packet({...tailer.reducer.snapshot(),status:'unavailable',progress:reason,live:false,observed_utc:new Date().toISOString()}));
 async function checkBackend(){
  if(checking||Date.now()-lastCheck<(lowPower?20000:5000))return;checking=true;lastCheck=Date.now();
  try{
   const ps="$ErrorActionPreference='Stop'; $p = @(Get-CimInstance Win32_Process -Filter \"Name = 'codex.exe'\" | Where-Object { $_.ExecutablePath -match '\\\\OpenAI\\\\Codex\\\\bin\\\\[0-9a-f]+\\\\codex\\.exe$' -and $_.CommandLine -match '(?:^|\\s)app-server(?:\\s|$)' } | Where-Object { $parent=Get-CimInstance Win32_Process -Filter ('ProcessId = '+$_.ParentProcessId); $parent.Name -eq 'ChatGPT.exe' -and $parent.ExecutablePath -match '\\\\OpenAI\\.Codex_[^\\\\]+\\\\app\\\\ChatGPT\\.exe$' }); if ($p.Count -eq 1) { [pscustomobject]@{pid=$p[0].ProcessId;created=([DateTimeOffset]$p[0].CreationDate).ToUnixTimeMilliseconds();path=$p[0].ExecutablePath} | ConvertTo-Json -Compress }";
   const discovery="[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ProgressPreference='SilentlyContinue';"+ps;
   const output=await command('C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',['-NoProfile','-EncodedCommand',Buffer.from(discovery,'utf16le').toString('base64')]);
   const next=output.startsWith('{')?JSON.parse(output):null;
   if(next&&(!Number.isSafeInteger(next.pid)||!Number.isFinite(next.created)))throw Error('Invalid process identity');
   if(next&&(!ready||backend?.path!==next.path)){const version=await command(next.path,['--version']);if(!SUPPORTED.some(v=>version.includes(v)))throw Error('Untested desktop backend version');ready=true;}
   if(backendSeen&&(backend?.pid!==next?.pid||backend?.created!==next?.created)){connectionLost=true;tailer.reducer.unknown('Codex连接已变化，等待新的任务事件');tailer.lastSent=-1;}
   if(next!==null)backendSeen=true;backend=next;
   if(backend===null&&!stopped)unavailable('Codex后端未连接');
  }catch{backend=null;if(!stopped)unavailable('暂时无法核对Codex连接');}finally{checking=false;}
 }
 const loop=()=>{
  if(stopped)return;try{
   checkBackend();const rev=tailer.reducer.s.revision;
   const more=tailer.step(),usageMore=catalog.tickUsage();
   if(!more&&Date.now()-lastCatalog>=catalog.interval){lastCatalog=Date.now();tailer.lastSent=-1;tailer.publish(false);}
   // Reconnect requires a fresh start/end event, never a silent replay of old active state.
   if(connectionLost&&backend!==null&&tailer.reducer.s.revision>rev&&tailer.reducer.lastLifecycle>=Date.now()-15000){connectionLost=false;tailer.lastSent=-1;tailer.publish(true);}
   timer=more||usageMore?setImmediate(loop):setTimeout(loop,lowPower?2000:500);
  }catch(e){parentPort.postMessage({error:String(e.message)});stopped=true;tailer.close();parentPort.close();}
 };
 parentPort.on('message',m=>{if(m.stop){stopped=true;clearTimeout(timer);clearImmediate(timer);tailer.close();parentPort.close();}else if(typeof m.lowPower==='boolean'){lowPower=m.lowPower;catalog.interval=lowPower?12000:4000;lastCatalog=0;}});
 checkBackend().then(loop).catch(e=>{parentPort.postMessage({error:String(e.message)});tailer.close();parentPort.close();});
}
module.exports={SUPPORTED,scope,Reducer,Tailer,start,text};
