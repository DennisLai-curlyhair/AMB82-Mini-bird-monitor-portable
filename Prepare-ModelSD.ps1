param([Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z]:$')][string]$Drive)
$ErrorActionPreference='Stop'
Set-Location $PSScriptRoot
$driveRoot="$Drive\"
if(-not (Test-Path -LiteralPath $driveRoot)){throw "找不到 SD 卡磁碟：$Drive"}
$source=Join-Path $PSScriptRoot 'birds_2@yolov7-tiny.nb'
if(-not (Test-Path -LiteralPath $source)){throw "找不到權重：$source"}
$folder=Join-Path $driveRoot 'NN_MDL'; New-Item -ItemType Directory -Force -Path $folder|Out-Null
$destination=Join-Path $folder 'yolov7_tiny.nb'; Copy-Item -LiteralPath $source -Destination $destination -Force
$a=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash; $b=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
if($a -ne $b){throw 'SD 卡模型驗證失敗'}
Write-Host "模型已安裝：$destination" -ForegroundColor Green
Write-Host "SHA-256：$($a.ToLower())"

