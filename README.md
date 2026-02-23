# Visual Studio Developer Shell

Enter a Visual Studio developer environment from PowerShell the way it should have always been:

```powershell
Install-Module VsDevShell
Enter-VsDevShell x64
```

That's it! Use `Get-Help Enter-VsDevShell` to find all available options.

## Export as dotenv (.env)

Get the environment delta as dotenv text:

```powershell
Get-VsDevEnv x64 -AsDotEnv
```

Write it to disk as a `.env` file:

```powershell
Get-VsDevEnv x64 -DotEnvPath .\.env
```
