#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

Describe 'mVolt+ profile guard' {
    BeforeAll {
        $script:Guard = Join-Path $PSScriptRoot '..\scripts\mvoltplus-profile-guard.ps1'
        $script:PowerShell = (Get-Process -Id $PID).Path
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mvolt-guard-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:ProtectedId = '11111111-1111-4111-8111-111111111111'
        function New-ProfileFixture([string] $Path, [string[]] $Ids, [int] $Revision = 1, [string] $Adapter = 'test-adapter') {
            $profiles = @($Ids | ForEach-Object { [pscustomobject]@{ id=$_; name="Profile $_" } })
            $document = [pscustomobject]@{
                schema='mvolt.profile.v3'; revision=$Revision; vbios_id='test-vbios'
                gpu_name='Test GPU'; adapter_id=$Adapter
                startup_profile_id=''; profiles=$profiles
            }
            $parent = Split-Path -Parent $Path
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            $document | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
            Set-Content -LiteralPath ($Path + '.bak') -Value 'previous backup bytes' -Encoding UTF8
        }
        function Invoke-Guard([string] $Mode, [string] $Source, [string] $Backup, [string] $Extra = '', [switch] $Generic, [switch] $Async, [string] $ExpectedId = $script:ProtectedId) {
            $nativeArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:Guard,'-Mode',$Mode,'-SourceDirectory',$Source,'-BackupDirectory',$Backup,'-ExecutablePath',($script:PowerShell+'|'+$script:PowerShell))
            if (!$Generic) { $nativeArgs += @('-ExpectedProfileId',$ExpectedId) }
            if ($Extra) { $nativeArgs += $Extra.Split(' ') }
            $arguments = ($nativeArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
            $stdout = Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N') + '.stdout')
            $stderr = Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N') + '.stderr')
            $process = Start-Process -FilePath $script:PowerShell -ArgumentList $arguments -WindowStyle Hidden -Wait:(!$Async) -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            if ($Async) { $null = $process.Handle; return [pscustomobject]@{ Process=$process; Stdout=$stdout; Stderr=$stderr } }
            $output = [System.IO.File]::ReadAllText($stdout) + [System.IO.File]::ReadAllText($stderr)
            [pscustomobject]@{ ExitCode=$process.ExitCode; Output=$output }
        }
    }

    AfterAll {
        $resolved = [IO.Path]::GetFullPath($script:TempRoot)
        $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
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

    It 'preserves malformed JSON bytes without blocking installation' {
        $source = Join-Path $script:TempRoot 'malformed'
        $profile = Join-Path $source 'profiles\gpu.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $profile) -Force | Out-Null
        Set-Content -LiteralPath $profile -Value '{not json'
        $backup = Join-Path $script:TempRoot 'backups-malformed'
        $result = Invoke-Guard Backup $source $backup
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'warnings'
        $saved = Get-ChildItem (Join-Path $backup 'incidents') -Filter gpu.json -Recurse | Select-Object -First 1
        (Get-FileHash $saved.FullName).Hash | Should -Be (Get-FileHash $profile).Hash
    }

    It 'preserves empty profile documents while warning health checks' {
        $source = Join-Path $script:TempRoot 'empty'
        $profile = Join-Path $source 'profiles\gpu.json'
        $backup = Join-Path $script:TempRoot 'backups-empty'
        New-ProfileFixture $profile @()
        $backupResult = Invoke-Guard Backup $source $backup
        $backupResult.ExitCode | Should -Be 0
        $healthResult = Invoke-Guard HealthCheck $source $backup
        $healthResult.ExitCode | Should -Be 2
        @(Get-ChildItem (Join-Path $backup 'incidents') -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'metadata.json') }).Count | Should -Be 1
        (Get-Content (Join-Path $backup 'health.log') -Raw) | Should -Match $script:ProtectedId
        $healthResult.Output | Should -Match 'Profile hashes:'
        $healthResult.Output | Should -Match ([regex]::Escape($script:PowerShell))
    }

    It 'retains valid snapshots and warns when the expected profile disappears' {
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
        Test-Path (Join-Path $backup 'incidents') | Should -BeFalse
        @(Get-ChildItem (Join-Path $backup 'snapshots') -Filter metadata.json -Recurse).Count | Should -Be 2
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

    It 'warns on an unwritable destination and supports strict backup failure' {
        $source = Join-Path $script:TempRoot 'failure'
        $profile = Join-Path $source 'profiles\gpu.json'
        $blocked = Join-Path $script:TempRoot 'not-a-directory'
        New-ProfileFixture $profile @($script:ProtectedId)
        Set-Content -LiteralPath $blocked -Value 'file blocks directory creation'
        $result = Invoke-Guard Backup $source $blocked
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'WARNING'
        (Invoke-Guard Backup $source $blocked -Extra '-Strict').ExitCode | Should -Be 1
        (Invoke-Guard HealthCheck $source $blocked).ExitCode | Should -Be 2
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

    It 'repairs missing or altered snapshot payloads instead of trusting metadata' {
        foreach ($damage in @('missing-primary','altered-primary','missing-backup')) {
            $source = Join-Path $script:TempRoot ('repair-' + $damage)
            $profile = Join-Path $source 'profiles\gpu.json'
            $backup = Join-Path $script:TempRoot ('backups-repair-' + $damage)
            New-ProfileFixture $profile @($script:ProtectedId)
            (Invoke-Guard Backup $source $backup).ExitCode | Should -Be 0
            $metadata = Get-ChildItem (Join-Path $backup 'snapshots') -Filter metadata.json -Recurse | Select-Object -First 1
            $saved = Join-Path $metadata.DirectoryName 'gpu.json'
            switch ($damage) {
                'missing-primary' { Remove-Item -LiteralPath $saved }
                'altered-primary' { Set-Content -LiteralPath $saved -Value '{broken}' }
                'missing-backup' { Remove-Item -LiteralPath ($saved + '.bak') }
            }
            (Invoke-Guard Backup $source $backup).ExitCode | Should -Be 0
            $good = @(Get-ChildItem (Join-Path $backup 'snapshots') -Filter gpu.json -Recurse | Where-Object {
                (Get-FileHash $_.FullName).Hash -eq (Get-FileHash $profile).Hash -and
                (Test-Path -LiteralPath ($_.FullName + '.bak')) -and
                (Get-FileHash ($_.FullName + '.bak')).Hash -eq (Get-FileHash ($profile + '.bak')).Hash
            })
            $good.Count | Should -BeGreaterThan 0
        }
    }

    It 'rejects zero and negative retention before writing any snapshots' {
        $source = Join-Path $script:TempRoot 'invalid-retention'
        New-ProfileFixture (Join-Path $source 'profiles\gpu.json') @($script:ProtectedId)
        foreach ($count in @(0,-1)) {
            $backup = Join-Path $script:TempRoot ('backups-invalid-retention-' + $count)
            (Invoke-Guard Backup $source $backup -Extra ("-KeepSnapshots $count")).ExitCode | Should -Not -Be 0
            Test-Path -LiteralPath $backup | Should -BeFalse
        }
    }

    It 'promotes deduplicated generic snapshots and honors protection in later generic runs' {
        $source = Join-Path $script:TempRoot 'promote'
        $profile = Join-Path $source 'profiles\gpu.json'
        $backup = Join-Path $script:TempRoot 'backups-promote'
        New-ProfileFixture $profile @($script:ProtectedId)
        (Invoke-Guard Backup $source $backup -Generic).ExitCode | Should -Be 0
        (Invoke-Guard Backup $source $backup).ExitCode | Should -Be 0
        $metadataFile = Get-ChildItem (Join-Path $backup 'snapshots') -Filter metadata.json -Recurse | Select-Object -First 1
        (Get-Content $metadataFile.FullName -Raw | ConvertFrom-Json).protected_profile_ids | Should -Contain $script:ProtectedId
        New-ProfileFixture $profile @('22222222-2222-4222-8222-222222222222') 2
        (Invoke-Guard Backup $source $backup -Generic -Extra '-KeepSnapshots 1').ExitCode | Should -Be 0
        Test-Path -LiteralPath $metadataFile.FullName | Should -BeTrue
    }

    It 'keeps a recovery baseline for each explicitly protected profile' {
        $source = Join-Path $script:TempRoot 'multiple-protections'
        $profile = Join-Path $source 'profiles\gpu.json'
        $backup = Join-Path $script:TempRoot 'backups-multiple-protections'
        $secondId = '22222222-2222-4222-8222-222222222222'
        New-ProfileFixture $profile @($script:ProtectedId)
        (Invoke-Guard Backup $source $backup).ExitCode | Should -Be 0
        New-ProfileFixture $profile @($secondId) 2
        (Invoke-Guard Backup $source $backup -ExpectedId $secondId).ExitCode | Should -Be 0
        New-ProfileFixture $profile @('33333333-3333-4333-8333-333333333333') 3
        (Invoke-Guard Backup $source $backup -Extra '-KeepSnapshots 1').ExitCode | Should -Be 0
        $metadata = @(Get-ChildItem (Join-Path $backup 'snapshots') -Filter metadata.json -Recurse | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
        @($metadata | Where-Object { $_.profile_ids -contains $script:ProtectedId }).Count | Should -Be 1
        @($metadata | Where-Object { $_.profile_ids -contains $secondId }).Count | Should -Be 1
        $metadata.Count | Should -Be 3
    }

    It 'honors protection in legacy snapshot metadata' {
        $source = Join-Path $script:TempRoot 'legacy'
        $profile = Join-Path $source 'profiles\gpu.json'
        $backup = Join-Path $script:TempRoot 'backups-legacy'
        New-ProfileFixture $profile @($script:ProtectedId)
        (Invoke-Guard Backup $source $backup).ExitCode | Should -Be 0
        $metadataFile = Get-ChildItem (Join-Path $backup 'snapshots') -Filter metadata.json -Recurse | Select-Object -First 1
        $metadata = Get-Content $metadataFile.FullName -Raw | ConvertFrom-Json
        foreach ($property in @('format_version','protected_profile_ids','protected_baseline','last_seen_utc')) { $metadata.PSObject.Properties.Remove($property) }
        $metadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metadataFile.FullName -Encoding UTF8
        New-ProfileFixture $profile @('22222222-2222-4222-8222-222222222222') 2
        (Invoke-Guard Backup $source $backup -Generic -Extra '-KeepSnapshots 1').ExitCode | Should -Be 0
        Test-Path -LiteralPath $metadataFile.FullName | Should -BeTrue
    }

    It 'does not report healthy when one document is corrupt' {
        $source = Join-Path $script:TempRoot 'mixed'
        $backup = Join-Path $script:TempRoot 'backups-mixed'
        New-ProfileFixture (Join-Path $source 'profiles\good.json') @($script:ProtectedId)
        $corrupt = Join-Path $source 'profiles\broken.json'
        Set-Content -LiteralPath $corrupt -Value '{broken'
        $before = (Get-FileHash $corrupt).Hash
        $result = Invoke-Guard HealthCheck $source $backup
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Not -Match 'Health check OK'
        (Get-Content (Join-Path $backup 'health.log') -Raw) | Should -Not -Match 'Health check OK'
        $saved = Get-ChildItem (Join-Path $backup 'incidents') -Filter broken.json -Recurse | Select-Object -First 1
        (Get-FileHash $saved.FullName).Hash | Should -Be $before
        (Get-FileHash $corrupt).Hash | Should -Be $before
    }

    It 'checks multiple GPUs without requiring the expected profile on every GPU' {
        $source = Join-Path $script:TempRoot 'multiple-gpus'
        $backup = Join-Path $script:TempRoot 'backups-multiple-gpus'
        New-ProfileFixture (Join-Path $source 'profiles\first.json') @($script:ProtectedId)
        New-ProfileFixture (Join-Path $source 'profiles\second.json') @('22222222-2222-4222-8222-222222222222') 1 'second-adapter'
        (Invoke-Guard HealthCheck $source $backup).ExitCode | Should -Be 0
        @(Get-ChildItem (Join-Path $backup 'snapshots') -Filter metadata.json -Recurse).Count | Should -Be 2
        Test-Path (Join-Path $backup 'incidents') | Should -BeFalse
    }

    It 'preserves every current document when several files describe the same GPU' {
        $source = Join-Path $script:TempRoot 'multiple-current-files'
        $backup = Join-Path $script:TempRoot 'backups-multiple-current-files'
        foreach ($name in @('first.json','second.json')) {
            New-ProfileFixture (Join-Path $source ('profiles\' + $name)) @($script:ProtectedId)
        }
        (Invoke-Guard Backup $source $backup -Generic -Extra '-KeepSnapshots 1').ExitCode | Should -Be 0
        foreach ($name in @('first.json','second.json')) {
            $saved = @(Get-ChildItem (Join-Path $backup 'snapshots') -Filter $name -Recurse)
            $saved.Count | Should -Be 1
            (Get-FileHash $saved[0].FullName).Hash | Should -Be (Get-FileHash (Join-Path $source ('profiles\' + $name))).Hash
        }
    }

    It 'preserves orphan backup files and unfamiliar documents as original bytes' {
        foreach ($caseName in @('orphan','unfamiliar')) {
            $source = Join-Path $script:TempRoot $caseName
            $profile = Join-Path $source 'profiles\gpu.json'
            $backup = Join-Path $script:TempRoot ('backups-' + $caseName)
            New-ProfileFixture $profile @($script:ProtectedId)
            if ($caseName -eq 'orphan') { Remove-Item -LiteralPath $profile; $profile += '.bak' }
            else { Set-Content -LiteralPath $profile -Value '{"schema":"future.format","content":"preserve me"}' -Encoding UTF8 }
            $before = (Get-FileHash $profile).Hash
            (Invoke-Guard Backup $source $backup -Extra '-Strict').ExitCode | Should -Be 0
            $saved = Get-ChildItem (Join-Path $backup 'incidents') -Filter (Split-Path -Leaf $profile) -Recurse | Select-Object -First 1
            (Get-FileHash $saved.FullName).Hash | Should -Be $before
        }
    }

    It 'supports paths containing spaces, brackets, and non-ASCII characters' {
        $source = Join-Path $script:TempRoot ('profile folder [test] ' + [char]0x00e9)
        $profile = Join-Path $source 'profiles\gpu.json'
        $backup = Join-Path $script:TempRoot 'backup folder [test]'
        New-ProfileFixture $profile @($script:ProtectedId)
        (Invoke-Guard Backup $source $backup).ExitCode | Should -Be 0
        $saved = Get-ChildItem -LiteralPath (Join-Path $backup 'snapshots') -Filter gpu.json -Recurse | Select-Object -First 1
        (Get-FileHash -LiteralPath $saved.FullName).Hash | Should -Be (Get-FileHash -LiteralPath $profile).Hash
    }

    It 'preserves empty files, undecodable bytes, and future schemas without rewriting them' {
        foreach ($caseName in @('empty-file','invalid-utf8','future-schema')) {
            $source = Join-Path $script:TempRoot $caseName
            $profile = Join-Path $source 'profiles\gpu.json'
            $backup = Join-Path $script:TempRoot ('backups-' + $caseName)
            New-ProfileFixture $profile @($script:ProtectedId)
            if ($caseName -eq 'empty-file') { [IO.File]::WriteAllBytes($profile, [byte[]]@()) }
            elseif ($caseName -eq 'invalid-utf8') { [IO.File]::WriteAllBytes($profile, [byte[]]@(255,254,255)) }
            else {
                $document = Get-Content $profile -Raw | ConvertFrom-Json
                $document.schema = 'mvolt.profile.v999'
                $document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $profile -Encoding UTF8
            }
            $hash = (Get-FileHash $profile).Hash
            (Invoke-Guard Backup $source $backup -Extra '-Strict').ExitCode | Should -Be 0
            $saved = Get-ChildItem -LiteralPath $backup -Filter gpu.json -Recurse | Select-Object -First 1
            (Get-FileHash $saved.FullName).Hash | Should -Be $hash
            (Get-FileHash $profile).Hash | Should -Be $hash
        }
    }

    It 'does not fail a valid backup because diagnostic logging is unavailable' {
        $source = Join-Path $script:TempRoot 'blocked-log'
        $profile = Join-Path $source 'profiles\gpu.json'
        $backup = Join-Path $script:TempRoot 'backups-blocked-log'
        New-ProfileFixture $profile @($script:ProtectedId)
        New-Item -ItemType Directory -Path (Join-Path $backup 'health.log') -Force | Out-Null
        (Invoke-Guard HealthCheck $source $backup).ExitCode | Should -Be 0
        @(Get-ChildItem (Join-Path $backup 'snapshots') -Filter metadata.json -Recurse).Count | Should -Be 1
    }

    It 'serializes concurrent backups and publishes only complete snapshots' {
        $source = Join-Path $script:TempRoot 'concurrent'
        $profile = Join-Path $source 'profiles\gpu.json'
        $backup = Join-Path $script:TempRoot 'backups-concurrent'
        New-ProfileFixture $profile @($script:ProtectedId)
        $first = Invoke-Guard Backup $source $backup -Async -Extra '-Strict'
        $second = Invoke-Guard Backup $source $backup -Async -Extra '-Strict'
        foreach ($run in @($first,$second)) { $run.Process.WaitForExit(); $run.Process.ExitCode | Should -Be 0 }
        @(Get-ChildItem (Join-Path $backup 'snapshots') -Filter metadata.json -Recurse).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $backup -Directory -Recurse -Force | Where-Object { $_.Name -like '.pending-*' }).Count | Should -Be 0
    }

    It 'preserves unrelated files and rejects overlapping source and destination paths' {
        $source = Join-Path $script:TempRoot 'unrelated'
        $profile = Join-Path $source 'profiles\gpu.json'
        $backup = Join-Path $script:TempRoot 'backups-unrelated'
        New-ProfileFixture $profile @($script:ProtectedId)
        (Invoke-Guard Backup $source $backup -Generic).ExitCode | Should -Be 0
        $metadataFile = Get-ChildItem (Join-Path $backup 'snapshots') -Filter metadata.json -Recurse | Select-Object -First 1
        $note = Join-Path $metadataFile.DirectoryName 'user-note.txt'
        Set-Content -LiteralPath $note -Value 'keep this file'
        New-ProfileFixture $profile @($script:ProtectedId) 2
        (Invoke-Guard Backup $source $backup -Generic -Extra '-KeepSnapshots 1').ExitCode | Should -Be 0
        Test-Path -LiteralPath $note | Should -BeTrue
        $overlap = Join-Path $source 'backups'
        (Invoke-Guard Backup $source $overlap -Extra '-Strict').ExitCode | Should -Be 1
        Test-Path -LiteralPath $overlap | Should -BeFalse
    }

    It 'logs missing-profile warnings without turning backup failures into installation failures' {
        $source = Join-Path $script:TempRoot 'missing-health'
        $backup = Join-Path $script:TempRoot 'backups-missing-health'
        (Invoke-Guard HealthCheck $source $backup).ExitCode | Should -Be 2
        (Get-Content (Join-Path $backup 'health.log') -Raw) | Should -Match 'No mVolt\+ profile documents'
    }

    It 'preserves drive roots when resolving physical paths' {
        $tokens=$null; $errors=$null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Guard, [ref]$tokens, [ref]$errors)
        $definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-PhysicalPath'}, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        $root = [IO.Path]::GetPathRoot($script:TempRoot)
        Resolve-PhysicalPath $root | Should -Be $root
    }

    It 'rejects overlap hidden by a junction without writing into the source' {
        $source = Join-Path $script:TempRoot 'junction-source'
        $profile = Join-Path $source 'profiles\gpu.json'
        New-ProfileFixture $profile @($script:ProtectedId)
        $before = (Get-FileHash $profile).Hash
        $junction = Join-Path $script:TempRoot 'junction-alias'
        New-Item -ItemType Junction -Path $junction -Target $source | Out-Null
        try {
            $result = Invoke-Guard Backup $source (Join-Path $junction 'backups') -Extra '-Strict'
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'overlapping'
            Test-Path -LiteralPath (Join-Path $source 'backups') | Should -BeFalse
            (Get-FileHash $profile).Hash | Should -Be $before
        } finally { [IO.Directory]::Delete($junction) }
    }

    It 'allows installation when the bucket helper cannot be resolved' {
        $oldLocal = $env:LOCALAPPDATA
        $oldScoop = $env:SCOOP
        try {
            $env:LOCALAPPDATA = Join-Path $script:TempRoot 'missing-hook-helper'
            New-ProfileFixture (Join-Path $env:LOCALAPPDATA 'mVolt+\profiles\gpu.json') @($script:ProtectedId)
            $scoopdir = Join-Path $script:TempRoot 'missing-helper-scoop'
            $env:SCOOP = $null
            $bucket = 'another-alias'
            $manifest = Get-Content (Join-Path $PSScriptRoot '..\bucket\mvoltplus.json') -Raw | ConvertFrom-Json
            { & ([scriptblock]::Create(($manifest.pre_install -join "`r`n"))) } | Should -Not -Throw
        } finally { $env:LOCALAPPDATA = $oldLocal; $env:SCOOP = $oldScoop }
    }

    It 'rejects unsupported architectures before installing the x64 executable' {
        $manifest = Get-Content (Join-Path $PSScriptRoot '..\bucket\mvoltplus.json') -Raw | ConvertFrom-Json
        $tokens=$null; $errors=$null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $env:SCOOP_HOME 'lib\manifest.ps1'), [ref]$tokens, [ref]$errors)
        foreach ($name in @('arch_specific','Get-SupportedArchitecture')) {
            $definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        function ConvertToPrettyJson { param([Parameter(ValueFromPipeline)]$InputObject) process { $InputObject | ConvertTo-Json -Depth 30 } }
        foreach ($WindowsBuild in @(19045,26100)) {
            Get-SupportedArchitecture $manifest '64bit' | Should -Be '64bit'
            Get-SupportedArchitecture $manifest '32bit' | Should -BeNullOrEmpty
            Get-SupportedArchitecture $manifest 'arm64' | Should -BeNullOrEmpty
        }
    }
}
