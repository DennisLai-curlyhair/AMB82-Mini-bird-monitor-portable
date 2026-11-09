function groupingSummary(g){
 if(!g)return '分群分數：舊紀錄未提供';
 if(g.score==null){
  if(g.decision===1)return '首次建立外觀群，無既有群可比對';
  if(!g.eligible)return '尚未比對：未校時或跨日持續到訪';
  return '尚未比對：有效樣本 '+g.samples+'/5（樣本不足或無可用影像）';
 }
 const gap=g.threshold-g.score;
 return (g.decision===2?'合併前比對群 ':'當時最接近外觀群 ')+g.candidate+'：'+g.score.toFixed(2)+'% · 當時門檻 '+g.threshold+'% · '+
  (gap>0?'低於門檻 '+gap.toFixed(2)+' 個百分點':'已達門檻')+
  (g.decision===1?' · 未合併，建立新群':g.decision===3?' · 群組容量已滿':'');
}

let similarityInitialized=false,similarityBusy=false;
const similarityInput=document.getElementById('groupSimilarity');
similarityInput.oninput=()=>{document.getElementById('groupSimilarityValue').textContent=similarityInput.value+'%';};
async function applySimilarity(){
 if(similarityBusy)return;
 const value=Number(similarityInput.value),status=document.getElementById('similarityStatus');
 similarityBusy=true;document.getElementById('applySimilarity').disabled=true;status.textContent='等待板端確認…';
 try{
  const response=await fetch('/api/similarity',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({value}),signal:AbortSignal.timeout(6500)});
  const data=await response.json();if(!response.ok||!data.ok)throw Error(data.error||'套用失敗');
  status.textContent='板端已確認 '+value+'%';await refresh();
 }catch(e){status.textContent=e.message;}finally{similarityBusy=false;}
}
document.getElementById('applySimilarity').onclick=applySimilarity;
function renderSimilarity(state){
 const v=state.vision,supported=!!v?.similarityControl;
 document.getElementById('applySimilarity').disabled=similarityBusy||!supported||state.visionStale||!state.connected;
 if(!supported){document.getElementById('unassignedScores').replaceChildren();document.getElementById('similarityStatus').textContent='需要燒錄新版韌體才能讀取分數與設定門檻';return;}
 if(!similarityInitialized){similarityInput.value=v.similarityThreshold;similarityInput.oninput();similarityInitialized=true;}
 if(!similarityBusy)document.getElementById('similarityStatus').textContent='板端目前 '+v.similarityThreshold+'%'+(Number(similarityInput.value)!==v.similarityThreshold?' · 滑桿尚未套用':'');
 document.getElementById('unassignedScores').replaceChildren(...(v.tracks||[]).filter(t=>!t.group).map(t=>{const p=document.createElement('p');p.textContent='未分群 #'+t.id+' · '+groupingSummary(t.grouping);return p;}));
}
function groupingReason(t,v){
  if(t.group)return '群 '+t.group;
  if(!v.clockValid)return '等待校時';
  if(!v.allDayGrouping&&!v.inWindow)return '舊版韌體：統計時段外，需更新以全天分群';
  if(t.eligible===false)return t.awaitingClock?'校時完成，等待新的有效偵測':(v.allDayGrouping?'前一日持續停留，不重算新到訪':'本次到訪不在統計範圍');
  if(t.assigned)return '群組容量已滿';
  if(t.score<v.confidence)return '低於板端信心門檻';
  if(t.samples<5)return '累積有效樣本 '+t.samples+'/5（小框或重疊會跳過）';
  return '等待新的有效偵測完成分群';
}

