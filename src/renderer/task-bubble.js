(function(root){
 'use strict';
 const labels={active:'执行中',completed:'本轮回复结束',failed:'本轮出错',interrupted:'已中断',unavailable:'未连接',unknown:'状态待核对'};
 root.PetTaskBubble={create(dock){
  const card=document.createElement('section');card.className='task-card';card.hidden=true;card.setAttribute('aria-label','Codex任务状态');card.setAttribute('role','status');
  const head=document.createElement('div');head.className='task-head';const label=document.createElement('strong');label.className='task-label';head.appendChild(label);
  const toggle=document.createElement('button');toggle.type='button';toggle.id='tasks-toggle';toggle.setAttribute('aria-expanded','false');toggle.title='展开其他项目的任务';head.appendChild(toggle);
  const close=document.createElement('button');close.type='button';close.id='task-dismiss';close.textContent='×';close.title='关闭当前消息';head.appendChild(close);card.appendChild(head);
  const list=document.createElement('div');list.className='task-list';list.id='tasks-list';list.hidden=true;toggle.setAttribute('aria-controls',list.id);card.appendChild(list);
  const progress=document.createElement('div');progress.className='task-progress';card.appendChild(progress);dock.appendChild(card);
  const usage=document.createElement('div');usage.className='task-usage';usage.hidden=true;usage.title='Codex记录的本轮总token，包含输入（含缓存）和输出';card.appendChild(usage);
  let current=null,dismissed=null,expanded=false,selected=null,latestID=null,listSignature='';const dismissedNotifications=new Set();
  function shown(){return current?current.tasks.filter(t=>!current.notification_mode||!dismissedNotifications.has(t.notification_id)):[];}
  function key(){return current?(current.tasks[0]?.notification_id||(current.turn_id||'connection')+':'+current.status):null;}
  function render(){
   const available=shown();card.hidden=!current||current.notification_mode&&!available.length||!current.notification_mode&&dismissed===key();if(!current||card.hidden)return;
   const tasks=available.length?available:[current],focus=tasks.find(t=>t.thread_id===selected)||tasks[0];
   card.dataset.status=focus.status;label.textContent=focus.title+' · '+labels[focus.status];label.title=focus.title;
   progress.textContent=focus.progress;toggle.hidden=tasks.length<2;toggle.textContent=(expanded?'▴ ':'▾ ')+tasks.length;toggle.setAttribute('aria-expanded',String(expanded));list.hidden=!expanded;
   const signature=JSON.stringify(tasks.map(t=>[t.thread_id,t.title,t.status,focus.thread_id===t.thread_id]));
   if(signature!==listSignature){listSignature=signature;list.replaceChildren();for(const task of tasks){const button=document.createElement('button');button.type='button';button.dataset.threadId=task.thread_id;button.setAttribute('aria-pressed',String(task.thread_id===focus.thread_id));button.textContent=task.title+' · '+labels[task.status];button.title=task.project?task.project+' / '+task.title:task.title;button.addEventListener('click',()=>{selected=task.thread_id;render();});list.appendChild(button);}}
   const terminal=['completed','failed','interrupted'].includes(focus.status);usage.hidden=!terminal;
   usage.textContent=terminal&&Number.isSafeInteger(focus.usage?.total_tokens)&&focus.usage.total_tokens>=0?'本轮使用 '+focus.usage.total_tokens.toLocaleString('zh-CN')+' token':focus.usage_state==='reading'?'正在读取本轮 token…':'暂无用量数据';
  }
  function sanitize(s){return {status:Object.hasOwn(labels,s.status)?s.status:'unknown',thread_id:String(s.thread_id||''),turn_id:s.turn_id||null,notification_id:String(s.notification_id||''),title:String(s.title||'未命名对话').slice(0,80),progress:String(s.progress||'').slice(0,160),project:String(s.project||'').slice(0,48),usage:s.usage&&Number.isSafeInteger(s.usage.total_tokens)?{total_tokens:s.usage.total_tokens}:null,usage_state:s.usage_state==='reading'?'reading':null,waiting_supported:Boolean(s.waiting_supported)};}
  toggle.addEventListener('click',()=>{expanded=!expanded;render();});
  close.addEventListener('click',()=>{if(current?.notification_mode){const tasks=shown(),focus=tasks.find(t=>t.thread_id===selected)||tasks[0];if(focus) dismissedNotifications.add(focus.notification_id);if(dismissedNotifications.size>64)dismissedNotifications.delete(dismissedNotifications.values().next().value);selected=null;}else dismissed=key();render();});
  return {update(s){if(!s||!Object.hasOwn(labels,s.status)){current=null;render();return;}current={...sanitize(s),notification_mode:Boolean(s.notification_mode),tasks:Array.isArray(s.tasks)?s.tasks.slice(0,8).map(sanitize):[]};const nextID=current.tasks[0]?.notification_id;if(current.notification_mode&&nextID&&nextID!==latestID)selected=null;latestID=nextID;render();},snapshot(){return {visible:!card.hidden,source:current?{...current}:null,text:progress.textContent,label:label.textContent,expanded,selected,task_count:shown().length,usage_text:usage.hidden?null:usage.textContent};}};
 }};
})(window);
