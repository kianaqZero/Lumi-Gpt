'use strict';
const fs=require('node:fs'),path=require('node:path'),api=require('./tibo-feed.cjs'),verify=require('./tibo-verify.cjs'),siteApi=require('./tibo-site.cjs');
const args=Object.fromEntries(process.argv.slice(2).map(s=>{const i=s.indexOf('=');return i<0?[s.slice(2),true]:[s.slice(2,i),s.slice(i+1)];}));
if(typeof args.output!=='string'||typeof args.state!=='string')throw Error('Explicit owned state/output required');
const read=file=>JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));
function primaryRequest(mode,value=''){return new Promise((resolve,reject)=>{const ps=path.join(process.env.SystemRoot||'C:/Windows','System32/WindowsPowerShell/v1.0/powershell.exe');require('node:child_process').execFile(ps,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',path.join(__dirname,'Tibo.PublicRequest.ps1'),'-Mode',mode,...(value?['-Value',value]:[])],{windowsHide:true,timeout:5500,maxBuffer:1200000,encoding:'utf8'},(error,output)=>{if(error)return reject(Error('PUBLIC_REQUEST_UNAVAILABLE'));try{const r=JSON.parse(output.replace(/^\uFEFF/,''));resolve(r);}catch{reject(Error('PUBLIC_REQUEST_UNAVAILABLE'));}});});}
async function checkPrimary(raw,feed,previous,now){
 const proofs={},fixture=args['primary-fixture']?read(args['primary-fixture']):null,candidates=feed.posts.filter(p=>p.kind||verify.completionCandidate(p.text)),latest=candidates.at(-1);if(!latest)return proofs;
 const cached=previous?.latest;if(cached?.id===latest.id&&cached.verification?.status==='primary_confirmed'&&api.safeUrl(cached.verification.official_url,latest.id)&&verify.clean(cached.verification.official_text)===verify.clean(latest.text)&&(!verify.completionCandidate(latest.text)||cached.verification.completion_context_verified===true)){proofs[latest.id]=cached.verification;return proofs;}
 if(args.fixture&&!fixture){proofs[latest.id]={status:'fixture_unverified'};return proofs;}
 async function original(id){let payload;if(fixture)payload=fixture.posts[id];else{const r=await primaryRequest('Original',id);if(r.status!==200)throw Error('PRIMARY_UNAVAILABLE');payload=JSON.parse(r.body);}return verify.primaryPost(payload,id);}
 try{
  const post=await original(latest.id);let context=null;
  if(latest.context){context=await original(latest.context.id);if(verify.clean(context.text)!==verify.clean(latest.context.text))throw Error('PRIMARY_CONTEXT_MISMATCH');}
  if(verify.completionCandidate(post.text)){
   const short=post.text.match(/https:\/\/t\.co\/[a-zA-Z0-9]+/);if(!short)throw Error('COMPLETION_CONTEXT_MISSING');let target;if(fixture)target=fixture.redirects[short[0]];else{const r=await primaryRequest('ShortLink',short[0]);if(![301,302,303,307,308].includes(r.status))throw Error('COMPLETION_CONTEXT_UNAVAILABLE');target=r.headers.location;}
   const id=typeof target==='string'?target.match(/\/status\/(\d{15,22})/)?.[1]:null,url=api.safeUrl(target,id),prior=feed.posts.find(p=>p.id===id);if(!url||!prior||Date.parse(latest.at)-Date.parse(prior.at)>86400000||Date.parse(prior.at)>Date.parse(latest.at))throw Error('COMPLETION_CONTEXT_MISMATCH');context=await original(id);if(!/\bglobal reset\b/i.test(context.text))throw Error('COMPLETION_CONTEXT_NOT_GLOBAL');
  }
  proofs[latest.id]=verify.confirmation(post,latest,context,now);
 }catch(error){proofs[latest.id]={reason:/^[A-Z_0-9]+$/.test(error.message)?error.message:"PRIMARY_PARSE_FAILED",status:'primary_unavailable',checked_at:new Date(now).toISOString(),all_accounts:null,all_quota_windows:null};}
 return proofs;
}
(async()=>{let result;const now=args.now?Date.parse(args.now):Date.now();let previous=null;try{previous=read(args.state);}catch{}
 try{
  if(!Number.isFinite(now))throw Error('INVALID_CLOCK');
  let retryAt=now+60000;
  async function request(mode){const r=await primaryRequest(mode);if(r.status===429){let delay=Number(r.headers?.retry_after);if(!Number.isFinite(delay)||delay<=0)delay=(Date.parse(r.headers?.retry_after)-now)/1000;retryAt=Math.max(retryAt,now+Math.max(60,Number.isFinite(delay)?delay:300)*1000);}if(r.status!==200)throw Error('PUBLIC_REQUEST_UNAVAILABLE');return JSON.parse(r.body);}
  const fixture=Boolean(args.fixture),skipped=Date.parse(previous?.site?.next_allowed_at)>now;
  const extraPromise=fixture?Promise.resolve({forecast:args['forecast-fixture']?read(args['forecast-fixture']):null,timeline:args['timeline-fixture']?read(args['timeline-fixture']):null}):skipped?Promise.resolve(null):Promise.allSettled([request('Forecast'),request('Timeline')]).then(rows=>({forecast:rows[0].status==='fulfilled'?rows[0].value:null,timeline:rows[1].status==='fulfilled'?rows[1].value:null}));
  let change,proofs={},feedError=null;
  try{const raw=fixture?read(args.fixture):await request('Feed'),first=api.normalize(raw,now);proofs=await checkPrimary(raw,first,previous,now);change=api.reduce(previous,api.normalize(raw,now,proofs),{bootstrap:Boolean(args.bootstrap),now});}
  catch(e){feedError=/^[A-Z_0-9]+$/.test(e.message)?e.message:'INVALID_SOURCE';change={state:previous?.version===1&&previous.handle===api.HANDLE?{...previous}:{version:1,handle:api.HANDLE,enabled:true,anchor:new Date(now).toISOString(),seen:[],classified:[],history:[],latest:null,latest_public:null},notices:[],baseline:Boolean(args.bootstrap)};}
  const inputs=await extraPromise;
  const extra=inputs?siteApi.reduce(previous?.site,{...inputs,next_allowed_at:new Date(retryAt).toISOString()},{bootstrap:Boolean(args.bootstrap),now}):{site:previous.site,notices:[]};
  if(feedError&&extra.site.forecast_error&&extra.site.timeline_error)result={ok:false,error:feedError,next_allowed_at:new Date(retryAt).toISOString()};
  else{change=siteApi.merge(change,extra,now);change.state.checked_at=new Date(now).toISOString();change.state.feed_error=feedError;result={ok:true,...change,primary_checks:proofs,next_allowed_at:new Date(retryAt).toISOString()};}
 }catch(error){result={ok:false,error:/^[A-Z_0-9]+$/.test(error.message)?error.message:'INVALID_SOURCE'};}
 const destination=path.resolve(args.output);fs.mkdirSync(path.dirname(destination),{recursive:true});const tmp=destination+'.tmp';fs.writeFileSync(tmp,JSON.stringify(result));fs.renameSync(tmp,destination);
})().catch(error=>{process.stderr.write(error.name+'\n');process.exitCode=1;});
