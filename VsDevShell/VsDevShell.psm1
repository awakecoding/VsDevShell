
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

function ConvertFrom-VsDotEnvValue
{
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string] $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $trimmed = $Value.Trim()

    # Convention for this module: NAME="" means "unset" (round-trips $null from Get-VsDevEnv/Export-VsDevEnv)
    if ($trimmed -eq '""') {
        return $null
    }
    if ($trimmed.Length -ge 2 -and $trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) {
        $inner = $trimmed.Substring(1, $trimmed.Length - 2)

        $sb = New-Object System.Text.StringBuilder
        $i = 0
        while ($i -lt $inner.Length) {
            $ch = $inner[$i]
            if ($ch -ne '\') {
                $null = $sb.Append($ch)
                $i++
                continue
            }

            $start = $i
            while ($i -lt $inner.Length -and $inner[$i] -eq '\') {
                $i++
            }

            $slashCount = $i - $start
            $nextChar = if ($i -lt $inner.Length) { $inner[$i] } else { $null }

            $isEscape = $false
            $escapedChar = $null
            if ($null -ne $nextChar -and ($slashCount % 2 -eq 1)) {
                switch ($nextChar) {
                    'n' { $isEscape = $true; $escapedChar = "`n" }
                    'r' { $isEscape = $true; $escapedChar = "`r" }
                    't' { $isEscape = $true; $escapedChar = "`t" }
                    '"' { $isEscape = $true; $escapedChar = '"' }
                }
            }

            $literalSlashPairs = if ($isEscape) { ($slashCount - 1) / 2 } else { $slashCount / 2 }
            for ($j = 0; $j -lt $literalSlashPairs; $j++) {
                $null = $sb.Append('\')
            }

            if ($isEscape) {
                $null = $sb.Append($escapedChar)
                $i++
            }
            else {
                if ($slashCount % 2 -eq 1) {
                    $null = $sb.Append('\')
                }
                if ($null -ne $nextChar) {
                    $null = $sb.Append($nextChar)
                    $i++
                }
            }
        }

        $result = $sb.ToString()
        if ($result.Length -eq 0) {
            return $null
        }

        return $result
    }

    if ($trimmed.Length -ge 2 -and $trimmed.StartsWith("'") -and $trimmed.EndsWith("'")) {
        return $trimmed.Substring(1, $trimmed.Length - 2)
    }

    return $trimmed
}

function Import-VsDevEnv
{
    [CmdletBinding()]
    param(
        [Parameter(Position=0, Mandatory=$true, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [Alias('FullName','PSPath','LiteralPath')]
        [string] $Path
    )

    process {
        if (-not (Test-Path -Path $Path -PathType Leaf)) {
            throw [System.IO.FileNotFoundException] "$Path not found."
        }

        $text = [System.IO.File]::ReadAllText($Path)
        $lines = $text -split "`r?`n"

        $envDelta = [ordered]@{}

        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }
            if ($trimmed.StartsWith('#')) {
                continue
            }

            if ($trimmed -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
                continue
            }

            $name = $Matches[1]
            $rawValue = $Matches[2]
            $envDelta[$name] = ConvertFrom-VsDotEnvValue -Value $rawValue
        }

        $envDelta
    }
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

function Add-TextFileUtf8NoBom
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
    [System.IO.File]::AppendAllText($Path, $Content, $encoding)
}

function Remove-EnvAssignments
{
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $Lines = @(),
        [Parameter(Mandatory=$true)]
        [System.Collections.Generic.HashSet[string]] $KeysToRemove
    )

    foreach ($line in $Lines) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') {
            $key = $Matches[1]
            if ($KeysToRemove.Contains($key)) {
                continue
            }
        }

        $line
    }
}

