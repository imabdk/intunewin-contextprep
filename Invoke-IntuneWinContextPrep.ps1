<#
.SYNOPSIS
    Packages a setup file into an .intunewin file. Invoked by the Explorer context menu entry.

.DESCRIPTION
    Runs IntuneWinAppUtil.exe against whatever was right-clicked. A file means its parent folder
    becomes the source folder; a folder is used directly, and the user is prompted when it holds
    more than one setup file. A confirmation shows what is about to be included, because everything
    in the source folder ends up in the package.

    Output goes to a timestamped folder under %LOCALAPPDATA%\IntuneWinContextPrep, so a re-run never
    bundles a previous package into the next one, and the package is renamed to include the detected
    product version. The finished package is read back to report its metadata, and a .json file with
    a suggested detection rule and install and uninstall commands is written next to it.

    Progress and errors are written to a per-run log under Logs, and errors are also shown in a
    message box because the console window is hidden when launched from Explorer.

.PARAMETER Path
    Full path to the setup file or folder to package. Supplied by the shell verb as %1, or as %V
    when invoked from the background of an open folder.

.EXAMPLE
    .\Invoke-IntuneWinContextPrep.ps1 -Path 'C:\Packages\7zip\7z2409-x64.msi'

    Packages C:\Packages\7zip using 7z2409-x64.msi as the setup file.

.EXAMPLE
    .\Invoke-IntuneWinContextPrep.ps1 -Path 'C:\Packages\7zip'

    Packages the folder, prompting for the setup file if it contains more than one.

.NOTES
    Not intended to be run directly. Install-IntuneWinContextPrep.ps1 copies this script next to
    IntuneWinAppUtil.exe and registers the shell verb that calls it.

    Version: 1.5.0
    Updated: 2026-09-27

    Changelog:
    1.5.0 - 2026-09-27 - Removed the remembered setup file per folder. It only ever helped when a
                         source folder held more than one setup file, at the cost of a persisted
                         file and a concept to explain; the picker now simply shows every time.
    1.4.1 - 2026-09-19 - No change in this script; version kept in step with the installer.
    1.4.0 - 2026-09-19 - Added .ps1, .cmd and .bat as setup files, with install commands suited to
                         each.
    1.3.1 - 2026-09-18 - Suggested commands now quote the setup file only when its name contains a
                         space, so the handoff file no longer carries JSON escapes around a name
                         that never needed quoting.
    1.3.0 - 2026-09-18 - Added detection for 7-Zip's own installer, which is neither NSIS nor Inno
                         and was reported as Unknown.
    1.2.2 - 2026-09-18 - Fixed packaging failing for any source path containing a space, because
                         Start-Process joins an argument array without quoting it. Errors now
                         report the packaging tool's own message, which it writes to stdout while
                         still exiting 0.
    1.2.1 - 2026-09-18 - Dropped the content size from the completion summary. It measures the
                         compressed payload before encryption, so it matched the package size at
                         any realistic size.
    1.2.0 - 2026-09-18 - Added the publisher to the handoff, from MsiPublisher for an MSI and from
                         the version resource for an exe.
    1.1.0 - 2026-09-18 - Added architecture detection for the Intune requirement rule, a warning
                         when the source exceeds the 30 GB Win32 app limit, and the MSI product
                         version in the suggested detection rule. Removed repeated values from the
                         completion dialog.
    1.0.0 - 2026-09-17 - Initial release.

    Author: Martin Bengtsson
    Blog:   www.imab.dk
    X:      @mwbengtsson
#>
param(
    [Parameter(Mandatory)]
    [string]$Path
)

$toolPath = Join-Path $PSScriptRoot 'IntuneWinAppUtil.exe'
# packages and logs live in the user profile because a machine-scope install root is read-only.
# the folder name is also hard-coded in Install-IntuneWinContextPrep.ps1 - change both together
$dataRoot = Join-Path $env:LOCALAPPDATA 'IntuneWinContextPrep'
$logDir = Join-Path $dataRoot 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logFile = Join-Path $logDir "IntuneWinContextPrep_$timestamp.log"
$setupExtensions = @('.exe', '.msi', '.msp', '.ps1', '.cmd', '.bat')
# Intune rejects a Win32 app larger than this
$maxAppBytes = 30GB

