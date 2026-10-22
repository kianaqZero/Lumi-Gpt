const fs=require('fs'),path=require('path'),crypto=require('crypto');
exports.apply=function(registry){
 const root=path.resolve(__dirname,'head_models'),manifest=JSON.parse(fs.readFileSync(path.join(root,'MODEL_OVERRIDES.json'),'utf8'));
 if(manifest.schema!==1||manifest.models.length!==10)throw Error('Expected ten verified pose-specific head models');
 const seen=new Set();
 for(const m of manifest.models){
  const entry=registry.forms.find(f=>f.id===m.form_id);
  if(!entry||(!['idle','greeting','working','thinking','pout_angry'].includes(entry.state)||(m.state&&m.state!==entry.state))||!m.core_verified||seen.has(m.form_id))throw Error('Unverified head model override');seen.add(m.form_id);
  for(const f of m.required_files){const file=path.resolve(root,f.path);if(!file.startsWith(root+path.sep))throw Error('Head model resource outside candidate');if(crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')!==f.sha256)throw Error('Head model hash mismatch');}
  if(!m.required_files.some(f=>f.path===m.model3)||m.head_motion.parameter!=='ParamAngleZ'||m.head_motion.authored_parameter_range?.[0]!==-30||m.head_motion.authored_parameter_range?.[1]!==30||m.head_motion.runtime_policy!=='RELAXED_HEAD_IDLE_R1')throw Error('Invalid verified head metadata');
  entry.model3=m.model3;entry.runtime_model_root=root;entry.head_motion=m.head_motion;
 }
 return registry;
};
