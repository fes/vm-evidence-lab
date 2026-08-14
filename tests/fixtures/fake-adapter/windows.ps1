[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $JobPath,

    [Parameter(Mandatory = $true)]
    [string] $SourceMapPath,

    [Parameter(Mandatory = $true)]
    [string] $ArtifactDirectory
)

$ErrorActionPreference = 'Stop'
$job = Get-Content -Raw -LiteralPath $JobPath | ConvertFrom-Json
$sourceMap = @(Get-Content -Raw -LiteralPath $SourceMapPath | ConvertFrom-Json)
if ($job.adapter_id -ne 'fake' -or $sourceMap.Count -ne 1) {
    throw 'Fake adapter received an invalid contract.'
}
if (-not (Test-Path -LiteralPath (Join-Path $sourceMap[0].path 'evidence.txt'))) {
    throw 'Exact source checkout is missing evidence.txt.'
}
if ($job.mode -eq 'fail') {
    exit 7
}
Set-Content -LiteralPath (Join-Path $ArtifactDirectory 'fake-result.txt') `
    -Value 'fake-adapter=pass'
