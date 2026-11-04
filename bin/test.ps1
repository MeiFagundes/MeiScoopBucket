#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'BuildHelpers'; ModuleVersion = '2.0.1' }
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

$pesterConfig = New-PesterConfiguration -Hashtable @{
    Run    = @{
        Path     = "$PSScriptRoot/.."
        PassThru = $true
    }
    Output = @{
        Verbosity = 'Detailed'
    }
}
$result = Invoke-Pester -Configuration $pesterConfig
if ($null -eq $result) { exit 1 }

$failed = [int]$result.FailedCount
foreach ($property in @('FailedContainersCount', 'FailedBlocksCount')) {
    $member = $result.PSObject.Properties[$property]
    if ($member) { $failed += [int]$member.Value }
}
$totalMember = $result.PSObject.Properties['TotalCount']
if ($totalMember -and [int]$totalMember.Value -eq 0) {
    Write-Error 'No tests were discovered.'
    exit 1
}
exit $failed
