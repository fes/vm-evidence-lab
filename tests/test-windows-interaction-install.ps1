[CmdletBinding()]
param([string] $ControllerPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'host\controller.sh'))

$ErrorActionPreference = 'Stop'
$lines = @(Get-Content -LiteralPath $ControllerPath | Where-Object {
    $_ -match 'Move-Item -LiteralPath.*\.driver\.ps1\.partial.*-SelfTest'
})
if ($lines.Count -ne 1) { throw 'Expected one Windows installer self-test command.' }
$template = $lines[0].Trim().Trim('"').Replace('\$', '$').Replace('\\', '\')
$work = Join-Path ([IO.Path]::GetTempPath()) ('interaction install ' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $command = $template.Replace('$root', $work)
    foreach ($expected in @(0, 19)) {
        @"
param([switch]`$SelfTest)
if (-not `$SelfTest) { exit 31 }
if ((Get-ExecutionPolicy) -ne 'Bypass') { exit 32 }
exit $expected
"@ | Set-Content -LiteralPath (Join-Path $work '.driver.ps1.partial')
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Restricted -Command $command
        if ($LASTEXITCODE -ne $expected) {
            throw "Installer did not preserve child self-test exit $expected (got $LASTEXITCODE)."
        }
    }
    # A failed promotion must not run an older installed driver successfully.
    $marker = Join-Path $work 'stale-driver-ran'
    "Set-Content -LiteralPath '$marker' -Value stale; exit 0" |
        Set-Content -LiteralPath (Join-Path $work 'driver.ps1')
    $previous = $ErrorActionPreference
    try {
        # Windows PowerShell promotes native stderr under Stop, even when redirected.
        $ErrorActionPreference = 'Continue'
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Restricted -Command $command 2>$null
        $promotionExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($promotionExit -eq 0 -or (Test-Path -LiteralPath $marker)) {
        throw 'Installer accepted a failed promotion or ran the stale driver.'
    }
    Write-Output 'Windows interaction installer regression passed (restricted parent, child exits, promotion failure).'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
