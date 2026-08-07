@echo off
:: UxPlay Debug Mode - shows console output and logs to debug.log
cd /d "%~dp0"
set GST_PLUGIN_PATH=%~dp0lib\gstreamer-1.0
set PATH=%~dp0;%PATH%

echo Starting UxPlay in debug mode...
echo Connect from your iPhone/iPad, let it play, then close this window when done.
echo The log will be saved to debug.log in this folder.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0uxplay.exe' -n '%COMPUTERNAME%' -nh -d -vsync 2^>^&1 ^| Tee-Object -FilePath '%~dp0debug.log'"
pause
