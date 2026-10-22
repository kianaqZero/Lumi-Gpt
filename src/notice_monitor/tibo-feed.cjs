'use strict';
const HANDLE='thsottiaux',PROVIDER='https://codex-reset.com/api/feed',SOURCE_LABEL='社区镜像 · codex-reset.com';
function resetTeaser(text){const t=String(text).replace(/\s+/g,' ').trim();return /\bday\s*\d+\s*\/\s*reset\b/i.test(t)&&/\b(?:my|the) reset button\b/i.test(t)&&!/\b(?:password|router|device|cache|project)\b/i.test(t);}
function landingReply(text){if(/^landing\s+(?:sometime\s+)?today\s+by\s+EOD\s+PST[.!\s]*$/i.test(String(text).trim()))return true;return /^landing\s+(?:within|in)\s+(?:the\s+)?next\s+\d+\s+(?:hours?|minutes?)\b[.!\s]*$/i.test(String(text).trim());}
function completionCandidate(text){const t=String(text).replace(/https?:\/\/\S+/g,'').replace(/[’‘]/g,"'").replace(/\s+/g,' ').trim();return /\breset\b/i.test(t)&&/[.?!]\s*(?:it's|it is|the reset is)\s+(?:now )?done\b/i.test(t)&&!(/\b(?:password|router|device|branch|cache|project|server|settings|not|isn't|haven't|hope|wish|might|if)\b/i.test(t))&&!/\b(?:could|can|would) you (?:please )?reset\b/i.test(t);}
function safeUrl(url,id){
 if(typeof id!=='string'||!/^\d{15,22}$/.test(id)||typeof url!=='string')return null;
 try{const u=new URL(url);if(u.protocol!=='https:'||u.username||u.password||u.port||!['x.com','twitter.com'].includes(u.hostname.toLowerCase())||u.pathname.toLowerCase()!=='/'+HANDLE+'/status/'+id)return null;return 'https://x.com/'+HANDLE+'/status/'+id;}catch{return null;}
}
function classify(text){
 if(typeof text!=='string')return null;const t=text.replace(/[’‘]/g,"'").replace(/\s+/g,' ').trim();
 if(/\b(?:don't|do not|won't|will not|not (?:going to |yet |fully |yet fully )?(?:reset|resetting|propagated|processed|complete(?:d)?)|no (?:global )?reset)\b/i.test(t)||/\b(?:can|could|would|should) (?:you|we|someone)\b[^.!]*\breset\b/i.test(t)||/\b(?:wish|hoping|hope|might|maybe|possibly|perhaps|if)\b[^.!]*\breset\b/i.test(t))return null;
 const related=/\b(?:codex|chatgpt|usage|rate limits?|quota|tokens?)\b/i.test(t)||/\bglobal reset\b/i.test(t)||/\breset\b[^.!]*\b(?:processed|propagated|in the bag)\b/i.test(t);
 const dayReset=/^day\s*\d+\s*\/[\s\S]*\b(?:limit reset|reset)\b/i.test(t)&&!/\b(?:password|router|device|cache|branch|server|settings)\b/i.test(t);
 if(completionCandidate(t))return 'completed';
 if((!related&&!dayReset)||!/\breset(?:s|ting)?\b/i.test(t))return null;
 if(/\b(?:have|has) (?:now |already |just )?(?:been )?reset\b/i.test(t)||/\b(?:we|i)'ve (?:now |already |just )?reset\b/i.test(t)||/\breset\b[^.!]*\b(?:has been |is now )?(?:processed|complete(?:d)?|fully propagated)\b/i.test(t)||/\breset\b[^.!]*\b(?:in the bag|all propagated)\b/i.test(t))return 'completed';
 if(/\b(?:we|i)(?: will|'ll| am going to| are going to) reset\b/i.test(t)||/\b(?:will be|going to be) reset\b/i.test(t)||/\bglobal reset\b[^.!]*\b(?:landing|coming|by |tomorrow|tonight|today|eod)\b/i.test(t)||/\breset\b[^.!]*\b(?:tomorrow|tonight|later today|next hour|by eod)\b/i.test(t))return 'planned';
 if(/\b(?:we are|we're|i am|i'm) resetting\b/i.test(t)||/\breset\b[^.!]*\b(?:rolling out|in progress|propagating)\b/i.test(t))return 'in_progress';
 return dayReset?'mentioned':null;
}
const labels={mentioned:'可能重置，结果待核对',planned:'即将重置',completed:'宣布重置完成',in_progress:'正在重置'};
const messages={mentioned:'Tibo 发布了重置相关动态；原文没有明确本账号是否已恢复，请查看额度实测。',planned:'Tibo 宣布即将重置额度，时间和适用范围请查看原帖。',completed:'Tibo 宣布额度重置已完成；你的账户状态仍以实际额度为准。',in_progress:'Tibo 称额度重置正在推进，完成情况请留意后续公告。'};
function normalize(raw,now=Date.now(),confirmations={}){
 if(!raw||raw.version!==1||raw.source_scope!=='timeline'||raw.profile?.handle?.toLowerCase()!==HANDLE||!Array.isArray(raw.tweets)||raw.tweets.length>200)throw Error('INVALID_SOURCE_IDENTITY');
 const fetched=Date.parse(raw.fetched_at);if(raw.stale!==false||!Number.isFinite(fetched)||fetched>now+300000||now-fetched>1800000)throw Error('STALE_SOURCE');
 const posts=[],ids=new Set();for(const row of raw.tweets){const url=safeUrl(row?.url,row?.id),at=Date.parse(row?.declared_at||row?.at);if(!url||ids.has(row.id)||typeof row.text!=='string'||row.text.length>10000||!Number.isFinite(at)||at>now+300000)continue;ids.add(row.id);
  const text=row.text.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u202a-\u202e\u2066-\u2069]/g,'').trim(),kind=classify(text)||(completionCandidate(text)?'completed':null)||(resetTeaser(text)?'planned':null);posts.push({id:row.id,url,text:text.slice(0,1500),at:new Date(at).toISOString(),kind,label:kind?labels[kind]:'其他公开动态',message:kind?messages[kind]:'',provider:SOURCE_LABEL,reply_to:/^\d{15,22}$/.test(row.in_reply_to_tweet_id||'')?row.in_reply_to_tweet_id:null,event_id:row.id});
 }
 posts.sort((a,b)=>Date.parse(a.at)-Date.parse(b.at)||((BigInt(a.id)>BigInt(b.id))?1:-1));
 for(const post of posts){if(!post.kind&&landingReply(post.text)&&post.reply_to){const parent=posts.find(p=>p.id===post.reply_to);if(parent&&['planned','mentioned'].includes(parent.kind)&&Date.parse(post.at)>=Date.parse(parent.at)&&Date.parse(post.at)-Date.parse(parent.at)<=21600000){post.kind='planned';post.label=labels.planned;post.message='Tibo 在本轮重置预告的回复中给出了落地时间；完成情况仍待核对。';post.context={id:parent.id,url:parent.url,text:parent.text};post.event_id=parent.event_id;}}}
 for(const post of posts){if(!post.kind&&/^done[.!\s]*$/i.test(post.text)&&post.reply_to){const parent=posts.find(p=>p.id===post.reply_to);if(parent&&['planned','mentioned','in_progress'].includes(parent.kind)&&Date.parse(post.at)>=Date.parse(parent.at)&&Date.parse(post.at)-Date.parse(parent.at)<=86400000){post.kind='completed';post.label=labels.completed;post.message='Tibo 在重置相关帖的回复中表示已完成；账号额度仍需实测。';post.context={id:parent.id,url:parent.url,text:parent.text};post.event_id=parent.event_id;}}}
 for(const post of posts){
  const proof=confirmations[post.id];if(proof){post.verification=proof;post.original_text=post.text;}
  if(proof?.status==='primary_confirmed'&&safeUrl(proof.official_url,post.id)&&(!completionCandidate(post.text)||proof.completion_context_verified===true)){
   if(post.kind){post.label=(post.kind==='completed'&&proof.global?'全球重置已完成':labels[post.kind])+' · 原帖已核对';post.message=post.kind==='completed'?'已核对 Tibo 原帖：'+(proof.global?'全球':'')+'重置已完成。':messages[post.kind];}
  }else if(post.kind==='completed'){post.label='完成消息待原帖核对';post.message='镜像转述重置完成，原帖及适用范围尚待核对。';}
 }
 return {handle:HANDLE,provider:SOURCE_LABEL,fetched_at:new Date(fetched).toISOString(),posts,latest_public:posts.at(-1)||null,latest:[...posts].reverse().find(p=>p.kind)||null};
}
function reduce(previous,feed,{bootstrap=false,now=Date.now()}={}){
 const valid=previous?.version===1&&previous.handle===HANDLE&&Array.isArray(previous.seen)&&Array.isArray(previous.history),seen=new Set(valid?previous.seen.filter(s=>typeof s==='string'&&/^\d{15,22}$/.test(s)):[]),history=valid?previous.history.slice(-50):[];
 const seed=bootstrap||!valid,anchor=valid&&Number.isFinite(Date.parse(previous.anchor))?previous.anchor:feed.fetched_at,newNotices=[];
 const priorKinds=valid&&Array.isArray(previous.classified)?new Set(previous.classified):new Set(valid?[previous.latest,...previous.history].filter(p=>p?.kind).map(p=>p.id):[]);
 for(const post of feed.posts){if(!seed&&(!seen.has(post.id)||!priorKinds.has(post.id))&&post.kind&&Date.parse(post.at)>=Date.parse(anchor)&&now-Date.parse(post.at)<=86400000)newNotices.push(post);seen.add(post.id);}
 // A parent teaser and its timing reply describe one event, not two alerts.
 const grouped=new Map();for(const post of newNotices)grouped.set(post.event_id||post.id,post);newNotices.splice(0,newNotices.length,...grouped.values());
 // First connection is a quiet baseline. Latest public notice remains available in the panel.
 const deliver=newNotices.slice(-3);for(const p of deliver)history.push(p);
 return {state:{version:1,handle:HANDLE,anchor,seen:[...seen].slice(-500),classified:[...new Set([...priorKinds,...feed.posts.filter(p=>p.kind).map(p=>p.id)])].slice(-500),history:history.slice(-50),latest:feed.latest,latest_public:feed.latest_public||null,source_coverage:'community_mirror_may_omit_posts',checked_at:new Date(now).toISOString(),source_checked_at:feed.fetched_at,enabled:previous?.enabled!==false},notices:deliver,baseline:seed};
}
module.exports={HANDLE,PROVIDER,SOURCE_LABEL,safeUrl,classify,completionCandidate,resetTeaser,landingReply,normalize,reduce,labels,messages};
