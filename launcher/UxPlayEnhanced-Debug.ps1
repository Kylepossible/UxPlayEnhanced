$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exePath = Join-Path $scriptDir "uxplay.exe"
$pluginPath = Join-Path $scriptDir "lib\gstreamer-1.0"
$logPath = Join-Path $scriptDir "debug.log"

$env:GST_PLUGIN_PATH = $pluginPath
$env:Path = "$scriptDir;$env:Path"

Write-Host "Starting UxPlayEnhanced debug mode..."
Write-Host "Connect from your iPhone/iPad, reproduce the issue, then close this window."
Write-Host "The log will be saved to $logPath"

& $exePath -n $env:COMPUTERNAME -nh -vs 0 -d 2>&1 |
    Tee-Object -FilePath $logPath
