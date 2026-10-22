'use strict';
const fs=require('node:fs'),path=require('node:path');
const {TurnUsage,terminal}=require('./turn-usage.cjs');
const clean=(v,n=80)=>String(v||'').replace(/[\x00-\x1f\x7f]/g,' ').replace(/\s+/g,' ').trim().slice(0,n);
const ordinary=v=>String(v||'').replace(/^\\\\\?\\/,'');
const inside=(root,file)=>{const r=path.relative(root,file);return !r.startsWith('..')&&!path.isAbsolute(r);};
const id=/^[0-9a-f-]{36}$/;
const publicMessage=p=>{
 if(p.item?.type!=='AgentMessage')return '';
 const c=p.item.content;
 return clean(typeof c==='string'?c:Array.isArray(c)?c.filter(x=>x.type==='Text'&&typeof x.text==='string').map(x=>x.text).join(' '):'',4000);
};
class Catalog{
 constructor(config){this.config=config;this.cache=new Map();this.usageReaders=new Map();this.last=0;this.interval=4000;this.rows=[];this.started=Date.now();}
 tickUsage(){let more=false;for(const row of this.rows){const reader=this.usageReaders.get(row.thread_id);if(!reader||reader.turn!==row.turn_id)continue;more=reader.step()||more;const r=reader.result();row.usage=r.usage;row.usage_state=r.reason;}return more;}
 list(primary,backend){
  if(Date.now()-this.last<this.interval)return this.rows;
  this.last=Date.now();let db;
  try{
   const {DatabaseSync}=require('node:sqlite');db=new DatabaseSync(path.join(path.dirname(this.config.sessions_root),'state_5.sqlite'),{readOnly:true});
   const rows=db.prepare("SELECT id,name,cwd,rollout_path,updated_at FROM threads WHERE archived=0 AND agent_path IS NULL AND source IN ('vscode','cli') ORDER BY updated_at DESC LIMIT 16").all();
   this.rows=rows.map(r=>({...r,rollout_path:ordinary(r.rollout_path)})).filter(r=>id.test(r.id)&&r.rollout_path&&inside(this.config.sessions_root,r.rollout_path)).map(r=>{
    const base={thread_id:r.id,title:clean(r.name)||'未命名对话',project:clean(path.basename(ordinary(r.cwd))),status:'unknown',progress:'记录状态待核对',live:false};
    let st,last;try{st=fs.statSync(r.rollout_path);const prior=this.cache.get(r.id);last=prior?.size===st.size&&prior.mtime===st.mtimeMs?prior.last:this.readLifecycle(r.rollout_path,st.size);this.cache.set(r.id,{size:st.size,mtime:st.mtimeMs,last});}catch{return null;}
    if(!last)return null;
    const recent=Date.now()-Date.parse(last.at)<10*60*1000;
    // A task already running when Lumi starts is useful status, but old completed turns stay quiet.
    if(terminal.has(last.status)&&Date.parse(last.at)<=this.started)return null;
    if(last.status==='active'&&!recent)return null;
    const notice={...base,status:last.status,activity:last.activity,turn_id:last.turn_id,event_utc:last.at,notification_id:last.turn_id,live:recent&&backend!==null,progress:last.progress||'Codex正在处理',response:last.response||''};
    if(r.id===primary.thread_id&&primary.turn_id===last.turn_id&&primary.usage){notice.usage=primary.usage;notice.usage_state='available';return notice;}
    let reader=this.usageReaders.get(r.id);
    if(!reader||reader.turn!==last.turn_id||reader.signature!==st.dev+':'+st.ino||st.size<reader.end){reader=new TurnUsage(r,last,st,{final:terminal.has(last.status)});this.usageReaders.set(r.id,reader);}
    reader.final=terminal.has(last.status);if(reader.usage)reader.usage.final=reader.final;
    const value=reader.result();notice.usage=value.usage;notice.usage_state=value.reason;return notice;
   }).filter(Boolean).sort((a,b)=>Date.parse(b.event_utc)-Date.parse(a.event_utc)).slice(0,8);
   const visible=new Set(this.rows.map(r=>r.thread_id));for(const key of this.usageReaders.keys())if(!visible.has(key))this.usageReaders.delete(key);
   const current=new Set(rows.map(r=>r.id));for(const key of this.cache.keys())if(!current.has(key))this.cache.delete(key);
  }catch{this.rows=[];this.usageReaders.clear();}finally{db?.close();}
  return this.rows;
 }
 readLifecycle(file,size){
  const length=Math.min(size,2*1024*1024),buf=Buffer.allocUnsafe(length),fd=fs.openSync(file,'r');try{fs.readSync(fd,buf,0,length,size-length);}finally{fs.closeSync(fd);}
  const lines=buf.toString('utf8').split('\n');let found=null,progress='',response='';
  for(let i=lines.length-1;i>=(length<size?1:0);i--){const line=lines[i];if(line.length>262144||!/^\{"timestamp":"[^"]+",(?:"ordinal":\d+,)?"type":"event_msg","payload":\{"type":"(?:item_completed|task_started|task_complete|turn_aborted)"/.test(line))continue;
   try{const o=JSON.parse(line),p=o.payload,a=p.turn_attribution;if(a&&(a.parent_turn_id||a.initiating_agent_path))continue;if(!id.test(p.turn_id||''))continue;
    if(found&&p.turn_id!==found.turn_id)break;
    if(!found){
     const status=p.type==='task_complete'?(p.error?'failed':'completed'):p.type==='turn_aborted'?'interrupted':'active';
     const activity=p.type==='item_completed'?(p.item?.type==='Reasoning'?'thinking':p.item?.type==='AgentMessage'?'thinking':'working'):'thinking';
     found={status,activity,turn_id:p.turn_id,at:o.timestamp,failed:Boolean(p.error)};
    }
    if(p.type==='item_completed'&&p.item?.type==='AgentMessage'&&['commentary','final','final_answer'].includes(p.item.phase)){
     const value=publicMessage(p);if(value&&!progress)progress=clean(value,240);if(value&&!response&&['final','final_answer'].includes(p.item.phase))response=value;
    }
    if(p.type==='task_started')break;
   }catch{}
  }
  if(found){found.progress=progress||({thinking:'Codex正在思考',working:'Codex正在工作'}[found.activity]||'Codex正在处理');found.response=response;}
  return found;
 }
}
exports.Catalog=Catalog;
