(function(root){
 'use strict';
 root.PetNoticeHeader=function({dock,identity,button,showPanel,openSource,dismiss}){
  let base=identity.textContent,active=null,simulation=false;
  const labels={mentioned:'重置动态待核对',planned:'即将重置',completed:'重置完成',in_progress:'正在重置'};
  function render(){identity.textContent=active?(simulation?'演示 · ':active.local?'额度 · ':'Tibo · ')+(active.assessment==='suspected'?'疑似全球重置':active.kind==='completed'&&!simulation&&!active.primaryConfirmed?'完成待核对':labels[active.kind]):base;identity.title=active?active.message+' 点击提示文字可收起。':base;identity.style.cursor=active?'pointer':'';dock.classList.toggle('has-tibo-notice',Boolean(active));button.textContent=active&&!active.local?'原帖':'公告';button.title=active&&!active.local?'查看这条公告的 X 原帖':'额度重置公告与本机观测';}
  identity.addEventListener('click',()=>{if(active)dismiss();});button.addEventListener('click',()=>{if(active&&!active.local)openSource(active.id);else showPanel();});
  return Object.freeze({setIdentity(value){base=value;render();},update(notice,demo=false){simulation=Boolean(demo);const local=Boolean(notice&&/^local-reset-\d{10,13}$/.test(notice.id)&&notice.assessment==='suspected'&&notice.provider==='本机额度观测'&&notice.url==='');active=notice&&(local||/^\d{15,22}$/.test(notice.id))&&Object.hasOwn(labels,notice.kind)&&typeof notice.message==='string'?{id:notice.id,kind:notice.kind,message:notice.message.slice(0,240),primaryConfirmed:!local&&notice.verification?.status==='primary_confirmed',assessment:notice.assessment==='suspected'?'suspected':null,local}:null;render();},snapshot(){return {active:active?{...active}:null,simulation,base,label:identity.textContent};}});
 };
})(window);
