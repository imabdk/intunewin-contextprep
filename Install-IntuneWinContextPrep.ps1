<#
.SYNOPSIS
    Adds or removes a 'Package as .intunewin' entry in the Windows Explorer context menu.

.DESCRIPTION
    Install downloads the Microsoft Win32 Content Prep Tool (IntuneWinAppUtil.exe), verifies that it
    is signed by Microsoft, and adds a 'Package as .intunewin' entry to the context menu for .exe,
    .msi, .msp, .ps1, .cmd and .bat files, for folders, and for the background of an open folder.
    Uninstall removes it again.

    Machine scope is the better choice wherever you can elevate: the files Explorer executes are
    then writable only by administrators, and the entry is available to every user on the machine.
    User scope needs no elevation, at the cost of leaving that code in a folder the signed-in user
    can modify. Generated packages and logs go to %LOCALAPPDATA% under either scope.

    A copy of this script is installed next to the wrapper, so the entry can be removed later without
    the original download.

.PARAMETER Action
    Install registers the context menu entry, Uninstall removes it. Defaults to Install.

.PARAMETER Scope
    Machine installs to %ProgramFiles% and HKLM and requires elevation. User installs to
    %LOCALAPPDATA% and HKCU. Defaults to Machine when running elevated, otherwise User. Ignored on
    uninstall, which always clears both hives.

.PARAMETER InstallPath
    Folder that receives IntuneWinAppUtil.exe, the wrapper script and a copy of this script.
    Defaults to an IntuneWinContextPrep folder in the location the chosen scope implies. On
    uninstall it is only used together with -RemoveFiles.

.PARAMETER ToolVersionTag
    Git tag in microsoft/Microsoft-Win32-Content-Prep-Tool to download IntuneWinAppUtil.exe from.
    Defaults to v1.8.7. Ignored when -ToolPath is used.

.PARAMETER ToolPath
    Path to an existing IntuneWinAppUtil.exe to install instead of downloading one. It is verified
    the same way a downloaded copy is.

.PARAMETER ExpectedHash
    SHA256 hash the packaging tool must match. Git tags are mutable and Microsoft has already moved
    the v1.8.7 tag to a different binary once, so pin the hash when you need an exact build.

.PARAMETER RemoveFiles
    Uninstall only. Also deletes the install folder, including IntuneWinAppUtil.exe, all logs and
    every .intunewin file generated so far. When -InstallPath is omitted, both default locations
    are removed.

.EXAMPLE
    .\Install-IntuneWinContextPrep.ps1

    Installs per machine when elevated, per user otherwise, using the pinned tool version.

.EXAMPLE
    .\Install-IntuneWinContextPrep.ps1 -Scope User

    Forces a per-user install to %LOCALAPPDATA% and HKCU, without elevation.

.EXAMPLE
    .\Install-IntuneWinContextPrep.ps1 -ToolPath 'C:\Approved\IntuneWinAppUtil.exe' -ExpectedHash 'C1BA45B5CB939E84AF064BB7FF4B38FB3DFE33C8DC1078FD9B157672EAE671F6'

    Installs from a pre-staged copy of the packaging tool and fails unless it matches the hash.

.EXAMPLE
    .\Install-IntuneWinContextPrep.ps1 -Action Uninstall

    Removes the context menu entry and leaves the install folder and generated packages in place.

.EXAMPLE
    .\Install-IntuneWinContextPrep.ps1 -Action Uninstall -RemoveFiles

    Removes the context menu entry and deletes the install folder and everything in it.

