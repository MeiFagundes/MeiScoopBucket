#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $BucketPath,
    [string] $Token = $env:GITHUB_TOKEN
)

if (!$BucketPath) { $BucketPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\bucket' }

function Split-ScoopVersion {
    param(
        [string] $Version,
        [string] $Delimiter = '-'
    )
    $Version = $Version -replace '[a-zA-Z]+', "$Delimiter$&$Delimiter"
    return ($Version -split [regex]::Escape($Delimiter) -ne '' | ForEach-Object { if ($_ -match '^\d+$') { [long]$_ } else { $_ } })
}

function Compare-ScoopVersion {
    param(
        [string] $ReferenceVersion,
        [string] $DifferenceVersion,
        [string] $Delimiter = '-'
    )
    $ReferenceVersion, $DifferenceVersion = @($ReferenceVersion, $DifferenceVersion) -replace '\+', '-'
    if ($DifferenceVersion -eq $ReferenceVersion) { return 0 }

    $referenceParts = @(Split-ScoopVersion -Version $ReferenceVersion -Delimiter $Delimiter)
    $differenceParts = @(Split-ScoopVersion -Version $DifferenceVersion -Delimiter $Delimiter)

    for ($i = 0; $i -lt [Math]::Max($referenceParts.Length, $differenceParts.Length); $i++) {
        if ($i -ge $referenceParts.Length) {
            if ($differenceParts[$i] -match 'alpha|beta|rc|pre') { return -1 }
            return 1
        }
        if ($i -ge $differenceParts.Length) {
            if ($referenceParts[$i] -match 'alpha|beta|rc|pre') { return 1 }
            return -1
        }

        if (($referenceParts[$i] -match '\.') -or ($differenceParts[$i] -match '\.')) {
            $result = Compare-ScoopVersion -ReferenceVersion $referenceParts[$i] -DifferenceVersion $differenceParts[$i] -Delimiter '.'
            if ($result -ne 0) { return $result }
            continue
        }
        if (($referenceParts[$i] -match '_') -or ($differenceParts[$i] -match '_')) {
            $result = Compare-ScoopVersion -ReferenceVersion $referenceParts[$i] -DifferenceVersion $differenceParts[$i] -Delimiter '_'
            if ($result -ne 0) { return $result }
            continue
        }

        if ($null -ne $referenceParts[$i] -and $null -ne $differenceParts[$i]) {
            if ($referenceParts[$i] -is [string] -and $differenceParts[$i] -isnot [string]) { $differenceParts[$i] = "$($differenceParts[$i])" }
            if ($differenceParts[$i] -is [string] -and $referenceParts[$i] -isnot [string]) { $referenceParts[$i] = "$($referenceParts[$i])" }
        }

        if ($differenceParts[$i] -gt $referenceParts[$i]) { return 1 }
        if ($differenceParts[$i] -lt $referenceParts[$i]) { return -1 }
    }
}

function ConvertFrom-ReleaseTag {
    param([string] $Tag)
    $match = [regex]::Match([string]$Tag, '(?:^|[^\d])(?:v|V)?(\d[\d.-]*)')
    if (!$match.Success -or !$match.Groups[1].Value) { return $null }
    return $match.Groups[1].Value
}

function ConvertTo-GitHubLatestApiUrl {
    param([string] $RepositoryUrl)
    $url = ([string]$RepositoryUrl).TrimEnd('/')
    if ($url -match '^https://api\.github\.com/repos/([^/]+)/([^/]+)(?:/.*)?$') {
        return "https://api.github.com/repos/$($Matches[1])/$($Matches[2])/releases/latest"
    }
    if ($url -match '^https://(?:www\.)?github\.com/([^/]+)/([^/]+)$') {
        return "https://api.github.com/repos/$($Matches[1])/$($Matches[2])/releases/latest"
    }
    return $null
}

function Get-GitHubCheckverSource {
    param([object] $Manifest)

    if ($null -eq $Manifest.checkver) {
        return [pscustomobject]@{ Supported = $true; Skip = $true; Source = $null; Message = 'no checkver; not auto-updated' }
    }

    $checkver = $Manifest.checkver
    if ($checkver -is [string]) {
        if ($checkver -eq 'github') {
            return [pscustomobject]@{ Supported = $true; Skip = $false; Source = $Manifest.homepage; Message = $null }
        }
        return [pscustomobject]@{ Supported = $false; Skip = $false; Source = $null; Message = "checkver string '$checkver' is not supported by this verifier" }
    }

    $properties = @($checkver.PSObject.Properties.Name)
    $unsupported = @($properties | Where-Object { $_ -notin @('github', 'useragent') })
    if ($unsupported.Count -gt 0) {
        return [pscustomobject]@{ Supported = $false; Skip = $false; Source = $null; Message = "checkver.$($unsupported -join ', checkver.') is not supported by this verifier" }
    }
    if (!$checkver.github) {
        return [pscustomobject]@{ Supported = $false; Skip = $false; Source = $null; Message = 'checkver has no GitHub source' }
    }
    return [pscustomobject]@{ Supported = $true; Skip = $false; Source = $checkver.github; Message = $null }
}

function Get-LatestRelease {
    param(
        [string] $CheckverGithub,
        [string] $Homepage,
        [string] $Token
    )
    $source = if ($CheckverGithub) { $CheckverGithub } else { $Homepage }
    $apiUrl = ConvertTo-GitHubLatestApiUrl -RepositoryUrl $source
    if (!$apiUrl) { throw "unsupported GitHub repository URL: $source" }

    $headers = @{
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'MeiScoopBucket-update-verifier'
    }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }

    $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get -ErrorAction Stop
    if (!$release.tag_name) { throw "release response from $apiUrl has no tag_name" }
    $version = ConvertFrom-ReleaseTag -Tag $release.tag_name
    if (!$version) { throw "cannot parse a version from release tag '$($release.tag_name)'" }
    return [pscustomobject]@{ Version = $version; Tag = $release.tag_name; Url = $release.html_url }
}

