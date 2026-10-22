'use strict';
// Windows-only, owning process only. Never address another application's window.
const koffi=require('koffi'),path=require('node:path');
const user=koffi.load(path.join(process.env.SystemRoot,'System32/user32.dll'));
const prototype=koffi.proto('int __stdcall LumiOwnInputVisibilityEnum(uintptr_t hwnd, intptr_t data)');
const enumerate=user.func('int __stdcall EnumChildWindows(uintptr_t parent, LumiOwnInputVisibilityEnum *callback, intptr_t data)');
const getClass=user.func('int __stdcall GetClassNameW(uintptr_t hwnd, void *buffer, int size)');
const isVisible=user.func('int __stdcall IsWindowVisible(uintptr_t hwnd)');
const isChild=user.func('int __stdcall IsChild(uintptr_t parent, uintptr_t child)');
const getProcess=user.func('uint32_t __stdcall GetWindowThreadProcessId(uintptr_t hwnd, _Out_ uint32_t *pid)');
const setPosition=user.func('int __stdcall SetWindowPos(uintptr_t hwnd, uintptr_t insertAfter, int x, int y, int width, int height, uint32_t flags)');
exports.create=function(win){
 const root=win.getNativeWindowHandle().readBigUInt64LE(),pid=[0];getProcess(root,pid);if(pid[0]!==process.pid)throw Error('Input visibility requires its own native window');
 let disposed=false,nextCheck=0,rows=[];const stats={checks:0,repairs:0,failures:0,last_check_utc:null,last_repair_utc:null,input_children:[]};
 const callback=koffi.register(hwnd=>{const buffer=Buffer.alloc(512);getClass(hwnd,buffer,256);if(buffer.toString('utf16le').split('\0')[0]==='Chrome_RenderWidgetHostHWND')rows.push(hwnd);return 1;},koffi.pointer(prototype));
 function maintain(enabled=true,force=false){
  if(disposed||!enabled||win.isDestroyed()||!win.isVisible()||(!force&&Date.now()<nextCheck))return;nextCheck=Date.now()+1000;rows=[];enumerate(root,callback,0);stats.checks++;stats.last_check_utc=new Date().toISOString();const children=[];
  for(const hwnd of rows){const owner=[0];getProcess(hwnd,owner);if(owner[0]!==process.pid||!isChild(root,hwnd))continue;const before=!!isVisible(hwnd);if(!before){
   // SWP_NOSIZE | NOMOVE | NOZORDER | NOACTIVATE | SHOWWINDOW.
   // Restore only the legacy input child's visibility; preserve position,
   // z-order, foreground focus and the normal mouse hit/activation guards.
   const ok=setPosition(hwnd,0,0,0,0,0,0x57);if(ok&&isVisible(hwnd)){stats.repairs++;stats.last_repair_utc=new Date().toISOString();}else stats.failures++;
  }children.push({hwnd:String(hwnd),visible:!!isVisible(hwnd),was_hidden:!before});}stats.input_children=children;
 }
 return {maintain,snapshot:()=>({...stats,input_children:stats.input_children.map(c=>({...c})),disposed}),dispose(){if(disposed)return;disposed=true;koffi.unregister(callback);}};
};
