const {app, BrowserWindow, ipcMain, protocol, session, screen, Tray, Menu, nativeImage, powerMonitor, shell} = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const identity=require('../APP_IDENTITY.json');
const language=require('./language.cjs');let updateTrayLanguage=()=>{};
function buildLocalizedMenu(rows){const locale=language.read();const visit=list=>list.map(row=>({...row,label:row.label?language.text(row.label,locale):row.label,...(row.submenu?{submenu:visit(row.submenu)}:{})}));return Menu.buildFromTemplate(visit(rows));}
app.setName(identity.name);
// Local compatibility candidate: keep hardware WebGL, use software window compositing.
// No unlimited frame scheduling or system/driver configuration changes.
app.commandLine.appendSwitch('disable-gpu-compositing');
if(process.platform==='win32')app.setAppUserModelId('studio.lumi.desktop');
const {validateModelBundle, resolveLocalFile} = require('./model-contract.cjs');
const galleryMode=process.argv.includes('--gallery-test');
const testMode = process.argv.includes('--self-test')||galleryMode;
const modelBase=path.resolve(__dirname,'../models/original');
const registry=require('./head-models.cjs').apply(JSON.parse(fs.readFileSync(path.join(modelBase,'MODEL_REGISTRY.json'),'utf8')));
require('./body-models.cjs').apply(registry);
require('./full-body-models.cjs').apply(registry);
const powerEvents=require('./power-monitor-events.cjs').create({capacity:20});
let detachPower=null;
let selectedForm, galleryRunning=false, galleryReady=null,bridgeReloading=false,bridgeSetModel;
const bridgeRoot=process.argv.find(a=>a.startsWith('--bridge='))?.slice(9),owner=Number(process.argv.find(a=>a.startsWith('--owner='))?.slice(8));
if(!bridgeRoot||testMode)throw Error('This renderer requires the isolated quota owner');
const bridge=require('./quota-bridge.cjs').createQuotaBridge({root:path.resolve(bridgeRoot),owner,registry,test:process.argv.includes('--bridge-test'),getWindow:()=>win,getDragging:()=>dragging||inputHeldUntil>Date.now(),getSelected:()=>bridgeReloading?null:selectedForm,getControls:()=>({...ui}),getNativeHealth:()=>({mouse_ignored:ignoreMouse,renderer_unresponsive:rendererUnresponsive,last_hit_utc:lastHitUtc,input_held:inputHeldUntil>Date.now(),graphics_features:app.isReady()?app.getGPUFeatureStatus():null,cursor_pending:Boolean(cursorPending),cursor_pending_age_ms:cursorPending?Math.max(0,Date.now()-cursorPending.at):null,cursor_timeouts:cursorTimeouts,cursor_sent:cursorSent,cursor_acked:cursorAcked,passive_input:passiveInput?.snapshot()||null,input_visibility:inputVisibility?.snapshot()||null,events:[...inputEvents],power_events:powerEvents.snapshot()}),visibleArea:()=>{const point=win&&!win.isDestroyed()?win.getPosition():[0,0];return screen.getDisplayNearestPoint({x:point[0]+575,y:point[1]+320}).workArea;},setControls:controls=>{const changed=Object.keys(controls).some(key=>ui[key]!==controls[key]);ui={...controls};if(win&&!win.isDestroyed()){applyWindowPresentation();if(changed)win.webContents.send('host:controls',ui);}},setModel:id=>bridgeSetModel(id),onError:fail,onClosed:()=>app.quit()});
function registeredModel(id){if(typeof id!=='string')throw Error('Invalid model identifier');const entry=registry.forms.find(f=>f.id===id);if(!entry||!entry.core_verified)throw Error('Unverified or unknown form');const file=path.resolve(entry.runtime_model_root||modelBase,entry.model3);return {entry,file,contract:validateModelBundle(file)};}
const proofName=process.argv.find(x=>x.startsWith('--proof='))?.slice(8)||'core_load'; if(!/^[a-z0-9_]+$/.test(proofName))throw Error('Invalid proof directory'); const proof = process.argv.includes('--bridge-test') ? path.join(path.resolve(bridgeRoot),'renderer_proof') : path.join(__dirname,(testMode||process.argv.includes('--smoke-start-exit'))?'../validation/'+proofName:'local_state/diagnostics');
const log = [];
let win, dragging = null, dragTimer = null, startupDeadline = null;
let taskObserver=null,taskPresentation=null,taskHeartbeat=null;
const taskSnapshots=require('./snapshot-writer.cjs').create(path.resolve(bridgeRoot),['task-state.json']);
function publishTask(value){taskPresentation=value;if(win&&!win.isDestroyed())win.webContents.send('codex-task:state',value);}
function startTaskObserver(){
 if(taskObserver)return;const config=JSON.parse(fs.readFileSync(path.join(__dirname,'PROJECT_TASK_BINDING.json'),'utf8'));
 const write=value=>{const s={...value,schema:1,session:path.basename(path.resolve(bridgeRoot)),owner_pid:owner,published_utc:new Date().toISOString()};taskSnapshots.write('task-state.json',s);publishTask(s);};
 taskObserver=require('./codex-observer.cjs').start(config,write,error=>write({thread_id:config.thread_id,status:'unknown',title:config.title,progress:'Codex状态接入暂不可用',turn_id:null,revision:0,live:false,scope_verified:false,waiting_supported:false,error_code:'observer_unavailable'}));
 taskHeartbeat=setInterval(()=>{if(!shuttingDown&&taskPresentation)write(taskPresentation);},2000);
}

