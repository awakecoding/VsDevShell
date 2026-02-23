---
name: vsdevshell
description: Enter the Visual Studio Developer environment in the current PowerShell session via the VsDevShell module (MSBuild/CL toolchain env vars).
---

# VsDevShell (Visual Studio Developer Shell)

Use this skill when you need to run Windows build tools that typically only work after a Visual Studio Developer Prompt / `VsDevCmd.bat` has been applied.

## When to use

Use this skill when you see errors like:

- `msbuild : The term 'msbuild' is not recognized...`
- `cl.exe`/`link.exe`/`rc.exe` not found
- CMake/Ninja can’t find the MSVC toolchain

Start with `msbuild`, but the same approach applies to many VS toolchain commands.

## Common tools that often need VS dev env

If you need to run any of the following, **enter the VS dev shell first** so PATH/Windows SDK/VC tools variables are set correctly:

- Build / project tooling: `msbuild.exe`, `devenv.com`, `nmake.exe`
- Build systems (sometimes VS-bundled): `cmake.exe`, `ninja.exe`
- Packaging & signing (Windows SDK): `signtool.exe`, `makeappx.exe`, `makepri.exe`, `appcert.exe`
- Resources & manifests (Windows SDK): `rc.exe`, `mt.exe`, `mc.exe`
- IDL / interop: `midl.exe`, `tlibimp.exe`, `tlbexp.exe`
- Binary inspection & PDB/symbol utilities (varies by installed components): `dumpbin.exe`, `pdbcopy.exe`, `pdbstr.exe`, `symstore.exe`, `symchk.exe`
- Driver/INF tooling (specialized; requires WDK components): `inf2cat.exe`

If the user’s command references one of these tools (or a build script calls them indirectly), run the “enable” step before running the command.

## Key idea

`Enter-VsDevShell` updates **process environment variables** (PATH, INCLUDE, LIB, VSINSTALLDIR, etc.) for the **current PowerShell process**.

- Run it in the **same** terminal/session where you will run `msbuild`.
- In VS Code tool runners, avoid starting a brand-new shell between “enable env” and “build”.

### Important: one-time per PowerShell process

Treat `Enter-VsDevShell` as a **one-time initialization step per PowerShell process**:

- If you start a **fresh** `pwsh`/`powershell.exe` process (new terminal tab, new task invocation, new CI step, etc.) and you need VS build tools, you must call `Enter-VsDevShell` in that process.
- If you **reuse an existing** PowerShell process where you already called `Enter-VsDevShell`, don’t call it again.
- If you need a *different* dev environment (for example a different `-Arch`/`-HostArch`/`-WinSdk`), use a **new PowerShell process** and call `Enter-VsDevShell` there with the new parameters.

## Prerequisite

This skill assumes the `VsDevShell` module is installed and available on `PSModulePath`.

- Verify availability: `Get-Module -ListAvailable VsDevShell`

If it isn't present, install it from PowerShell Gallery for the current user:

- `Install-Module -Name VsDevShell -Repository PSGallery -Scope CurrentUser`

Then import it:

- `Import-Module VsDevShell`

Notes:

- On first install, PowerShell may prompt to install the NuGet provider and/or to trust `PSGallery`.

## Parameter mapping (intent → Enter-VsDevShell)

- `-Arch`: **target** architecture you want to build for
  - Build `Win32` → `-Arch x86`
  - Build `x64` → `-Arch x64`
  - Build `ARM64` → `-Arch arm64`
- `-HostArch`: architecture of the machine running the tools
  - Typical x64 Windows host → `-HostArch x64`
  - Typical x86 Windows host → `-HostArch x86`
  - Windows on ARM host → `-HostArch arm64`
- `-AppPlatform`: `Desktop` or `UWP` (forwarded to `VsDevCmd.bat` as `-app_platform=`)
- `-WinSdk`: optional Windows SDK version string (only set when the user specifies a required SDK)
- `-NoExt`, `-NoLogo`: optional switches to reduce startup work/noise
- `-VsInstallPath`: only set when targeting a specific Visual Studio installation

## Recommended workflow (msbuild)

1. Import and enter the environment (x64 host building x64):

  - Run in the *current* PowerShell session:
    - `Import-Module VsDevShell`
    - `Enter-VsDevShell -Arch x64 -HostArch x64 -NoLogo`

2. Verify:

  - Run: `msbuild -version`

3. Build:

   - Run your `msbuild` command (solution/project + configuration/platform as requested).

## VS Code / tool-runner tip

If your tool runner uses a fresh PowerShell process per command, run the “enter dev env” step and the build command in the **same** invocation, for example:

- `pwsh -NoProfile -Command "Import-Module VsDevShell; Enter-VsDevShell -Arch x64 -HostArch x64 -NoLogo; msbuild -version"`

If your tool runner reuses a single long-lived terminal session, run `Enter-VsDevShell` once at the start of that session, then run as many build commands as you need in the same session.

## Cross-compile examples

- Build Win32 from an x64 machine:
  - `Enter-VsDevShell -Arch x86 -HostArch x64`

- Build ARM64 from an x64 machine:
  - `Enter-VsDevShell -Arch arm64 -HostArch x64`

## Inspect without applying

If you want to see what would change without modifying your current process environment:

- `Get-VsDevEnv -Arch x64 -HostArch x64 | Format-Table -AutoSize`

## Export to a `.env` (dotenv) file

If you need to reuse the computed VS dev environment from **non-PowerShell** tooling that can load a dotenv file, you can export the output of `Get-VsDevEnv` as `KEY="VALUE"` lines.

PowerShell snippet (creates a dotenv file from the env delta):

```powershell
$envDelta = Get-VsDevEnv -Arch x64 -HostArch x64

$dotenvPath = Join-Path $PWD '.vsdevshell.env'

$lines = foreach ($pair in ($envDelta.GetEnumerator() | Sort-Object Key)) {
  $key = $pair.Key
  $value = [string]$pair.Value

  # Quote/escape for common dotenv parsers: KEY="..."
  $escaped = $value.Replace('"', '\"').Replace("`r", '').Replace("`n", '\n')
  "$key=\"$escaped\""
}

([System.IO.File]::WriteAllLines(
  $dotenvPath,
  $lines,
  (New-Object System.Text.UTF8Encoding $false) # UTF-8 without BOM
))
"Wrote $dotenvPath"
```

Notes:

- This writes the **computed values** (including `PATH`) and will typically **override** whatever values your target process already has.
- Loading a dotenv file varies by tool/shell. For example, in `bash` you often need `set -a; source ./.vsdevshell.env; set +a` to export the variables to child processes.

## Notes

- Windows only (relies on `%COMSPEC%` and Visual Studio's `VsDevCmd.bat`).
- If `msbuild` still isn’t available after enabling the environment, the installed Visual Studio workload may be missing MSBuild/VC tools.
- `AppPlatform` is forwarded to `VsDevCmd.bat`; if a particular VS version rejects it, re-run without `-AppPlatform` (or keep the default `Desktop`).
