$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$moduleManifest = Join-Path $repoRoot 'VsDevShell/VsDevShell.psd1'

Import-Module $moduleManifest -Force | Out-Null

Describe 'VsDevShell' {
    InModuleScope VsDevShell {
        Context 'ConvertTo-VsDotEnvValue' {
            It 'Quotes null as empty string' {
                ConvertTo-VsDotEnvValue -Value $null | Should -Be '""'
            }

            It 'Escapes backslashes, quotes, and newlines' {
                $value = "C:\path\`"quoted`"`nline2"
                $expected = '"C:\\path\\\"quoted\"' + '\n' + 'line2"'
                ConvertTo-VsDotEnvValue -Value $value | Should -Be $expected
            }
        }

        Context 'ConvertTo-VsDotEnv' {
            It 'Skips invalid keys and ends with a newline' {
                $delta = [ordered]@{
                    'GOOD' = '1'
                    'BAD KEY' = '2'
                    'BAD=KEY' = '3'
                }

                $text = ConvertTo-VsDotEnv -EnvDelta $delta

                $text | Should -Match '(?m)^GOOD="1"\r?$'
                $text | Should -Not -Match 'BAD KEY='
                $text | Should -Not -Match 'BAD=KEY='
                $text | Should -Match '(\r\n|\n)$'
            }

            It 'Returns empty string for an empty delta' {
                ConvertTo-VsDotEnv -EnvDelta ([ordered]@{}) | Should -Be ''
            }
        }

        Context 'Get-VsInstallPath' {
            It 'Throws when vswhere.exe is missing' {
                Mock Get-VsWherePath { 'C:\missing\vswhere.exe' }
                Mock Test-Path { $false } -ParameterFilter { $Path -eq 'C:\missing\vswhere.exe' -and $PathType -eq 'Leaf' }

                { Get-VsInstallPath } | Should -Throw
            }

            It 'Trims the vswhere output' {
                Mock Get-VsWherePath { 'C:\ok\vswhere.exe' }
                Mock Test-Path { $true } -ParameterFilter { $Path -eq 'C:\ok\vswhere.exe' -and $PathType -eq 'Leaf' }
                Mock Invoke-VsWhere { "C:\VS`r`n" }

                Get-VsInstallPath | Should -Be 'C:\VS'
            }
        }

        Context 'Get-VsDevEnv (unit, mocked execution)' {
            BeforeEach {
                Mock Get-VsDevCmdPath { 'C:\VS\Common7\Tools\VsDevCmd.bat' }

                Mock Test-Path { $true } -ParameterFilter { $Path -eq 'C:\VS' -and $PathType -eq 'Container' }
                Mock Test-Path { $true } -ParameterFilter { $Path -eq 'C:\VS\Common7\Tools\VsDevCmd.bat' -and $PathType -eq 'Leaf' }

                Mock Get-ChildItem {
                    @(
                        [pscustomobject]@{ Name = 'FOO'; Value = 'before' },
                        [pscustomobject]@{ Name = 'UNCHANGED'; Value = 'same' },
                        [pscustomobject]@{ Name = 'REMOVED'; Value = 'x' }
                    )
                } -ParameterFilter { $Path -eq 'env:' }

                Mock Invoke-VsDevCmdSet {
                    [ordered]@{
                        ExitCode = 0
                        OutputLines = @(
                            'FOO=after',
                            'UNCHANGED=same'
                        )
                    }
                }
            }

            It 'Returns only changed and removed variables' {
                $delta = Get-VsDevEnv -VsInstallPath 'C:\VS'

                $delta.Keys | Should -Contain 'FOO'
                $delta['FOO'] | Should -Be 'after'

                $delta.Keys | Should -Contain 'REMOVED'
                $delta['REMOVED'] | Should -BeNullOrEmpty

                $delta.Keys | Should -Not -Contain 'UNCHANGED'
            }

            It 'Includes new variables set by VsDevCmd' {
                Mock Get-ChildItem {
                    @(
                        [pscustomobject]@{ Name = 'FOO'; Value = 'before' }
                    )
                } -ParameterFilter { $Path -eq 'env:' }

                Mock Invoke-VsDevCmdSet {
                    [ordered]@{
                        ExitCode = 0
                        OutputLines = @(
                            'FOO=before',
                            'NEWVAR=new'
                        )
                    }
                }

                $delta = Get-VsDevEnv -VsInstallPath 'C:\VS'
                $delta.Keys | Should -Contain 'NEWVAR'
                $delta['NEWVAR'] | Should -Be 'new'
                $delta.Keys | Should -Not -Contain 'FOO'
            }

            It 'Ignores lines without "=" and preserves values containing "="' {
                Mock Invoke-VsDevCmdSet {
                    [ordered]@{
                        ExitCode = 0
                        OutputLines = @(
                            'THIS IS NOT AN ENV LINE',
                            'HAS_EQUALS=a=b=c'
                        )
                    }
                }

                $delta = Get-VsDevEnv -VsInstallPath 'C:\VS'
                $delta['HAS_EQUALS'] | Should -Be 'a=b=c'
            }

            It 'Builds VsDevCmd arguments from parameters' {
                Mock Invoke-VsDevCmdSet {
                    [ordered]@{ ExitCode = 0; OutputLines = @('FOO=after') }
                }

                $null = Get-VsDevEnv -VsInstallPath 'C:\VS' -Arch ARM64 -HostArch X64 -WinSdk '10.0.0.0' -NoExt -NoLogo

                Assert-MockCalled Invoke-VsDevCmdSet -Times 1 -ParameterFilter {
                    $VsCmdArgs -like '*-arch=arm64*' -and
                    $VsCmdArgs -like '*-host_arch=x64*' -and
                    $VsCmdArgs -like '*-winsdk=10.0.0.0*' -and
                    $VsCmdArgs -like '*-no_ext*' -and
                    $VsCmdArgs -like '*-no_logo*'
                }
            }
        }

        Context 'Get-VsDevEnv (unit, error paths)' {
            BeforeEach {
                Mock Get-VsDevCmdPath { 'C:\VS\Common7\Tools\VsDevCmd.bat' }
            }

            It 'Throws if the VS install path does not exist' {
                Mock Test-Path { $false } -ParameterFilter { $Path -eq 'C:\VS' -and $PathType -eq 'Container' }
                { Get-VsDevEnv -VsInstallPath 'C:\VS' } | Should -Throw
            }

            It 'Throws if VsDevCmd.bat does not exist' {
                Mock Test-Path { $true } -ParameterFilter { $Path -eq 'C:\VS' -and $PathType -eq 'Container' }
                Mock Test-Path { $false } -ParameterFilter { $Path -eq 'C:\VS\Common7\Tools\VsDevCmd.bat' -and $PathType -eq 'Leaf' }
                { Get-VsDevEnv -VsInstallPath 'C:\VS' } | Should -Throw
            }

            It 'Throws if VsDevCmd.bat returns a non-zero exit code' {
                Mock Test-Path { $true } -ParameterFilter { $Path -eq 'C:\VS' -and $PathType -eq 'Container' }
                Mock Test-Path { $true } -ParameterFilter { $Path -eq 'C:\VS\Common7\Tools\VsDevCmd.bat' -and $PathType -eq 'Leaf' }
                Mock Get-ChildItem { @() } -ParameterFilter { $Path -eq 'env:' }
                Mock Invoke-VsDevCmdSet { [ordered]@{ ExitCode = 1; OutputLines = @() } }

                { Get-VsDevEnv -VsInstallPath 'C:\VS' } | Should -Throw
            }
        }

        Context 'Export-VsDevEnv (unit)' {
            It 'Creates a new .env file from a provided delta' {
                $path = Join-Path $TestDrive 'out/vs.env'
                $delta = [ordered]@{ FOO = 'bar' }

                Export-VsDevEnv -Path $path -Mode Create -EnvDelta $delta
                (Get-Content -Path $path -Raw) | Should -Match '(?m)^FOO="bar"\r?$'

                $bytes = [System.IO.File]::ReadAllBytes($path)
                if ($bytes.Length -ge 3) {
                    ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
                }
            }

            It 'Updates an existing .env file by replacing keys and preserving other lines' {
                $path = Join-Path $TestDrive 'out/vs.env'
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                Set-Content -Encoding UTF8 -Path $path -Value @(
                    '# keep comment',
                    'KEEP=1',
                    'FOO="old"'
                )

                $delta = [ordered]@{ FOO = 'new'; BAR = '2' }
                Export-VsDevEnv -Path $path -Mode Update -EnvDelta $delta

                $content = Get-Content -Path $path -Raw
                $content | Should -Match '(?m)^# keep comment\r?$'
                $content | Should -Match '(?m)^KEEP=1\r?$'
                $content | Should -Not -Match '(?m)^FOO="old"\r?$'
                $content | Should -Match '(?m)^FOO="new"\r?$'
                $content | Should -Match '(?m)^BAR="2"\r?$'

                ([regex]::Matches($content, '(?m)^FOO=')).Count | Should -Be 1
            }

            It 'Throws in Create mode when the file already exists' {
                $path = Join-Path $TestDrive 'out/vs.env'
                New-Item -ItemType File -Force -Path $path | Out-Null

                { Export-VsDevEnv -Path $path -Mode Create -EnvDelta ([ordered]@{ A = '1' }) } | Should -Throw
            }
        }

        Context 'Import-VsDevEnv' {
            It 'Parses basic KEY=VALUE entries and ignores comments/blank lines' {
                $path = Join-Path $TestDrive 'in/basic.env'
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                Set-Content -Encoding UTF8 -Path $path -Value @(
                    '# comment',
                    '',
                    'A=1',
                    'B="two"'
                )

                $delta = Import-VsDevEnv -Path $path
                $delta['A'] | Should -Be '1'
                $delta['B'] | Should -Be 'two'
            }

            It 'Unescapes exported sequences in double-quoted values' {
                $path = Join-Path $TestDrive 'in/esc.env'
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                Set-Content -Encoding UTF8 -Path $path -Value @(
                    'Q="a\"b"',
                    'P="C:\\temp"',
                    'N="line1\nline2"',
                    'T="a\tb"'
                )

                $delta = Import-VsDevEnv -Path $path
                    $delta['Q'] | Should -Be 'a"b'
                $delta['P'] | Should -Be 'C:\temp'
                $delta['N'] | Should -Be "line1`nline2"
                $delta['T'] | Should -Be "a`tb"
            }

            It 'Treats NAME="" as $null (unset convention)' {
                $path = Join-Path $TestDrive 'in/unset.env'
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                Set-Content -Encoding UTF8 -Path $path -Value @(
                    'UNSET=""'
                )

                $delta = Import-VsDevEnv -Path $path
                $delta['UNSET'] | Should -BeNullOrEmpty
                ($null -eq $delta['UNSET']) | Should -BeTrue
            }

            It 'Throws when the file does not exist' {
                { Import-VsDevEnv -Path (Join-Path $TestDrive 'nope.env') } | Should -Throw
            }
        }

        Context 'Enter-VsDevShell (unit)' {
            BeforeEach {
                Remove-Variable -Scope Global -Name VsDevShellState -ErrorAction SilentlyContinue
            }

            AfterEach {
                Leave-VsDevShell -Force
                Remove-Variable -Scope Global -Name VsDevShellState -ErrorAction SilentlyContinue
            }

            It 'Applies values and removes variables when value is $null' {
                $oldFoo = [System.Environment]::GetEnvironmentVariable('FOO')
                $oldRemoved = [System.Environment]::GetEnvironmentVariable('REMOVED')

                try {
                    [System.Environment]::SetEnvironmentVariable('FOO', 'before')
                    [System.Environment]::SetEnvironmentVariable('REMOVED', 'x')

                    Mock Get-VsDevEnv {
                        [ordered]@{
                            FOO = 'after'
                            REMOVED = $null
                        }
                    }

                    Enter-VsDevShell -VsInstallPath 'C:\VS'

                    [System.Environment]::GetEnvironmentVariable('FOO') | Should -Be 'after'
                    [System.Environment]::GetEnvironmentVariable('REMOVED') | Should -BeNullOrEmpty
                }
                finally {
                    Leave-VsDevShell -Force
                    [System.Environment]::SetEnvironmentVariable('FOO', $oldFoo)
                    [System.Environment]::SetEnvironmentVariable('REMOVED', $oldRemoved)
                }
            }

            It 'Accepts a VsDevEnv object from the pipeline' {
                $path = Join-Path $TestDrive 'in/vs.env'
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                Set-Content -Encoding UTF8 -Path $path -Value @(
                    'FOO="pipe"',
                    'MULTI="line1\nline2"'
                )

                $oldFoo = [System.Environment]::GetEnvironmentVariable('FOO')
                $oldMulti = [System.Environment]::GetEnvironmentVariable('MULTI')
                try {
                    [System.Environment]::SetEnvironmentVariable('FOO', $null)
                    [System.Environment]::SetEnvironmentVariable('MULTI', $null)

                    Import-VsDevEnv -Path $path | Enter-VsDevShell

                    [System.Environment]::GetEnvironmentVariable('FOO') | Should -Be 'pipe'
                    [System.Environment]::GetEnvironmentVariable('MULTI') | Should -Be "line1`nline2"
                }
                finally {
                    Leave-VsDevShell -Force
                    [System.Environment]::SetEnvironmentVariable('FOO', $oldFoo)
                    [System.Environment]::SetEnvironmentVariable('MULTI', $oldMulti)
                }
            }

            It 'Accepts an env file path (standard .env / GITHUB_ENV style)' {
                $path = Join-Path $TestDrive 'in/github.env'
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                Set-Content -Encoding UTF8 -Path $path -Value @(
                    'FOO=fromfile',
                    'REMOVED=""'
                )

                $oldFoo = [System.Environment]::GetEnvironmentVariable('FOO')
                $oldRemoved = [System.Environment]::GetEnvironmentVariable('REMOVED')
                try {
                    [System.Environment]::SetEnvironmentVariable('FOO', $null)
                    [System.Environment]::SetEnvironmentVariable('REMOVED', 'x')

                    Enter-VsDevShell -EnvFilePath $path

                    [System.Environment]::GetEnvironmentVariable('FOO') | Should -Be 'fromfile'
                    [System.Environment]::GetEnvironmentVariable('REMOVED') | Should -BeNullOrEmpty
                }
                finally {
                    Leave-VsDevShell -Force
                    [System.Environment]::SetEnvironmentVariable('FOO', $oldFoo)
                    [System.Environment]::SetEnvironmentVariable('REMOVED', $oldRemoved)
                }
            }

            It 'Binds EnvFilePath from pipeline property (FileInfo.FullName)' {
                $path = Join-Path $TestDrive 'in/github2.env'
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                Set-Content -Encoding UTF8 -Path $path -Value @(
                    'FOO=frompipeline'
                )

                $oldFoo = [System.Environment]::GetEnvironmentVariable('FOO')
                try {
                    [System.Environment]::SetEnvironmentVariable('FOO', $null)

                    Get-Item -Path $path | Enter-VsDevShell

                    [System.Environment]::GetEnvironmentVariable('FOO') | Should -Be 'frompipeline'
                }
                finally {
                    Leave-VsDevShell -Force
                    [System.Environment]::SetEnvironmentVariable('FOO', $oldFoo)
                }
            }

            It 'Matches direct Enter-VsDevShell when using Get|Export|Import|Enter pipeline' {
                $keys = @('FOO','REMOVED','MULTI','PATH','KEEP')
                $saved = @{}
                foreach ($k in $keys) {
                    $saved[$k] = [System.Environment]::GetEnvironmentVariable($k)
                }

                $delta = [ordered]@{
                    FOO = 'after'
                    REMOVED = $null
                    MULTI = "line1`nline2"
                    PATH = 'C:\A;C:\B'
                }

                try {
                    # Establish a known baseline
                    [System.Environment]::SetEnvironmentVariable('FOO', 'before')
                    [System.Environment]::SetEnvironmentVariable('REMOVED', 'x')
                    [System.Environment]::SetEnvironmentVariable('MULTI', 'old')
                    [System.Environment]::SetEnvironmentVariable('PATH', 'C:\Z')
                    [System.Environment]::SetEnvironmentVariable('KEEP', 'keep')

                    Mock Get-VsDevEnv { $delta }

                    # Direct apply
                    Enter-VsDevShell -VsInstallPath 'C:\VS'
                    $direct = @{}
                    foreach ($k in $keys) {
                        $direct[$k] = [System.Environment]::GetEnvironmentVariable($k)
                    }

                    # Clear saved session state so the piped Enter can run
                    Leave-VsDevShell

                    # Reset baseline
                    [System.Environment]::SetEnvironmentVariable('FOO', 'before')
                    [System.Environment]::SetEnvironmentVariable('REMOVED', 'x')
                    [System.Environment]::SetEnvironmentVariable('MULTI', 'old')
                    [System.Environment]::SetEnvironmentVariable('PATH', 'C:\Z')
                    [System.Environment]::SetEnvironmentVariable('KEEP', 'keep')

                    # Chain: Get -> Export (via pipeline) -> Import -> Enter (via pipeline)
                    $outPath = Join-Path $TestDrive 'out/chain.env'
                    Get-VsDevEnv -VsInstallPath 'C:\VS' |
                        Export-VsDevEnv -Path $outPath -Mode Create -PassThru |
                        Import-VsDevEnv |
                        Enter-VsDevShell

                    foreach ($k in $keys) {
                        [System.Environment]::GetEnvironmentVariable($k) | Should -Be $direct[$k]
                    }
                }
                finally {
                    Leave-VsDevShell -Force
                    foreach ($k in $keys) {
                        [System.Environment]::SetEnvironmentVariable($k, $saved[$k])
                    }
                }
            }

            It 'Can restore the pre-enter environment via Leave-VsDevShell' {
                $oldFoo = [System.Environment]::GetEnvironmentVariable('FOO')
                $oldRemoved = [System.Environment]::GetEnvironmentVariable('REMOVED')

                try {
                    [System.Environment]::SetEnvironmentVariable('FOO', 'before')
                    [System.Environment]::SetEnvironmentVariable('REMOVED', 'x')

                    Mock Get-VsDevEnv {
                        [ordered]@{
                            FOO = 'after'
                            REMOVED = $null
                        }
                    }

                    Enter-VsDevShell -VsInstallPath 'C:\VS'
                    [System.Environment]::GetEnvironmentVariable('FOO') | Should -Be 'after'
                    [System.Environment]::GetEnvironmentVariable('REMOVED') | Should -BeNullOrEmpty
                    ($null -ne $global:VsDevShellState) | Should -BeTrue

                    Leave-VsDevShell
                    [System.Environment]::GetEnvironmentVariable('FOO') | Should -Be 'before'
                    [System.Environment]::GetEnvironmentVariable('REMOVED') | Should -Be 'x'
                    ($null -eq $global:VsDevShellState) | Should -BeTrue
                }
                finally {
                    [System.Environment]::SetEnvironmentVariable('FOO', $oldFoo)
                    [System.Environment]::SetEnvironmentVariable('REMOVED', $oldRemoved)
                    Remove-Variable -Scope Global -Name VsDevShellState -ErrorAction SilentlyContinue
                }
            }

            It 'Can restore using Leave-VsDevShell -EnvFilePath (symmetry with Enter -EnvFilePath)' {
                $path = Join-Path $TestDrive 'in/leave.env'
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                Set-Content -Encoding UTF8 -Path $path -Value @(
                    'FOO=fromfile',
                    'REMOVED=""'
                )

                $oldFoo = [System.Environment]::GetEnvironmentVariable('FOO')
                $oldRemoved = [System.Environment]::GetEnvironmentVariable('REMOVED')
                try {
                    [System.Environment]::SetEnvironmentVariable('FOO', 'before')
                    [System.Environment]::SetEnvironmentVariable('REMOVED', 'x')

                    Enter-VsDevShell -EnvFilePath $path
                    [System.Environment]::GetEnvironmentVariable('FOO') | Should -Be 'fromfile'
                    [System.Environment]::GetEnvironmentVariable('REMOVED') | Should -BeNullOrEmpty

                    Leave-VsDevShell -EnvFilePath $path
                    [System.Environment]::GetEnvironmentVariable('FOO') | Should -Be 'before'
                    [System.Environment]::GetEnvironmentVariable('REMOVED') | Should -Be 'x'
                }
                finally {
                    Leave-VsDevShell -Force
                    [System.Environment]::SetEnvironmentVariable('FOO', $oldFoo)
                    [System.Environment]::SetEnvironmentVariable('REMOVED', $oldRemoved)
                }
            }

            It 'Binds Leave-VsDevShell EnvFilePath from pipeline property (FileInfo.FullName)' {
                $path = Join-Path $TestDrive 'in/leave2.env'
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                Set-Content -Encoding UTF8 -Path $path -Value @(
                    'FOO=fromfile'
                )

                $oldFoo = [System.Environment]::GetEnvironmentVariable('FOO')
                try {
                    [System.Environment]::SetEnvironmentVariable('FOO', 'before')
                    Enter-VsDevShell -EnvFilePath $path
                    [System.Environment]::GetEnvironmentVariable('FOO') | Should -Be 'fromfile'

                    Get-Item -Path $path | Leave-VsDevShell
                    [System.Environment]::GetEnvironmentVariable('FOO') | Should -Be 'before'
                }
                finally {
                    Leave-VsDevShell -Force
                    [System.Environment]::SetEnvironmentVariable('FOO', $oldFoo)
                }
            }

            It 'Can round-trip using a full environment .env file export snippet' {
                $path = Join-Path $TestDrive 'in/full.env'
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null

                $sentinelKey = 'VSDEVSHELL_TEST_FOO'
                $oldSentinel = [System.Environment]::GetEnvironmentVariable($sentinelKey)

                try {
                    [System.Environment]::SetEnvironmentVariable($sentinelKey, 'before')

                    # Simple snippet: export the current process environment to a standard .env file (UTF-8 no BOM)
                    $lines = foreach ($item in (Get-ChildItem Env: | Sort-Object Name)) {
                        $name = [string] $item.Name
                        $value = [string] $item.Value
                        "$name=$(ConvertTo-VsDotEnvValue -Value $value)"
                    }

                    # Override the sentinel at the end (last assignment wins when importing)
                    $lines += "$sentinelKey=$(ConvertTo-VsDotEnvValue -Value 'after')"

                    $content = ($lines -join [System.Environment]::NewLine) + [System.Environment]::NewLine
                    $encoding = New-Object System.Text.UTF8Encoding($false)
                    [System.IO.File]::WriteAllText($path, $content, $encoding)

                    Enter-VsDevShell -EnvFilePath $path
                    [System.Environment]::GetEnvironmentVariable($sentinelKey) | Should -Be 'after'

                    Leave-VsDevShell -EnvFilePath $path
                    [System.Environment]::GetEnvironmentVariable($sentinelKey) | Should -Be 'before'
                }
                finally {
                    Leave-VsDevShell -Force
                    [System.Environment]::SetEnvironmentVariable($sentinelKey, $oldSentinel)
                }
            }
        }
    }
}
