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
  // Native select popups depend on focus. Inline buttons also work in this
  // non-activating desktop window without changing foreground application.
  const row=document.createElement('section');row.className='lumi-language-row';
  const title=document.createElement('span');title.textContent='语言';
  const group=document.createElement('div');group.id='lumi-language';group.className='lumi-language-options';group.setAttribute('role','group');group.setAttribute('aria-label','语言');
  const feedback=document.createElement('span');feedback.id='lumi-language-feedback';feedback.setAttribute('role','status');feedback.setAttribute('aria-live','polite');feedback.setAttribute('data-lumi-content','');feedback.hidden=true;
  const failures={zh:'语言设置未保存，请重试。',en:'Language was not saved. Please try again.',ja:'言語設定を保存できませんでした。もう一度お試しください。',ko:'언어 설정을 저장하지 못했습니다. 다시 시도해 주세요.'};
  let pending=null;
  function reflect(){for(const button of group.children){button.setAttribute('aria-pressed',String(button.dataset.locale===language));button.disabled=Boolean(pending);}group.setAttribute('aria-busy',String(Boolean(pending)));}
  for(const [value,label]of Object.entries(catalog.languages)){const button=document.createElement('button');button.type='button';button.dataset.locale=value;button.textContent=label;button.setAttribute('data-lumi-content','');button.onclick=()=>{if(pending||value===language)return;setLocale(value).catch(()=>{});};group.append(button);}
  row.append(title,group,feedback);controlBody.append(row);reflect();
  function setLocale(next,persist=true){
   if(!Object.hasOwn(catalog.languages,next))return Promise.reject(Error('Unsupported locale'));
   if(pending)return pending;
   feedback.hidden=true;
   pending=Promise.resolve().then(async()=>{if(persist){const saved=await host.setLanguage(next);if(saved!==next)throw Error('Language persistence not acknowledged');}language=next;render();root.dispatchEvent(new CustomEvent('lumi-language-changed',{detail:next}));return next;}).catch(error=>{feedback.textContent=failures[language];feedback.hidden=false;throw error;}).finally(()=>{pending=null;reflect();});
   reflect();return pending;
  }
  const observer=new MutationObserver(()=>render());observer.observe(dock,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['title','aria-label','placeholder']});render();
  return {t,setLocale,render,get locale(){return language;},destroy(){observer.disconnect();}};
 }};
})(window);
