const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
exports.createQuotaBridge=function(options){
 const {root,owner,registry,onError,getWindow,getDragging,getSelected,setModel,setControls}=options;
 const allowed=path.resolve(__dirname,'../local_state/render_sessions');
 const rel=path.relative(allowed,root),session=path.basename(root);
 if(rel.startsWith('..')||path.isAbsolute(rel)||!/^[a-f0-9]{32}$/.test(session)||!Number.isSafeInteger(owner)||owner<=0)throw Error('Invalid isolated bridge location or owner');
 let timer,lastState=null,sequence=0,misses=0,observing=false,lastObservation=0,lastHealth=0,lastHiddenSync=0,latestRenderHealth=null,pendingMove=0,controlsTesting=false;
 const pendingControls=new Map();
 const forms=new Map(registry.forms.map(f=>[f.id,f]));
 function read(){const s=JSON.parse(fs.readFileSync(path.join(root,'state.json'),'utf8'));if(s.schema!==1||s.session!==session||s.owner_pid!==owner||!forms.has(s.form_id)||forms.get(s.form_id).state!==s.visual_state)throw Error('Invalid bridge state');if(!Number.isFinite(s.scale)||s.scale<.5||s.scale>1.15||!Number.isSafeInteger(s.x)||!Number.isSafeInteger(s.y))throw Error('Invalid bridge presentation');return s;}
 const snapshots=require('./snapshot-writer.cjs').create(root,['interaction_health.json','render_observation.json','controls_test.json']);
 function write(name,value){if(['interaction_health.json','render_observation.json','controls_test.json'].includes(name))snapshots.write(name,value);else if(options.test&&/^[a-z0-9_]+\.json$/.test(name))fs.writeFileSync(path.join(root,name),JSON.stringify(value,null,2));else throw Error('Unregistered bridge proof');}
 function command(kind,args={}){if(!['quota','accounts','tap','form','auto','appearance','refresh','history','tibo','tibo-source','tibo-dismiss','sound','scale','topmost','lock','move','quit','minimize','restore','language','quota-page','quota-follow','quota-refresh','reset-cards-read','reset-cards-refresh','reset-cards-consume'].includes(kind))throw Error('Unknown bridge command');if(kind==='form'&&!forms.has(args.id))throw Error('Unverified form');const seq=++sequence;const file=String(seq).padStart(12,'0')+'_'+crypto.randomUUID()+'.json',dest=path.join(root,'commands',file);fs.writeFileSync(dest+'.tmp',JSON.stringify({schema:1,session,sequence:seq,command:kind,...args}));fs.renameSync(dest+'.tmp',dest);if(kind==='move')pendingMove=seq;if(['scale','topmost','lock'].includes(kind))pendingControls.set(kind==='lock'?'locked':kind,{sequence:seq,value:args.value});return {accepted:true,sequence:seq};}
 function sync(){
  if((lastState?.tray_minimized||lastState?.fullscreen_suspended)&&Date.now()-lastHiddenSync<1000)return;
  lastHiddenSync=Date.now();
  try{process.kill(owner,0);const state=read();misses=0;lastState=state;if(state.closed){clearInterval(timer);options.onClosed();return;}
   const win=getWindow();if(!win||win.isDestroyed())return;
   const controls={scale:state.scale,topmost:Boolean(state.topmost),locked:Boolean(state.locked),fullscreen_suspended:Boolean(state.fullscreen_suspended),tray_minimized:Boolean(state.tray_minimized),foreground_epoch:Number(state.foreground_epoch)||0};
   controls.restore_epoch=Number.isSafeInteger(state.restore_epoch)&&state.restore_epoch>=0?state.restore_epoch:0;
   const area=options.visibleArea?.();if(area){controls.visible_left=Math.max(0,area.x-(state.x-365));controls.visible_right=Math.min(1150,area.x+area.width-(state.x-365));}
   // Each field keeps its newest local value until the owner has processed that command.
   // An acknowledgement of an older wheel event must not undo newer input.
   for(const [field,pending] of pendingControls){
    if(state.processed_sequence>=pending.sequence)pendingControls.delete(field);
    else controls[field]=pending.value;
   }
   setControls(controls);
   if(pendingMove&&state.processed_sequence>=pendingMove)pendingMove=0;
   if(!getDragging()&&!pendingMove){const [x,y]=win.getPosition();if(x!==state.x-365||y!==state.y)win.setPosition(state.x-365,state.y,false);}
   if(!state.fullscreen_suspended&&!state.tray_minimized&&!getDragging()&&getSelected()?.id!==state.form_id)setModel(state.form_id);
   win.webContents.send('quota-bridge:state',{manual_override:Boolean(state.manual_override),quota_summary:String(state.quota_summary).slice(0,160),quota_open:Boolean(state.quota_open),tibo_notice:state.tibo_notice||null,simulation:Boolean(state.simulation),tap_feedback_active:Boolean(state.tap_feedback_active),reset_cards:state.reset_cards||null,quota_detail:state.quota_detail||null,quota_notice:state.quota_notice||null,quota_notice_id:state.quota_notice_id||null,quota_notice_key:state.quota_notice_key||null});
   if(options.test&&state.control_test_request&&!controlsTesting){controlsTesting=true;controlsTest().catch(e=>write('controls_test.json',{status:'FAIL',error:String(e.stack)}));}
   const hidden=Boolean(state.tray_minimized||state.fullscreen_suspended);
   if(Date.now()-lastHealth>(hidden?10000:2000)){lastHealth=Date.now();write('interaction_health.json',{session,recorded_utc:new Date().toISOString(),owner_state_sequence:state.sequence,processed_sequence:state.processed_sequence,issued_sequence:sequence,observation_pending:observing,last_observation_utc:latestRenderHealth?.at||null,fullscreen_suspended:Boolean(state.fullscreen_suspended),snapshot_writer:snapshots.snapshot(),native:options.getNativeHealth?.()||null,render:latestRenderHealth?.value||null});}
   if(!hidden&&!observing&&Date.now()-lastObservation>750&&getSelected()?.id===state.form_id){observing=true;lastObservation=Date.now();win.webContents.executeJavaScript('({diagnostics:window.petDiagnostics.snapshot(),interaction:window.petDiagnostics.interactionHealth()})').then(async ({diagnostics,interaction})=>{
    latestRenderHealth={at:new Date().toISOString(),value:interaction};
    const observation={session,observed_utc:new Date().toISOString(),form_id:getSelected().id,state_sequence:state.sequence,visual_state:state.visual_state,native_position:win.getPosition(),drag_active:Boolean(getDragging()),native_visible:win.isVisible(),native_topmost:win.isAlwaysOnTop(),native_focused:win.isFocused(),interaction_health:interaction,controls:options.getControls(),diagnostics};
    if(options.test){const png=await win.webContents.capturePage(),region=png.crop({x:50,y:200,width:320,height:405}).toBitmap();let count=0;for(let i=3;i<region.length;i+=4)if(region[i]>0)count++;observation.character_pixels=count;if(count>1000)fs.writeFileSync(path.join(root,'frame_'+observation.form_id+'.png'),png.toPNG());}
    write('render_observation.json',observation);
   }).catch(()=>{}).finally(()=>observing=false);}
  }catch(error){if(++misses>=12){clearInterval(timer);onError(error);}}
 }
 async function controlsTest(){
  const checks=[],assert=(value,label)=>{if(!value)throw Error(label);checks.push(label);},wait=async predicate=>{const deadline=Date.now()+7000;while(Date.now()<deadline){try{const s=read();if(predicate(s))return s;}catch(error){if(error.code!=='ENOENT')throw error;}await new Promise(r=>setTimeout(r,150));}throw Error('Native control response deadline');};
  const win=getWindow(),click=async id=>{const rect=await win.webContents.executeJavaScript('(()=>{const r=document.getElementById('+JSON.stringify(id)+').getBoundingClientRect();return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)};})()');win.webContents.sendInputEvent({type:'mouseDown',...rect,button:'left',clickCount:1});win.webContents.sendInputEvent({type:'mouseUp',...rect,button:'left',clickCount:1});};
  const capture=async name=>{await win.webContents.executeJavaScript('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve())))');await new Promise(r=>setTimeout(r,100));fs.writeFileSync(path.join(root,name),(await win.webContents.capturePage()).toPNG());};
  let s=await wait(()=>true);const quotaBefore=s.quota_open;await click('quota');s=await wait(s=>s.quota_open!==quotaBefore);assert(true,'Native quota button reaches the WPF panel');
  const layout=()=>win.webContents.executeJavaScript('window.petDiagnostics.controlLayout()');
  const waitLayout=async test=>{const deadline=Date.now()+7000;while(Date.now()<deadline){const value=await layout();if(value.zoom_scale===value.zoom_target&&test(value))return value;await new Promise(r=>setTimeout(r,100));}throw Error('Control panel layout deadline');};
  let compact=await layout();assert(!compact.expanded&&compact.aria_expanded==='false','Controls initially occupy one collapsed toolbar');
  const attached=value=>Math.abs(value.model_box.y-value.dock.bottom-14)<1;
  assert(attached(compact),'Collapsed toolbar stays directly above the rendered character');
  const evalHead=code=>win.webContents.executeJavaScript(code),headRecords=[];
  for(const entry of registry.forms.filter(f=>f.head_motion&&f.state==='idle')){
   command('scale',{value:1});command('form',{id:entry.id});await wait(s=>s.form_id===entry.id&&getSelected()?.id===entry.id&&s.scale===1);await waitLayout(v=>v.model_id===entry.id&&Math.abs(v.ui_scale-1)<.0001);
   const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms)),call=(method,...args)=>evalHead('window.petDiagnostics.'+method+'('+args.map(x=>JSON.stringify(x)).join(',')+')');
   const config=await evalHead('window.petHost.config()'),info=await call('coreInfo');
   assert(config.selectedForm.head_motion.source_model===entry.head_motion.source_model&&config.selectedForm.head_motion.runtime_policy==='RELAXED_HEAD_IDLE_R1','R7 uses verified horn-consistent model and relaxed driver: '+entry.id);
   if(entry.body_motion){await call('override','ParamBodyAngleZ',0);await call('override','ParamBodyAngleY',0);} await call('override','ParamBreath',0);await call('override','ParamAngleZ',0);await pause(150);const neutral=await call('vertices');
   await call('override','ParamAngleZ',-30);await pause(150);const lo=await call('vertices');await capture(entry.appearance+'_head_left.png');
   await call('override','ParamAngleZ',30);await pause(150);const hi=await call('vertices');await capture(entry.appearance+'_head_right.png');
   const face=[],allMovement=[];
   for(let d=0;d<neutral.length;d++)for(let i=0;i<neutral[d].length;i+=2){const x=neutral[d][i]*info.canvas.PixelsPerUnit+info.canvas.Width/2,y=info.canvas.Height/2-neutral[d][i+1]*info.canvas.PixelsPerUnit,delta=Math.hypot(hi[d][i]-lo[d][i],hi[d][i+1]-lo[d][i+1])*info.canvas.PixelsPerUnit;
    if(delta>.02){const vertex={d,index:i/2,x,y,source_span:delta};allMovement.push(vertex);const r=entry.head_motion.face_roi;if(x>=r[0]&&x<=r[1]&&y>=r[2]&&y<=r[3])face.push(vertex);}
   }
   const normal=await call('snapshot'),normalFace=Math.max(...face.map(v=>v.source_span))*normal.scale,roi=entry.head_motion.roi;
   assert(face.length>=3&&normalFace>=entry.head_motion.minimum_face_span_css,'Head mesh retains visible authored range at normal size: '+entry.id);
   assert(allMovement.every(v=>v.x>=roi[0]-.1&&v.x<=roi[1]+.1&&v.y>=roi[2]-.1&&v.y<=roi[3]+.1),'Body remains fixed outside the head/adjacent guard region: '+entry.id);
   for(const horn of entry.head_motion.horns){let covered=0;for(let i=0;i<neutral[0].length;i+=2){const x=neutral[0][i]*info.canvas.PixelsPerUnit+info.canvas.Width/2,y=info.canvas.Height/2-neutral[0][i+1]*info.canvas.PixelsPerUnit;if(x>=horn.box[0]&&x<=horn.box[1]&&y>=horn.box[2]&&y<=horn.box[3]){covered++;assert(allMovement.some(v=>v.d===0&&v.index===i/2),'Horn contour vertex moves with the head: '+entry.id+' '+horn.name+' '+i/2);}}assert(covered>=3,'Horn region is represented by actual Core vertices: '+entry.id+' '+horn.name);}
   command('scale',{value:.5});await wait(s=>s.scale===.5);await waitLayout(v=>v.model_id===entry.id&&Math.abs(v.ui_scale-.75)<.0001);const small=await call('snapshot');assert(Math.abs(small.scale/normal.scale-.5)<.001,'Head visibility checks use the real half-size renderer: '+entry.id);
   command('scale',{value:1});await wait(s=>s.scale===1);await waitLayout(v=>v.model_id===entry.id&&Math.abs(v.ui_scale-1)<.0001);await call('clearOverrides');
   await call('headTarget',30);await pause(1200);const right=await call('snapshot');await call('headTarget',-30);await pause(1200);const left=await call('snapshot');
   assert(right.driven_head_value>6&&left.driven_head_value<-6&&Math.abs(right.driven_head_value)<19&&Math.abs(left.driven_head_value)<19,'Pointer targets follow both directions within the reduced limit: '+entry.id);
   const b=(await layout()).model_box,r=entry.head_motion.face_roi,cx=b.x+(r[0]+r[1])/2/info.canvas.Width*b.width,cy=b.y+(r[2]+r[3])/2/info.canvas.Height*b.height;
   await call('resetHeadMotion');win.webContents.sendInputEvent({type:'mouseMove',x:Math.round(cx-55),y:Math.round(cy)});await pause(1400);const pointerLeft=await call('snapshot');win.webContents.sendInputEvent({type:'mouseMove',x:Math.round(cx+55),y:Math.round(cy)});await pause(1400);const pointerRight=await call('snapshot');
   assert(pointerLeft.driven_head_value<-3&&pointerRight.driven_head_value>3&&pointerRight.head_driver.pointer_weight>.8,'Actual face-adjacent mouse events reach the relaxed driver: '+entry.id);
   win.webContents.sendInputEvent({type:'mouseMove',x:Math.round(cx),y:Math.round(b.y+b.height-10)});await pause(1400);assert((await call('snapshot')).head_driver.pointer_weight<.1,'Moving far below the face releases pointer steering: '+entry.id);
   await call('resetHeadMotion');if(entry.body_motion)await call('resetBodyMotion');const samples=[],faceSamples=[],idleDuration=entry.body_motion?22000:entry.appearance==='anime'?20000:17000,videoPromise=call('record',idleDuration);
   for(let t=0;t<Math.floor(idleDuration/400);t++){await pause(400);samples.push(await call('snapshot'));const vertices=await call('vertices');faceSamples.push(face.map(v=>[vertices[v.d][v.index*2],vertices[v.d][v.index*2+1]]));}
   const values=samples.map(s=>s.driven_head_value),video=await videoPromise,z=info.parameters.findIndex(p=>p.id==='ParamAngleZ');
   if(entry.body_motion){const bi=info.parameters.findIndex(p=>p.id==='ParamBodyAngleZ'),yi=info.parameters.findIndex(p=>p.id==='ParamBodyAngleY'),vals=samples.map(s=>s.body_values.z);assert(samples.every(s=>s.body_motion_supported&&Math.abs(s.submitted_parameter_values[bi]-s.body_values.z)<.01&&Math.abs(s.submitted_parameter_values[yi]-s.body_values.y)<.01),'Body pose and breathing response reach actual Core: '+entry.id);assert(Math.max(...vals)-Math.min(...vals)>5&&samples.at(-1).body_driver.cycle>=1,'Visible body loop continues through multiple phases: '+entry.id);}
   assert(Math.max(...values)>12&&Math.min(...values)<-10&&samples.every(s=>Math.abs(s.driven_head_value)<(entry.appearance==='anime'?28.1:23.1)),'Actual relaxed ambient motion visits both smaller head poses: '+entry.id);
   const resting=samples.filter(s=>s.head_driver.phase==='rest'&&Math.abs(s.driven_head_value)<2).length/samples.length;
   assert(resting>.2&&samples.every(s=>Math.abs(s.submitted_parameter_values[z]-s.driven_head_value)<.01),'Rendered idle includes settled pauses and submits the actual gentle head parameter: '+entry.id);
   const renderedFaceSpan=Math.max(...face.map((v,i)=>{const xs=faceSamples.map(frame=>frame[i][0]),ys=faceSamples.map(frame=>frame[i][1]);return Math.hypot(Math.max(...xs)-Math.min(...xs),Math.max(...ys)-Math.min(...ys))*info.canvas.PixelsPerUnit*normal.scale;}));
   assert(renderedFaceSpan>(entry.appearance==='anime'?4:3),'Looped idle moves actual face vertices visibly: '+entry.id);
   assert(video.bytes>10000&&samples.every(s=>s.visible_models===1&&s.errors.length===0),'Seventeen-second runtime recording contains one healthy model: '+entry.id);
   fs.copyFileSync(path.join(root,'renderer_proof/live2d_host.webm'),path.join(root,entry.appearance+'_head_runtime.webm'));
   headRecords.push({form_id:entry.id,model:entry.head_motion.source_model,policy:'RELAXED_HEAD_IDLE_R1',head_changed_vertices:allMovement.length,authored_face_span_css:normalFace,half_scale_factor:small.scale/normal.scale,actual_gentle_face_span_css:renderedFaceSpan,rest_fraction:resting,ambient_min:Math.min(...values),ambient_max:Math.max(...values),video:entry.appearance+'_head_runtime.webm',samples});
  }
  assert(headRecords.length===2&&registry.forms.filter(f=>f.head_motion).length===10,'Both idle motions and eight state-specific head poses are registered');
  write('head_runtime_checks.json',{status:'PASS',forms:headRecords,user_naturalness_acceptance:false,real_account_switch_requested:false});
  const stateHeadRecords=[];
  for(const entry of registry.forms.filter(f=>f.head_motion&&f.state!=='idle')){
   command('scale',{value:1});command('form',{id:entry.id});await wait(s=>s.form_id===entry.id&&getSelected()?.id===entry.id&&s.scale===1);await waitLayout(v=>v.model_id===entry.id&&Math.abs(v.ui_scale-1)<.0001);
   const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms)),call=(method,...args)=>evalHead('window.petDiagnostics.'+method+'('+args.map(x=>JSON.stringify(x)).join(',')+')');
   const config=await evalHead('window.petHost.config()'),info=await call('coreInfo');
   assert(config.selectedForm.state===entry.state&&config.selectedForm.head_motion.source_model===entry.head_motion.source_model,'Pose model follows reviewed semantic state: '+entry.id);
   if(entry.body_motion){await call('override','ParamBodyAngleZ',0);await call('override','ParamBodyAngleY',0);} await call('override','ParamBreath',0);await call('override','ParamAngleZ',0);await pause(150);const neutral=await call('vertices');
   await call('override','ParamAngleZ',-30);await pause(150);const lo=await call('vertices');await capture(entry.id+'_head_left.png');
   await call('override','ParamAngleZ',30);await pause(150);const hi=await call('vertices');await capture(entry.id+'_head_right.png');
   const face=[],changed=[];
   for(let d=0;d<neutral.length;d++)for(let i=0;i<neutral[d].length;i+=2){const x=neutral[d][i]*info.canvas.PixelsPerUnit+info.canvas.Width/2,y=info.canvas.Height/2-neutral[d][i+1]*info.canvas.PixelsPerUnit,span=Math.hypot(hi[d][i]-lo[d][i],hi[d][i+1]-lo[d][i+1])*info.canvas.PixelsPerUnit;if(span>.02){const v={d,index:i/2,x,y,span};changed.push(v);const r=entry.head_motion.face_roi;if(x>=r[0]&&x<=r[1]&&y>=r[2]&&y<=r[3])face.push(v);}}
   const normal=await call('snapshot'),authoredSpan=Math.max(...face.map(v=>v.span))*normal.scale;
   assert(face.length>=3&&authoredSpan>=entry.head_motion.minimum_face_span_css,'State head has actual face deformation: '+entry.id);
   assert((entry.head_motion.exclusions||[]).every(e=>changed.every(v=>v.x<e[0]||v.x>e[1]||v.y<e[2]||v.y>e[3])),'Head pose preserves protected hand and prop vertices: '+entry.id);
   for(const horn of entry.head_motion.horns){const indices=[];for(let i=0;i<neutral[0].length;i+=2){const x=neutral[0][i]*info.canvas.PixelsPerUnit+info.canvas.Width/2,y=info.canvas.Height/2-neutral[0][i+1]*info.canvas.PixelsPerUnit;if(x>=horn.box[0]&&x<=horn.box[1]&&y>=horn.box[2]&&y<=horn.box[3])indices.push(i/2);}assert(indices.length>=3&&indices.every(index=>changed.some(v=>v.d===0&&v.index===index)),'State horns follow head: '+entry.id+' '+horn.name);}
   await call('clearOverrides');await call('headTarget',null);await call('resetHeadMotion');
   const duration=entry.state==='pout_angry'?30000:entry.appearance==='anime'||entry.state==='thinking'?20000:entry.state==='greeting'?16000:10000,samples=[],frames=[],recording=call('record',duration);
   for(let t=0;t<duration/200;t++){await pause(200);samples.push(await call('snapshot'));const vertices=await call('vertices');frames.push(face.map(v=>[vertices[v.d][v.index*2],vertices[v.d][v.index*2+1]]));}
   const video=await recording,values=samples.map(s=>s.driven_head_value),z=info.parameters.findIndex(p=>p.id==='ParamAngleZ');
   assert(samples.every(s=>s.head_driver.behavior_state===entry.state&&Math.abs(s.submitted_parameter_values[z]-s.driven_head_value)<.01&&s.visible_models===1&&s.errors.length===0),'Real renderer uses state driver without overlap or errors: '+entry.id);
   if(entry.state==='greeting'||entry.state==='thinking'||entry.state==='pout_angry'||entry.appearance==='anime'){
    assert(Math.max(...values)>20&&Math.min(...values)<-20,'Repeated state motion reaches both head directions: '+entry.id);
    assert(samples.some(s=>s.head_driver.phase==='rest'&&Math.abs(s.driven_head_value)<2),'Repeated state motion includes neutral rests: '+entry.id);
    const cycles=new Set(samples.filter(s=>Math.abs(s.driven_head_value)>8).map(s=>s.head_driver.gesture));assert(cycles.size>=2,'Actual recording covers multiple distinct gesture cycles: '+entry.id);
    assert(values.every(v=>Math.abs(v)<28.1),'State motion stays inside verified key range: '+entry.id);
   }else{assert(Math.max(...values)>7&&values.every(v=>Math.abs(v)<16)&&samples.some(s=>s.head_driver.phase==='rest'&&Math.abs(s.driven_head_value)<2),'Q working retains the accepted restrained motion: '+entry.id);}
   const span=Math.max(...face.map((v,i)=>{const xs=frames.map(f=>f[i][0]),ys=frames.map(f=>f[i][1]);return Math.hypot(Math.max(...xs)-Math.min(...xs),Math.max(...ys)-Math.min(...ys))*info.canvas.PixelsPerUnit*normal.scale;}));
   write('state_visibility_'+entry.id+'.json',{span,video,values,samples});
   assert(span>(entry.appearance==='anime'?4:entry.state==='greeting'||entry.state==='thinking'||entry.state==='pout_angry'?2:1)&&video.bytes>10000,'Actual state gesture visibly moves face vertices and records: '+entry.id);
   let smallSpan=null;
   if(entry.appearance==='anime'||entry.state==='pout_angry'){
    command('scale',{value:.5});await wait(s=>s.scale===.5);await waitLayout(v=>v.model_id===entry.id&&Math.abs(v.ui_scale-.75)<.0001);await call('resetHeadMotion');
    const smallFrames=[],smallSamples=[];for(let t=0;t<(entry.state==='pout_angry'?100:80);t++){await pause(200);smallSamples.push(await call('snapshot'));const vertices=await call('vertices');smallFrames.push(face.map(v=>[vertices[v.d][v.index*2],vertices[v.d][v.index*2+1]]));}
    const small=await call('snapshot');smallSpan=Math.max(...face.map((v,i)=>{const xs=smallFrames.map(f=>f[i][0]),ys=smallFrames.map(f=>f[i][1]);return Math.hypot(Math.max(...xs)-Math.min(...xs),Math.max(...ys)-Math.min(...ys))*info.canvas.PixelsPerUnit*small.scale;}));write('half_visibility_'+entry.id+'.json',{span:smallSpan,scale:small.scale,normal_scale:normal.scale,min:Math.min(...smallSamples.map(s=>s.driven_head_value)),max:Math.max(...smallSamples.map(s=>s.driven_head_value)),samples:smallSamples});assert(smallSpan>(entry.appearance==='anime'?2:1)&&Math.min(...smallSamples.map(s=>s.driven_head_value))<-20,'Actual half-size motion remains visible over repeated cycles: '+entry.id);
    command('scale',{value:1});await wait(s=>s.scale===1);await waitLayout(v=>v.model_id===entry.id&&Math.abs(v.ui_scale-1)<.0001);
   }
   const file=entry.id+'_runtime.webm';fs.copyFileSync(path.join(root,'renderer_proof/live2d_host.webm'),path.join(root,file));
   stateHeadRecords.push({form_id:entry.id,state:entry.state,model:entry.head_motion.source_model,authored_face_span_css:authoredSpan,actual_face_span_css:span,half_size_face_span_css:smallSpan,ambient_min:Math.min(...values),ambient_max:Math.max(...values),duration_ms:duration,video:file,samples});
  }
  assert(stateHeadRecords.length===8,'Greeting, working, thinking and angry forms have actual repeating state gestures');
  write('state_head_runtime_checks.json',{status:'PASS',forms:stateHeadRecords,user_visual_acceptance:false,real_account_switch_requested:false});


  const attachmentCases=[];
  for(const entry of registry.forms){
   command('form',{id:entry.id});await wait(s=>s.form_id===entry.id&&getSelected()?.id===entry.id);
   let small;
   for(const scale of [.5,1.15]){
    command('scale',{value:scale});await wait(s=>Math.abs(s.scale-scale)<.0001);
    const value=await waitLayout(v=>v.model_id===entry.id&&Math.abs(v.ui_scale-Math.max(.75,scale))<.0001&&attached(v));
    assert(value.dock.y>=8-.1&&value.dock.right<=value.viewport.width&&attached(value),'Attached toolbar follows '+entry.id+' at '+scale);
    attachmentCases.push({form:entry.id,scale,layout:value});
    if(scale===.5)small=value;else assert(value.dock.y<small.dock.y-50,'Toolbar moves toward the enlarged character: '+entry.id);
    if(['chibi_lumi_idle_default','anime_lumi_nonchibi_idle_default'].includes(entry.id))await capture(entry.appearance+'_attached_'+String(scale).replace('.','_')+'.png');
   }
  }
  write('attached_layouts.json',{status:'PASS',cases:attachmentCases,real_account_switch_requested:false});
  const probe=()=>win.webContents.executeJavaScript('window.petDiagnostics.swapProbe()');
  let swap=await probe();assert(swap.completed>=14&&swap.observed_frames>100,'Real renderer completed the registered model changes while observing frames');
  assert(swap.visible_models===1&&swap.max_visible_models===1&&swap.min_visible_models===1&&swap.overlap_frames===0&&swap.empty_frames===0,'All sampled frames contain one character with no overlapping or empty model stage');
  const burst=registry.forms.filter(f=>f.appearance==='chibi').slice(0,3).map(f=>f.id);
  await win.webContents.executeJavaScript('Promise.all('+JSON.stringify(burst)+'.map(id=>window.petHost.selectModel(id)))');await wait(s=>s.form_id===burst[2]&&getSelected()?.id===burst[2]);
  swap=await probe();assert(swap.model_id===burst[2]&&swap.visible_models===1&&swap.overlap_frames===0&&swap.empty_frames===0,'Rapid model requests settle on the final selection without overlap or blank frames');
  write('atomic_swap_probe.json',{status:'PASS',probe:swap,rapid_request_ids:burst,real_account_switch_requested:false});
  command('auto');await wait(s=>!s.manual_override);
  await win.webContents.executeJavaScript('window.petHost.selectAppearance("anime")');await wait(s=>s.form_id==='anime_lumi_nonchibi_idle_default'&&!s.manual_override&&getSelected()?.id===s.form_id);
  command('scale',{value:1});await wait(s=>s.scale===1);compact=await waitLayout(v=>v.ui_scale===1&&attached(v));
  await capture('controls_compact.png');
  await click('controls-toggle');compact=await waitLayout(v=>v.expanded);assert(compact.aria_expanded==='true'&&compact.buttons.some(b=>b.id==='form-picker')&&compact.footer_count===1,'Native expand exposes controls, forms and status in one panel');
  const assertFits=value=>{assert(value.dock.x>=0&&value.dock.y>=8-.1&&value.dock.right<=value.viewport.width&&value.buttons.every(b=>b.x>=value.dock.x-.1&&b.right<=value.dock.right+.1&&b.bottom<=value.dock.bottom+.1),'Scaled controls and selectors remain within the panel and viewport');assert(value.model_box.y>=value.dock.bottom&&attached(value),'Expanded controls stay close to the character without covering its head');};
  for(const scale of [.5,1.15]){command('scale',{value:scale});await wait(s=>Math.abs(s.scale-scale)<.0001);compact=await waitLayout(v=>Math.abs(v.ui_scale-Math.max(.75,scale))<.0001);assertFits(compact);assert(Math.abs(compact.dock.width-350*Math.max(.75,scale))<.1,'Control panel actually changes rendered size with pet zoom: '+scale);}
  const wheel=compact.buttons.find(b=>b.id==='larger');win.webContents.sendInputEvent({type:'mouseWheel',x:Math.round(wheel.x+wheel.width/2),y:Math.round(wheel.y+wheel.height/2),deltaX:0,deltaY:-120});await wait(s=>s.scale<1.15);await waitLayout(v=>v.ui_scale<1.15);assert(true,'Native wheel over the panel zooms both the pet and its controls');
  command('scale',{value:1});await wait(s=>s.scale===1);await waitLayout(v=>v.ui_scale===1);await capture('controls_expanded.png');
  await click('controls-toggle');await waitLayout(v=>!v.expanded);assert(true,'Native collapse hides selectors and status together');
  win.webContents.sendInputEvent({type:'mouseDown',x:210,y:420,button:'right',clickCount:1});win.webContents.sendInputEvent({type:'mouseUp',x:210,y:420,button:'right',clickCount:1});await waitLayout(v=>v.expanded);assert(true,'Native right-click on the character reopens the compact controls');
  await click('controls-toggle');await waitLayout(v=>!v.expanded);
  await click('controls-toggle');await waitLayout(v=>v.expanded);
  const lockedBefore=s.locked;await click('lock');s=await wait(s=>s.locked!==lockedBefore&&options.getControls().locked===s.locked);assert(true,'Native lock button synchronizes both hosts');
  const scaleBefore=s.scale;await click('larger');s=await wait(s=>s.scale>scaleBefore);await wait(s=>Math.abs(options.getControls().scale-s.scale)<.0001);assert(true,'Native zoom changes the real renderer scale');
  const topmostBefore=s.topmost;await click('topmost');s=await wait(s=>s.topmost!==topmostBefore);assert(true,'Native topmost button reaches the owner');
  await click('accounts');await wait(s=>s.account_panel_open);assert(true,'Native accounts button opens the existing management panel');
  await win.webContents.executeJavaScript('window.petHost.selectAppearance("chibi")');await wait(s=>s.form_id==='chibi_lumi_idle_default'&&!s.manual_override&&getSelected()?.appearance==='chibi');assert(true,'Appearance selection preserves automatic mode and logical state');
  let rejected=false;try{await win.webContents.executeJavaScript('window.petHost.selectModel("unknown_form")');}catch{rejected=true;}assert(rejected,'Unknown form cannot cross the bridge');
  command('lock',{value:false});await wait(s=>!s.locked&&!options.getControls().locked);
  const area=require('electron').screen.getDisplayMatching(win.getBounds()).workArea;
  const safePosition={x:area.x+Math.round(area.width*.6),y:area.y+50};command('move',safePosition);
  await wait(s=>s.x===safePosition.x&&s.y===safePosition.y&&win.getPosition()[0]===s.x&&win.getPosition()[1]===s.y);
  assert(true,'Exact displacement fixtures start inside the current display work area');
  command('lock',{value:true});await wait(s=>s.locked&&options.getControls().locked);const before=getSelected().id;const dragBefore=getWindow().getPosition();const lockedMove=command('move',{x:dragBefore[0]-20,y:dragBefore[1]-10});await wait(s=>s.processed_sequence>=lockedMove.sequence&&s.x===dragBefore[0]&&s.y===dragBefore[1]);assert(getSelected().id===before,'Position lock prevents a move request');
  command('lock',{value:false});await wait(s=>!s.locked);command('move',{x:dragBefore[0]-20,y:dragBefore[1]-10});await wait(s=>s.x===dragBefore[0]-20&&s.y===dragBefore[1]-10);await wait(s=>{const p=win.getPosition();return p[0]===s.x&&p[1]===s.y;});assert(true,'Unlocked move synchronizes both native window positions');
  command('topmost',{value:true});await wait(s=>s.topmost&&win.isAlwaysOnTop());
  assert(true,'Physical drag fixture starts inside the current display work area');const beforeDrag=win.getPosition();
  const drag=await new Promise((resolve,reject)=>require('node:child_process').execFile('powershell.exe',['-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(__dirname,'owned-actor-drag.ps1'),'-ActorPid',String(process.pid),'-SessionRoot',root],{windowsHide:true,timeout:12000},(error,stdout)=>error?reject(error):resolve(JSON.parse(stdout))));
  write('owned_drag_attempt.json',{drag,before:beforeDrag,after:win.getPosition(),owner_position:[read().x,read().y]});
  await wait(s=>s.x===beforeDrag[0]-30&&s.y===beforeDrag[1]-20);assert(drag.owner_verified&&win.getPosition()[0]===beforeDrag[0]-30,'Owned native pointer drag commits the actor and quota owner positions');write('owned_drag.json',drag);
  win.webContents.sendInputEvent({type:'mouseDown',x:210,y:420,button:'left',clickCount:1});win.webContents.sendInputEvent({type:'mouseUp',x:210,y:420,button:'left',clickCount:1});await wait(s=>s.tap_feedback_active);assert(true,'Native character click reaches the existing interaction state');
  await wait(s=>getSelected()?.state==='greeting');assert(true,'Click activates the mapped greeting model');
  await wait(s=>!s.tap_feedback_active);assert(true,'Click feedback expires normally after changing models');
  let last;for(let i=0;i<105;i++)last=command('scale',{value:1});await wait(s=>s.processed_sequence>=last.sequence);assert(true,'The bridge processes commands beyond the first hundred files');
  write('controls_test.json',{status:'PASS',checks,real_account_switch_requested:false});
 }
 const initial=read();lastState=initial;if(options.test&&!initial.simulation)throw Error('Controlled tests require simulated accounts');
 return {initial,command,get state(){return lastState;},start(){if(timer)return;sync();timer=setInterval(sync,250);},sync,stop(){clearInterval(timer);timer=null;snapshots.close();}};
};
