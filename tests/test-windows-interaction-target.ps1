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
 public static int ClickCase, DownCount, UpCount, FocusCalls, MovementOnly, LastUpFlags;
 public static int CursorX,CursorY;
 public static int OwnerPid = 123;
 public static bool Background, ForeignChild, Exited, Disposed;
 public static IntPtr Hit = new IntPtr(2);
 public class Lifetime : IDisposable {
  public int Id { get { return 123; } }
  public bool HasExited { get { return Exited; } }
  public void Dispose() { Disposed=true; }
 }
 public static Lifetime RetainProcess(int pid) { if(pid!=123) throw new InvalidOperationException("wrong lifetime"); return new Lifetime(); }
 public static bool Focus(IntPtr h) { FocusCalls++; return false; }
 public static IntPtr HitWindow(int x,int y) { return Hit; }
 public static bool Cursor(out int x,out int y) { x=CursorX;y=CursorY;return true; }
 public static bool HitOwnedWindow(int x,int y,int pid,IntPtr root) { return Hit==root && !ForeignChild && OwnerPid==pid; }
 public static void Pointer(int x,int y,uint flags,uint data) {
  if(flags==0) MovementOnly++;
  if(flags==2 || flags==8) {
   DownCount++; Background=false;CursorX=x;CursorY=y;
   if(ClickCase==2 || ClickCase==8) Hit=new IntPtr(99);
   if(ClickCase==3) Exited=true;
   if(ClickCase==4) Mode=3;
   if(ClickCase==6) throw new InvalidOperationException("simulated down failure");
   if(ClickCase==10) OwnerPid=456;
   if(ClickCase==12) CursorX=99;
  }
 }
 public static void ReleasePointerButton(uint flags) {
  UpCount++; LastUpFlags=(int)flags;
  if(ClickCase==5) Hit=new IntPtr(99);
  if(ClickCase==13) CursorX=99;
  if(ClickCase==7 || ClickCase==8) throw new InvalidOperationException("simulated release failure");
 }
 public static void ReleaseModifiers() {}
 public static void Reset() { Mode=0;ClickCase=0;DownCount=0;UpCount=0;FocusCalls=0;MovementOnly=0;LastUpFlags=0;OwnerPid=123;Background=true;ForeignChild=false;Exited=false;Disposed=false;Hit=new IntPtr(2);CursorX=0;CursorY=0; }

 public static IntPtr[] WindowsForPid(int pid) { return Mode==3 ? new [] {new IntPtr(3)} : new [] {new IntPtr(1),new IntPtr(2),new IntPtr(3)}; }
 public static int WindowPid(IntPtr h) { return OwnerPid; }
 public static bool Visible(IntPtr h) { return Mode!=2 && (h.ToInt32()==2 || ((Mode==1 || Mode==3) && h.ToInt32()==3)); }
 public static bool Foreground(IntPtr h) { return !Background && h.ToInt32()==2; }
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

