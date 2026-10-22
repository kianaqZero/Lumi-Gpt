const fs=require('fs'),path=require('path'),crypto=require('crypto');
exports.apply=function(registry){
 const root=path.resolve(__dirname,'body_models'),m=JSON.parse(fs.readFileSync(path.join(root,'MODEL_OVERRIDES.json'),'utf8'));
 if(m.schema!==1||m.models.length!==8)throw Error('Expected eight verified anchored body models');const seen=new Set();
 for(const model of m.models){
  const entry=registry.forms.find(f=>f.id===model.form_id),body=model.body_motion;
  if(!entry||!['idle','greeting','working','thinking'].includes(entry.state)||!entry.head_motion||!model.core_verified||seen.has(entry.id)||!body||body.policy!==(entry.state==='thinking'?'ANCHORED_BODY_THINKING_R1':entry.state==='working'?'ANCHORED_BODY_WORKING_R1':entry.state==='greeting'?'ANCHORED_BODY_GREETING_R1':'ANCHORED_BODY_IDLE_R1')||body.parameter_z!=='ParamBodyAngleZ'||body.parameter_y!=='ParamBodyAngleY'||body.authored_range?.[0]!==-10||body.authored_range?.[1]!==10||body.independent_limb_rig!==false)throw Error('Unverified body-model metadata');seen.add(entry.id);
  for(const f of model.required_files){const file=path.resolve(root,f.path);if(!file.startsWith(root+path.sep)||crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')!==f.sha256)throw Error('Body model hash/path mismatch');}
  if(!model.required_files.some(f=>f.path===model.model3))throw Error('Missing verified body model3');entry.model3=model.model3;entry.runtime_model_root=root;entry.body_motion=body;
 }
 return registry;
};
