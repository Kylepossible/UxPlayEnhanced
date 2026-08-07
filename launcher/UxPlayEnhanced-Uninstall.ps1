$ErrorActionPreference = "Stop"

$uninstallKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\UxPlayEnhanced"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    $elevatedProcess = Start-Process -FilePath "powershell.exe" -Verb RunAs `
        -ArgumentList $arguments -Wait -PassThru
    exit $elevatedProcess.ExitCode
}

# Resolve the directory to delete from the registry entry that setup wrote, not
# from this script's own location. This script ships inside the release ZIP, so
# a location-derived path would delete whatever folder the user happened to run
# it from -- typically their extracted download.
function Get-InstalledProductRoot {
    $recorded = (Get-ItemProperty -Path $uninstallKey -Name InstallLocation -ErrorAction SilentlyContinue).InstallLocation
    if ([string]::IsNullOrWhiteSpace($recorded)) {
        return $null
    }

    $expectedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:ProgramFiles "UxPlayEnhanced"))
    $candidate = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($recorded))

    # Accept the product root itself or a directory beneath it, and nothing else.
    $isExpected = $candidate -ieq $expectedRoot -or
        $candidate.StartsWith($expectedRoot.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $isExpected) {
        throw "Refusing to remove '$candidate': it is outside '$expectedRoot'. Delete it manually if it is stale."
    }

    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        return $null
    }
    return $candidate
}

$productRoot = Get-InstalledProductRoot

if ($productRoot) {
    $installPrefix = $productRoot.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith($installPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

Get-NetFirewallRule -Group "UxPlayEnhanced" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

$desktopShortcut = Join-Path ([Environment]::GetFolderPath("CommonDesktopDirectory")) "UxPlayEnhanced.lnk"
$startMenuShortcut = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\UxPlayEnhanced.lnk"
Remove-Item -LiteralPath $desktopShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $startMenuShortcut -Force -ErrorAction SilentlyContinue

Remove-Item -Path $uninstallKey -Recurse -Force -ErrorAction SilentlyContinue

if ($productRoot) {
    # Delete from a detached process so the install directory can be removed
    # while this script is still running out of it.
    $escapedProductRoot = $productRoot.Replace("'", "''")
    $cleanup = "Start-Sleep -Milliseconds 500; Remove-Item -LiteralPath '$escapedProductRoot' -Recurse -Force"
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        $cleanup
    )
    Write-Host "UxPlayEnhanced has been removed from $productRoot." -ForegroundColor Green
} else {
    Write-Host "Firewall rules and shortcuts were removed." -ForegroundColor Green
    Write-Host "No installed copy was registered, so no files were deleted." -ForegroundColor Yellow
    Write-Host "If you are using the portable release, delete its folder yourself." -ForegroundColor Yellow
}
