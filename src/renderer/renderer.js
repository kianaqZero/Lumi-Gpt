'use strict';
const errors=[];
window.addEventListener('error',event=>{errors.push(event.message);window.petHost.error(event.message);});
window.addEventListener('unhandledrejection',event=>{errors.push(String(event.reason));window.petHost.error(String(event.reason));});
async function start(){
  const config=await window.petHost.config();
  const appearance=document.getElementById('appearance'),form=document.getElementById('form');
  const dock=document.getElementById('control-dock'),controlBody=document.getElementById('control-body'),controlToggle=document.getElementById('controls-toggle');
  let resizeForControls=null;
  let formPicker=null;
  const noticeHeader=window.PetNoticeHeader({dock,identity:document.getElementById('identity'),button:document.getElementById('tibo'),showPanel:()=>window.petHost.control('tibo'),openSource:id=>window.petHost.openTiboSource(id),dismiss:()=>window.petHost.control('tibo-dismiss')});
  function toggleControls(force){const expanded=typeof force==='boolean'?force:controlBody.hidden;if(formPicker)formPicker.close();controlBody.hidden=!expanded;controlToggle.setAttribute('aria-expanded',String(expanded));controlToggle.textContent=expanded?'收起 ▴':'控制 ▾';if(resizeForControls)resizeForControls();}
  controlToggle.addEventListener('click',()=>toggleControls());
  window.addEventListener('keydown',event=>{if(event.key==='Escape')toggleControls(false);});
  dock.addEventListener('wheel',event=>{if(event.target.closest('#lumi-bubble,#bk-settings,[role=dialog],.form-picker'))return;event.preventDefault();window.petHost.control(event.deltaY<0?'larger':'smaller');},{passive:false});
  function updateFormControls(){appearance.value=config.selectedForm.appearance;form.replaceChildren();
  for(const entry of config.forms.filter(f=>f.appearance===appearance.value)){const option=document.createElement('option');option.value=entry.id;option.textContent=entry.label;option.disabled=!entry.core_verified;form.appendChild(option);}form.value=config.selectedForm.id;if(formPicker)formPicker.sync();}updateFormControls();
  formPicker=window.PetFormPicker({dock,appearance,form});formPicker.sync();
  async function select(id){try{await window.petHost.selectModel(id);}catch(error){appearance.disabled=false;form.disabled=false;window.petHost.error(error.message);}}
  appearance.addEventListener('change',()=>window.petHost.selectAppearance(appearance.value).catch(error=>window.petHost.error(error.message)));
  form.addEventListener('change',()=>select(form.value));
  PIXI.live2d.config.sound=false;
  const scene=window.LumiBubbleUI.create({dock,controlBody,controlToggle,settings:config.bubbleSettings,host:window.petHost});
  const localization=window.LumiI18n.create({catalog:config.languageCatalog,locale:config.language,host:window.petHost,dock,controlBody});
  window.lumiLocalization=localization;
  const app=new PIXI.Application({view:document.getElementById('pet'),width:420,height:650,backgroundAlpha:0,antialias:true,resolution:window.devicePixelRatio||1,autoDensity:true});
  app.ticker.maxFPS=60;
  let model=await PIXI.live2d.Live2DModel.from(config.modelUrl,{autoInteract:false,autoUpdate:true});
  let releaseFullBody=null;
  if(config.selectedForm.full_body_motion){releaseFullBody=await window.PetFullBodyMotionConfig.configure(model);await model.motion('Idle',0,3);}
  app.stage.addChild(model);
  let originalWidth=model.width,originalHeight=model.height;
  const swaps={completed:0,observed_frames:0,min_visible_models:1,max_visible_models:1,overlap_frames:0,empty_frames:0};
  let control={...config.controls},frames=0,headTarget=null,headValue=0,headDriver=window.PetHeadMotion.create(config.selectedForm.appearance,config.selectedForm.state);
  let bodyDriver=config.selectedForm.body_motion?window.PetBodyMotion.create(config.selectedForm.body_motion):null,bodyValues=null;
  let displayedScale=control.scale,zoomFrame=null,zoomTime=0;
  const started=performance.now();
  let fit=Math.min(312/originalWidth,440/originalHeight);
  model.anchor.set(.5,1);model.position.set(210,618);
  resizeForControls=()=>{
    const uiScale=Math.max(.75,Math.min(1.15,displayedScale));
    document.documentElement.style.setProperty('--controls-scale',String(uiScale));
    const dockHeight=0,dockWidth=0,gap=0,margin=8;scene.setViewport(control);
    fit=Math.min(312/originalWidth,440/originalHeight);
    const availableHeight=618-margin-gap-dockHeight;
    model.scale.set(Math.min(fit*displayedScale,availableHeight/originalHeight));
    const bounds=roleBounds();
    const center=Math.max(dockWidth/2+margin,Math.min(innerWidth-dockWidth/2-margin,bounds.x+bounds.width/2));
    document.documentElement.style.setProperty('--controls-top',String(Math.max(margin,bounds.y-gap-dockHeight))+'px');
    document.documentElement.style.setProperty('--controls-center',String(center)+'px');scene.layout(bounds,config.selectedForm.appearance);
  };
  function animateZoom(now){
    zoomFrame=null;
    const elapsed=Math.max(0,Math.min(50,now-zoomTime));zoomTime=now;
    displayedScale+=(control.scale-displayedScale)*(1-Math.exp(-elapsed/55));
    if(Math.abs(control.scale-displayedScale)<.0001)displayedScale=control.scale;
    resizeForControls();
    if(displayedScale!==control.scale)zoomFrame=requestAnimationFrame(animateZoom);
  }
  function updateControls(next){const wasSuspended=Boolean(control.fullscreen_suspended||control.tray_minimized);control={...next};if(control.fullscreen_suspended||control.tray_minimized){app.ticker.stop();PIXI.Ticker.shared.stop();}else if(wasSuspended){PIXI.Ticker.shared.start();app.ticker.start();}document.getElementById('topmost').textContent=control.topmost?'置顶 ✓':'置顶';document.getElementById('lock').textContent=control.locked?'解锁':'锁定';resizeForControls();if(displayedScale!==control.scale&&zoomFrame===null){zoomTime=performance.now();zoomFrame=requestAnimationFrame(animateZoom);}}
  new ResizeObserver(()=>resizeForControls()).observe(dock);
  window.addEventListener('resize',()=>resizeForControls());
  updateControls(control);window.petHost.onControls(updateControls);
  noticeHeader.setIdentity(config.sampleOnly?'Haru 官方示例 · 非项目角色':(config.selectedForm.appearance==='chibi'?'Q 版':'非 Q 版')+' · '+config.selectedForm.label.replace(' · 局部呼吸',''));
  document.querySelector('footer').textContent=config.sampleOnly?'Haru 示例 © Live2D Inc. · 仅验证渲染宿主':config.selectedForm.motion_support==='LOCAL_CHEST_BREATH_ONLY'?'局部呼吸试作 · 尚未接入正式桌宠':'原形态静态模型 · 动画尚未绑定';
  for(const command of ['smaller','larger','lock','topmost','quota','accounts','auto','quit','minimize'])document.getElementById(command).addEventListener('click',()=>window.petHost.control(command));
  let bridgeTapActive=false;function updateBridge(value){scene.updateBridge(value);noticeHeader.update(value.tibo_notice,value.simulation);document.querySelector('footer').textContent=(value.manual_override?'手动形态 · ':'自动状态 · ')+value.quota_summary;document.getElementById('quota').textContent=value.quota_open?'收起额度':'额度';if(value.tap_feedback_active&&!bridgeTapActive&&tapStarted===null)tapStarted=performance.now();bridgeTapActive=Boolean(value.tap_feedback_active);speech.hidden=true;scene.tapActive=Boolean(value.tap_feedback_active);}
  setTimeout(()=>updateBridge(config.bridgePresentation),0);window.petHost.onBridge(updateBridge);
  function roleBounds(){const b=model.getBounds();return {x:b.x+365,y:b.y,width:b.width,height:b.height};}
  const canvas=app.view;let press=null,tapStarted=null,tapCount=0,tapTimer=null,drivenBreathValue=null;
  canvas.addEventListener('contextmenu',event=>{event.preventDefault();if(characterHit(event.clientX,event.clientY))toggleControls();});
  let breathPeriod=Number(config.selectedForm.breath_period_seconds),breathEpoch=performance.now();
  if(config.selectedForm.motion_support==='LOCAL_CHEST_BREATH_ONLY'&&(!Number.isFinite(breathPeriod)||breathPeriod<2||breathPeriod>10))throw Error('Invalid verified breathing period');
  const taskBubble=window.PetTaskBubble.create(dock);taskBubble.update(config.taskPresentation);window.petHost.onTask(value=>{taskBubble.update(value);scene.updateTask(value);});scene.updateTask(config.taskPresentation);
  const speech=document.createElement('div');speech.className='speech';speech.hidden=true;speech.setAttribute('role','status');dock.appendChild(speech);
  let pixelHit=window.PetPixelHit.create(model),cursor={x:-1,y:-1},nativeHit=null;
  function alphaAt(x,y){return pixelHit.hit(x-365,y);}
  function characterHit(x,y){return alphaAt(x,y);}
  function updateNativeHit(){
    const insideDock=scene.hit(cursor.x,cursor.y);
    const active=Boolean(press)||insideDock||alphaAt(cursor.x,cursor.y);
    if(nativeHit!==active){nativeHit=active;window.petHost.hitRegion(active);}
  }
  // Use cached alpha and current deformed mesh, including zoom.
  // Re-evaluate every rendered frame even when the physical pointer is stationary.
  let renderedFrames=0,lastRenderMs=null;
  app.renderer.on('postrender',()=>{renderedFrames++;lastRenderMs=performance.now();updateNativeHit();});
  // Input must remain usable when rendering pauses or the GPU stalls.
  window.petHost.onCursor(point=>{cursor=point;updateNativeHit();});
  // Physical polling is authoritative; delayed DOM moves must not flip native
  // passthrough using a stale location.
  let inputHeld=false,inputHoldTimer=null;
  document.addEventListener('pointerdown',event=>{if(event.button!==0)return;inputHeld=true;window.petHost.inputHold(true);clearTimeout(inputHoldTimer);inputHoldTimer=setTimeout(releaseInputHold,5000);},true);
  function releaseInputHold(){if(!inputHeld)return;inputHeld=false;clearTimeout(inputHoldTimer);window.petHost.inputHold(false);updateNativeHit();}
  document.addEventListener('pointerup',releaseInputHold,true);
  document.addEventListener('pointercancel',releaseInputHold,true);
  window.addEventListener('blur',releaseInputHold);
  const inputHealth={clicks:0,last_click:null,last_click_ms:null};
  dock.addEventListener('click',event=>{inputHealth.clicks++;inputHealth.last_click=event.target.closest('button')?.id||'dock';inputHealth.last_click_ms=performance.now();},true);
  const frameHealth=window.PetLongGapHealth.create({thresholdMs:1000,capacity:20});
  function respondToTap(){window.petHost.bridgeTap();tapCount++;clearTimeout(tapTimer);scene.toggle('chat');speech.hidden=true;if(config.selectedForm.motion_support==='LOCAL_CHEST_BREATH_ONLY')tapStarted=performance.now();}
  canvas.addEventListener('pointerdown',event=>{if(event.button!==0||!characterHit(event.clientX,event.clientY))return;press={x:event.clientX,y:event.clientY,drag:false};headTarget=null;window.petHost.primeDrag({x:event.clientX,y:event.clientY});canvas.setPointerCapture(event.pointerId);});
  canvas.addEventListener('pointermove',event=>{
    if(config.selectedForm.head_motion){const cv=core._model.canvasinfo;headTarget=press?null:window.PetHeadMotion.pointerTarget(event.clientX,event.clientY,roleBounds(),{Width:cv.CanvasWidth,Height:cv.CanvasHeight},config.selectedForm.head_motion.face_roi,config.selectedForm.appearance);}else if(!config.selectedForm.full_body_motion)model.focus(event.clientX-365,event.clientY);
    if(press && !press.drag && Math.hypot(event.clientX-press.x,event.clientY-press.y)>6){press.drag=true;window.petHost.startDrag({x:event.clientX-press.x,y:event.clientY-press.y});}
  });
  canvas.addEventListener('pointerleave',()=>{headTarget=null;});
  canvas.addEventListener('pointerup',event=>{if(press && !press.drag&&characterHit(event.clientX,event.clientY))respondToTap();press=null;window.petHost.endDrag();});
  canvas.addEventListener('pointercancel',()=>{press=null;window.petHost.endDrag();});
  canvas.addEventListener('lostpointercapture',()=>{press=null;window.petHost.endDrag();});
  window.addEventListener('blur',()=>{press=null;headTarget=null;window.petHost.endDrag();});
  canvas.addEventListener('wheel',event=>{if(!characterHit(event.clientX,event.clientY))return;event.preventDefault();window.petHost.control(event.deltaY<0?'larger':'smaller');},{passive:false});
  let core=model.internalModel.coreModel;const overrides=new Map();let appliedParameters=[],submitted={angle_x:0,eye_open_left:1};
  function attachModelDriver(instance){const localCore=instance.internalModel.coreModel;instance.internalModel.on('beforeModelUpdate',()=>{
   if(instance!==model)return;
   drivenBreathValue=(1-Math.cos((performance.now()-breathEpoch)/1000/breathPeriod*Math.PI*2))/2;
   if(tapStarted!==null){const t=(performance.now()-tapStarted)/1400;if(t>=1)tapStarted=null;else drivenBreathValue=(1-Math.cos(t*Math.PI*2))/2;}
   if(!config.selectedForm.full_body_motion)localCore.setParameterValueById('ParamBreath',drivenBreathValue);
   const head=config.selectedForm.head_motion;
   if(head){if(head.runtime_policy!==window.PetHeadMotion.id)throw Error('Unknown verified head motion driver');headValue=headDriver.step(performance.now(),headTarget);localCore.setParameterValueById(head.parameter,headValue);}
   if(bodyDriver){bodyValues=bodyDriver.step(performance.now(),drivenBreathValue,headValue);localCore.setParameterValueById('ParamBodyAngleZ',bodyValues.z);localCore.setParameterValueById('ParamBodyAngleY',bodyValues.y);}else bodyValues=null;
   for(const [id,value] of overrides)localCore.setParameterValueById(id,value);
   appliedParameters=[...localCore._model.parameters.values];submitted={angle_x:localCore.getParameterValueById('ParamAngleX'),eye_open_left:localCore.getParameterValueById('ParamEyeLOpen')};
  });}
  attachModelDriver(model);
  async function finishTransition(animation){try{await Promise.race([animation.finished,new Promise(resolve=>setTimeout(resolve,400))]);}catch{}finally{animation.cancel();}}
  async function replaceModel(){
   const nextConfig=await window.petHost.config(),next=await PIXI.live2d.Live2DModel.from(nextConfig.modelUrl,{autoInteract:false,autoUpdate:true});
   let nextRelease=null;
   if(nextConfig.selectedForm.full_body_motion){nextRelease=await window.PetFullBodyMotionConfig.configure(next);await next.motion('Idle',0,3);}
   const transition=!control.fullscreen_suspended&&!control.tray_minimized&&document.visibilityState==='visible'&&config.selectedForm.state!==nextConfig.selectedForm.state&&!matchMedia('(prefers-reduced-motion: reduce)').matches;
   let leave=null;if(transition){leave=canvas.animate([{opacity:1,transform:'translateY(0)'},{opacity:.28,transform:'translateY(9px)'}],{duration:120,easing:'ease-in',fill:'forwards'});await finishTransition(leave);}
   const old=model;releaseFullBody?.();releaseFullBody=nextRelease;Object.assign(config,nextConfig);model=next;core=next.internalModel.coreModel;pixelHit=window.PetPixelHit.create(next);originalWidth=next.width;originalHeight=next.height;
   fit=Math.min(312/originalWidth,440/originalHeight);breathPeriod=Number(config.selectedForm.breath_period_seconds);breathEpoch=performance.now();headTarget=null;headValue=0;headDriver=window.PetHeadMotion.create(config.selectedForm.appearance,config.selectedForm.state);overrides.clear();bodyDriver=config.selectedForm.body_motion?window.PetBodyMotion.create(config.selectedForm.body_motion):null;bodyValues=null;
   if(!Number.isFinite(breathPeriod)||breathPeriod<2||breathPeriod>10)throw Error('Invalid model cadence');
   next.anchor.set(.5,1);next.position.set(210,618);next.alpha=1;
   app.stage.removeChild(old);app.stage.addChild(next);attachModelDriver(next);updateControls(control);updateFormControls();
   noticeHeader.setIdentity((config.selectedForm.appearance==='chibi'?'Q 版':'非 Q 版')+' · '+config.selectedForm.label.replace(' · 局部呼吸',''));
   // Pixi caches textures by URL. Keep only textures shared by the next model.
   const retired=old.textures.filter(texture=>!next.textures.includes(texture));
   old.destroy({children:true});for(const texture of new Set(retired))texture.destroy(true);
   scene.layout(roleBounds(),config.selectedForm.appearance);swaps.completed++;app.renderer.render(app.stage);
   if(transition){const enter=canvas.animate([{opacity:.28,transform:'translateY(9px)'},{opacity:1,transform:'translateY(0)'}],{duration:180,easing:'cubic-bezier(.18,.78,.25,1.05)',fill:'forwards'});leave.cancel();await finishTransition(enter);}
   window.petHost.ready();
  }
  let replacement=null;window.petHost.onModel(()=>{if(replacement)return;replacement=replaceModel().catch(error=>window.petHost.modelError(error.message)).finally(()=>replacement=null);});
  function signature(values){let hash=2166136261;for(const value of values){hash=Math.imul(hash^Math.round(value*100000),16777619);}return hash>>>0;}
  function vertices(){const values=[];for(const p of core._model.drawables.vertexPositions)for(const n of p)values.push(n);return values;}
  function resources(){const textures=app.renderer.texture.managedTextures;return {managed_textures:textures.length,texture_rgba_bytes:textures.reduce((n,t)=>n+t.width*t.height*4,0),model_swaps:swaps.completed,shared_ticker_listeners:PIXI.Ticker.shared.count,input_held:inputHeld};}
  window.petDiagnostics={
    resources,
    fullBodyMotion:()=>({enabled:Boolean(config.selectedForm.full_body_motion),policy:config.selectedForm.full_body_motion?.policy||null,parameters:Object.fromEntries(core._model.parameters.ids.map((id,i)=>[id,appliedParameters[i]]))}),
    bubbleUI:()=>scene.snapshot(),
    openBubble:page=>scene.show(page),toggleBubble:page=>scene.toggle(page),bubbleHit:(x,y)=>scene.hit(x,y),updateBubbleTasks:value=>scene.updateTask(value),
    notice:()=>noticeHeader.snapshot(),
    resetBodyMotion:()=>{bodyDriver=config.selectedForm.body_motion?window.PetBodyMotion.create(config.selectedForm.body_motion):null;bodyValues=null;},
    formPicker:()=>formPicker.snapshot(),
    characterHit:(x,y)=>characterHit(x,y),
    hitMetrics:()=>pixelHit.metrics(),
    interactionHealth:()=>({clicks:inputHealth.clicks,last_click:inputHealth.last_click,last_click_age_ms:inputHealth.last_click_ms===null?null:performance.now()-inputHealth.last_click_ms,native_hit:nativeHit,cursor:{...cursor},visibility:document.visibilityState,focused:document.hasFocus(),frame_age_ms:frameHealth.snapshot().last_ms===null?null:performance.now()-frameHealth.snapshot().last_ms,rendered_frames:renderedFrames,last_render_age_ms:lastRenderMs===null?null:performance.now()-lastRenderMs,context_lost:Boolean(app.renderer.gl?.isContextLost()),recent_fps:frameHealth.snapshot().recent_gaps_ms.length>=10?1000*frameHealth.snapshot().recent_gaps_ms.length/frameHealth.snapshot().recent_gaps_ms.reduce((a,b)=>a+b,0):null,...frameHealth.snapshot(),hit_metrics:pixelHit.metrics(),resources:resources()}),
    hitSamples:points=>{return points.map(({x,y})=>({x,y,hit:alphaAt(x,y)}));},
    interactionLayout:()=>({native_hit:nativeHit,cursor:{...cursor},speech:{visible:!speech.hidden,x:speech.getBoundingClientRect().x,y:speech.getBoundingClientRect().y,width:speech.offsetWidth,height:speech.offsetHeight},model:{...roleBounds()}}),
    swapProbe:()=>({...swaps,model_id:config.selectedForm.id,visible_models:app.stage.children.filter(child=>child.visible&&child.alpha>0).length}),
    controlLayout:()=>{const box=element=>{const r=element.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height,right:r.right,bottom:r.bottom};};const b=roleBounds();return {model_id:config.selectedForm.id,zoom_scale:displayedScale,zoom_target:control.scale,expanded:!controlBody.hidden,aria_expanded:controlToggle.getAttribute('aria-expanded'),ui_scale:Number(getComputedStyle(document.documentElement).getPropertyValue('--controls-scale')),viewport:{width:innerWidth,height:innerHeight},dock:box(dock),model_box:{x:b.x,y:b.y,width:b.width,height:b.height},buttons:[...dock.querySelectorAll('button,select')].filter(e=>e.getClientRects().length).map(e=>({id:e.id,...box(e)})),footer_count:document.querySelectorAll('footer').length};},
 coreInfo:()=>({canvas:{Width:core._model.canvasinfo.CanvasWidth,Height:core._model.canvasinfo.CanvasHeight,PixelsPerUnit:core._model.canvasinfo.PixelsPerUnit},drawable_ids:[...core._model.drawables.ids],vertex_counts:[...core._model.drawables.vertexCounts],vertices:core._model.drawables.vertexPositions.map(a=>Array.from(a)),parameters:[...core._model.parameters.ids].map((id,i)=>({id,min:core._model.parameters.minimumValues[i],max:core._model.parameters.maximumValues[i],default:core._model.parameters.defaultValues[i]}))}),
 headTarget:value=>{headTarget=value;},resetHeadMotion:()=>{headTarget=null;headValue=0;headDriver=window.PetHeadMotion.create(config.selectedForm.appearance,config.selectedForm.state);},indices:()=>core._model.drawables.indices.map(a=>Array.from(a)),vertices:()=>core._model.drawables.vertexPositions.map(a=>Array.from(a)),override:(id,value)=>overrides.set(id,value),clearOverrides:()=>overrides.clear(),
    record:ms=>new Promise((resolve,reject)=>{
      const stream=canvas.captureStream(30),chunks=[];
      const recorder=new MediaRecorder(stream,{mimeType:'video/webm;codecs=vp9',videoBitsPerSecond:1200000});
      recorder.ondataavailable=event=>{if(event.data.size)chunks.push(event.data);};
      recorder.onerror=event=>{stream.getTracks().forEach(t=>t.stop());reject(event.error||new Error('Recording failed'));};
      recorder.onstop=async()=>{try{stream.getTracks().forEach(t=>t.stop());const bytes=await new Blob(chunks,{type:'video/webm'}).arrayBuffer();resolve(await window.petHost.recording(bytes));}catch(error){reject(error);}};
      recorder.start();setTimeout(()=>recorder.stop(),ms);
    }),
    snapshot:()=>({task:scene.taskSnapshot(),notice:noticeHeader.snapshot(),model_id:config.selectedForm.id,transition_active:false,visible_models:app.stage.children.filter(child=>child.visible&&child.alpha>0).length,continuous_canvas:true,body_motion_supported:Boolean(bodyDriver),body_driver:bodyDriver?bodyDriver.snapshot():null,body_values:bodyValues?{...bodyValues}:null,head_motion_supported:!!config.selectedForm.head_motion,driven_head_value:config.selectedForm.head_motion?headValue:null,head_driver:config.selectedForm.head_motion?headDriver.snapshot():null,breath_period_seconds:breathPeriod,driven_breath_value:drivenBreathValue,tap_count:tapCount,tap_breath_active:tapStarted!==null,renderer:app.renderer.type===PIXI.RENDERER_TYPE.WEBGL?'WebGL':'Canvas',drawables:core._model.drawables.count,frame_count:frames,elapsed_seconds:(performance.now()-started)/1000,average_fps:frames/((performance.now()-started)/1000),scale:model.scale.x,submitted_parameter_values:[...appliedParameters],parameter_signature:signature(appliedParameters),vertex_signature:signature(vertices()),angle_x:submitted.angle_x,eye_open_left:submitted.eye_open_left,focus_x:model.internalModel.focusController.x,errors:[...errors],motion_groups:config.modelSummary.motion_groups}),
    focus:(x,y)=>model.internalModel.focusController.focus(x,y,true),
    tap:()=>model.motion(config.modelSummary.motion_groups.includes('TapBody')?'TapBody':config.modelSummary.motion_groups[0],0,3),
    background:mode=>{document.body.style.background=mode==='light'?'#f3f2ed':mode==='dark'?'#19262f':'transparent';}
  };
  function readLongGapContext(){return {at_utc:new Date().toISOString(),state_at_resume:{visibility:document.visibilityState,focused:document.hasFocus(),ticker_running:app.ticker.started,fullscreen_suspended:Boolean(control.fullscreen_suspended),tray_minimized:Boolean(control.tray_minimized)}};}
  app.ticker.add(()=>{frames++;const now=performance.now();frameHealth.frame({nowMs:now,readContext:readLongGapContext});const visible=app.stage.children.filter(child=>child.visible&&child.alpha>0).length;swaps.observed_frames++;swaps.min_visible_models=Math.min(swaps.min_visible_models,visible);swaps.max_visible_models=Math.max(swaps.max_visible_models,visible);if(visible>1)swaps.overlap_frames++;if(visible===0)swaps.empty_frames++;});
  app.renderer.render(app.stage);
  window.petHost.ready();
}
start().catch(error=>window.petHost.error(error.stack||error.message));
