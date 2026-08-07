# Run as Administrator to create Windows Firewall rules for UxPlay
# Usage: Right-click > Run with PowerShell (as Admin)
#   or:  powershell -ExecutionPolicy Bypass -File setup-firewall.ps1

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exePath = Join-Path $scriptDir "uxplay.exe"

if (-not (Test-Path $exePath)) {
    Write-Host "ERROR: uxplay.exe not found at $exePath" -ForegroundColor Red
    Write-Host "Place this script in the same folder as uxplay.exe" -ForegroundColor Yellow
    Start-Sleep -Seconds 3
    exit 1
}

# Remove old portable rules if they exist
Remove-NetFirewallRule -DisplayName "UxPlay AirPlay (TCP)" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "UxPlay AirPlay (UDP)" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "UxPlayEnhanced AirPlay (TCP)" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "UxPlayEnhanced AirPlay (UDP)" -ErrorAction SilentlyContinue

# Allow inbound TCP (AirPlay control + mirroring)
New-NetFirewallRule -DisplayName "UxPlayEnhanced AirPlay (TCP)" `
    -Direction Inbound -Action Allow -Protocol TCP `
    -Program $exePath -Profile Private,Public `
    -Description "Allow AirPlay connections to UxPlay"

# Allow inbound UDP (mDNS discovery + RTP audio/video streams)
New-NetFirewallRule -DisplayName "UxPlayEnhanced AirPlay (UDP)" `
    -Direction Inbound -Action Allow -Protocol UDP `
    -Program $exePath -Profile Private,Public `
    -Description "Allow AirPlay UDP streams and mDNS to UxPlay"

Write-Host ""
Write-Host "Firewall rules created successfully!" -ForegroundColor Green
Write-Host "You can now run UxPlayEnhanced and connect from your Apple device." -ForegroundColor Cyan
Start-Sleep -Seconds 3
