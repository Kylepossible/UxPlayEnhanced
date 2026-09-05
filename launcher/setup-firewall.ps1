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
$firewallRules = @(
    [pscustomobject]@{
        RuleName = "UxPlayEnhanced-AirPlay-TCP"
        DisplayName = "UxPlayEnhanced AirPlay (TCP)"
        Protocol = "TCP"
        Description = "Allow AirPlay connections to UxPlayEnhanced"
    },
    [pscustomobject]@{
        RuleName = "UxPlayEnhanced-AirPlay-UDP"
        DisplayName = "UxPlayEnhanced AirPlay (UDP)"
        Protocol = "UDP"
        Description = "Allow AirPlay UDP streams and mDNS to UxPlayEnhanced"
    }
)

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
foreach ($managedRule in $firewallRules) {
    Get-NetFirewallRule -Name $managedRule.RuleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Get-NetFirewallRule -DisplayName $managedRule.DisplayName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

# Remove only enabled inbound block rules for this exact executable. Windows
# block rules take precedence over allow rules.
$normalizedExePath = [System.IO.Path]::GetFullPath($exePath)
Get-NetFirewallRule -Direction Inbound -Action Block -Enabled True -ErrorAction SilentlyContinue |
    ForEach-Object {
        $rule = $_
        $removeRule = $false
        $applicationFilters = @($rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue)
        foreach ($applicationFilter in $applicationFilters) {
            $program = [string]$applicationFilter.Program
            if ($program -and $program -ne "Any") {
                try {
                    $ruleProgram = [System.IO.Path]::GetFullPath(
                        [Environment]::ExpandEnvironmentVariables($program)
                    )
                    if ($ruleProgram -ieq $normalizedExePath) {
                        $removeRule = $true
                        break
                    }
                } catch {
                    # Ignore non-file application filters from unrelated rules.
                }
            }
        }
        if ($removeRule) {
            $rule | Remove-NetFirewallRule
        }
    }

foreach ($managedRule in $firewallRules) {
    New-NetFirewallRule -Name $managedRule.RuleName `
        -DisplayName $managedRule.DisplayName -Group $firewallGroup `
        -Direction Inbound -Action Allow -Protocol $managedRule.Protocol `
        -Program $exePath -Profile Private,Public -Enabled True `
        -Description $managedRule.Description | Out-Null
}

foreach ($expected in $firewallRules) {
    $matchingRules = @(Get-NetFirewallRule -Name $expected.RuleName -ErrorAction Stop)
    if ($matchingRules.Count -ne 1) {
        throw "Firewall verification expected one rule named $($expected.RuleName), found $($matchingRules.Count)."
    }
    $rule = $matchingRules[0]
    $applicationFilters = @($rule | Get-NetFirewallApplicationFilter)
    $portFilters = @($rule | Get-NetFirewallPortFilter)
    if ($applicationFilters.Count -ne 1 -or $portFilters.Count -ne 1) {
        throw "Firewall verification found unexpected filters for $($expected.DisplayName)."
    }
    $program = $applicationFilters[0].Program
    if ($program -is [array] -or [string]::IsNullOrWhiteSpace([string]$program)) {
        throw "Firewall verification found an invalid program for $($expected.DisplayName)."
    }
    $ruleProgram = [System.IO.Path]::GetFullPath(
        [Environment]::ExpandEnvironmentVariables([string]$program)
    )
    if ($rule.DisplayName -ne $expected.DisplayName -or
        $rule.Enabled -ne "True" -or $rule.Direction -ne "Inbound" -or
        $rule.Action -ne "Allow" -or $ruleProgram -ine $normalizedExePath -or
        $portFilters[0].Protocol -ne $expected.Protocol) {
        throw "Firewall verification failed for $($expected.DisplayName)."
    }
}

Write-Host ""
Write-Host "Firewall rules created and verified successfully!" -ForegroundColor Green
Write-Host "You can now run UxPlayEnhanced and connect from your Apple device." -ForegroundColor Cyan
