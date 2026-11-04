#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

Describe 'Manifest update verification' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\scripts\verify-updates.ps1')

        $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('mvolt-verify-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:Releases = @{}

        function Get-LatestRelease {
            param($CheckverGithub, $Homepage, $Token)
            $source = if ($CheckverGithub) { $CheckverGithub } else { $Homepage }
            if (!$script:Releases.ContainsKey($source)) { throw "no fixture release for $source" }
            return [pscustomobject]$script:Releases[$source]
        }

        function New-TestManifest {
            param(
                [string] $Version,
                [string] $Repository = 'https://github.com/example/app',
                [switch] $WithoutCheckver,
                [hashtable] $ExtraCheckver = @{}
            )
            $manifest = [ordered]@{
                version  = $Version
                homepage = $Repository
            }
            if (!$WithoutCheckver) {
                $checkver = [ordered]@{ github = $Repository }
                foreach ($key in $ExtraCheckver.Keys) { $checkver[$key] = $ExtraCheckver[$key] }
                $manifest['checkver'] = $checkver
            }
            [pscustomobject]$manifest
        }

        function New-BucketFixture {
            param([hashtable] $Manifests)
            $directory = Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            foreach ($name in $Manifests.Keys) {
                $Manifests[$name] | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory "$name.json") -Encoding UTF8
            }
            return $directory
        }

        function Set-FixtureRelease {
            param([string] $Repository, [string] $Version)
            $script:Releases[$Repository] = [pscustomobject]@{ Version = $Version; Tag = "v$Version"; Url = "$Repository/releases/tag/v$Version" }
        }
    }

    AfterAll {
        $resolved = [IO.Path]::GetFullPath($script:TempRoot)
        $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }

    BeforeEach {
        $script:Releases = @{}
    }

    It 'reports a current manifest as successful' {
        $repository = 'https://github.com/example/app'
        Set-FixtureRelease $repository '1.0.0'
        $directory = New-BucketFixture @{ app = (New-TestManifest '1.0.0' $repository) }

        $result = Invoke-UpdateVerification -BucketPath $directory -Token ''

        $result.Success | Should -BeTrue
        $result.Results[0].Status | Should -Be 'Current'
        $result.Failures.Count | Should -Be 0
    }

    It 'reports an older manifest as outdated' {
        $repository = 'https://github.com/example/app'
        Set-FixtureRelease $repository '1.1.0'
        $directory = New-BucketFixture @{ app = (New-TestManifest '1.0.0' $repository) }

        $result = Invoke-UpdateVerification -BucketPath $directory -Token ''

        $result.Success | Should -BeFalse
        $result.Results[0].Status | Should -Be 'Outdated'
        $result.Results[0].Latest | Should -Be '1.1.0'
        $result.Failures.Count | Should -Be 1
    }

    It 'reports a manifest ahead of upstream without failing' {
        $repository = 'https://github.com/example/app'
        Set-FixtureRelease $repository '1.0.0'
        $directory = New-BucketFixture @{ app = (New-TestManifest '1.1.0' $repository) }

        $result = Invoke-UpdateVerification -BucketPath $directory -Token ''

        $result.Success | Should -BeTrue
        $result.Results[0].Status | Should -Be 'Ahead'
    }

    It 'reports release lookup failures as errors' {
        $directory = New-BucketFixture @{ app = (New-TestManifest '1.0.0') }

        $result = Invoke-UpdateVerification -BucketPath $directory -Token ''

        $result.Success | Should -BeFalse
        $result.Results[0].Status | Should -Be 'Error'
        $result.Results[0].Message | Should -Match 'cannot read latest release'
    }

    It 'reports malformed JSON and still checks the remaining manifests' {
        $repository = 'https://github.com/example/app'
        Set-FixtureRelease $repository '1.0.0'
        $directory = New-BucketFixture @{ good = (New-TestManifest '1.0.0' $repository) }
        Set-Content -LiteralPath (Join-Path $directory 'bad.json') -Value '{not json' -Encoding UTF8

        $result = Invoke-UpdateVerification -BucketPath $directory -Token ''

        $result.Success | Should -BeFalse
        ($result.Results | Where-Object App -eq 'bad').Status | Should -Be 'Error'
        ($result.Results | Where-Object App -eq 'good').Status | Should -Be 'Current'
    }

    It 'rejects checkver configurations that the verifier cannot reproduce' {
        $repository = 'https://github.com/example/app'
        Set-FixtureRelease $repository '1.0.0'
        $manifest = New-TestManifest '1.0.0' $repository -ExtraCheckver @{ regex = 'v([\d.]+)' }
        $directory = New-BucketFixture @{ app = $manifest }

        $result = Invoke-UpdateVerification -BucketPath $directory -Token ''

        $result.Success | Should -BeFalse
        $result.Results[0].Status | Should -Be 'Error'
        $result.Results[0].Message | Should -Match 'not supported'
    }

    It 'flags version pairs that Scoop treats as different' {
        $repository = 'https://github.com/example/app'
        Set-FixtureRelease $repository '1.0.0-beta'
        $directory = New-BucketFixture @{ app = (New-TestManifest '1.0.0_beta' $repository) }

        $result = Invoke-UpdateVerification -BucketPath $directory -Token ''

        $result.Success | Should -BeFalse
        $result.Results[0].Status | Should -Be 'Error'
        $result.Results[0].Message | Should -Match 'as different'
    }

    It 'rejects nightly manifests instead of comparing them as strings' {
        $repository = 'https://github.com/example/app'
        Set-FixtureRelease $repository '1.0.0'
        $directory = New-BucketFixture @{ app = (New-TestManifest 'nightly' $repository) }

        $result = Invoke-UpdateVerification -BucketPath $directory -Token ''

        $result.Success | Should -BeFalse
        $result.Results[0].Status | Should -Be 'Error'
        $result.Results[0].Message | Should -Match 'nightly'
    }

    It 'skips manifests without a checkver' {
        $directory = New-BucketFixture @{ app = (New-TestManifest '1.0.0' -WithoutCheckver) }

        $result = Invoke-UpdateVerification -BucketPath $directory -Token ''

        $result.Success | Should -BeTrue
        $result.Results[0].Status | Should -Be 'Skipped'
    }

    It 'aggregates one failure across multiple current manifests' {
        $currentRepository = 'https://github.com/example/current'
        $outdatedRepository = 'https://github.com/example/outdated'
        Set-FixtureRelease $currentRepository '2.0.0'
        Set-FixtureRelease $outdatedRepository '3.0.0'
        $directory = New-BucketFixture @{
            current  = (New-TestManifest '2.0.0' $currentRepository)
            outdated = (New-TestManifest '2.9.0' $outdatedRepository)
        }

        $result = Invoke-UpdateVerification -BucketPath $directory -Token ''

        $result.Success | Should -BeFalse
        $result.Results.Count | Should -Be 2
        $result.Failures.Count | Should -Be 1
        ($result.Results | Where-Object App -eq 'current').Status | Should -Be 'Current'
        ($result.Results | Where-Object App -eq 'outdated').Status | Should -Be 'Outdated'
    }
}

