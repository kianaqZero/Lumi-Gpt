(function(root){
 'use strict';
 const idle='ANCHORED_BODY_IDLE_R1',greeting='ANCHORED_BODY_GREETING_R1',working='ANCHORED_BODY_WORKING_R1',thinking='ANCHORED_BODY_THINKING_R1',lengths=[13,21,17,26],directions=[1,-1,-1,1],ease=t=>{t=Math.max(0,Math.min(1,t));return t*t*(3-2*t);};
 function create(meta){
  if(!meta||![idle,greeting,working,thinking].includes(meta.policy)||meta.parameter_z!=='ParamBodyAngleZ'||meta.parameter_y!=='ParamBodyAngleY'||!Number.isFinite(meta.amplitude_z)||meta.amplitude_z<2||meta.amplitude_z>5)throw Error('Unverified anchored body motion');
  let last=null,elapsed=0,z=0,y=0,cycle=0;
  return Object.freeze({step(now,breath,head=0){if(!Number.isFinite(now)||!Number.isFinite(breath)||breath<0||breath>1||!Number.isFinite(head))throw Error('Invalid body motion clock/breath/head');const dt=last===null?0:Math.max(0,Math.min(80,now-last>300?0:now-last));last=now;elapsed+=dt/1000;
   if(meta.policy===greeting||meta.policy===working||meta.policy===thinking){const divisor=meta.policy===thinking?(meta.appearance==='chibi'?24:26):meta.policy===working&&meta.appearance==='chibi'?14:27;const desired=Math.max(-1,Math.min(1,head/divisor))*meta.amplitude_z*ease(elapsed/1.5);z+=(desired-z)*(1-Math.exp(-dt/(meta.policy===thinking?480:meta.policy===working?420:320)));cycle=Math.floor(elapsed/(meta.policy===thinking?9:meta.policy===working?8:6));}
   else{let t=elapsed,index=0;const total=lengths.reduce((a,b)=>a+b,0);cycle=Math.floor(t/total)*lengths.length;t%=total;while(t>=lengths[index]){t-=lengths[index];cycle++;index++;}const p=t/lengths[index],weight=p<.10?0:p<.32?ease((p-.10)/.22):p<.43?1:p<.73?1-ease((p-.43)/.30):0;z=directions[index]*meta.amplitude_z*weight;}
   const desiredY=(-2.2*breath+.4*(1-breath))*ease(elapsed/3);y+=(desiredY-y)*(1-Math.exp(-dt/180));return {z,y};
  },snapshot(){return {policy:meta.policy,z,y,elapsed_seconds:elapsed,cycle};}});
 }
 root.PetBodyMotion=Object.freeze({id:idle,greetingId:greeting,workingId:working,thinkingId:thinking,create});if(typeof module==='object'&&module.exports)module.exports=root.PetBodyMotion;
})(typeof window==='object'?window:globalThis);
