@echo off
setlocal
cd /d "%~dp0"

:: The PowerShell installer requests elevation, copies the portable package,
:: creates the desktop shortcut, and configures the AirPlay firewall rules.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0UxPlayEnhanced-Setup.ps1"
if errorlevel 1 (
    echo.
    echo Installation failed. See the error above.
    pause
    exit /b 1
)

exit /b 0
