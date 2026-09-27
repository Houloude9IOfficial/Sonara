param(
    [switch]$NoBuild,
    [switch]$NoInstall,
    [int]$Port = 49833,
    [string]$Serial = "",
    [string]$HostAddress = "10.0.2.2",
    [int]$DurationSeconds = 5,
    [int]$SourcePid = 0,
    [switch]$ScreenOff,
    [ValidateSet('synchronized', 'low-delay')]
    [string]$Mode = 'synchronized',
    [ValidateSet('ultra-low', 'balanced', 'stable')]
    [string]$Profile = 'balanced'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$app = Join-Path $root 'apps\sonara'
$apk = Join-Path $app 'build\app\outputs\flutter-apk\app-debug.apk'
$binary = Join-Path $root 'target\debug\sonara.exe'
$evidence = Join-Path $root ('.tmp-android-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $evidence | Out-Null

if (-not $NoBuild) {
    Push-Location $app
    try {
        flutter build apk --debug
        if ($LASTEXITCODE -ne 0) { throw 'Flutter APK build failed' }
    } finally {
        Pop-Location
    }
}

$deviceLines = adb devices | Select-String '^\S+\s+device$'
if ([string]::IsNullOrWhiteSpace($Serial)) {
    $Serial = ($deviceLines | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ -like 'emulator-*' } | Select-Object -First 1)
}
if ([string]::IsNullOrWhiteSpace($Serial)) { throw 'No booted Android device was discovered' }
$device = $deviceLines | Where-Object { $_ -match "^$([regex]::Escape($Serial))\s+device$" }
if (-not $device) { throw "Android device $Serial is not connected and booted" }
if (-not $NoInstall) {
    adb -s $Serial install -r $apk | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'APK installation failed' }
}
adb -s $Serial shell am force-stop dev.sonara.sonara
adb -s $Serial logcat -c

$invitationFile = Join-Path $evidence 'invitation.txt'
$hostStdout = Join-Path $evidence 'host.stdout.log'
$hostStderr = Join-Path $evidence 'host.stderr.log'
$hostProcess = $null
try {
    $sourceArguments = if ($SourcePid -gt 0) {
        @('--pid', $SourcePid)
    } else {
        @('--test-tone')
    }
    $hostArguments = @('host') + $sourceArguments + @(
        '--listen', "0.0.0.0:$Port",
        '--advertise', "${HostAddress}:$Port",
        '--duration', $DurationSeconds,
        '--invitation-out', $invitationFile,
        '--mode', $Mode,
        '--profile', $Profile
    )
    $hostProcess = Start-Process $binary -ArgumentList $hostArguments `
        -RedirectStandardOutput $hostStdout -RedirectStandardError $hostStderr `
        -WindowStyle Hidden -PassThru

    $deadline = (Get-Date).AddSeconds(10)
    while (-not (Test-Path -LiteralPath $invitationFile) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $invitationFile)) {
        throw "Host did not create an invitation: $(Get-Content -LiteralPath $hostStderr -Raw)"
    }
    $invitation = (Get-Content -LiteralPath $invitationFile -Raw).Trim()
    adb -s $Serial shell am start -W -n dev.sonara.sonara/.MainActivity `
        --es sonara_invitation $invitation | Out-Null
    if ($ScreenOff) {
        adb -s $Serial shell input keyevent KEYCODE_SLEEP
    }

    if (-not $hostProcess.WaitForExit(($DurationSeconds + 20) * 1000)) { throw 'Host did not finish' }
    if ($hostProcess.ExitCode -ne 0) {
        throw "Host failed: $(Get-Content -LiteralPath $hostStderr -Raw)"
    }
    Start-Sleep -Seconds 2
    $receiverLines = adb -s $Serial logcat -d | Select-String 'SonaraReceiver:'
    $stopped = $receiverLines | Where-Object { $_ -match '"state":"stopped"' } | Select-Object -Last 1
    if (-not $stopped) {
        $receiverLines | Set-Content -LiteralPath (Join-Path $evidence 'receiver.log')
        throw 'Receiver did not reach a clean stopped state'
    }
    $json = [regex]::Match($stopped.ToString(), '\{.*\}').Value
    $report = $json | ConvertFrom-Json
    $minimumPackets = $DurationSeconds * 180
    if ($report.packets_received -lt $minimumPackets) { throw "too few packets: $($report.packets_received)" }
    if ($report.packets_lost -ne 0 -or $report.invalid_packets -ne 0) {
        throw "media validation failed: lost=$($report.packets_lost), invalid=$($report.invalid_packets)"
    }
    if ($null -eq $report.clock_uncertainty_ms) { throw 'clock uncertainty was not reported' }
    if ([Math]::Abs($report.rate_correction_ppm) -gt 500) {
        throw "rate correction exceeded 500 ppm: $($report.rate_correction_ppm)"
    }
    if ($report.buffered_frames -gt 48000) {
        throw "native render ring exceeded one second: $($report.buffered_frames) frames"
    }
    if ($Profile -eq 'ultra-low' -and $report.target_buffer_ms -gt 10.0) {
        throw "ultra-low target exceeded 10 ms: $($report.target_buffer_ms) ms"
    }
    if ($Profile -eq 'ultra-low' -and $report.packet_duration_ms -gt 5.0) {
        throw "ultra-low packet duration exceeded 5 ms: $($report.packet_duration_ms) ms"
    }
    if ($Profile -eq 'ultra-low' -and $report.buffered_frames -gt 1200) {
        throw "ultra-low render queue exceeded 25 ms: $($report.buffered_frames) frames"
    }
    if ($Profile -eq 'balanced' -and $report.output_silence_frames -gt ($DurationSeconds * 100)) {
        throw "balanced playback inserted too much recovery silence: $($report.output_silence_frames) frames"
    }
    if ($Profile -eq 'balanced' -and $report.packet_duration_ms -gt 5.0) {
        throw "balanced packet duration exceeded 5 ms: $($report.packet_duration_ms) ms"
    }
    if ($report.output_sample_rate -le 0 -or $report.output_channels -le 0) {
        throw 'platform output format was not reported'
    }
    $minimumRenderedFrames = [int]($report.output_sample_rate * $DurationSeconds * 0.8)
    if ($report.frames_rendered -lt $minimumRenderedFrames) {
        throw "too few rendered frames: $($report.frames_rendered) at $($report.output_sample_rate) Hz"
    }
    if (-not $report.platform_model -or -not $report.output_route) {
        throw 'platform model or selected output route was not reported'
    }
    if ($report.error) { throw "receiver error: $($report.error)" }
    if ($SourcePid -gt 0) {
        $hostLog = Get-Content -LiteralPath $hostStderr -Raw
        if ($hostLog -notmatch '0 device discontinuities, 0 expired capture blocks') {
            throw "process capture reported a discontinuity or overflow: $hostLog"
        }
    }
    $receiverLines | Set-Content -LiteralPath (Join-Path $evidence 'receiver.log')
    Write-Output "Android loopback passed: $($report.packets_received) packets, $($report.frames_rendered) Oboe frames, $($report.output_underruns) underruns/$($report.output_silence_frames) silence frames, adaptive $($report.adaptive_buffer_ms) ms"
    Write-Output "Evidence retained at $evidence"
} finally {
    if ($null -ne $hostProcess -and -not $hostProcess.HasExited) { $hostProcess.Kill() }
    if ($ScreenOff) {
        adb -s $Serial shell input keyevent KEYCODE_WAKEUP 2>$null | Out-Null
    }
    adb -s $Serial shell am force-stop dev.sonara.sonara 2>$null | Out-Null
}
