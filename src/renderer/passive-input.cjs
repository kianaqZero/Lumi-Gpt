// Runs inside the owning Electron main/UI thread. Never hooks another process.
const koffi=require('koffi'),path=require('node:path');
const system=path.join(process.env.SystemRoot,'System32');
const user=koffi.load(path.join(system,'user32.dll')),common=koffi.load(path.join(system,'comctl32.dll')),kernel=koffi.load(path.join(system,'kernel32.dll'));
const currentThread=kernel.func('uint32_t __stdcall GetCurrentThreadId()');
const getThread=user.func('uint32_t __stdcall GetWindowThreadProcessId(void *hwnd, _Out_ uint32_t *pid)');
const callbackType=koffi.proto('intptr_t __stdcall PetPassiveProc(void *hwnd, uint32_t message, uintptr_t wParam, intptr_t lParam, uintptr_t id, uintptr_t data)');
const setSubclass=common.func('int __stdcall SetWindowSubclass(void *hwnd, PetPassiveProc *proc, uintptr_t id, uintptr_t data)');
const removeSubclass=common.func('int __stdcall RemoveWindowSubclass(void *hwnd, PetPassiveProc *proc, uintptr_t id)');
const defaultProc=common.func('intptr_t __stdcall DefSubclassProc(void *hwnd, uint32_t message, uintptr_t wParam, intptr_t lParam)');
const active=new Set();
function install(win){
 const handle=win.getNativeWindowHandle().readBigUInt64LE(),pid=[0];
 const thread=getThread(handle,pid);
 if(pid[0]!==process.pid||thread!==currentThread())throw Error('Passive input hook requires its own window and UI thread');
 const stats={installed:true,activation_preserved:0,last_activation_utc:null},id=0x47515033;
 let registered=true,destroying=false,callback;
 const release=()=>{if(registered){registered=false;koffi.unregister(callback);active.delete(dispose);}};
 callback=koffi.register((hwnd,message,w,l)=>{
  // MA_NOACTIVATE keeps focus in the foreground app and preserves the actual
  // mouse down. Electron focusable:false otherwise permits MA_NOACTIVATEANDEAT.
  if(message===0x21&&(Number(l)&0xffff)===1){stats.activation_preserved++;stats.last_activation_utc=new Date().toISOString();return 3;}
  if(message===0x82){removeSubclass(hwnd,callback,id);stats.installed=false;destroying=true;queueMicrotask(release);}
  return defaultProc(hwnd,message,w,l);
 },koffi.pointer(callbackType));
 const dispose=()=>{
  if(!registered||destroying)return;
  if(stats.installed&&!removeSubclass(handle,callback,id))throw Error('Cannot detach passive input hook');
  stats.installed=false;release();
 };
 if(!setSubclass(handle,callback,id,0)){release();throw Error('Cannot install passive input hook');}
 active.add(dispose);
 return {snapshot:()=>({...stats}),dispose};
}
exports.install=install;
