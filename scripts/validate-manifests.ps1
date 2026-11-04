#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $BucketPath,
    [string] $ScoopHome = $env:SCOOP_HOME
)

if (!$BucketPath) { $BucketPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\bucket' }
if (!$ScoopHome) { throw 'SCOOP_HOME is required to validate manifests.' }

$validatorDll = Join-Path $ScoopHome 'supporting\validator\bin\Scoop.Validator.dll'
$schemaPath = Join-Path $ScoopHome 'schema.json'
if (!(Test-Path -LiteralPath $validatorDll -PathType Leaf)) { throw "Scoop validator not found: $validatorDll" }
if (!(Test-Path -LiteralPath $schemaPath -PathType Leaf)) { throw "Scoop schema not found: $schemaPath" }

$files = @(Get-ChildItem -LiteralPath $BucketPath -Filter '*.json' -File -ErrorAction Stop | Sort-Object Name)
if ($files.Count -eq 0) { throw "no manifests found in $BucketPath" }

Add-Type -Path $validatorDll
$validator = New-Object Scoop.Validator($schemaPath, $true)
$failed = 0
foreach ($file in $files) {
    try {
        $null = $validator.Validate($file.FullName)
        if ($validator.Errors.Count -gt 0) {
            $failed++
            Write-Host "[-] $($file.Name) has $($validator.Errors.Count) error(s)" -ForegroundColor Red
            Write-Host $validator.ErrorsAsString -ForegroundColor Yellow
        } else {
            Write-Host "[+] $($file.Name)"
        }
    } catch {
        $failed++
        Write-Host "[-] $($file.Name) validation failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($failed -gt 0) { exit 1 }
Write-Host "Validated $($files.Count) manifest(s)."
exit 0
