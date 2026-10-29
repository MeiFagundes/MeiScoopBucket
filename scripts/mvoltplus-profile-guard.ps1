[CmdletBinding()]
param(
    [ValidateSet('Backup', 'HealthCheck')]
    [string] $Mode = 'Backup',
    [string] $SourceDirectory = (Join-Path $env:LOCALAPPDATA 'mVolt+'),
    [string] $BackupDirectory = (Join-Path $env:LOCALAPPDATA 'mVoltPlus-ProfileBackups'),
    [string] $ExpectedProfileId = '',
    [string[]] $ExecutablePath = @(),
    [int] $KeepSnapshots = 30,
    [switch] $SkipRetention
)

$ErrorActionPreference = 'Stop'
$ExecutablePath = @($ExecutablePath | ForEach-Object { ([string]$_ -split '\|') } | Where-Object { $_ })
if ($ExecutablePath.Count -eq 0) {
    if ($env:SCOOP) { $ExecutablePath += Join-Path $env:SCOOP 'apps\mvoltplus\current\mVolt+.exe' }
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $startupTasks = Get-ScheduledTask -TaskName 'mVolt+ Apply Startup Profile*' -ErrorAction SilentlyContinue
        foreach ($startupTask in $startupTasks) {
            foreach ($action in $startupTask.Actions) {
                if ($action.Execute) { $ExecutablePath += [string]$action.Execute }
            }
        }
    }
}
$profilesDirectory = Join-Path $SourceDirectory 'profiles'
$snapshotRoot = Join-Path $BackupDirectory 'snapshots'
$incidentRoot = Join-Path $BackupDirectory 'incidents'
$logPath = Join-Path $BackupDirectory 'health.log'
$profileLabel = if ($ExpectedProfileId) { "Protected profile $ExpectedProfileId" } else { 'Profiles' }

function Write-GuardLog([string] $Message) {
    if (!(Test-Path -LiteralPath $BackupDirectory)) {
        New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    }
    $lastLine = $null
    if (Test-Path -LiteralPath $logPath) { $lastLine = Get-Content -LiteralPath $logPath -Tail 1 -ErrorAction SilentlyContinue }
    if ($lastLine -notlike ('* ' + $Message)) {
        Add-Content -LiteralPath $logPath -Value ('{0:o} {1}' -f (Get-Date), $Message) -Encoding UTF8
    }
}

function Get-ExecutableMetadata {
    $items = @()
    foreach ($path in $ExecutablePath) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $file = Get-Item -LiteralPath $path
            $items += [pscustomobject]@{
                path = $file.FullName
                version = $file.VersionInfo.FileVersion
                sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            }
        }
    }
    return $items
}

