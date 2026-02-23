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
                $text | Should -Not -Match "BAD KEY="
                $text | Should -Not -Match "BAD=KEY="
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

            It 'Outputs dotenv text when -AsDotEnv is used' {
                $text = Get-VsDevEnv -VsInstallPath 'C:\VS' -AsDotEnv

                $text | Should -BeOfType [string]
                $text | Should -Match '(?m)^FOO="after"\r?$'
                $text | Should -Match '(?m)^REMOVED=""\r?$'
                $text | Should -Not -Match '(?m)^UNCHANGED='
            }

            It 'Writes a UTF-8 (no BOM) .env file when -DotEnvPath is used' {
                $path = Join-Path $TestDrive 'out/vs.env'
                $text = Get-VsDevEnv -VsInstallPath 'C:\VS' -DotEnvPath $path

                ([System.IO.File]::Exists($path)) | Should -BeTrue
                (Get-Content -Path $path -Raw) | Should -Be $text

                $bytes = [System.IO.File]::ReadAllBytes($path)
                if ($bytes.Length -ge 3) {
                    # Ensure there is no UTF-8 BOM (EF BB BF)
                    ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
                }
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

        Context 'Enter-VsDevShell (unit)' {
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
                    [System.Environment]::SetEnvironmentVariable('FOO', $oldFoo)
                    [System.Environment]::SetEnvironmentVariable('REMOVED', $oldRemoved)
                }
            }
        }
    }
}