# ConstrainedLanguage blocks every .NET call below, including the message box used to report
# errors, so bail to the log before the first Add-Type rather than failing invisibly
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Add-Content -Path $logFile -Value "PowerShell is running in $($ExecutionContext.SessionState.LanguageMode) mode under an application control policy. Sign Invoke-IntuneWinContextPrep.ps1 and allow the signer in your AppLocker or App Control policy."
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-Log {
    param([string]$Message)
    Add-Content -Path $logFile -Value $Message
}

# Explorer launches this with a hidden window and no foreground rights, so an unowned dialog opens
# behind whatever the user is looking at and the tool appears to have done nothing
function Show-Dialog {
    param([string]$Text, [string]$Title, [string]$Buttons = 'OK', [string]$Icon = 'Information')

    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $owner.ShowInTaskbar = $false
    $owner.FormBorderStyle = 'None'
    $owner.Size = New-Object System.Drawing.Size(1, 1)
    $owner.StartPosition = 'CenterScreen'
    $owner.Opacity = 0
    $owner.Show()
    try {
        [System.Windows.Forms.MessageBox]::Show(
            $owner, $Text, $Title,
            [System.Windows.Forms.MessageBoxButtons]$Buttons,
            [System.Windows.Forms.MessageBoxIcon]$Icon)
    }
    finally {
        $owner.Close()
        $owner.Dispose()
    }
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) }
    else { '{0:N0} KB' -f ($Bytes / 1KB) }
}

# the tool writes its failures to stdout and still exits 0, so its own message is the only detail
# worth reporting back
function Get-ToolError {
    param([string[]]$LogPath)

    foreach ($path in $LogPath) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $line = Get-Content -LiteralPath $path | Where-Object { $_ -match 'ERROR' } | Select-Object -First 1
        if ($line) { return $line.Trim() }
    }
    "See $logDir for details."
}

function Get-PackageMetadata {
    param([string]$PackagePath)

    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $entry = $archive.Entries | Where-Object { $_.FullName -eq 'IntuneWinPackage/Metadata/Detection.xml' }
        if (-not $entry) { return $null }

        $reader = New-Object System.IO.StreamReader($entry.Open())
        try { return ([xml]$reader.ReadToEnd()).ApplicationInfo }
        finally { $reader.Dispose() }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-SetupVersion {
    param([string]$SetupFile, $AppInfo)

    if ($AppInfo -and $AppInfo.MsiInfo -and $AppInfo.MsiInfo.MsiProductVersion) {
        return $AppInfo.MsiInfo.MsiProductVersion
    }
    $versionInfo = (Get-Item -LiteralPath $SetupFile).VersionInfo
    foreach ($candidate in @($versionInfo.ProductVersion, $versionInfo.FileVersion)) {
        if ($candidate -and $candidate.Trim()) { return $candidate.Trim() }
    }
    $null
}

function Get-SetupPublisher {
    param([string]$SetupFile, $AppInfo)

    if ($AppInfo -and $AppInfo.MsiInfo -and $AppInfo.MsiInfo.MsiPublisher) {
        return $AppInfo.MsiInfo.MsiPublisher
    }
    $company = (Get-Item -LiteralPath $SetupFile).VersionInfo.CompanyName
    if ($company -and $company.Trim()) { return $company.Trim() }
    $null
}

function Get-PESectionNames {
    param([string]$LiteralPath)

    $stream = [System.IO.File]::OpenRead($LiteralPath)
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -le 0 -or $peOffset -ge $stream.Length) { return @() }
        $stream.Position = $peOffset
        if ((-join $reader.ReadChars(2)) -ne 'PE') { return @() }
        $stream.Position = $peOffset + 6
        $sectionCount = $reader.ReadUInt16()
        $stream.Position = $peOffset + 20
        $optionalHeaderSize = $reader.ReadUInt16()
        $stream.Position = $peOffset + 24 + $optionalHeaderSize

        $names = @()
        for ($i = 0; $i -lt $sectionCount; $i++) {
            $names += ([System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(8))).Trim([char]0)
            $stream.Position += 32
        }
        $names
    }
    catch { @() }
    finally { $stream.Dispose() }
}

