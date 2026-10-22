'use strict';
// Candidate for ordinary, unmasked, double-sided ArtMeshes. No framebuffer readback.
window.PetPixelHit={create(model){
 const internal=model.internalModel,draw=internal.coreModel._model.drawables;
 if(!Number.isInteger(draw.count)||draw.count<1||model.textures.length<1)throw Error('No verified ArtMeshes or textures');
 for(let i=0;i<draw.count;i++){
  if(draw.masks[i]?.length||draw.constantFlags[i]&3||!(draw.constantFlags[i]&4))throw Error('Hit candidate requires normal, double-sided ArtMeshes without masks');
  if(!Number.isInteger(draw.textureIndices[i])||!model.textures[draw.textureIndices[i]])throw Error('Invalid ArtMesh texture index');
 }
 const cache=new Map(),textures=model.textures.map(t=>{
  const base=t.baseTexture;if(cache.has(base))return cache.get(base);
  const width=base.width,height=base.height,canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;
  const ctx=canvas.getContext('2d',{willReadFrequently:true});ctx.drawImage(base.resource.source,0,0,width,height);
  const rgba=ctx.getImageData(0,0,width,height).data,alpha=new Uint8Array(width*height);
  for(let i=0;i<alpha.length;i++)alpha[i]=rgba[i*4+3];
  // The hit map retains only alpha. Release the temporary RGBA backing store now.
  canvas.width=0;canvas.height=0;
  const info={width,height,alpha};cache.set(base,info);return info;
 });
 const point=new PIXI.Point(),local=new PIXI.Point(),cv=internal.coreModel._model.canvasinfo,ppu=cv.PixelsPerUnit;
 const at=(t,x,y)=>t.alpha[Math.max(0,Math.min(t.height-1,y))*t.width+Math.max(0,Math.min(t.width-1,x))];
 function sample(t,u,v){const x=u*t.width-.5,y=(1-v)*t.height-.5,x0=Math.floor(x),y0=Math.floor(y),fx=x-x0,fy=y-y0;return ((at(t,x0,y0)*(1-fx)+at(t,x0+1,y0)*fx)*(1-fy)+(at(t,x0,y0+1)*(1-fx)+at(t,x0+1,y0+1)*fx)*fy)/255;}
 let calls=0,totalMs=0,maxMs=0;
 return {hit(x,y){const started=performance.now();calls++;try{
  if(x<0||y<0||x>=innerWidth||y>=innerHeight||model.worldAlpha<=0)return false;
  point.set(x,y);model.toModelPosition(point,local);const px=(local.x-cv.CanvasWidth/2)/ppu,py=-(local.y-cv.CanvasHeight/2)/ppu;let alpha=0;
  for(let i=0;i<draw.count;i++){
   if(draw.opacities[i]<=0)continue;const positions=draw.vertexPositions[i],uv=draw.vertexUvs[i],indices=draw.indices[i],texture=textures[draw.textureIndices[i]];
   let minX=Infinity,minY=Infinity,maxX=-Infinity,maxY=-Infinity;for(let j=0;j<positions.length;j+=2){minX=Math.min(minX,positions[j]);maxX=Math.max(maxX,positions[j]);minY=Math.min(minY,positions[j+1]);maxY=Math.max(maxY,positions[j+1]);}if(px<minX||px>maxX||py<minY||py>maxY)continue;
   let drawableAlpha=0;
   for(let j=0;j<indices.length;j+=3){
    const a=indices[j]*2,b=indices[j+1]*2,c=indices[j+2]*2,ax=positions[a],ay=positions[a+1],bx=positions[b],by=positions[b+1],cx=positions[c],cy=positions[c+1];
    if(px<Math.min(ax,bx,cx)||px>Math.max(ax,bx,cx)||py<Math.min(ay,by,cy)||py>Math.max(ay,by,cy))continue;
    const denominator=(by-cy)*(ax-cx)+(cx-bx)*(ay-cy);if(Math.abs(denominator)<1e-12)continue;
    const wa=((by-cy)*(px-cx)+(cx-bx)*(py-cy))/denominator,wb=((cy-ay)*(px-cx)+(ax-cx)*(py-cy))/denominator,wc=1-wa-wb;
    if(wa>=-1e-6&&wb>=-1e-6&&wc>=-1e-6){drawableAlpha=sample(texture,wa*uv[a]+wb*uv[b]+wc*uv[c],wa*uv[a+1]+wb*uv[b+1]+wc*uv[c+1])*draw.opacities[i];break;}
   }
   alpha=1-(1-alpha)*(1-drawableAlpha*model.worldAlpha);if(alpha*255>=32)return true;
  }
  return false;
 }finally{const ms=performance.now()-started;totalMs+=ms;maxMs=Math.max(maxMs,ms);}},metrics:()=>({calls,total_ms:totalMs,max_ms:maxMs,alpha_bytes:[...cache.values()].reduce((s,t)=>s+t.alpha.byteLength,0),drawables:draw.count,textures:cache.size,triangles:draw.indices.reduce((s,a)=>s+a.length/3,0),gpu_readbacks:0,unsupported_masks_rejected:true})};
}};
