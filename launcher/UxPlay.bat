@echo off
:: UxPlay AirPlay Receiver - No Bonjour Required (Embedded mDNS)
:: Receives iPhone/iPad audio without starting the local video renderer
cd /d "%~dp0"
set GST_PLUGIN_PATH=%~dp0lib\gstreamer-1.0
set PATH=%~dp0;%PATH%

:: The release includes a standalone tray executable; keep a direct fallback
:: for source/build folders where it has not been generated yet.
if exist "%~dp0UxPlayTray.exe" (
    start "" "%~dp0UxPlayTray.exe"
) else (
    start /min "" uxplay.exe -n "%COMPUTERNAME%" -nh -vs 0
)
