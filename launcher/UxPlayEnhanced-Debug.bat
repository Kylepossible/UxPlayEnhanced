@echo off
:: UxPlayEnhanced debug mode - shows console output and logs to debug.log
cd /d "%~dp0"
set GST_PLUGIN_PATH=%~dp0lib\gstreamer-1.0
set PATH=%~dp0;%PATH%

echo Starting UxPlayEnhanced in debug mode...
echo Connect from your iPhone/iPad, let it play, then close this window when done.
echo The log will be saved to debug.log in this folder.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0UxPlayEnhanced-Debug.ps1"
pause