function Get-HealthEvidence {
    $exeText = @(Get-ExecutableMetadata | ForEach-Object { '{0} version={1} sha256={2}' -f $_.path,$_.version,$_.sha256 }) -join '; '
    $hashes = @()
    if (Test-Path -LiteralPath $profilesDirectory -PathType Container) {
        $hashes = @(Get-ChildItem -LiteralPath $profilesDirectory -Filter '*.json' -File | Where-Object { $_.Name -notlike '*.bak' } | ForEach-Object { '{0}={1}' -f $_.Name,(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
    }
    if ($hashes.Count -eq 0) { $hashes = @('none') }
    return ('Profile hashes: {0}. Executables: {1}' -f ($hashes -join '; '), $exeText)
}

function Get-StableDocument([string] $Path) {
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $before = Get-Item -LiteralPath $Path -ErrorAction Stop
            $bytes = [System.IO.File]::ReadAllBytes($Path)
            Start-Sleep -Milliseconds 150
            $after = Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($before.Length -eq $after.Length -and $before.LastWriteTimeUtc -eq $after.LastWriteTimeUtc -and $bytes.Length -eq $after.Length) {
                return ,$bytes
            }
        } catch {
            if ($attempt -eq 4) { throw }
        }
        Start-Sleep -Milliseconds (100 * $attempt)
    }
    throw "Profile file kept changing while it was read: $Path"
}

function Get-JsonFromBytes([byte[]] $Bytes) {
    $json = [System.Text.Encoding]::UTF8.GetString($Bytes)
    $json = $json.TrimStart([char]0xFEFF)
    return ($json | ConvertFrom-Json -ErrorAction Stop)
}

function Save-Snapshot([string] $Path, [switch] $HealthCheck) {
    $bytes = Get-StableDocument $Path
    $document = Get-JsonFromBytes $bytes
    if (!$document.schema -or !$document.adapter_id -or !$document.vbios_id -or $null -eq $document.profiles) {
        throw "Profile document is missing required identity or profile fields: $Path"
    }
    $profileIds = @($document.profiles | ForEach-Object { [string]$_.id })
    $empty = $profileIds.Count -eq 0
    $incident = $HealthCheck -and ($empty -or ($ExpectedProfileId -and $profileIds -notcontains $ExpectedProfileId))
    if ($empty -and !$HealthCheck) {
        throw "Refusing to replace a valid recovery snapshot with an empty profile document: $Path"
    }
    if ($document.adapter_id -notmatch '^[\w-]+$' -or $document.vbios_id -notmatch '^[\w.\-]+$') {
        throw "Profile document has an invalid GPU identity: $Path"
    }

    $primaryHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '')
    $backupPath = $Path + '.bak'
    $backupHash = $null
    $backupBytes = $null
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        $backupBytes = Get-StableDocument $backupPath
        $backupHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($backupBytes)).Replace('-', '')
    }
    $gpuKey = ('{0}-{1}' -f $document.vbios_id, $document.adapter_id) -replace '[^A-Za-z0-9._-]', '_'
    $gpuRoot = Join-Path $snapshotRoot $gpuKey
    if (!(Test-Path -LiteralPath $gpuRoot)) { New-Item -ItemType Directory -Path $gpuRoot -Force | Out-Null }

    $targetRoot = if ($Incident) { $incidentRoot } else { $gpuRoot }
    if (!(Test-Path -LiteralPath $targetRoot)) { New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null }
    $same = Get-ChildItem -LiteralPath $targetRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
        $metadataPath = Join-Path $_.FullName 'metadata.json'
        if (Test-Path -LiteralPath $metadataPath) {
            try {
                $old = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
                $old.primary_sha256 -eq $primaryHash -and $old.adjacent_backup_sha256 -eq $backupHash
            } catch { $false }
        } else { $false }
    } | Select-Object -First 1
    if ($same) { return $same.FullName }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $snapshot = Join-Path $targetRoot ($stamp + '-' + $gpuKey)
    New-Item -ItemType Directory -Path $snapshot -Force | Out-Null
    $leaf = Split-Path -Leaf $Path
    [System.IO.File]::WriteAllBytes((Join-Path $snapshot $leaf), $bytes)
    if ($null -ne $backupBytes) {
        [System.IO.File]::WriteAllBytes((Join-Path $snapshot ($leaf + '.bak')), $backupBytes)
    }
    $metadata = [ordered]@{
        created_utc = [DateTime]::UtcNow.ToString('o')
        primary_file = $leaf
        primary_sha256 = $primaryHash
        adjacent_backup_sha256 = $backupHash
        schema = [string]$document.schema
        revision = $document.revision
        profile_ids = $profileIds
        profile_names = @($document.profiles | ForEach-Object { [string]$_.name })
        protected_baseline = ([bool]$ExpectedProfileId -and $profileIds -contains $ExpectedProfileId)
        empty_profiles = $empty
        incident = [bool]$Incident
        gpu_name = [string]$document.gpu_name
        vbios_id = [string]$document.vbios_id
        adapter_id = [string]$document.adapter_id
        startup_profile_id = [string]$document.startup_profile_id
        executable_versions = @(Get-ExecutableMetadata)
        protected_profile_id = $ExpectedProfileId
    }
    $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $snapshot 'metadata.json') -Encoding UTF8

    if (!$Incident -and !$SkipRetention) { Invoke-Retention $gpuRoot }
    return $snapshot
}

