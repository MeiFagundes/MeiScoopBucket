#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

Describe 'mVolt+ profile guard' {
    BeforeAll {
        $script:Guard = Join-Path $PSScriptRoot '..\scripts\mvoltplus-profile-guard.ps1'
        $script:PowerShell = (Get-Process -Id $PID).Path
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mvolt-guard-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:ProtectedId = '11111111-1111-4111-8111-111111111111'
        function New-ProfileFixture([string] $Path, [string[]] $Ids, [int] $Revision = 1) {
            $profiles = @($Ids | ForEach-Object { [pscustomobject]@{ id=$_; name="Profile $_" } })
            $document = [pscustomobject]@{
                schema='mvolt.profile.v3'; revision=$Revision; vbios_id='test-vbios'
                gpu_name='Test GPU'; adapter_id='test-adapter'
                startup_profile_id=''; profiles=$profiles
            }
            $parent = Split-Path -Parent $Path
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            $document | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
            Set-Content -LiteralPath ($Path + '.bak') -Value 'previous backup bytes' -Encoding UTF8
        }
        function Invoke-Guard([string] $Mode, [string] $Source, [string] $Backup, [string] $Extra = '', [switch] $Generic) {
            $nativeArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:Guard,'-Mode',$Mode,'-SourceDirectory',$Source,'-BackupDirectory',$Backup,'-ExecutablePath',($script:PowerShell+'|'+$script:PowerShell))
            if (!$Generic) { $nativeArgs += @('-ExpectedProfileId',$script:ProtectedId) }
            if ($Extra) { $nativeArgs += $Extra.Split(' ') }
            $arguments = ($nativeArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
            $stdout = Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N') + '.stdout')
            $stderr = Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N') + '.stderr')
            $process = Start-Process -FilePath $script:PowerShell -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            $output = [System.IO.File]::ReadAllText($stdout) + [System.IO.File]::ReadAllText($stderr)
            [pscustomobject]@{ ExitCode=$process.ExitCode; Output=$output }
        }
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) { Remove-Item -LiteralPath $script:TempRoot -Recurse -Force }
    }

    It 'deduplicates unchanged primary documents and keeps the adjacent backup bytes' {
        $source = Join-Path $script:TempRoot 'unchanged'
        $profile = Join-Path $source 'profiles\gpu.json'
        $backup = Join-Path $script:TempRoot 'backups-unchanged'
        New-ProfileFixture $profile @($script:ProtectedId)
        $first = Invoke-Guard Backup $source $backup
        $second = Invoke-Guard Backup $source $backup
        $first.ExitCode | Should -Be 0
        $second.ExitCode | Should -Be 0
        @(Get-ChildItem (Join-Path $backup 'snapshots') -Directory -Recurse | Where-Object { Test-Path (Join-Path $_.FullName 'metadata.json') }).Count | Should -Be 1
        (Get-ChildItem (Join-Path $backup 'snapshots') -Filter 'gpu.json.bak' -Recurse | Select-Object -First 1 | Get-Content -Raw) | Should -Match 'previous backup bytes'
    }

    It 'allows a fresh install when the profile directory is missing' {
        $result = Invoke-Guard Backup (Join-Path $script:TempRoot 'missing') (Join-Path $script:TempRoot 'backups-missing')
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'fresh install'
    }

    It 'rejects malformed JSON without creating a valid snapshot' {
        $source = Join-Path $script:TempRoot 'malformed'
        $profile = Join-Path $source 'profiles\gpu.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $profile) -Force | Out-Null
        Set-Content -LiteralPath $profile -Value '{not json'
        $result = Invoke-Guard Backup $source (Join-Path $script:TempRoot 'backups-malformed')
        $result.ExitCode | Should -Not -Be 0
    }

    It 'rejects empty profile documents for backup and records them as incidents in health mode' {
        $source = Join-Path $script:TempRoot 'empty'
        $profile = Join-Path $source 'profiles\gpu.json'
        $backup = Join-Path $script:TempRoot 'backups-empty'
        New-ProfileFixture $profile @()
        $backupResult = Invoke-Guard Backup $source $backup
        $backupResult.ExitCode | Should -Not -Be 0
        $healthResult = Invoke-Guard HealthCheck $source $backup
        $healthResult.ExitCode | Should -Be 2
        @(Get-ChildItem (Join-Path $backup 'incidents') -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'metadata.json') }).Count | Should -Be 1
        (Get-Content (Join-Path $backup 'health.log') -Raw) | Should -Match $script:ProtectedId
        $healthResult.Output | Should -Match 'Profile hashes:'
        $healthResult.Output | Should -Match ([regex]::Escape($script:PowerShell))
    }

    It 'retains healthy scheduled snapshots and preserves missing-profile incidents separately' {
        $source = Join-Path $script:TempRoot 'healthy-retention'
        $profile = Join-Path $source 'profiles\gpu.json'
        $backup = Join-Path $script:TempRoot 'backups-healthy-retention'
        foreach ($revision in 1..3) {
            New-ProfileFixture $profile @($script:ProtectedId) $revision
            (Invoke-Guard HealthCheck $source $backup -Extra '-KeepSnapshots 1').ExitCode | Should -Be 0
        }
        $snapshots = @(Get-ChildItem (Join-Path $backup 'snapshots') -Filter metadata.json -Recurse)
        $snapshots.Count | Should -Be 1
        (Get-Content $snapshots[0].FullName -Raw | ConvertFrom-Json).revision | Should -Be 3
        Test-Path (Join-Path $backup 'incidents') | Should -BeFalse

        New-ProfileFixture $profile @('22222222-2222-4222-8222-222222222222') 4
        (Invoke-Guard HealthCheck $source $backup -Extra '-KeepSnapshots 1').ExitCode | Should -Be 2
        @(Get-ChildItem (Join-Path $backup 'incidents') -Filter metadata.json -Recurse).Count | Should -Be 1
        @(Get-ChildItem (Join-Path $backup 'snapshots') -Filter metadata.json -Recurse).Count | Should -Be 1
    }

    It 'checks nonempty profiles without requiring a user-specific profile ID' {
        $source = Join-Path $script:TempRoot 'generic'
        $profile = Join-Path $source 'profiles\gpu.json'
        $backup = Join-Path $script:TempRoot 'backups-generic'
        New-ProfileFixture $profile @('22222222-2222-4222-8222-222222222222')
        (Invoke-Guard HealthCheck $source $backup -Generic).ExitCode | Should -Be 0
        $metadataPath = Get-ChildItem (Join-Path $backup 'snapshots') -Filter metadata.json -Recurse | Select-Object -First 1
        $metadata = Get-Content $metadataPath.FullName -Raw | ConvertFrom-Json
        $metadata.protected_profile_id | Should -BeNullOrEmpty
        $metadata.protected_baseline | Should -BeFalse
    }

    It 'resolves the actual bucket alias from Scoop context without optional environment variables' {
        $oldLocal = $env:LOCALAPPDATA
        $oldScoop = $env:SCOOP
        $oldScoopHome = $env:SCOOP_HOME
        $manifest = Get-Content (Join-Path $PSScriptRoot '..\bucket\mvoltplus.json') -Raw | ConvertFrom-Json
        try {
            $env:SCOOP = $null
            $env:SCOOP_HOME = $null
            foreach ($caseName in @('selected-alias','install-metadata')) {
                $caseRoot = Join-Path $script:TempRoot $caseName
                $scoopdir = Join-Path $caseRoot 'scoop'
                $aliasName = 'arbitrary-alias'
                $guardDirectory = Join-Path $scoopdir ('buckets\' + $aliasName + '\scripts')
                New-Item -ItemType Directory -Path $guardDirectory -Force | Out-Null
                Copy-Item -LiteralPath $script:Guard -Destination (Join-Path $guardDirectory 'mvoltplus-profile-guard.ps1')
                $env:LOCALAPPDATA = Join-Path $caseRoot 'local'
                New-ProfileFixture (Join-Path $env:LOCALAPPDATA 'mVolt+\profiles\gpu.json') @($script:ProtectedId)
                $bucket = $aliasName
                if ($caseName -eq 'install-metadata') {
                    $bucket = ''
                    $installInfo = Join-Path $scoopdir 'apps\mvoltplus\current\scoop-install.json'
                    New-Item -ItemType Directory -Path (Split-Path -Parent $installInfo) -Force | Out-Null
                    @{bucket=$aliasName} | ConvertTo-Json | Set-Content -LiteralPath $installInfo -Encoding UTF8
                }
                & ([scriptblock]::Create(($manifest.pre_install -join "`r`n"))) | Out-Null
                $metadataFiles = @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'mVoltPlus-ProfileBackups\snapshots') -Filter metadata.json -Recurse)
                $metadataFiles.Count | Should -Be 1
            }
        } finally {
            $env:LOCALAPPDATA = $oldLocal
            $env:SCOOP = $oldScoop
            $env:SCOOP_HOME = $oldScoopHome
        }
    }

    It 'retries and snapshots the latest bytes when a profile changes during a read' {
        $source = Join-Path $script:TempRoot 'changing'
        $profile = Join-Path $source 'profiles\gpu.json'
        $backup = Join-Path $script:TempRoot 'backups-changing'
        New-ProfileFixture $profile @($script:ProtectedId)
        $marker = Join-Path $script:TempRoot 'change-lock-ready'
        $job = Start-Job -ArgumentList $profile,$marker,$script:ProtectedId -ScriptBlock {
            param($Path,$Marker,$Id)
            $handle = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            [System.IO.File]::WriteAllText($Marker, 'ready')
            Start-Sleep -Milliseconds 300
            $handle.Dispose()
            Start-Sleep -Milliseconds 50
            $document = [pscustomobject]@{ schema='mvolt.profile.v3'; revision=2; vbios_id='test-vbios'; gpu_name='Test GPU'; adapter_id='test-adapter'; profiles=@([pscustomobject]@{id=$Id;name='Changed profile'}) }
            [System.IO.File]::WriteAllText($Path, ($document | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
        }
        $limit = (Get-Date).AddSeconds(10)
        while (!(Test-Path -LiteralPath $marker) -and (Get-Date) -lt $limit) { Start-Sleep -Milliseconds 25 }
        try { $result = Invoke-Guard Backup $source $backup }
        finally { Wait-Job $job | Out-Null; Remove-Job $job }
        $result.ExitCode | Should -Be 0
        $snapshot = Get-ChildItem (Join-Path $backup 'snapshots') -Filter 'gpu.json' -Recurse | Select-Object -First 1
        (Get-Content $snapshot.FullName -Raw | ConvertFrom-Json).revision | Should -Be 2
    }

    It 'fails clearly when the snapshot destination cannot be written' {
        $source = Join-Path $script:TempRoot 'failure'
        $profile = Join-Path $source 'profiles\gpu.json'
        $blocked = Join-Path $script:TempRoot 'not-a-directory'
        New-ProfileFixture $profile @($script:ProtectedId)
        Set-Content -LiteralPath $blocked -Value 'file blocks directory creation'
        $result = Invoke-Guard Backup $source $blocked
        $result.ExitCode | Should -Not -Be 0
    }

    It 'retains an older protected recovery baseline outside the newest snapshot window' {
        $source = Join-Path $script:TempRoot 'retention'
        $profile = Join-Path $source 'profiles\gpu.json'
        $backup = Join-Path $script:TempRoot 'backups-retention'
        New-ProfileFixture $profile @($script:ProtectedId) 1
        (Invoke-Guard Backup $source $backup -Extra '-KeepSnapshots 1').ExitCode | Should -Be 0
        New-ProfileFixture $profile @('22222222-2222-4222-8222-222222222222') 2
        (Invoke-Guard Backup $source $backup -Extra '-KeepSnapshots 1').ExitCode | Should -Be 0
        $metadata = @(Get-ChildItem (Join-Path $backup 'snapshots') -Filter metadata.json -Recurse | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
        @($metadata | Where-Object { $_.profile_ids -contains $script:ProtectedId }).Count | Should -Be 1
        $metadata.Count | Should -Be 2
    }
}
