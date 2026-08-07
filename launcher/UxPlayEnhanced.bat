@echo off
:: UxPlayEnhanced - lightweight Bonjour-free AirPlay audio receiver
cd /d "%~dp0"
set GST_PLUGIN_PATH=%~dp0lib\gstreamer-1.0
set PATH=%~dp0;%PATH%

:: Prefer the branded standalone tray executable. Keep the previous executable
:: name as an upgrade fallback, then fall back to direct audio-only UxPlay.
if exist "%~dp0UxPlayEnhanced.exe" (
    start "" "%~dp0UxPlayEnhanced.exe"
) else if exist "%~dp0UxPlayTray.exe" (
    start "" "%~dp0UxPlayTray.exe"
) else (
    start /min "" uxplay.exe -n "%COMPUTERNAME%" -nh -vs 0
)
