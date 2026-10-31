#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Backup', 'HealthCheck')]
    [string] $Mode = 'Backup',
    [ValidateNotNullOrEmpty()]
    [string] $SourceDirectory = (Join-Path $env:LOCALAPPDATA 'mVolt+'),
    [ValidateNotNullOrEmpty()]
    [string] $BackupDirectory = (Join-Path $env:LOCALAPPDATA 'mVoltPlus-ProfileBackups'),
    [string] $ExpectedProfileId = '',
    [string[]] $ExecutablePath = @(),
    [ValidateRange(1, 2147483647)]
    [int] $KeepSnapshots = 30,
    [switch] $SkipRetention,
    [switch] $Strict
)

$ErrorActionPreference = 'Stop'
$script:hadWarning = $false
$script:hadIoFailure = $false
$script:canWriteLog = $false
$script:observedHashes = @()
$lock = $null
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$ExecutablePath = @($ExecutablePath | ForEach-Object { ([string]$_ -split '\|') } | Where-Object { $_ } | Select-Object -Unique)

function Get-BytesHash([byte[]] $Bytes) {
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hasher.ComputeHash($Bytes)).Replace('-', '') }
    finally { $hasher.Dispose() }
}

function Assert-OrdinaryDirectory([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Backup directory must be an ordinary directory: $Path" }
}

function Resolve-PhysicalPath([string] $Path) {
    if (!('MVoltProfileGuard.NativePath' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace MVoltProfileGuard {
    public static class NativePath {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle,
            StringBuilder path, uint capacity, uint flags);
        public static string ResolveDirectory(string path) {
            using (var handle = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                var buffer = new StringBuilder(1024);
                uint size = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
                if (size >= buffer.Capacity) {
                    buffer = new StringBuilder((int)size + 1);
                    size = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
                }
                if (size == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                string result = buffer.ToString();
                if (result.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
                    return @"\\" + result.Substring(8);
                if (result.StartsWith(@"\\?\", StringComparison.Ordinal)) return result.Substring(4);
                return result;
            }
        }
    }
}
'@
    }
    $existing = [IO.Path]::GetFullPath($Path)
    $tail = @()
    while (!(Test-Path -LiteralPath $existing)) {
        $parent = Split-Path -Parent $existing
        if (!$parent -or $parent -eq $existing) { throw "Cannot resolve an existing ancestor for $Path" }
        $tail = @([IO.Path]::GetFileName($existing.TrimEnd('\', '/'))) + $tail
        $existing = $parent
    }
    if (!(Test-Path -LiteralPath $existing -PathType Container)) { throw "A directory path names an existing file: $existing" }
    $resolved = [MVoltProfileGuard.NativePath]::ResolveDirectory($existing)
    foreach ($part in $tail) { $resolved = Join-Path $resolved $part }
    $resolved = [IO.Path]::GetFullPath($resolved)
    if ($resolved.Length -gt ([IO.Path]::GetPathRoot($resolved)).Length) { $resolved = $resolved.TrimEnd('\', '/') }
    return $resolved
}

function Write-GuardLog([string] $Message) {
    if (!$script:canWriteLog) { return }
    try {
        Assert-OrdinaryDirectory $BackupDirectory
        $log = Join-Path $BackupDirectory 'health.log'
        if ((Test-Path -LiteralPath $log) -and ((Get-Item -LiteralPath $log -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
        $last = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 1 } else { '' }
        if (!$last -or !([string]$last).EndsWith(' ' + $Message, [StringComparison]::Ordinal)) {
            Add-Content -LiteralPath $log -Value ('{0:o} {1}' -f (Get-Date), $Message) -Encoding UTF8
        }
    } catch {
        # Diagnostic logging must not prevent preserving profiles or installing the app.
    }
}

function Write-GuardWarning([string] $Message, [switch] $IoFailure) {
    $script:hadWarning = $true
    if ($IoFailure) { $script:hadIoFailure = $true }
    Write-GuardLog ('WARNING: ' + $Message)
    Write-Warning -Message $Message -WarningAction Continue
}

function Get-ExecutableMetadata {
    foreach ($path in $ExecutablePath) {
        try {
            $file = Get-Item -LiteralPath $path
            if (!$file.PSIsContainer) {
                [pscustomobject]@{ path=$file.FullName; version=$file.VersionInfo.FileVersion; sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
            }
        } catch {
            # Optional metadata is best effort; never inspect or launch other processes.
        }
    }
}

function Get-StableBytes([string] $Path) {
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $before = Get-Item -LiteralPath $Path
            $length = $before.Length
            $written = $before.LastWriteTimeUtc
            $bytes = [IO.File]::ReadAllBytes($Path)
            Start-Sleep -Milliseconds 100
            $second = [IO.File]::ReadAllBytes($Path)
            $after = Get-Item -LiteralPath $Path
            if ($length -eq $after.Length -and $written -eq $after.LastWriteTimeUtc -and (Get-BytesHash $bytes) -eq (Get-BytesHash $second)) {
                return ,$bytes
            }
        } catch {
            if ($attempt -eq 4) { throw }
        }
        Start-Sleep -Milliseconds (100 * $attempt)
    }
    throw "Profile file kept changing while it was read: $Path"
}

function Get-DocumentInfo([byte[]] $Bytes, [string] $Name) {
    $issues = @()
    $document = $null
    try { $document = $utf8.GetString($Bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json }
    catch { $issues += 'The document is not valid UTF-8 JSON.' }
    $ids = @()
    if ($document) {
        if (!$document.schema -or !$document.adapter_id -or !$document.vbios_id -or $document.profiles -isnot [array]) {
            $issues += 'The document does not expose recognizable profile and GPU identity fields.'
        } else {
            foreach ($profile in $document.profiles) {
                if ($profile.id -isnot [string] -or [string]::IsNullOrWhiteSpace($profile.id)) { $issues += 'A profile is missing its identifier.' }
                else { $ids += [string]$profile.id }
            }
            if ($ids.Count -eq 0) { $issues += 'The document contains no saved profiles.' }
        }
    } else {
        if ($issues.Count -eq 0) { $issues += 'The document does not contain a profile object.' }
    }
    if ($Name.EndsWith('.json.bak', [StringComparison]::OrdinalIgnoreCase)) { $issues += 'An adjacent backup exists without its primary document.' }
    $identity = if ($document -and $document.vbios_id -and $document.adapter_id) { [string]$document.vbios_id + '-' + [string]$document.adapter_id } else { '' }
    $key = if ($identity -and $identity.Length -le 120 -and $identity -match '^[A-Za-z0-9._-]+$') {
        $identity
    } else {
        'document-' + (Get-BytesHash ($utf8.GetBytes($identity + '|' + $Name))).Substring(0, 32)
    }
    [pscustomobject]@{ Document=$document; Ids=$ids; Issues=$issues; Valid=($issues.Count -eq 0); Key=$key }
}

function Get-ProtectionIds($Metadata, [string[]] $ActualIds) {
    $ids = @($Metadata.protected_profile_ids)
    # Accept protection metadata written by earlier helper versions.
    if ($Metadata.protected_profile_id) { $ids += [string]$Metadata.protected_profile_id }
    elseif ($Metadata.protected_baseline) { $ids += $ActualIds }
    @($ids | Where-Object { $_ -and $ActualIds -contains $_ } | Select-Object -Unique)
}

function Get-VerifiedSnapshot([string] $Directory) {
    try {
        Assert-OrdinaryDirectory $Directory
        $metadataFile = Join-Path $Directory 'metadata.json'
        if ((Get-Item -LiteralPath $metadataFile -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
        $metadata = Get-Content -LiteralPath $metadataFile -Raw | ConvertFrom-Json
        if ($metadata.format_version -and $metadata.format_version -ne 2) { return }
        $leaf = [string]$metadata.primary_file
        if (!$leaf -or [IO.Path]::GetFileName($leaf) -ne $leaf -or $leaf -eq 'metadata.json' -or $metadata.primary_sha256 -notmatch '^[A-Fa-f0-9]{64}$') { return }
        $file = Get-Item -LiteralPath (Join-Path $Directory $leaf) -Force
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        if ((Get-BytesHash $bytes) -ne $metadata.primary_sha256) { return }
        $bak = Join-Path $Directory ($leaf + '.bak')
        if ($metadata.adjacent_backup_sha256) {
            $backupFile = Get-Item -LiteralPath $bak -Force
            if ($backupFile.PSIsContainer -or ($backupFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
            if ((Get-BytesHash ([IO.File]::ReadAllBytes($bak))) -ne $metadata.adjacent_backup_sha256) { return }
        } elseif (Test-Path -LiteralPath $bak) { return }
        $info = Get-DocumentInfo $bytes $leaf
        $seen = [DateTimeOffset]::MinValue
        $timestamp = if ($metadata.last_seen_utc) { $metadata.last_seen_utc } else { $metadata.created_utc }
        if (![DateTimeOffset]::TryParse([string]$timestamp, [ref]$seen)) { return }
        [pscustomobject]@{ Directory=$Directory; Metadata=$metadata; Info=$info; Seen=$seen; ProtectedIds=@(Get-ProtectionIds $metadata $info.Ids) }
    } catch {
        # Incomplete, altered, or unfamiliar snapshots are neither reused nor pruned.
    }
}

function Set-SnapshotMetadata([string] $Directory, $Metadata) {
    $target = Join-Path $Directory 'metadata.json'
    $temporary = Join-Path $Directory ('.metadata-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporary, ($Metadata | ConvertTo-Json -Depth 12), $utf8)
    if (Test-Path -LiteralPath $target) {
        $previous = $temporary + '.previous'
        [IO.File]::Replace($temporary, $target, $previous)
        Remove-Item -LiteralPath $previous
    } else { [IO.File]::Move($temporary, $target) }
}

function Save-Snapshot([string] $Path) {
    $bytes = Get-StableBytes $Path
    $leaf = [IO.Path]::GetFileName($Path)
    $hash = Get-BytesHash $bytes
    $script:observedHashes += "$leaf=$hash"
    $bakBytes = $null
    $bakHash = $null
    if (Test-Path -LiteralPath ($Path + '.bak') -PathType Leaf) {
        $bakBytes = Get-StableBytes ($Path + '.bak')
        $bakHash = Get-BytesHash $bakBytes
    }
    $info = Get-DocumentInfo $bytes $leaf
    $root = if ($info.Valid) { Join-Path $snapshotRoot $info.Key } else { $incidentRoot }
    [void][IO.Directory]::CreateDirectory($root)
    Assert-OrdinaryDirectory $root
    $entries = @(Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object { $_.Name -notlike '.pending-*' } | ForEach-Object { Get-VerifiedSnapshot $_.FullName })
    $same = $entries | Where-Object { $_.Metadata.primary_file -eq $leaf -and $_.Metadata.primary_sha256 -eq $hash -and $_.Metadata.adjacent_backup_sha256 -eq $bakHash } | Select-Object -First 1
    $protection = @()
    if ($info.Valid -and $ExpectedProfileId -and $info.Ids -contains $ExpectedProfileId) { $protection += $ExpectedProfileId }
    if ($same) {
        $metadata = $same.Metadata
        $protection = @(@($same.ProtectedIds) + $protection | Select-Object -Unique)
        $metadata | Add-Member -NotePropertyName protected_profile_ids -NotePropertyValue $protection -Force
        $metadata | Add-Member -NotePropertyName last_seen_utc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        Set-SnapshotMetadata $same.Directory $metadata
        $saved = Get-VerifiedSnapshot $same.Directory
    } else {
        $pending = Join-Path $root ('.pending-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($pending)
        [IO.File]::WriteAllBytes((Join-Path $pending $leaf), $bytes)
        if ($null -ne $bakBytes) { [IO.File]::WriteAllBytes((Join-Path $pending ($leaf + '.bak')), $bakBytes) }
        $document = $info.Document
        $metadata = [ordered]@{
            format_version=2; created_utc=[DateTime]::UtcNow.ToString('o'); last_seen_utc=[DateTime]::UtcNow.ToString('o')
            primary_file=$leaf; primary_sha256=$hash; adjacent_backup_sha256=$bakHash
            schema=$document.schema; revision=$document.revision; profile_ids=@($info.Ids)
            profile_names=@($document.profiles | ForEach-Object { [string]$_.name })
            protected_profile_ids=$protection; protected_profile_id=$ExpectedProfileId
            protected_baseline=($protection.Count -gt 0); empty_profiles=($info.Ids.Count -eq 0)
            incident=(!$info.Valid); issues=@($info.Issues); gpu_name=$document.gpu_name
            vbios_id=$document.vbios_id; adapter_id=$document.adapter_id
            startup_profile_id=$document.startup_profile_id; executable_versions=@(Get-ExecutableMetadata)
        }
        Set-SnapshotMetadata $pending $metadata
        if (!(Get-VerifiedSnapshot $pending)) { throw "Snapshot verification failed: $pending" }
        $final = Join-Path $root ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fffffff') + '-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::Move($pending, $final)
        $saved = Get-VerifiedSnapshot $final
    }
    if (!$saved) { throw "Snapshot could not be verified for $Path" }
    [pscustomobject]@{ Snapshot=$saved.Directory; Root=$root; Info=$info }
}

function Invoke-Retention([string] $Root, [string[]] $CurrentSnapshots) {
    Assert-OrdinaryDirectory $Root
    $valid = @(Get-ChildItem -LiteralPath $Root -Directory -Force | Where-Object { $_.Name -notlike '.pending-*' } | ForEach-Object { Get-VerifiedSnapshot $_.FullName } | Where-Object { $_.Info.Valid -and $_.Info.Key -eq [IO.Path]::GetFileName($Root) } | Sort-Object Seen -Descending)
    $keep = @($valid | Select-Object -First $KeepSnapshots | ForEach-Object { $_.Directory })
    # Several current files can describe one GPU; every file just backed up must remain recoverable.
    $keep += $CurrentSnapshots
    $protectedIds = @($valid | ForEach-Object { $_.ProtectedIds } | Select-Object -Unique)
    foreach ($id in $protectedIds) {
        $baseline = $valid | Where-Object { $_.Info.Ids -contains $id } | Select-Object -First 1
        if ($baseline) { $keep += $baseline.Directory }
    }
    foreach ($entry in $valid) {
        if ($keep -contains $entry.Directory) { continue }
        # Only remove verified, flat snapshots immediately inside the managed GPU directory.
        if ([IO.Path]::GetFullPath((Split-Path -Parent $entry.Directory)) -ne [IO.Path]::GetFullPath($Root)) { throw 'Retention path escaped its managed directory.' }
        $allowed = @('metadata.json', [string]$entry.Metadata.primary_file)
        if ($entry.Metadata.adjacent_backup_sha256) { $allowed += [string]$entry.Metadata.primary_file + '.bak' }
        $files = @(Get-ChildItem -LiteralPath $entry.Directory -Force)
        if (@($files | Where-Object { $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $allowed -notcontains $_.Name }).Count -gt 0) { continue }
        foreach ($file in $files) { Remove-Item -LiteralPath $file.FullName }
        Remove-Item -LiteralPath $entry.Directory
    }
}

try {
    $SourceDirectory = Resolve-PhysicalPath $SourceDirectory
    $BackupDirectory = Resolve-PhysicalPath $BackupDirectory
    $sourcePrefix = $SourceDirectory.TrimEnd('\') + '\'
    $backupPrefix = $BackupDirectory.TrimEnd('\') + '\'
    if ($SourceDirectory -eq $BackupDirectory -or $BackupDirectory.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase) -or $SourceDirectory.StartsWith($backupPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Source and backup directories must be separate, non-overlapping directories.'
    }
    $profilesDirectory = Join-Path $SourceDirectory 'profiles'
    $snapshotRoot = Join-Path $BackupDirectory 'snapshots'
    $incidentRoot = Join-Path $BackupDirectory 'incidents'
    $results = @()
    $expectedFound = $false
    $files = @()
    if (Test-Path -LiteralPath $profilesDirectory -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $profilesDirectory -File | Where-Object {
            $_.Name.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase) -or
            ($_.Name.EndsWith('.json.bak', [StringComparison]::OrdinalIgnoreCase) -and !(Test-Path -LiteralPath $_.FullName.Substring(0, $_.FullName.Length - 4)))
        })
    }
    if ($files.Count -eq 0) {
        if ($Mode -eq 'HealthCheck') {
            [void][IO.Directory]::CreateDirectory($BackupDirectory)
            Assert-OrdinaryDirectory $BackupDirectory
            $script:canWriteLog = $true
            Write-GuardWarning 'No mVolt+ profile documents were found. Profile hashes: none.'
        }
        else { Write-Output 'No existing mVolt+ profile documents; fresh install requires no backup.' }
    } else {
        [void][IO.Directory]::CreateDirectory($BackupDirectory)
        Assert-OrdinaryDirectory $BackupDirectory
        $script:canWriteLog = $true
        $clock = [Diagnostics.Stopwatch]::StartNew()
        do {
            try { $lock = [IO.File]::Open((Join-Path $BackupDirectory '.profile-guard.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            catch [IO.IOException] { if ($clock.Elapsed.TotalSeconds -ge 3) { throw }; Start-Sleep -Milliseconds 100 }
        } while (!$lock)
        foreach ($managedRoot in @($snapshotRoot, $incidentRoot)) {
            if (Test-Path -LiteralPath $managedRoot) { Assert-OrdinaryDirectory $managedRoot }
        }
        foreach ($file in $files) {
            try {
                $result = Save-Snapshot $file.FullName
                $results += $result
                if (!$result.Info.Valid) { Write-GuardWarning ($file.Name + ': ' + ($result.Info.Issues -join ' ') + ' Original bytes preserved in ' + $result.Snapshot) }
                if ($result.Info.Valid -and (!$ExpectedProfileId -or $result.Info.Ids -contains $ExpectedProfileId)) { $expectedFound = $true }
                if ($Mode -eq 'Backup') { Write-Output ('Profile snapshot: ' + $result.Snapshot) }
            } catch { Write-GuardWarning ($file.Name + ': ' + $_.Exception.Message) -IoFailure }
        }
        if (!$SkipRetention -and !$script:hadIoFailure) {
            foreach ($root in @($results | Where-Object { $_.Info.Valid } | ForEach-Object { $_.Root } | Select-Object -Unique)) {
                try {
                    $current = @($results | Where-Object { $_.Root -eq $root } | ForEach-Object { $_.Snapshot })
                    Invoke-Retention $root $current
                }
                catch { Write-GuardWarning ('Snapshot retention could not complete: ' + $_.Exception.Message) -IoFailure }
            }
        }
        if ($Mode -eq 'HealthCheck' -and !$expectedFound) {
            $label = if ($ExpectedProfileId) { 'Protected profile ' + $ExpectedProfileId } else { 'Valid profiles' }
            $executables = @(Get-ExecutableMetadata | ForEach-Object { '{0} version={1} sha256={2}' -f $_.path,$_.version,$_.sha256 }) -join '; '
            Write-GuardWarning ($label + ' missing. Profile hashes: ' + ($script:observedHashes -join '; ') + '. Executables: ' + $executables)
        }
    }
} catch { Write-GuardWarning $_.Exception.Message -IoFailure }
finally { if ($lock) { $lock.Dispose() } }

if ($Mode -eq 'HealthCheck') {
    if ($script:hadWarning) { exit 2 }
    Write-GuardLog 'Health check OK: all profile documents were preserved and checked.'
    Write-Output 'Health check OK.'
} elseif ($Strict -and $script:hadIoFailure) { exit 1 }
elseif ($script:hadWarning) { Write-Output 'Backup completed with warnings; installation may continue.' }
else { Write-Output 'Backup complete.' }
