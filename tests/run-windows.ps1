$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root '.test-work\windows'

if (Test-Path -LiteralPath $work) {
    Remove-Item -LiteralPath $work -Recurse -Force
}
try {
    $spool = Join-Path $work 'spool'
    $source = Join-Path $work 'source'
    $repositoryRoot = Join-Path $work 'repositories'
    $adapterRoot = Join-Path $work 'adapters'
    $adapterPath = Join-Path $adapterRoot 'fake'
    New-Item -ItemType Directory -Force -Path `
        (Join-Path $spool 'jobs'), (Join-Path $spool 'bundles'),
        $source, $repositoryRoot, $adapterPath | Out-Null

    Copy-Item -LiteralPath (Join-Path $root 'tests\fixtures\fake-adapter\policy.json') `
        -Destination (Join-Path $adapterPath 'policy.json')
    Copy-Item -LiteralPath (Join-Path $root 'tests\fixtures\fake-adapter\windows.ps1') `
        -Destination (Join-Path $adapterPath 'windows.ps1')
    Set-Content -LiteralPath (Join-Path $adapterPath 'adapter-version.txt') `
        -Value ('0' * 40) -NoNewline

    & git init -q $source
    & git -C $source config user.name vm-evidence-test
    & git -C $source config user.email vm-evidence-test@example.invalid
    Set-Content -LiteralPath (Join-Path $source 'evidence.txt') -Value 'exact source'
    & git -C $source add evidence.txt
    & git -C $source commit -qm 'Create test source'
    $sha = (& git -C $source rev-parse HEAD).Trim()
    $bundlePath = Join-Path $spool 'bundles\pass.bundle'
    & git -C $source bundle create $bundlePath --all

    [ordered]@{
        schema_version = 1
        run_id = 'pass-run'
        adapter_id = 'fake'
        adapter_sha = '0000000000000000000000000000000000000000'
        adapter_schema_version = 1
        mode = 'pass'
        platform = 'windows'
        sources = @(
            [ordered]@{
                id = 'product'
                sha = $sha
                bundle = 'pass.bundle'
            }
        )
        payload = [ordered]@{}
    } | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $spool 'jobs\pass.json')

    & (Join-Path $root 'relay\windows.ps1') `
        -Spool $spool `
        -RepositoryRoot $repositoryRoot `
        -AdapterRoot $adapterRoot `
        -Platform windows

    $result = Get-Content -Raw -LiteralPath `
        (Join-Path $spool 'results\pass-run.json') | ConvertFrom-Json
    if ($result.status -ne 'pass' -or
        $result.resolved_sources[0].resolved_sha -ne $sha) {
        throw 'Windows relay did not preserve exact-SHA evidence.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $spool 'jobs\processed-pass.json'))) {
        throw 'Windows relay did not atomically process the job.'
    }

    $mismatchJob = Get-Content -Raw -LiteralPath `
        (Join-Path $spool 'jobs\processed-pass.json') | ConvertFrom-Json
    $mismatchJob.run_id = 'adapter-mismatch-run'
    $mismatchJob.adapter_sha = '1' * 40
    $mismatchJob | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $spool 'jobs\adapter-mismatch.json')
    & (Join-Path $root 'relay\windows.ps1') `
        -Spool $spool `
        -RepositoryRoot $repositoryRoot `
        -AdapterRoot $adapterRoot `
        -Platform windows
    $mismatchResult = Get-Content -Raw -LiteralPath `
        (Join-Path $spool 'results\adapter-mismatch-run.json') | ConvertFrom-Json
    if ($mismatchResult.status -ne 'fail' -or
        $mismatchResult.failure_class -ne 'infrastructure') {
        throw 'Windows relay accepted a mismatched adapter revision.'
    }

    foreach ($script in 'relay\windows.ps1', 'relay\install-windows.ps1') {
        [scriptblock]::Create(
            (Get-Content -Raw -LiteralPath (Join-Path $root $script))
        ) | Out-Null
    }

    python (Join-Path $root 'tests\test_contract.py')
    if ($LASTEXITCODE -ne 0) {
        throw 'Schema contract tests failed.'
    }
    Write-Output 'Windows contract tests passed.'
} finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
