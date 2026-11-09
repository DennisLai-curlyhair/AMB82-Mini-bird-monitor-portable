$ErrorActionPreference='Stop'
$bin=Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null
$vs='C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$lines=@('@echo off',('call "'+$vs+'" >nul'),'cl /nologo /EHsc /std:c++14 /I "..\firmware\BirdFeederDemo" /Fo:bin\weight_core_test.obj /Fe:bin\weight_core_test.exe weight_core_test.cpp','if errorlevel 1 exit /b 1','bin\weight_core_test.exe','exit /b %errorlevel%')
[IO.File]::WriteAllLines((Join-Path $bin 'run-weight.cmd'),$lines,[Text.Encoding]::Default)
Push-Location $PSScriptRoot
try{& cmd.exe /d /c bin\run-weight.cmd}finally{Pop-Location}
if($LASTEXITCODE -ne 0){throw 'weight core tests failed'}
