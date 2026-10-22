const fs=require('node:fs');
const path=require('node:path');
function resolveLocalFile(root, requested){
  const name=decodeURIComponent(requested).replace(/^\/+/, '');
  if(!name || name.includes('\\') || name.includes('\0') || name.includes(':'))throw new Error('Invalid resource path');
  const base=fs.realpathSync(root),file=path.resolve(base,name);
  const rel=path.relative(base,file);
  if(rel==='..'||rel.startsWith('..'+path.sep)||path.isAbsolute(rel))throw new Error('Resource escapes model root');
  const actual=fs.realpathSync(file), actualRel=path.relative(base,actual);
  if(actualRel==='..'||actualRel.startsWith('..'+path.sep)||path.isAbsolute(actualRel))throw new Error('Resource link escapes model root');
  if(!fs.statSync(actual).isFile())throw new Error('Resource is not a file');
  return actual;
}
function validateModelBundle(modelFile){
  if(!modelFile.toLowerCase().endsWith('.model3.json'))throw new Error('Expected .model3.json');
  const root=path.dirname(modelFile),model=JSON.parse(fs.readFileSync(modelFile,'utf8').replace(/^\uFEFF/,''));
  const r=model.FileReferences;
  if(model.Version!==3||!r||typeof r.Moc!=='string'||!Array.isArray(r.Textures)||r.Textures.length===0)throw new Error('Invalid model file references');
  if([r.Moc,...r.Textures].some(x=>typeof x!=='string'||x.length===0))throw new Error('Required model resources must be nonempty file paths');
  const files=[path.basename(modelFile),r.Moc,...r.Textures,r.Physics,r.Pose,r.DisplayInfo,...(r.Expressions||[]).map(x=>x.File),...Object.values(r.Motions||{}).flatMap(g=>g.map(x=>x.File))].filter(Boolean);
  if(files.some(x=>typeof x!=='string'))throw new Error('Model resources must be local file paths');
  for(const file of files)resolveLocalFile(root,file);
  const moc=fs.readFileSync(resolveLocalFile(root,r.Moc));
  if(moc.subarray(0,4).toString()!=='MOC3')throw new Error('Not a Cubism MOC3 model');
  return {allowedFiles:[...new Set(files.map(f=>f.replaceAll('\\','/')))],summary:{model:path.basename(modelFile),textures:r.Textures.length,motion_groups:Object.keys(r.Motions||{}),expressions:(r.Expressions||[]).length,physics:Boolean(r.Physics),sounds_enabled:false}};
}
module.exports={resolveLocalFile,validateModelBundle};
