(function(root){
 'use strict';
 root.PetFormPicker=function({dock,appearance,form}){
  const panel=document.getElementById('choice-panel'),list=document.getElementById('choice-options'),title=document.getElementById('choice-title'),pages=document.getElementById('choice-pages'),pageLabel=document.getElementById('choice-page');
  const triggers={appearance:document.getElementById('appearance-picker'),form:document.getElementById('form-picker')};
  let current=null,page=0;
  const source=()=>current==='appearance'?appearance:form;
  const label=option=>option.textContent.replace(' · 局部呼吸','').replace(' · 静态','');
  function close(){current=null;panel.hidden=true;for(const button of Object.values(triggers))button.setAttribute('aria-expanded','false');}
  function render(){
   const select=source(),options=Array.from(select.options),count=Math.ceil(options.length/4);
   page=Math.max(0,Math.min(count-1,page));title.textContent=current==='appearance'?'角色版本':'角色形态';list.replaceChildren();
   for(const option of options.slice(page*4,page*4+4)){
    const button=document.createElement('button');button.type='button';button.dataset.choice=option.value;button.setAttribute('role','option');button.setAttribute('aria-selected',String(option.value===select.value));button.disabled=option.disabled;button.textContent=label(option);button.title=label(option);
    button.addEventListener('click',()=>{const next=option.value,submit=select===form||select.value!==next;close();if(submit){select.value=next;select.dispatchEvent(new Event('change',{bubbles:true}));}});list.appendChild(button);
   }
   pages.hidden=count<=1;pageLabel.textContent=(page+1)+' / '+count;document.getElementById('choice-prev').disabled=page===0;document.getElementById('choice-next').disabled=page>=count-1;
  }
  function open(kind){if(current===kind){close();return;}close();current=kind;const select=source();page=Math.floor(Math.max(0,select.selectedIndex)/4);panel.hidden=false;triggers[kind].setAttribute('aria-expanded','true');render();}
  for(const kind of ['appearance','form'])triggers[kind].addEventListener('click',()=>open(kind));
  document.getElementById('choice-close').addEventListener('click',close);
  document.getElementById('choice-prev').addEventListener('click',()=>{page--;render();});document.getElementById('choice-next').addEventListener('click',()=>{page++;render();});
  panel.addEventListener('wheel',event=>{event.preventDefault();event.stopPropagation();if(current){page+=Math.sign(event.deltaY);render();}},{passive:false});
  document.addEventListener('pointerdown',event=>{if(current&&!panel.contains(event.target)&&!Object.values(triggers).includes(event.target))close();});
  window.addEventListener('keydown',event=>{if(event.key==='Escape')close();});
  return Object.freeze({close,sync(){close();triggers.appearance.textContent=(appearance.value==='chibi'?'Q 版':'非 Q 版')+' ▾';triggers.form.textContent=label(form.selectedOptions[0])+' ▾';},snapshot(){return {open:current,page,options:Array.from(list.querySelectorAll('[data-choice]')).map(button=>({value:button.dataset.choice,selected:button.getAttribute('aria-selected')==='true',disabled:button.disabled}))};}});
 };
})(window);
