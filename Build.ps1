param(
  [switch]$Upload,
  [string]$Port = 'COM3',
  [string]$ToolsRoot = '',
  [string]$ModelPath = (Join-Path $PSScriptRoot 'birds_2@yolov7-tiny.nb')
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (-not $ToolsRoot) {
  $candidates = @(
    (Join-Path $PSScriptRoot '.tools'),
    (Join-Path (Split-Path $PSScriptRoot -Parent) '物聯網作業一\.tools')
  )
  $ToolsRoot = $candidates | Where-Object { Test-Path "$_\cli\arduino-cli.exe" } | Select-Object -First 1
}
if (-not $ToolsRoot) { throw '找不到 Arduino CLI/SDK，請先執行 Setup.ps1' }
if (-not (Test-Path -LiteralPath $ModelPath)) { throw "找不到自訂模型：$ModelPath" }

$ToolsRoot = (Resolve-Path $ToolsRoot).Path
$ModelPath = (Resolve-Path -LiteralPath $ModelPath).Path
$sdkData = Join-Path $ToolsRoot 'arduino-data'
$cli = Join-Path $ToolsRoot 'cli\arduino-cli.exe'
$nnManifest = Join-Path $sdkData 'packages\realtek\hardware\AmebaPro2\4.1.0\variants\common_nn_models\amebapro2_fwfs_nn_models.json'
if (-not (Test-Path -LiteralPath $nnManifest)) { throw "缺少 NN 模型清單：$nnManifest" }

# Realtek's validator always looks below USERPROFILE\AppData\Local\Arduino15.
$fakeProfile = Join-Path $ToolsRoot 'ameba-cli-profile'
$fakeLocal = Join-Path $fakeProfile 'AppData\Local'
$arduino15Link = Join-Path $fakeLocal 'Arduino15'
New-Item -ItemType Directory -Force $fakeLocal, (Join-Path $fakeProfile 'Documents') | Out-Null
if (-not (Test-Path -LiteralPath $arduino15Link)) {
  New-Item -ItemType Junction -Path $arduino15Link -Target $sdkData | Out-Null
}

$deployModel = Join-Path $PSScriptRoot 'firmware\BirdFeederDemo\yolov7_tiny.nb'
Copy-Item -LiteralPath $ModelPath -Destination $deployModel -Force
if ((Get-FileHash -LiteralPath $ModelPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $deployModel -Algorithm SHA256).Hash) {
  throw '部署模型複製後雜湊不一致'
}

$sdkMirror = Join-Path $sdkData 'packages\realtek\hardware\AmebaPro2\4.1.0\libraries\NeuralNetwork\examples\BirdFeederDemo'
New-Item -ItemType Directory -Force $sdkMirror | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'firmware\BirdFeederDemo\BirdFeederDemo.ino') -Destination $sdkMirror -Force
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'firmware\BirdFeederDemo') -Filter '*.h' |
  Where-Object { $_.Name -ne 'wifi_secrets.h' } |
  Copy-Item -Destination $sdkMirror -Force
Copy-Item -LiteralPath $deployModel -Destination $sdkMirror -Force
$mirrorCreated = $true

