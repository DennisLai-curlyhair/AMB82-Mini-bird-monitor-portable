$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Force $testRoot | Out-Null
$source=[IO.File]::ReadAllText((Join-Path $root 'Start-Demo.ps1'))
$prefix=$source.Substring(0,$source.IndexOf('$serial = $null'))
$prefix=$prefix.Replace('Set-Location $PSScriptRoot','')
$prefix=$prefix.Replace("Join-Path `$PSScriptRoot 'records'","Join-Path `$testRoot 'records'")
. ([scriptblock]::Create($prefix)) -Simulate -NoBrowser
$serial=$null
function Assert($ok,$message){if(-not $ok){throw $message}}
$json='{"version":"0.3.0","ms":1000,"day":20000,"dailyVisits":2,"tracks":[],"groups":[]}'
$packet='@VISION '+$json+"`n"
Receive-SerialChunk $packet.Substring(0,12)
Assert ($null -eq $state.vision) 'partial packet was parsed'
Receive-SerialChunk $packet.Substring(12)
Assert ($state.vision.dailyVisits -eq 2) 'split packet lost'
Assert (-not $state.visionStale) 'fresh packet marked stale'
$oldSession=$state.visionSession
Receive-SerialChunk ('@EVENT {"type":"START","id":1,"group":0}'+"`n")
Receive-SerialChunk ('@SYSTEM BOOT'+"`n")
Assert ($state.visionSession -ne $oldSession) 'reset reused session'
Assert ($null -eq $state.vision) 'reset retained old counts'
Assert $state.visionStale 'reset not stale'
Receive-SerialChunk $packet
Receive-SerialChunk ('@VISION '+$json.Replace('1000','900')+"`n")
Assert ($state.vision.ms -eq 900) 'new boot packet not accepted'
$records=Get-Content -LiteralPath $recordPath -Encoding UTF8 | ForEach-Object {$_|ConvertFrom-Json}
Assert (@($records|Where-Object {$_.kind -eq 'event'}).Count -eq 1) 'event not archived'
Assert (@($records|Where-Object {$_.kind -eq 'before_reset'}).Count -ge 1) 'reset snapshot not archived'
Write-Output 'PASS: fragmented serial JSON, events, boot/session reset, snapshot archive'

Receive-SerialChunk ("@GROUP_DELETE 20000 7 OK"+ "`n")
Assert ($deleteAck.generation -eq 7 -and $deleteAck.result -eq 'OK') 'delete ack missing'
Receive-SerialChunk ("@GROUP_DELETE 20000 8 REJECTED"+ "`n")
Assert ($deleteAck.generation -eq 8 -and $deleteAck.result -eq 'REJECTED') 'delete rejection missing'
Write-Output 'PASS: group delete acknowledgement and rejection parsing'
$header='@VISION {"version":"0.3.0","ms":2000,"day":20000,"dailyVisits":1,"tracks":[],"groups":[{"id":1,"generation":5,"visits":1}]}'
Receive-SerialChunk ($header+[Environment]::NewLine)
$photo='@THUMB {"day":20000,"generation":5,"width":24,"thumb":"'+('ff0000'*576)+'"}'
Receive-SerialChunk ($photo+[Environment]::NewLine)
Assert ($state.vision.groups[0].thumb.Length -eq 3456) 'same frame thumbnail missing'
Receive-SerialChunk ($header.Replace('2000,','2100,')+[Environment]::NewLine)
Assert ($state.vision.groups[0].thumbWidth -eq 24) 'thumbnail lost during status refresh'
Receive-SerialChunk ('@CONFIDENCE 80 OK'+[Environment]::NewLine)
Assert ($confidenceAck.value -eq 80 -and $confidenceAck.result -eq 'OK') 'confidence ack missing'
Receive-SerialChunk ($header.Replace('"generation":5','"generation":6')+[Environment]::NewLine)
Assert ($thumbCache.Count -eq 0) 'deleted thumbnail cache retained'
Write-Output 'PASS: same-frame thumbnail cache, eviction, confidence acknowledgement'
$vp='@VISIT {"boot":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","id":1,"ms":3000,"epoch":1792550000,"first_ms":0,"last_ms":2500,"ended":true}'
Receive-SerialChunk ($vp+[Environment]::NewLine)
Receive-SerialChunk ($vp.Replace('"ms":3000','"ms":4000')+[Environment]::NewLine)
$visitRecords=@(Get-Content -LiteralPath $recordPath -Encoding UTF8|ForEach-Object {$_|ConvertFrom-Json}|Where-Object {$_.kind -eq 'visit'})
Assert ($visitRecords.Count -eq 1) 'unchanged visit replay duplicated raw log'
Write-Output 'PASS: visit identity and raw replay de-duplication'
Receive-SerialChunk ('@SIMILARITY 85 OK'+[Environment]::NewLine)
Assert ($similarityAck.value -eq 85 -and $similarityAck.result -eq 'OK') 'similarity ack missing'
Receive-SerialChunk ('@SIMILARITY 101 REJECTED'+[Environment]::NewLine)
Assert ($similarityAck.result -eq 'REJECTED') 'similarity rejection missing'