# Exercise the production dispatcher and click guards with native calls replaced
# by counters. No desktop, real process, or SendInput is used by these fixtures.
foreach ($name in @('Assert-Target','Focus-Target','Convert-Point','Assert-CommandDeadline',
                     'Get-OperationGrant','Send-Click','Assert-ClickCursor','Resolve-ClickPoint','Invoke-Interaction')) {
    $node=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if ($null -eq $node) { throw "Missing production function $name" }
    . ([ScriptBlock]::Create($node.Extent.Text))
}
$script:CommandDeadline=$null
$script:UnexpectedKeyboardDispatch=$false
function Send-KeyCommand { param($Key) $script:UnexpectedKeyboardDispatch=$true }
$session=[pscustomobject]@{target=[pscustomobject]@{pid=123};grants=@('pointer')}
$point=[pscustomobject]@{x=20;y=30;coordinate_space='physical-screen'}
function Invoke-ClickFixture {
    param([int] $Case=0,[int] $Repeat=1,[string] $Button='primary')
    [EvidenceNative]::Reset();[EvidenceNative]::ClickCase=$Case
    if ($Case -eq 1) { [EvidenceNative]::Hit=[IntPtr]::new(99) }
    if ($Case -eq 9) { [EvidenceNative]::Exited=$true }
    if ($Case -eq 11) { [EvidenceNative]::ForeignChild=$true }
    $command=[pscustomobject]@{operation=$(if($Repeat -eq 2){'double-click'}else{'click'});point=$point;button=$Button;duration_ms=0}
    $failure=''
    try { $null=Invoke-Interaction $session $command '' } catch { $failure=$_.Exception.Message }
    return $failure
}
$failure=Invoke-ClickFixture
if ($failure -or [EvidenceNative]::DownCount -ne 1 -or [EvidenceNative]::UpCount -ne 1 -or
    [EvidenceNative]::FocusCalls -ne 0 -or [EvidenceNative]::MovementOnly -ne 0 -or
    -not [EvidenceNative]::Disposed -or [EvidenceNative]::LastUpFlags -ne 4) {
    throw 'Explicit background owned click did not activate with one balanced click'
}
foreach ($caseNumber in @(1,9,11)) {
    $failure=Invoke-ClickFixture $caseNumber
    if (-not $failure -or [EvidenceNative]::DownCount -ne 0 -or [EvidenceNative]::UpCount -ne 0 -or
        -not [EvidenceNative]::Disposed) { throw "Unsafe pre-down case $caseNumber accepted" }
}
foreach ($caseNumber in @(2,3,4,6,10,12)) {
    $failure=Invoke-ClickFixture $caseNumber
    if (-not $failure -or [EvidenceNative]::DownCount -ne 1 -or [EvidenceNative]::UpCount -ne 1 -or
        [EvidenceNative]::MovementOnly -ne 0 -or -not [EvidenceNative]::Disposed) {
        throw "Post-down change $caseNumber did not release without another movement"
    }
}
foreach ($caseNumber in @(5,13)) {
    $failure=Invoke-ClickFixture -Case $caseNumber -Repeat 2
    if (-not $failure -or [EvidenceNative]::DownCount -ne 1 -or [EvidenceNative]::UpCount -ne 1) {
        throw 'Double-click sent a second down after ownership or cursor changed'
    }
}
$failure=Invoke-ClickFixture -Button secondary
if ($failure -or [EvidenceNative]::LastUpFlags -ne 16) { throw 'Secondary click cleanup released wrong button' }
$failure=Invoke-ClickFixture -Case 8
if ($failure -notlike '*native hit-test*matching button release also failed*' -or
    [EvidenceNative]::UpCount -ne 1 -or -not [EvidenceNative]::Disposed) {
    throw 'Release failure hid the first ownership failure or leaked lifetime'
}
[EvidenceNative]::Reset();$session.grants=@()
$command=[pscustomobject]@{operation='click';point=$point}
$failure=''
try { $null=Invoke-Interaction $session $command '' } catch { $failure=$_.Exception.Message }
if ($failure -notlike '*not granted*' -or [EvidenceNative]::DownCount -ne 0) { throw 'Click bypassed pointer grant' }
foreach ($operation in @('key','text','move','drag','scroll')) {
    [EvidenceNative]::Reset()
    $session.grants=@('keyboard','pointer','wheel')
    $command=[pscustomobject]@{operation=$operation;point=$point}
    $failure=''
    try { $null=Invoke-Interaction $session $command '' } catch { $failure=$_.Exception.Message }
    if ($failure -notlike '*foreground*' -or [EvidenceNative]::FocusCalls -ne 1 -or
        [EvidenceNative]::DownCount -ne 0 -or $script:UnexpectedKeyboardDispatch) {
        throw "$operation stopped requiring foreground ownership"
    }
}
Write-Output 'Windows click regression passed (background, grants, occlusion, foreign child, lifetime, balanced release, foreground-only inputs).'

# Compile only the production release method against an in-memory Send spy.
# This verifies cleanup cannot add movement/absolute-position flags or coordinates.
$text=Get-Content -LiteralPath $DriverPath -Raw
$start=$text.IndexOf('    public static void ReleasePointerButton(uint flags)')
$end=$text.IndexOf('    public static void ReleaseModifiers()', $start)
if ($start -lt 0 -or $end -lt 0) { throw 'Missing production button release boundary' }
$method=$text.Substring($start,$end-$start)
$boundary=@'
public static class ReleaseBoundary {
 public struct Mouse { public uint dwFlags; public int dx,dy; }
 public struct Union { public Mouse mi; }
 public struct INPUT { public int type; public Union U; }
 public static uint Flags;
 public static int X,Y,Type,Calls;
 static void Send(INPUT[] values) { Calls++;Flags=values[0].U.mi.dwFlags;X=values[0].U.mi.dx;Y=values[0].U.mi.dy;Type=values[0].type; }
 __METHOD__
}
'@
Add-Type -TypeDefinition ($boundary.Replace('__METHOD__',$method))
[ReleaseBoundary]::ReleasePointerButton(4)
if ([ReleaseBoundary]::Calls -ne 1 -or [ReleaseBoundary]::Flags -ne 4 -or
    [ReleaseBoundary]::X -ne 0 -or [ReleaseBoundary]::Y -ne 0 -or [ReleaseBoundary]::Type -ne 0) {
    throw 'Failure cleanup moved the pointer or sent extra input'
}
Write-Output 'Windows button-only release boundary regression passed.'
