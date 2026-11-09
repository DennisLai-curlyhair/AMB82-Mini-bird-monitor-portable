// UVC is a different stream: ring matching is approximate, not frame synchronization.
(() => {
  const video=document.getElementById('liveVideo'),status=document.getElementById('photoStatus');
  const ring=[],done=new Set();let bytes=0,lastCapture=0,capturing=false,uploading=false,boot=null;
  const MAX_BYTES=16*1024*1024;
  status.textContent='大圖擷取模組已載入；等待攝影機播放與板端資料';
  function clear(){ring.length=0;bytes=0;done.clear();}
  function active(){return !document.hidden&&!video.paused&&video.readyState>=2&&video.videoWidth>0;}
  function prune(now){while(ring.length&&(now-ring[0].stamp>20000||bytes>MAX_BYTES)){bytes-=ring.shift().blob.size;}}
  async function sample(now){
    if(!active()||capturing||now-lastCapture<250)return;
    const v=typeof lastState!=='undefined'?lastState?.vision:null;
    if(!v?.photoCapture){status.textContent='大圖保存需新版韌體提供代表樣本座標';return;}
    if(!v.clockValid||lastState.visionStale){clear();status.textContent='等待校時及有效板端資料，暫停大圖擷取';return;}
    if(boot!==v.boot){boot=v.boot;clear();}
    lastCapture=now;capturing=true;
    try{
      const scale=Math.min(1,1280/video.videoWidth,720/video.videoHeight),c=document.createElement('canvas');
      c.width=Math.round(video.videoWidth*scale);c.height=Math.round(video.videoHeight*scale);
      c.getContext('2d').drawImage(video,0,0,c.width,c.height);
      const stamp=Date.now();const blob=await new Promise(resolve=>c.toBlob(resolve,'image/jpeg',.9));
      if(blob){if(!ring.length)status.textContent='影像緩衝已啟用，等待符合條件的到訪代表照';ring.push({blob,stamp,boot});bytes+=blob.size;prune(Date.now());}
    }finally{capturing=false;}
  }
  function tick(now){sample(now).catch(e=>status.textContent='影像緩衝失敗：'+e.message);video.requestVideoFrameCallback(tick);}
  if(video.requestVideoFrameCallback)video.requestVideoFrameCallback(tick);
  else status.textContent='此瀏覽器不支援逐影格擷取，請使用新版 Chrome／Edge';
  document.addEventListener('visibilitychange',()=>{if(document.hidden){clear();status.textContent='頁面在背景：暫停大圖擷取';}});
  video.addEventListener('pause',()=>{clear();status.textContent='畫面已暫停：不擷取大圖';});
  async function bitmap(url){const r=await fetch(url);if(!r.ok)throw Error('參考縮圖讀取失敗');return createImageBitmap(await r.blob());}
  function pixels(image,box){const c=document.createElement('canvas');c.width=c.height=24;const ctx=c.getContext('2d');ctx.imageSmoothingEnabled=false;
    if(box)ctx.drawImage(image,box[0]*image.width,box[1]*image.height,(box[2]-box[0])*image.width,(box[3]-box[1])*image.height,0,0,24,24);
    else ctx.drawImage(image,0,0,24,24);return ctx.getImageData(0,0,24,24).data;}
  function error(a,b){let s=0;for(let i=0;i<a.length;i++)if(i%4!==3)s+=Math.abs(a[i]-b[i]);return s/(1728*255);}
  async function base64(blob){return new Promise((resolve,reject)=>{const r=new FileReader();r.onload=()=>resolve(r.result.split(',')[1]);r.onerror=reject;r.readAsDataURL(blob);});}
  async function match(){
    if(uploading||!active()||!ring.length)return;
    uploading=true;
    try{
      const response=await fetch('/history/api/photo-targets',{signal:AbortSignal.timeout(5000)});
      const data=await response.json();if(!response.ok)throw Error(data.error||'照片服務未就緒');
      for(const t of data.targets){
        if(t.boot!==boot)continue;
        const id=t.key+':'+t.sequence;if(done.has(id))continue;
        const candidates=ring.filter(f=>f.boot===boot&&Math.abs(f.stamp-t.epoch*1000)<=data.time_tolerance_ms);
        if(!candidates.length)continue;
        const ref=await bitmap('/history/images/'+t.reference);let best=null,bestError=Infinity;
        try{const reference=pixels(ref);for(const f of candidates){const im=await createImageBitmap(f.blob);try{
          if((t.bbox[2]-t.bbox[0])*im.width<64||(t.bbox[3]-t.bbox[1])*im.height<64)continue;
          const score=error(pixels(im,t.bbox),reference);if(score<bestError){bestError=score;best=f;}
        }finally{im.close();}}}finally{ref.close();}
        if(!best||bestError>data.max_error){status.textContent='未找到相符大圖，保留板端縮圖';continue;}
        if(!active()||t.boot!==boot)continue;
        const result=await fetch('/history/api/photo',{method:'POST',headers:{'Content-Type':'application/json'},
          body:JSON.stringify({key:t.key,sequence:t.sequence,captured_utc:best.stamp/1000,jpeg:await base64(best.blob)}),signal:AbortSignal.timeout(10000)});
        const saved=await result.json();if(!result.ok){status.textContent='大圖未保存：'+saved.error;continue;}
        done.add(id);if(done.size>256)done.delete(done.values().next().value);
        status.textContent=saved.saved?'已保存到訪代表照（時間與內容近似配對），可至歷史頁放大':'已保留較佳代表照';
      }
    }catch(e){status.textContent='大圖保存失敗：'+e.message+'；板端縮圖仍獨立保存';}
    finally{uploading=false;}
  }
  setInterval(match,1200);
})();
