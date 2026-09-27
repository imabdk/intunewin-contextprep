# IntuneWinContextPrep

Adds a **Package as .intunewin** entry to the Windows Explorer context menu. Right-click a setup
file or a folder and get a finished `.intunewin` package, without opening a console and typing out
`-c`, `-s` and `-o` paths for IntuneWinAppUtil.exe.

The Microsoft [Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
does the packaging. This project handles everything around it.

Most organizations run a third-party patch management solution for apps that update regularly, and
packaging those manually every release isn't worth it. But in-house apps aren't in any patch
management catalog, smaller shops don't always have one, and there's always the one-off - testing a
version, troubleshooting a failed install, packaging something for a pilot group. This is for that.

![Package as .intunewin in the Explorer context menu](docs/context-menu.png)

## What it adds on top of IntuneWinAppUtil.exe

- **Paths resolved from what you clicked.** Right-click a setup file and its parent folder becomes
  the source. Right-click a folder and it is used directly, and you are prompted if it holds several
  setup files.
- **A confirmation before anything is packaged.** Everything in the source folder goes into the
  package, so the prompt shows the file count and size, flags personal and system folders, calls out
  existing `.intunewin` files, and warns past the 30 GB limit Intune enforces.
- **Output kept away from the source.** Packages land under
  `%LOCALAPPDATA%\IntuneWinContextPrep\Output`, so a re-run never wraps the previous package into
  the next one.
- **Version in the filename.** `remotehelpinstaller_5.2.1040.0.intunewin`, from the MSI product
  version or the exe's version resource.
- **Portal handoff.** A `.json` file next to the package with the publisher, install and uninstall
  commands, and a detection rule. For an MSI that carries the product code and product version.
- **Architecture for the requirement rule.** Read from the installer itself and reported as what to
  select under **Operating system architecture**. A 32-bit installer reports `x86, x64`.
- **Silent switches for exe installers.** The wrapper identifies which installer built the exe
  and reports the switches that installer documents.

| Detected as | Install command | Uninstall |
| --- | --- | --- |
| WiX Burn bundle | `/quiet /norestart` | `/uninstall /quiet /norestart` |
| NSIS | `/S` (case sensitive) | `Uninstall.exe /S`, path from `QuietUninstallString` |
| Inno Setup | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` | `unins000.exe` with the same switches |
| InstallShield | `/s /v"/qn"` | From `UninstallString` |
| MSI | `msiexec /i "<file>" /qn` | `msiexec /x <ProductCode> /qn` |
| PowerShell script | `powershell.exe -ExecutionPolicy Bypass -File <file>` | Supply your own |
| `.cmd` or `.bat` | File name only | Supply your own |
| Unknown | File name only | Check after a test install |

## Requirements

- Windows PowerShell 5.1
- .NET Framework 4.7.2 or later, which IntuneWinAppUtil.exe depends on. The installer checks this
  and stops if it is missing.
- Local administrator rights for a per-machine install. Not needed for a per-user install.

## Install

Download both scripts and keep them in the same folder, then run:

```powershell
.\Install-IntuneWinContextPrep.ps1
```

Elevated, this installs per machine to `%ProgramFiles%\IntuneWinContextPrep` and registers the menu
entry in `HKLM`. Without elevation it installs per user to `%LOCALAPPDATA%\IntuneWinContextPrep` and
`HKCU`. Force either with `-Scope Machine` or `-Scope User`.

The installer downloads IntuneWinAppUtil.exe, verifies it, copies it and both scripts into the
install folder, and adds the menu entry for `.exe`, `.msi`, `.msp`, `.ps1`, `.cmd` and `.bat` files,
for folders, and for the background of an open folder.

### Where IntuneWinAppUtil.exe comes from

The installer downloads it from a pinned tag in Microsoft's repository, `v1.8.7` by default, and
refuses to install it unless Windows confirms the file is signed by Microsoft.

## Use it

Right-click any of the following and choose **Package as .intunewin**. On Windows 11 it sits under
**Show more options**.

- an `.exe`, `.msi`, `.msp`, `.ps1`, `.cmd` or `.bat` file
- a folder containing one
- the empty background of an open folder

Confirm what is about to be packaged:

![Confirmation before packaging](docs/confirmation.png)

Explorer opens the output folder when it finishes, and the result is reported with the values the
portal asks for next:

![Completion dialog showing the portal values](docs/done.png)

The same values are written to a `.json` file next to the package:

```json
{
    "Package":  "C:\\Users\\<you>\\AppData\\Local\\IntuneWinContextPrep\\Output\\7z2603-x64_20260918_162715\\7z2603-x64_26.03.intunewin",
    "SetupFile":  "7z2603-x64.exe",
    "Publisher":  "Igor Pavlov",
    "InstallerType":  "7-Zip installer",
    "InstallCommand":  "7z2603-x64.exe /S",
    "UninstallCommand":  "Uninstall.exe /S in the install folder - read UninstallString from Add/Remove Programs for the full path.",
    "DetectionRule":  "File or registry rule - no MSI metadata available",
    "Notes":  "Add /D=\"C:\\Program Files\\7-Zip\" to set the install folder.",
    "OSArchitecture":  "x64"
}
```

## Output

Everything is written under `%LOCALAPPDATA%\IntuneWinContextPrep`, under both install scopes, because
`%ProgramFiles%` is not writable at packaging time.

| Path | Contents |
| --- | --- |
| `Output\<setup>_<timestamp>\` | The `.intunewin` package and its `.json` handoff file |
| `Logs\` | A log per run, plus the packaging tool's own output |

## AppLocker and App Control

Under an application control policy that does not trust these scripts, PowerShell runs restricted
and neither script can do its job. Since Explorer runs the wrapper with no visible window, that
would otherwise look like nothing happened, so both scripts check for this first and report the
reason - the wrapper by writing it to its log.

Sign `Invoke-IntuneWinContextPrep.ps1` and allow the signer in your policy. If the installed wrapper
is signed, the installer registers the menu entry with `-ExecutionPolicy AllSigned`, so a tampered
copy refuses to run. Unsigned, it falls back to `-ExecutionPolicy Bypass` and warns you.

## Uninstall

```powershell
.\Install-IntuneWinContextPrep.ps1 -Action Uninstall
```

This clears both `HKCU` and `HKLM`, so a per-user and a per-machine install are removed in one pass.
Clearing `HKLM` needs elevation; without it the per-machine entry is left in place and a warning is
written.

The install folder, the packaging tool, the logs and every package generated so far are left alone
unless you ask for them:

```powershell
.\Install-IntuneWinContextPrep.ps1 -Action Uninstall -RemoveFiles
```

## Parameters

`Get-Help .\Install-IntuneWinContextPrep.ps1 -Full` documents every parameter, including scope,
install path, tool version tag and hash pinning.

## Author

**Martin Bengtsson**

- Blog: [www.imab.dk](https://www.imab.dk)
- X: [@mwbengtsson](https://x.com/mwbengtsson)
- LinkedIn: [martin-bengtsson](https://www.linkedin.com/in/martin-bengtsson/)
