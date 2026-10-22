'use strict';
const fs=require('node:fs'),path=require('node:path');
const {Rpc}=require('./task-rpc.cjs');
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const norm=p=>path.resolve(String(p).replace(/^\\\\\?\\/,'')).toLowerCase();
const inside=(root,file)=>{const r=path.relative(root,file);return r!==''&&!r.startsWith('..')&&!path.isAbsolute(r);};
function message(entry){const item=entry?.item||entry;if(!item||typeof item.id!=='string')return null;let text,role;
 if(item.type==='agentMessage'&&[null,undefined,'commentary','final','final_answer'].includes(item.phase)){role='assistant';text=item.text;}
 else if(item.type==='userMessage'){role='user';text=(item.content||[]).filter(x=>x.type==='text'&&typeof x.text==='string').map(x=>x.text).join('\n\n');}
 else return null;
 if(typeof text!=='string'||!text.trim())return null;
 return {id:item.id,turnId:entry.turnId||null,clientId:item.clientId||null,role,text,phase:item.phase||null,at:entry.startedAtMs||entry.completedAtMs||null};
}
function create({binding,resolveRow,executable,makeRpc=options=>new Rpc(options),wake,desktopAvailable=async()=>true}){
 const home=path.dirname(binding.sessions_root);let rpc,closed=false,tail=Promise.resolve();const targets=new Map(),requests=new Map(),requestTexts=new Map(),historyBootstrapped=new Set();
 const client=()=>{if(closed)throw Error('CHAT_CLOSED');return rpc??=makeRpc({executable,home,cwd:home});};
 async function target(id){if(!UUID.test(id))throw Error('INVALID_THREAD');const row=await resolveRow(id);if(!row||row.id!==id||row.archived||!inside(binding.sessions_root,row.rollout_path))throw Error('THREAD_UNAVAILABLE');const realRoot=fs.realpathSync(binding.sessions_root),realFile=fs.realpathSync(row.rollout_path);if(!inside(realRoot,realFile))throw Error('THREAD_SCOPE_MISMATCH');const meta=await client().request('thread/read',{threadId:id});if(meta.thread.id!==id||norm(meta.thread.cwd)!==norm(row.cwd)||meta.thread.path&&norm(meta.thread.path)!==norm(row.rollout_path))throw Error('THREAD_SCOPE_MISMATCH');targets.set(id,{...row,title:meta.thread.name||row.name||'Codex',project:path.basename(row.cwd)});return targets.get(id);}
 async function history(id,cursor=null){const row=await target(id);if(cursor!==null&&(typeof cursor!=='string'||cursor.length>8192))throw Error('INVALID_CURSOR');const values=[],seenMessages=new Set(),seenCursors=new Set();let next=cursor,pages=0;const maxPages=cursor||!historyBootstrapped.has(id)?6:1;do{const page=await client().request('thread/items/list',{threadId:id,limit:60,sortDirection:'desc',...(next?{cursor:next}:{})});for(const value of (page.data||[]).map(message).filter(Boolean)){if(!seenMessages.has(value.id)){seenMessages.add(value.id);values.push(value);}}const previous=next;next=page.nextCursor||null;pages++;if(next&&(next===previous||seenCursors.has(next)))break;if(next)seenCursors.add(next);}while(next&&pages<maxPages&&values.length<12);historyBootstrapped.add(id);const pending=await client().request('thread/queue/list',{threadId:id,limit:30});return {threadId:id,title:row.title,project:row.project,messages:values.reverse(),cursor:next,queued:(pending.data||[]).map(q=>({id:q.id,clientId:q.clientUserMessageId,text:(q.input||[]).filter(x=>x.type==='text').map(x=>x.text).join('\n\n')}))};}
 function send(id,{text,requestId}){if(!UUID.test(requestId)||typeof text!=='string'||!text.trim()||text.length>32000||text.includes('\0'))return Promise.reject(Error('INVALID_MESSAGE'));const key=id+':'+requestId;if(requests.has(key))return requestTexts.get(key)===text?requests.get(key):Promise.reject(Error('REQUEST_CONTENT_MISMATCH'));if(requests.size>=500)return Promise.reject(Error('TOO_MANY_MESSAGES'));const job=tail.then(async()=>{await target(id);if(!await desktopAvailable())throw Error('DESKTOP_UNAVAILABLE');
  // Never resume this thread in the helper. Queue storage is shared with Codex;
  // the desktop's wake link asks its existing host to take over the submission.
  const listed=await client().request('thread/queue/list',{threadId:id,limit:100});let q=listed.data?.find(x=>x.clientUserMessageId===requestId);
  if(!q){try{q=(await client().request('thread/queue/add',{threadId:id,clientUserMessageId:requestId,input:[{type:'text',text}]})).queuedSubmission;}catch(error){if(error.message==='BACKEND_TIMEOUT'||error.message==='BACKEND_DISCONNECTED')throw Error('SEND_UNCERTAIN');throw error;}}
  if(!q||q.clientUserMessageId!==requestId)throw Error('SEND_UNCERTAIN');let awakened=false;try{await wake(id);awakened=true;}catch{}
  return {state:'queued',threadId:id,requestId,queueId:q.id,awakened};
 });requests.set(key,job);requestTexts.set(key,text);tail=job.catch(()=>{});job.catch(error=>{if(error.message!=='SEND_UNCERTAIN'){requests.delete(key);requestTexts.delete(key);}});return job;}
 return {target,history,send,async close(){closed=true;await rpc?.close();}};
}
module.exports={create,message,UUID,inside};
