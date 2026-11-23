<#
    .Synopsis
        Synthetic tests for the warning stream of Get-Quser (issue #11).

    .Description
        No real host, network, or quser.exe is used. `Get-Command` and `Invoke-Expression` are
        mocked, so the tests run on any platform. Hosts named 'bad*' fail with an RPC error and
        exit code 1; every other host returns one synthetic logged-on user.
#>
[IO.DirectoryInfo] $projectRoot = Split-Path -Parent (Split-Path -Parent ([string] (Resolve-Path -Path $MyInvocation.MyCommand.Path)))
foreach ($file in @(
    (Join-Path $projectRoot 'QuserObject/Private/Invoke-Quser.ps1'),
    (Join-Path $projectRoot 'QuserObject/Private/Get-QuserIdleTime.ps1'),
    (Join-Path $projectRoot 'QuserObject/Private/ConvertTo-QuserObject.ps1'),
    (Join-Path $projectRoot 'QuserObject/Public/Get-Quser.ps1')
)) {
    . $file
}

Describe 'Get-Quser warning stream' {
    Mock Get-Command -ParameterFilter { $Name -eq 'quser.exe' } {
        [pscustomobject] @{ Path = 'C:\Synthetic\quser.exe' }
    }

    $priorExitCode = $global:LASTEXITCODE

    Mock Invoke-Expression {
        if ($Command -like '*bad*') {
            $global:LASTEXITCODE = 1
            return 'ERROR 1722: The RPC server is unavailable'
        }
        $global:LASTEXITCODE = 0
        return @(
            ' USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME',
            ' alice                 console             1  Active      none   1/1/2026 8:00 AM'
        )
    }

    $warningMessage = ' badhost: ERROR 1722: The RPC server is unavailable'

    Context 'direct call' {
        It 'records the warning in -WarningVariable' {
            $null = Get-Quser -Server 'badhost' -WarningVariable wv 3>$null
            @($wv).Count | Should Be 1
            $wv[0].Message | Should Be $warningMessage
        }

        It 'records the warning in -WarningVariable even with -WarningAction SilentlyContinue' {
            $null = Get-Quser -Server 'badhost' -WarningAction 'SilentlyContinue' -WarningVariable wv
            @($wv).Count | Should Be 1
            $wv[0].Message | Should Be $warningMessage
        }

        It 'shows nothing on the warning stream with -WarningAction SilentlyContinue' {
            $stream = Get-Quser -Server 'badhost' -WarningAction 'SilentlyContinue' 3>&1
            @($stream | Where-Object { $_ -is [Management.Automation.WarningRecord] }).Count | Should Be 0
        }

        It 'still writes the warning to the warning stream by default' {
            $stream = Get-Quser -Server 'badhost' 3>&1
            $records = @($stream | Where-Object { $_ -is [Management.Automation.WarningRecord] })
            $records.Count | Should Be 1
            $records[0].Message | Should Be $warningMessage
        }

        It 'honors -WarningAction Stop' {
            { Get-Quser -Server 'badhost' -WarningAction 'Stop' } | Should Throw 'RPC server is unavailable'
        }

        It 'records one warning per failing host for a multi-server call' {
            $result = Get-Quser -Server 'badhost', 'goodhost', 'bad2' -WarningAction 'SilentlyContinue' -WarningVariable wv
            @($wv).Count | Should Be 2
            @($result | Where-Object { $_ }).Count | Should Be 1
            @($result | Where-Object { $_ })[0].Server | Should Be 'goodhost'
        }

        It 'records no warning for a reachable host' {
            $null = Get-Quser -Server 'goodhost' -WarningVariable wv 3>$null
            @($wv).Count | Should Be 0
        }

        It 'works through the Get-LoggedOnUsers alias' {
            $null = Get-LoggedOnUsers -Server 'badhost' -WarningVariable wv 3>$null
            @($wv).Count | Should Be 1
        }
    }

    Context 'pipeline call' {
        It 'records one warning per failing host and keeps the good result' {
            $result = 'badhost', 'goodhost', 'bad2' | Get-Quser -WarningAction 'SilentlyContinue' -WarningVariable wv
            @($wv).Count | Should Be 2
            @($wv | ForEach-Object { $_.Message }) -contains ' bad2: ERROR 1722: The RPC server is unavailable' | Should Be $true
            @($result | Where-Object { $_ }).Count | Should Be 1
            @($result | Where-Object { $_ })[0].Server | Should Be 'goodhost'
        }

        It 'records the warning for AdComputer-style objects using -Property' {
            $computers = @(
                [pscustomobject] @{ Name = 'x'; DNSHostName = 'badhost.example.invalid' },
                [pscustomobject] @{ Name = 'y'; DNSHostName = 'goodhost.example.invalid' }
            )
            $result = $computers | Get-Quser -Property 'DNSHostName' -WarningAction 'SilentlyContinue' -WarningVariable wv
            @($wv).Count | Should Be 1
            $wv[0].Message | Should Be ' badhost.example.invalid: ERROR 1722: The RPC server is unavailable'
            @($result | Where-Object { $_ }).Count | Should Be 1
        }
    }

    Context 'imported module scope' {
        # The caller in the bug report used the imported module, not dot-sourced functions.
        $moduleRoot = $projectRoot.FullName
        New-Module -Name 'QuserObjectWarningTest' -ScriptBlock {
            param($root)
            foreach ($file in 'Private/Invoke-Quser.ps1', 'Private/Get-QuserIdleTime.ps1',
                              'Private/ConvertTo-QuserObject.ps1', 'Public/Get-Quser.ps1') {
                . (Join-Path $root "QuserObject/$file")
            }
            Export-ModuleMember -Function 'Get-Quser' -Alias '*'
        } -ArgumentList $moduleRoot | Import-Module -Force

        Mock -ModuleName 'QuserObjectWarningTest' Get-Command -ParameterFilter { $Name -eq 'quser.exe' } {
            [pscustomobject] @{ Path = 'C:\Synthetic\quser.exe' }
        }
        Mock -ModuleName 'QuserObjectWarningTest' Invoke-Expression {
            if ($Command -like '*bad*') { $global:LASTEXITCODE = 1; return 'ERROR 1722: The RPC server is unavailable' }
            $global:LASTEXITCODE = 0
            return @(
                ' USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME',
                ' alice                 console             1  Active      none   1/1/2026 8:00 AM'
            )
        }

        It 'records the warning in -WarningVariable for the imported command' {
            $result = QuserObjectWarningTest\Get-Quser -Server 'badhost', 'goodhost' -WarningAction 'SilentlyContinue' -WarningVariable wv
            @($wv).Count | Should Be 1
            $wv[0].Message | Should Be $warningMessage
            @($result | Where-Object { $_ })[0].Server | Should Be 'goodhost'
        }

        Remove-Module -Name 'QuserObjectWarningTest' -Force -ErrorAction SilentlyContinue
    }

    Context 'output is unchanged' {
        It 'returns the parsed session for a reachable host' {
            $result = @(Get-Quser -Server 'goodhost')
            $result.Count | Should Be 1
            $result[0].UserName | Should Be 'alice'
            $result[0].Server | Should Be 'goodhost'
            $result[0].Id | Should Be 1
            $result[0].State | Should Be 'Active'
        }

        It 'returns no session object for a failing host' {
            $result = @(Get-Quser -Server 'badhost' 3>$null | Where-Object { $_ })
            $result.Count | Should Be 0
        }

        It 'returns the same sessions for the pipeline and the direct call' {
            $direct = @(Get-Quser -Server 'goodhost')
            $piped = @('goodhost' | Get-Quser)
            $piped.Count | Should Be $direct.Count
            $piped[0].UserName | Should Be $direct[0].UserName
        }
    }

    AfterAll {
        if ($null -eq $priorExitCode) { Remove-Variable -Scope 'Global' -Name 'LASTEXITCODE' -ErrorAction SilentlyContinue }
        else { $global:LASTEXITCODE = $priorExitCode }
    }
}
