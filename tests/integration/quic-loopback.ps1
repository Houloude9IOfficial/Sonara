$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exe = Join-Path $repo 'target\debug\sonara.exe'
$testDir = Join-Path $repo ('.tmp-quic-integration-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
$env:SONARA_IDENTITY_DIR = Join-Path $testDir 'identity'
$hostProcess = $null

function Get-InvitationFingerprint([string]$encoded) {
    $payload = $encoded.Substring('sonara1:'.Length).Replace('-', '+').Replace('_', '/')
    while ($payload.Length % 4 -ne 0) { $payload += '=' }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    return $json.host_fingerprint
}

Push-Location $repo
try {
    cargo build -p sonara
    if ($LASTEXITCODE -ne 0) { throw 'cargo build failed' }

    $invite = Join-Path $testDir 'invitation.txt'
    $wav = Join-Path $testDir 'received.wav'
    $hostOut = Join-Path $testDir 'host.out'
    $hostErr = Join-Path $testDir 'host.err'
    $hostProcess = Start-Process -FilePath $exe `
        -ArgumentList @('host', '--test-tone', '--listen', '127.0.0.1:0', '--duration', '2', '--invitation-out', $invite) `
        -WorkingDirectory $repo -RedirectStandardOutput $hostOut -RedirectStandardError $hostErr `
        -WindowStyle Hidden -PassThru

    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $invite); $i++) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $invite)) {
        throw "host did not create invitation: $(Get-Content -LiteralPath $hostErr -Raw)"
    }

    $json = & $exe receive --invitation-file $invite --output $wav | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'receiver failed' }
    for ($i = 0; $i -lt 100 -and -not $hostProcess.HasExited; $i++) {
        Start-Sleep -Milliseconds 100
        $hostProcess.Refresh()
    }
    if (-not $hostProcess.HasExited -or $hostProcess.ExitCode -ne 0) {
        throw "host failed: $(Get-Content -LiteralPath $hostErr -Raw)"
    }
    if ($json.packets_received -ne 400 -or $json.packets_lost -ne 0 -or $json.invalid_packets -ne 0) {
        throw "unexpected packet report: $($json | ConvertTo-Json -Compress)"
    }
    if ($json.frames_written -ne 96000) { throw "expected 96000 frames, got $($json.frames_written)" }
    if ($json.rms -lt 0.14 -or $json.rms -gt 0.143) { throw "unexpected signal RMS $($json.rms)" }
    if ($json.clock_samples -lt 8 -or $json.clock_uncertainty_ms -lt 0 -or $json.clock_uncertainty_ms -gt 5) {
        throw "clock synchronization did not qualify: $($json | ConvertTo-Json -Compress)"
    }
    if ((Get-Item -LiteralPath $wav).Length -ne 384044) { throw 'unexpected WAV byte length' }

    $firstFingerprint = Get-InvitationFingerprint (Get-Content -LiteralPath $invite -Raw)
    $invite2 = Join-Path $testDir 'invitation-2.txt'
    $wav2 = Join-Path $testDir 'received-2.wav'
    $hostProcess = Start-Process -FilePath $exe `
        -ArgumentList @('host', '--test-tone', '--listen', '127.0.0.1:0', '--duration', '0.1', '--invitation-out', $invite2) `
        -WorkingDirectory $repo -RedirectStandardOutput (Join-Path $testDir 'host-2.out') `
        -RedirectStandardError (Join-Path $testDir 'host-2.err') -WindowStyle Hidden -PassThru
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $invite2); $i++) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $invite2)) { throw 'second host did not create invitation' }
    $json2 = & $exe receive --invitation-file $invite2 --output $wav2 | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'second receiver failed' }
    for ($i = 0; $i -lt 100 -and -not $hostProcess.HasExited; $i++) {
        Start-Sleep -Milliseconds 100
        $hostProcess.Refresh()
    }
    if (-not $hostProcess.HasExited -or $hostProcess.ExitCode -ne 0) { throw 'second host failed' }
    $secondFingerprint = Get-InvitationFingerprint (Get-Content -LiteralPath $invite2 -Raw)
    if ($firstFingerprint -ne $secondFingerprint) { throw 'persistent host fingerprint changed between runs' }
    if ($json2.packets_received -ne 20 -or $json2.frames_written -ne 4800) { throw 'second identity-reload stream was incomplete' }

    Write-Output "QUIC loopback passed: 400 PCM packets, 96000 frames, zero loss, $($json.clock_samples) clock samples"
    Write-Output "DPAPI identity reload passed: fingerprint $firstFingerprint"
    Write-Output "Evidence retained at $testDir"
}
finally {
    if ($null -ne $hostProcess) {
        $hostProcess.Refresh()
        if (-not $hostProcess.HasExited) {
            Stop-Process -Id $hostProcess.Id -Force
        }
    }
    Pop-Location
}