.NOTES
    Installing requires .NET Framework 4.7.2 or later, which IntuneWinAppUtil.exe depends on.

    Both scripts must sit in the same folder. The installer copies the wrapper next to
    IntuneWinAppUtil.exe in the install folder.

    Version: 1.5.0
    Updated: 2026-09-27

    Changelog:
    1.5.0 - 2026-09-27 - No change in this script; version kept in step with the wrapper.
    1.4.1 - 2026-09-19 - Fail up front with an explanation when Invoke-IntuneWinContextPrep.ps1 is
                         missing from the same folder. The Copy-Item error it produced previously
                         read as though this script referenced the wrong file name. Unknown
                         parameters are now rejected instead of being silently ignored.
    1.4.0 - 2026-09-19 - Added .ps1, .cmd and .bat as setup files. Registered under
                         SystemFileAssociations so the entry survives a user changing which
                         application opens those types.
    1.3.1 - 2026-09-18 - No change in this script; version kept in step with the wrapper.
    1.3.0 - 2026-09-18 - No change in this script; version kept in step with the wrapper.
    1.2.2 - 2026-09-18 - No change in this script; version kept in step with the wrapper.
    1.2.1 - 2026-09-18 - No change in this script; version kept in step with the wrapper.
    1.2.0 - 2026-09-18 - No change in this script; version kept in step with the wrapper.
    1.1.0 - 2026-09-18 - Removed pre-release migration code. Verification failures now name the
                         file's actual source instead of always blaming the download URL.
    1.0.0 - 2026-09-17 - Initial release.

    Author: Martin Bengtsson
    Blog:   www.imab.dk
    X:      @mwbengtsson
#>
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall')]
    [string]$Action = 'Install',
    [ValidateSet('User', 'Machine')]
    [string]$Scope,
    [string]$InstallPath,
    [string]$ToolVersionTag = 'v1.8.7',
    [string]$ToolPath,
    [string]$ExpectedHash,
    [switch]$RemoveFiles
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    throw "PowerShell is running in $($ExecutionContext.SessionState.LanguageMode) mode under an application control policy. Sign this script and allow the signer in your AppLocker or App Control policy."
}

# this name is also hard-coded in Invoke-IntuneWinContextPrep.ps1, which runs standalone from
# Explorer and cannot share it - change both together
$appName = 'IntuneWinContextPrep'
$verbKey = $appName

# folder background passes the path as %V, every other class passes %1.
# MultiSelectModel=Single is needed because a static verb can only ever receive one path: without
# it Explorer assumes Document, launches a hidden instance per selected file, and hides the verb
# altogether past 15. Background has no selection, so it is left unset there.
# One flat verb per class rather than a submenu: registry-based cascading submenus
# (ExtendedSubCommandsKey) don't render in this Explorer build, top-level or under "Show more
# options".
# Script types go under SystemFileAssociations rather than their ProgID, so the entry survives a
# user changing which application opens .ps1, .cmd or .bat.
$shellTargets = @(
    @{ Class = 'exefile'; PathToken = '%1'; MultiSelectModel = 'Single' },
    @{ Class = 'Msi.Package'; PathToken = '%1'; MultiSelectModel = 'Single' },
    @{ Class = 'Msi.Patch'; PathToken = '%1'; MultiSelectModel = 'Single' },
    @{ Class = 'SystemFileAssociations\.ps1'; PathToken = '%1'; MultiSelectModel = 'Single' },
    @{ Class = 'SystemFileAssociations\.cmd'; PathToken = '%1'; MultiSelectModel = 'Single' },
    @{ Class = 'SystemFileAssociations\.bat'; PathToken = '%1'; MultiSelectModel = 'Single' },
    @{ Class = 'Directory'; PathToken = '%1'; MultiSelectModel = 'Single' },
    @{ Class = 'Directory\Background'; PathToken = '%V'; MultiSelectModel = $null }
)

$hives = @('HKCU:\Software\Classes', 'HKLM:\Software\Classes')
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# packages and logs stay in the user profile because %ProgramFiles% is not writable at package time
$dataRoot = Join-Path $env:LOCALAPPDATA $appName
$machineRoot = Join-Path $env:ProgramFiles $appName

$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$iconSource = "$powerShellExe,0"

# pinned to a tag rather than master, so a given install always gets the same binary
$toolDownloadUrl = "https://raw.githubusercontent.com/microsoft/Microsoft-Win32-Content-Prep-Tool/$ToolVersionTag/IntuneWinAppUtil.exe"

