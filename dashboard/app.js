const $ = (selector) => document.querySelector(selector);
let lastLogCount = 0;
let cameraStream = null;
let lastState = null;
let bboxConfidence = 20;
let confidenceInitialized=false;
try {
  const saved = Number(localStorage.getItem('bird.bboxConfidence'));
  if (Number.isFinite(saved) && saved >= 20 && saved <= 100) bboxConfidence = Math.round(saved);
} catch (_) { /* Storage may be disabled; controls still work. */ }
function passesBBoxConfidence(score) {
  return typeof score === 'number' && Number.isFinite(score) && score >= bboxConfidence;
}
const confidenceInput = document.getElementById('bboxConfidence');
function updateBBoxConfidence() {
  const value = Number(confidenceInput.value);
  bboxConfidence = Number.isFinite(value) ? Math.max(20, Math.min(100, Math.round(value))) : 20;
  confidenceInput.value = bboxConfidence;
  document.getElementById('bboxConfidenceValue').textContent = `${bboxConfidence}%`;
  try { localStorage.setItem('bird.bboxConfidence', String(bboxConfidence)); } catch (_) {}
  if (lastState) renderBBox(lastState);
}
confidenceInput.value = bboxConfidence;
confidenceInput.addEventListener('input', updateBBoxConfidence);
updateBBoxConfidence();

async function applyConfidence(){
  const status=document.getElementById('confidenceStatus'),button=document.getElementById('applyConfidence');
  button.disabled=true;status.textContent='等待板端確認…';
  try{
    const response=await fetch('/api/confidence',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({value:bboxConfidence}),signal:AbortSignal.timeout(6500)});
    const result=await response.json();
    if(!response.ok||!result.ok)throw Error(result.error||'套用失敗');
    status.textContent='板端已確認套用 '+bboxConfidence+'%';await refresh();
  }catch(e){status.textContent=e.message;}
  finally{button.disabled=false;}
}
document.getElementById('applyConfidence').onclick=applyConfidence;
async function post(path, data) {
  await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  });
  await refresh();
}

function render(state) {
  lastState = state;
  const v=state.vision;
  if(v&&v.confidenceControl){
    if(!confidenceInitialized){bboxConfidence=v.confidence;confidenceInput.value=bboxConfidence;updateBBoxConfidence();confidenceInitialized=true;}
    document.getElementById('confidenceStatus').textContent='板端目前 '+v.confidence+'%'+(bboxConfidence!==v.confidence?' · 滑桿尚未套用':'');
  }else{
    document.getElementById('confidenceStatus').textContent='舊韌體：目前僅過濾顯示，需更新才能控制分群';
  }
  $('#connection').textContent = state.connected ? '開發板已連線' : '開發板未連線';
  $('#connection').className = `pill ${state.connected ? 'online' : 'offline'}`;
  $('#birdState').textContent = state.birdPresent ? '偵測到鳥' : '尚未偵測到鳥';
  $('#birdDot').className = `dot ${state.birdPresent ? 'active' : ''}`;
  $('#proximity').textContent = ({ FAR: '遠', NEAR: '靠近', CLOSE: '非常靠近', NONE: '—' })[state.proximity] || state.proximity;
  $('#score').textContent = state.birdPresent ? `${state.score}%` : '—';
  $('#area').textContent = state.birdPresent ? `${(state.area * 100).toFixed(1)}%` : '—';
  $('#nnCount').textContent = state.nnCount ?? 0;
  $('#bbox').textContent = state.bbox
    ? `${state.bbox.xMin.toFixed(3)}, ${state.bbox.yMin.toFixed(3)} → ${state.bbox.xMax.toFixed(3)}, ${state.bbox.yMax.toFixed(3)}`
    : '—';
  $('#visit').textContent = state.visitId ? `#${String(state.visitId).padStart(3, '0')}` : '—';
  $('#timestamp').textContent = new Date().toLocaleString('zh-TW');
  $('#lastSeen').textContent = state.lastSeen || '尚無紀錄';
  if (state.logs.length !== lastLogCount) {
    $('#logs').innerHTML = state.logs.slice().reverse().map((line) => `<li>${escapeHtml(line)}</li>`).join('');
    lastLogCount = state.logs.length;
  }
  renderVision(state);
  if(typeof renderWeights==='function')renderWeights(state);
  renderBBox(state);
}

function renderBBox(state) {
  if (state.vision) { renderTrackBoxes(state); return; }
  const video = $('#liveVideo');
  const overlay = $('#bboxOverlay');
  const label = $('#bboxLabel');
  if (!state.bbox || !passesBBoxConfidence(state.bbox.score) || !video.videoWidth || !video.videoHeight || !cameraStream || video.paused) {
    overlay.style.display = 'none';
    return;
  }
  const containerWidth = video.clientWidth;
  const containerHeight = video.clientHeight;
  const scale = Math.min(containerWidth / video.videoWidth, containerHeight / video.videoHeight);
  const displayWidth = video.videoWidth * scale;
  const displayHeight = video.videoHeight * scale;
  const offsetX = (containerWidth - displayWidth) / 2;
  const offsetY = (containerHeight - displayHeight) / 2;
  const box = state.bbox;
  overlay.style.left = `${offsetX + box.xMin * displayWidth}px`;
  overlay.style.top = `${offsetY + box.yMin * displayHeight}px`;
  overlay.style.width = `${(box.xMax - box.xMin) * displayWidth}px`;
  overlay.style.height = `${(box.yMax - box.yMin) * displayHeight}px`;
  overlay.style.display = 'block';
  label.textContent = `bird ${box.score}%`;
}

