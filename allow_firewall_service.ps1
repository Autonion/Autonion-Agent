# Self-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Write-Host "=== Creating Firewall Rules for Autonion Unlock Helper ===" -ForegroundColor Cyan
Write-Host ""

# Remove any stale rules first
Write-Host "Removing old rules..." -ForegroundColor Gray
Remove-NetFirewallRule -DisplayName "Autonion Unlock Helper (WebSocket)" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Autonion Unlock Helper (mDNS In)" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Autonion Unlock Helper (mDNS Out)" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Autonion Unlock Helper (Service)" -ErrorAction SilentlyContinue
# Also remove the old script's rules if they somehow exist
Remove-NetFirewallRule -DisplayName "Autonion Agent (mDNS)" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Autonion Agent (WebSocket)" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Autonion Agent (mDNS Out)" -ErrorAction SilentlyContinue

# Port-based rules (-Profile Any = works on Private, Public, AND Domain)
# This is critical: before first login, Windows NLA may classify the network differently
Write-Host "Creating INBOUND TCP 4545 (WebSocket)..." -ForegroundColor Cyan
New-NetFirewallRule -DisplayName "Autonion Unlock Helper (WebSocket)" -Direction Inbound -Protocol TCP -LocalPort 4545 -Action Allow -Profile Any -Description "Allows Android companion to connect to Autonion pre-login WebSocket server" | Out-Null

Write-Host "Creating INBOUND UDP 5353 (mDNS)..." -ForegroundColor Cyan
New-NetFirewallRule -DisplayName "Autonion Unlock Helper (mDNS In)" -Direction Inbound -Protocol UDP -LocalPort 5353 -Action Allow -Profile Any -Description "Allows mDNS queries to reach Autonion pre-login service" | Out-Null

Write-Host "Creating OUTBOUND UDP 5353 (mDNS announcements)..." -ForegroundColor Cyan
New-NetFirewallRule -DisplayName "Autonion Unlock Helper (mDNS Out)" -Direction Outbound -Protocol UDP -RemotePort 5353 -Action Allow -Profile Any -Description "Allows Autonion pre-login service to send mDNS announcements" | Out-Null

# Program-based rule as belt-and-suspenders
$servicePath = "C:\Program Files\Autonion Agent\autonion_unlock_helper.exe"
if (Test-Path $servicePath) {
    Write-Host "Creating program-based rule for $servicePath..." -ForegroundColor Cyan
    New-NetFirewallRule -DisplayName "Autonion Unlock Helper (Service)" -Direction Inbound -Program $servicePath -Action Allow -Profile Any -Description "Allows all inbound connections to Autonion unlock helper service" | Out-Null
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " Firewall rules created successfully!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

# Show results
Write-Host "Active Autonion Unlock Helper firewall rules:" -ForegroundColor Cyan
Get-NetFirewallRule -DisplayName "Autonion Unlock Helper*" | Format-Table DisplayName, Direction, Action, Profile, Enabled -AutoSize

Read-Host "Press Enter to exit..."
