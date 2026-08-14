[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Spool,

    [Parameter(Mandatory = $true)]
    [string] $RepositoryRoot,

    [Parameter(Mandatory = $true)]
    [string] $AdapterRoot,

    [Parameter(Mandatory = $true)]
    [string] $RelayRoot
)

$ErrorActionPreference = 'Stop'
$relayPath = Join-Path $RelayRoot 'windows.ps1'
New-Item -ItemType Directory -Force -Path $Spool, (Join-Path $Spool 'jobs'),
    (Join-Path $Spool 'bundles'), (Join-Path $Spool 'results'),
    (Join-Path $Spool 'logs'), (Join-Path $Spool 'artifacts'),
    $RepositoryRoot, $AdapterRoot, $RelayRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows.ps1') `
    -Destination $relayPath -Force
Write-Output "Installed the Windows relay at $relayPath."
Write-Output 'The host controller invokes it in the logged-in user session.'
