param(
    [switch]$NoBuild,
    [switch]$NoInstall,
    [int]$Port = 49835,
    [string[]]$Serials = @(),
    [string]$HostAddress = "",
    [int]$DurationSeconds = 10,
    [int]$SourcePid = 0,
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
$evidence = Join-Path $root ('.tmp-android-multi-' + [guid]::NewGuid().ToString('N'))
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

$connected = @(adb devices | Select-String '^\S+\s+device$' | ForEach-Object {
    ($_ -split '\s+')[0]
})
if ($Serials.Count -eq 0) { $Serials = $connected }
$Serials = @($Serials | Select-Object -Unique)
if ($Serials.Count -lt 2) { throw 'At least two connected Android devices are required' }
foreach ($serial in $Serials) {
    if ($connected -notcontains $serial) { throw "Android device $serial is not connected" }
}

if ([string]::IsNullOrWhiteSpace($HostAddress)) {
    $HostAddress = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object {
            $_.IPAddress -notlike '127.*' -and
            $_.IPAddress -notlike '169.254.*' -and
            $_.InterfaceAlias -notmatch 'Loopback|WSL|vEthernet|Virtual'
        } |
        Sort-Object -Property InterfaceMetric |
        Select-Object -ExpandProperty IPAddress -First 1
}
if ([string]::IsNullOrWhiteSpace($HostAddress)) {
    throw 'No eligible LAN IPv4 address was found; pass -HostAddress explicitly'
}
$advertiseAddresses = @(
    $HostAddress
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object {
            $_.IPAddress -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' -and
            $_.IPAddress -ne $HostAddress
        } |
        Select-Object -ExpandProperty IPAddress
) | Select-Object -Unique

foreach ($serial in $Serials) {
    if (-not $NoInstall) {
        & adb -s $serial install -r $apk | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "APK installation failed on $serial" }
    }
    & adb -s $serial shell am force-stop dev.sonara.sonara | Out-Null
    & adb -s $serial logcat -c
}

$invitationFile = Join-Path $evidence 'invitation.txt'
$hostStdout = Join-Path $evidence 'host.stdout.log'
$hostStderr = Join-Path $evidence 'host.stderr.log'
$hostProcess = $null
$launches = @()
try {
    $sourceArguments = if ($SourcePid -gt 0) { @('--pid', $SourcePid) } else { @('--test-tone') }
    $hostArguments = @('host') + $sourceArguments + @(
        '--listen', "0.0.0.0:$Port",
        '--duration', $DurationSeconds,
        '--invitation-out', $invitationFile,
        '--mode', $Mode,
        '--profile', $Profile
    )
    foreach ($address in $advertiseAddresses) {
        $hostArguments += @('--advertise', "${address}:$Port")
    }
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
    foreach ($serial in $Serials) {
        $arguments = @(
            '-s', $serial, 'shell', 'am', 'start', '-W',
            '-n', 'dev.sonara.sonara/.MainActivity',
            '--es', 'sonara_invitation', $invitation
        )
        $launches += Start-Process adb -ArgumentList $arguments -WindowStyle Hidden -PassThru
    }
    foreach ($launch in $launches) {
        if (-not $launch.WaitForExit(15000) -or $launch.ExitCode -ne 0) {
            throw 'An Android receiver did not launch successfully'
        }
    }

    if (-not $hostProcess.WaitForExit(($DurationSeconds + 25) * 1000)) { throw 'Host did not finish' }
    if ($hostProcess.ExitCode -ne 0) {
        throw "Host failed: $(Get-Content -LiteralPath $hostStderr -Raw)"
    }
    Start-Sleep -Seconds 5

    $reports = @()
    foreach ($serial in $Serials) {
        $receiverLines = & adb -s $serial logcat -d | Select-String 'SonaraReceiver:'
        $receiverLines | Set-Content -LiteralPath (Join-Path $evidence "receiver-$($serial -replace '[^A-Za-z0-9_.-]', '_').log")
        $stopped = $receiverLines | Where-Object { $_ -match '"state":"stopped"' } | Select-Object -Last 1
        if (-not $stopped) { throw "Receiver $serial did not reach a clean stopped state" }
        $json = [regex]::Match($stopped.ToString(), '\{.*\}').Value
        $report = $json | ConvertFrom-Json
        if ($report.packets_received -lt ($DurationSeconds * 150)) {
            throw "Receiver $serial got too few packets: $($report.packets_received)"
        }
        $maximumConcealedPackets = [Math]::Ceiling($DurationSeconds * 200 * 0.01)
        if ($report.packets_lost -gt $maximumConcealedPackets -or $report.invalid_packets -ne 0) {
            throw "Receiver $serial media validation failed: lost=$($report.packets_lost), invalid=$($report.invalid_packets)"
        }
        if ($report.error) { throw "Receiver $serial error: $($report.error)" }
        if ($null -eq $report.first_sequence -or $null -eq $report.last_sequence) {
            throw "Receiver $serial did not report its media sequence range"
        }
        $reports += [pscustomobject]@{ Serial = $serial; Report = $report }
    }

    $lastSequences = @($reports | ForEach-Object { [uint64]$_.Report.last_sequence })
    $sequenceSpread = ($lastSequences | Measure-Object -Maximum).Maximum - ($lastSequences | Measure-Object -Minimum).Minimum
    if ($sequenceSpread -gt 2) {
        throw "Receivers ended more than two packets apart: spread=$sequenceSpread"
    }
    $firstSequences = @($reports | ForEach-Object { [uint64]$_.Report.first_sequence })
    $startSpread = ($firstSequences | Measure-Object -Maximum).Maximum - ($firstSequences | Measure-Object -Minimum).Minimum
    if ($startSpread -gt 2) {
        throw "Receivers started more than two packets apart: spread=$startSpread"
    }
    $hostLog = Get-Content -LiteralPath $hostStderr -Raw
    if ($hostLog -notmatch "across $($Serials.Count) receivers") {
        throw "Host did not retain all $($Serials.Count) receivers: $hostLog"
    }

    foreach ($item in $reports) {
        $report = $item.Report
        Write-Output "$($item.Serial): $($report.platform_model), packets $($report.first_sequence)-$($report.last_sequence), recovered duplicates $($report.redundant_packets), lost $($report.packets_lost), underruns $($report.output_underruns), adaptive $($report.adaptive_buffer_ms) ms"
    }
    Write-Output "Android multi-receiver passed on $($Serials.Count) devices; start/final sequence spread $startSpread/$sequenceSpread packets"
    Write-Output "Evidence retained at $evidence"
} finally {
    foreach ($launch in $launches) {
        if (-not $launch.HasExited) { $launch.Kill() }
    }
    if ($null -ne $hostProcess -and -not $hostProcess.HasExited) { $hostProcess.Kill() }
    foreach ($serial in $Serials) {
        & adb -s $serial shell am force-stop dev.sonara.sonara 2>$null | Out-Null
    }
}