function Invoke-UpdateVerification {
    param(
        [string] $BucketPath,
        [string] $Token
    )

    $files = @(Get-ChildItem -LiteralPath $BucketPath -Filter '*.json' -File -ErrorAction Stop | Sort-Object Name)
    if ($files.Count -eq 0) { throw "no manifests found in $BucketPath" }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($file in $files) {
        $app = $file.BaseName
        try {
            $manifest = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $results.Add([pscustomobject]@{ App = $app; Status = 'Error'; Current = $null; Latest = $null; Message = "invalid JSON: $($_.Exception.Message)" })
            continue
        }

        if (!$manifest.version) {
            $results.Add([pscustomobject]@{ App = $app; Status = 'Error'; Current = $null; Latest = $null; Message = 'manifest has no version' })
            continue
        }
        if ($manifest.version -eq 'nightly') {
            $results.Add([pscustomobject]@{ App = $app; Status = 'Error'; Current = $manifest.version; Latest = $null; Message = 'nightly manifests are not supported by this verifier' })
            continue
        }

        $checkver = Get-GitHubCheckverSource -Manifest $manifest
        if ($checkver.Skip) {
            $results.Add([pscustomobject]@{ App = $app; Status = 'Skipped'; Current = $manifest.version; Latest = $null; Message = $checkver.Message })
            continue
        }
        if (!$checkver.Supported) {
            $results.Add([pscustomobject]@{ App = $app; Status = 'Error'; Current = $manifest.version; Latest = $null; Message = $checkver.Message })
            continue
        }

        try {
            $release = Get-LatestRelease -CheckverGithub $checkver.Source -Homepage $manifest.homepage -Token $Token
        } catch {
            $results.Add([pscustomobject]@{ App = $app; Status = 'Error'; Current = $manifest.version; Latest = $null; Message = "cannot read latest release: $($_.Exception.Message)" })
            continue
        }

        $comparison = Compare-ScoopVersion -ReferenceVersion $manifest.version -DifferenceVersion $release.Version
        if ($null -eq $comparison) {
            $results.Add([pscustomobject]@{ App = $app; Status = 'Error'; Current = $manifest.version; Latest = $release.Version; Message = "Scoop treats manifest version '$($manifest.version)' and upstream '$($release.Version)' as different" })
        } elseif ($comparison -gt 0) {
            $results.Add([pscustomobject]@{ App = $app; Status = 'Outdated'; Current = $manifest.version; Latest = $release.Version; Message = "upstream $($release.Version) is newer than manifest $($manifest.version)" })
        } elseif ($comparison -lt 0) {
            $results.Add([pscustomobject]@{ App = $app; Status = 'Ahead'; Current = $manifest.version; Latest = $release.Version; Message = "manifest $($manifest.version) is ahead of upstream $($release.Version)" })
        } else {
            $results.Add([pscustomobject]@{ App = $app; Status = 'Current'; Current = $manifest.version; Latest = $release.Version; Message = $null })
        }
    }

    $failures = @($results | Where-Object { $_.Status -in @('Outdated', 'Error') })
    return [pscustomobject]@{
        Success  = ($failures.Count -eq 0)
        Results  = $results.ToArray()
        Failures = $failures
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $verification = Invoke-UpdateVerification -BucketPath $BucketPath -Token $Token
    } catch {
        Write-Host "::error title=Manifest update verification::$($_.Exception.Message)"
        exit 1
    }

    $verification.Results | ForEach-Object {
        $latest = if ($_.Latest) { $_.Latest } else { '-' }
        $line = '{0,-12} {1,-10} manifest={2,-12} latest={3,-12} {4}' -f $_.App, $_.Status, $_.Current, $latest, $_.Message
        Write-Host $line.TrimEnd()
        if ($_.Status -in @('Outdated', 'Error')) {
            Write-Host "::error title=$($_.App) update verification::$($_.Message)"
        }
    }

    if ($verification.Success) {
        Write-Host 'All auto-updated manifests are current.'
        exit 0
    }
    Write-Host "::error title=Manifest update verification::$($verification.Failures.Count) update check(s) failed."
    exit 1
}
