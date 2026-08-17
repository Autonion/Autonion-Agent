# Autonion Unlock Helper - Service Update Script
# Run this in an ADMINISTRATOR PowerShell window

# Self-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$buildPath = "F:\Autonion Desktop\Autonion-Agent\build\windows\x64\unlock_helper\Release\autonion_unlock_helper.exe"
$installPath = "C:\Program Files\Autonion Agent\autonion_unlock_helper.exe"

Write-Host "=== Updating Autonion Unlock Helper Service ===" -ForegroundColor Cyan
Write-Host ""

# Step 1: Stop the service
Write-Host "[1/5] Stopping service..." -ForegroundColor Yellow
Stop-Service -Name AutonionUnlockHelper -Force -ErrorAction SilentlyContinue
Stop-Process -Name autonion_unlock_helper -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# Step 2: Copy new binary
Write-Host "[2/5] Copying new binary..." -ForegroundColor Yellow
Copy-Item -Path $buildPath -Destination $installPath -Force

# Step 3: Create firewall rules (the actual fix!)
Write-Host "[3/5] Creating firewall rules..." -ForegroundColor Yellow

# Remove old rules first
netsh advfirewall firewall delete rule name="Autonion Unlock Helper (WebSocket)" 2>$null | Out-Null
netsh advfirewall firewall delete rule name="Autonion Unlock Helper (mDNS In)" 2>$null | Out-Null
netsh advfirewall firewall delete rule name="Autonion Unlock Helper (mDNS Out)" 2>$null | Out-Null
netsh advfirewall firewall delete rule name="Autonion Unlock Helper (Service)" 2>$null | Out-Null

# Create port-based rules with profile=any (critical for pre-login)
netsh advfirewall firewall add rule name="Autonion Unlock Helper (WebSocket)" dir=in action=allow protocol=TCP localport=4545 profile=any description="Allows Android companion to connect to Autonion pre-login WebSocket" | Out-Null
netsh advfirewall firewall add rule name="Autonion Unlock Helper (mDNS In)" dir=in action=allow protocol=UDP localport=5353 profile=any description="Allows mDNS queries to reach Autonion pre-login service" | Out-Null
netsh advfirewall firewall add rule name="Autonion Unlock Helper (mDNS Out)" dir=out action=allow protocol=UDP remoteport=5353 profile=any description="Allows Autonion pre-login service to send mDNS announcements" | Out-Null
netsh advfirewall firewall add rule name="Autonion Unlock Helper (Service)" dir=in action=allow profile=any program="$installPath" description="Allows all inbound connections to Autonion unlock helper service" | Out-Null

# Step 4: Start the service
Write-Host "[4/5] Starting service..." -ForegroundColor Yellow
Start-Service -Name AutonionUnlockHelper

# Step 5: Verify
Write-Host "[5/5] Verifying..." -ForegroundColor Yellow
Write-Host ""

Write-Host "Service Status:" -ForegroundColor Cyan
Get-Service AutonionUnlockHelper | Format-Table Status, DisplayName -AutoSize

Write-Host "Firewall Rules:" -ForegroundColor Cyan
Get-NetFirewallRule -DisplayName "Autonion Unlock Helper*" | Format-Table DisplayName, Direction, Profile, Enabled, Action -AutoSize

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " Update complete! Restart PC to test." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

Read-Host "Press Enter to exit..."
