
function Get-VsWherePath
{
    [CmdletBinding()]
    param(
    )

    $VsWhereCommand = Get-Command -Name vswhere -CommandType Application -ErrorAction SilentlyContinue

    if ($VsWhereCommand) {
        $VsWherePath = $VswhereCommand[0].Source
    } else {
        $VsWherePath = Join-Path ${Env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    }

    $VsWherePath
}

function Invoke-VsWhere
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string] $VsWherePath
    )

    $VsInstallPath = & $VsWherePath "-latest" "-property" "installationPath"
    [string] $VsInstallPath
}

function Get-VsInstallPath
{
    [CmdletBinding()]
    param(
    )
    
    $VsWherePath = Get-VsWherePath

    if (-Not (Test-Path -Path $VsWherePath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException] "vswhere.exe not found."
    }

    (Invoke-VsWhere -VsWherePath $VsWherePath).Trim()
}

function Get-VsDevCmdPath
{
    [CmdletBinding()]
    param(
        [string] $VsInstallPath
    )
    
    if ([string]::IsNullOrEmpty($VsInstallPath)) {
        $VsInstallPath = Get-VsInstallPath
    }

    $VsToolsPath = Join-Path $VsInstallPath "Common7/Tools"
    $VsDevCmdPath = Join-Path $VsToolsPath "VsDevCmd.bat"
    $VsDevCmdPath
}

function ConvertTo-VsDotEnvValue
{
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string] $Value
    )

    if ($null -eq $Value) {
        return '""'
    }

    $escaped = [string] $Value
    $escaped = $escaped.Replace('\', '\\')
    $escaped = $escaped.Replace('"', '\"')
    $escaped = $escaped.Replace("`r", '\r')
    $escaped = $escaped.Replace("`n", '\n')
    $escaped = $escaped.Replace("`t", '\t')

    '"' + $escaped + '"'
}

function ConvertTo-VsDotEnv
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.IDictionary] $EnvDelta
    )

    $lines = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $EnvDelta.GetEnumerator()) {
        $name = [string] $entry.Key

        if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('=') -or $name -match '\s') {
            continue
        }

        $lines.Add(($name + '=' + (ConvertTo-VsDotEnvValue -Value $entry.Value)))
    }

    $text = $lines -join [System.Environment]::NewLine
    if ($text.Length -gt 0) {
        $text += [System.Environment]::NewLine
    }
    $text
}

function Write-TextFileUtf8NoBom
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string] $Path,
        [Parameter(Mandatory=$true)]
        [string] $Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Invoke-VsDevCmdSet
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string] $VsDevCmdPath,
        [Parameter(Mandatory=$true)]
        [string] $VsCmdArgs
    )

    $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processStartInfo.FileName = "${Env:COMSPEC}"
    $processStartInfo.Arguments = "/c `"`"$VsDevCmdPath`" $VsCmdArgs && set`""
    $processStartInfo.WorkingDirectory = Split-Path $VsDevCmdPath
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processStartInfo
    $process.Start() | Out-Null
    $outputText = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()

    [ordered]@{
        ExitCode = $process.ExitCode
        OutputLines = ($outputText -split "`r`n")
    }
}

function Get-VsDevEnv
{
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [ValidateSet('x86','x64','arm','arm64')]
        [string] $Arch = "x64",
        [ValidateSet('x86','x64')]
        [string] $HostArch = "x64",
        [ValidateSet('Desktop','UWP')]
        [string] $AppPlatform = "Desktop",
        [string] $WinSdk,
        [switch] $NoExt,
        [switch] $NoLogo,
        [string] $VsInstallPath,
        [switch] $AsDotEnv,
        [string] $DotEnvPath
    )

    if ([string]::IsNullOrEmpty($VsInstallPath)) {
        $VsInstallPath = Get-VsInstallPath
    }

    if (-Not (Test-Path -Path $VsInstallPath -PathType Container)) {
        throw [System.IO.FileNotFoundException] "$VsInstallPath not found."
    }

    $VsDevCmdPath = Get-VsDevCmdPath -VsInstallPath $VsInstallPath

    if (-Not (Test-Path -Path $VsDevCmdPath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException] "$VsDevCmdPath not found."
    }

    $Arch = $Arch.ToLower()
    $HostArch = $HostArch.ToLower()

    $VsCmdArgs = "-arch=$Arch"
    $VsCmdArgs += " -host_arch=$HostArch"

    if (-Not [string]::IsNullOrEmpty($WinSdk)) {
        $VsCmdArgs += " -winsdk=$WinSdk"
    }

    if ($NoExt) {
        $VsCmdArgs += " -no_ext"
    }

    if ($NoLogo) {
        $VsCmdArgs += " -no_logo"
    }

    $Env:VSCMD_SKIP_SENDTELEMETRY = "1"
    $Env:VSCMD_BANNER_SHELL_NAME_ALT = "$Arch Developer Shell"

    $vsCmdResult = Invoke-VsDevCmdSet -VsDevCmdPath $VsDevCmdPath -VsCmdArgs $VsCmdArgs
    $VsCmdOutput = $vsCmdResult.OutputLines

    if ($vsCmdResult.ExitCode -ne 0) {
        throw "Failed to execute VsDevCmd.bat"
    }

    $PreEnv = [ordered]@{}
    (Get-ChildItem env:) | ForEach-Object {
        $PreEnv.Add($_.Name, $_.Value)
    }

    $VsDevEnv = [ordered]@{}
    $VsCmdNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($VsCmdLine in $VsCmdOutput) {
        if ($VsCmdLine.Contains('=')) {
            $Name, $Value = $VsCmdLine -split '=', 2
            $null = $VsCmdNames.Add($Name)
            if ($PreEnv[$Name] -ne $Value) {
                $VsDevEnv.Add($Name, $Value)
            }
        }
    }

    foreach ($name in $PreEnv.Keys) {
        if (-not $VsCmdNames.Contains($name)) {
            $VsDevEnv[$name] = $null
        }
    }

    if ($AsDotEnv -or $PSBoundParameters.ContainsKey('DotEnvPath')) {
        $dotEnvText = ConvertTo-VsDotEnv -EnvDelta $VsDevEnv

        if (-not [string]::IsNullOrEmpty($DotEnvPath)) {
            Write-TextFileUtf8NoBom -Path $DotEnvPath -Content $dotEnvText
        }

        return $dotEnvText
    }

    $VsDevEnv
}

function Enter-VsDevShell
{
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [ValidateSet('x86','x64','arm','arm64')]
        [string] $Arch = "x64",
        [ValidateSet('x86','x64')]
        [string] $HostArch = "x64",
        [ValidateSet('Desktop','UWP')]
        [string] $AppPlatform = "Desktop",
        [string] $WinSdk,
        [switch] $NoExt,
        [switch] $NoLogo,
        [string] $VsInstallPath
    )

    $VsDevEnv = Get-VsDevEnv -Arch:$Arch -HostArch:$HostArch `
        -AppPlatform:$AppPlatform -WinSdk:$WinSdk `
        -NoExt:$NoExt -NoLogo:$NoLogo `
        -VsInstallPath:$VsInstallPath

    $VsDevEnv.GetEnumerator() | ForEach-Object {
        [System.Environment]::SetEnvironmentVariable($_.Key, $_.Value)
    }
}
