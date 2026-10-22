'use strict';
const fs=require('node:fs'),path=require('node:path');
// Coalesce disposable snapshots; commands and auth never use this writer.
exports.create=function(root,names,io=fs.promises){
 const allowed=new Set(names),pending=new Map(),stats={written:0,errors:0,last_error:null};let active=false,closed=false,timer=null;
 async function pump(){
  if(active||closed||!pending.size)return;active=true;
  try{
   for(const [name,value] of [...pending]){
    const file=path.join(root,name),tmp=file+'.'+process.pid+'.snapshot.tmp';
    try{await io.writeFile(tmp,value);await io.rename(tmp,file);stats.written++;if(pending.get(name)===value)pending.delete(name);stats.last_error=null;}
    catch(e){stats.errors++;stats.last_error={file:name,code:String(e.code||'WRITE_FAILED'),at:new Date().toISOString()};}
   }
  }finally{active=false;if(!closed&&pending.size){timer=setTimeout(pump,stats.last_error?250:0);timer.unref?.();}}
 }
 return {
  write(name,value){if(closed)return;if(!allowed.has(name))throw Error('Unregistered snapshot');pending.set(name,JSON.stringify(value,null,2));pump();},
  snapshot(){return {...stats,pending:pending.size,active};},
  close(){closed=true;clearTimeout(timer);pending.clear();},
  async flush(timeout=5000){const until=Date.now()+timeout;while(active||pending.size){if(Date.now()>until)throw Error('Snapshot flush timeout');await new Promise(r=>setTimeout(r,10));}}
 };
};
