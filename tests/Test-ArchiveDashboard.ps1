$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin=Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null
$html=[IO.File]::ReadAllText((Join-Path $root 'archive/index.html'))
$bootstrap=@'
<script>
window.fixture={visits:[{key:'abc',track:1,local_time:'2026-10-21T09:00:00+08:00',time_uncertain:false,duration_ms:5000,peak:90,threshold:60,image:'test.png',group_label:'unassigned',end_status:'ended',excluded:0,reason:'',auto_group:'original'}],stats:{total:1,valid:1,excluded:0,missing_images:0,uncertain_time:0},groups:[],last_ingest:'2026-10-21T01:00:00Z',last_error:null,max_evictions:0};
window.lastRequest=null;window.confirm=()=>true;
window.fetch=async(path,options)=>{
 if(options){lastRequest=JSON.parse(options.body);if(lastRequest.key){fixture.visits=fixture.visits.filter(r=>r.key!==lastRequest.key);fixture.stats.total=fixture.visits.length;return {ok:true,json:async()=>({ok:true,affected:1})};}if(lastRequest.action==='assign'){fixture.visits[0].group_label=lastRequest.name;fixture.groups=[{id:'manual',name:lastRequest.name}];}return {ok:true,json:async()=>({ok:true,affected:1})};}
 return {ok:true,json:async()=>fixture};
};
</script>
'@
$html=$html.Replace('src="/history/navigation.js"','src="../../dashboard/navigation.js"')
$html=$html.Replace('<script>',$bootstrap+'<script>')
$checks=@'
<script>
setTimeout(async()=>{
 const output=document.createElement('pre');output.id='test-result';document.body.append(output);
 try{
  const check=(ok,msg)=>{if(!ok)throw Error(msg);};await load();
  check(document.querySelectorAll('.card').length===1,'visit card');
  check(!document.getElementById('export')&&!document.getElementById('assign')&&!document.getElementById('exclude'),'read only visits');
  check(document.querySelector('.card img').getAttribute('src').endsWith('test.png'),'thumbnail fallback');
  const groupLink=document.querySelector('.card div a');check(groupLink.getAttribute('href').includes('/history/groups?'),'group navigation');
  fixture.visits[0].photo={crop_image:'crop.jpg',full_image:'full.jpg',width:1280,height:720,crop_width:384,crop_height:216,captured_utc:1792621200,delta:.2};
  await load();check(document.querySelector('.card img').getAttribute('src').endsWith('crop.jpg'),'large crop preferred');
  document.querySelector('.card>a').click();check(document.getElementById('viewer').open,'photo viewer');
  check(document.getElementById('full').getAttribute('href').endsWith('full.jpg'),'full image link');
  check(document.getElementById('photoNote').textContent.includes('近似配對'),'match caveat in viewer');
  document.getElementById('close').click();check(!document.getElementById('viewer').open,'viewer close');
  document.getElementById('allDates').checked=true;document.getElementById('allDates').dispatchEvent(new Event('change'));await load();
  check(document.getElementById('date').disabled,'all dates filter');
  check(document.querySelectorAll('nav a').length===3,'consistent navigation');
  let focused=false,reloaded=false;
  const previousOpen=window.open;
  window.open=(url,target)=>{check(url===''&&target==='bird-monitor','reuse named monitor window');return {location:{origin:location.origin,pathname:'/',set href(v){reloaded=true;}},focus(){focused=true;}};};
  document.querySelector('nav a[href="/"]').click();
  check(focused&&!reloaded,'return to monitor focuses without reload');
  window.open=previousOpen;
  offset=48;await load();check(offset===0,'out of range page corrected');
  const deletion=document.querySelector('.card .delete-visit');check(!!deletion,'delete button present');
  const previousRequest=lastRequest;window.confirm=()=>false;await deletion.onclick();check(lastRequest===previousRequest,'cancel makes no request');
  window.confirm=()=>true;await deletion.onclick();check(!!lastRequest.key,'delete sends exact visit key');
  check(!document.querySelector('.card'),'deleted visit removed');check(document.getElementById('summary').textContent==='0 次到訪','total adjusted');
  check(!document.querySelector('.card .delete-visit'),'no repeat delete button');
  output.textContent='PASS: history photos, dated group links, monitor focus without reload';
 }catch(e){output.textContent='FAIL: '+e.stack;}
},500);
</script>
'@
$html=$html.Replace('</html>',$checks+'</html>')
$page=Join-Path $bin 'archive-dashboard-test.html';[IO.File]::WriteAllText($page,$html,[Text.UTF8Encoding]::new($false))
$chrome='C:\Program Files\Google\Chrome\Application\chrome.exe'
$out=Join-Path $bin 'archive-dashboard-dom.txt'
$args=@('--headless=new','--disable-gpu','--no-first-run','--window-size=1440,900','--virtual-time-budget=2500','--dump-dom',('--user-data-dir="'+(Join-Path $bin 'archive-chrome-profile')+'"'),([Uri]$page).AbsoluteUri)
$proc=Start-Process -FilePath $chrome -ArgumentList $args -Wait -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError (Join-Path $bin 'archive-chrome-error.txt')
$dom=[IO.File]::ReadAllText($out)
if($dom -notmatch '<pre id="test-result">PASS:'){throw ('Archive dashboard failed: '+$dom.Substring([Math]::Max(0,$dom.Length-1800)))}
Write-Output 'PASS: read-only visit history, photo viewer, group links and date filter'
