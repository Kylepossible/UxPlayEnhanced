# Creates and verifies Windows Firewall rules for portable UxPlayEnhanced.

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    $elevatedProcess = Start-Process -FilePath "powershell.exe" -Verb RunAs `
        -ArgumentList $arguments -Wait -PassThru
    exit $elevatedProcess.ExitCode
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exePath = Join-Path $scriptDir "uxplay.exe"
$firewallGroup = "UxPlayEnhanced"

if (-not (Test-Path $exePath)) {
    Write-Host "ERROR: uxplay.exe not found at $exePath" -ForegroundColor Red
    Write-Host "Place this script in the same folder as uxplay.exe" -ForegroundColor Yellow
    exit 1
}

Get-ChildItem -LiteralPath $scriptDir -Recurse -File -Force |
    Unblock-File -ErrorAction SilentlyContinue

# Remove old portable rules if they exist.
Remove-NetFirewallRule -DisplayName "UxPlay AirPlay (TCP)" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "UxPlay AirPlay (UDP)" -ErrorAction SilentlyContinue
Get-NetFirewallRule -Group $firewallGroup -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

# Remove only enabled inbound block rules for this exact executable. Windows
# block rules take precedence over allow rules.
$normalizedExePath = [System.IO.Path]::GetFullPath($exePath)
Get-NetFirewallRule -Direction Inbound -Action Block -Enabled True -ErrorAction SilentlyContinue |
    ForEach-Object {
        $rule = $_
        $applicationFilter = $rule | Get-NetFirewallApplicationFilter
        if ($applicationFilter.Program -and $applicationFilter.Program -ne "Any") {
            $ruleProgram = [System.IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables($applicationFilter.Program)
            )
            if ($ruleProgram -ieq $normalizedExePath) {
                $rule | Remove-NetFirewallRule
            }
        }
    }

# Allow inbound TCP (AirPlay control + mirroring)
New-NetFirewallRule -DisplayName "UxPlayEnhanced AirPlay (TCP)" `
    -Group $firewallGroup -Direction Inbound -Action Allow -Protocol TCP `
    -Program $exePath -Profile Private,Public -Enabled True `
    -Description "Allow AirPlay connections to UxPlay" | Out-Null

# Allow inbound UDP (mDNS discovery + RTP audio/video streams)
New-NetFirewallRule -DisplayName "UxPlayEnhanced AirPlay (UDP)" `
    -Group $firewallGroup -Direction Inbound -Action Allow -Protocol UDP `
    -Program $exePath -Profile Private,Public -Enabled True `
    -Description "Allow AirPlay UDP streams and mDNS to UxPlay" | Out-Null

foreach ($expected in @(
    @{ Name = "UxPlayEnhanced AirPlay (TCP)"; Protocol = "TCP" },
    @{ Name = "UxPlayEnhanced AirPlay (UDP)"; Protocol = "UDP" }
)) {
    $rule = Get-NetFirewallRule -DisplayName $expected.Name -ErrorAction Stop
    $applicationFilter = $rule | Get-NetFirewallApplicationFilter
    $portFilter = $rule | Get-NetFirewallPortFilter
    $ruleProgram = [System.IO.Path]::GetFullPath(
        [Environment]::ExpandEnvironmentVariables($applicationFilter.Program)
    )
    if ($rule.Enabled -ne "True" -or $rule.Direction -ne "Inbound" -or
        $rule.Action -ne "Allow" -or $ruleProgram -ine $normalizedExePath -or
        $portFilter.Protocol -ne $expected.Protocol) {
        throw "Firewall verification failed for $($expected.Name)."
    }
}

Write-Host ""
Write-Host "Firewall rules created and verified successfully!" -ForegroundColor Green
Write-Host "You can now run UxPlayEnhanced and connect from your Apple device." -ForegroundColor Cyan
