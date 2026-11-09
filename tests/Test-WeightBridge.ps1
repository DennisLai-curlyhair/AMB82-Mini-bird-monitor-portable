$ErrorActionPreference='Stop'
$testRoot=Join-Path $PSScriptRoot 'bin'
$source=[IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'Start-Demo.ps1'))
$prefix=$source.Substring(0,$source.IndexOf('$serial = $null')).Replace('Set-Location $PSScriptRoot','')
$prefix=$prefix.Replace("Join-Path `$PSScriptRoot 'records'","Join-Path `$testRoot 'weight-records'")
. ([scriptblock]::Create($prefix)) -Simulate -NoBrowser
$serial=$null
function Check($ok,$why){if(-not $ok){throw $why}}
$id='1'*32;$boot='a'*32
$data=[pscustomobject]@{request_id=$id;boot=$boot;channel=1;action='MASS';grams=100.25;confirm_empty=$false}
Check ((ConvertTo-WeightCommand $data) -eq "WEIGHT $id 1 MASS 100.25") 'command serialization'
$data.action='ZERO'
$rejected=$false;try{ConvertTo-WeightCommand $data|Out-Null}catch{$rejected=$true};Check $rejected 'empty confirmation required'
$data.confirm_empty=$true
Check ((ConvertTo-WeightCommand $data) -eq "WEIGHT $id 1 ZERO") 'zero command'
$data.request_id="bad`nFEED"
$rejected=$false;try{ConvertTo-WeightCommand $data|Out-Null}catch{$rejected=$true};Check $rejected 'injected command accepted'
$data.request_id=$id;$data.action='MASS';$data.grams=[double]::NaN
$rejected=$false;try{ConvertTo-WeightCommand $data|Out-Null}catch{$rejected=$true};Check $rejected 'NaN mass accepted'
$packet='@WEIGHT {"version":1,"boot":"'+$boot+'","seq":1,"channels":[{"id":1,"grams":null},{"id":2,"grams":123.4}]}'
Receive-SerialChunk ($packet+[Environment]::NewLine)
Check ($state.weights.channels[0].grams -eq $null) 'uncalibrated value became zero'
Check ($state.weights.channels[1].grams -eq 123.4) 'other scale lost'
$state.connected=$true;Update-WeightFreshness;Check (-not $state.weightStale) 'fresh packet stale'
$lastWeightAt=[DateTime]::UtcNow.AddSeconds(-4);Update-WeightFreshness;Check $state.weightStale 'stale packet trusted'
Receive-SerialChunk ('@WEIGHT_ACK {"boot":"'+$boot+'","request_id":"'+$id+'","channel":1,"phase":"ACCEPTED","reason":"COLLECTING"}'+[Environment]::NewLine)
Check ($weightAcks[$id].phase -eq 'ACCEPTED') 'accepted not tracked'
Receive-SerialChunk ('@WEIGHT_ACK {"boot":"'+$boot+'","request_id":"'+$id+'","channel":1,"phase":"COMPLETE","reason":"OK"}'+[Environment]::NewLine)
Check ($weightAcks[$id].phase -eq 'COMPLETE') 'completion not tracked'
Receive-SerialChunk ('@SYSTEM BOOT'+[Environment]::NewLine)
Check ($null -eq $state.weights -and $weightAcks.Count -eq 0) 'boot retains obsolete scale state'
Write-Output 'PASS: weight commands, telemetry, stale, accepted/completed and reboot'
