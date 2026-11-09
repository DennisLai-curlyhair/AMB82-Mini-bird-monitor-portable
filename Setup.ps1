$ErrorActionPreference='Stop'
Set-Location $PSScriptRoot
$tools=Join-Path $PSScriptRoot '.tools'; New-Item -ItemType Directory -Force $tools|Out-Null
$index='https://raw.githubusercontent.com/Ameba-AIoT/ameba-arduino-pro2/main/Arduino_package/package_realtek_amebapro2_index.json'
if(-not (Test-Path "$tools\cli\arduino-cli.exe")){Invoke-WebRequest -UseBasicParsing 'https://downloads.arduino.cc/arduino-cli/arduino-cli_1.5.1_Windows_64bit.zip' -OutFile "$tools\arduino-cli.zip"; Expand-Archive "$tools\arduino-cli.zip" "$tools\cli" -Force}
$config=@{directories=@{data="$tools\arduino-data";downloads="$tools\downloads";user="$tools\sketchbook"};board_manager=@{additional_urls=@($index)}}
$config|ConvertTo-Json -Depth 5|Set-Content "$tools\arduino-cli.yaml" -Encoding UTF8
$env:ARDUINO_DIRECTORIES_DATA="$tools\arduino-data"
& "$tools\cli\arduino-cli.exe" core update-index --config-file "$tools\arduino-cli.yaml"; if($LASTEXITCODE){throw '更新套件索引失敗'}
& "$tools\cli\arduino-cli.exe" core install realtek:AmebaPro2@4.1.0 --config-file "$tools\arduino-cli.yaml"; if($LASTEXITCODE){throw '安裝 AmebaPro2 SDK 失敗'}

