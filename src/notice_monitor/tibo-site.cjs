'use strict';
const {safeUrl}=require('./tibo-feed.cjs');
const SOURCE='https://codex-reset.com/',MAX_AGE=15*60000;
const text=s=>typeof s==='string'?s.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u202a-\u202e\u2066-\u2069]/g,'').slice(0,1200):'';
function time(s,now){const n=typeof s==='string'?Date.parse(s):NaN;if(!Number.isFinite(n)||n>now+300000)throw Error('INVALID_SITE_TIME');return new Date(n).toISOString();}
function fresh(s,now){const at=time(s,now);if(now-Date.parse(at)>MAX_AGE)throw Error('STALE_SITE_DATA');return at;}
function forecast(raw,now){
 const at=fresh(raw?.updated_at,now),p=raw?.probabilities;
 if(!p||![p.rounded_24h,p.rounded_48h].every(n=>Number.isInteger(n)&&n>=0&&n<=100)||p.rounded_24h>p.rounded_48h||!['low','medium','high'].includes(raw.confidence))throw Error('INVALID_FORECAST');
 let signal=null;const a=raw.latest_alert;
 if(a?.kind==='watch'&&a.state==='active'&&a.corrected===false&&/^[0-9]{15,22}$/.test(a.id)&&safeUrl(a.url,a.id)){
  const at=time(a.source_at,now);let window=null;
  if(a.window){const start=time(a.window.start_at,now+172800000),end=time(a.window.end_at,now+172800000);if(Date.parse(end)<Date.parse(start)||Date.parse(end)-Date.parse(start)>172800000)throw Error('INVALID_SIGNAL_WINDOW');window={start_at:start,end_at:end};}
  if(now-Date.parse(at)<=86400000&&(!window||Date.parse(window.end_at)>now))signal={id:a.id,url:safeUrl(a.url,a.id),at,summary:text(a.localized_summary||a.summary),score:[83,93].includes(a.score)?a.score:null,pending:['done','on_its_way'].includes(a.pending)?a.pending:null,window};
 }
 return {updated_at:at,p24:p.rounded_24h,p48:p.rounded_48h,confidence:raw.confidence,last_reset_at:raw.last_reset_at?time(raw.last_reset_at,now):null,signal};
}
function timeline(raw,now){
 const updated_at=fresh(raw?.updated_at,now);if(!Array.isArray(raw.events)||raw.events.length>2000)throw Error('INVALID_TIMELINE');
 const seen=new Set(),events=[];
 for(const e of raw.events){
  if(e?.group!=='reset'||e.announcement_state!=='announced'||e.preview===true||e.confirmed===false||typeof e.id!=='string'||!/^[-_a-zA-Z0-9]{1,80}$/.test(e.id)||seen.has(e.id))continue;
  try{const at=time(e.announced_at,now);const url=safeUrl(e.url,e.id);events.push({id:e.id,at,url,summary:text(e.localized_summary||e.summary)});seen.add(e.id);}catch{}
 }
 events.sort((a,b)=>Date.parse(b.at)-Date.parse(a.at)||a.id.localeCompare(b.id));return {updated_at,events:events.slice(0,8)};
}
function reduce(previous,inputs,{now=Date.now(),bootstrap=false}={}){
 const prior=previous?.version===1?previous:null,site={version:1,source:SOURCE,checked_at:new Date(now).toISOString(),forecast:prior?.forecast||null,timeline:prior?.timeline||null,forecast_error:null,timeline_error:null,next_allowed_at:inputs.next_allowed_at||null,seen:Array.isArray(prior?.seen)?prior.seen.slice(-100):[],anchor:prior?.anchor||new Date(now).toISOString()};
 for(const [key,parse]of [['forecast',forecast],['timeline',timeline]]){
  try{if(!inputs[key])throw Error('SITE_UNAVAILABLE');site[key]=parse(inputs[key],now);}catch(e){site[key+'_error']=/^[A-Z_]+$/.test(e.message)?e.message:'INVALID_SITE_DATA';}
 }
 const seed=bootstrap||!prior,seen=new Set(site.seen),candidates=[];
 const last=site.timeline?.events?.[0];
 if(!site.timeline_error&&last?.url)candidates.push({id:last.id,url:last.url,at:last.at,kind:'completed',label:'社区记录称重置完成',message:'社区记录称新一轮重置已完成；你的账号额度仍待实测。数据：codex-reset.com',text:last.summary,notice_key:'site-reset:'+last.id,event_id:last.id,provider:'codex-reset.com',verification:{status:'community_recorded'}});
 const f=site.forecast,s=f?.signal;
 if(!site.forecast_error&&s&&(!last||Date.parse(s.at)>Date.parse(last.at)))candidates.push({id:s.id,url:s.url,at:s.at,kind:'planned',label:s.pending?'可能已完成重置（待核实）':'即将重置',message:s.pending?'Tibo 有重置进展，社区尚待确认实际完成。数据：codex-reset.com':'检测到新的明确重置预告，请查看时间与适用范围。数据：codex-reset.com',text:s.summary,notice_key:'site-watch:'+s.id,event_id:s.id,provider:'codex-reset.com',verification:{status:'community_signal'}});
 const notices=[];
 for(const n of candidates){if(!seed&&!seen.has(n.notice_key)&&Date.parse(n.at)>=Date.parse(site.anchor)&&now-Date.parse(n.at)<=86400000)notices.push(n);seen.add(n.notice_key);}
 site.seen=[...seen].slice(-100);return {site,notices};
}
function merge(change,extra,now){
 const last=extra.site.timeline?.events?.[0],same=last&&!extra.site.timeline_error;
 const filtered=change.notices.filter(n=>!(same&&Date.parse(n.at)<=Date.parse(last.at)&&['mentioned','planned','in_progress'].includes(n.kind)));
 const combined=new Map();for(const n of [...filtered,...extra.notices])combined.set(n.id+':'+n.kind,n);
 change.state.history=change.state.history.filter(n=>!change.notices.includes(n));
 const notices=[...combined.values()].slice(-3);
 change.state.history=[...change.state.history,...notices].slice(-50);change.state.site=extra.site;
 return {...change,notices};
}
module.exports={SOURCE,MAX_AGE,forecast,timeline,reduce,merge};
