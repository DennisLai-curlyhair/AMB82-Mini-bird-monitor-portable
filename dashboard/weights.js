// Weight UI never computes a calibration coefficient or fabricates a measurement.
const weightLabels={UNCALIBRATED:'未校正：先設定空載零點',AWAITING_MASS:'已設零點：請放已知重量校正',CHANGE_PENDING:'重量變動確認中，暫不採用新值',CALIBRATING:'等待穩定後完成校正',STABLE:'穩定',UNSTABLE:'重量波動／等待穩定',SETTLING:'鳥離開後等待恢復',BIRD_INTERFERENCE:'鳥類可能干擾重量',VISION_UNAVAILABLE:'視覺資料無效，暫停更新穩定值',OFFLINE:'感測器無回應',SATURATED:'ADC 飽和／接線或負載異常'};
const weightReasons={WAIT_EMPTY_STABLE:'空載仍在晃動，持續等穩定',WAIT_MASS_SIGNAL:'等待足夠且穩定的重量差，請確認砝碼',WAIT_MASS_STABLE:'砝碼仍在晃動，持續等穩定',WAIT_TARE_STABLE:'等待穩定後歸零',OK:'完成',COLLECTING:'已接受，正在取樣',CANCELLED:'已取消',REMEASURING:'已開始重新量測，等待穩定',BUSY:'此秤正在校正',SAMPLE_TIMEOUT:'取樣逾時：30 秒內未取得穩定樣本；請固定秤台、確認砝碼與接線後重試',EMPTY_UNSTABLE:'空載讀值不穩，請固定秤台',MASS_UNSTABLE:'砝碼讀值不穩',TARE_UNSTABLE:'歸零時重量不穩',MASS_SIGNAL_TOO_SMALL_OR_UNSTABLE:'重量變化太小或不穩，請確認砝碼與克數',ADC_SATURATED:'ADC 飽和，請檢查負載與接線',SENSOR_UNAVAILABLE:'感測器尚無有效資料',VISION_OR_BIRD_INTERFERENCE:'舊版韌體仍會用視覺阻擋校正，請燒錄 0.15.1 以上版本',ZERO_REQUIRED_OR_INVALID_MASS:'請先設定空載零點並輸入有效克數',CALIBRATED_WEIGHT_REQUIRED:'請先完成已知重量校正，再使用空容器歸零',STABLE_CALIBRATED_WEIGHT_REQUIRED:'須先校正並等讀值穩定後才能歸零'};
const weightPending=new Map();let weightLastState=null,weightBoot=null,weightSeq=null,weightPacketAt=Date.now();
// Browser-only recent telemetry; never converts uncalibrated ADC counts to grams.
const weightTrends=new Map();
function renderWeightRaw(id,s,w,online){
 const raw=Number.isFinite(s?.raw_latest)?s.raw_latest:s?.raw;
 const valid=online&&Number.isFinite(raw)&&!['OFFLINE','SATURATED'].includes(s?.status);
 let history=weightTrends.get(id);
 const key=w?.boot+':'+w?.seq;
 if(!valid){weightTrends.delete(id);history=null;}
 else{
  if(!history||history.boot!==w.boot){history={boot:w.boot,key:null,points:[],delta:null};weightTrends.set(id,history);}
  if(history.key!==key){
   const previous=history.points.at(-1);history.delta=previous?raw-previous.value:null;
   history.points.push({value:raw,at:Date.now()});if(history.points.length>60)history.points.shift();history.key=key;
  }
 }
 const fmt=v=>Number.isFinite(v)?v.toLocaleString('zh-TW',{maximumFractionDigits:1}):'—';
 document.getElementById('weightRaw'+id).textContent=valid?fmt(raw):'—';
 document.getElementById('weightFiltered'+id).textContent=valid?fmt(s.raw):'—';
 const delta=history?.delta;
 document.getElementById('weightDelta'+id).textContent=Number.isFinite(delta)?(delta>0?'+':'')+fmt(delta):'—';
 const canvas=document.getElementById('weightTrend'+id),ctx=canvas.getContext('2d');ctx.clearRect(0,0,canvas.width,canvas.height);
 const points=history?.points||[],values=points.map(p=>p.value);
 const info=document.getElementById('weightTrendInfo'+id);
 if(!valid){info.textContent='等待有效讀值；斷線或感測器異常時不顯示舊曲線。';return;}
 const lo=Math.min(...values),hi=Math.max(...values),span=hi-lo;
 info.textContent='最近 '+points.length+' 筆回報 · 波動範圍 '+fmt(span)+' ADC · 曲線縱軸自動縮放';
 ctx.strokeStyle='#4ee39a';ctx.lineWidth=2;ctx.beginPath();
 points.forEach((point,i)=>{const x=8+(canvas.width-16)*i/Math.max(1,points.length-1),y=span?canvas.height-8-(canvas.height-16)*(point.value-lo)/span:canvas.height/2;if(i)ctx.lineTo(x,y);else ctx.moveTo(x,y);});ctx.stroke();
 if(points.length===1){ctx.fillStyle='#4ee39a';ctx.fillRect(6,canvas.height/2-2,4,4);}
}
function weightMessage(id,message){document.getElementById('weightMessage'+id).textContent=message;}
function setupWeights(){
 const root=document.getElementById('weightCards');if(!root)return;
 for(const id of [1,2]){
  const card=document.createElement('article');card.className='weight-card';
  card.innerHTML='<h4>'+ (id===1?'飼料秤':'水秤')+' · '+id+' 號</h4><strong id="weightValue'+id+'">—</strong><p id="weightState'+id+'">等待雙秤韌體</p><small id="weightStable'+id+'">尚無穩定值</small><section class="weight-raw"><b>即時感測數值（ADC，非公克）</b><div>原始值 <strong id="weightRaw'+id+'">—</strong></div><small>過濾後 <span id="weightFiltered'+id+'">—</span> · 比上一筆 <span id="weightDelta'+id+'">—</span></small><canvas id="weightTrend'+id+'" width="520" height="80" role="img" aria-label="最近原始讀值走勢，縱軸自動縮放"></canvas><small id="weightTrendInfo'+id+'">等待有效讀值</small><small>校正前與校正中皆可看變化；約每 0.5 秒回報，不是每筆硬體取樣。</small></section><details><summary>校正與歸零</summary><p class="hint">先放空容器設定零點，再放上已知重量。每次開機需重新校正；校正不受畫面有鳥或視覺失聯影響，只需確認秤台無鳥、無碰觸。系統最多等 30 秒，晃動時會繼續取樣；請等「板端已完成」，20 筆不代表已通過。</p><button data-weight-action="ZERO" type="button">① 設定空載零點</button><label>參考重量（g）<input id="weightMass'+id+'" type="number" min="0.001" max="1000000" step="any" placeholder="例如 100"></label><button data-weight-action="MASS" type="button">② 已知重量校正</button><button data-weight-action="TARE" type="button">空容器歸零</button><button data-weight-action="CANCEL" type="button">取消校正</button></details><button data-weight-action="REMEASURE" type="button">重新量測</button><p id="weightMessage'+id+'" role="status"></p>';
  for(const b of card.querySelectorAll('button')){b.dataset.channel=id;b.disabled=true;b.onclick=()=>weightAction(id,b.dataset.weightAction);}
  root.append(card);
 }
}
function renderWeights(state){
 weightLastState=state;const w=state.weights,online=!!(state.connected&&w&&!state.weightStale);
 if(w&&(w.seq!==weightSeq||w.boot!==weightBoot)){weightPacketAt=Date.now();weightSeq=w.seq;}
 if(w&&weightBoot&&w.boot!==weightBoot){weightPending.clear();for(const id of [1,2])weightMessage(id,'開發板已重啟，請重新校正');}
 if(w)weightBoot=w.boot;
 document.getElementById('weightConnection').textContent=online?(w.channels?.[0]?.calibration_independent?'每 0.5 秒回傳 · 一般穩定觀察 3 秒，大幅變動確認 5 秒':'目前為舊版重量韌體；需燒錄 0.15.1 才能解除校正的視覺限制'):'重量資料未連線／已過期，或尚未燒錄雙秤韌體';
 for(const id of [1,2]){
  const s=w?.channels?.find(c=>c.id===id),pending=weightPending.get(id);
  renderWeightRaw(id,s,w,online);
  if(pending&&s?.request_id===pending.id&&['COMPLETE','FAILED','REJECTED'].includes(s.phase)){
   weightMessage(id,(s.phase==='COMPLETE'?'板端已完成：':'操作失敗：')+(weightReasons[s.reason]||s.reason));weightPending.delete(id);
  }else if(pending&&Date.now()-pending.at>35000){weightMessage(id,'結果未確認，請檢查最新狀態；不會自動重送');weightPending.delete(id);}
  document.getElementById('weightValue'+id).textContent=online&&Number.isFinite(s?.grams)?s.grams.toFixed(1)+' g':'—';
  document.getElementById('weightState'+id).textContent=online?(weightLabels[s?.status]||'等待有效資料')+(s?.status==='CALIBRATING'?' · '+s.progress+'/20 筆；'+(weightReasons[s.reason]||'正在取樣'):''):'資料過期／未連線';
  const stable=document.getElementById('weightStable'+id);
  stable.textContent=Number.isFinite(s?.stable_g)?'最近穩定值 '+s.stable_g.toFixed(1)+' g · '+Math.floor((s.stable_age_ms+Date.now()-weightPacketAt)/1000)+' 秒前'+(!online||s.status!=='STABLE'?'（保留值，非目前可信重量）':''):'尚無穩定值';
  for(const b of document.querySelectorAll('button[data-channel="'+id+'"]')){
   const action=b.dataset.weightAction,busy=!!weightPending.get(id)||s?.status==='CALIBRATING';
   b.disabled=!online||(busy&&action!=='CANCEL')||(action==='CANCEL'&&!busy)||(action==='MASS'&&!s?.zero_ready)||(action==='TARE'&&(!s?.calibrated||(!s?.calibration_independent&&s?.status!=='STABLE')));
  }
 }
}
async function weightAction(channel,action){
 const w=weightLastState?.weights;if(!w||!weightLastState.connected||weightLastState.weightStale)return;
 let grams;
 if(action==='MASS'){
  grams=Number(document.getElementById('weightMass'+channel).value);
  if(!Number.isFinite(grams)||grams<=0||grams>1000000){weightMessage(channel,'請輸入有效的已知重量克數');return;}
 }
 if(['ZERO','TARE'].includes(action)&&!confirm('確認 '+channel+' 號秤上只有空容器，沒有內容物、砝碼或鳥？'+(action==='ZERO'?'完成後需重新用砝碼校正。':'')))return;
 const id=crypto.randomUUID().replace(/-/g,'');
 weightPending.set(channel,{id,at:Date.now()});weightMessage(channel,'等待板端回覆…');renderWeights(weightLastState);
 try{
  const response=await fetch('/api/weights/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({request_id:id,boot:w.boot,channel,action,grams,confirm_empty:['ZERO','TARE'].includes(action)}),signal:AbortSignal.timeout(5000)});
  const data=await response.json();
  if(!response.ok)throw Error(data.error||'操作未確認');
  const ack=data.ack;
  if(!ack||ack.request_id!==id||ack.channel!==channel||ack.boot!==w.boot)throw Error('回覆識別碼不符，結果未確認');
  if(ack.phase==='ACCEPTED')weightMessage(channel,'板端已接受，正在取樣；尚未完成');
  else{weightPending.delete(channel);weightMessage(channel,(ack.phase==='COMPLETE'?'板端已完成：':'操作失敗：')+(weightReasons[ack.reason]||ack.reason));}
 }catch(e){weightMessage(channel,e.message+'；請查看狀態，不會自動重送');}
 if(weightLastState)renderWeights(weightLastState);
}
setupWeights();
