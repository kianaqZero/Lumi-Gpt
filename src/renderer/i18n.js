(function(root){'use strict';
 function translator(catalog,getLocale){
  const entries=catalog.entries,keys=Object.keys(entries).sort((a,b)=>b.length-a.length);
  const parts=new RegExp(keys.map(s=>s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')).join('|'),'g');
  return function translate(value){const locale=getLocale();if(typeof value!=='string'||locale==='zh')return value;
   const edge=value.match(/^(\s*)([\s\S]*?)(\s*)$/),s=edge[2];
   if(entries[s])return edge[1]+entries[s][locale]+edge[3];
   for(const p of catalog.patterns){const re=new RegExp(p.pattern);if(re.test(s))return edge[1]+s.replace(re,p[locale])+edge[3];}
   return value.replace(parts,key=>entries[key][locale]);
  };
 }
 root.LumiI18n={translator,create({catalog,locale='zh',host,dock,controlBody}){
  let language=Object.hasOwn(catalog.languages,locale)?locale:'zh';
  const t=translator(catalog,()=>language),originals=new WeakMap();
  const skip=e=>e?.closest('[data-lumi-content],#bk-task-list .bk-task p,#bk-task-list .bk-task b,#bk-cards-account');
  function translateNode(node){if(skip(node.parentElement))return;const current=node.nodeValue;let state=originals.get(node);if(!state||current!==state.rendered)state={source:current};const output=t(state.source);state.rendered=output;originals.set(node,state);if(current!==output)node.nodeValue=output;}
  const attrOriginals=new WeakMap();function attributes(e){if(skip(e))return;let record=attrOriginals.get(e)||{};for(const key of ['title','aria-label','placeholder']){const current=e.getAttribute(key);if(current===null)continue;let state=record[key];if(!state||current!==state.rendered)state={source:current};const output=t(state.source);state.rendered=output;record[key]=state;if(output!==current)e.setAttribute(key,output);}attrOriginals.set(e,record);}
  function render(subtree=dock){const walker=document.createTreeWalker(subtree,NodeFilter.SHOW_TEXT);let n;while((n=walker.nextNode()))translateNode(n);if(subtree.nodeType===1)attributes(subtree);subtree.querySelectorAll?.('*').forEach(attributes);document.documentElement.lang={zh:'zh-CN',en:'en',ja:'ja',ko:'ko'}[language];}
  const row=document.createElement('label');row.className='lumi-language-row';const title=document.createElement('span');title.textContent='语言';const select=document.createElement('select');select.id='lumi-language';select.setAttribute('aria-label','语言');for(const [value,label]of Object.entries(catalog.languages)){const option=document.createElement('option');option.value=value;option.textContent=label;option.setAttribute('data-lumi-content','');select.append(option);}select.value=language;row.append(title,select);controlBody.append(row);
  async function setLocale(next,persist=true){if(!Object.hasOwn(catalog.languages,next))throw Error('Unsupported locale');if(persist)await host.setLanguage(next);language=next;select.value=next;render();root.dispatchEvent(new CustomEvent('lumi-language-changed',{detail:next}));return next;}
  select.onchange=()=>{select.disabled=true;setLocale(select.value).catch(()=>{select.value=language;}).finally(()=>{select.disabled=false;});};
  const observer=new MutationObserver(()=>render());observer.observe(dock,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['title','aria-label','placeholder']});render();
  return {t,setLocale,render,get locale(){return language;},destroy(){observer.disconnect();}};
 }};
})(window);
