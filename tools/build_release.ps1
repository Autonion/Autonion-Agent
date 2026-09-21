param(
    [string]$FlutterPath = 'flutter',
    [string]$IsccPath = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$pubspec = Get-Content -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Raw
$appConfig = Get-Content -LiteralPath (Join-Path $projectRoot 'lib/core/config/app_config.dart') -Raw
$setup = Get-Content -LiteralPath (Join-Path $projectRoot 'setup.iss') -Raw

$packageMatch = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
$appMatch = [regex]::Match($appConfig, "appVersion\s*=\s*'(\d+\.\d+\.\d+)'")
$setupMatch = [regex]::Match($setup, '(?m)^AppVersion=(\d+\.\d+\.\d+)\s*$')
if (!$packageMatch.Success -or !$appMatch.Success -or !$setupMatch.Success) {
    throw 'Expected stable versions in pubspec.yaml, AppConfig.appVersion and setup.iss.'
}
$version = $packageMatch.Groups[1].Value
$buildNumber = $packageMatch.Groups[2].Value
if ($appMatch.Groups[1].Value -ne $version -or $setupMatch.Groups[1].Value -ne $version) {
    throw 'Version mismatch: pubspec.yaml, AppConfig.appVersion and setup.iss must match before publishing.'
}
Write-Host "Validated release version $version+$buildNumber. Publish as GitHub tag v$version."
if ($ValidateOnly) { return }
if (!(Test-Path -LiteralPath $IsccPath)) { throw "Inno Setup compiler not found: $IsccPath" }

Push-Location -LiteralPath $projectRoot
try {
    & $FlutterPath pub get
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed.' }
    & $FlutterPath test --no-pub test/update_service_test.dart test/update_widgets_test.dart
    if ($LASTEXITCODE -ne 0) { throw 'Update checks failed; installer was not rebuilt.' }
    & $FlutterPath build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Windows release build failed; installer was not rebuilt.' }

    $appExe = Join-Path $projectRoot 'build/windows/x64/runner/Release/autonion_cross_device.exe'
    $binaryVersion = (Get-Item -LiteralPath $appExe).VersionInfo.ProductVersion.Trim()
    if ($binaryVersion -ne "$version+$buildNumber") {
        throw "Built application version $binaryVersion does not match $version+$buildNumber."
    }

    & $IsccPath /Qp (Join-Path $projectRoot 'setup.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
    $installer = Join-Path $projectRoot 'Output/Autonion Agent.exe'
    $installerVersion = (Get-Item -LiteralPath $installer).VersionInfo.ProductVersion.Trim()
    if ($installerVersion -ne $version) {
        throw "Installer version $installerVersion does not match $version."
    }
    $hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$installer.sha256" -Value "$hash  Autonion Agent.exe" -Encoding ascii
    Write-Host "Ready to upload: $installer (v$version)"
    Write-Host "SHA256: $hash"
} finally {
    Pop-Location
}
