param(
    [ValidateSet('All', 'Windows', 'Android')]
    [string]$Platform = 'All',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$app = Join-Path $root 'apps\sonara'
$dist = Join-Path $root 'dist'
$versionLine = Get-Content (Join-Path $app 'pubspec.yaml') |
    Where-Object { $_ -match '^version:\s*' } | Select-Object -First 1
if ($versionLine -notmatch '^version:\s*([^+\s]+)') { throw 'Could not read app version from pubspec.yaml.' }
$version = $Matches[1]

if (-not $dist.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Resolved distribution directory is outside the repository.'
}
New-Item -ItemType Directory -Force -Path $dist | Out-Null

function Invoke-Checked([string]$Command, [string[]]$Arguments, [string]$WorkingDirectory) {
    Push-Location $WorkingDirectory
    try {
        & $Command @Arguments
        if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

function Write-Hash([string]$Path) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$Path.sha256" -Encoding ascii -Value "$hash  $([IO.Path]::GetFileName($Path))"
}

if ($Platform -in @('All', 'Windows')) {
    if (-not $SkipBuild) {
        $brandingScript = Join-Path $root 'tools\branding\round_desktop_icons.py'
        $checkedInIcon = Join-Path $app 'windows\runner\resources\app_icon.ico'
        $python = Get-Command python -ErrorAction SilentlyContinue
        $hasPillow = $false
        if ($python) {
            & $python.Source -c 'import PIL' 2>$null
            $hasPillow = $LASTEXITCODE -eq 0
        }
        if ($hasPillow) {
            Invoke-Checked $python.Source @($brandingScript) $root
        } elseif (-not (Test-Path $checkedInIcon)) {
            throw 'Pillow is unavailable and the checked-in Windows icon is missing.'
        } else {
            Write-Warning 'Pillow is unavailable; using the checked-in generated Windows icon.'
        }
        Invoke-Checked 'flutter' @('build', 'windows', '--release') $app
    }
    $built = Join-Path $app 'build\windows\x64\runner\Release'
    if (-not (Test-Path (Join-Path $built 'sonara.exe'))) {
        throw "Windows release was not found at $built"
    }
    $portable = Join-Path $dist 'Sonara-windows-x64-portable'
    if (Test-Path $portable) { Remove-Item -LiteralPath $portable -Recurse -Force }
    Copy-Item -LiteralPath $built -Destination $portable -Recurse
    Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $portable
    Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination $portable
    $zip = Join-Path $dist "Sonara-$version-windows-x64-portable.zip"
    if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $portable '*') -DestinationPath $zip -CompressionLevel Optimal
    Write-Hash $zip

    $iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    $isccPath = if ($iscc) { $iscc.Source } else {
        Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'
    }
    if (Test-Path $isccPath) {
        Invoke-Checked $isccPath @("/DMyAppVersion=$version", (Join-Path $PSScriptRoot 'Sonara.iss')) $root
        $installer = Join-Path $dist "Sonara-$version-windows-x64-setup.exe"
        if (Test-Path $installer) { Write-Hash $installer }
    } else {
        Write-Warning 'Inno Setup was not found; the verified portable Windows package was still produced.'
    }
}

if ($Platform -in @('All', 'Android')) {
    $androidRoot = Join-Path $app 'android'
    $keyStore = Join-Path $androidRoot 'release-key.jks'
    $keyProperties = Join-Path $androidRoot 'key.properties'
    if (-not (Test-Path $keyStore)) {
        $passwordBytes = New-Object byte[] 24
        [Security.Cryptography.RandomNumberGenerator]::Fill($passwordBytes)
        $password = [Convert]::ToBase64String($passwordBytes).Replace('+', 'A').Replace('/', 'B').TrimEnd('=')
        $keytool = (Get-Command keytool -ErrorAction Stop).Source
        Invoke-Checked $keytool @(
            '-genkeypair', '-v', '-keystore', $keyStore, '-storetype', 'PKCS12',
            '-storepass', $password, '-keypass', $password, '-alias', 'sonara',
            '-keyalg', 'RSA', '-keysize', '3072', '-validity', '3650',
            '-dname', 'CN=Sonara Developer, O=Sonara, C=CY'
        ) $root
        Set-Content -LiteralPath $keyProperties -Encoding ascii -Value @(
            'storeFile=release-key.jks'
            "storePassword=$password"
            'keyAlias=sonara'
            "keyPassword=$password"
        )
    } elseif (-not (Test-Path $keyProperties)) {
        throw 'The release keystore exists but android/key.properties is missing.'
    }
    if (-not $SkipBuild) {
        Invoke-Checked 'flutter' @('build', 'apk', '--release') $app
    }
    $builtApk = Join-Path $app 'build\app\outputs\flutter-apk\app-release.apk'
    if (-not (Test-Path $builtApk)) { throw "Android release was not found at $builtApk" }
    $apk = Join-Path $dist "Sonara-$version-android.apk"
    Copy-Item -LiteralPath $builtApk -Destination $apk -Force
    Write-Hash $apk
}

Get-ChildItem -LiteralPath $dist -File | Sort-Object Name | Select-Object Name, Length
