param([switch]$Stop,[switch]$Offline,[switch]$NoBrowser,[int]$WebPort=0)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$lock=$null
$stopFile=Join-Path $root '.stop-request'
if($Stop){[IO.File]::WriteAllText($stopFile,'stop');Write-Host 'Stop requested.';exit}
try {
    $lock=[IO.File]::Open((Join-Path $root '.instance-lock'),'OpenOrCreate','ReadWrite','None')
    $cfg=Get-Content -LiteralPath (Join-Path $root 'settings.json') -Raw | ConvertFrom-Json
    if($WebPort -eq 0){$WebPort=[int]$cfg.web_port}
    if($WebPort -lt 1024 -or $WebPort -gt 65533){throw 'Invalid web_port (1024..65533).'}
    foreach($n in @($WebPort,($WebPort+2))){
        $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$n)
        try{$probe.Start()}catch{throw "Port $n is in use. Stop the other service first."}finally{$probe.Stop()}
    }
    $port=[string]$cfg.serial_port
    if(-not $Offline -and $port -eq 'auto'){
        $ports=@([IO.Ports.SerialPort]::GetPortNames() | Where-Object {$_ -ne 'COM1'})
        if($ports.Count -gt 1){throw ('Multiple serial ports: '+($ports -join ', ')+'. Set serial_port in settings.json.')}
        if($ports.Count -eq 1){$port=$ports[0]}else{$Offline=$true;$port=''}
    }
    if(Test-Path -LiteralPath $stopFile){Remove-Item -LiteralPath $stopFile}
    & (Join-Path $root 'Start-Demo.ps1') -Port $port -WebPort $WebPort -PythonPath (Join-Path $root 'runtime/python.exe') -Offline:$Offline -NoBrowser:$NoBrowser -StopFile $stopFile
} finally {if($lock){$lock.Dispose()}}
