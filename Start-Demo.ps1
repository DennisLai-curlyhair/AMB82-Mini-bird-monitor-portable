param(
    [string]$Port = '',
    [int]$WebPort = 8080,
    [switch]$Simulate,
    [switch]$NoBrowser,
    [string]$PythonPath = '',
    [switch]$NoArchive,
    [switch]$Offline,
    [string]$StopFile = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location $PSScriptRoot

$logs = [System.Collections.ArrayList]::new()
$lastDiagnosticLine = ''
$lastDiagnosticAt = [DateTime]::MinValue
$state = [ordered]@{
    weights = $null
    weightStale = $true
    vision = $null
    visionStale = $true
    visionSession = [Guid]::NewGuid().ToString('N')
    connected = $false
    birdPresent = $false
    proximity = 'NONE'
    score = 0
    area = 0.0
    visitId = 0
    decision = 'PENDING'
    nnCount = 0
    bbox = $null
    rtspUrl = ''
    lastSeen = ''
    logs = $logs
}

function Add-DemoLog([string]$message) {
    $stamp = (Get-Date).ToString('HH:mm:ss')
    [void]$logs.Add("$stamp  $message")
    while ($logs.Count -gt 60) { $logs.RemoveAt(0) }
    $state.lastSeen = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[$stamp] $message"
}

function Set-SimulatedEvent([string]$eventName) {
    switch ($eventName.ToLowerInvariant()) {
        'present' { $state.birdPresent=$true; $state.proximity='FAR'; $state.score=78; $state.area=0.035; $state.visitId=[int]$state.visitId+1; $state.decision='PENDING'; Add-DemoLog "模擬：偵測到鳥，來訪 #$($state.visitId)" }
        'near'    { if(-not $state.birdPresent){$state.visitId=[int]$state.visitId+1}; $state.birdPresent=$true; $state.proximity='NEAR'; $state.score=86; $state.area=0.105; $state.decision='PENDING'; Add-DemoLog '模擬：鳥正在靠近' }
        'close'   { if(-not $state.birdPresent){$state.visitId=[int]$state.visitId+1}; $state.birdPresent=$true; $state.proximity='CLOSE'; $state.score=92; $state.area=0.235; $state.decision='PENDING'; Add-DemoLog '模擬：鳥已靠近餵食區' }
        'clear'   { $state.birdPresent=$false; $state.proximity='NONE'; $state.score=0; $state.area=0.0; Add-DemoLog "模擬：來訪 #$($state.visitId) 結束" }
    }
}

$lastWeightAt=[DateTime]::MinValue
$lastWeightLogAt=[DateTime]::MinValue
$weightAcks=@{}
$lastVisionAt=[DateTime]::MinValue
$lastArchiveAt=[DateTime]::MinValue
$lastSyncAt=[DateTime]::MinValue
$serialBuffer=''
$recordDir=Join-Path $PSScriptRoot 'records'
New-Item -ItemType Directory -Force $recordDir | Out-Null
$recordPath=Join-Path $recordDir ('vision-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'.jsonl')
function Save-VisionRecord($kind,$payload) {
    $record=[ordered]@{received_utc=[DateTime]::UtcNow.ToString('o');session=$state.visionSession;kind=$kind;data=$payload}
    Add-Content -LiteralPath $recordPath -Value ($record|ConvertTo-Json -Depth 10 -Compress) -Encoding UTF8
}
function Sync-BoardTime {
    if($serial -and $serial.IsOpen){
        $serial.WriteLine('TIME '+[DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        $script:lastSyncAt=[DateTime]::UtcNow
    }
}

function Receive-SerialChunk([string]$chunk) {
    $script:serialBuffer += $chunk
    while(($end=$script:serialBuffer.IndexOf("`n")) -ge 0){
        $incoming=$script:serialBuffer.Substring(0,$end)
        $script:serialBuffer=$script:serialBuffer.Substring($end+1)
        Process-SerialLine $incoming
    }
    if($script:serialBuffer.Length -gt 65536){$script:serialBuffer='';Add-DemoLog '序列資料過長，已丟棄未完成訊息'}
}

$deleteAck=$null
$confidenceAck=$null
$similarityAck=$null
$thumbCache=@{}
$visitArchiveHashes=@{}
function Update-WeightFreshness {
    $state.weightStale=(-not $state.connected -or -not $state.weights -or ([DateTime]::UtcNow-$lastWeightAt).TotalSeconds -gt 3)
}
function ConvertTo-WeightCommand($data) {
    if([string]$data.request_id -cnotmatch '^[0-9a-f]{32}$'){throw '無效的重量操作識別碼'}
    if($data.channel -is [bool] -or $data.channel -notin @(1,2)){throw '請選擇 1 或 2 號秤'}
    $action=[string]$data.action
    if($action -cnotin @('ZERO','MASS','TARE','REMEASURE','CANCEL')){throw '不支援的重量操作'}
    if($action -in @('ZERO','TARE') -and ($data.confirm_empty -isnot [bool] -or $data.confirm_empty -ne $true)){throw '請確認空容器沒有內容物且沒有鳥'}
    $command="WEIGHT $($data.request_id) $($data.channel) $action"
    if($action -eq 'MASS'){
        $grams=[double]$data.grams
        if($data.grams -is [bool] -or [double]::IsNaN($grams) -or [double]::IsInfinity($grams) -or $grams -le 0 -or $grams -gt 1000000){throw '參考克數須為大於 0 且不超過 1000000 的有限數值'}
        $command+=' '+$grams.ToString('G12',[Globalization.CultureInfo]::InvariantCulture)
    }
    return $command
}
function Process-SerialLine([string]$line) {
    $line = $line.Trim()
    if(-not $line){ return }
    if($line.StartsWith('@WEIGHT ')){
        try{
            $w=$line.Substring(8)|ConvertFrom-Json
            if($w.version -ne 1 -or $w.boot -notmatch '^[0-9a-f]{32}$' -or @($w.channels).Count -ne 2 -or $w.channels[0].id -ne 1 -or $w.channels[1].id -ne 2){throw 'Invalid weight packet'}
            $state.weights=$w;$state.weightStale=$false;$script:lastWeightAt=[DateTime]::UtcNow
            if(($lastWeightAt-$lastWeightLogAt).TotalSeconds -ge 5){Save-VisionRecord 'weight' $w;$script:lastWeightLogAt=$lastWeightAt}
        }catch{Add-DemoLog '重量封包無效，等待下一筆有效資料'}
        return
    }
    if($line.StartsWith('@WEIGHT_ACK ')){
        try{
            $ack=$line.Substring(12)|ConvertFrom-Json
            if($ack.request_id -notmatch '^[0-9a-f]{32}$' -or $ack.channel -notin @(1,2) -or $ack.phase -notin @('ACCEPTED','COMPLETE','FAILED','REJECTED')){throw 'Invalid weight acknowledgement'}
            if($weightAcks.Count -ge 64 -and -not $weightAcks.ContainsKey($ack.request_id)){$weightAcks.Clear()}
            $weightAcks[$ack.request_id]=$ack;Save-VisionRecord 'weight_ack' $ack
        }catch{Add-DemoLog '重量操作回覆格式錯誤'}
        return
    }
    if($line.StartsWith('@VISIT ')){
        try{
            $visit=$line.Substring(7)|ConvertFrom-Json
            if($visit.boot -notmatch '^[0-9a-f]{32}$' -or [long]$visit.id -lt 1){throw 'Invalid visit identity'}
            $identity="$($visit.boot):$($visit.id)"
            $stable=$visit|Select-Object * -ExcludeProperty ms,epoch
            $signature=($stable|ConvertTo-Json -Compress -Depth 6)+':'+([long]$visit.epoch -gt 0)
            $sha=[Security.Cryptography.SHA256]::Create()
            try{$digest=[Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($signature)))}finally{$sha.Dispose()}
            if(-not $visitArchiveHashes.ContainsKey($identity) -or $visitArchiveHashes[$identity] -ne $digest){
                Save-VisionRecord 'visit' $visit
                if($visitArchiveHashes.Count -ge 1024){$visitArchiveHashes.Clear()}
                $visitArchiveHashes[$identity]=$digest
            }
        }catch{Add-DemoLog "到訪封包未保存：$($_.Exception.Message)"}
        return
    }
    if($line -match '^@CONFIDENCE (\d+) (OK|REJECTED)$'){
        $script:confidenceAck=@{value=[int]$Matches[1];result=$Matches[2]}
        Save-VisionRecord 'confidence_ack' $script:confidenceAck
        return
    }
    if($line -match '^@SIMILARITY (\d+) (OK|REJECTED)$'){
        $script:similarityAck=@{value=[int]$Matches[1];result=$Matches[2]}
        Save-VisionRecord 'similarity_ack' $script:similarityAck
        return
    }
    if($line.StartsWith('@THUMB ')){
        try{
            $photo=$line.Substring(7)|ConvertFrom-Json
            if($photo.width -ne 24 -or $photo.thumb -notmatch '^[a-fA-F0-9]{3456}$'){return}
            if(-not $state.vision -or $photo.day -ne $state.vision.day){return}
            $g=@($state.vision.groups|Where-Object {$_.generation -eq $photo.generation})
            if($g.Count -ne 1){return}
            $key="$($photo.day):$($photo.generation)"
            $script:thumbCache[$key]=$photo
            $g[0]|Add-Member -NotePropertyName thumb -NotePropertyValue $photo.thumb -Force
            $g[0]|Add-Member -NotePropertyName thumbWidth -NotePropertyValue 24 -Force
        }catch{Add-DemoLog '代表圖資料解析失敗'}
        return
    }
    if($line -match '^@GROUP_DELETE (\d+) (\d+) (OK|REJECTED)$'){
        $script:deleteAck=@{day=[uint32]$Matches[1];generation=[uint32]$Matches[2];result=$Matches[3]}
        Save-VisionRecord 'group_delete_ack' $script:deleteAck
        Add-DemoLog "群組刪除回覆：$($Matches[3])"
        return
    }
    if($line -eq '@SYSTEM BOOT'){
        $state.weights=$null;$state.weightStale=$true;$weightAcks.Clear()
        $script:thumbCache=@{}
        if($state.vision){Save-VisionRecord 'before_reset' $state.vision}
        $state.visionSession=[Guid]::NewGuid().ToString('N')
        $state.vision=$null;$state.visionStale=$true
        Add-DemoLog '板子重新啟動：本次開機統計重新開始'
        Sync-BoardTime;return
    }
    if($line.StartsWith('@VISION ')){
        try {
            $v=$line.Substring(8)|ConvertFrom-Json
            if($v.version -ne '0.3.0'){return}
            if($state.vision -and ($v.ms -lt $state.vision.ms)){
                $script:thumbCache=@{}
                Save-VisionRecord 'before_reset' $state.vision
                $state.visionSession=[Guid]::NewGuid().ToString('N')
            }
                        if($state.vision -and $state.vision.day -ne $v.day){Save-VisionRecord 'day_end' $state.vision}
            $activeKeys=@{}
            foreach($g in $v.groups){
                if($g.PSObject.Properties['generation']){
                    $key="$($v.day):$($g.generation)";$activeKeys[$key]=$true
                    if($thumbCache.ContainsKey($key)){
                        $g|Add-Member -NotePropertyName thumb -NotePropertyValue $thumbCache[$key].thumb -Force
                        $g|Add-Member -NotePropertyName thumbWidth -NotePropertyValue 24 -Force
                    }
                }
            }
            foreach($key in @($thumbCache.Keys)){if(-not $activeKeys.ContainsKey($key)){$thumbCache.Remove($key)}}
            $state.vision=$v;$state.visionStale=$false;$state.connected=$true
            if($v.PSObject.Properties['clockValid'] -and -not $v.clockValid -and ([DateTime]::UtcNow-$lastSyncAt).TotalSeconds -ge 2){Sync-BoardTime}
            $script:lastVisionAt=[DateTime]::UtcNow
            if(($script:lastVisionAt-$script:lastArchiveAt).TotalSeconds -ge 60){
                Save-VisionRecord 'snapshot' $v;$script:lastArchiveAt=$script:lastVisionAt
            }
        } catch {Add-DemoLog "視覺資料解析失敗：$($_.Exception.Message)"}
        return
    }
    if($line.StartsWith('@EVENT ')){
        try{
            $e=$line.Substring(7)|ConvertFrom-Json
            Save-VisionRecord 'event' $e
            Add-DemoLog "視覺事件 $($e.type)：到訪 #$($e.id)，外觀群 $($e.group)"
        }catch{Add-DemoLog '視覺事件格式錯誤'}
        return
    }
    if($line -match '^@SYSTEM RTSP (rtsp://.+)$') {
        $state.rtspUrl=$Matches[1]; Add-DemoLog "收到 RTSP 位址：$($state.rtspUrl)"; return
    }
    if($line -eq '@SYSTEM READY') { Add-DemoLog 'AMB82 系統已就緒'; Sync-BoardTime; return }
    if($line -eq '@SYSTEM UVC_CONNECTED') { Add-DemoLog 'AMB82 UVC 影像已連接'; return }
    if($line -eq '@SYSTEM UVC_DISCONNECTED') { Add-DemoLog 'AMB82 UVC 影像已中斷'; return }
    if($line -match '^@NN COUNT (\d+)$') {
        $state.nnCount=[int]$Matches[1]
        if($state.nnCount -eq 0){$state.bbox=$null}
        return
    }
    if($line -match '^@BBOX (\d+) ([0-9.]+) ([0-9.]+) ([0-9.]+) ([0-9.]+)$') {
        $culture=[Globalization.CultureInfo]::InvariantCulture
        $state.bbox=[ordered]@{
            score=[int]$Matches[1]
            xMin=[double]::Parse($Matches[2],$culture)
            yMin=[double]::Parse($Matches[3],$culture)
            xMax=[double]::Parse($Matches[4],$culture)
            yMax=[double]::Parse($Matches[5],$culture)
        }
        return
    }
    if($line -match '^@BIRD (PRESENT|UPDATE) (\d+) (\d+) ([0-9.]+) (FAR|NEAR|CLOSE)$') {
        $newVisit = ([int]$Matches[2] -ne [int]$state.visitId) -or (-not $state.birdPresent)
        $oldProximity = [string]$state.proximity
        $state.birdPresent=$true; $state.visitId=[int]$Matches[2]; $state.score=[int]$Matches[3]; $state.area=[double]::Parse($Matches[4],[Globalization.CultureInfo]::InvariantCulture); $state.proximity=$Matches[5]
        if($newVisit){$state.decision='PENDING'; Add-DemoLog "偵測到鳥，來訪 #$($state.visitId)"}
        elseif($oldProximity -ne $state.proximity){Add-DemoLog "鳥的位置變化：$oldProximity → $($state.proximity)"}
        return
    }
    if($line -match '^@BIRD CLEAR (\d+) (\w+)$') { $state.birdPresent=$false; $state.proximity='NONE'; $state.score=0; $state.area=0.0; Add-DemoLog "來訪 #$($Matches[1]) 結束，決策：$($Matches[2])"; return }
    if($line -match '^@DECISION (FEED|SKIP) (\d+)$') { $state.decision=$Matches[1]; Add-DemoLog "板端確認決策：$($Matches[1])，來訪 #$($Matches[2])"; return }
    if($line -match '^@ERROR (.+)$') { Add-DemoLog "AMB82 錯誤：$($Matches[1])"; return }
    if($line -match '(?i)error|fail|vipnn') {
        $now=[DateTime]::UtcNow
        if($script:lastDiagnosticLine -eq $line -and ($now-$script:lastDiagnosticAt).TotalSeconds -lt 5){return}
        $script:lastDiagnosticLine=$line; $script:lastDiagnosticAt=$now
        Add-DemoLog "板端診斷：$line"; return
    }
}

$serial = $null
if(-not $Simulate -and -not $Offline) {
    $available = @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object)
    if(-not $Port) { $Port = @($available | Where-Object {$_ -ne 'COM1'} | Select-Object -Last 1) }
    if($Port) {
        try {
            $serial = [System.IO.Ports.SerialPort]::new($Port,115200,'None',8,'One')
            $serial.NewLine = "`n"; $serial.ReadTimeout = 20; $serial.WriteTimeout = 500; $serial.Open()
            $state.connected=$true; Add-DemoLog "已連接 AMB82：$Port"
        } catch { Add-DemoLog "無法連接 $Port，改用模擬模式：$($_.Exception.Message)"; $serial=$null }
    } else { Add-DemoLog '沒有偵測到 AMB82 序列埠，使用模擬模式' }
} elseif($Offline) { Add-DemoLog '離線瀏覽：未連接開發板' } else { Add-DemoLog '已啟用純模擬模式' }

function Open-Rtsp {
    if(-not $state.rtspUrl){ Add-DemoLog '尚未取得 RTSP 位址'; return }
    $vlcCandidates=@("$env:ProgramFiles\VideoLAN\VLC\vlc.exe","${env:ProgramFiles(x86)}\VideoLAN\VLC\vlc.exe")
    $vlc=$vlcCandidates | Where-Object {$_ -and (Test-Path -LiteralPath $_)} | Select-Object -First 1
    if($vlc){ Start-Process -FilePath $vlc -ArgumentList @($state.rtspUrl); Add-DemoLog '已用 VLC 開啟 RTSP' }
    else { Set-Clipboard $state.rtspUrl; Add-DemoLog '未找到 VLC，RTSP 位址已複製到剪貼簿' }
}

function Send-HttpResponse($stream,[int]$status,[string]$contentType,[byte[]]$body) {
    $statusText = if($status -eq 200){'OK'}elseif($status -eq 404){'Not Found'}else{'Bad Request'}
    $header="HTTP/1.1 $status $statusText`r`nContent-Type: $contentType`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $headerBytes=[Text.Encoding]::ASCII.GetBytes($header); $stream.Write($headerBytes,0,$headerBytes.Length); $stream.Write($body,0,$body.Length); $stream.Flush()
}

$archivePort=$WebPort+2
$archiveProcess=$null
if(-not $Simulate -and -not $NoArchive){
    if(-not $PythonPath){
        $candidates=@((Join-Path $env:USERPROFILE 'anaconda3\python.exe'),(Join-Path $env:USERPROFILE 'miniconda3\python.exe'))
        $PythonPath=$candidates|Where-Object {Test-Path -LiteralPath $_}|Select-Object -First 1
        if(-not $PythonPath){
            $pythonCommand=Get-Command python -ErrorAction SilentlyContinue
            if($pythonCommand -and $pythonCommand.Source -notmatch 'WindowsApps'){$PythonPath=$pythonCommand.Source}
        }
    }
    if(-not $PythonPath){throw '找不到 Python 3.10+，請使用 -PythonPath 指定 python.exe'}
    $archiveReady=$false
    try{
        $health=Invoke-RestMethod "http://127.0.0.1:$archivePort/history/health" -TimeoutSec 2
        $archiveReady=$health.service -eq 'bird-visit-archive'
    }catch{}
    if(-not $archiveReady){
        $archiveArgs=@('-u',('"'+(Join-Path $PSScriptRoot 'archive\server.py')+'"'),'--data',('"'+(Join-Path $PSScriptRoot 'data')+'"'),'--records',('"'+$recordDir+'"'),'--port',"$archivePort")
        $archiveProcess=Start-Process -FilePath $PythonPath -ArgumentList $archiveArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $recordDir 'archive-out.log') -RedirectStandardError (Join-Path $recordDir 'archive-error.log')
        for($i=0;$i -lt 30;$i++){
            try{$health=Invoke-RestMethod "http://127.0.0.1:$archivePort/history/health" -TimeoutSec 1;if($health.ok){$archiveReady=$true;break}}catch{}
            Start-Sleep -Milliseconds 100
        }
        if(-not $archiveReady){throw '到訪資料服務啟動失敗，請檢查 records/archive-error.log'}
    }
    Add-DemoLog '每日到訪檔案已啟動：/history/'
}
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$WebPort)
$listener.Start(); Add-DemoLog "Dashboard：http://localhost:$WebPort"
if(-not $NoBrowser){ Start-Process "http://localhost:$WebPort" }

