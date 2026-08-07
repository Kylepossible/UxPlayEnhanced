@echo off
:: UxPlay AirPlay Receiver - No Bonjour Required (Embedded mDNS)
:: Receives iPhone/iPad audio without starting the local video renderer
cd /d "%~dp0"
set GST_PLUGIN_PATH=%~dp0lib\gstreamer-1.0
set PATH=%~dp0;%PATH%

:: Uses your computer's hostname as the AirPlay name
start /min "" uxplay.exe -n "%COMPUTERNAME%" -nh -vs 0
