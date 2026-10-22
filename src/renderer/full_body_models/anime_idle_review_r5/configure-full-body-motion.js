'use strict';
(function(root){
 async function configure(model){
  const internal=model.internalModel,manager=internal.motionManager;
  internal.breath=undefined;internal.eyeBlink=undefined;
  const prepare=(group,index,motion)=>{if(group==='Idle'&&motion){motion.setIsLoop(true);motion.setIsLoopFadeIn(false);motion.setFadeInTime(0);motion.setFadeOutTime(0);}};
  manager.on('motionLoaded',prepare);
  const idle=await manager.loadMotion('Idle',0);
  if(!idle)throw new Error('Full-body Idle motion could not be loaded');
  prepare('Idle',0,idle);
  return ()=>manager.off('motionLoaded',prepare);
 }
 const api={configure};if(typeof module==='object'&&module.exports)module.exports=api;else root.PetFullBodyMotionConfig=api;
})(typeof window==='object'?window:globalThis);
