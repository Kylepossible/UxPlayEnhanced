@echo off
:: UxPlay AirPlay Receiver - No Bonjour Required (Embedded mDNS)
:: Mirrors your iPhone/iPad screen to this PC
cd /d "%~dp0"
set GST_PLUGIN_PATH=%~dp0lib\gstreamer-1.0
set PATH=%~dp0;%PATH%

:: Uses your computer's hostname as the AirPlay name
start /min "" uxplay.exe -n "%COMPUTERNAME%" -nh -vsync -h265