function Export-VsDevEnv
{
    [CmdletBinding(DefaultParameterSetName='FromParameters')]
    param(
        [Parameter(Mandatory=$true)]
        [string] $Path,

        [ValidateSet('Create', 'Update')]
        [string] $Mode = 'Update',

        [ValidateSet('Full', 'Skip', 'GitHubPath')]
        [string] $PathMode = 'Full',

        [switch] $PassThru,

        [Parameter(ParameterSetName='FromDelta', Mandatory=$true, ValueFromPipeline=$true)]
        [System.Collections.IDictionary] $EnvDelta,

        [Parameter(ParameterSetName='FromParameters')]
        [ValidateSet('x86','x64','arm','arm64')]
        [string] $Arch = 'x64',

        [Parameter(ParameterSetName='FromParameters')]
        [ValidateSet('x86','x64')]
        [string] $HostArch = 'x64',

        [Parameter(ParameterSetName='FromParameters')]
        [ValidateSet('Desktop','UWP')]
        [string] $AppPlatform = 'Desktop',

        [Parameter(ParameterSetName='FromParameters')]
        [string] $WinSdk,

        [Parameter(ParameterSetName='FromParameters')]
        [switch] $NoExt,

        [Parameter(ParameterSetName='FromParameters')]
        [switch] $NoLogo,

        [Parameter(ParameterSetName='FromParameters')]
        [string] $VsInstallPath
    )

    $baselinePath = $Env:Path

    if ($PSCmdlet.ParameterSetName -eq 'FromParameters') {
        $EnvDelta = Get-VsDevEnv -Arch:$Arch -HostArch:$HostArch `
            -AppPlatform:$AppPlatform -WinSdk:$WinSdk `
            -NoExt:$NoExt -NoLogo:$NoLogo `
            -VsInstallPath:$VsInstallPath
    }

    $exportDelta = [ordered]@{}
    foreach ($entry in $EnvDelta.GetEnumerator()) {
        $exportDelta[$entry.Key] = $entry.Value
    }

    if ($PathMode -eq 'Skip') {
        $null = $exportDelta.Remove('Path')
        $null = $exportDelta.Remove('PATH')
    }
    elseif ($PathMode -eq 'GitHubPath') {
        $githubPath = $Env:GITHUB_PATH
        if (-not [string]::IsNullOrEmpty($githubPath) -and $exportDelta.Contains('PATH')) {
            $newPath = [string] $exportDelta['PATH']

            if (-not [string]::IsNullOrEmpty($baselinePath) -and $newPath.EndsWith($baselinePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $prefix = $newPath.Substring(0, $newPath.Length - $baselinePath.Length)
                $prefix = $prefix.TrimEnd(';')
                $prefixParts = $prefix -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

                if ($prefixParts.Count -gt 0) {
                    $content = ($prefixParts -join [System.Environment]::NewLine) + [System.Environment]::NewLine
                    Add-TextFileUtf8NoBom -Path $githubPath -Content $content
                    $null = $exportDelta.Remove('PATH')
                }
            }
        }
    }

    $dotEnvText = ConvertTo-VsDotEnv -EnvDelta $exportDelta

    if ($Mode -eq 'Create' -and (Test-Path -Path $Path -PathType Leaf)) {
        throw "File already exists: $Path"
    }

    if ($Mode -eq 'Update' -and (Test-Path -Path $Path -PathType Leaf)) {
        $existingText = [System.IO.File]::ReadAllText($Path)
        $existingLines = $existingText -split "`r?`n"

        $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $exportDelta.Keys) { $null = $keys.Add([string] $k) }

        $keptLines = @(Remove-EnvAssignments -Lines $existingLines -KeysToRemove $keys)
        $keptText = ($keptLines -join [System.Environment]::NewLine).TrimEnd()

        if ($keptText.Length -gt 0) {
            $keptText += [System.Environment]::NewLine
        }

        Write-TextFileUtf8NoBom -Path $Path -Content ($keptText + $dotEnvText)
    }
    else {
        Write-TextFileUtf8NoBom -Path $Path -Content $dotEnvText
    }

    if ($PassThru) {
        Get-Item -Path $Path
    }
}

function Invoke-VsDevCmdSet
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string] $VsDevCmdPath,
        [Parameter(Mandatory=$true)]
        [string] $VsCmdArgs,
        [hashtable] $AdditionalEnvironment
    )

    $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processStartInfo.FileName = "${Env:COMSPEC}"
    $processStartInfo.Arguments = "/c `"`"$VsDevCmdPath`" $VsCmdArgs && set`""
    $processStartInfo.WorkingDirectory = Split-Path $VsDevCmdPath
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.CreateNoWindow = $true

    if ($AdditionalEnvironment) {
        foreach ($pair in $AdditionalEnvironment.GetEnumerator()) {
            $key = [string] $pair.Key
            $value = if ($null -eq $pair.Value) { '' } else { [string] $pair.Value }

            if ($processStartInfo.PSObject.Properties.Name -contains 'Environment') {
                $processStartInfo.Environment[$key] = $value
            }
            else {
                $processStartInfo.EnvironmentVariables[$key] = $value
            }
        }
    }

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
        [string] $VsInstallPath
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

    $additionalEnv = @{
        VSCMD_SKIP_SENDTELEMETRY = '1'
        VSCMD_BANNER_SHELL_NAME_ALT = "$Arch Developer Shell"
    }

    $vsCmdResult = Invoke-VsDevCmdSet -VsDevCmdPath $VsDevCmdPath -VsCmdArgs $VsCmdArgs -AdditionalEnvironment $additionalEnv
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

    $VsDevEnv
}

function Enter-VsDevShell
{
    [CmdletBinding(DefaultParameterSetName='FromParameters')]
    param(
        [Parameter(ParameterSetName='FromParameters', Position=0)]
        [ValidateSet('x86','x64','arm','arm64')]
        [string] $Arch = "x64",
        [Parameter(ParameterSetName='FromParameters')]
        [ValidateSet('x86','x64')]
        [string] $HostArch = "x64",
        [Parameter(ParameterSetName='FromParameters')]
        [ValidateSet('Desktop','UWP')]
        [string] $AppPlatform = "Desktop",
        [Parameter(ParameterSetName='FromParameters')]
        [string] $WinSdk,
        [Parameter(ParameterSetName='FromParameters')]
        [switch] $NoExt,
        [Parameter(ParameterSetName='FromParameters')]
        [switch] $NoLogo,
        [Parameter(ParameterSetName='FromParameters')]
        [string] $VsInstallPath,

        [Parameter(ParameterSetName='FromFile', Mandatory=$true, Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [Alias('Path', 'FullName', 'PSPath', 'LiteralPath')]
        [string] $EnvFilePath,

        [Parameter(ParameterSetName='FromEnv', Mandatory=$true, ValueFromPipeline=$true)]
        [System.Collections.IDictionary] $VsDevEnv,

        [switch] $Force
    )

    process {
        if ($global:VsDevShellState -and -not $Force) {
            throw "VsDevShell is already active in this session. Call Leave-VsDevShell first (or use -Force to overwrite the saved state)."
        }

        if ($Force -and $global:VsDevShellState) {
            Remove-Variable -Scope Global -Name VsDevShellState -ErrorAction SilentlyContinue
        }

        if ($PSCmdlet.ParameterSetName -eq 'FromParameters') {
            $VsDevEnv = Get-VsDevEnv -Arch:$Arch -HostArch:$HostArch `
                -AppPlatform:$AppPlatform -WinSdk:$WinSdk `
                -NoExt:$NoExt -NoLogo:$NoLogo `
                -VsInstallPath:$VsInstallPath
        }

        if ($PSCmdlet.ParameterSetName -eq 'FromFile') {
            $VsDevEnv = Import-VsDevEnv -Path $EnvFilePath
        }

        $preEnv = [ordered]@{}
        foreach ($key in $VsDevEnv.Keys) {
            $preEnv[$key] = [System.Environment]::GetEnvironmentVariable([string] $key)
        }

        $global:VsDevShellState = [pscustomobject]@{
            IsActive = $true
            EnteredAt = Get-Date
            PreEnv = $preEnv
        }

        $VsDevEnv.GetEnumerator() | ForEach-Object {
            [System.Environment]::SetEnvironmentVariable($_.Key, $_.Value)
        }
    }
}

function Leave-VsDevShell
{
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium', DefaultParameterSetName='All')]
    param(
        [Parameter(ParameterSetName='FromFile', Mandatory=$true, Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [Alias('Path', 'FullName', 'PSPath', 'LiteralPath')]
        [string] $EnvFilePath,

        [switch] $Force
    )

    process {
        $state = $global:VsDevShellState
        if (-not $state -or -not $state.IsActive -or -not $state.PreEnv) {
            if (-not $Force) {
                Write-Verbose 'No active VsDevShell session state was found.'
            }
            return
        }

        $keysToRestore = @()
        if ($PSCmdlet.ParameterSetName -eq 'FromFile') {
            $fileDelta = Import-VsDevEnv -Path $EnvFilePath
            $keysToRestore = @($fileDelta.Keys)
        }
        else {
            $keysToRestore = @($state.PreEnv.Keys)
        }

        foreach ($key in $keysToRestore) {
            $value = $null
            if ($state.PreEnv.Contains($key)) {
                $value = $state.PreEnv[$key]
            }

            if ($PSCmdlet.ShouldProcess("Env:$key", 'Restore')) {
                [System.Environment]::SetEnvironmentVariable([string] $key, $value)
            }

            if ($state.PreEnv.Contains($key)) {
                $null = $state.PreEnv.Remove($key)
            }
        }

        if ($state.PreEnv.Count -eq 0) {
            Remove-Variable -Scope Global -Name VsDevShellState -ErrorAction SilentlyContinue
        }
    }
}