function Assert-MicrosoftSignedExecutable {
    param([string]$LiteralPath, [string]$Source)

    $stream = [System.IO.File]::OpenRead($LiteralPath)
    try {
        $header = @($stream.ReadByte(), $stream.ReadByte())
    }
    finally {
        $stream.Dispose()
    }
    if ($header[0] -ne 0x4D -or $header[1] -ne 0x5A) {
        throw "IntuneWinAppUtil.exe from $Source is not a Windows executable."
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $LiteralPath
    if ($signature.Status -ne 'Valid') {
        throw "Authenticode signature on IntuneWinAppUtil.exe from $Source is not valid (status: $($signature.Status))."
    }
    if ($signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "IntuneWinAppUtil.exe from $Source is not signed by Microsoft Corporation. Signer: $($signature.SignerCertificate.Subject)"
    }
}

function New-CommandVerb {
    param($Path, $DisplayName, $Command, $MultiSelectModel)
    New-Item -Path $Path -Force | Out-Null
    Set-ItemProperty -Path $Path -Name 'MUIVerb' -Value $DisplayName
    Set-ItemProperty -Path $Path -Name 'Icon' -Value $iconSource
    if ($MultiSelectModel) {
        Set-ItemProperty -Path $Path -Name 'MultiSelectModel' -Value $MultiSelectModel
    }
    New-Item -Path "$Path\command" -Force -Value $Command | Out-Null
}

function Remove-ContextMenuVerb {
    $removed = 0
    foreach ($hive in $hives) {
        if ($hive -like 'HKLM*' -and -not $isElevated) { continue }
        foreach ($target in $shellTargets) {
            $verbPath = "$hive\$($target.Class)\shell\$verbKey"
            if (Test-Path $verbPath) {
                Remove-Item -Path $verbPath -Recurse -Force
                $removed++
            }
        }
    }
    $removed
}

if ($Action -eq 'Uninstall') {
    $removedCount = Remove-ContextMenuVerb

    if (-not $isElevated) {
        Write-Warning 'Not running elevated, so any per-machine install under HKLM was left in place. Re-run elevated to remove it.'
    }

    if ($RemoveFiles) {
        $filePaths = if ($InstallPath) { @($InstallPath) } else { @($machineRoot, $dataRoot) }
        foreach ($filePath in $filePaths) {
            if (Test-Path $filePath) {
                Remove-Item -Path $filePath -Recurse -Force
                Write-Host "Removed $filePath"
            }
        }
    }

    Write-Host "Context menu entry removed ($removedCount registry key(s))."
    return
}

# checked before anything is downloaded, because the error Copy-Item raises later reads as though
# this script references the wrong file name
$wrapperSource = Join-Path $PSScriptRoot 'Invoke-IntuneWinContextPrep.ps1'
if (-not (Test-Path -LiteralPath $wrapperSource)) {
    throw "Invoke-IntuneWinContextPrep.ps1 was not found in $PSScriptRoot. Both scripts are required and must sit in the same folder. Download them from https://github.com/imabdk/intunewin-contextprep"
}

if ($Scope -eq 'Machine' -and -not $isElevated) {
    throw 'Machine scope writes to %ProgramFiles% and HKLM. Re-run this script elevated, or use -Scope User.'
}
if (-not $Scope) {
    $Scope = if ($isElevated) { 'Machine' } else { 'User' }
}
if (-not $InstallPath) {
    $InstallPath = if ($Scope -eq 'Machine') { $machineRoot } else { $dataRoot }
}
$classesRoot = if ($Scope -eq 'Machine') { 'HKLM:\Software\Classes' } else { 'HKCU:\Software\Classes' }

# IntuneWinAppUtil.exe requires .NET Framework 4.7.2, release value 461808
$netRelease = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name 'Release' -ErrorAction SilentlyContinue).Release
if (-not $netRelease -or $netRelease -lt 461808) {
    throw "IntuneWinAppUtil.exe requires .NET Framework 4.7.2 or later. Detected release value: $netRelease"
}

if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}

