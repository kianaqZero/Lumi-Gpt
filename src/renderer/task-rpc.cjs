'use strict';
const {spawn}=require('node:child_process');
// This helper may inspect history and persist a queued message. It never starts
// or resumes an agent turn and never accepts approvals on the user's behalf.
const ALLOWED=new Set(['thread/read','thread/items/list','thread/queue/list','thread/queue/add']);
class Rpc {
 constructor({executable,home,cwd,spawnProcess=spawn,timeout=15000}){this.options={executable,home,cwd,spawnProcess,timeout};this.pending=new Map();this.next=1;this.closed=false;}
 async connect(){if(this.closed)throw Error('BACKEND_CLOSED');if(this.ready)return this.ready;this.ready=(async()=>{
  const o=this.options,env={...process.env,CODEX_HOME:o.home};delete env.ELECTRON_RUN_AS_NODE;
  this.child=o.spawnProcess(o.executable,['app-server','--stdio'],{cwd:o.cwd,env,windowsHide:true,stdio:['pipe','pipe','pipe']});
  const child=this.child;const broken=code=>{if(this.child!==child)return;this.ready=null;this.fail(code);if(child.exitCode===null)child.kill();};
  let buffer='';child.stdout.setEncoding('utf8');child.stdout.on('data',chunk=>{if(this.child!==child)return;buffer+=chunk;if(buffer.length>32*1024*1024){broken('RESPONSE_TOO_LARGE');return;}let n;while((n=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,n);buffer=buffer.slice(n+1);try{this.receive(JSON.parse(line));}catch{broken('INVALID_RPC_RESPONSE');return;}}});
  child.stderr.resume();child.on('error',()=>broken('BACKEND_UNAVAILABLE'));child.on('exit',()=>{if(this.child===child){this.ready=null;this.fail('BACKEND_DISCONNECTED');}});
  await this.raw('initialize',{clientInfo:{name:'lumi_task_chat',title:'Lumi task chat',version:'0.4.0'},capabilities:{experimentalApi:true}});
  this.child.stdin.write(JSON.stringify({method:'initialized'})+'\n');
 })();const ready=this.ready;try{return await ready;}catch(error){if(this.ready===ready)this.ready=null;throw error;}}
 receive(packet){if(packet.id!==undefined&&packet.method){this.child.stdin.write(JSON.stringify({id:packet.id,error:{code:-32601,message:'This client does not execute approval requests'}})+'\n');return;}const p=this.pending.get(packet.id);if(!p)return;this.pending.delete(packet.id);clearTimeout(p.timer);if(packet.error){const error=Error('CODEX_RPC_ERROR');error.rpcCode=packet.error.code;p.reject(error);}else p.resolve(packet.result);}
 fail(code){for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(Error(code));}this.pending.clear();}
 raw(method,params){if(this.closed)return Promise.reject(Error('BACKEND_CLOSED'));const id=this.next++;return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{this.pending.delete(id);reject(Error(method==='thread/queue/add'?'SEND_UNCERTAIN':'BACKEND_TIMEOUT'));},this.options.timeout);this.pending.set(id,{resolve,reject,timer});this.child.stdin.write(JSON.stringify({id,method,params})+'\n',error=>{if(error){clearTimeout(timer);this.pending.delete(id);reject(Error('BACKEND_DISCONNECTED'));}});});}
 async request(method,params){if(!ALLOWED.has(method))throw Error('RPC_METHOD_NOT_ALLOWED');await this.connect();return this.raw(method,params);}
 async close(){if(this.closed)return;this.closed=true;this.fail('BACKEND_CLOSED');if(!this.child)return;this.child.stdin.end();await Promise.race([new Promise(r=>this.child.once('exit',r)),new Promise(r=>setTimeout(r,1800))]);if(this.child.exitCode===null)this.child.kill();}
}
module.exports={Rpc,ALLOWED};