function Invoke-Retention([string] $GpuRoot) {
    $directories = @(Get-ChildItem -LiteralPath $GpuRoot -Directory | Sort-Object Name -Descending)
    $valid = @()
    foreach ($directory in $directories) {
        $metadataPath = Join-Path $directory.FullName 'metadata.json'
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -ErrorAction Stop
            if (!$metadata.empty_profiles -and $metadata.profile_ids.Count -gt 0) { $valid += [pscustomobject]@{ Directory=$directory; Metadata=$metadata } }
        } catch { }
    }
    $protected = @($valid | Where-Object { $_.Metadata.protected_baseline -or $_.Metadata.profile_ids -contains $ExpectedProfileId } | Select-Object -First 1)
    $keep = @($valid | Select-Object -First $KeepSnapshots)
    if ($protected.Count -gt 0 -and !($keep | Where-Object { $_.Directory.FullName -eq $protected[0].Directory.FullName })) { $keep += $protected[0] }
    $keepPaths = @($keep | ForEach-Object { $_.Directory.FullName })
    foreach ($entry in $valid) {
        if ($keepPaths -notcontains $entry.Directory.FullName) { Remove-Item -LiteralPath $entry.Directory.FullName -Recurse -Force }
    }
}

if (!(Test-Path -LiteralPath $profilesDirectory -PathType Container)) {
    if ($Mode -eq 'Backup') { Write-Output 'No existing mVolt+ profile directory; fresh install requires no backup.'; exit 0 }
    $message = '{0} missing because the profile directory is absent. {1}' -f $profileLabel,(Get-HealthEvidence)
    Write-GuardLog ('WARNING: ' + $message)
    Write-Warning $message
    exit 2
}

$profileFiles = @(Get-ChildItem -LiteralPath $profilesDirectory -Filter '*.json' -File | Where-Object { $_.Name -notlike '*.bak' })
if ($profileFiles.Count -eq 0) {
    if ($Mode -eq 'Backup') { throw "Profile directory exists but has no profile JSON files: $profilesDirectory" }
    $message = '{0} missing because there are no profile JSON files. {1}' -f $profileLabel,(Get-HealthEvidence)
    Write-GuardLog ('WARNING: ' + $message)
    Write-Warning $message
    exit 2
}

$expectedFound = $false
foreach ($file in $profileFiles) {
    try {
        $snapshot = Save-Snapshot -Path $file.FullName -HealthCheck:($Mode -eq 'HealthCheck')
        $bytes = Get-StableDocument $file.FullName
        $document = Get-JsonFromBytes $bytes
        $ids = @($document.profiles | ForEach-Object { [string]$_.id })
        if (($ExpectedProfileId -and $ids -contains $ExpectedProfileId) -or (!$ExpectedProfileId -and $ids.Count -gt 0)) { $expectedFound = $true }
        if ($Mode -eq 'Backup') { Write-Output "Profile snapshot: $snapshot" }
    } catch {
        if ($Mode -eq 'Backup') { throw }
        Write-GuardLog ('WARNING: profile snapshot failed: ' + $_.Exception.Message)
        Write-Warning $_.Exception.Message
    }
}

if ($Mode -eq 'HealthCheck' -and !$expectedFound) {
    $message = '{0} missing. {1}' -f $profileLabel,(Get-HealthEvidence)
    Write-GuardLog ('WARNING: ' + $message)
    Write-Warning $message
    exit 2
}

if ($Mode -eq 'HealthCheck') { Write-GuardLog "Health check OK: $profileLabel present." }
Write-Output "Profile check complete. Expected profiles present: $expectedFound"
