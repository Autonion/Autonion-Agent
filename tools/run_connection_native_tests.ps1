# Prerequisites: Visual Studio C++ workload, Windows SDK, and a Windows Debug Flutter build.
$ErrorActionPreference = 'Stop'
$agentRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vsRoot) { throw 'Visual Studio C++ tools were not found' }
$vcPath = (Get-ChildItem (Join-Path $vsRoot 'VC/Tools/MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkPath = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10'
$sdkVersion = (Get-ChildItem (Join-Path $sdkPath 'Include') -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'um/Windows.h') } | Sort-Object Name -Descending | Select-Object -First 1).Name
$flutterPath = Join-Path $agentRoot 'windows/flutter/ephemeral'
$wrapper = Join-Path $agentRoot 'build/windows/x64/flutter/Debug/flutter_wrapper_plugin.lib'
if (!(Test-Path -LiteralPath $wrapper)) { throw 'Run flutter build windows --debug first' }
$env:INCLUDE = "$vcPath/include;$sdkPath/Include/$sdkVersion/ucrt;$sdkPath/Include/$sdkVersion/um;$sdkPath/Include/$sdkVersion/shared;$flutterPath;$flutterPath/cpp_client_wrapper/include"
$env:LIB = "$vcPath/lib/x64;$sdkPath/Lib/$sdkVersion/um/x64;$sdkPath/Lib/$sdkVersion/ucrt/x64"
$env:PATH = "$flutterPath;" + $env:PATH
$outputPath = Join-Path $agentRoot 'build/connection_native_tests'
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
$compiler = Join-Path $vcPath 'bin/Hostx64/x64/cl.exe'
$plugin = Join-Path $agentRoot 'packages/nsd_windows/windows'
$helper = Join-Path $agentRoot 'windows/unlock_helper'
Push-Location $outputPath
try {
    & $compiler /nologo /std:c++17 /EHsc /MDd /D_DEBUG /DUNICODE /D_UNICODE /DNOMINMAX "$plugin/test/callback_thread_test.cpp" "$plugin/nsd_windows.cpp" "$plugin/nsd_error.cpp" "$plugin/utilities.cpp" /Fecallback_thread_test.exe /link $wrapper "$flutterPath/flutter_windows.dll.lib" User32.lib Dnsapi.lib
    if ($LASTEXITCODE -ne 0) { throw 'DNS-SD regression compilation failed' }
    ./callback_thread_test.exe
    if ($LASTEXITCODE -ne 0) { throw 'DNS-SD regression failed' }
    foreach ($testName in @('unlock_verification_test', 'prelogin_auth_test')) {
        & $compiler /nologo /std:c++17 /EHsc "$helper/$testName.cpp" "/Fe$testName.exe"
        if ($LASTEXITCODE -ne 0) { throw "$testName compilation failed" }
        & (Join-Path $outputPath "$testName.exe")
        if ($LASTEXITCODE -ne 0) { throw "$testName failed" }
    }
    & $compiler /nologo /std:c++17 /EHsc /DUNICODE /D_UNICODE /DNOMINMAX "$helper/prelogin_wire_test.cpp" /Feprelogin_wire_test.exe /link Advapi32.lib Crypt32.lib User32.lib Ws2_32.lib Wtsapi32.lib
    if ($LASTEXITCODE -ne 0) { throw 'Pre-login wire test compilation failed' }
    ./prelogin_wire_test.exe "$helper/testdata/gson-client-info.json"
    if ($LASTEXITCODE -ne 0) { throw 'Pre-login wire test failed' }
} finally { Pop-Location }
