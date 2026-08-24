(function(){
'use strict';
var input,output,direction,submit,copy,cancel,retry,progress,status,count,limitNote,directionNote;
var ready=false,busy=false,currentJob='',timer=0,lastRequest=null,pending=false;
function el(id){return document.getElementById(id)}
function maxChars(){var n=document.querySelector('meta[name="yaku-max-batch-chars"]');return Math.max(1,Number(n&&n.content)||3000)}
function setStatus(message,kind){status.textContent=message||'';status.className=kind?'is-'+kind:''}
function update(){
 var text=input.value.trim(),len=text.length,tooLong=len>maxChars();
 count.textContent=len.toLocaleString('ja-JP')+'字';
 limitNote.textContent=tooLong?'1回で送れるのは '+maxChars().toLocaleString('ja-JP')+'字までです。':'';
 submit.disabled=!text||tooLong||busy;
 input.readOnly=busy;direction.disabled=busy;copy.disabled=!output.value;
 if(direction.value==='auto') directionNote.textContent='翻訳方向は自動で判定します';
 else directionNote.textContent=direction.value==='to_en'?'日本語から英語へ翻訳します':'英語などから日本語へ翻訳します';
}
function showProgress(data){
 var pct=Math.max(0,Math.min(100,Math.round(Number(data&&data.progress)||0)));
 progress.hidden=false;progress.textContent=(data&&data.label||'翻訳しています')+' '+pct+'%'+(data&&data.detail?'\n'+data.detail:'');
}
function resultText(data){
 var box=document.createElement('div');box.innerHTML=String(data&&data.html||'');
 var main=box.querySelector('[data-yaku-main-text]');
 return String(main?main.textContent:(data&&data.translation||'')).trim();
}
function finish(data){
 busy=false;currentJob='';window.clearTimeout(timer);progress.hidden=true;
 var text=resultText(data);output.value=text;
 if(text){setStatus('翻訳できました。コピーできます。','success');copy.focus()}
 else{setStatus('訳文を取得できませんでした。再試行してください。','error');retry.hidden=false}
 cancel.hidden=true;update();
}
function fail(message){
 busy=false;currentJob='';window.clearTimeout(timer);progress.hidden=true;cancel.hidden=true;retry.hidden=false;
 setStatus(message||'翻訳できませんでした。','error');update();
}
function poll(jobId){
 YakuCommon.json('/api/jobs/'+encodeURIComponent(jobId)).then(function(data){
  if(jobId!==currentJob)return;
  if(data.mode==='done'||data.mode==='completed_with_warnings'){finish(data);return}
  if(data.mode==='cancelled'){fail('翻訳を中止しました。');return}
  if(data.mode==='error'||data.mode==='failed'){fail(data.detail||'翻訳が途中で止まりました。');return}
  showProgress(data);timer=window.setTimeout(function(){poll(jobId)},1000);
 }).catch(function(){if(jobId===currentJob){showProgress({label:'接続の回復を待っています',detail:'翻訳は続いています。'});timer=window.setTimeout(function(){poll(jobId)},2500)}});
}
function startRequest(request){
 lastRequest=request;retry.hidden=true;output.value='';busy=true;pending=false;setStatus('','');showProgress({label:'翻訳を準備しています',progress:0});cancel.hidden=true;update();
 YakuCommon.post('/api/palette/translate',request).then(function(data){
  if(!data||!data.job_id)throw new Error('翻訳を開始できませんでした。');
  currentJob=String(data.job_id);cancel.hidden=false;poll(currentJob);
 }).catch(function(error){
  if(error&&error.status===409&&error.data&&error.data.code==='DIRECTION_CONFIRMATION_REQUIRED'){
   direction.value=String(error.data.suggested_direction||'auto');update();fail('翻訳方向を確認しました。もう一度「翻訳」を押してください。');return;
  }
  fail(error&&error.message);
 });
}
function requestTranslation(){
 var text=input.value.trim();if(!text||busy||text.length>maxChars())return;
 var request={text:text,direction_intent:direction.value||'auto'};
 if(!ready){pending=true;lastRequest=request;setStatus('Copilotの準備ができ次第、翻訳を始めます。','');return}
 startRequest(request);
}
function boot(){
 input=el('quick-page-input');output=el('quick-page-output');direction=el('quick-page-direction');submit=el('quick-page-submit');copy=el('quick-page-copy');cancel=el('quick-page-cancel');retry=el('quick-page-retry');progress=el('quick-page-progress');status=el('quick-page-status');count=el('quick-page-count');limitNote=el('quick-page-limit');directionNote=el('quick-page-direction-note');
 YakuCommon.start();
 YakuCommon.onReady(function(value){ready=!!value;if(ready&&pending&&lastRequest)startRequest(lastRequest)});
 input.addEventListener('input',function(){if(!busy){setStatus('','');retry.hidden=true}update()});
 direction.addEventListener('change',update);
 el('quick-page-form').addEventListener('submit',function(event){event.preventDefault();requestTranslation()});
 input.addEventListener('keydown',function(event){if(event.key==='Enter'&&(event.ctrlKey||event.metaKey)){event.preventDefault();requestTranslation()}});
 copy.addEventListener('click',function(){YakuCommon.copyText(output.value).then(function(){setStatus('訳文をコピーしました。','success')}).catch(function(){setStatus('コピーできませんでした。','error')})});
 retry.addEventListener('click',function(){if(lastRequest&&ready)startRequest(lastRequest);else requestTranslation()});
 cancel.addEventListener('click',function(){if(!currentJob)return;var id=currentJob;cancel.disabled=true;YakuCommon.post('/api/cancel-translation',{job_id:id}).then(function(){if(id===currentJob)fail('翻訳を中止しました。')}).catch(function(error){cancel.disabled=false;setStatus(error.message||'中止できませんでした。','error')})});
 update();input.focus();
}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot);else boot();
})();
