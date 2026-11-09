$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin=Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null
$html=@'
<!doctype html><meta charset="utf-8"><video id="liveVideo"></video><p id="photoStatus"></p><pre id="test-result"></pre>
<script>
const video=document.getElementById('liveVideo');let lastState={visionStale:false,vision:{clockValid:true,photoCapture:true,boot:'a'.repeat(32)}};
let uploaded=0,lastBody=null,failures=[];
window.onerror=m=>failures.push(m);
Object.defineProperties(video,{videoWidth:{get:()=>640},videoHeight:{get:()=>360},paused:{get:()=>false},readyState:{get:()=>4}});
const source=document.createElement('canvas');source.width=640;source.height=360;
const ctx=source.getContext('2d');ctx.fillStyle='#9cab97';ctx.fillRect(0,0,640,360);
for(let y=72;y<288;y+=18)for(let x=128;x<512;x+=24){ctx.fillStyle=(Math.floor(x/24)+Math.floor(y/18))%2?'#c24b15':'#26333a';ctx.fillRect(x,y,24,18);}
const draw=CanvasRenderingContext2D.prototype.drawImage;
CanvasRenderingContext2D.prototype.drawImage=function(im,...args){return draw.call(this,im===video?source:im,...args);};
video.requestVideoFrameCallback=fn=>setTimeout(()=>fn(performance.now()),260);
const small=document.createElement('canvas');small.width=small.height=24;const sc=small.getContext('2d');sc.imageSmoothingEnabled=false;sc.drawImage(source,128,72,384,216,0,0,24,24);
let stamp=Date.now()+550;
window.fetch=async(url,opt)=>{
 if(url.includes('/images/'))return {ok:true,blob:async()=>new Promise(r=>small.toBlob(r))};
 if(url.endsWith('/photo-targets'))return {ok:true,json:async()=>({targets:[{key:'b'.repeat(64),sequence:6,boot:'a'.repeat(32),epoch:stamp/1000,bbox:[.2,.2,.8,.8],reference:'test.png'}],time_tolerance_ms:1200,max_error:.15})};
 if(url.endsWith('/photo')){lastBody=JSON.parse(opt.body);uploaded++;setTimeout(()=>window.verifyPhoto(),100);return {ok:true,json:async()=>({saved:true})};}
 throw Error(url);
};
</script><script src="../../dashboard/visit-photos.js"></script>
<script>
window.verifyPhoto=async()=>{
const out=document.getElementById('test-result');try{
 if(failures.length)throw Error(failures.join(';'));
 if(uploaded!==1)throw Error('expected one photo upload, got '+uploaded+'; '+document.getElementById('photoStatus').textContent);
 if(lastBody.sequence!==6||Math.abs(lastBody.captured_utc*1000-stamp)>1200)throw Error('bad reference/time association');
 const binary=Uint8Array.from(atob(lastBody.jpeg),c=>c.charCodeAt(0));const im=await createImageBitmap(new Blob([binary],{type:'image/jpeg'}));
 if(im.width!==640||im.height!==360)throw Error('bad full resolution');im.close();
 out.textContent='PASS: frame buffer, visual match, full JPEG, visit identity, time tolerance, duplicate suppression';
}catch(e){out.textContent='FAIL: '+e.stack;}
};
</script>
'@
$page=Join-Path $bin 'visit-photo-test.html';[IO.File]::WriteAllText($page,$html,[Text.UTF8Encoding]::new($false))
$output=Join-Path $bin 'visit-photo-dom.txt'
$args=@('--headless=new','--disable-gpu','--no-first-run','--allow-file-access-from-files','--virtual-time-budget=15000','--dump-dom',('--user-data-dir="'+(Join-Path $bin 'photo-chrome-profile')+'"'),([Uri]$page).AbsoluteUri)
$proc=Start-Process -FilePath 'C:\Program Files\Google\Chrome\Application\chrome.exe' -ArgumentList $args -Wait -WindowStyle Hidden -PassThru -RedirectStandardOutput $output -RedirectStandardError (Join-Path $bin 'photo-chrome-errors.txt')
$dom=[IO.File]::ReadAllText($output)
if($dom -notmatch '<pre id="test-result">PASS:'){throw ('Photo browser test failed: '+$dom.Substring([Math]::Max(0,$dom.Length-2200)))}
Write-Output 'PASS: photo frame buffer, matching, upload and duplicate suppression'
