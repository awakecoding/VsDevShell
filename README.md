# Visual Studio Developer Shell

Enter a Visual Studio developer environment from PowerShell the way it should have always been:

```powershell
Install-Module VsDevShell
Enter-VsDevShell x64
```

Restore the original environment:

```powershell
Exit-VsDevShell
```

That's it! Use `Get-Help Enter-VsDevShell` to find all available options.

## Compute without applying

Get the environment delta (only variables that would change):

```powershell
$delta = Get-VsDevEnv -Arch x64 -HostArch x64
$delta.Keys | Sort-Object | Select-Object -First 20
```

## Export as dotenv (.env)

Write the environment delta to disk as a `.env` file:

```powershell
Export-VsDevEnv -Arch x64 -HostArch x64 -Path .\vsdev.env
```

Update an existing `.env` file in-place (replaces only the exported keys; preserves other lines):

```powershell
Export-VsDevEnv -Arch x64 -HostArch x64 -Path .\vsdev.env -Mode Update
```

Fail if the target file already exists:

```powershell
Export-VsDevEnv -Arch x64 -HostArch x64 -Path .\vsdev.env -Mode Create
```

## Import and apply

Import a previously exported `.env` delta and apply it to the current PowerShell session:

```powershell
Import-VsDevEnv .\vsdev.env | Enter-VsDevShell
```

This is useful when you want to generate the delta in one step/process and apply it later in another.

Fully piped chain (compute → export → import → apply):

```powershell
Get-VsDevEnv -Arch x64 -HostArch x64 |
	Export-VsDevEnv -Path .\vsdev.env -Mode Update -PassThru |
	Import-VsDevEnv |
	Enter-VsDevShell
```

Apply an existing `.env` file directly (shortcut for `Import-VsDevEnv ... | Enter-VsDevShell`):

```powershell
Enter-VsDevShell -EnvFilePath .\vsdev.env
```

## GitHub Actions example

In GitHub Actions, `$env:GITHUB_ENV` is a UTF-8 no-BOM file containing `NAME=VALUE` lines.
You can update it so later steps inherit the VS dev environment:

```powershell
Export-VsDevEnv -Arch x64 -HostArch x64 -Path $env:GITHUB_ENV -Mode Update
```

If you also want to use `$env:GITHUB_PATH` for PATH updates (when it is available), use:

```powershell
Export-VsDevEnv -Arch x64 -HostArch x64 -Path $env:GITHUB_ENV -Mode Update -PathMode GitHubPath
```

Apply an existing env file (like `$env:GITHUB_ENV`) to the current PowerShell session:

```powershell
Enter-VsDevShell -EnvFilePath $env:GITHUB_ENV
```

Pipeline form:

```powershell
Get-Item -Path $env:GITHUB_ENV | Enter-VsDevShell
```

Restore only the keys listed in an env file (using the saved pre-enter snapshot):

```powershell
Exit-VsDevShell -EnvFilePath $env:GITHUB_ENV
```

Pipeline form:

```powershell
Get-Item -Path $env:GITHUB_ENV | Exit-VsDevShell
```
