param(
    [switch]$NoBuild,
    [int]$Port = 49824
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
$binary = Join-Path $root 'target\debug\sonara.exe'
$evidence = Join-Path $root ('.tmp-wasapi-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $evidence | Out-Null

if (-not $NoBuild) {
    & $cargo build -p sonara --manifest-path (Join-Path $root 'Cargo.toml')
    if ($LASTEXITCODE -ne 0) { throw 'cargo build failed' }
}

$fixture = Join-Path $evidence 'fixture.wav'
$sampleRate = 48000
$seconds = 8
$frames = $sampleRate * $seconds
$stream = [IO.File]::Create($fixture)
$writer = [IO.BinaryWriter]::new($stream)
try {
    $dataBytes = $frames * 4
    $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
    $writer.Write([int](36 + $dataBytes))
    $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
    $writer.Write([int]16)
    $writer.Write([int16]1)
    $writer.Write([int16]2)
    $writer.Write([int]$sampleRate)
    $writer.Write([int]($sampleRate * 4))
    $writer.Write([int16]4)
    $writer.Write([int16]16)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
    $writer.Write([int]$dataBytes)
    for ($frame = 0; $frame -lt $frames; $frame++) {
        $sample = [int16]([Math]::Sin(2 * [Math]::PI * 440 * $frame / $sampleRate) * 6000)
        $writer.Write($sample)
        $writer.Write($sample)
    }
} finally {
    $writer.Dispose()
    $stream.Dispose()
}

$invitation = Join-Path $evidence 'invitation.txt'
$received = Join-Path $evidence 'received.wav'
$hostStdout = Join-Path $evidence 'host.stdout.log'
$hostStderr = Join-Path $evidence 'host.stderr.log'
$escapedFixture = $fixture.Replace("'", "''")
$playerScript = "(New-Object System.Media.SoundPlayer '$escapedFixture').PlaySync()"
$player = $null
$hostProcess = $null
try {
    $player = Start-Process pwsh.exe -ArgumentList @('-NoProfile', '-Command', $playerScript) -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 150
    $hostProcess = Start-Process $binary -ArgumentList @(
        'host', '--pid', $player.Id,
        '--listen', "127.0.0.1:$Port",
        '--duration', '1.0',
        '--invitation-out', $invitation
    ) -RedirectStandardOutput $hostStdout -RedirectStandardError $hostStderr -WindowStyle Hidden -PassThru

    $deadline = (Get-Date).AddSeconds(10)
    while (-not (Test-Path -LiteralPath $invitation) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $invitation)) {
        throw "Host did not create an invitation: $(Get-Content -LiteralPath $hostStderr -Raw)"
    }

    $json = & $binary receive --invitation-file $invitation --output $received
    if ($LASTEXITCODE -ne 0) { throw 'receiver failed' }
    $report = $json | ConvertFrom-Json
    if ($report.packets_received -lt 150) { throw "too few packets: $($report.packets_received)" }
    if ($report.packets_lost -ne 0 -or $report.invalid_packets -ne 0) {
        throw "media validation failed: lost=$($report.packets_lost), invalid=$($report.invalid_packets)"
    }
    if ($report.rms -lt 0.01) { throw "captured stream is unexpectedly silent: rms=$($report.rms)" }
    if ($report.source_timestamp_regressions -ne 0) {
        throw "capture timestamps regressed $($report.source_timestamp_regressions) times"
    }
    $sourceSpanMs = ($report.last_source_time_ns - $report.first_source_time_ns) / 1000000
    if ($sourceSpanMs -lt 900) { throw "capture timestamp span is too short: $sourceSpanMs ms" }

    if (-not $hostProcess.WaitForExit(15000)) { throw 'host did not exit after capture completed' }
    if ($hostProcess.ExitCode -ne 0) {
        throw "host failed: $(Get-Content -LiteralPath $hostStderr -Raw)"
    }
    $hostLog = Get-Content -LiteralPath $hostStderr -Raw
    if ($hostLog -notmatch '0 device discontinuities, 0 expired capture blocks') {
        throw "capture reported a discontinuity or overflow: $hostLog"
    }
    Write-Output "WASAPI-to-QUIC loopback passed: $($report.packets_received) packets, $($report.frames_written) frames, RMS $([Math]::Round($report.rms, 4)), source span $([Math]::Round($sourceSpanMs, 1)) ms"
    Write-Output "Evidence retained at $evidence"
} finally {
    if ($null -ne $hostProcess -and -not $hostProcess.HasExited) { $hostProcess.Kill() }
    if ($null -ne $player -and -not $player.HasExited) { $player.Kill() }
}
