[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Spool,

    [Parameter(Mandatory = $true)]
    [string] $RepositoryRoot,

    [Parameter(Mandatory = $true)]
    [string] $AdapterRoot,

    [Parameter(Mandatory = $true)]
    [ValidateSet('windows')]
    [string] $Platform
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-ExactProperties {
    param(
        [object] $Value,
        [string[]] $Names
    )

    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    $actual.Count -eq $expected.Count -and
        -not (Compare-Object $actual $expected)
}

function Invoke-NativeCommand {
    # Native commands (git, cargo, etc.) routinely write normal progress output
    # to stderr. With $ErrorActionPreference = 'Stop', PowerShell promotes that
    # stderr text into a script-terminating error regardless of stream
    # redirection. Temporarily relax the preference so callers can rely on
    # $LASTEXITCODE (as this script already does) to detect real failures.
    param([scriptblock] $Command)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Test-Identifier {
    param([object] $Value)
    $Value -is [string] -and $Value -match '^[a-z][a-z0-9-]{0,63}$'
}

function Test-FullSha {
    param([object] $Value)
    $Value -is [string] -and $Value -match '^([0-9a-f]{40}|[0-9a-f]{64})$'
}

function Test-RelayJob {
    param([object] $Job)

    if (-not (Test-ExactProperties $Job @(
        'schema_version', 'run_id', 'adapter_id', 'adapter_sha', 'adapter_schema_version',
        'mode', 'platform', 'sources', 'payload'
    ))) {
        return $false
    }
    if ($Job.schema_version -ne 1 -or
        $Job.run_id -isnot [string] -or
        $Job.run_id -notmatch '^[A-Za-z0-9._-]{1,128}$' -or
        -not (Test-Identifier $Job.adapter_id) -or
        -not (Test-FullSha $Job.adapter_sha) -or
        ($Job.adapter_schema_version -isnot [long] -and
            $Job.adapter_schema_version -isnot [int]) -or
        $Job.adapter_schema_version -lt 1 -or
        -not (Test-Identifier $Job.mode) -or
        $Job.platform -ne $Platform -or
        $Job.sources -isnot [array] -or
        $Job.sources.Count -gt 8 -or
        $Job.payload -isnot [pscustomobject]) {
        return $false
    }

    $ids = @{}
    $bundles = @{}
    foreach ($source in $Job.sources) {
        if (-not (Test-ExactProperties $source @('id', 'sha', 'bundle')) -or
            -not (Test-Identifier $source.id) -or
            -not (Test-FullSha $source.sha) -or
            $source.bundle -isnot [string] -or
            $source.bundle -notmatch '^[A-Za-z0-9._-]{1,128}\.bundle$' -or
            $ids.ContainsKey($source.id) -or
            $bundles.ContainsKey($source.bundle)) {
            return $false
        }
        $ids[$source.id] = $true
        $bundles[$source.bundle] = $true
    }
    return $true
}

function Test-AdapterPolicy {
    param([object] $Job)

    if ($Job.adapter_id -eq 'infrastructure') {
        return $Job.mode -eq 'readiness-probe' -and $Job.sources.Count -eq 0
    }
    $policyPath = Join-Path (Join-Path $AdapterRoot $Job.adapter_id) 'policy.json'
    $versionPath = Join-Path (Join-Path $AdapterRoot $Job.adapter_id) 'adapter-version.txt'
    if (-not (Test-Path -LiteralPath $policyPath) -or
        -not (Test-Path -LiteralPath $versionPath) -or
        (Get-Content -Raw -LiteralPath $versionPath).Trim() -ne $Job.adapter_sha) {
        return $false
    }
    $policy = Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json
    Test-ExactProperties $policy @(
        'adapter_id', 'schema_version', 'modes', 'platforms'
    ) -and
        $policy.adapter_id -eq $Job.adapter_id -and
        $policy.schema_version -eq $Job.adapter_schema_version -and
        $policy.modes -contains $Job.mode -and
        $policy.platforms -contains $Platform
}

function Write-RelayResult {
    param(
        [string] $Path,
        [object] $Job,
        [string] $Status,
        [string] $Phase,
        [AllowNull()]
        [string] $FailureClass,
        [string] $Message,
        [array] $ResolvedSources
    )

    [ordered]@{
        schema_version = 1
        run_id = $Job.run_id
        status = $Status
        phase = $Phase
        failure_class = $FailureClass
        message = $Message
        adapter_id = $Job.adapter_id
        adapter_sha = $Job.adapter_sha
        adapter_schema_version = $Job.adapter_schema_version
        mode = $Job.mode
        platform = $Platform
        resolved_sources = @($ResolvedSources)
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 8 -Compress |
        Set-Content -LiteralPath "$Path.partial" -NoNewline
    if (Test-Path -LiteralPath $Path) {
        $partialPath = (Get-Item -LiteralPath "$Path.partial").FullName
        $destinationPath = (Get-Item -LiteralPath $Path).FullName
        $backupPath = "$destinationPath.backup"
        $replaceDeadline = (Get-Date).AddSeconds(5)
        while ($true) {
            try {
                Remove-Item -LiteralPath $backupPath -Force -ErrorAction Ignore
                [System.IO.File]::Replace($partialPath, $destinationPath, $backupPath)
                break
            } catch [System.IO.IOException] {
                if ((Get-Date) -ge $replaceDeadline) {
                    throw
                }
                Start-Sleep -Milliseconds 50
            }
        }
        Remove-Item -LiteralPath $backupPath -Force
    } else {
        Move-Item -LiteralPath "$Path.partial" -Destination $Path
    }
}

function Stage-Sources {
    param(
        [object] $Job,
        [string] $SourceMapPath
    )

    $sourceMap = @()
    $resolved = @()
    foreach ($source in $Job.sources) {
        $bundlePath = Join-Path (Join-Path $Spool 'bundles') $source.bundle
        $checkoutPath = Join-Path $RepositoryRoot $source.id
        if (-not (Test-Path -LiteralPath $bundlePath)) {
            throw "Source bundle is missing: $($source.bundle)"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $checkoutPath '.git'))) {
            Invoke-NativeCommand { & git clone $bundlePath $checkoutPath *> $null }
        } else {
            Invoke-NativeCommand { & git -C $checkoutPath fetch $bundlePath $source.sha *> $null }
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Could not fetch source: $($source.id)"
        }
        Invoke-NativeCommand { & git -C $checkoutPath checkout --detach --force $source.sha *> $null }
        if ($LASTEXITCODE -ne 0) {
            throw "Could not check out source: $($source.id)"
        }
        $resolvedSha = (Invoke-NativeCommand { & git -C $checkoutPath rev-parse HEAD }).Trim()
        if ($LASTEXITCODE -ne 0 -or $resolvedSha -ne $source.sha) {
            throw "Resolved SHA differs from requested SHA: $($source.id)"
        }
        $sourceMap += [ordered]@{
            id = $source.id
            sha = $resolvedSha
            path = $checkoutPath
        }
        $resolved += [ordered]@{
            id = $source.id
            requested_sha = $source.sha
            resolved_sha = $resolvedSha
        }
    }
    $sourceMap | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath "$SourceMapPath.partial" -NoNewline
    Move-Item -LiteralPath "$SourceMapPath.partial" -Destination $SourceMapPath -Force
    return ,$resolved
}

$jobsPath = Join-Path $Spool 'jobs'
$bundlesPath = Join-Path $Spool 'bundles'
$logsPath = Join-Path $Spool 'logs'
$resultsPath = Join-Path $Spool 'results'
$artifactsPath = Join-Path $Spool 'artifacts'
$locksPath = Join-Path $jobsPath '.locks'
New-Item -ItemType Directory -Force -Path $jobsPath, $bundlesPath, $logsPath,
    $resultsPath, $artifactsPath, $locksPath, $RepositoryRoot | Out-Null

Get-ChildItem -LiteralPath $jobsPath -Filter '*.json' -File |
    Where-Object {
        $_.Name -notlike '.running-*' -and
        $_.Name -notlike 'processed-*' -and
        $_.Name -notlike 'rejected-*' -and
        $_.Name -notlike 'infrastructure-failed-*'
    } |
    Sort-Object Name |
    ForEach-Object {
        $queuedPath = $_.FullName
        $lockPath = Join-Path $locksPath $_.Name
        $claimedPath = Join-Path $jobsPath ".running-$($_.Name)"
        $relayPidPath = $null
        try {
            New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
        } catch {
            return
        }
        try {
            Move-Item -LiteralPath $queuedPath -Destination $claimedPath -ErrorAction Stop
        } catch {
            Remove-Item -LiteralPath $lockPath -Force
            return
        }

        $accepted = $false
        try {
            $job = Get-Content -Raw -LiteralPath $claimedPath | ConvertFrom-Json
            if (-not (Test-RelayJob $job)) {
                throw 'Job does not satisfy the common schema.'
            }
            $resultPath = Join-Path $resultsPath "$($job.run_id).json"
            if (Test-Path -LiteralPath $resultPath) {
                throw "Result already exists for run ID: $($job.run_id)"
            }
            $accepted = $true
            $logPath = Join-Path $logsPath "$($job.run_id).log"
            $artifactPath = Join-Path $artifactsPath $job.run_id
            $sourceMapPath = Join-Path $artifactPath 'source-map.json'
            $relayPidPath = Join-Path $artifactPath 'relay.pid'
            $resolvedSources = @()
            New-Item -ItemType Directory -Force -Path $artifactPath | Out-Null
            Set-Content -LiteralPath "$relayPidPath.partial" -Value $PID -NoNewline
            Move-Item -LiteralPath "$relayPidPath.partial" -Destination $relayPidPath -Force
            Write-RelayResult $resultPath $job 'running' 'queued' $null 'relay accepted job' @()

            try {
                Write-RelayResult $resultPath $job 'running' 'preflight' $null `
                    'validating installed adapter policy' @()
                if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
                    throw 'Missing required guest command: git'
                }
                if (-not (Test-AdapterPolicy $job)) {
                    throw 'Installed adapter policy rejected the job.'
                }
                if ($job.adapter_id -eq 'infrastructure') {
                    Write-RelayResult $resultPath $job 'pass' 'complete' $null `
                        'relay readiness passed' @()
                } else {
                    Write-RelayResult $resultPath $job 'running' 'checkout' $null `
                        'staging exact source revisions' @()
                    $resolvedSources = @(Stage-Sources $job $sourceMapPath)
                    $adapterPath = Join-Path (Join-Path $AdapterRoot $job.adapter_id) 'windows.ps1'
                    if (-not (Test-Path -LiteralPath $adapterPath)) {
                        throw "Installed adapter is missing: $($job.adapter_id)"
                    }
                    Write-RelayResult $resultPath $job 'running' 'adapter' $null `
                        'running installed product adapter' $resolvedSources
                    try {
                        Invoke-NativeCommand {
                            & $adapterPath -JobPath $claimedPath `
                                -SourceMapPath $sourceMapPath `
                                -ArtifactDirectory $artifactPath *>> $logPath
                        }
                        if ($LASTEXITCODE -ne 0) {
                            throw "Product adapter exited with status $LASTEXITCODE"
                        }
                    } catch {
                        $_ | Out-String | Add-Content -LiteralPath $logPath
                        Write-RelayResult $resultPath $job 'fail' 'complete' 'product' `
                            "evidence failed; inspect $logPath" $resolvedSources
                        throw
                    }
                    Write-RelayResult $resultPath $job 'pass' 'complete' $null `
                        'adapter evidence passed' $resolvedSources
                }
            } catch {
                if ((Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json).status -ne 'fail') {
                    $_ | Out-String | Add-Content -LiteralPath $logPath
                    Write-RelayResult $resultPath $job 'fail' 'complete' 'infrastructure' `
                        "evidence failed; inspect $logPath" $resolvedSources
                }
            }
        } catch {
            if ($accepted) {
                $_ | Out-String | Add-Content -LiteralPath $logPath
            }
        } finally {
            if ($relayPidPath) {
                Remove-Item -LiteralPath $relayPidPath -Force -ErrorAction Ignore
            }
            $prefix = if ($accepted) { 'processed-' } else { 'rejected-' }
            Move-Item -LiteralPath $claimedPath `
                -Destination (Join-Path $jobsPath "$prefix$($_.Name)") -Force
            Remove-Item -LiteralPath $lockPath -Force
        }
    }
