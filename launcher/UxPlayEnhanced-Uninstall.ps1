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

$installDir = Split-Path -Parent $PSCommandPath
$desktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "UxPlayEnhanced.lnk"
$startMenuShortcut = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\UxPlayEnhanced.lnk"

Get-Process UxPlayTray, uxplay -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$installDir\*" } |
    ForEach-Object { $_.Kill() }

Get-NetFirewallRule -Group "UxPlayEnhanced" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

[System.IO.File]::Delete($desktopShortcut)
[System.IO.File]::Delete($startMenuShortcut)
Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\UxPlayEnhanced" -Recurse -Force -ErrorAction SilentlyContinue

$escapedInstallDir = $installDir.Replace("'", "''")
$cleanup = "Start-Sleep -Milliseconds 500; Remove-Item -LiteralPath '$escapedInstallDir' -Recurse -Force"
Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-Command",
    $cleanup
)

Write-Host "UxPlayEnhanced has been removed." -ForegroundColor Green