try {
    while($true) {
        if($StopFile -and (Test-Path -LiteralPath $StopFile)){break}
        if($serial -and $serial.IsOpen) {
            try {
                Receive-SerialChunk $serial.ReadExisting()
                if(([DateTime]::UtcNow-$lastSyncAt).TotalSeconds -ge 60){Sync-BoardTime}
            }catch{$state.connected=$false;$state.visionStale=$true;Add-DemoLog "序列連線失敗：$($_.Exception.Message)";$serial.Close()}
        }
        if($state.vision -and ([DateTime]::UtcNow-$lastVisionAt).TotalSeconds -gt 3){
            $state.visionStale=$true;$state.birdPresent=$false;$state.bbox=$null
        }
        Update-WeightFreshness
        if(-not $listener.Pending()){ Start-Sleep -Milliseconds 25; continue }
        $client=$listener.AcceptTcpClient()
        try {
            $reader=$null
            $stream=$client.GetStream();$stream.ReadTimeout=5000;$stream.WriteTimeout=10000
            $headerBytes=[Collections.Generic.List[byte]]::new()
            while($true){
                $b=$stream.ReadByte();if($b -lt 0){throw 'Incomplete HTTP header'}
                $headerBytes.Add([byte]$b);$n=$headerBytes.Count
                if($n -ge 4 -and $headerBytes[$n-4] -eq 13 -and $headerBytes[$n-3] -eq 10 -and $headerBytes[$n-2] -eq 13 -and $headerBytes[$n-1] -eq 10){break}
                if($n -gt 65536){throw 'HTTP header too large'}
            }
            $lines=[Text.Encoding]::ASCII.GetString($headerBytes.ToArray()) -split '\r\n'
            $parts=$lines[0].Split(' ');$method=$parts[0];$path=$parts[1].Split('?')[0];$contentLength=0
            foreach($line in $lines){if($line -match '^Content-Length:\s*(\d+)$'){$contentLength=[int]$Matches[1]}}
            if($contentLength -gt $(if($path -eq '/history/api/photo'){4000000}else{1000000})){throw 'HTTP body too large'}
            $bodyBytes=New-Object byte[] $contentLength;$read=0
            while($read -lt $contentLength){$n=$stream.Read($bodyBytes,$read,$contentLength-$read);if($n -le 0){throw 'Incomplete HTTP body'};$read+=$n}
            $bodyText=[Text.Encoding]::UTF8.GetString($bodyBytes)
            if($path -eq '/history' -or $path.StartsWith('/history/')){
                try{
                    $forward=[Net.HttpWebRequest]::Create("http://127.0.0.1:$archivePort"+$parts[1])
                    $forward.Method=$method;$forward.Timeout=10000
                    if($method -eq 'POST'){
                        $bytes=[Text.Encoding]::UTF8.GetBytes($bodyText)
                        $forward.ContentType='application/json';$forward.ContentLength=$bytes.Length
                        $out=$forward.GetRequestStream();try{$out.Write($bytes,0,$bytes.Length)}finally{$out.Dispose()}
                    }
                    try{$remote=$forward.GetResponse()}catch [Net.WebException]{if($_.Exception.Response){$remote=$_.Exception.Response}else{throw}}
                    $memory=[IO.MemoryStream]::new()
                    try{$remote.GetResponseStream().CopyTo($memory);Send-HttpResponse $stream ([int]$remote.StatusCode) $remote.ContentType $memory.ToArray()}finally{$memory.Dispose();$remote.Dispose()}
                }catch{Send-HttpResponse $stream 503 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('{"error":"歷史服務尚未啟動，請重新啟動監控服務"}'))}
                continue
            }
            if($method -eq 'GET' -and $path -eq '/api/status') {
                $json=$state | ConvertTo-Json -Depth 5 -Compress; Send-HttpResponse $stream 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json)); continue
            }
            if($method -eq 'POST' -and $path -eq '/api/weights/action'){
                try{
                    $data=$bodyText|ConvertFrom-Json
                    $command=ConvertTo-WeightCommand $data
                    if(-not $serial -or -not $serial.IsOpen -or $state.weightStale -or -not $state.weights){throw '重量資料未連線或已過期，需燒錄雙秤韌體並確認連線'}
                    if($data.boot -ne $state.weights.boot){throw '開發板已重啟，請重新確認重量狀態'}
                    $id=[string]$data.request_id
                    if(-not $weightAcks.ContainsKey($id)){
                        Save-VisionRecord 'weight_command' $data;$serial.WriteLine($command)
                        $until=[DateTime]::UtcNow.AddSeconds(2)
                        while([DateTime]::UtcNow -lt $until){
                            Receive-SerialChunk $serial.ReadExisting()
                            if($weightAcks.ContainsKey($id)){break}
                            Start-Sleep -Milliseconds 10
                        }
                    }
                    if(-not $weightAcks.ContainsKey($id)){throw '操作結果未確認；請查看校正狀態，不會自動重送'}
                    $ack=$weightAcks[$id]
                    if($ack.boot -ne $data.boot -or $ack.channel -ne $data.channel){throw '回覆不屬於本次開機或指定秤'}
                    $reply=@{ok=($ack.phase -in @('ACCEPTED','COMPLETE'));ack=$ack}|ConvertTo-Json -Depth 5 -Compress
                    $status=200
                }catch{$reply=@{ok=$false;error=$_.Exception.Message}|ConvertTo-Json -Compress;$status=400}
                Send-HttpResponse $stream $status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($reply));continue
            }
            if($method -eq 'POST' -and $path -eq '/api/confidence'){
                try{
                    $data=$bodyText|ConvertFrom-Json
                    if(-not $serial -or -not $serial.IsOpen -or $state.visionStale -or -not $state.vision){throw '開發板未連線或資料過期'}
                    if(-not $state.vision.PSObject.Properties['confidenceControl'] -or -not $state.vision.confidenceControl){throw '需燒錄新版韌體才能套用分群門檻'}
                    $value=[int]$data.value
                    if($value -lt 20 -or $value -gt 100 -or $value -ne $data.value){throw '門檻必須為 20 到 100 的整數'}
                    $script:confidenceAck=$null
                    $serial.WriteLine("CONFIDENCE $value")
                    $until=[DateTime]::UtcNow.AddSeconds(4)
                    while([DateTime]::UtcNow -lt $until){
                        Receive-SerialChunk $serial.ReadExisting()
                        if($confidenceAck -and $confidenceAck.value -eq $value){break}
                        Start-Sleep -Milliseconds 20
                    }
                    if(-not $confidenceAck -or $confidenceAck.value -ne $value -or $confidenceAck.result -ne 'OK'){throw '板端尚未確認套用，請檢查目前門檻後重試'}
                    $reply='{"ok":true}';$status=200
                }catch{$reply=@{ok=$false;error=$_.Exception.Message}|ConvertTo-Json -Compress;$status=400}
                Send-HttpResponse $stream $status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($reply));continue
            }
            if($method -eq 'POST' -and $path -eq '/api/similarity'){
                try{
                    $data=$bodyText|ConvertFrom-Json
                    if(-not $serial -or -not $serial.IsOpen -or $state.visionStale -or -not $state.vision){throw '開發板未連線或資料過期'}
                    if(-not $state.vision.PSObject.Properties['similarityControl'] -or -not $state.vision.similarityControl){throw '需燒錄新版韌體才能套用分群門檻'}
                    $value=[int]$data.value
                    if($value -lt 0 -or $value -gt 100 -or $value -ne $data.value){throw '門檻必須為 0 到 100 的整數'}
                    $script:similarityAck=$null
                    $serial.WriteLine("SIMILARITY $value")
                    $until=[DateTime]::UtcNow.AddSeconds(4)
                    while([DateTime]::UtcNow -lt $until){
                        Receive-SerialChunk $serial.ReadExisting()
                        if($similarityAck -and $similarityAck.value -eq $value){break}
                        Start-Sleep -Milliseconds 20
                    }
                    if(-not $similarityAck -or $similarityAck.value -ne $value -or $similarityAck.result -ne 'OK'){throw '板端尚未確認套用，請檢查目前門檻後重試'}
                    $reply='{"ok":true}';$status=200
                }catch{$reply=@{ok=$false;error=$_.Exception.Message}|ConvertTo-Json -Compress;$status=400}
                Send-HttpResponse $stream $status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($reply));continue
            }
            if($method -eq 'POST' -and $path -eq '/api/groups/delete'){
                try {
                    $data=$bodyText|ConvertFrom-Json
                    if(-not $serial -or -not $serial.IsOpen -or $state.visionStale -or -not $state.vision){throw '開發板未連線或資料過期'}
                    if(-not $state.vision.PSObject.Properties['deleteGroups'] -or -not $state.vision.deleteGroups){throw '請先燒錄支援刪除的新版韌體'}
                    if([string]$data.session -ne $state.visionSession -or [uint32]$data.day -ne $state.vision.day){throw '資料已換日或重置，請重新選擇'}
                    $generation=[uint32]$data.generation
                    if(-not @($state.vision.groups|Where-Object {$_.generation -eq $generation}).Count){throw '群組不存在'}
                    $script:deleteAck=$null
                    Save-VisionRecord 'group_delete_request' $data
                    $serial.WriteLine("DELETE_GROUP $($state.vision.day) $generation")
                    $until=[DateTime]::UtcNow.AddSeconds(4)
                    while([DateTime]::UtcNow -lt $until){
                        Receive-SerialChunk $serial.ReadExisting()
                        if($deleteAck -and $deleteAck.day -eq $data.day -and $deleteAck.generation -eq $generation){break}
                        Start-Sleep -Milliseconds 20
                    }
                    if(-not $deleteAck -or $deleteAck.day -ne $data.day -or $deleteAck.generation -ne $generation){throw '等待板端回覆逾時；請查看最新群組狀態'}
                    if($deleteAck.result -ne 'OK'){throw '板端拒絕刪除：群組可能已變更'}
                    $reply='{"ok":true}';$status=200
                }catch{$reply=@{ok=$false;error=$_.Exception.Message}|ConvertTo-Json -Compress;$status=400}
                Send-HttpResponse $stream $status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($reply));continue
            }
            if($Simulate -and $method -eq 'POST' -and $path -eq '/api/simulate') { $data=$bodyText|ConvertFrom-Json; Set-SimulatedEvent $data.event; Send-HttpResponse $stream 200 'application/json' ([Text.Encoding]::UTF8.GetBytes('{"ok":true}')); continue }
            if($method -eq 'POST' -and $path -eq '/api/open-rtsp') { Open-Rtsp; Send-HttpResponse $stream 200 'application/json' ([Text.Encoding]::UTF8.GetBytes('{"ok":true}')); continue }
            $files=@{'/'='index.html';'/index.html'='index.html';'/style.css'='style.css';'/app.js'='app.js';'/vision.js'='vision.js';'/visit-photos.js'='visit-photos.js';'/navigation.js'='navigation.js';'/weights.js'='weights.js'}
            if($method -eq 'GET' -and $files.ContainsKey($path)) { $file=Join-Path "$PSScriptRoot\dashboard" $files[$path]; $mime=if($path -eq '/style.css'){'text/css; charset=utf-8'}elseif($path -in @('/app.js','/vision.js','/visit-photos.js','/navigation.js','/weights.js')){'application/javascript; charset=utf-8'}else{'text/html; charset=utf-8'}; Send-HttpResponse $stream 200 $mime ([IO.File]::ReadAllBytes($file)); continue }
            Send-HttpResponse $stream 404 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('Not found'))
        } catch { Write-Warning $_ } finally { if($reader){$reader.Dispose()}; $client.Dispose() }
    }
} finally {
    if($state.vision){Save-VisionRecord 'shutdown' $state.vision}
    if($archiveProcess -and -not $archiveProcess.HasExited){Stop-Process -Id $archiveProcess.Id -ErrorAction SilentlyContinue}
    $listener.Stop(); if($serial){if($serial.IsOpen){$serial.Close()};$serial.Dispose()}
}
