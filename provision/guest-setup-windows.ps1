<#
Configure a Windows 11 ARM64 guest (already installed from the seed and
reachable over SSH) as an evidence baseline. Run elevated, as the evidence
user, from a logged-in session. Idempotent. See docs/PROVISIONING.md.

  powershell -ExecutionPolicy Bypass -File guest-setup-windows.ps1 -RelayDir C:\path\to\relay

winget needs a real user session; it is unreliable from SYSTEM (prlctl exec).
The OpenSSH default shell is deliberately NOT changed: it must stay cmd.exe.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $RelayDir
)

$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script elevated.'
}
if (-not (Test-Path (Join-Path $RelayDir 'install-windows.ps1'))) {
    throw "No install-windows.ps1 in $RelayDir"
}
$userHome = $env:USERPROFILE

function Install-Winget([string] $Id, [string[]] $Extra = @()) {
    $listed = winget list --id $Id --exact --accept-source-agreements 2>&1 | Out-String
    if ($listed -match [regex]::Escape($Id)) { Write-Output "$Id already installed"; return }
    winget install --id $Id --exact --silent --disable-interactivity `
        --accept-package-agreements --accept-source-agreements @Extra
    # 0x8A150109 / -1978335189 = "already installed / no applicable upgrade"
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        throw "winget install $Id failed with exit code $LASTEXITCODE"
    }
}

# Power: no sleep, display-off, or hibernate inside a qualified baseline.
powercfg.exe /change standby-timeout-ac 0
powercfg.exe /change monitor-timeout-ac 0
powercfg.exe /hibernate off

# Tools.
Install-Winget 'Git.Git'
Install-Winget 'jqlang.jq'
Install-Winget 'Rustlang.Rustup'

# Visual Studio 2022 Build Tools: ARM64 + x64 MSVC, Clang (LLVM), Windows 11 SDK.
# cc-rs on MSVC targets needs clang-cl, not plain clang.
$vsComponents = @(
    'Microsoft.VisualStudio.Workload.VCTools',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    'Microsoft.VisualStudio.Component.VC.Tools.ARM64',
    'Microsoft.VisualStudio.Component.VC.Llvm.Clang',
    'Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset',
    'Microsoft.VisualStudio.Component.Windows11SDK.26100'
)
$vsRoot = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools"
$clang = Get-ChildItem -Path $vsRoot -Recurse -Filter clang-cl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $clang) {
    $override = '--quiet --wait --norestart ' + (($vsComponents | ForEach-Object { "--add $_" }) -join ' ')
    Install-Winget 'Microsoft.VisualStudio.2022.BuildTools' @('--override', $override)
}

# Rust toolchain: the native ARM64 MSVC host.
$rustup = Join-Path $userHome '.cargo\bin\rustup.exe'
if (-not (Test-Path $rustup)) { throw "rustup not found at $rustup; open a new session and rerun." }
& $rustup toolchain install stable-aarch64-pc-windows-msvc --profile minimal -c clippy,rustfmt
& $rustup default stable-aarch64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw 'rustup default failed' }

# Graphical-session relay.
& (Join-Path $RelayDir 'install-windows.ps1') `
    -Spool (Join-Path $userHome 'vm-evidence-spool') `
    -RepositoryRoot (Join-Path $userHome 'vm-evidence-sources') `
    -AdapterRoot (Join-Path $userHome '.local\share\vm-evidence-adapters') `
    -RelayRoot (Join-Path $userHome '.local\share\vm-evidence-lab')

# OpenSSH must keep cmd.exe as its default shell (the controller wraps commands
# in powershell.exe -Command).
$shell = (Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -ErrorAction SilentlyContinue).DefaultShell
if ($shell -and $shell -notmatch 'cmd\.exe$') {
    Remove-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell
    Write-Warning "Reset OpenSSH DefaultShell (was $shell)"
}

# Verify so a bad baseline fails here, not during a qualification run.
$clang = Get-ChildItem -Path $vsRoot -Recurse -Filter clang-cl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $clang) { throw 'clang-cl.exe missing from the VS Build Tools install' }
$env:Path = "$userHome\.cargo\bin;$env:Path;$env:ProgramFiles\Git\cmd;$env:LOCALAPPDATA\Microsoft\WinGet\Links"
foreach ($tool in 'git', 'jq', 'cargo') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "missing $tool" }
}
if ((& rustc -vV | Out-String) -notmatch 'host: aarch64-pc-windows-msvc') { throw 'Rust host is not aarch64-pc-windows-msvc' }
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) { throw 'sshd is not installed' }
Write-Output 'guest-setup-windows: complete'
