'use strict';
(function(root){
  function create({thresholdMs=1000,capacity=20}={}) {
    if(!Number.isFinite(thresholdMs)||thresholdMs<0||!Number.isInteger(capacity)||capacity<1)throw new Error('Invalid long-gap health options');
    let lastMs=null,maxGapMs=0,maxGapAtUtc=null;
    const gaps=[],events=[];
    function frame({nowMs,readContext}) {
      if(!Number.isFinite(nowMs)||typeof readContext!=='function')throw new Error('Invalid frame observation');
      let gap=null;
      if(lastMs!==null){
        gap=Math.max(0,nowMs-lastMs);
        gaps.push(gap);if(gaps.length>120)gaps.shift();
        if(gap>=thresholdMs){
          const context=readContext();
          if(!context||typeof context.at_utc!=='string')throw new Error('Invalid long-gap context');
          if(gap>maxGapMs){maxGapMs=gap;maxGapAtUtc=context.at_utc;}
          events.push({at_utc:context.at_utc,gap_ms:Math.round(gap*10)/10,state_at_resume:context.state_at_resume||{}});
          if(events.length>capacity)events.shift();
        }else if(gap>maxGapMs){maxGapMs=gap;}
      }
      lastMs=nowMs;
      return gap;
    }
    function snapshot(){return {last_ms:lastMs,recent_gaps_ms:[...gaps],max_gap_ms:maxGapMs,max_gap_at_utc:maxGapAtUtc,long_gap_events:events.map(e=>({...e}))};}
    return {frame,snapshot};
  }
  root.PetLongGapHealth={create};
})(window);