function Test-FileMarker {
    param([string]$LiteralPath, [string]$Pattern, [int]$MaxBytes = 4194304)

    $stream = [System.IO.File]::OpenRead($LiteralPath)
    try {
        $length = [int][Math]::Min($MaxBytes, $stream.Length)
        $buffer = New-Object byte[] $length
        [void]$stream.Read($buffer, 0, $length)
        [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($buffer) -match $Pattern
    }
    catch { $false }
    finally { $stream.Dispose() }
}

# the machine type in the COFF header, which is what the Intune architecture requirement maps to
function Get-PEArchitecture {
    param([string]$LiteralPath)

    $stream = [System.IO.File]::OpenRead($LiteralPath)
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -le 0 -or $peOffset -ge $stream.Length) { return $null }
        $stream.Position = $peOffset
        if ((-join $reader.ReadChars(2)) -ne 'PE') { return $null }
        $stream.Position = $peOffset + 4
        switch ($reader.ReadUInt16()) {
            0x014C { 'x86' }
            0x8664 { 'x64' }
            0xAA64 { 'Arm64' }
            default { $null }
        }
    }
    catch { $null }
    finally { $stream.Dispose() }
}

# an MSI declares its platform in the Template summary property, as "x64;1033" or "Intel;1033"
function Get-MsiArchitecture {
    param([string]$LiteralPath)

    $installer = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $summary = $installer.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $installer, @($LiteralPath, 0))
        $template = $summary.GetType().InvokeMember('Property', 'GetProperty', $null, $summary, 7)
    }
    catch { return $null }
    finally {
        # the summary handle keeps the MSI open, which would block packaging the folder it sits in
        if ($summary) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary) }
        if ($installer) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) }
    }

    if ($template -match 'Arm64') { 'Arm64' }
    elseif ($template -match 'x64|Intel64|AMD64') { 'x64' }
    elseif ($template -match 'Intel') { 'x86' }
    else { $null }
}

# a 32-bit installer still installs on 64-bit Windows, so the requirement widens rather than matching
function Get-ArchitectureRequirement {
    param([string]$Architecture)

    switch ($Architecture) {
        'x86' { 'x86, x64' }
        'x64' { 'x64' }
        'Arm64' { 'Arm64' }
        default { $null }
    }
}

# quoting only when the name needs it keeps the handoff file free of JSON escapes, so a command can
# be pasted straight out of it
function Format-CommandPath {
    param([string]$FileName)

    if ($FileName -match '\s') { "`"$FileName`"" } else { $FileName }
}

# an exe carries no metadata the way an MSI does, so identify the installer technology instead and
# emit the switches that technology actually documents
function Get-InstallerProfile {
    param([string]$SetupFile)

    $fileName = Split-Path -Leaf $SetupFile
    $command = Format-CommandPath $fileName
    $sections = Get-PESectionNames -LiteralPath $SetupFile

    if ($sections -contains '.wixburn') {
        return [ordered]@{
            InstallerType    = 'WiX Burn bundle'
            InstallCommand   = "$command /quiet /norestart"
            UninstallCommand = "$command /uninstall /quiet /norestart"
            Notes            = 'Burn bundles also register a QuietUninstallString in Add/Remove Programs.'
        }
    }
    if ($sections -contains '.ndata' -or (Test-FileMarker -LiteralPath $SetupFile -Pattern 'Nullsoft')) {
        return [ordered]@{
            InstallerType    = 'NSIS'
            InstallCommand   = "$command /S"
            UninstallCommand = 'Uninstaller path is known only after install - read QuietUninstallString from Add/Remove Programs. Typically Uninstall.exe /S in the install folder.'
            Notes            = 'The NSIS /S switch is case sensitive.'
        }
    }
    if (Test-FileMarker -LiteralPath $SetupFile -Pattern 'Inno Setup') {
        return [ordered]@{
            InstallerType    = 'Inno Setup'
            InstallCommand   = "$command /VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
            UninstallCommand = 'unins000.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART in the install folder - read UninstallString from Add/Remove Programs for the full path.'
            Notes            = 'Add /SP- to skip the "This will install..." prompt.'
        }
    }
    if (Test-FileMarker -LiteralPath $SetupFile -Pattern 'InstallShield') {
        return [ordered]@{
            InstallerType    = 'InstallShield'
            InstallCommand   = "$command /s /v`"/qn`""
            UninstallCommand = 'Read UninstallString from Add/Remove Programs.'
            Notes            = 'Legacy InstallShield uses /s /f1"response.iss" with a recorded response file instead.'
        }
    }

    # 7-Zip ships its own installer, identified from the version resource rather than a byte scan so
    # that an installer merely bundling 7-Zip does not match
    $versionInfo = (Get-Item -LiteralPath $SetupFile).VersionInfo
    if ($versionInfo.OriginalFilename -eq '7zipInstall.exe' -or
        ($versionInfo.CompanyName -eq 'Igor Pavlov' -and $versionInfo.FileDescription -like '*7-Zip Installer*')) {
        return [ordered]@{
            InstallerType    = '7-Zip installer'
            InstallCommand   = "$command /S"
            UninstallCommand = 'Uninstall.exe /S in the install folder - read UninstallString from Add/Remove Programs for the full path.'
            Notes            = 'Add /D="C:\Program Files\7-Zip" to set the install folder.'
        }
    }

    [ordered]@{
        InstallerType    = 'Unknown'
        InstallCommand   = $command
        UninstallCommand = 'Read UninstallString from Add/Remove Programs after a test install.'
        Notes            = 'No installer technology detected - check the vendor documentation for the silent switch.'
    }
}