$toolDestination = Join-Path $InstallPath 'IntuneWinAppUtil.exe'
$stagedTool = Join-Path ([System.IO.Path]::GetTempPath()) ("IntuneWinAppUtil_{0}.exe" -f [guid]::NewGuid())
try {
    if ($ToolPath) {
        if (-not (Test-Path -LiteralPath $ToolPath)) {
            throw "ToolPath not found: $ToolPath"
        }
        Write-Host "Using pre-staged IntuneWinAppUtil.exe from $ToolPath..."
        $toolSource = $ToolPath
        Copy-Item -LiteralPath $ToolPath -Destination $stagedTool -Force
    }
    else {
        Write-Host "Downloading IntuneWinAppUtil.exe ($ToolVersionTag) from Microsoft's repository..."
        # a failed download can return an HTML error page rather than the binary, which the MZ check catches
        $toolSource = $toolDownloadUrl
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $toolDownloadUrl -OutFile $stagedTool -UseBasicParsing
    }

    Unblock-File -LiteralPath $stagedTool
    Assert-MicrosoftSignedExecutable -LiteralPath $stagedTool -Source $toolSource
    if ($ExpectedHash) {
        $actualHash = (Get-FileHash -LiteralPath $stagedTool -Algorithm SHA256).Hash
        if ($actualHash -ne $ExpectedHash.Trim()) {
            throw "SHA256 mismatch. Expected $($ExpectedHash.Trim()), got $actualHash."
        }
    }
    Move-Item -LiteralPath $stagedTool -Destination $toolDestination -Force
    Write-Host "Verified $((Get-Item $toolDestination).VersionInfo.FileVersion), signed by Microsoft Corporation."
}
finally {
    if (Test-Path -LiteralPath $stagedTool) {
        Remove-Item -LiteralPath $stagedTool -Force
    }
}

$wrapperPath = Join-Path $InstallPath 'Invoke-IntuneWinContextPrep.ps1'
# re-running from the installed copy would otherwise copy both files onto themselves
if ($wrapperSource -ne $wrapperPath) {
    Copy-Item -LiteralPath $wrapperSource -Destination $wrapperPath -Force
}
# a wrapper copied out of a downloaded repo zip carries MOTW and would be refused under AllSigned
Unblock-File -LiteralPath $wrapperPath

# keeping a copy next to the wrapper means uninstall works without the original download
$installedScriptPath = Join-Path $InstallPath (Split-Path -Leaf $PSCommandPath)
if ($PSCommandPath -ne $installedScriptPath) {
    Copy-Item -LiteralPath $PSCommandPath -Destination $installedScriptPath -Force
    Unblock-File -LiteralPath $installedScriptPath
}

if ((Get-AuthenticodeSignature -LiteralPath $wrapperPath).Status -eq 'Valid') {
    $executionPolicy = 'AllSigned'
}
else {
    $executionPolicy = 'Bypass'
    Write-Warning 'Invoke-IntuneWinContextPrep.ps1 is unsigned, so the menu entry is registered with -ExecutionPolicy Bypass. Sign the script and re-run this installer to register it with AllSigned instead.'
}

# clearing both hives first means switching scope never leaves two entries on the menu
Remove-ContextMenuVerb | Out-Null

foreach ($target in $shellTargets) {
    $command = "`"$powerShellExe`" -ExecutionPolicy $executionPolicy -WindowStyle Hidden -File `"$wrapperPath`" -Path `"$($target.PathToken)`""
    New-CommandVerb -Path "$classesRoot\$($target.Class)\shell\$verbKey" -DisplayName 'Package as .intunewin' -Command $command -MultiSelectModel $target.MultiSelectModel
}

Write-Host "Installed ($Scope scope) to $InstallPath. Packages and logs go to $dataRoot."
Write-Host "Right-click an .exe, .msi, .msp, .ps1, .cmd or .bat file, a folder, or the background of an open folder and choose 'Package as .intunewin'."
Write-Host "Uninstall with: `"$installedScriptPath`" -Action Uninstall"
