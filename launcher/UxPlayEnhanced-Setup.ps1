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

$sourceDir = Split-Path -Parent $PSCommandPath
$installDir = Join-Path $env:ProgramFiles "UxPlayEnhanced"
$trayPath = Join-Path $installDir "UxPlayEnhanced.exe"
$uxplayPath = Join-Path $installDir "uxplay.exe"
$desktopDir = [Environment]::GetFolderPath("Desktop")
$startMenuDir = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"
$firewallGroup = "UxPlayEnhanced"
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

# Stop only instances launched from this UxPlayEnhanced install directory.
Get-Process UxPlayEnhanced, UxPlayTray, uxplay -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $trayPath -or $_.Path -eq $uxplayPath } |
    ForEach-Object { $_.Kill() }

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Get-ChildItem -LiteralPath $sourceDir -Force |
    Where-Object { $_.Name -notin $excludedFiles } |
    ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $installDir -Recurse -Force
    }

if (-not (Test-Path $trayPath)) {
    throw "UxPlayEnhanced.exe was not copied to $installDir."
}

Get-ChildItem -LiteralPath $installDir -Recurse -File -Force |
    Unblock-File -ErrorAction Stop

# Replace only this application's firewall rules. The child uxplay.exe owns
# the AirPlay sockets, so the rules target it rather than the tray launcher.
Get-NetFirewallRule -Group $firewallGroup -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

# A Windows-generated block rule overrides an allow rule. Remove only enabled
# inbound block rules that target this exact installed uxplay.exe path.
$normalizedUxplayPath = [System.IO.Path]::GetFullPath($uxplayPath)
Get-NetFirewallRule -Direction Inbound -Action Block -Enabled True -ErrorAction SilentlyContinue |
    ForEach-Object {
        $rule = $_
        $applicationFilter = $rule | Get-NetFirewallApplicationFilter
        if ($applicationFilter.Program -and $applicationFilter.Program -ne "Any") {
            $ruleProgram = [System.IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables($applicationFilter.Program)
            )
            if ($ruleProgram -ieq $normalizedUxplayPath) {
                $rule | Remove-NetFirewallRule
            }
        }
    }

New-NetFirewallRule -DisplayName "UxPlayEnhanced AirPlay (TCP)" `
    -Group $firewallGroup -Direction Inbound -Action Allow -Protocol TCP `
    -Program $uxplayPath -Profile Private,Public -Enabled True `
    -Description "Allow UxPlayEnhanced AirPlay control and mirroring" | Out-Null

New-NetFirewallRule -DisplayName "UxPlayEnhanced AirPlay (UDP)" `
    -Group $firewallGroup -Direction Inbound -Action Allow -Protocol UDP `
    -Program $uxplayPath -Profile Private,Public -Enabled True `
    -Description "Allow UxPlayEnhanced mDNS and RTP audio/video streams" | Out-Null

# Do not report success unless both rules are enabled, inbound allows for the
# exact installed executable and expected protocols.
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
        $rule.Action -ne "Allow" -or $ruleProgram -ine $normalizedUxplayPath -or
        $portFilter.Protocol -ne $expected.Protocol) {
        throw "Firewall verification failed for $($expected.Name)."
    }
}

$shell = New-Object -ComObject WScript.Shell

$desktopShortcut = $shell.CreateShortcut((Join-Path $desktopDir "UxPlayEnhanced.lnk"))
$desktopShortcut.TargetPath = $trayPath
$desktopShortcut.WorkingDirectory = $installDir
$desktopShortcut.IconLocation = "$trayPath,0"
$desktopShortcut.Description = "UxPlayEnhanced AirPlay audio receiver"
$desktopShortcut.Save()

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
New-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value "1.0.1" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name Publisher -Value "Kylepossible" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name InstallLocation -Value $installDir -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name UninstallString -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$installDir\UxPlayEnhanced-Uninstall.ps1`"" -PropertyType String -Force | Out-Null

Write-Host "UxPlayEnhanced installed to $installDir" -ForegroundColor Green
Write-Host "Desktop shortcut created: $desktopDir\UxPlayEnhanced.lnk" -ForegroundColor Green
Write-Host "Firewall rules created and verified for AirPlay TCP and UDP." -ForegroundColor Green
Write-Host ""
Write-Host "You can now launch UxPlayEnhanced from the desktop." -ForegroundColor Cyan
Read-Host "Press Enter to close"
