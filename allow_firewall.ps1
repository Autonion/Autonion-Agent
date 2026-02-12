$exePath = "$PSScriptRoot\build\windows\x64\runner\Debug\autonion_cross_device.exe"

# Self-elevate
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

if (-not (Test-Path $exePath)) {
    Write-Host "Executable not found at $exePath" -ForegroundColor Red
    Write-Host "Attempting alternate path..."
    # Try identifying if we are in a different relative location or build type
    $exePath = "$PSScriptRoot\build\windows\x64\runner\Release\autonion_cross_device.exe"
    if (-not (Test-Path $exePath)) {
        Write-Host "Executable not found at $exePath either." -ForegroundColor Red
        Write-Host "Please run 'flutter build windows' first." -ForegroundColor Yellow
        Read-Host "Press Enter to exit..."
        exit
    }
}

Write-Host "Adding Firewall Rules for: $exePath" -ForegroundColor Cyan
Write-Host ""

# Validating Network Profile
$netProfile = Get-NetConnectionProfile
Write-Host "Current Network Profile: $($netProfile.NetworkCategory)" -ForegroundColor Cyan
if ($netProfile.NetworkCategory -eq "Public") {
    Write-Host ""
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host "WARNING: Your network is set to PUBLIC." -ForegroundColor Red
    Write-Host "Windows BLOCKS incoming connections on Public networks." -ForegroundColor Red
    Write-Host "This is the #1 cause of cross-device connection failure!" -ForegroundColor Red
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host ""
    Write-Host "To fix: Settings > Network & Internet > Wi-Fi > Properties > Private" -ForegroundColor Yellow
    Write-Host ""
}

# Remove old rules to avoid duplicates
Write-Host "Removing old rules..." -ForegroundColor Gray
Remove-NetFirewallRule -DisplayName "Autonion Agent (Debug)" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Autonion Agent (mDNS)" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Autonion Agent (mDNS Out)" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Autonion Agent (WebSocket)" -ErrorAction SilentlyContinue

# INBOUND rules
Write-Host "Creating INBOUND rules..." -ForegroundColor Cyan
New-NetFirewallRule -DisplayName "Autonion Agent (Debug)" -Direction Inbound -Program $exePath -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName "Autonion Agent (mDNS)" -Direction Inbound -Protocol UDP -LocalPort 5353 -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName "Autonion Agent (WebSocket)" -Direction Inbound -Protocol TCP -LocalPort 4545 -Action Allow -Profile Any | Out-Null

# OUTBOUND rule for mDNS (needed for advertising responses)
Write-Host "Creating OUTBOUND rules..." -ForegroundColor Cyan
New-NetFirewallRule -DisplayName "Autonion Agent (mDNS Out)" -Direction Outbound -Protocol UDP -RemotePort 5353 -Action Allow -Profile Any | Out-Null

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " Firewall rules added successfully!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

# Show current rules for verification
Write-Host "Active Autonion firewall rules:" -ForegroundColor Cyan
Get-NetFirewallRule -DisplayName "Autonion*" | Format-Table DisplayName, Direction, Action, Profile, Enabled -AutoSize

# Show local IPs for reference
Write-Host ""
Write-Host "Your local IP addresses:" -ForegroundColor Cyan
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne "127.0.0.1" } | Format-Table InterfaceAlias, IPAddress -AutoSize

Write-Host "You MUST restart the Flutter app for this to take effect." -ForegroundColor Yellow
Read-Host "Press Enter to exit..."