function Get-PortalHandoff {
    param($AppInfo, [string]$SetupFilePath, [string]$PackagePath)

    $setupFileName = Split-Path -Leaf $SetupFilePath
    $handoff = [ordered]@{
        Package   = $PackagePath
        SetupFile = $setupFileName
    }
    $publisher = Get-SetupPublisher -SetupFile $SetupFilePath -AppInfo $AppInfo
    if ($publisher) { $handoff['Publisher'] = $publisher }

    switch ([System.IO.Path]::GetExtension($setupFileName).ToLowerInvariant()) {
        '.msi' {
            $handoff['InstallerType'] = 'Windows Installer'
            $handoff['InstallCommand'] = "msiexec /i $(Format-CommandPath $setupFileName) /qn"
            if ($AppInfo -and $AppInfo.MsiInfo) {
                $handoff['UninstallCommand'] = "msiexec /x $($AppInfo.MsiInfo.MsiProductCode) /qn"
                $handoff['DetectionRule'] = "MSI product code $($AppInfo.MsiInfo.MsiProductCode), product version $($AppInfo.MsiInfo.MsiProductVersion)"
                $handoff['InstallContext'] = $AppInfo.MsiInfo.MsiExecutionContext
            }
            $architecture = Get-ArchitectureRequirement (Get-MsiArchitecture -LiteralPath $SetupFilePath)
        }
        '.msp' {
            $handoff['InstallerType'] = 'Windows Installer patch'
            $handoff['InstallCommand'] = "msiexec /p $(Format-CommandPath $setupFileName) /qn"
            $handoff['UninstallCommand'] = 'Patches cannot be removed with msiexec /x - set manually'
            $handoff['DetectionRule'] = 'File or registry rule - patches expose no product code'
            $architecture = $null
        }
        '.ps1' {
            $handoff['InstallerType'] = 'PowerShell script'
            $handoff['InstallCommand'] = "powershell.exe -ExecutionPolicy Bypass -File $(Format-CommandPath $setupFileName)"
            $handoff['UninstallCommand'] = 'Supply an uninstall script or command.'
            $handoff['DetectionRule'] = 'File, registry or script rule - a script exposes no metadata'
            $handoff['Notes'] = 'Intune can also take a PowerShell script as the installer directly, instead of a command line.'
            $architecture = $null
        }
        { $_ -in '.cmd', '.bat' } {
            $handoff['InstallerType'] = 'Script'
            $handoff['InstallCommand'] = Format-CommandPath $setupFileName
            $handoff['UninstallCommand'] = 'Supply an uninstall script or command.'
            $handoff['DetectionRule'] = 'File, registry or script rule - a script exposes no metadata'
            $architecture = $null
        }
        default {
            $installer = Get-InstallerProfile -SetupFile $SetupFilePath
            $handoff['InstallerType'] = $installer.InstallerType
            $handoff['InstallCommand'] = $installer.InstallCommand
            $handoff['UninstallCommand'] = $installer.UninstallCommand
            $handoff['DetectionRule'] = 'File or registry rule - no MSI metadata available'
            $handoff['Notes'] = $installer.Notes
            $architecture = Get-ArchitectureRequirement (Get-PEArchitecture -LiteralPath $SetupFilePath)
        }
    }
    if ($architecture) { $handoff['OSArchitecture'] = $architecture }
    $handoff
}