function escapeHtml(value) {
  const element = document.createElement('div');
  element.textContent = value;
  return element.innerHTML;
}

async function refresh() {
  try {
    const response = await fetch('/api/status', { cache: 'no-store' });
    render(await response.json());
  } catch (error) {
    if(typeof renderWeights==='function')renderWeights({...lastState,connected:false,weightStale:true});
    $('#connection').textContent = '伺服器中斷';
    $('#connection').className = 'pill offline';
  }
}

function stopTracks(stream) {
  if (stream) stream.getTracks().forEach((track) => track.stop());
}

function withTimeout(promise, milliseconds, message) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), milliseconds);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

async function findUvcDevice() {
  let devices = await navigator.mediaDevices.enumerateDevices();
  let uvc = devices.find((device) => device.kind === 'videoinput' && /USB UVC CLASS|AMB82|AMEBA/i.test(device.label));
  if (uvc) return uvc;

  // Device labels are hidden until the browser has received camera permission once.
  const permissionProbe = await withTimeout(
    navigator.mediaDevices.getUserMedia({ video: true, audio: false }),
    10000,
    '等待攝影機權限逾時',
  );
  stopTracks(permissionProbe);
  devices = await navigator.mediaDevices.enumerateDevices();
  uvc = devices.find((device) => device.kind === 'videoinput' && /USB UVC CLASS|AMB82|AMEBA/i.test(device.label));
  if (!uvc) {
    const names = devices.filter((device) => device.kind === 'videoinput').map((device) => device.label || '未命名攝影機');
    throw new Error(`找不到 USB UVC CLASS。目前裝置：${names.join('、') || '無'}`);
  }
  return uvc;
}

async function startCamera() {
  const button = $('#startCamera');
  const status = $('#cameraStatus');
  const video = $('#liveVideo');
  button.disabled = true;

  try {
    if (!navigator.mediaDevices?.getUserMedia) throw new Error('瀏覽器不支援攝影機 API');

    const liveTrack = cameraStream?.getVideoTracks().find((track) => track.readyState === 'live');
    if (liveTrack) {
      video.srcObject = cameraStream;
      await withTimeout(video.play(), 8000, '攝影機連線仍在，但未收到影像幀');
      const settings = liveTrack.getSettings() || {};
      const dimensions = settings.width && settings.height ? ` ${settings.width}×${settings.height}` : '';
      status.textContent = `即時畫面：${liveTrack.label || 'USB UVC CLASS'}${dimensions}`;
      $('#cameraEmpty').style.display = 'none';
      $('#stopCamera').disabled = false;
      button.textContent = '繼續畫面';
      return;
    }

    cameraStream = null;
    status.textContent = '正在尋找 AMB82 USB 攝影機…';
    const uvc = await findUvcDevice();
    status.textContent = `已找到 ${uvc.label}，正在協商 MJPEG 影像…`;
    const stream = await withTimeout(
      navigator.mediaDevices.getUserMedia({
        video: { deviceId: { exact: uvc.deviceId } },
        audio: false,
      }),
      12000,
      'AMB82 影像協商逾時；若先前已完全關閉 UVC，請按板上 RESET 一次',
    );
    cameraStream = stream;
    video.srcObject = stream;
    await withTimeout(video.play(), 8000, '已連到攝影機，但未收到影像幀');

    const track = stream.getVideoTracks()[0];
    const settings = track?.getSettings() || {};
    const dimensions = settings.width && settings.height ? ` ${settings.width}×${settings.height}` : '';
    status.textContent = `即時畫面：${track?.label || 'USB UVC CLASS'}${dimensions}`;
    $('#cameraEmpty').style.display = 'none';
    $('#stopCamera').disabled = false;
    button.textContent = '繼續畫面';
  } catch (error) {
    stopTracks(cameraStream);
    cameraStream = null;
    video.srcObject = null;
    $('#cameraEmpty').style.display = 'grid';
    $('#cameraEmpty').textContent = '未取得 AMB82 即時畫面';
    status.textContent = `攝影機錯誤：${error.message}`;
  } finally {
    button.disabled = false;
  }
}

function stopCamera() {
  const video = $('#liveVideo');
  video.pause();
  document.querySelector('#trackOverlays').replaceChildren();
  $('#bboxOverlay').style.display = 'none';
  $('#cameraEmpty').style.display = 'grid';
  $('#cameraEmpty').textContent = '畫面已暫停；USB UVC 連線仍保留';
  $('#cameraStatus').textContent = '畫面已暫停，可直接繼續，不需重啟開發板';
  $('#stopCamera').disabled = true;
  $('#startCamera').textContent = '繼續畫面';
}

$('#startCamera').onclick = startCamera;
$('#stopCamera').onclick = stopCamera;
window.addEventListener('resize', () => { if (lastState) renderBBox(lastState); });
setInterval(refresh, 500);
refresh();
