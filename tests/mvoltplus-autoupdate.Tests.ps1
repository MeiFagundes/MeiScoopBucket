#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

Describe 'mVolt+ autoupdate' {
    BeforeAll {
        $script:ManifestPath = Join-Path $PSScriptRoot '..\bucket\mvoltplus.json'
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
            $directory = Join-Path ([IO.Path]::GetTempPath()) ('mvolt-autoupdate-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $script:TempDirectories += $directory
            $path = Join-Path $directory 'mvoltplus.json'
            $manifest = Get-ManifestFixture
            $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding UTF8
            Invoke-AutoUpdate -AppName 'mvoltplus' -Path $path -Manifest $manifest -Version $Version -CustomMatches @{}
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

    It 'keeps the installed architecture x64-only while retaining the ARM marker' {
        $manifest = Get-ManifestFixture
        @($manifest.architecture.PSObject.Properties.Name) | Should -Be @('64bit')
        @($manifest.'##') | Should -Contain 'arm64'
        @($manifest.autoupdate.architecture.PSObject.Properties.Name) | Should -Not -Contain 'arm64'
    }

    It 'updates the version, URL and hash without traversing an empty ARM hash' {
        $result = Invoke-FixtureUpdate '9.9.9'
        try {
            $manifest = $result.Manifest
            $manifest.version | Should -Be '9.9.9'
            $manifest.architecture.'64bit'.url | Should -Be 'https://github.com/b00nz/mVolt/releases/download/v9.9.9/mVolt+.exe'
            $manifest.architecture.'64bit'.hash | Should -Be $script:ExpectedHash
            @($manifest.architecture.PSObject.Properties.Name) | Should -Be @('64bit')
            @($manifest.'##') | Should -Contain 'arm64'
            @($manifest.autoupdate.architecture.PSObject.Properties.Name) | Should -Not -Contain 'arm64'
            Get-SupportedArchitecture $manifest 'arm64' | Should -BeNullOrEmpty
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

    It 'preserves the profile guard hook and shortcuts after an update' {
        $result = Invoke-FixtureUpdate '9.9.9'
        try {
            $manifest = $result.Manifest
            ($manifest.pre_install -join "`n") | Should -Match 'mvoltplus-profile-guard\.ps1'
            @($manifest.bin).Count | Should -Be 1
            $manifest.bin[0][0] | Should -Be 'mVolt+.exe'
            $manifest.bin[0][1] | Should -Be 'mvoltplus'
            $manifest.shortcuts[0][0] | Should -Be 'mVolt+.exe'
            $manifest.shortcuts[0][1] | Should -Be 'mVolt+'
        } finally {
            Remove-Item -LiteralPath $result.Directory -Recurse -Force
        }
    }

    It 'continues to reject 32-bit and ARM64 on Windows 10 and 11' {
        $manifest = Get-ManifestFixture
        foreach ($WindowsBuild in @(19045, 26100)) {
            Get-SupportedArchitecture $manifest '64bit' | Should -Be '64bit'
            Get-SupportedArchitecture $manifest '32bit' | Should -BeNullOrEmpty
            Get-SupportedArchitecture $manifest 'arm64' | Should -BeNullOrEmpty
        }
    }
}