function Get-SourceProfile {
    param([string]$Folder, $Files)

    $protected = @(
        $env:USERPROFILE
        $env:OneDrive
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
        $env:SystemRoot
        [Environment]::GetFolderPath('Desktop')
        [Environment]::GetFolderPath('MyDocuments')
        (Join-Path $env:USERPROFILE 'Downloads')
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

    [pscustomobject]@{
        FileCount        = $Files.Count
        TotalBytes       = [double](($Files | Measure-Object -Property Length -Sum).Sum)
        ExistingPackages = @($Files | Where-Object { $_.Extension -eq '.intunewin' }).Count
        IsProtected      = $protected -contains $Folder.TrimEnd('\')
    }
}

function Select-SetupFile {
    param($Candidates)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Select the setup file'
    $form.Size = New-Object System.Drawing.Size(540, 330)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.TopMost = $true

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(12, 12)
    $list.Size = New-Object System.Drawing.Size(500, 230)
    foreach ($candidate in $Candidates) {
        $list.Items.Add(('{0}   ({1})' -f $candidate.Name, (Format-Bytes $candidate.Length))) | Out-Null
    }
    $list.SelectedIndex = 0
    $form.Controls.Add($list)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'OK'
    $okButton.Location = New-Object System.Drawing.Point(356, 252)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($okButton)
    $form.AcceptButton = $okButton

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object System.Drawing.Point(437, 252)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)
    $form.CancelButton = $cancelButton

    $form.Add_Shown({ $form.Activate() })
    $result = $form.ShowDialog()
    $index = $list.SelectedIndex
    $form.Dispose()

    if ($result -ne [System.Windows.Forms.DialogResult]::OK -or $index -lt 0) { return $null }
    $Candidates[$index].FullName
}

try {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path not found: $Path"
    }
    if (-not (Test-Path $toolPath)) {
        throw "IntuneWinAppUtil.exe not found at $toolPath. Re-run the installer."
    }

    # right-clicked a file -> that file is the source folder's parent; right-clicked a folder -> wrap it directly
    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) {
        $sourceFolder = $item.FullName
        $candidates = @(Get-ChildItem -LiteralPath $sourceFolder -File | Where-Object { $_.Extension -in $setupExtensions })
        if ($candidates.Count -eq 0) {
            throw "No $($setupExtensions -join ', ') file found in $sourceFolder."
        }
    }
    else {
        $sourceFolder = $item.DirectoryName
        $candidates = @($item)
    }

    $sourceFiles = @(Get-ChildItem -LiteralPath $sourceFolder -Recurse -File -ErrorAction SilentlyContinue)
    $sourceProfile = Get-SourceProfile -Folder $sourceFolder -Files $sourceFiles

    while ($true) {
        if ($candidates.Count -eq 1) {
            $setupFile = $candidates[0].FullName
        }
        else {
            $setupFile = Select-SetupFile -Candidates $candidates
            if (-not $setupFile) { throw 'Setup file selection was cancelled.' }
        }

        $confirmLines = @(
            "Setup file:    $(Split-Path -Leaf $setupFile)"
            "Source folder: $sourceFolder"
            "Contents:      $($sourceProfile.FileCount) file(s), $(Format-Bytes $sourceProfile.TotalBytes)"
            ''
            'Everything in the source folder is included in the package.'
        )
        if ($sourceProfile.ExistingPackages -gt 0) {
            $confirmLines += "", "$($sourceProfile.ExistingPackages) existing .intunewin file(s) in the source folder will be bundled in."
        }
        if ($sourceProfile.TotalBytes -gt $maxAppBytes) {
            $confirmLines += "", "WARNING: this exceeds the $(Format-Bytes $maxAppBytes) limit for a Win32 app and Intune will reject the upload."
        }
        if ($sourceProfile.IsProtected) {
            $confirmLines += "", "WARNING: this is a personal or system folder. Unrelated files will be encrypted into the package."
        }
        if ($candidates.Count -gt 1) {
            $confirmLines += "", "Yes to package, No to pick a different setup file, Cancel to abort."
        }

        $buttons = if ($candidates.Count -gt 1) { 'YesNoCancel' } else { 'YesNo' }
        $icon = if ($sourceProfile.IsProtected) { 'Warning' } else { 'Question' }
        $answer = Show-Dialog -Text ($confirmLines -join [Environment]::NewLine) -Title 'Package as .intunewin' -Buttons $buttons -Icon $icon

        if ($answer -eq 'Yes') { break }
        if ($answer -eq 'No' -and $candidates.Count -gt 1) { continue }
        throw 'Cancelled before packaging.'
    }

    # the tool stages content under %TEMP%\<guid>\IntuneWinPackage\Contents, so a tree that fits on
    # disk can still break MAX_PATH during compression
    $maxRelativeLength = 259 - (([System.IO.Path]::GetTempPath()).Length + 63)
    $overLength = @($sourceFiles | Where-Object { ($_.FullName.Length - $sourceFolder.Length) -gt $maxRelativeLength })
    if ($overLength.Count -gt 0) {
        throw ("{0} file(s) are nested too deeply for the packaging tool to stage. Move the source folder closer to the drive root. First: {1}" -f $overLength.Count, $overLength[0].FullName)
    }

    $setupBaseName = [System.IO.Path]::GetFileNameWithoutExtension($setupFile)
    $outputFolder = Join-Path $dataRoot ("Output\{0}_{1}" -f $setupBaseName, $timestamp)
    New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null

    Write-Log "Setup file:    $setupFile"
    Write-Log "Source folder: $sourceFolder"
    Write-Log "Source size:   $($sourceProfile.FileCount) file(s), $(Format-Bytes $sourceProfile.TotalBytes)"
    Write-Log "Output folder: $outputFolder"

    # -q rather than -qq: -qq suppresses all console output and would leave the log empty.
    # the paths are quoted because Start-Process joins an argument array without quoting, so a
    # source folder containing a space would reach the tool as several arguments
    $arguments = '-c "{0}" -s "{1}" -o "{2}" -q' -f $sourceFolder, $setupFile, $outputFolder
    $stdoutLog = Join-Path $logDir "IntuneWinAppUtil_${timestamp}_stdout.log"
    $stderrLog = Join-Path $logDir "IntuneWinAppUtil_${timestamp}_stderr.log"
    $process = Start-Process -FilePath $toolPath -ArgumentList $arguments -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog

    if ($process.ExitCode -ne 0) {
        throw "IntuneWinAppUtil.exe exited with code $($process.ExitCode). $(Get-ToolError -LogPath $stdoutLog, $stderrLog)"
    }

    $packagePath = Join-Path $outputFolder "$setupBaseName.intunewin"
    if (-not (Test-Path -LiteralPath $packagePath)) {
        throw "IntuneWinAppUtil.exe reported success but produced no package. $(Get-ToolError -LogPath $stdoutLog, $stderrLog)"
    }

    $appInfo = Get-PackageMetadata -PackagePath $packagePath

    $setupVersion = Get-SetupVersion -SetupFile $setupFile -AppInfo $appInfo
    if ($setupVersion) {
        $versionedName = "{0}_{1}.intunewin" -f $setupBaseName, ($setupVersion -replace '[^\w\.\-]', '_')
        Rename-Item -LiteralPath $packagePath -NewName $versionedName -Force
        $packagePath = Join-Path $outputFolder $versionedName
    }

    $summary = [ordered]@{}
    if ($appInfo) {
        $summary['Setup file'] = $appInfo.SetupFile
    }
    $summary['Package size'] = Format-Bytes (Get-Item -LiteralPath $packagePath).Length

    $handoff = Get-PortalHandoff -AppInfo $appInfo -SetupFilePath $setupFile -PackagePath $packagePath
    $handoffPath = [System.IO.Path]::ChangeExtension($packagePath, '.json')
    $handoff | ConvertTo-Json | Set-Content -LiteralPath $handoffPath -Encoding UTF8

    $summaryText = ($summary.GetEnumerator() | ForEach-Object { '{0}: {1}' -f $_.Key, $_.Value }) -join [Environment]::NewLine
    # the package path and setup file are already shown above, so only the portal-specific keys are repeated
    $handoffText = ($handoff.GetEnumerator() | Where-Object { $_.Key -notin 'Package', 'SetupFile' } | ForEach-Object { '{0}: {1}' -f $_.Key, $_.Value }) -join [Environment]::NewLine

    Write-Log 'Completed successfully.'
    Write-Log $summaryText
    Write-Log $handoffText

    Start-Process -FilePath 'explorer.exe' -ArgumentList $outputFolder
    $dialogText = @(
        $packagePath
        ''
        $summaryText
        ''
        'For the Intune portal:'
        $handoffText
    ) -join [Environment]::NewLine
    Show-Dialog -Text $dialogText -Title 'Package as .intunewin - Done' -Buttons 'OK' -Icon 'Information' | Out-Null
}
catch {
    Write-Log $_.Exception.Message
    Show-Dialog -Text $_.Exception.Message -Title 'Package as .intunewin - Error' -Buttons 'OK' -Icon 'Error' | Out-Null
}
