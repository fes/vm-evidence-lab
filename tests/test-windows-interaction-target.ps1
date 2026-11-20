[CmdletBinding()]
param([string] $DriverPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'interaction\windows\driver.ps1'))
$ErrorActionPreference = 'Stop'
# Exercise the production selector with deterministic native metadata, without
# querying a desktop, focusing a window, or sending input.
Add-Type -TypeDefinition @'
using System;
public static class EvidenceNative {
 public struct RECT { public int Left, Top, Right, Bottom; }
 public static int Mode = 0;
 public static IntPtr[] WindowsForPid(int pid) { return new [] {new IntPtr(1),new IntPtr(2),new IntPtr(3)}; }
 public static int WindowPid(IntPtr h) { return 123; }
 public static bool Visible(IntPtr h) { return Mode!=2 && (h.ToInt32()==2 || (Mode==1 && h.ToInt32()==3)); }
 public static bool Foreground(IntPtr h) { return h.ToInt32()==2; }
 public static bool Rectangle(IntPtr h,out RECT r) { r=new RECT(); if(h.ToInt32()!=1) {r.Right=400;r.Bottom=300;} return true; }
}
'@
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($DriverPath,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Driver parse failure' }
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-TargetState'},$true)
if ($null -eq $function) { throw 'Missing production selector' }
. ([ScriptBlock]::Create($function.Extent.Text))
$session=[pscustomobject]@{target=[pscustomobject]@{pid=123}}
$state=Get-TargetState $session
if ($state.Handle.ToInt32() -ne 2 -or -not $state.Visible) { throw 'Hidden first HWND selected' }
[EvidenceNative]::Mode=1
$refused=$false
try { Get-TargetState $session | Out-Null } catch { $refused=$_.Exception.Message -like '*exactly one visible*' }
if (-not $refused) { throw 'Ambiguous visible windows accepted' }
# The diagnostic fallback must preserve a structured failure, never assign
# PowerShell's read-only automatic $PID variable.
foreach ($name in @('Test-IntegerInRange','Get-TargetDiagnostics')) {
    $node=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([ScriptBlock]::Create($node.Extent.Text))
}
$diagnostic=Get-TargetDiagnostics $session
if ($diagnostic.pid -ne 123 -or $diagnostic.window_found) { throw 'Ambiguous target diagnostic fallback failed' }
$session.target | Add-Member -NotePropertyName window_index -NotePropertyValue 0
$state=Get-TargetState $session
if ($state.Handle.ToInt32() -ne 1 -or $state.Visible) { throw 'Explicit index semantics changed' }
$session.target.window_index=9
if ((Get-TargetState $session).Found) { throw 'Missing explicit window accepted' }
$session.target.PSObject.Properties.Remove('window_index')
[EvidenceNative]::Mode=2
$refused=$false
try { Get-TargetState $session | Out-Null } catch { $refused=$_.Exception.Message -like '*exactly one visible*' }
if (-not $refused) { throw 'Missing visible target accepted' }
Write-Output 'Windows target selector regression passed (hidden default, ambiguity, explicit index, missing index).'

# Execute the actual screenshot return statement with bounded metadata fixtures.
# Its caller collects pipeline output with @(); an extra unary comma nests it.
$capture=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Capture-Screenshot'},$true)
$return=$capture.Body.Find({param($node) $node -is [Management.Automation.Language.ReturnStatementAst]},$true)
$Command=[pscustomobject]@{artifact=[pscustomobject]@{name='fixture.png'}}
$paths=[pscustomobject]@{Final='C:\private\fixture.png'}
$item=[pscustomobject]@{Length=123}
$sha='a'*64
$artifacts=@(& ([ScriptBlock]::Create($return.Extent.Text)))
$result=([ordered]@{artifacts=$artifacts}|ConvertTo-Json -Depth 8 -Compress)|ConvertFrom-Json
if ($result.artifacts.Count -ne 1 -or $result.artifacts[0] -isnot [pscustomobject] -or
    $result.artifacts[0].name -ne 'fixture.png' -or $result.artifacts[0].size -ne 123 -or
    $result.artifacts[0].sha256 -cne $sha) { throw 'Screenshot artifact result is nested or malformed' }
Write-Output 'Windows screenshot artifact shape regression passed.'
