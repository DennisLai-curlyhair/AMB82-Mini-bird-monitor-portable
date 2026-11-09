$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin=Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null
$html=[IO.File]::ReadAllText((Join-Path $root 'dashboard\index.html'))
$bootstrap=@'
<script>
window.testErrors=[];window.onerror=(m)=>testErrors.push(String(m));
window.fixture={connected:true,birdPresent:true,proximity:'NEAR',score:80,area:.12,nnCount:2,bbox:null,visitId:2,decision:'PENDING',lastSeen:'test',logs:[],visionStale:false,
vision:{version:'0.3.0',ms:2000,epoch:1728003600,day:20000,clockValid:true,inWindow:true,frameAgeMs:50,sequence:20,overflow:0,rgbFailures:0,totalVisits:2,dailyVisits:2,
tracks:[{id:1,group:1,visible:true,samples:3,score:80,durationMs:300000,xMin:.1,yMin:.2,xMax:.3,yMax:.6},{id:2,group:1,visible:true,samples:3,score:85,durationMs:20000,xMin:.6,yMin:.3,xMax:.8,yMax:.7}],groups:[{id:1,visits:2,thumb:'ff0000'.repeat(64)}]}};
window.fetch=async()=>({ok:true,json:async()=>JSON.parse(JSON.stringify(fixture))});
</script>
'@
$checks=@'
<script>
setTimeout(async()=>{
 const result=document.createElement('pre');result.id='test-result';document.body.append(result);
 try {
  function check(ok,msg){if(!ok)throw Error(msg);}
  check(!testErrors.length,testErrors.join(';'));
  check(window.name==='bird-monitor','monitor window identity');
  check(document.querySelector('nav a[href="/history/"]').target==='bird-library','library opens outside live monitor');
  const outside={...fixture.vision,inWindow:false,allDayGrouping:true,confidence:60};
  outside.groupingAlgorithm='spatial-anchor-v1';
  const sample={group:0,eligible:true,score:90,samples:2};
  check(groupingReason(sample,outside).includes('累積有效樣本'),'night sampling is allowed');
  check(groupingReason(sample,{...outside,allDayGrouping:false}).includes('舊版韌體'),'old firmware scope warning');
  renderVision({...fixture,vision:outside});
  check(document.getElementById('visionHealth').textContent.includes('分區外觀＋固定代表樣本'),'algorithm label');
  check(document.getElementById('dailyVisitsLabel').textContent==='今日全天新到訪','all-day count label');
  check(document.getElementById('visionWindow').textContent.includes('全天自動分群'),'all-day mode description');
  check(document.querySelectorAll('.group-card').length===1,'night groups remain visible');
  const video=document.getElementById('liveVideo');let paused=false;
  Object.defineProperty(video,'videoWidth',{get:()=>1280});Object.defineProperty(video,'videoHeight',{get:()=>720});
  Object.defineProperty(video,'paused',{get:()=>paused});render(fixture);
  const slider=document.getElementById('bboxConfidence');
  slider.value=25;slider.dispatchEvent(new Event('input'));
  check(document.querySelectorAll('.track-box').length===2,'two boxes');
  slider.value=85;slider.dispatchEvent(new Event('input'));
  check(document.querySelectorAll('.track-box').length===1,'threshold inclusive boundary');
  check(document.querySelector('.track-box').textContent.includes('#2'),'correct filtered track');
  check(document.getElementById('bboxConfidenceValue').textContent==='85%','threshold label');
  check(localStorage.getItem('bird.bboxConfidence')==='85','threshold persistence');
  check(fixture.vision.dailyVisits===2 && fixture.vision.groups[0].visits===2,'display filter preserves statistics');
  slider.value=100;slider.dispatchEvent(new Event('input'));
  check(document.querySelectorAll('.track-box').length===0,'hide below threshold');
  check(!passesBBoxConfidence(NaN) && !passesBBoxConfidence(undefined),'invalid score hidden');
  slider.value=25;slider.dispatchEvent(new Event('input'));
  check(document.getElementById('dailyVisits').textContent==='2','daily count');
  check(document.querySelectorAll('.group-card').length===1,'group rendering');
  const rgb=document.querySelector('.group-card canvas').getContext('2d').getImageData(0,0,1,1).data;
  check(rgb[0]===255&&rgb[1]===0,'board thumbnail RGB');
  paused=true;renderBBox(fixture);check(!document.querySelectorAll('.track-box').length,'pause hides boxes');
  paused=false;fixture.visionStale=true;render(fixture);check(document.getElementById('liveBirds').textContent==='—','stale count');
  check(!document.querySelectorAll('.track-box').length,'stale boxes');
  fixture.visionStale=false;render(fixture);check(document.querySelectorAll('.track-box').length===2,'resume boxes');
  const cameraRect=document.querySelector('.camera-card').getBoundingClientRect();
  const groupRect=document.querySelector('.vision-panel').getBoundingClientRect();
  check(groupRect.left>=cameraRect.right && groupRect.top>=cameraRect.top,'desktop camera/group columns');
  const sidebar=document.querySelector('.monitor-sidebar');
  check(sidebar.contains(document.querySelector('.status-card')) && sidebar.contains(document.querySelector('.log-panel')) && sidebar.contains(document.querySelector('.threshold-panel')),'all information in right column');
  check(!document.querySelector('[data-sim]'),'simulation controls removed');
  check([...sidebar.querySelectorAll('details')].every(d=>!d.open),'secondary controls collapsed');
  sidebar.querySelectorAll('details').forEach(d=>d.open=true);
  sidebar.scrollTop=sidebar.scrollHeight;
  const afterCamera=document.querySelector('.camera-card').getBoundingClientRect();
  const statusRect=document.querySelector('.status-card').getBoundingClientRect();
  check(sidebar.scrollTop>0 && Math.abs(afterCamera.top-cameraRect.top)<2,'right scrolling preserves camera position');
  check(statusRect.left>=afterCamera.right,'camera never overlaps status');
  sidebar.scrollTop=0;
  check(document.querySelector('.group-card button').disabled,'legacy firmware delete disabled');
  fixture.vision.deleteGroups=true;fixture.vision.groups[0].generation=10;fixture.visionSession='test-session';
  render(fixture);check(!document.querySelector('.group-card button').disabled,'capability enables delete');
  window.confirm=()=>true;
  let request;
  window.fetch=async(path,options)=>{
    if(path==='/api/groups/delete'){request=JSON.parse(options.body);return {ok:true,json:async()=>({ok:true})};}
    return {ok:true,json:async()=>fixture};
  };
  await deleteAppearanceGroup(fixture,fixture.vision.groups[0]);
  check(request.generation===10&&request.session==='test-session','delete identity sent');
  check(document.getElementById('groupActionStatus').textContent.includes('已確認'),'delete acknowledgement');
  window.fetch=async()=>({ok:false,json:async()=>({error:'test rejection'})});
  await deleteAppearanceGroup(fixture,fixture.vision.groups[0]);
  check(document.getElementById('groupActionStatus').textContent.includes('test rejection'),'delete failure visible');
  window.fetch=async()=>({ok:true,json:async()=>fixture});
  fixture.vision.groups[0].thumbWidth=24;fixture.vision.groups[0].thumb='00ff00'.repeat(576);
  fixture.vision.sameFrameThumbs=true;render(fixture);
  check(document.querySelector('.group-card canvas').width===24,'same-frame crop dimensions');
  const boardPixel=document.querySelector('.group-card canvas').getContext('2d').getImageData(0,0,1,1).data;
  check(boardPixel[1]===255&&boardPixel[0]===0,'same-frame crop RGB');
  check(document.querySelector('.group-card small').textContent.includes('同一推論影格'),'crop source label');
  fixture.vision.tracks=[];render(fixture);
  check(document.querySelector('.group-card canvas').getContext('2d').getImageData(0,0,1,1).data[1]===255,'bird disappearance preserves stored crop');
  fixture.vision.confidenceControl=true;fixture.vision.confidence=60;render(fixture);
  check(document.getElementById('bboxConfidence').value==='60','initial threshold from board');
  slider.value=85;slider.dispatchEvent(new Event('input'));
  window.fetch=async(path,options)=>{
    if(path==='/api/confidence'){check(JSON.parse(options.body).value===85,'threshold command');fixture.vision.confidence=85;return {ok:true,json:async()=>({ok:true})};}
    return {ok:true,json:async()=>fixture};
  };
  await applyConfidence();
  check(document.getElementById('confidenceStatus').textContent.includes('85%'),'confirmed threshold shown');
  check(document.getElementById('applySimilarity').disabled,'old firmware blocks similarity control');
  fixture.vision.similarityControl=true;fixture.vision.similarityThreshold=76;render(fixture);
  const grouping=document.getElementById('groupSimilarity');grouping.value=85;grouping.dispatchEvent(new Event('input'));
  window.fetch=async(path,options)=>{
   if(path==='/api/similarity'){check(JSON.parse(options.body).value===85,'independent grouping threshold request');fixture.vision.similarityThreshold=85;return {ok:true,json:async()=>({ok:true})};}
   return {ok:true,json:async()=>fixture};
  };
  await applySimilarity();render(fixture);
  check(document.getElementById('similarityStatus').textContent.includes('85%'),'board confirmed grouping threshold');
  check(groupingSummary({score:70,threshold:76,candidate:1,decision:3}).includes('6.00'),'percentage point gap');
  check(groupingSummary({score:null,threshold:76,samples:2,eligible:true}).includes('2/5'),'insufficient samples not fake zero');
  check(groupingSummary(null).includes('舊紀錄'),'unknown old score');
  result.textContent='PASS: dashboard multi-box, counters, groups, crop RGB, paused/stale/resume';
 }catch(e){result.textContent='FAIL: '+e.stack;}
},500);
</script>
'@
$html=$html.Replace('href="/style.css"','href="../../dashboard/style.css"').Replace('src="/vision.js"','src="../../dashboard/vision.js"').Replace('src="/weights.js"','src="../../dashboard/weights.js"').Replace('src="/app.js"','src="../../dashboard/app.js"').Replace('src="/visit-photos.js"','src="../../dashboard/visit-photos.js"').Replace('src="/navigation.js"','src="../../dashboard/navigation.js"')
$html=$html.Replace('<script src="../../dashboard/vision.js">',$bootstrap+'<script src="../../dashboard/vision.js">').Replace('</body>',$checks+'</body>')
$page=Join-Path $bin 'dashboard-test.html';[IO.File]::WriteAllText($page,$html,[Text.UTF8Encoding]::new($false))
$chrome='C:\Program Files\Google\Chrome\Application\chrome.exe'
$profile=Join-Path $bin 'chrome-profile'
$output=Join-Path $bin 'dashboard-dom.txt'
$args=@('--headless=new','--window-size=1440,900','--disable-gpu','--no-first-run','--allow-file-access-from-files','--virtual-time-budget=2500','--dump-dom',('--user-data-dir="'+$profile+'"'),([Uri]$page).AbsoluteUri)
$proc=Start-Process -FilePath $chrome -ArgumentList $args -Wait -WindowStyle Hidden -PassThru -RedirectStandardOutput $output -RedirectStandardError (Join-Path $bin 'chrome-errors.txt')
$dom=[IO.File]::ReadAllText($output)
if($dom -notmatch '<pre id="test-result">PASS:'){throw ('Dashboard tests failed: '+$dom.Substring([Math]::Max(0,$dom.Length-2500)))}
Write-Output 'PASS: dashboard multi-box, counters, groups, crop RGB, paused/stale/resume'
