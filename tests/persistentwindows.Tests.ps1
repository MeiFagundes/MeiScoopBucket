#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

Describe 'PersistentWindows manifest' {
    BeforeAll {
        $script:ManifestPath = Join-Path $PSScriptRoot '..\bucket\persistentwindows.json'
        $script:ScoopHome = $env:SCOOP_HOME
        if (!$script:ScoopHome) { $script:ScoopHome = (Resolve-Path (scoop prefix scoop)).Path }
        . "$script:ScoopHome\lib\core.ps1"
        . "$script:ScoopHome\lib\json.ps1"
        . "$script:ScoopHome\lib\versions.ps1"
        . "$script:ScoopHome\lib\manifest.ps1"
        . "$script:ScoopHome\lib\autoupdate.ps1"

        $script:ExpectedHash = '0123456789abcdef' * 4
        $script:TempDirectories = @()

        function get_hash_for_app {
            param($AppName, $Config, $Version, $URL, $Substitutions)
            return $script:ExpectedHash
        }

        function Get-ManifestFixture {
            Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
        }

        function Invoke-FixtureUpdate([string] $Version) {
            $directory = Join-Path ([IO.Path]::GetTempPath()) ('persistentwindows-autoupdate-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $script:TempDirectories += $directory
            $path = Join-Path $directory 'persistentwindows.json'
            $manifest = Get-ManifestFixture
            $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding UTF8
            Invoke-AutoUpdate -AppName 'persistentwindows' -Path $path -Manifest $manifest -Version $Version -CustomMatches @{}
            $text = Get-Content -LiteralPath $path -Raw
            [pscustomobject]@{
                Directory = $directory
                Text      = $text
                Manifest  = $text | ConvertFrom-Json
            }
        }
    }

    AfterAll {
        foreach ($directory in $script:TempDirectories) {
            if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
        }
    }

    It 'uses the standard release archive instead of the strip or source archive' {
        $manifest = Get-ManifestFixture
        $url = $manifest.architecture.'64bit'.url
        $url | Should -Match '^https://github\.com/kangyu-california/PersistentWindows/releases/download/5\.77/PersistentWindows5\.77\.zip$'
        $url | Should -Not -Match 'Strip'
        $url | Should -Not -Match '/archive/'
    }

    It 'pins a full SHA-256 hash for the release archive' {
        $manifest = Get-ManifestFixture
        $manifest.architecture.'64bit'.hash | Should -Match '^[0-9a-f]{64}$'
    }

    It 'launches from a shortcut that disables the in-app upgrade check' {
        $manifest = Get-ManifestFixture
        @($manifest.shortcuts).Count | Should -Be 1
        $manifest.shortcuts[0][0] | Should -Be 'PersistentWindows.exe'
        $manifest.shortcuts[0][1] | Should -Be 'PersistentWindows'
        $manifest.shortcuts[0][2] | Should -Be '-check_upgrade=0'
        $manifest.PSObject.Properties.Name | Should -Not -Contain 'bin'
    }

    It 'does not manage windows state, startup tasks or registry overrides' {
        $manifest = Get-ManifestFixture
        foreach ($hook in @('pre_install', 'post_install', 'installer', 'uninstaller', 'persist')) {
            $manifest.PSObject.Properties.Name | Should -Not -Contain $hook
        }
        $raw = Get-Content -LiteralPath $script:ManifestPath -Raw
        $raw | Should -Not -Match 'portable_mode'
        $raw | Should -Not -Match 'auto_start'
        $raw | Should -Not -Match 'uninstall'
        $raw | Should -Not -Match 'schtasks'
        $raw | Should -Not -Match 'reg add'
    }

    It 'documents app data, updates, elevation and display scaling' {
        $manifest = Get-ManifestFixture
        $notes = $manifest.notes -join "`n"
        $notes | Should -Match 'LOCALAPPDATA%\\PersistentWindows'
        $notes | Should -Match 'scoop update persistentwindows'
        $notes | Should -Match 'administrator'
        $notes | Should -Match 'DPI'
    }

    It 'selects x64 and rejects 32-bit and ARM64' {
        $manifest = Get-ManifestFixture
        @($manifest.architecture.PSObject.Properties.Name) | Should -Be @('64bit')
        @($manifest.'##') | Should -Contain 'arm64'
        Get-SupportedArchitecture $manifest '64bit' | Should -Be '64bit'
        Get-SupportedArchitecture $manifest '32bit' | Should -BeNullOrEmpty
        Get-SupportedArchitecture $manifest 'arm64' | Should -BeNullOrEmpty
    }

    It 'rejects unsupported architectures on Windows 10 and 11 builds' {
        $manifest = Get-ManifestFixture
        foreach ($WindowsBuild in @(19045, 26100)) {
            Get-SupportedArchitecture $manifest 'arm64' | Should -BeNullOrEmpty
            Get-SupportedArchitecture $manifest '32bit' | Should -BeNullOrEmpty
        }
    }

    It 'updates the version, URL and hash for the standard archive' {
        $result = Invoke-FixtureUpdate '9.9.9'
        try {
            $manifest = $result.Manifest
            $manifest.version | Should -Be '9.9.9'
            $manifest.architecture.'64bit'.url | Should -Be 'https://github.com/kangyu-california/PersistentWindows/releases/download/9.9.9/PersistentWindows9.9.9.zip'
            $manifest.architecture.'64bit'.hash | Should -Be $script:ExpectedHash
        } finally {
            Remove-Item -LiteralPath $result.Directory -Recurse -Force
        }
    }

    It 'keeps the package contract and architecture guard after an update' {
        $result = Invoke-FixtureUpdate '9.9.9'
        try {
            $manifest = $result.Manifest
            @($manifest.architecture.PSObject.Properties.Name) | Should -Be @('64bit')
            @($manifest.'##') | Should -Contain 'arm64'
            @($manifest.autoupdate.architecture.PSObject.Properties.Name) | Should -Not -Contain 'arm64'
            Get-SupportedArchitecture $manifest 'arm64' | Should -BeNullOrEmpty
            $manifest.shortcuts[0][2] | Should -Be '-check_upgrade=0'
            $manifest.license | Should -Be 'GPL-3.0-only'
            @($manifest.notes).Count | Should -Be 6
            foreach ($hook in @('pre_install', 'post_install', 'installer', 'uninstaller', 'persist')) {
                $manifest.PSObject.Properties.Name | Should -Not -Contain $hook
            }
        } finally {
            Remove-Item -LiteralPath $result.Directory -Recurse -Force
        }
    }

    It 'generates a manifest without trailing whitespace' {
        $result = Invoke-FixtureUpdate '9.9.9'
        try {
            $badLines = @($result.Text -split "`r?`n" | Where-Object { $_ -match '^[ \t]+$' -or $_ -match '[ \t]+$' })
            $badLines.Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $result.Directory -Recurse -Force
        }
    }
}