Describe 'Update verification helpers' {
    BeforeAll {
        $script:ScoopHome = $env:SCOOP_HOME
        if (!$script:ScoopHome) { $script:ScoopHome = (Resolve-Path (scoop prefix scoop)).Path }
        . "$script:ScoopHome\lib\versions.ps1"
        . (Join-Path $PSScriptRoot '..\scripts\verify-updates.ps1')
    }

    It 'matches Scoop version ordering' {
        $cases = @(
            @('0.50.10', '0.50.11'),
            @('0.50.11', '0.50.11'),
            @('0.50.11', '0.50.10'),
            @('1.1.0', '1.1.0-beta'),
            @('1.0.0-rc', '1.0.0'),
            @('1.0.0_beta', '1.0.0-beta'),
            @('1.0.0_beta', '1.0.0-beta2'),
            @('1.0.0+1', '1.0.0-1')
        )
        foreach ($case in $cases) {
            $expected = Compare-Version -ReferenceVersion $case[0] -DifferenceVersion $case[1]
            $actual = Compare-ScoopVersion -ReferenceVersion $case[0] -DifferenceVersion $case[1]
            Should -ActualValue $actual -Be $expected -Because "$($case[0]) vs $($case[1]) should match Scoop"
        }
    }

    It 'extracts versions from common release tags' {
        ConvertFrom-ReleaseTag -Tag 'v0.50.11' | Should -Be '0.50.11'
        ConvertFrom-ReleaseTag -Tag '0.50.11' | Should -Be '0.50.11'
        ConvertFrom-ReleaseTag -Tag 'release-2.3.4' | Should -Be '2.3.4'
        ConvertFrom-ReleaseTag -Tag 'nightly' | Should -BeNullOrEmpty
    }

    It 'normalizes GitHub repository URLs to the latest release API' {
        ConvertTo-GitHubLatestApiUrl -RepositoryUrl 'https://github.com/b00nz/mVolt' | Should -Be 'https://api.github.com/repos/b00nz/mVolt/releases/latest'
        ConvertTo-GitHubLatestApiUrl -RepositoryUrl 'https://api.github.com/repos/b00nz/mVolt' | Should -Be 'https://api.github.com/repos/b00nz/mVolt/releases/latest'
        ConvertTo-GitHubLatestApiUrl -RepositoryUrl 'https://example.com/not-github' | Should -BeNullOrEmpty
    }
}
