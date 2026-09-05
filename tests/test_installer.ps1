param(
    [Parameter(Mandatory = $true)][string]$PackageDir,
    [Parameter(Mandatory = $true)][string]$ResultPath
)
# Integration test: intentionally installs/repairs this release. Run elevated
# with Windows PowerShell 5.1 on a Windows test host.
$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This integration test requires an elevated Windows PowerShell process.'
}
$PackageDir = (Resolve-Path -LiteralPath $PackageDir).Path
$seedNames = @()
$result = [ordered]@{ Passed = $false; PowerShell = $PSVersionTable.PSVersion.ToString() }
Start-Transcript -LiteralPath ($ResultPath + '.log') | Out-Null
try {
    foreach ($protocol in @('TCP', 'UDP')) {
        foreach ($index in 1..2) {
            $name = 'UxPlayEnhanced-Test-' + [Guid]::NewGuid().ToString('N')
            $seedNames += $name
            New-NetFirewallRule -Name $name -DisplayName "UxPlayEnhanced AirPlay ($protocol)" `
                -Direction Inbound -Action Allow -Protocol $protocol -Profile Private,Public `
                -Program (Join-Path $PackageDir 'uxplay.exe') | Out-Null
        }
    }
    $duplicateRules = @(Get-NetFirewallRule -DisplayName 'UxPlayEnhanced AirPlay (TCP)')
    if ($duplicateRules.Count -lt 2) { throw 'Duplicate fixture was not created.' }
    $result.DuplicateRulesBefore = $duplicateRules.Count
    $oldFailed = $false
    try {
        $filters = $duplicateRules | Get-NetFirewallApplicationFilter
        [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($filters.Program)) | Out-Null
    } catch { $oldFailed = $true; $result.OldVerificationError = $_.Exception.Message }
    if (-not $oldFailed) { throw 'Expected the v1.1.0 verification to fail in Windows PowerShell 5.1.' }

    # Exercise both entry points, then leave installed rules targeting Program Files.
    foreach ($iteration in 1..2) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PackageDir 'setup-firewall.ps1')
        if ($LASTEXITCODE -ne 0) { throw "Portable firewall setup failed on run $iteration." }
    }
    # Repeat the legacy-state fixture for the full installer independently.
    foreach ($protocol in @('TCP', 'UDP')) {
        $name = 'UxPlayEnhanced-Test-' + [Guid]::NewGuid().ToString('N')
        $seedNames += $name
        New-NetFirewallRule -Name $name -DisplayName "UxPlayEnhanced AirPlay ($protocol)" `
            -Direction Inbound -Action Allow -Protocol $protocol -Profile Private,Public `
            -Program (Join-Path $PackageDir 'uxplay.exe') | Out-Null
    }
    foreach ($iteration in 1..2) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PackageDir 'UxPlayEnhanced-Setup.ps1') -SkipPause
        if ($LASTEXITCODE -ne 0) { throw "Installer failed on run $iteration." }
    }
    $registration = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\UxPlayEnhanced'
    if ($registration.DisplayVersion -ne '1.1.1') { throw 'Wrong installed version.' }
    $installDir = Join-Path $registration.InstallLocation 'app-1.1.1'
    $count = 0
    foreach ($file in Get-ChildItem -LiteralPath $PackageDir -Recurse -File) {
        $relative = $file.FullName.Substring($PackageDir.Length).TrimStart('\')
        if ($relative -in @('UxPlayEnhanced-Setup.cmd', 'UxPlayEnhanced-Setup.ps1')) { continue }
        $installed = Join-Path $installDir $relative
        if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $installed).Hash) {
            throw "Installed hash mismatch: $relative"
        }
        $count++
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'UxPlayEnhanced.lnk'))
    if ($shortcut.TargetPath -ine (Join-Path $installDir 'UxPlayEnhanced.exe')) { throw 'Incorrect desktop shortcut.' }
    foreach ($protocol in @('TCP', 'UDP')) {
        $rules = @(Get-NetFirewallRule -DisplayName "UxPlayEnhanced AirPlay ($protocol)")
        if ($rules.Count -ne 1) { throw "Duplicate $protocol rules remain." }
        $program = ($rules[0] | Get-NetFirewallApplicationFilter).Program
        if ($program -ine (Join-Path $installDir 'uxplay.exe')) { throw 'Incorrect firewall program.' }
    }
    $result.Passed = $true
    $result.InstalledFilesVerified = $count
    $result.Version = $registration.DisplayVersion
    $result.PortableRuns = 2
    $result.InstallerRuns = 2
} catch {
    $result.Error = $_.Exception.ToString()
    throw
} finally {
    foreach ($name in $seedNames) {
        Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
    $result | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    Stop-Transcript | Out-Null
}
