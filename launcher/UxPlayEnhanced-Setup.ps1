$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $arguments
    exit 0
}

$sourceDir = Split-Path -Parent $PSCommandPath
$installDir = Join-Path $env:ProgramFiles "UxPlayEnhanced"
$trayPath = Join-Path $installDir "UxPlayTray.exe"
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

# Stop only instances launched from this UxPlayEnhanced install directory.
Get-Process UxPlayTray, uxplay -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $trayPath -or $_.Path -eq $uxplayPath } |
    ForEach-Object { $_.Kill() }

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Get-ChildItem -LiteralPath $sourceDir -Force |
    Where-Object { $_.Name -notin $excludedFiles } |
    ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $installDir -Recurse -Force
    }

if (-not (Test-Path $trayPath)) {
    throw "UxPlayTray.exe was not copied to $installDir."
}

# Replace only this application's firewall rules. The child uxplay.exe owns
# the AirPlay sockets, so the rules target it rather than the tray launcher.
Get-NetFirewallRule -Group $firewallGroup -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

New-NetFirewallRule -DisplayName "UxPlayEnhanced AirPlay (TCP)" `
    -Group $firewallGroup -Direction Inbound -Action Allow -Protocol TCP `
    -Program $uxplayPath -Profile Private,Public `
    -Description "Allow UxPlayEnhanced AirPlay control and mirroring" | Out-Null

New-NetFirewallRule -DisplayName "UxPlayEnhanced AirPlay (UDP)" `
    -Group $firewallGroup -Direction Inbound -Action Allow -Protocol UDP `
    -Program $uxplayPath -Profile Private,Public `
    -Description "Allow UxPlayEnhanced mDNS and RTP audio/video streams" | Out-Null

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
New-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value "2.3.0" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name Publisher -Value "Kylepossible" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name InstallLocation -Value $installDir -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name UninstallString -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$installDir\UxPlayEnhanced-Uninstall.ps1`"" -PropertyType String -Force | Out-Null

Write-Host "UxPlayEnhanced installed to $installDir" -ForegroundColor Green
Write-Host "Desktop shortcut created: $desktopDir\UxPlayEnhanced.lnk" -ForegroundColor Green
Write-Host "Firewall rules created for AirPlay TCP and UDP." -ForegroundColor Green
Write-Host ""
Write-Host "You can now launch UxPlayEnhanced from the desktop." -ForegroundColor Cyan
Read-Host "Press Enter to close"
