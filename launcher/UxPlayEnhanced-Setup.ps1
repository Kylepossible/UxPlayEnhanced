param(
    [switch]$SkipPause
)

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    if ($SkipPause) {
        $arguments += ' -SkipPause'
    }
    $elevatedProcess = Start-Process -FilePath "powershell.exe" -Verb RunAs `
        -ArgumentList $arguments -Wait -PassThru
    exit $elevatedProcess.ExitCode
}

function Stop-InstalledProcesses {
    param([Parameter(Mandatory = $true)][string]$InstallDirectory)

    $installPrefix = [System.IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\') + '\'
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $processFreeSince = $null
    do {
        $targets = @(
            Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
                $_.ExecutablePath -and
                $_.ExecutablePath.StartsWith($installPrefix, [System.StringComparison]::OrdinalIgnoreCase)
            }
        )

        if ($targets.Count -eq 0) {
            if ($null -eq $processFreeSince) {
                $processFreeSince = [DateTime]::UtcNow
            } elseif (([DateTime]::UtcNow - $processFreeSince).TotalSeconds -ge 1) {
                return
            }
        } else {
            $processFreeSince = $null
            foreach ($target in $targets) {
                Write-Host "Stopping $($target.Name) (PID $($target.ProcessId))..."
                try {
                    Stop-Process -Id $target.ProcessId -Force -ErrorAction Stop
                } catch {
                    if (Get-Process -Id $target.ProcessId -ErrorAction SilentlyContinue) {
                        Write-Warning "Could not stop $($target.Name) (PID $($target.ProcessId)): $($_.Exception.Message)"
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    $remaining = @(
        Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith($installPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        }
    )
    $remainingText = $remaining | ForEach-Object { "$($_.Name) (PID $($_.ProcessId))" }
    throw "Installed UxPlayEnhanced processes did not stop: $($remainingText -join ', ')."
}

function Copy-PackageFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $sourceItem = Get-Item -LiteralPath $Source -Force
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $destinationItem = Get-Item -LiteralPath $Destination -Force
        if ($sourceItem.Length -eq $destinationItem.Length) {
            $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
            $destinationHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
            if ($sourceHash -eq $destinationHash) {
                return $false
            }
        }
    }

    $destinationDirectory = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null

    $attempts = 60
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
            $destinationHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
            if ($sourceHash -ne $destinationHash) {
                throw "Hash verification failed after copying $Destination."
            }
            return $true
        } catch {
            if ($attempt -eq $attempts) {
                throw
            }
            Write-Warning "Copy attempt $attempt failed for $Destination; retrying..."
            Start-Sleep -Milliseconds 500
        }
    }
}

$version = "1.1.1"
$sourceDir = Split-Path -Parent $PSCommandPath
$productRoot = Join-Path $env:ProgramFiles "UxPlayEnhanced"
$installDir = Join-Path $productRoot "app-$version"
$trayPath = Join-Path $installDir "UxPlayEnhanced.exe"
$uxplayPath = Join-Path $installDir "uxplay.exe"
$desktopDir = [Environment]::GetFolderPath("CommonDesktopDirectory")
$startMenuDir = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"
$firewallGroup = "UxPlayEnhanced"
$firewallRules = @(
    [pscustomobject]@{
        RuleName = "UxPlayEnhanced-AirPlay-TCP"
        DisplayName = "UxPlayEnhanced AirPlay (TCP)"
        Protocol = "TCP"
        Description = "Allow UxPlayEnhanced AirPlay control and mirroring"
    },
    [pscustomobject]@{
        RuleName = "UxPlayEnhanced-AirPlay-UDP"
        DisplayName = "UxPlayEnhanced AirPlay (UDP)"
        Protocol = "UDP"
        Description = "Allow UxPlayEnhanced mDNS and RTP audio/video streams"
    }
)
$excludedFiles = @(
    "UxPlayEnhanced-Setup.cmd",
    "UxPlayEnhanced-Setup.ps1"
)

Write-Host "Installing UxPlayEnhanced..." -ForegroundColor Cyan

if (-not (Test-Path (Join-Path $sourceDir "uxplay.exe"))) {
    throw "uxplay.exe was not found beside the installer. Extract the complete release ZIP first."
}

# ZIP downloads can carry Mark-of-the-Web metadata into every extracted file.
# Remove it from this release payload before copying so Windows does not block
# the installed executables or DLLs on first launch.
Get-ChildItem -LiteralPath $sourceDir -Recurse -File -Force |
    Unblock-File -ErrorAction SilentlyContinue

# Stop every running executable from any installed UxPlayEnhanced version and
# wait for the product directory to stay process-free before upgrading.
Stop-InstalledProcesses -InstallDirectory $productRoot

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
$copiedFileCount = 0
$unchangedFileCount = 0
Get-ChildItem -LiteralPath $sourceDir -Recurse -File -Force | ForEach-Object {
    $relativePath = $_.FullName.Substring($sourceDir.Length).TrimStart('\')
    if ($relativePath -notin $excludedFiles) {
        $destinationPath = Join-Path $installDir $relativePath
        if (Copy-PackageFile -Source $_.FullName -Destination $destinationPath) {
            $copiedFileCount++
        } else {
            $unchangedFileCount++
        }
    }
}

if (-not (Test-Path $trayPath)) {
    throw "UxPlayEnhanced.exe was not copied to $installDir."
}

Get-ChildItem -LiteralPath $installDir -Recurse -File -Force |
    Unblock-File -ErrorAction Stop

# Replace every locally managed version of this application's firewall rules.
# Older releases did not use stable rule names and could leave duplicate rules
# outside the current group, so remove both the group and exact display names.
Get-NetFirewallRule -Group $firewallGroup -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
foreach ($managedRule in $firewallRules) {
    Get-NetFirewallRule -Name $managedRule.RuleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Get-NetFirewallRule -DisplayName $managedRule.DisplayName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

# A Windows-generated block rule overrides an allow rule. Remove only enabled
# inbound block rules that target this exact installed uxplay.exe path.
$normalizedUxplayPath = [System.IO.Path]::GetFullPath($uxplayPath)
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
                    if ($ruleProgram -ieq $normalizedUxplayPath) {
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
        -Program $uxplayPath -Profile Private,Public -Enabled True `
        -Description $managedRule.Description | Out-Null
}

