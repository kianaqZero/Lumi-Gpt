'use strict';
const fs=require('node:fs'),path=require('node:path');
const {StringDecoder}=require('node:string_decoder');
const CHUNK=256*1024,MAX_BACKSCAN=32*1024*1024,MAX_LINE=8192;
const terminal=new Set(['completed','failed','interrupted']);
const norm=v=>path.resolve(String(v).replace(/^\\\\\?\\/, '')).toLowerCase();
// Read only the event envelope and counters; never parse prompts, tools or reasoning.
function event(line,thread){
 if(line.length>MAX_LINE||!/^\{"timestamp":"[^"]+",(?:"ordinal":\d+,)?"type":"event_msg","payload":\{"type":"(?:token_count|task_started)"/.test(line))return null;
 try{const o=JSON.parse(line),p=o.payload,t=Date.parse(o.timestamp),a=p.turn_attribution;
  if(!Number.isFinite(t)||p.thread_id&&p.thread_id!==thread||a&&(a.parent_turn_id||a.initiating_agent_path||a.root_turn_id&&p.turn_id&&a.root_turn_id!==p.turn_id))return null;
  if(p.type==='token_count'&&(!Number.isSafeInteger(p.info?.total_token_usage?.total_tokens)||p.info.total_token_usage.total_tokens<0))return null;
  return {p,t};
 }catch{return null;}
}
class TurnUsage{
 constructor(row,last,stat,options={}){
  this.file=row.rollout_path;this.thread=row.id;this.turn=last.turn_id;this.cwd=row.cwd;
  this.signature=stat.dev+':'+stat.ino;this.end=stat.size;this.position=stat.size;this.floor=Math.max(0,stat.size-(options.maxBackscan||MAX_BACKSCAN));
  this.eventTime=Date.parse(last.at);this.final=options.final!==false;this.phase='verify';this.reason='reading';this.usage=null;this.latest=null;this.latestAt=-Infinity;this.baseline=null;this.reset=false;this.carry='';this.startedAt=null;this.bytesRead=0;this.sealed=false;
  this.appendOffset=stat.size;this.pending='';this.skipping=false;this.decoder=new StringDecoder('utf8');
 }
 result(){return {usage:this.usage,reason:this.reason,reading:!['done','invalid'].includes(this.phase),bytes_read:this.bytesRead};}
 done(reason){this.phase='done';this.reason=reason;}
 commit(){
  if(this.baseline===null||this.latest===null||this.reset||this.latest<this.baseline){this.usage=null;this.reason=this.reset?'counter_reset':this.baseline===null?'baseline_unavailable':'count_unavailable';return;}
  this.usage={total_tokens:this.latest-this.baseline,source:'thread_cumulative_delta',final:this.final};this.reason='available';
 }
 verify(fd){
  const b=Buffer.allocUnsafe(Math.min(this.end,512*1024));const n=fs.readSync(fd,b,0,b.length,0);this.bytesRead+=n;
  const first=b.subarray(0,n).toString('utf8').split('\n')[0];
  let o;try{o=JSON.parse(first);}catch{throw Error('metadata_unavailable');}
  if(o.type!=='session_meta'||o.payload?.id!==this.thread||norm(o.payload.cwd)!==norm(this.cwd))throw Error('metadata_mismatch');
  this.phase='turn';
 }
 reverse(line){
  const e=event(line,this.thread);if(!e)return;const {p,t}=e;
  if(this.phase==='baseline'){
   if(p.type==='token_count'&&t<=this.startedAt){this.baseline=p.info.total_token_usage.total_tokens;this.commit();this.done(this.reason);}return;
  }
  if(p.type==='task_started'){
   if(p.turn_id!==this.turn){this.latest=null;this.latestAt=-Infinity;this.reset=false;return;}
   if(t>this.eventTime){this.done('turn_boundary_mismatch');return;}
   this.startedAt=t;this.phase='baseline';return;
  }
  if(p.turn_id&&p.turn_id!==this.turn)return;
  const total=p.info.total_token_usage.total_tokens;
  if(this.latest===null){this.latest=total;this.latestAt=t;}
  else if(t<=this.latestAt&&total>this.latest)this.reset=true;
 }
 forward(line){
  const e=event(line,this.thread);if(!e||this.sealed)return;const {p,t}=e;
  if(p.type==='task_started'){if(p.turn_id!==this.turn)this.sealed=true;return;}
  if(this.startedAt===null||t<this.startedAt||t<this.latestAt||p.turn_id&&p.turn_id!==this.turn)return;
  const total=p.info.total_token_usage.total_tokens;
  if(this.latest!==null&&total<this.latest)this.reset=true;
  this.latest=total;this.latestAt=t;this.commit();
 }
 step(){
  if(this.phase==='invalid'||this.sealed)return false;
  let fd;try{
   const st=fs.statSync(this.file);if(st.dev+':'+st.ino!==this.signature||st.size<this.end||st.size<this.appendOffset)throw Error('source_changed');
   fd=fs.openSync(this.file,'r');
   if(this.phase==='verify'){this.verify(fd);return true;}
   if(this.phase==='done'){
    const n=Math.min(CHUNK,st.size-this.appendOffset);if(!n)return false;
    const b=Buffer.allocUnsafe(n),read=fs.readSync(fd,b,0,n,this.appendOffset);this.appendOffset+=read;this.bytesRead+=read;
    for(const piece of this.decoder.write(b.subarray(0,read)).split(/(?<=\n)/)){
     if(!this.skipping)this.pending+=piece;if(this.pending.length>MAX_LINE){this.pending='';this.skipping=true;}
     if(piece.endsWith('\n')){if(!this.skipping)this.forward(this.pending.trimEnd());this.pending='';this.skipping=false;}
    }return this.appendOffset<st.size;
   }
   const n=Math.min(CHUNK,this.position-this.floor);if(!n){this.done(this.startedAt?'baseline_outside_window':'start_outside_window');return false;}
   const b=Buffer.allocUnsafe(n),start=this.position-n,read=fs.readSync(fd,b,0,n,start);this.bytesRead+=read;this.position=start;
   let part=b.subarray(0,read).toString('utf8');if(start+read===this.end&&!part.endsWith('\n')){const split=part.lastIndexOf('\n'),tail=part.slice(split+1);this.pending=tail.length<=MAX_LINE?tail:'';this.skipping=tail.length>MAX_LINE;part=split>=0?part.slice(0,split+1):'';}
   const lines=(part+this.carry).split('\n');this.carry=lines.shift();if(this.carry.length>MAX_LINE)this.carry='';
   if(start===0){lines.unshift(this.carry);this.carry='';}
   for(let i=lines.length-1;i>=0&&!['done','invalid'].includes(this.phase);i--)this.reverse(lines[i]);
   if(!['done','invalid'].includes(this.phase)&&this.position<=this.floor)this.done(this.startedAt?'baseline_outside_window':'start_outside_window');
   return this.phase!=='done'||this.appendOffset<st.size;
  }catch(e){this.phase='invalid';this.usage=null;this.reason=String(e.message);return false;}finally{if(fd!==undefined)fs.closeSync(fd);}
 }
}
exports.TurnUsage=TurnUsage;
exports.terminal=terminal;
