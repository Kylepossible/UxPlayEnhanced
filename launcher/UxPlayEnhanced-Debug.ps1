$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exePath = Join-Path $scriptDir "uxplay.exe"
$pluginPath = Join-Path $scriptDir "lib\gstreamer-1.0"

# Write the debug log beside the tray application's logs rather than next to
# the executable. After installation that directory is C:\Program Files\
# UxPlayEnhanced, which a normal user cannot write to, so Tee-Object failed and
# took the debug session with it.
$dataDir = $env:UXPLAYENHANCED_DATA_DIR
if (-not $dataDir) {
    if ($env:LOCALAPPDATA) {
        $dataDir = Join-Path $env:LOCALAPPDATA "UxPlayEnhanced"
    } else {
        $dataDir = Join-Path $HOME "UxPlayEnhanced"
    }
}
$logDir = Join-Path $dataDir "Logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir "UxPlayEnhanced-Debug.log"

$env:GST_PLUGIN_PATH = $pluginPath
$env:Path = "$scriptDir;$env:Path"

Write-Host "Starting UxPlayEnhanced debug mode..."
Write-Host "Connect from your iPhone/iPad, reproduce the issue, then close this window."
Write-Host "The log will be saved to $logPath"

if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    Write-Host "ERROR: uxplay.exe was not found at $exePath" -ForegroundColor Red
    exit 1
}

& $exePath -n $env:COMPUTERNAME -nh -vs 0 -d 2>&1 |
    Tee-Object -FilePath $logPath
