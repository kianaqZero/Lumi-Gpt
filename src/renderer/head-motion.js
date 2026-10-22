(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  else root.PetHeadMotion=api;
})(typeof globalThis==='object'?globalThis:this,function(){
  'use strict';
  const ID='RELAXED_HEAD_IDLE_R1',REVISION='ANGER_POSE_COVERAGE_R1';
  const gestures=[
    {duration:10.2,rest:1.2,approach:1.5,hold:1.0,returnTime:2.0,angle:21},
    {duration:12.6,rest:2.0,approach:1.8,hold:.8,returnTime:2.2,angle:-18},
    {duration:11.4,rest:1.6,approach:1.6,hold:1.2,returnTime:2.1,angle:17},
    {duration:13.5,rest:2.4,approach:1.9,hold:.9,returnTime:2.3,angle:-20}
  ];
  const period=gestures.reduce((sum,g)=>sum+g.duration,0);
  const clamp=(value,min,max)=>Math.max(min,Math.min(max,value));
  const ease=t=>{t=clamp(t,0,1);return t*t*t*(10+t*(-15+6*t));};
  function profile(appearance){return appearance==='anime'?{amplitude:.86,time:1.07,pointer:14}:{amplitude:1,time:1,pointer:18};}
  function repeating(seconds,appearance,state){
    const greeting=state==='greeting',work=state==='working',thinking=state==='thinking',angry=state==='pout_angry';
    const durations=angry?[12.4,14.2]:thinking?[8.6,9.4]:greeting?(appearance==='anime'?[6.2,7]:[5.8,6.4]):work?[8,8.8]:[8.8,9.8];
    const total=durations[0]+durations[1],secondsSafe=Math.max(0,seconds),pair=Math.floor(secondsSafe/total),within=secondsSafe%total,odd=within>=durations[0],local=odd?within-durations[0]:within,cycle=pair*2+Number(odd);
    const rest=angry?(odd?2.6:1.1):greeting?.12:.8,approach=angry?.9:greeting?.85:1.2,hold=angry?1.35:greeting?.65:work?.85:1,returnTime=angry?2.3:greeting?1.3:1.6;
    const a=local-rest,b=a-approach,c=b-hold;
    let pose=0,phase='rest';
    if(a>=0&&b<0){pose=ease(a/approach);phase='approach';}
    else if(b>=0&&c<0){pose=1;phase='hold';}
    else if(c>=0&&c<returnTime){pose=1-ease(c/returnTime);phase='return';}
    const angle=angry?(appearance==='anime'?27:25):thinking?(appearance==='anime'?26:24):appearance==='anime'?(greeting?28:27):26;
    return {target:(odd?-1:1)*angle*pose,phase,gesture:cycle};
  }
  function ambient(seconds,appearance,state='idle'){
    if(state==='greeting'||state==='thinking'||state==='pout_angry'||appearance==='anime')return repeating(seconds,appearance,state);
    const p=profile(appearance),work=state==='working',time=Math.max(0,seconds)/(p.time*(work?1.25:1));
    let local=time%period,index=0;
    while(index<gestures.length-1&&local>=gestures[index].duration){local-=gestures[index].duration;index++;}
    const g=gestures[index],a=local-g.rest,b=a-g.approach,c=b-g.hold;
    let pose=0,phase='rest';
    if(a>=0&&b<0){pose=g.angle*ease(a/g.approach);phase='approach';}
    else if(b>=0&&c<0){pose=g.angle;phase='hold';}
    else if(c>=0&&c<g.returnTime){pose=g.angle*(1-ease(c/g.returnTime));phase='return';}
    const micro=.65*Math.sin(seconds*2*Math.PI/7.1)+.35*Math.sin(seconds*2*Math.PI/11.3);
    return {target:(pose+micro)*p.amplitude*(work?.65:1),phase,gesture:index};
  }
  function pointerTarget(x,y,bounds,canvas,face,appearance){
    if(![x,y,bounds.x,bounds.y,bounds.width,bounds.height,canvas.Width,canvas.Height,...face].every(Number.isFinite)||bounds.width<=0||bounds.height<=0||canvas.Width<=0||canvas.Height<=0)return null;
    const cx=bounds.x+(face[0]+face[1])/2/canvas.Width*bounds.width,cy=bounds.y+(face[2]+face[3])/2/canvas.Height*bounds.height;
    const width=(face[1]-face[0])/canvas.Width*bounds.width,height=(face[3]-face[2])/canvas.Height*bounds.height;
    const dx=x-cx,dy=y-cy,distance=Math.hypot(dx/Math.max(70,width*2.2),dy/Math.max(65,height*2));
    if(distance>=1.5)return null;
    const influence=1-ease((distance-.9)/.6),offset=Math.max(0,Math.abs(dx)-7)*Math.sign(dx);
    return profile(appearance).pointer*Math.tanh(offset/Math.max(45,width*.85))*influence;
  }
  function create(appearance,state='idle'){
    let value=0,velocity=0,last=null,epoch=null,weight=0,rememberedPointer=0,lastPointer=null,pointerChangedAt=-Infinity,lastState={value:0,target:0,phase:'rest',pointer_weight:0,velocity:0};
    const max=appearance==='anime'?28:state==='greeting'||state==='thinking'||state==='pout_angry'?27:23,maxSpeed=24,omega=6.5;
    return {
      step(now,pointer=null){
        if(!Number.isFinite(now))throw Error('Finite monotonic motion time required');
        if(epoch===null)epoch=now;
        const dt=last===null?0:clamp((now-last)/1000,0,.1);last=now;
        const idle=ambient((now-epoch)/1000,appearance,state),incoming=Number.isFinite(pointer);
        if(incoming&&(lastPointer===null||Math.abs(pointer-lastPointer)>.05)){lastPointer=pointer;pointerChangedAt=now;}
        if(!incoming)lastPointer=null;
        const active=incoming&&now-pointerChangedAt<=2400;
        if(active)rememberedPointer=clamp(pointer,-profile(appearance).pointer,profile(appearance).pointer);
        weight+=(Number(active)-weight)*(1-Math.exp(-dt/.38));
        const target=idle.target*(1-weight)+rememberedPointer*weight;
        const offset=value-target,coefficient=velocity+omega*offset,decay=Math.exp(-omega*dt);
        const next=target+(offset+coefficient*dt)*decay;
        velocity=clamp((velocity-omega*coefficient*dt)*decay,-maxSpeed,maxSpeed);
        value=clamp(value+clamp(next-value,-maxSpeed*dt,maxSpeed*dt),-max,max);
        lastState={value,target,phase:idle.phase,gesture:idle.gesture,pointer_weight:weight,pointer_fresh:active,velocity,behavior_state:state};
        return value;
      },
      snapshot:()=>({...lastState,policy:ID,revision:REVISION})
    };
  }
  return Object.freeze({id:ID,revision:REVISION,create,ambient,pointerTarget});
});