# Do not report success unless both rules are enabled, inbound allows for the
# exact installed executable and expected protocols.
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
        $rule.Action -ne "Allow" -or $ruleProgram -ine $normalizedUxplayPath -or
        $portFilters[0].Protocol -ne $expected.Protocol) {
        throw "Firewall verification failed for $($expected.DisplayName)."
    }
}

$shell = New-Object -ComObject WScript.Shell

$desktopShortcutPath = Join-Path $desktopDir "UxPlayEnhanced.lnk"
$desktopShortcut = $shell.CreateShortcut($desktopShortcutPath)
$desktopShortcut.TargetPath = $trayPath
$desktopShortcut.WorkingDirectory = $installDir
$desktopShortcut.IconLocation = "$trayPath,0"
$desktopShortcut.Description = "UxPlayEnhanced AirPlay audio receiver"
$desktopShortcut.Save()

if (-not (Test-Path -LiteralPath $desktopShortcutPath -PathType Leaf)) {
    throw "Desktop shortcut was not created at $desktopShortcutPath."
}
$verifiedDesktopShortcut = $shell.CreateShortcut($desktopShortcutPath)
if ([System.IO.Path]::GetFullPath($verifiedDesktopShortcut.TargetPath) -ine
    [System.IO.Path]::GetFullPath($trayPath)) {
    throw "Desktop shortcut verification failed: target is $($verifiedDesktopShortcut.TargetPath)."
}

New-Item -ItemType Directory -Path $startMenuDir -Force | Out-Null
$startMenuShortcut = $shell.CreateShortcut((Join-Path $startMenuDir "UxPlayEnhanced.lnk"))
$startMenuShortcut.TargetPath = $trayPath
$startMenuShortcut.WorkingDirectory = $installDir
$startMenuShortcut.IconLocation = "$trayPath,0"
$startMenuShortcut.Description = "UxPlayEnhanced AirPlay audio receiver"
$startMenuShortcut.Save()

$uninstallKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\UxPlayEnhanced"
New-Item -Path $uninstallKey -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name DisplayName -Value "UxPlayEnhanced" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value $version -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name Publisher -Value "Kylepossible" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name InstallLocation -Value $productRoot -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name DisplayIcon -Value $trayPath -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name UninstallString -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$installDir\UxPlayEnhanced-Uninstall.ps1`"" -PropertyType String -Force | Out-Null

Write-Host "UxPlayEnhanced installed to $installDir" -ForegroundColor Green
Write-Host "Package files verified: $copiedFileCount updated, $unchangedFileCount unchanged." -ForegroundColor Green
Write-Host "Desktop shortcut created and verified: $desktopShortcutPath" -ForegroundColor Green
Write-Host "Firewall rules created and verified for AirPlay TCP and UDP." -ForegroundColor Green
Write-Host ""
Write-Host "You can now launch UxPlayEnhanced from the desktop." -ForegroundColor Cyan
if (-not $SkipPause) {
    Read-Host "Press Enter to close"
}
