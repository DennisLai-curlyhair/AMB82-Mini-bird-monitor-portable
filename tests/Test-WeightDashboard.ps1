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
 try{
  const check=(ok,msg)=>{if(!ok)throw Error(msg);};
  check(!document.getElementById('feed')&&!document.getElementById('skip'),'feeding removed');
  const boot='a'.repeat(32);
  const scales=[1,2].map(id=>({id,calibrated:false,zero_ready:false,status:'UNCALIBRATED',grams:null,stable_g:null,stable_age_ms:null,progress:0,request_id:'',phase:'',reason:''}));
  fixture.weights={boot,seq:1,channels:scales};fixture.weightStale=false;render(fixture);
  check(document.getElementById('weightValue1').textContent==='—','unknown is not zero');
  Object.assign(scales[0],{raw_latest:16000,raw:15990});fixture.weights.seq++;render(fixture);
  check(document.getElementById('weightRaw1').textContent==='16,000','raw visible before calibration');
  check(document.getElementById('weightFiltered1').textContent==='15,990','filtered raw visible');
  check(document.getElementById('weightValue1').textContent==='—','raw not falsely converted to grams');
  render(fixture);check(weightTrends.get(1).points.length===1,'duplicate polling does not append');
  Object.assign(scales[0],{status:'CALIBRATING',raw_latest:16100});fixture.weights.seq++;render(fixture);
  check(document.getElementById('weightDelta1').textContent==='+100','delta while calibrating');
  check(weightTrends.get(1).points.length===2,'trend while calibrating');
  fixture.weights.boot='b'.repeat(32);render(fixture);check(weightTrends.get(1).points.length===1,'reboot clears old history');
  fixture.weights.boot=boot;scales[0].status='UNCALIBRATED';render(fixture);
  for(let i=0;i<65;i++){fixture.weights.seq++;render(fixture);}check(weightTrends.get(1).points.length===60,'bounded trend memory');
  Object.assign(scales[1],{raw_latest:-123,raw:-125});fixture.weights.seq++;render(fixture);
  check(document.getElementById('weightRaw2').textContent==='-123','independent second scale signed value');
  let calls=0,posted;window.confirm=()=>false;
  window.fetch=async(path,options)=>{if(options){calls++;posted=JSON.parse(options.body);return {ok:true,json:async()=>({ok:true,ack:{boot,request_id:posted.request_id,channel:posted.channel,phase:'ACCEPTED',reason:'COLLECTING'}})};}return {ok:true,json:async()=>fixture};};
  await weightAction(1,'ZERO');check(calls===0,'cancel sends nothing');
  window.confirm=()=>true;await weightAction(1,'ZERO');
  check(posted.action==='ZERO'&&posted.confirm_empty===true,'zero request');
  check(document.getElementById('weightMessage1').textContent.includes('尚未完成'),'accept is not complete');
  check(!document.querySelector('[data-channel="2"][data-weight-action="ZERO"]').disabled,'second scale independent');
  Object.assign(scales[0],{request_id:posted.request_id,phase:'COMPLETE',reason:'OK',zero_ready:true,status:'AWAITING_MASS'});render(fixture);
  check(document.getElementById('weightMessage1').textContent.includes('已完成'),'terminal status');
  document.getElementById('weightMass1').value='';await weightAction(1,'MASS');check(calls===1,'bad mass not sent');
  document.getElementById('weightMass1').value='100';await weightAction(1,'MASS');check(posted.grams===100,'mass command');
  Object.assign(scales[0],{request_id:posted.request_id,phase:'FAILED',reason:'SAMPLE_TIMEOUT'});render(fixture);
  check(document.getElementById('weightMessage1').textContent.includes('逾時'),'failure shown');
  Object.assign(scales[0],{calibrated:true,status:'STABLE',grams:12.3,stable_g:12.3,stable_age_ms:0});render(fixture);
  check(document.getElementById('weightValue1').textContent==='12.3 g','live weight');
  Object.assign(scales[0],{status:'CHANGE_PENDING',grams:null});render(fixture);
  check(document.getElementById('weightValue1').textContent==='—','pending change is not live weight');
  check(document.getElementById('weightState1').textContent.includes('變動確認中'),'change explanation');
  check(document.getElementById('weightStable1').textContent.includes('保留值'),'old trusted value labeled during change');
  Object.assign(scales[0],{status:'CALIBRATING',progress:20,reason:'WAIT_EMPTY_STABLE'});render(fixture);
  check(document.getElementById('weightState1').textContent.includes('晃動'),'calibration wait explanation');
  Object.assign(scales[0],{status:'BIRD_INTERFERENCE',calibrated:true,calibration_independent:true});render(fixture);
  check(!document.querySelector('[data-channel="1"][data-weight-action="TARE"]').disabled,'manual tare not blocked by bird state');
  Object.assign(scales[0],{status:'VISION_UNAVAILABLE'});render(fixture);
  check(!document.querySelector('[data-channel="1"][data-weight-action="ZERO"]').disabled,'manual zero not blocked by missing vision');
  fixture.weightStale=true;render(fixture);
  check(document.getElementById('weightValue1').textContent==='—','stale not live');
  check(document.getElementById('weightRaw1').textContent==='—'&&!weightTrends.has(1),'stale raw and curve cleared');
  check(document.getElementById('weightStable1').textContent.includes('保留值'),'held weight labeled');
  check(document.querySelector('[data-channel="1"][data-weight-action="ZERO"]').disabled,'offline blocked');
  check(!testErrors.length,testErrors.join(';'));
  result.textContent='PASS: weight UI, confirmation, async completion, errors, stale, no feeding';
 }catch(e){result.textContent='FAIL: '+e.stack;}
},500);
</script>
'@
$html=$html.Replace('href="/style.css"','href="../../dashboard/style.css"').Replace('src="/vision.js"','src="../../dashboard/vision.js"').Replace('src="/weights.js"','src="../../dashboard/weights.js"').Replace('src="/app.js"','src="../../dashboard/app.js"').Replace('src="/visit-photos.js"','src="../../dashboard/visit-photos.js"').Replace('src="/navigation.js"','src="../../dashboard/navigation.js"')
$html=$html.Replace('<script src="../../dashboard/vision.js">',$bootstrap+'<script src="../../dashboard/vision.js">').Replace('</body>',$checks+'</body>')
$page=Join-Path $bin 'weight-dashboard-test.html';[IO.File]::WriteAllText($page,$html,[Text.UTF8Encoding]::new($false))
$chrome='C:\Program Files\Google\Chrome\Application\chrome.exe'
$profile=Join-Path $bin 'weight-chrome-profile'
$output=Join-Path $bin 'weight-dashboard-dom.txt'
$args=@('--headless=new','--window-size=1440,900','--disable-gpu','--no-first-run','--allow-file-access-from-files','--virtual-time-budget=2500','--dump-dom',('--user-data-dir="'+$profile+'"'),([Uri]$page).AbsoluteUri)
$proc=Start-Process -FilePath $chrome -ArgumentList $args -Wait -WindowStyle Hidden -PassThru -RedirectStandardOutput $output -RedirectStandardError (Join-Path $bin 'chrome-errors.txt')
$dom=[IO.File]::ReadAllText($output)
if($dom -notmatch '<pre id="test-result">PASS:'){throw ('Dashboard tests failed: '+$dom.Substring([Math]::Max(0,$dom.Length-2500)))}
Write-Output 'PASS: independent weight UI, calibration lifecycle, errors, stale and monitor-only controls'
