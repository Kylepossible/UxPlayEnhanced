param(
    [switch]$Cleanup,
    [string]$ProductRoot
)

$ErrorActionPreference = "Stop"
$uninstallKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\UxPlayEnhanced"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ExpectedProductRoot {
    return [System.IO.Path]::GetFullPath((Join-Path $env:ProgramFiles "UxPlayEnhanced"))
}

function Assert-SafeProductRoot {
    param([Parameter(Mandatory = $true)][string]$Candidate)

    $expected = Get-ExpectedProductRoot
    $resolved = [System.IO.Path]::GetFullPath(
        [Environment]::ExpandEnvironmentVariables($Candidate)
    )
    $isExpected = $resolved -ieq $expected -or
        $resolved.StartsWith($expected.TrimEnd('\') + '\app-', [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $isExpected) {
        throw "Refusing to remove '$resolved': it is outside '$expected'."
    }
    return $expected
}

function Get-InstalledProductRoot {
    $recorded = (Get-ItemProperty -Path $uninstallKey -Name InstallLocation -ErrorAction SilentlyContinue).InstallLocation
    if ([string]::IsNullOrWhiteSpace($recorded)) {
        return $null
    }
    $root = Assert-SafeProductRoot -Candidate $recorded
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return $null
    }
    return $root
}

function Stop-InstalledProcesses {
    param([Parameter(Mandatory = $true)][string]$InstallDirectory)

    $prefix = [System.IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\') + '\'
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $processFreeSince = $null
    do {
        $targets = @(
            Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
                $_.ExecutablePath -and
                $_.ExecutablePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
            }
        )
        if ($targets.Count -eq 0) {
            if ($null -eq $processFreeSince) {
                $processFreeSince = [DateTime]::UtcNow
            } elseif (([DateTime]::UtcNow - $processFreeSince).TotalSeconds -ge 1) {
                return
            }
        } else {
            $processFreeSince = $null
            foreach ($target in $targets) {
                Stop-Process -Id $target.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "UxPlayEnhanced processes did not stop before uninstall."
}

function Assert-NoReparsePoints {
    param([Parameter(Mandatory = $true)][string]$Root)

    $reparsePoints = @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop |
            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }
    )
    if ($reparsePoints.Count -gt 0) {
        throw "Refusing recursive removal because the install contains a reparse point: $($reparsePoints[0].FullName)"
    }
}

function Register-DeleteAtRestart {
    param([Parameter(Mandatory = $true)][string]$Root)

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class UxPlayEnhancedPendingDelete {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool MoveFileEx(string existingName, string newName, int flags);
}
"@

    $paths = @()
    $paths += Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction Stop |
        Select-Object -ExpandProperty FullName
    $paths += Get-ChildItem -LiteralPath $Root -Recurse -Directory -Force -ErrorAction Stop |
        Sort-Object { $_.FullName.Length } -Descending |
        Select-Object -ExpandProperty FullName
    $paths += $Root

    $failures = @()
    foreach ($path in $paths) {
        if (-not [UxPlayEnhancedPendingDelete]::MoveFileEx($path, $null, 4)) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $failures += "$path (Win32 error $errorCode)"
        }
    }
    if ($failures.Count -gt 0) {
        throw "Could not schedule all remaining files for deletion: $($failures -join '; ')"
    }
}

function Remove-Registration {
    Get-NetFirewallRule -Group "UxPlayEnhanced" -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue

    $desktopShortcut = Join-Path ([Environment]::GetFolderPath("CommonDesktopDirectory")) "UxPlayEnhanced.lnk"
    $startMenuShortcut = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\UxPlayEnhanced.lnk"
    Remove-Item -LiteralPath $desktopShortcut -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $startMenuShortcut -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $uninstallKey -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not (Test-IsAdministrator)) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    if ($Cleanup) {
        $arguments += ' -Cleanup -ProductRoot "' + $ProductRoot + '"'
    }
    $elevatedProcess = Start-Process -FilePath "powershell.exe" -Verb RunAs `
        -ArgumentList $arguments -Wait -PassThru
    exit $elevatedProcess.ExitCode
}

if ($Cleanup) {
    $safeRoot = Assert-SafeProductRoot -Candidate $ProductRoot
    if (-not (Test-Path -LiteralPath $safeRoot -PathType Container)) {
        Remove-Registration
        Write-Host "UxPlayEnhanced was already absent; registration was removed." -ForegroundColor Green
        exit 0
    }

    Stop-InstalledProcesses -InstallDirectory $safeRoot
    Assert-NoReparsePoints -Root $safeRoot

    $lastRemovalError = $null
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            Remove-Item -LiteralPath $safeRoot -Recurse -Force -ErrorAction Stop
            $lastRemovalError = $null
        } catch {
            $lastRemovalError = $_
        }
        if (-not (Test-Path -LiteralPath $safeRoot)) {
            break
        }
        Start-Sleep -Milliseconds 500
    }

    $restartRequired = Test-Path -LiteralPath $safeRoot
    if ($restartRequired) {
        if ($lastRemovalError) {
            Write-Warning "Immediate removal was blocked; scheduling the remaining files for the next restart. $($lastRemovalError.Exception.Message)"
        }
        Assert-NoReparsePoints -Root $safeRoot
        Register-DeleteAtRestart -Root $safeRoot
    }

    Remove-Registration
    if ($restartRequired) {
        Write-Host "UxPlayEnhanced is unregistered. Protected files will be removed after Windows restarts." -ForegroundColor Yellow
    } else {
        Write-Host "UxPlayEnhanced has been removed." -ForegroundColor Green
    }
    exit 0
}

$installedRoot = Get-InstalledProductRoot
if (-not $installedRoot) {
    Remove-Registration
    Write-Host "Firewall rules and shortcuts were removed." -ForegroundColor Green
    Write-Host "No installed copy was registered, so no files were deleted." -ForegroundColor Yellow
    Write-Host "If you are using the portable release, delete its folder yourself." -ForegroundColor Yellow
    exit 0
}

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("UxPlayEnhanced-Uninstall-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
$temporaryScript = Join-Path $temporaryDirectory "UxPlayEnhanced-Uninstall.ps1"
Copy-Item -LiteralPath $PSCommandPath -Destination $temporaryScript -Force

try {
    Set-Location ([System.IO.Path]::GetTempPath())
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $temporaryScript `
        -Cleanup -ProductRoot $installedRoot
    exit $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
