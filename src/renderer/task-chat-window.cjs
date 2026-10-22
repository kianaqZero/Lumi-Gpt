'use strict';
const path=require('node:path'),fs=require('node:fs'),{pathToFileURL}=require('node:url');
const {create,UUID}=require('./task-conversation.cjs');
function createManager({BrowserWindow,ipcMain,shell,app,screen,base,getTasks,locale,serviceFactory=create}){
 const windows=new Map(),bySender=new Map();let service;
 // The companion's default session accepts only pet:// model resources.
 // Keep that policy intact and give report windows their own in-memory session.
 const chatSession=require('electron').session.fromPartition('lumi-task-chat');
 const resources=new Set(['task-chat.html','task-chat.css','task-chat-ui.js'].map(name=>pathToFileURL(path.join(base,name)).href));
 chatSession.setPermissionRequestHandler((_contents,_permission,callback)=>callback(false));
 chatSession.setPermissionCheckHandler(()=>false);
 chatSession.webRequest.onBeforeRequest((details,callback)=>callback({cancel:!resources.has(details.url)}));
 const binding=()=>JSON.parse(fs.readFileSync(path.join(base,'PROJECT_TASK_BINDING.json'),'utf8'));
 function resolveRow(id){const config=binding(),{DatabaseSync}=require('node:sqlite'),db=new DatabaseSync(path.join(path.dirname(config.sessions_root),'state_5.sqlite'),{readOnly:true});try{const row=db.prepare("SELECT id,name,cwd,rollout_path,archived FROM threads WHERE id=? AND agent_path IS NULL AND source IN ('vscode','cli')").get(id);if(row)row.rollout_path=row.rollout_path.replace(/^\\\\\?\\/,'');return row;}finally{db.close();}}
 const desktopAvailable=()=>new Promise(resolve=>{require('node:child_process').execFile(path.join(process.env.SystemRoot,'System32/WindowsPowerShell/v1.0/powershell.exe'),['-NoProfile','-NonInteractive','-Command',"$p=@(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue|Where-Object {$_.Path -and $_.Path.Replace([char]92,[char]47) -like '*/OpenAI.Codex_*/app/ChatGPT.exe'});[Console]::Write([int]($p.Count -gt 0))"],{windowsHide:true,timeout:4000},(error,out)=>resolve(!error&&out.trim()==='1'));});
 function backend(){return service??=serviceFactory({binding:binding(),resolveRow,executable:path.join(process.env.LOCALAPPDATA,'Programs/OpenAI/Codex/bin/codex.exe'),wake:id=>shell.openExternal('codex://threads/wake/'+id),desktopAvailable});}
 function sender(event){const entry=bySender.get(event.sender.id);if(!entry||event.senderFrame!==event.sender.mainFrame||event.senderFrame.url!==pathToFileURL(path.join(base,'task-chat.html')).href)throw Error('UNTRUSTED_CHAT_FRAME');return entry;}
 async function safe(fn){try{return {ok:true,...await fn()};}catch(error){const code=/^[A-Z_]+$/.test(error.message)?error.message:'TASK_CHAT_UNAVAILABLE';return {ok:false,error:code};}}
 ipcMain.handle('task-chat:config',event=>{const entry=sender(event);return {threadId:entry.id,title:entry.task.title,project:entry.task.project,initialReport:entry.task.response||entry.task.progress||'',locale:locale()};});
 ipcMain.handle('task-chat:history',(event,cursor)=>safe(()=>backend().history(sender(event).id,cursor)));
 ipcMain.handle('task-chat:send',(event,value)=>safe(()=>backend().send(sender(event).id,value||{})));
 ipcMain.handle('task-chat:open-codex',event=>{const entry=sender(event);return shell.openExternal('codex://threads/'+entry.id);});
 async function open(id){if(!UUID.test(id))throw Error('INVALID_THREAD');const task=getTasks().find(t=>t.thread_id===id);if(!task)throw Error('TASK_NO_LONGER_AVAILABLE');const existing=windows.get(id);if(existing&&!existing.window.isDestroyed()){existing.window.show();existing.window.focus();return {opened:true,reused:true};}
  // Opening is user initiated. This is a normal, resizable editor window;
  // the transparent companion itself remains non-activating and unchanged.
  const area=screen.getPrimaryDisplay().workAreaSize,width=Math.min(1000,area.width-40),height=Math.min(820,area.height-40);
  const win=new BrowserWindow({width,height,minWidth:Math.min(600,width),minHeight:Math.min(480,height),title:'Lumi · '+task.title,show:false,backgroundColor:'#faf8fd',autoHideMenuBar:true,webPreferences:{session:chatSession,preload:path.join(base,'task-chat-preload.cjs'),contextIsolation:true,nodeIntegration:false,sandbox:true,webSecurity:true}});
  const entry={id,task,window:win};windows.set(id,entry);bySender.set(win.webContents.id,entry);
  win.webContents.setWindowOpenHandler(()=>({action:'deny'}));const expected=pathToFileURL(path.join(base,'task-chat.html')).href;win.webContents.on('will-navigate',(event,url)=>{if(url!==expected)event.preventDefault();});
  const senderId=win.webContents.id;win.on('closed',()=>{windows.delete(id);bySender.delete(senderId);if(!windows.size){service?.close();service=null;}});
  try{await win.loadFile(path.join(base,'task-chat.html'));if(!win.isDestroyed())win.show();return {opened:true,reused:false};}catch(error){if(!win.isDestroyed())win.destroy();throw Error('CHAT_PAGE_LOAD_FAILED');}
 }
 function close(){for(const entry of windows.values())entry.window.destroy();service?.close();service=null;}
 app.on('before-quit',close);return {open,close};
}
module.exports={createManager};
