$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin=Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null
$html=[IO.File]::ReadAllText((Join-Path $root 'archive/group-gallery.html'))
$bootstrap=@'
<script>
const a='auto:aaaaaaaa:20748:1',b='auto:aaaaaaaa:20748:2';
window.fixture=[{key:'one',track:1,auto_group:'aaaaaaaa:20748:1',manual_group:null,bucket:a,local_time:'2026-10-22T09:00:00+08:00',image:'small.png',photo:{crop_image:'crop.jpg',full_image:'full.jpg',width:1280,height:720,crop_width:300,crop_height:200},duration_ms:4000,peak:90,end_status:'已離開'},
{key:'two',track:2,auto_group:'aaaaaaaa:20748:2',manual_group:null,bucket:b,local_time:'2026-10-22T10:00:00+08:00',image:'two.png',duration_ms:4000,peak:90,end_status:'已離開'}];
window.lastRequest=null;window.confirm=()=>true;window.historyCopies=[];
window.fetch=async(url,options)=>{
 if(options){lastRequest=JSON.parse(options.body);if(lastRequest.key){fixture=fixture.filter(r=>r.key!==lastRequest.key);return {ok:true,json:async()=>({ok:true,affected:1})};}
  if(lastRequest.action==='undo'){fixture=historyCopies.pop();return {ok:true,json:async()=>({ok:true,undone:1})};}
  historyCopies.push(structuredClone(fixture));
  for(const r of fixture)if(lastRequest.keys.includes(r.key)){r.bucket=lastRequest.name?'manual:new':(lastRequest.group||'auto:'+r.auto_group);r.manual_group=lastRequest.group;}
  return {ok:true,json:async()=>({ok:true,affected:lastRequest.keys.length})};
 }
 const q=new URL(url,'http://localhost').searchParams,group=q.get('group');
 const groups=[...new Set(fixture.map(r=>r.bucket))].map(id=>({id,name:id===a?'群 A':id===b?'群 B':'新群',count:fixture.filter(r=>r.bucket===id).length,photo_count:1,first:'2026-10-22T09:00',last:'2026-10-22T10:00',preview:'crop.jpg'}));
 return {ok:true,json:async()=>({dates:fixture.length?[{date:'2026-10-22',visits:fixture.length}]:[],groups,targets:groups,visits:fixture.filter(r=>r.bucket===group),total:fixture.filter(r=>r.bucket===group).length,total_visits:fixture.length})};
};
</script>
'@
$html=$html.Replace('src="/history/navigation.js"','src="../../dashboard/navigation.js"')
$html=$html.Replace('<script>',$bootstrap+'<script>')
$checks=@'
<script>
setTimeout(async()=>{
 const out=document.createElement('pre');out.id='test-result';document.body.append(out);
 try{
  const check=(ok,msg)=>{if(!ok)throw Error(msg);};
  await load();check(document.querySelectorAll('.group').length===2,'group cards');
  check(document.getElementById('date').value==='2026-10-22'&&!document.getElementById('allDates'),'date-first latest default');
  check(document.querySelector('.visit img').getAttribute('src').endsWith('crop.jpg'),'large crop displayed');
  document.querySelector('.visit a').click();check(document.getElementById('viewer').open,'large photo modal');document.getElementById('closeViewer').click();
  [...document.querySelectorAll('.visit button')].find(b=>b.textContent.includes('完整畫面')).click();check(document.getElementById('viewImage').src.endsWith('full.jpg'),'full frame modal');document.getElementById('closeViewer').click();
  check(document.getElementById('selectionTools').hidden,'move tools initially hidden');
  document.querySelector('.visit input').click();check(!document.getElementById('selectionTools').hidden,'selection reveals move tools');document.getElementById('target').value=b;await change('move');
  check(document.getElementById('selectionTools').hidden,'tools hidden after move');
  check(lastRequest.keys[0]==='one'&&lastRequest.group===b,'auto target assignment');check(!selected.size,'selection cleared');check(document.querySelectorAll('.visit').length===2,'empty source switches to remaining group');
  current=b;await load();check(document.querySelectorAll('.visit').length===2,'target has both visits');
  document.querySelector('.visit input').click();document.getElementById('name').value='新鳥群';await change('move');check(lastRequest.name==='新鳥群','new group assignment');
  await change('undo');check(document.querySelectorAll('.visit').length===2,'undo restores target');
  const deletion=document.querySelector('.visit .delete-visit');check(!!deletion,'delete button present');
  const previousRequest=lastRequest;window.confirm=()=>false;await deletion.onclick();check(lastRequest===previousRequest,'cancel makes no request');
  window.confirm=()=>true;await deletion.onclick();check(!!lastRequest.key,'delete sends exact visit key');
  check(fixture.length===1&&document.querySelectorAll('.visit').length===1,'visit removed and other visit preserved');
  check(document.getElementById('summary').textContent.includes('1 次到訪'),'album total adjusted');
  check(document.getElementById('date').selectedOptions[0].textContent.includes('1 次到訪'),'date count adjusted');
  await document.querySelector('.delete-visit').onclick();
  check(!document.querySelector('.group')&&!document.querySelector('.visit'),'last visit removes empty group');
  check(document.getElementById('summary').textContent==='0 群 · 0 次到訪','empty archive totals');
  out.textContent='PASS: gallery photos, full frame modal, auto-to-auto move, new group and undo';
 }catch(e){out.textContent='FAIL: '+e.stack;}
},500);
</script>
'@
$html=$html.Replace('</html>',$checks+'</html>')
$page=Join-Path $bin 'group-gallery-test.html';[IO.File]::WriteAllText($page,$html,[Text.UTF8Encoding]::new($false))
$chrome='C:\Program Files\Google\Chrome\Application\chrome.exe'
$out=Join-Path $bin 'group-gallery-dom.txt'
$args=@('--headless=new','--disable-gpu','--no-first-run','--window-size=1440,900','--virtual-time-budget=2500','--dump-dom',('--user-data-dir="'+(Join-Path $bin 'gallery-chrome-profile')+'"'),([Uri]$page).AbsoluteUri)
$proc=Start-Process -FilePath $chrome -ArgumentList $args -Wait -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError (Join-Path $bin 'gallery-chrome-error.txt')
$dom=[IO.File]::ReadAllText($out)
if($dom -notmatch '<pre id="test-result">PASS:'){throw ('Group gallery failed: '+$dom.Substring([Math]::Max(0,$dom.Length-1800)))}
Write-Output 'PASS: group gallery photos, modal, move, new group and undo'
