$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin=Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null
$vs='C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
if(-not(Test-Path -LiteralPath $vs)){throw 'Install Visual Studio C++ Build Tools or compile visual_core_test.cpp with a C++14 compiler.'}
$batch=Join-Path $bin 'run-core.cmd'
$lines=@('@echo off',('call "'+$vs+'" >nul'),
 'cl /nologo /EHsc /std:c++14 /I "..\firmware\BirdFeederDemo" /Fo:bin\visual_core_test.obj /Fe:bin\visual_core_test.exe visual_core_test.cpp /link /STACK:8388608',
 'if errorlevel 1 exit /b 1','bin\visual_core_test.exe','exit /b %errorlevel%')
[IO.File]::WriteAllLines($batch,$lines,[Text.Encoding]::Default)
Push-Location $PSScriptRoot
try { & cmd.exe /d /c bin\run-core.cmd } finally { Pop-Location }
if($LASTEXITCODE -ne 0){throw 'core tests failed'}
& (Join-Path $PSScriptRoot 'Test-VisualBridge.ps1')