$free = @('P','Q','R','S','T','U','V') | Where-Object { -not (Test-Path "${_}:\") }
if ($free.Count -lt 2) { throw '沒有足夠的暫用磁碟代號' }
$projectLetter = $free[0]
$toolsLetter = $free[1]
subst.exe "${projectLetter}:" $PSScriptRoot | Out-Null
subst.exe "${toolsLetter}:" $ToolsRoot | Out-Null

$oldData = $env:ARDUINO_DIRECTORIES_DATA
$oldLang = $env:LANG
$oldLocale = $env:LC_ALL
$oldUserProfile = $env:USERPROFILE

# Chrome and Edge negotiate reliably when the UVC descriptor exposes MJPEG only.
# Keep the SDK change temporary so other Ameba examples retain their defaults.
$uvcdHeader = Join-Path $sdkData 'packages\realtek\hardware\AmebaPro2\4.1.0\libraries\USB\src\UVCD_pram.h'
$uvcdOriginal = $null

try {
  if (-not (Test-Path -LiteralPath $uvcdHeader)) { throw "UVC format header not found: $uvcdHeader" }
  $uvcdOriginal = [IO.File]::ReadAllText($uvcdHeader)
  $uvcdBrowser = $uvcdOriginal
  $uvcdBrowser = $uvcdBrowser -replace '#define VIDEO_FHD_WIDTH_UVCD\s+1920', '#define VIDEO_FHD_WIDTH_UVCD  1280'
  $uvcdBrowser = $uvcdBrowser -replace '#define VIDEO_FHD_HEIGHT_UVCD\s+1080', '#define VIDEO_FHD_HEIGHT_UVCD 720'
  $uvcdBrowser = $uvcdBrowser -replace '#define UVCD_YUY2\s+1', '#define UVCD_YUY2 0'
  $uvcdBrowser = $uvcdBrowser -replace '#define UVCD_NV12\s+1', '#define UVCD_NV12 0'
  $uvcdBrowser = $uvcdBrowser -replace '#define UVCD_MJPG\s+0', '#define UVCD_MJPG 1'
  $uvcdBrowser = $uvcdBrowser -replace '#define UVCD_H264\s+1', '#define UVCD_H264 0'
  $uvcdBrowser = $uvcdBrowser -replace '#define UVCD_H265\s+1', '#define UVCD_H265 0'
  [IO.File]::WriteAllText($uvcdHeader, $uvcdBrowser, [Text.UTF8Encoding]::new($false))

  $p = "${projectLetter}:"
  $t = "${toolsLetter}:"
  $env:LANG = 'C'
  $env:LC_ALL = 'C'
  $env:USERPROFILE = "$t\ameba-cli-profile"
  $env:ARDUINO_DIRECTORIES_DATA = "$t\arduino-data"
  New-Item -ItemType Directory -Force "$p\.build", "$p\build" | Out-Null
  $config = @{ directories = @{ data = "$t\arduino-data"; downloads = "$t\downloads"; user = "$p\.build\sketchbook" } }
  $config | ConvertTo-Json -Depth 4 | Set-Content "$p\.build\arduino-cli.yaml" -Encoding UTF8
  $fqbn = 'realtek:AmebaPro2:Ameba_AMB82-MINI:04_CameraOption=f37,06_LoadNNModelSource=flash,09_Ard_logs=EnableArdErrLogs,10_system_mm_logs=DisableVidAndNNLogs,11_system_wifi_logs=DisableWiFiLogs'
  & $cli compile --config-file "$p\.build\arduino-cli.yaml" --fqbn $fqbn --build-path "$p\build" "$p\firmware\BirdFeederDemo"
  if ($LASTEXITCODE) { throw '編譯失敗' }

  # The Realtek uploader writes the neural network to a separate flash partition.
  # Arduino CLI 4.1.0 updates the model manifest but may omit these two conversion
  # steps, which otherwise yields upload success while VIPNN has no model to load.
  $vendor = "$t\arduino-data\packages\realtek\tools\ameba_pro2_tools\1.4.7"
  $elf2bin = "$vendor\misc\elf2bin.win.exe"
  $modelFolder = Split-Path -Parent $nnManifest
  $fwfsModel = Join-Path $modelFolder 'fwfs_nn_model.bin'
  $nnImage = "$vendor\nn_model.bin"
  if (-not (Test-Path -LiteralPath $elf2bin)) { throw "找不到 NN 映像工具：$elf2bin" }
  Push-Location $modelFolder
  try {
    & $elf2bin convert 'amebapro2_fwfs_nn_models.json' FWFS 'fwfs_nn_model.bin'
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fwfsModel)) { throw '建立 FWFS NN 模型失敗' }
  } finally { Pop-Location }
  Copy-Item -LiteralPath $fwfsModel -Destination "$vendor\fwfs_nn_model.bin" -Force
  Push-Location $vendor
  try {
    & $elf2bin convert 'misc\nn_img\amebapro2_nn_model.json' FIRMWARE 'nn_model.bin'
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $nnImage)) { throw '建立 NN Flash 分割區映像失敗' }
  } finally { Pop-Location }
  Copy-Item -LiteralPath $nnImage -Destination "$p\build\nn_model.bin" -Force
  Write-Host "NN 映像完成：$p\build\nn_model.bin ($((Get-Item $nnImage).Length) bytes)" -ForegroundColor Cyan

  $image = "$p\build\flash_ntz.bin"
  if (-not (Test-Path $image)) { throw '找不到燒錄映像' }
  $hash = (Get-FileHash $image -Algorithm SHA256).Hash
  Write-Host "映像完成：$image ($((Get-Item $image).Length) bytes, SHA256 $hash)" -ForegroundColor Cyan

  if ($Upload) {
    $vendor = "$t\arduino-data\packages\realtek\tools\ameba_pro2_tools\1.4.7"
    Copy-Item $image "$vendor\flash_ntz.bin" -Force
    $uploadLines = @(& "$vendor\image_windows.exe" $vendor $Port Ameba_AMB82-MINI Disable Disable 921600 uartfwburn.exe Auto_Flash_Pro2_V3.3_win.exe 0x60000 0x460000 0x530000 2>&1)
    $uploadExitCode = $LASTEXITCODE
    $uploadLines | ForEach-Object { Write-Host $_ }
    $uploadText = $uploadLines -join [Environment]::NewLine
    if ($uploadExitCode -ne 0 -or $uploadText -notmatch 'upload success' -or $uploadText -match 'open fail|Create File Error|loading fail|nop fail|upload fail|ping fail|Uart boot fail') {
      throw '燒錄失敗，請關閉占用 COM 埠的程式，並確認板子已進入下載模式'
    }
    Write-Host '燒錄完成，請按 RESET。' -ForegroundColor Green
  }
}
finally {
  if ($null -ne $uvcdOriginal) {
    [IO.File]::WriteAllText($uvcdHeader, $uvcdOriginal, [Text.UTF8Encoding]::new($false))
  }
  if ($mirrorCreated -and (Test-Path -LiteralPath $sdkMirror)) {
    $resolvedMirror = (Resolve-Path -LiteralPath $sdkMirror).Path
    $expectedParent = (Resolve-Path -LiteralPath (Split-Path $sdkMirror -Parent)).Path
    if ($resolvedMirror -ne $sdkMirror -or -not $resolvedMirror.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase)) {
      throw "不安全的 SDK 暫存清理路徑：$resolvedMirror"
    }
    Remove-Item -LiteralPath $resolvedMirror -Recurse -Force
  }
  $env:ARDUINO_DIRECTORIES_DATA = $oldData
  $env:LANG = $oldLang
  $env:LC_ALL = $oldLocale
  $env:USERPROFILE = $oldUserProfile
  subst.exe "${projectLetter}:" /D | Out-Null
  subst.exe "${toolsLetter}:" /D | Out-Null
}