let deletingGroup = false;
async function deleteAppearanceGroup(state,g){
  if(deletingGroup)return;
  if(!confirm('刪除外觀群 '+g.id+'，並扣除其 '+g.visits+' 次到訪？該群可能包含多個物件，刪除不會訓練模型。'))return;
  deletingGroup=true;
  const status=document.getElementById('groupActionStatus');
  status.textContent='等待開發板確認刪除…';
  try{
    const response=await fetch('/api/groups/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({session:state.visionSession,day:state.vision.day,generation:g.generation}),signal:AbortSignal.timeout(6500)});
    const result=await response.json();
    if(!response.ok||!result.ok)throw Error(result.error||'刪除失敗');
    status.textContent='開發板已確認刪除，統計已扣除。';
    await refresh();
  }catch(e){status.textContent='刪除未確認：'+e.message+'；請查看最新狀態後再操作。';}
  finally{deletingGroup=false;}
}
// Display only: detection, tracking, daily counts and grouping are on AMB82.
function renderVision(state) {
  renderSimilarity(state);
  const v=state.vision, el=(id)=>document.getElementById(id);
  if(!v){el('visionHealth').textContent='等待板端 v0.3.0 資料（不由網頁計數）';return;}
  const stale=state.visionStale||v.frameAgeMs>2000;
  el('visionHealth').textContent=stale?'影格／連線已過期':`板端運作中 · 影格 #${v.sequence}`;
  el('visionHealth').textContent+=v.groupingAlgorithm==='spatial-anchor-v1'?' · 分區外觀＋固定代表樣本':' · 舊版外觀分群';
  const tracks=(v.tracks||[]), groups=(v.groups||[]);
  el('liveBirds').textContent=stale?'—':tracks.filter(t=>t.visible).length;
  el('totalVisits').textContent=v.totalVisits;
  el('dailyVisitsLabel').textContent=v.allDayGrouping?'今日全天新到訪':'今日 08:00–17:00 新到訪';
  el('dailyVisits').textContent=v.clockValid?v.dailyVisits:'尚未校時';
  const grouped=groups.reduce((n,g)=>n+g.visits,0);
  el('unassigned').textContent=v.clockValid?Math.max(0,v.dailyVisits-grouped):'—';
  el('visionWindow').textContent=(v.clockValid?
    `${new Date(v.epoch*1000).toLocaleString('zh-TW',{timeZone:'Asia/Taipei'})} · ${v.allDayGrouping?'全天自動分群（08:00–17:00 僅供歷史報表篩選）':(v.inWindow?'舊版：統計時段內':'舊版：統計時段外，請更新韌體')} · 群組僅限當日／本次開機`:'尚未校時：追蹤繼續，但不納入每日分群')+
    ` · 容量溢出 ${v.overflow} · RGB 無效 ${v.rgbFailures}`;
  el('trackList').replaceChildren(...tracks.map(t=>{
    const e=document.createElement('div');e.textContent=`#${t.id} · ${t.visible&&!stale?'可見':'暫時遺失'} · ${Math.round(t.durationMs/1000)} 秒 · ${groupingReason(t,v)} · ${t.samples}/5 張起`;return e;
  }));

  el('groupGallery').replaceChildren(...groups.map(g=>{
    const card=document.createElement('div');card.className='group-card';
    const side=g.thumbWidth===24?24:8;
    const c=document.createElement('canvas');c.width=c.height=side;
    const ctx=c.getContext('2d'),pixels=ctx.createImageData(side,side);
    const valid=typeof g.thumb==='string'&&new RegExp('^[a-f0-9]{'+(side*side*6)+'}$','i').test(g.thumb);
    if(valid)for(let i=0;i<side*side;i++){
      for(let k=0;k<3;k++)pixels.data[i*4+k]=parseInt(g.thumb.slice((i*3+k)*2,(i*3+k)*2+2),16);
      pixels.data[i*4+3]=255;
    }
    ctx.putImageData(pixels,0,0);
    const label=document.createElement('p');label.textContent='外觀群 '+g.id+' · '+g.visits+' 次到訪';
    const note=document.createElement('small');
    note.textContent=valid?(side===24?'板端同一推論影格 · 24×24':'舊版板端色彩圖 · 8×8'):'等待板端代表圖傳送…';
    const button=document.createElement('button');button.className='danger';button.textContent='刪除此群';
    button.disabled=stale||!v.deleteGroups||!g.generation||deletingGroup;
    button.title=v.deleteGroups?'扣除整群到訪並忽略仍在場的相關追蹤':'需燒錄新版韌體才能刪除';
    button.onclick=()=>deleteAppearanceGroup(state,g);
    card.append(c,label,note,button);return card;
  }));
}
function renderTrackBoxes(state){
  document.getElementById('bboxOverlay').style.display='none';
  const layer=document.getElementById('trackOverlays');layer.replaceChildren();
  const video=document.getElementById('liveVideo'), v=state.vision;
  if(!v||state.visionStale||v.frameAgeMs>2000||video.paused||!video.videoWidth)return;
  const scale=Math.min(video.clientWidth/video.videoWidth,video.clientHeight/video.videoHeight);
  const w=video.videoWidth*scale,h=video.videoHeight*scale,ox=(video.clientWidth-w)/2,oy=(video.clientHeight-h)/2;
  for(const t of v.tracks||[]){if(!t.visible || !passesBBoxConfidence(t.score))continue;
    const box=document.createElement('div');box.className='track-box';
    Object.assign(box.style,{left:`${ox+t.xMin*w}px`,top:`${oy+t.yMin*h}px`,width:`${(t.xMax-t.xMin)*w}px`,height:`${(t.yMax-t.yMin)*h}px`});
    const label=document.createElement('span');label.textContent=`#${t.id} ${t.score}% · ${groupingReason(t,v)}`;
    box.append(label);layer.append(box);
  }
}
