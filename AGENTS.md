# AGENTS.md

Guidance for AI agents working in this repository.

## What this project is

`VsDevShell` is a small PowerShell module that lets you enter a Visual Studio Developer environment **from PowerShell** by importing the environment variables that `VsDevCmd.bat` would normally set.

It exports these public functions:

- `Enter-VsDevShell`: applies the Visual Studio developer environment variables to the current PowerShell process.
- `Exit-VsDevShell`: restores the pre-enter environment values captured by `Enter-VsDevShell`.
- `Get-VsDevEnv`: computes and returns the set of environment variables that would change.
- `Export-VsDevEnv`: writes the computed env delta to a standard `.env` file (UTF-8 no BOM), optionally updating an existing file.
- `Import-VsDevEnv`: parses a `.env` file back into a `VsDevEnv` (ordered hashtable) that can be piped into `Enter-VsDevShell`.

## Repo layout

- `VsDevShell/VsDevShell.psd1`: module manifest (exports `Enter-VsDevShell`, `Exit-VsDevShell`, `Get-VsDevEnv`, `Export-VsDevEnv`, `Import-VsDevEnv`).
- `VsDevShell/VsDevShell.psm1`: implementation.
- `tests/`: Pester tests.
- `skills/`: agent skills documentation.
- `README.md`: usage examples.

## How it works (implementation notes)

`Get-VsDevEnv`:

1. Locates `vswhere.exe`:
   - Prefers `vswhere` on `PATH` (`Get-Command vswhere`).
   - Otherwise uses the default Visual Studio Installer path: `%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe`.
2. Uses `vswhere.exe -latest -property installationPath` to find the latest Visual Studio install.
3. Builds the path to `VsDevCmd.bat` under `<installationPath>\Common7\Tools\VsDevCmd.bat`.
4. Runs `cmd.exe` (via `%COMSPEC%`) with:

   - `VsDevCmd.bat` + selected arguments (`-arch`, `-host_arch`, optional `-winsdk`, `-no_ext`, `-no_logo`)
   - then `set` to print the full environment.

5. Captures the `set` output, compares it against the current PowerShell environment, and returns an ordered hashtable of **only the variables that changed**.

It also includes variables that were present before but are not present in the `VsDevCmd.bat` output (returned with a `$null` value to indicate “unset”).

`Enter-VsDevShell`:

- Has multiple parameter sets:
   - Computes and applies a VS dev env delta (default) by calling `Get-VsDevEnv`.
   - Applies a precomputed delta object (`[IDictionary]`) from the pipeline.
   - Applies a standard `.env` file via `-EnvFilePath` (imports then applies).
- Applies variables using `[System.Environment]::SetEnvironmentVariable(key, value)`.
- Captures a pre-enter snapshot for the keys it is about to change in `$global:VsDevShellState`.
- Refuses to “enter” again while active unless `-Force` is provided.

`Exit-VsDevShell`:

- Restores environment variables from `$global:VsDevShellState.PreEnv`.
- Supports `-EnvFilePath` to restore only the keys listed in that `.env` file.
- Clears the saved global state when fully restored.

`Export-VsDevEnv`:

- Can compute a delta (by calling `Get-VsDevEnv`) or accept one via the pipeline (`-EnvDelta`).
- Writes a standard `.env` file (UTF-8 no BOM).
- `-Mode Create` fails if the file exists; `-Mode Update` preserves unrelated lines and only replaces keys being exported.
- `-PathMode` controls how `PATH` is handled (`Full`, `Skip`, `GitHubPath`).

`Import-VsDevEnv`:

- Parses `NAME=VALUE` lines (with optional quoting).
- Unescapes the module’s exported escape sequences.
- Treats `NAME=""` as `$null` (“unset” convention).

Notes:

- `AppPlatform` is currently accepted as a parameter but not used to build `VsDevCmd.bat` arguments.
- The module sets `VSCMD_SKIP_SENDTELEMETRY=1` and `VSCMD_BANNER_SHELL_NAME_ALT=...` for the `VsDevCmd.bat` invocation (without mutating the caller's environment).
- The environment changes apply to the current PowerShell process (and child processes started after). They do not persist system-wide.

## Usage (manual verification)

Import from source:

```powershell
Import-Module "$PSScriptRoot\VsDevShell\VsDevShell.psd1" -Force
```

See available parameters:

```powershell
Get-Help Enter-VsDevShell -Full
Get-Help Exit-VsDevShell -Full
Get-Help Get-VsDevEnv -Full
Get-Help Export-VsDevEnv -Full
Get-Help Import-VsDevEnv -Full
```

Compute environment changes without applying:

```powershell
$envDelta = Get-VsDevEnv -Arch x64 -HostArch x64
$envDelta.Keys | Sort-Object | Select-Object -First 20
```

Enter the developer shell in the current session:

```powershell
Enter-VsDevShell x64
cl.exe /?
```

Export/import/apply pipeline:

```powershell
$envFile = Join-Path $PWD 'vsdev.env'
Get-VsDevEnv -Arch x64 -HostArch x64 |
   Export-VsDevEnv -Path $envFile -Mode Update -PassThru |
   Import-VsDevEnv |
   Enter-VsDevShell
```

Run tests:

```powershell
Invoke-Pester -Path .\tests
```

## Requirements / assumptions

- Windows only (relies on `%COMSPEC%` and `VsDevCmd.bat`).
- Visual Studio installed with `VsDevCmd.bat` present.
- `vswhere.exe` available either on `PATH` or at the default VS Installer location.
- PowerShell 5.1+ (module manifest declares `PowerShellVersion = '5.1'`; `CompatiblePSEditions` includes Desktop and Core).

## Troubleshooting clues

- `vswhere.exe not found.`: Visual Studio Installer tools not installed or non-standard location; install Visual Studio Installer / ensure `vswhere.exe` exists.
- `<path> not found.` errors: `installationPath` returned empty or points to a removed install; verify `vswhere -latest` output.
- `Failed to execute VsDevCmd.bat`: `VsDevCmd.bat` returned a non-zero exit code; run it manually in `cmd.exe` to see the real error output.

## Making changes (guardrails)

- Keep the public API stable (`Enter-VsDevShell`, `Exit-VsDevShell`, `Get-VsDevEnv`, `Export-VsDevEnv`, `Import-VsDevEnv`) unless explicitly asked to change it.
- Prefer changes that still allow `Import-Module` to succeed even when Visual Studio is not installed (fail only when commands are invoked).
- Avoid adding new dependencies; this module is intended to be lightweight.
- If you add parameters, ensure they are forwarded correctly to `VsDevCmd.bat` and are covered by a simple manual verification snippet in this file.