let ui = {scale:1, topmost:true, locked:false};
let completed = false,shuttingDown=false,recoveryCount=0,recoveryWindowStart=0,modelFailure=null;
function incident(kind,detail){const row={at:new Date().toISOString(),kind,detail:String(detail).slice(0,1500),session:path.basename(bridgeRoot),selected_form:selectedForm?.id,hidden:Boolean(ui.tray_minimized||ui.fullscreen_suspended)};try{fs.appendFileSync(path.join(bridgeRoot,'lifecycle.jsonl'),JSON.stringify(row)+'\n');}catch{}inputEvent(kind,{detail:row.detail});}
function recoverModel(reason){if(shuttingDown)return;if(Date.now()-recoveryWindowStart>120000){recoveryWindowStart=Date.now();recoveryCount=0;}incident('model_recovery',reason);clearTimeout(startupDeadline);startupDeadline=null;modelFailure=String(reason);if(ui.tray_minimized||ui.fullscreen_suspended){interfaceReloading=false;return;}if(recoveryCount++<2){interfaceReloading=false;reloadInterface();}else{bridgeReloading=true;interfaceReloading=false;tray?.setToolTip('lumi · 界面恢复未完成，请右键重新加载');}}
function armLoadDeadline(reason){clearTimeout(startupDeadline);startupDeadline=setTimeout(()=>recoverModel(reason),45000);}
app.on('before-quit',()=>{detachPower?.();detachPower=null;shuttingDown=true;clearInterval(taskHeartbeat);taskObserver?.stop();taskObserver=null;taskSnapshots.close();});
let pointerTimer=null,ignoreMouse=true,appliedTopmost=null,lastPresentationSuspended=null;
let tray=null,rendererUnresponsive=false,lastHitUtc=null,interfaceReloading=false,passiveInput=null,inputVisibility=null;
let inputHeldUntil=0,cursorPending=null,cursorSequence=0,cursorLast=null,cursorLastAt=0,cursorSent=0,cursorAcked=0,cursorTimeouts=0,nativeRegionActive=false;
const inputEvents=[];
function inputEvent(kind,details={}){inputEvents.push({at:new Date().toISOString(),kind,...details});if(inputEvents.length>32)inputEvents.shift();}
function reloadInterface(){
 if(shuttingDown||interfaceReloading||!win||win.isDestroyed())return;
 inputEvent('interface_reload_requested');interfaceReloading=true;endDrag();dragPress=null;
 inputHeldUntil=0;cursorPending=null;cursorLast=null;ignoreMouse=true;win.setIgnoreMouseEvents(true,{forward:true});
 // Reload only the pet page; the quota owner, command sequence and Codex stay intact.
 bridgeReloading=true;armLoadDeadline('Interface reload timed out');
 if(rendererUnresponsive)win.webContents.forcefullyCrashRenderer();
 else win.webContents.reload();
}
let lastAppliedRestoreEpoch=0;
function applyWindowPresentation(){
 if(!win||win.isDestroyed())return;
 const suspended=Boolean(ui.fullscreen_suspended||ui.tray_minimized),topmost=ui.topmost&&!suspended;
 if(lastPresentationSuspended!==suspended){
  incident('presentation_change',JSON.stringify({suspended,tray_minimized:Boolean(ui.tray_minimized),fullscreen_suspended:Boolean(ui.fullscreen_suspended),desired_topmost:Boolean(ui.topmost)}));
  const resumed=lastPresentationSuspended===true&&!suspended;if(suspended&&bridgeReloading){clearTimeout(startupDeadline);startupDeadline=null;}
  if(resumed&&bridgeReloading){if(modelFailure)setImmediate(()=>{interfaceReloading=false;reloadInterface();});else armLoadDeadline('Model switch timed out after resume');}
  // Restore normal Chromium throttling while the whole pet is hidden. The
  // visible pet still needs unthrottled animation when another app has focus.
  win.webContents.setBackgroundThrottling(suspended);
  lastPresentationSuspended=suspended;
  taskObserver?.worker.postMessage({lowPower:suspended});
 }
 const actualTopmost=win.isAlwaysOnTop();if(appliedTopmost!==topmost||actualTopmost!==Boolean(topmost)){if(appliedTopmost===topmost)incident('topmost_drift',JSON.stringify({expected:Boolean(topmost),actual:actualTopmost}));win.setAlwaysOnTop(topmost);appliedTopmost=topmost;}
 if(suspended){endDrag();if(win.isVisible())win.hide();}
 else if(!startupDeadline&&!win.isVisible())win.showInactive();
 // Only an explicit tray restore may re-raise a visible but obscured window.
 // Ordinary polling must never keep pushing the pet above a fullscreen app.
 const restoreEpoch=Number(ui.restore_epoch)||0;
 if(restoreEpoch!==lastAppliedRestoreEpoch){
  lastAppliedRestoreEpoch=restoreEpoch;incident('explicit_restore',JSON.stringify({epoch:restoreEpoch,suspended,native_visible:win.isVisible(),native_topmost:win.isAlwaysOnTop()}));
  if(restoreEpoch>0&&!suspended&&!startupDeadline){win.setAlwaysOnTop(Boolean(topmost));win.showInactive();win.moveTop();}
 }
}
app.setPath('userData', process.argv.includes('--bridge-test') ? path.join(__dirname,'local_state','quota-owner-test',path.basename(path.resolve(bridgeRoot))) : path.join(__dirname,'local_state','quota-owner'));
app.commandLine.appendSwitch('autoplay-policy','user-gesture-required');
protocol.registerSchemesAsPrivileged([{scheme:'pet', privileges:{standard:true, secure:true, supportFetchAPI:true, corsEnabled:true}}]);
const ownsLock = app.requestSingleInstanceLock();
if (!ownsLock) app.exit(0);
app.on('second-instance',()=>{if(win && !win.isDestroyed() && !testMode)bridge.command('restore');});
const trusted = event => {
  // Closing can leave queued hit/drag messages after BrowserWindow destruction.
  if(shuttingDown||!win||win.isDestroyed()||event.sender.isDestroyed())return false;
  if(event.sender!==win.webContents || event.senderFrame?.url!=='pet://bundle/index.html') throw new Error('Untrusted host request');
  return true;
};
const delay = ms => new Promise(r=>setTimeout(r,ms));
function localWrite(name, data) {fs.mkdirSync(proof,{recursive:true});fs.writeFileSync(path.join(proof,name),data);}
function fail(error) {
  if(completed||shuttingDown)return;completed=true;
  incident('fatal_main_error',String(error?.stack||error));
  try{localWrite('result.json',JSON.stringify({status:'FAIL',error:String(error?.stack||error),log},null,2));}finally{app.exit(1);}
}
// Unexpected main errors must be recorded and exit, never leave a hidden modal
// error box with an animated but non-interactive Chromium child.
process.on('uncaughtException',fail);
process.on('unhandledRejection',fail);
function endDrag(){if(dragging&&win&&!win.isDestroyed()){const [x,y]=win.getPosition();bridge.command('move',{x:x+365,y});}dragging=null;if(dragTimer){clearInterval(dragTimer);dragTimer=null;}}
function clampPosition(x,y){
 const area=screen.getDisplayNearestPoint({x:Math.round(x+575),y:Math.round(y+win.getBounds().height/2)}).workArea;
  return [Math.round(Math.max(area.x-365,Math.min(x,area.x+area.width-785))),Math.round(Math.max(area.y,Math.min(y,area.y+area.height-win.getBounds().height)))];
}
let dragPress=null;
function beginDrag(offset={x:0,y:0}){
  if(ui.locked)return;
  const pressed=dragPress;dragPress=null;endDrag();const cursor=screen.getCursorScreenPoint();const bounds=win.getBounds();
  if(!offset||!Number.isFinite(offset.x)||!Number.isFinite(offset.y)||Math.abs(offset.x)>800||Math.abs(offset.y)>800)throw Error('Invalid drag displacement');dragging=pressed&&Date.now()-pressed.at<15000?{cursor:pressed.cursor,bounds:pressed.bounds,start:Date.now()}:{cursor:{x:cursor.x-offset.x,y:cursor.y-offset.y},bounds,start:Date.now()};
  dragTimer=setInterval(()=>{
    if(!dragging)return;
    if(Date.now()-dragging.start>15000){endDrag();return;}
    const pos=screen.getCursorScreenPoint();
    const [x,y]=clampPosition(dragging.bounds.x+pos.x-dragging.cursor.x,dragging.bounds.y+pos.y-dragging.cursor.y);
    win.setPosition(x,y,false);
  },16);
}
function applyControl(command){
  if(command==='quit'){win.close();return ui;}
  if(command==='topmost'){ui.topmost=!ui.topmost;applyWindowPresentation();}
  else if(command==='lock'){ui.locked=!ui.locked;if(ui.locked)endDrag();}
  else if(command==='larger')ui.scale=Math.min(1.15,Number((ui.scale+.05).toFixed(2)));
  else if(command==='smaller')ui.scale=Math.max(.5,Number((ui.scale-.05).toFixed(2)));
  else throw new Error('Unknown control');
  win.webContents.send('host:controls',{...ui});return {...ui};
}
async function snapshot(name){
  const image=await win.webContents.capturePage();
  const png=image.toPNG();localWrite(name+'.png',png);const region=image.crop({x:415,y:200,width:320,height:405}).toBitmap();let characterPixels=0;for(let i=3;i<region.length;i+=4)if(region[i]>0)characterPixels++;
  const pixels=image.toBitmap();let transparent=0,opaque=0;
  for(let i=3;i<pixels.length;i+=4){if(pixels[i]===0)transparent++;if(pixels[i]>200)opaque++;}
  return {character_pixels:characterPixels,sha256:crypto.createHash('sha256').update(png).digest('hex'),width:image.getSize().width,height:image.getSize().height,transparent_pixels:transparent,opaque_pixels:opaque};
}
async function selfTest(){
 const checks=[];const assert=(pass,label)=>{checks.push({label,pass:Boolean(pass)});if(!pass)throw Error(label);};
 const evaluate=code=>win.webContents.executeJavaScript(code,true);
 const initial=await evaluate('window.petDiagnostics.snapshot()'),info=await evaluate('window.petDiagnostics.coreInfo()');
 const expectMotion=process.argv.includes('--expect-local-motion');
 const planId=process.argv.find(a=>a.startsWith('--motion-plan='))?.slice(14);
 const plan=planId?JSON.parse(fs.readFileSync(path.join(modelBase,'LOCAL_MOTION_WORK_ORDER.json'),'utf8')).plans.find(p=>p.id===planId):null;
 if(planId&&!plan)throw Error('Unknown reviewed motion plan');
 if(plan&&!process.argv.find(a=>a.startsWith('--model='))?.includes('/'+plan.id+'_')&&!process.argv.find(a=>a.startsWith('--model='))?.includes('\\'+plan.id+'_'))throw Error('Model does not match the reviewed pose');
 const roi=plan?.roi||(info.canvas.Width===1086?[550,700,570,740]:[390,630,350,560]);
 assert(initial.renderer==='WebGL'&&initial.drawables>0,'Target original compiled moc3 has real WebGL drawables');
 assert(info.canvas.Width>0&&info.canvas.Height>0,'Core reports a valid original canvas');
 assert(info.drawable_ids.length===1,'Flat baseline has exactly one original-image ArtMesh');
 assert(win.isAlwaysOnTop(),'Native window starts topmost');
 const frame=await snapshot('original_transparent');assert(frame.transparent_pixels>1000&&frame.opaque_pixels>1000&&frame.character_pixels>1000,'Actual captured model contains visible pixels and alpha transparency');
 const probes=[];
 await evaluate('window.petDiagnostics.override("ParamBreath",0)');await delay(120);
 for(const id of info.parameters.map(p=>p.id)){
  const p=info.parameters.find(p=>p.id===id);if(!p)continue;
  await evaluate('window.petDiagnostics.override('+JSON.stringify(id)+','+p.min+')');await delay(120);const lo=await evaluate('window.petDiagnostics.snapshot()'),loVertices=await evaluate('window.petDiagnostics.vertices()');
  await evaluate('window.petDiagnostics.override('+JSON.stringify(id)+','+p.max+')');await delay(120);const hi=await evaluate('window.petDiagnostics.snapshot()'),hiVertices=await evaluate('window.petDiagnostics.vertices()');
  const changed=[];for(let drawable=0;drawable<loVertices.length;drawable++)for(let i=0;i<loVertices[drawable].length;i+=2){const x=loVertices[drawable][i],y=loVertices[drawable][i+1],dx=hiVertices[drawable][i]-x,dy=hiVertices[drawable][i+1]-y;if(Math.hypot(dx,dy)>1e-7)changed.push({drawable,index:i/2,x:x*info.canvas.PixelsPerUnit+info.canvas.Width/2,y:info.canvas.Height/2-y*info.canvas.PixelsPerUnit,dx:dx*info.canvas.PixelsPerUnit,dy:-dy*info.canvas.PixelsPerUnit});}
  const index=info.parameters.findIndex(p=>p.id===id);
  probes.push({id,min:p.min,max:p.max,actual_low:lo.submitted_parameter_values[index],actual_high:hi.submitted_parameter_values[index],parameter_input_changed:Math.abs(lo.submitted_parameter_values[index]-p.min)<0.0001&&Math.abs(hi.submitted_parameter_values[index]-p.max)<0.0001,vertices_changed:changed.length>0,changed_vertices:changed});
 }
 localWrite('parameter_probe.json',JSON.stringify({info,probes},null,2));
 assert(probes.length===info.parameters.length&&probes.every(p=>p.parameter_input_changed),'Every exported parameter accepts its range, or Core exports no unbound parameters');
 if(expectMotion){const breath=probes.find(p=>p.id==='ParamBreath');assert(breath&&breath.changed_vertices.length>0,'Compiled breathing parameter really moves original model vertices');assert(breath.changed_vertices.length<=12&&breath.changed_vertices.every(v=>v.x>=roi[0]&&v.x<=roi[1]&&v.y>=roi[2]&&v.y<=roi[3]&&v.x+v.dx>=roi[0]&&v.x+v.dx<=roi[1]&&v.y+v.dy>=roi[2]&&v.y+v.dy<=roi[3]&&Math.hypot(v.dx,v.dy)<=8),'Vertex movement stays within the small chest region and below 8 source pixels');assert(probes.filter(p=>p.id!=='ParamBreath').every(p=>!p.vertices_changed),'Face, eyes and other frozen motion parameters remain unbound');}
 else assert(probes.every(p=>!p.vertices_changed),'Static baseline has no vertex motion under all exported parameter ranges');
 let video=null;
 if(expectMotion){await evaluate('window.petDiagnostics.override("ParamBreath",0)');await delay(200);const min=await snapshot('breath_min');await evaluate('window.petDiagnostics.override("ParamBreath",1)');await delay(200);const max=await snapshot('breath_max');assert(min.sha256!==max.sha256,'Actual rendered frames change between breathing keyforms');await evaluate('window.petDiagnostics.clearOverrides()');const automaticA=await evaluate('window.petDiagnostics.snapshot()');const recording=evaluate('window.petDiagnostics.record(5000)');await delay(2000);const automaticB=await evaluate('window.petDiagnostics.snapshot()');assert(automaticA.vertex_signature!==automaticB.vertex_signature,'Automatic native breathing updates original Core vertices');video=await recording;assert(video.bytes>10000,'Actual moving model recording is saved');}
 await evaluate('window.petDiagnostics.clearOverrides()');await delay(200);
 const scaleBefore=(await evaluate('window.petDiagnostics.snapshot()')).scale;applyControl('smaller');await delay(100);assert((await evaluate('window.petDiagnostics.snapshot()')).scale<scaleBefore,'Native host zoom works with the target model');applyControl('larger');
 applyControl('topmost');assert(!win.isAlwaysOnTop(),'Topmost can turn off');applyControl('topmost');assert(win.isAlwaysOnTop(),'Topmost can restore');
 const [x,y]=win.getPosition();win.setPosition(x+12,y+9,false);const moved=win.getPosition();assert(moved[0]===x+12&&moved[1]===y+9,'Target model native window can move');win.setPosition(x,y,false);
 applyControl('lock');beginDrag();assert(dragging===null,'Position lock prevents drag');applyControl('lock');
 await evaluate('window.petDiagnostics.background("light")');await snapshot('original_light');await evaluate('window.petDiagnostics.background("dark")');await snapshot('original_dark');await evaluate('window.petDiagnostics.background("transparent")');
 const final=await evaluate('window.petDiagnostics.snapshot()');assert(final.frame_count>30,'Core renderer remains active');assert(final.errors.length===0&&log.every(x=>x.level!=='error'),'Original model loads and renders without errors');assert(!log.some(x=>x.blocked_url&&!x.blocked_url.startsWith('pet:')),'No remote asset or account access needed');
 localWrite('result.json',JSON.stringify({status:'PASS',model_type:expectMotion?'ACTUAL_ORIGINAL_LOCAL_CHEST_BREATH':'ACTUAL_ORIGINAL_STATIC_CUBISM_MODEL',core_load_verified:true,local_vertex_animation_verified:expectMotion,stage_02_complete:false,all_15_exported:false,user_visual_acceptance:false,windows:process.getSystemVersion(),checks,initial,final,info,probes,video,frame,log},null,2));completed=true;clearTimeout(startupDeadline);app.quit();
}
async function gallerySelfTest(){
 const checks=[],frames=[];const assert=(pass,label)=>{checks.push({label,pass:Boolean(pass)});if(!pass)throw Error(label);};
 const evaluate=code=>win.webContents.executeJavaScript(code,true);
 const semanticReview=JSON.parse(fs.readFileSync(path.join(modelBase,'STATE_ASSET_SEMANTICS.json'),'utf8'));
 assert(registry.forms.length===15&&registry.forms.filter(f=>f.appearance==='chibi').length===7&&registry.forms.filter(f=>f.appearance==='anime').length===8,'All 15 original forms are present');
 let unknownRejected=false;try{await evaluate('window.petHost.selectModel("not_registered")');}catch{unknownRejected=true;}assert(unknownRejected,'Unknown model selection is rejected');
 applyControl('smaller');applyControl('lock');
 for(const entry of registry.forms){
  if(selectedForm.id!==entry.id){const loaded=new Promise(resolve=>galleryReady=resolve);await evaluate('window.petHost.selectModel('+JSON.stringify(entry.id)+')');await loaded;}
  const config=await evaluate('window.petHost.config()');const state=await evaluate('window.petDiagnostics.snapshot()');
  assert(config.selectedForm.id===entry.id&&state.drawables===1&&state.errors.length===0,'Real Core loaded '+entry.id);
  assert(config.controls.scale===.95&&config.controls.locked===true,'Zoom and position lock survive '+entry.id);
  const selectors=await evaluate('({appearance:document.getElementById("appearance").value,form:document.getElementById("form").value,count:document.getElementById("form").options.length,label:document.getElementById("form").selectedOptions[0].textContent,heading:document.getElementById("identity").textContent})');
  assert(selectors.appearance===entry.appearance&&selectors.form===entry.id&&selectors.count===(entry.appearance==='chibi'?7:8),'Selectors reflect the active original form '+entry.id);
  const reviewed=semanticReview.corrections.find(c=>c.id===entry.id);
  if(reviewed)assert(config.selectedForm.state===reviewed.corrected_state&&config.selectedForm.source_sha256===reviewed.source_sha256&&selectors.label===entry.label&&entry.label===reviewed.label+(entry.motion_support==='LOCAL_CHEST_BREATH_ONLY'?' · 局部呼吸':' · 静态')&&selectors.heading==='非 Q 版 · '+entry.label,'Visually reviewed state, asset and labels match '+entry.id);
  const frame=await snapshot('gallery_'+entry.id);assert(frame.opaque_pixels>1000&&frame.transparent_pixels>1000&&frame.character_pixels>1000,'Visible character and transparency '+entry.id);frames.push({id:entry.id,frame});
  if(entry.motion_support==='LOCAL_CHEST_BREATH_ONLY'){
   const autoA=await evaluate('window.petDiagnostics.snapshot()');await delay(375);const autoB=await evaluate('window.petDiagnostics.snapshot()');
   assert(autoA.vertex_signature!==autoB.vertex_signature,'Unattended breathing updates real Core vertices '+entry.id);
   const breathIndex=(await evaluate('window.petDiagnostics.coreInfo()')).parameters.findIndex(p=>p.id==='ParamBreath');
   assert(autoB.breath_period_seconds===entry.breath_period_seconds&&Math.abs(autoB.submitted_parameter_values[breathIndex]-autoB.driven_breath_value)<.0001&&autoB.driven_breath_value>=0&&autoB.driven_breath_value<=1,'Reviewed breathing cadence reaches Core within parameter limits '+entry.id);
   win.webContents.sendInputEvent({type:'mouseDown',x:210,y:420,button:'left',clickCount:1});win.webContents.sendInputEvent({type:'mouseUp',x:210,y:420,button:'left',clickCount:1});await delay(200);
   const tapA=await evaluate('window.petDiagnostics.snapshot()');assert(tapA.tap_count===1&&tapA.tap_breath_active,'Actual native canvas click starts local breathing '+entry.id);
   assert(await evaluate('document.querySelector(".speech").textContent==="我在呢。"&&!document.querySelector(".speech").hidden'),'Click feedback bubble appears '+entry.id);
   await delay(450);const tapB=await evaluate('window.petDiagnostics.snapshot()');assert(tapA.vertex_signature!==tapB.vertex_signature,'Click response updates real model vertices '+entry.id);
   await delay(1150);assert(!(await evaluate('window.petDiagnostics.snapshot()')).tap_breath_active&&await evaluate('document.querySelector(".speech").hidden'),'Click response ends and bubble closes '+entry.id);
  }
 }
 assert(!log.some(x=>x.level==='error'),'All form transitions complete without renderer errors');
 localWrite('result.json',JSON.stringify({status:'PASS',checks,frames,forms:registry.forms.length,animated_forms:registry.forms.filter(f=>f.motion_support==='LOCAL_CHEST_BREATH_ONLY').length,static_forms:registry.forms.filter(f=>f.motion_support==='STATIC_ORIGINAL_FORM').length,animation_scope:'LOCAL_CHEST_BREATH_ONLY',stage_02_complete:false,automatic_state_policy_changed:false},null,2));completed=true;clearTimeout(startupDeadline);app.quit();
}
app.whenReady().then(async()=>{
  if(!ownsLock)return;
  detachPower=powerEvents.attach(powerMonitor);
  fs.mkdirSync(proof,{recursive:true});
  // Candidate imports are explicit file paths. No scan of credentials or other projects.
  const modelArg=process.argv.find(a=>a.startsWith('--model='));
  let modelFile=modelArg?path.resolve(modelArg.slice(8)):path.join(modelBase,'models/chibi_lumi_idle_local_breath_v2/chibi_lumi_idle_local_breath_v2.model3.json');
  modelFile=registeredModel(bridge.initial.form_id).file;
  let contract=validateModelBundle(modelFile);
  let modelRoot=path.dirname(modelFile);
  bridgeSetModel=id=>{if(bridgeReloading||selectedForm?.id===id)return;const next=registeredModel(id);bridgeReloading=true;modelFile=next.file;modelRoot=path.dirname(modelFile);contract=next.contract;selectedForm=next.entry;armLoadDeadline('Model switch deadline exceeded');win.webContents.send('host:model-load');};
  selectedForm=registry.forms.find(f=>f.id===bridge.initial.form_id);if(!selectedForm?.core_verified)throw Error('Only verified registered forms are available in this gallery');
  protocol.handle('pet',request=>{
    try{
      const url=new URL(request.url);
      const root=url.hostname==='bundle'?__dirname:url.hostname==='model'?modelRoot:null;
      if(!root)return new Response('Unknown root',{status:404});
      const file=resolveLocalFile(root,url.pathname);
      const relative=path.relative(root,file).replaceAll('\\','/');
      if(url.hostname==='bundle' && !(relative==='index.html'||relative==='style.css'||relative==='bubble-ui.css'||relative==='bubble-ui.js'||relative==='i18n.js'||relative==='renderer.js'||relative==='head-motion.js'||relative==='body-motion.js'||relative==='pixel-hit.js'||relative==='form-picker.js'||relative==='notice-header.js'||relative==='task-bubble.js'||relative==='long-gap-health.js'||relative==='configure-full-body-motion.js'||relative.startsWith('vendor/')))return new Response('Denied',{status:403});
      if(url.hostname==='model' && !contract.allowedFiles.includes(relative))return new Response('Not a model resource',{status:403});
      const types={'.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.js':'text/javascript; charset=utf-8','.json':'application/json','.png':'image/png','.moc3':'application/octet-stream'};
      return new Response(fs.readFileSync(file),{headers:{'Content-Type':types[path.extname(file)]||'application/octet-stream'}});
    }catch(e){return new Response('Invalid local resource',{status:403});}
  });
  session.defaultSession.setPermissionRequestHandler((_contents,_permission,callback)=>callback(false));
  session.defaultSession.webRequest.onBeforeRequest((details,callback)=>{
    const allow=details.url.startsWith('pet://bundle/')||details.url.startsWith('pet://model/');
    if(!allow)log.push({blocked_url:details.url});callback({cancel:!allow});
  });
  win=new BrowserWindow({width:1150,height:650,frame:false,transparent:true,backgroundColor:'#00000000',resizable:false,maximizable:false,minimizable:false,hasShadow:false,show:false,skipTaskbar:true,focusable:false,alwaysOnTop:false,title:identity.name,icon:path.resolve(__dirname,'..',identity.icon),webPreferences:{preload:path.join(__dirname,'preload.cjs'),contextIsolation:true,nodeIntegration:false,sandbox:true,webSecurity:true,backgroundThrottling:false,offscreen:testMode}});
  // A hidden Chromium input child routes mouse activation to this top window.
  // Preserve its native down without allowing the pet to take foreground focus.
  if(process.platform==='win32'){passiveInput=require('./passive-input.cjs').install(win);inputVisibility=require('./native-input-visibility.cjs').create(win);}
  win.on('hide',()=>incident('window_hidden',JSON.stringify({tray_minimized:Boolean(ui.tray_minimized),fullscreen_suspended:Boolean(ui.fullscreen_suspended)})));
  win.on('minimize',()=>incident('window_minimized','native_minimize'));
  win.on('restore',()=>incident('window_restored','native_restore'));
  win.on('show',()=>{incident('window_shown','native_show');appliedTopmost=null;applyWindowPresentation();inputVisibility?.maintain(true,true);setTimeout(()=>{if(!shuttingDown)inputVisibility?.maintain(!ui.fullscreen_suspended&&!ui.tray_minimized,true);},100).unref();});
  win.on('close',()=>{inputVisibility?.dispose();passiveInput?.dispose();});
  if(testMode)win.webContents.setFrameRate(60);
  const workArea=screen.getPrimaryDisplay().workArea;
  ui={scale:bridge.initial.scale,topmost:bridge.initial.topmost,locked:bridge.initial.locked};win.setPosition(bridge.initial.x-365,bridge.initial.y);
  win.webContents.on('context-menu',()=>{if(ignoreMouse||ui.fullscreen_suspended)return;buildLocalizedMenu([{label:'查看额度',click:()=>win.webContents.send('bubble:open','quota')},{label:'刷新额度',click:()=>bridge.command('refresh')},{label:'账号管理',click:()=>bridge.command('accounts')},{label:'提醒记录',click:()=>bridge.command('history')},{label:'Tibo 额度重置公告',click:()=>bridge.command('tibo')},{label:'开启提示音',click:()=>bridge.command('sound',{value:true})},{label:'关闭提示音',click:()=>bridge.command('sound',{value:false})},{type:'separator'},{label:'退出桌宠',click:()=>bridge.command('quit')}]).popup({window:win});});
  win.webContents.setWindowOpenHandler(()=>({action:'deny'}));
  win.webContents.on('will-navigate',(event,url)=>{if(url!=='pet://bundle/index.html')event.preventDefault();});
  win.webContents.on('console-message',details=>{if(['warning','error'].includes(details.level))log.push({level:details.level,message:details.message});});
  win.webContents.on('render-process-gone',(_event,details)=>{if(interfaceReloading){inputEvent('interface_reload_process_exit',{reason:details.reason});setImmediate(()=>{if(!shuttingDown&&!win.isDestroyed())win.webContents.reload();});return;}recoverModel('Renderer exited: '+details.reason);});
  win.webContents.on('unresponsive',()=>{rendererUnresponsive=true;inputEvent('renderer_unresponsive');});
  win.webContents.on('responsive',()=>{rendererUnresponsive=false;inputEvent('renderer_responsive');});
  win.webContents.on('before-mouse-event',(_event,input)=>{if(input.type==='mouseDown')inputEvent('native_mouse_down',{x:input.x,y:input.y});});
  if(process.platform==='win32')for(const message of [0x21,0x201,0x202])win.hookWindowMessage(message,(_w,l)=>{inputEvent('window_mouse_message',{message,detail:l.readUInt32LE()});});
  // A native tray remains accessible even if the transparent rendering page is stuck.
  if(!process.argv.includes('--bridge-test')){
   const icon=nativeImage.createFromPath(path.resolve(__dirname,'..',identity.icon_png)).resize({width:20,height:20});
   tray=new Tray(icon);tray.setToolTip(identity.name);
   tray.on('double-click',()=>bridge.command('restore'));
   updateTrayLanguage=()=>tray.setContextMenu(buildLocalizedMenu([
    {label:'显示桌宠',click:()=>bridge.command('restore')},
    {label:'收起到托盘',click:()=>bridge.command('minimize')},
    {label:'查看额度',click:()=>win.webContents.send('bubble:open','quota')},
    {label:'账号管理',click:()=>bridge.command('accounts')},
    {label:'Tibo 额度重置公告',click:()=>bridge.command('tibo')},
    {type:'separator'},
    {label:'重新加载桌宠界面',click:()=>{recoveryCount=0;interfaceReloading=false;reloadInterface();}},
    {label:'退出桌宠',click:()=>bridge.command('quit')}
   ]));updateTrayLanguage();
  }
  win.on('closed',()=>{shuttingDown=true;clearTimeout(startupDeadline);clearInterval(pointerTimer);if(tray){tray.destroy();tray=null;}endDrag();bridge.stop();try{bridge.command('quit');}catch{}app.quit();});
  win.on('blur',endDrag);
  win.setIgnoreMouseEvents(true,{forward:true});
  pointerTimer=setInterval(()=>{
   if(!win||win.isDestroyed())return;
   if(ui.tray_minimized||ui.fullscreen_suspended)return;
   if(inputHeldUntil&&inputHeldUntil<=Date.now()){
    inputHeldUntil=0;const next=Boolean(ui.fullscreen_suspended)||!nativeRegionActive;
    if(ignoreMouse!==next){ignoreMouse=next;win.setIgnoreMouseEvents(next,{forward:true});}
    inputEvent('input_hold_timeout');
   }
   inputVisibility?.maintain(!startupDeadline&&!ui.tray_minimized&&!ui.fullscreen_suspended);
   if(startupDeadline||ui.tray_minimized)return;
   // Keep one current location awaiting an acknowledgement. A lost reply must
   // not freeze hit testing forever while the animation continues playing.
   // Retry only the newest location at most once per 1500ms; a late reply for
   // an older sequence cannot acknowledge the new location.
   if(cursorPending){
    if(Date.now()-cursorPending.at<1500||rendererUnresponsive)return;
    inputEvent('cursor_ack_timeout',{sequence:cursorPending.sequence,age_ms:Date.now()-cursorPending.at});
    cursorPending=null;cursorLast=null;cursorTimeouts++;
   }
   const p=screen.getCursorScreenPoint(),b=win.getBounds(),point=ui.fullscreen_suspended?{x:-1,y:-1}:{x:p.x-b.x,y:p.y-b.y};
   if(!cursorPending&&cursorLast&&point.x===cursorLast.x&&point.y===cursorLast.y&&Date.now()-cursorLastAt<500)return;
   cursorPending={sequence:++cursorSequence,at:Date.now()};cursorLast=point;cursorLastAt=Date.now();cursorSent++;
   win.webContents.send('host:cursor',{...point,sequence:cursorSequence});
  },50);
  ipcMain.on('host:cursor-ack',(event,sequence)=>{if(!trusted(event)||!Number.isSafeInteger(sequence))return;if(cursorPending?.sequence===sequence){cursorPending=null;cursorAcked++;}});
  ipcMain.on('host:input-hold',(event,held)=>{if(!trusted(event)||typeof held!=='boolean')return;inputHeldUntil=held?Date.now()+5000:0;inputEvent('input_hold',{held});if(!held){const next=Boolean(ui.fullscreen_suspended)||!nativeRegionActive;if(ignoreMouse!==next){ignoreMouse=next;win.setIgnoreMouseEvents(next,{forward:true});inputEvent('mouse_passthrough',{ignored:next});}}});
  ipcMain.on('host:hit-region',(event,active)=>{if(!trusted(event))return;if(typeof active!=='boolean')return;nativeRegionActive=active;lastHitUtc=new Date().toISOString();const next=Boolean(ui.fullscreen_suspended)||(inputHeldUntil<=Date.now()&&!active);if(ignoreMouse!==next){ignoreMouse=next;win.setIgnoreMouseEvents(next,{forward:true});inputEvent('mouse_passthrough',{ignored:next});}});
  if(!process.argv.includes('--bridge-test')||process.argv.includes('--real-task-test')){try{startTaskObserver();}catch{publishTask({status:'unknown',progress:'Codex状态接入暂不可用',scope_verified:false});}}
  const taskChatWindows=require('./task-chat-window.cjs').createManager({BrowserWindow,ipcMain,shell,app,screen,base:__dirname,getTasks:()=>taskPresentation?.tasks||[],locale:()=>language.read()});
  ipcMain.handle('task-chat:open',(event,id)=>{if(!trusted(event))throw Error('UNTRUSTED_PET_FRAME');return taskChatWindows.open(id);});
  ipcMain.handle('host:config',event=>{if(!trusted(event))return;return {sampleOnly:false,modelUrl:'pet://model/'+encodeURIComponent(path.basename(modelFile)),modelSummary:contract.summary,bridgePresentation:bridge.state,taskPresentation,selectedForm,forms:registry.forms.map(({id,appearance,state,label,motion_support,core_verified})=>({id,appearance,state,label,motion_support,core_verified})),controls:{...ui},bubbleSettings:readBubbleSettings(),language:language.read(),languageCatalog:language.catalog};});
  ipcMain.handle('language:set',(event,locale)=>{if(!trusted(event))return;const result=language.save(locale);bridge.command('language',{value:result});updateTrayLanguage();return result;});
  ipcMain.handle('bubble:settings',(event,value)=>{if(!trusted(event))return;return saveBubbleSettings(value);});
  ipcMain.handle('bubble:account',(event,key)=>{if(!trusted(event))return;if(typeof key!=='string'||!/^[a-f0-9]{64}$/.test(key))throw Error('Invalid quota profile');return bridge.command('quota-page',{key});});
  ipcMain.handle('host:model',(event,id)=>{if(!trusted(event))return;registeredModel(id);return bridge.command('form',{id});});
  ipcMain.handle('quota-bridge:tibo-source',(event,id)=>{if(!trusted(event))return;if(typeof id!=='string'||!/^\d{15,22}$/.test(id))throw Error('Invalid public post ID');return bridge.command('tibo-source',{id});});
  ipcMain.handle('quota-bridge:appearance',(event,value)=>{if(!trusted(event))return;if(!['chibi','anime'].includes(value))throw Error('Invalid appearance');return bridge.command('appearance',{value});});
  ipcMain.handle('host:control',(event,command)=>{if(!trusted(event))return;inputEvent('control_request',{command});if(command==='quota'){win.webContents.send('bubble:open','quota');return {accepted:true};}if(['quota-refresh','quota-follow','reset-cards-read','reset-cards-refresh'].includes(command))return bridge.command(command);if(['accounts','auto','tibo','tibo-dismiss','minimize','restore'].includes(command))return bridge.command(command);if(command==='quit')return bridge.command('quit');const next=applyControl(command);bridge.command(command==='smaller'||command==='larger'?'scale':command,{value:command==='smaller'||command==='larger'?next.scale:command==='lock'?next.locked:next.topmost});return next;});
  ipcMain.on('host:press',(event,point)=>{if(!trusted(event))return;const bounds=win.getBounds();if(!point||!Number.isFinite(point.x)||!Number.isFinite(point.y)||point.x<0||point.y<0||point.x>=bounds.width||point.y>=bounds.height)return;dragPress={cursor:{x:bounds.x+point.x,y:bounds.y+point.y},bounds,at:Date.now()};});
  ipcMain.on('host:drag-start',(event,offset)=>{if(!trusted(event))return;beginDrag(offset);});
  ipcMain.on('host:drag-end',event=>{if(!trusted(event))return;const wasDragging=Boolean(dragging);endDrag();dragPress=null;if(wasDragging){const [x,y]=win.getPosition();bridge.command('move',{x:x+365,y});}});
  ipcMain.on('quota-bridge:tap',event=>{if(!trusted(event))return;bridge.command('tap');});
  ipcMain.on('host:ready',event=>{if(!trusted(event))return;interfaceReloading=false;rendererUnresponsive=false;modelFailure=null;inputEvent('interface_ready');cursorPending=null;cursorLast=null;bridgeReloading=false;setTimeout(()=>{if(shuttingDown||!win||win.isDestroyed())return;bridge.start();bridge.sync();},0);clearTimeout(startupDeadline);startupDeadline=null;applyWindowPresentation();if(galleryMode){if(galleryReady){const resolve=galleryReady;galleryReady=null;resolve();}else if(!galleryRunning){galleryRunning=true;gallerySelfTest().catch(fail);}}else if(testMode)selfTest().catch(fail);else {if(!ui.fullscreen_suspended&&!win.isVisible())win.showInactive();if(process.argv.includes('--smoke-start-exit'))setTimeout(async()=>{try{const config=await win.webContents.executeJavaScript('window.petHost.config()'),state=await win.webContents.executeJavaScript('window.petDiagnostics.snapshot()'),frame=await snapshot('visible_start');if(!win.isVisible()||!config.selectedForm.core_verified||state.errors.length||frame.opaque_pixels<1000)throw Error('Visible launcher validation failed');localWrite('result.json',JSON.stringify({status:'PASS',native_visible:true,selected:config.selectedForm.id,frame,state},null,2));completed=true;app.quit();}catch(e){fail(e);}},1700);}});
  ipcMain.on('host:model-error',(event,message)=>{if(trusted(event))recoverModel('Model loading failed: '+String(message).slice(0,400));});
  ipcMain.handle('cards:consume',(event,v)=>{if(!trusted(event))return;if(!v||Object.keys(v).some(k=>!['key','credit_id','request_id'].includes(k))||!/^[a-f0-9]{64}$/.test(v.key)||typeof v.credit_id!=='string'||v.credit_id.length<1||v.credit_id.length>256||! /^[a-f0-9-]{36}$/i.test(v.request_id))throw Error('Invalid reset-card request');return bridge.command('reset-cards-consume',v);});
  ipcMain.on('host:error',(event,message)=>{if(!trusted(event))return;recoverModel('Renderer: '+String(message).slice(0,1000));});
  ipcMain.handle('host:recording',(event,bytes)=>{if(!trusted(event))return;if(!testMode&&!process.argv.includes('--bridge-test'))throw new Error('Recording is enabled only in isolated simulated tests');const data=Buffer.from(bytes);if(data.length>8*1024*1024)throw new Error('Recording exceeded proof size limit');localWrite('live2d_host.webm',data);return {file:'live2d_host.webm',bytes:data.length};});
  armLoadDeadline('Model load timed out after 45 seconds');
  await win.loadURL('pet://bundle/index.html');
}).catch(fail);
// Host-side tests can exercise the same manual recovery used by the native tray.
exports.reloadInterface=reloadInterface;

const bubbleSettingsPath=path.resolve(__dirname,'../local_state/bubble-ui.json');
function readBubbleSettings(){try{const v=JSON.parse(fs.readFileSync(bubbleSettingsPath,'utf8'));if([280,320,360].includes(v.width)&&Number.isFinite(v.transparency)&&v.transparency>=0&&v.transparency<=80)return {width:v.width,transparency:v.transparency};}catch{}return {width:280,transparency:15};}
function saveBubbleSettings(v){if(!v||Object.keys(v).some(k=>!['width','transparency'].includes(k))||![280,320,360].includes(v.width)||!Number.isFinite(v.transparency)||v.transparency<0||v.transparency>80)throw Error('Invalid bubble settings');fs.mkdirSync(path.dirname(bubbleSettingsPath),{recursive:true});const file=bubbleSettingsPath+'.'+crypto.randomUUID()+'.tmp';fs.writeFileSync(file,JSON.stringify(v));fs.renameSync(file,bubbleSettingsPath);return v;}
