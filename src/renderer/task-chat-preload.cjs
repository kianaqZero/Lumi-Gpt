'use strict';
const {contextBridge,ipcRenderer}=require('electron');
contextBridge.exposeInMainWorld('taskChat',{
 config:()=>ipcRenderer.invoke('task-chat:config'),
 history:cursor=>ipcRenderer.invoke('task-chat:history',cursor??null),
 send:value=>ipcRenderer.invoke('task-chat:send',value),
 openCodex:()=>ipcRenderer.invoke('task-chat:open-codex'),
});
