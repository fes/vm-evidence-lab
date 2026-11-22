#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $SessionPath,
    [string] $CommandPath,
    [string] $ArtifactDirectory,
    [string] $ResultPath,
    [string] $Operation,
    [switch] $SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DriverName = 'vm-evidence-lab/interaction-windows-uia-v1'
$script:Platform = 'windows'
$script:IdentifierPattern = '^[A-Za-z0-9._-]{1,128}$'
$script:ArtifactPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
$script:Operations = @(
    'capabilities', 'observe', 'focus', 'key', 'text', 'move', 'click',
    'double-click', 'drag', 'scroll', 'wait', 'screenshot',
    'clipboard-set-sentinel', 'video-start', 'video-stop'
)
$script:Grants = @(
    'observe', 'keyboard', 'pointer', 'wheel', 'accessibility',
    'screenshot', 'video', 'clipboard-sentinel', 'fixture-files'
)

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class EvidenceNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    [StructLayout(LayoutKind.Sequential)] public struct RECT {
        public int Left, Top, Right, Bottom;
    }
    [StructLayout(LayoutKind.Sequential)] public struct POINT {
        public int X, Y;
    }
    [StructLayout(LayoutKind.Sequential)] struct CURSORINFO {
        public uint Size, Flags;
        public IntPtr Cursor;
        public POINT Position;
    }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT {
        public int dx, dy;
        public uint mouseData, dwFlags, time;
        public UIntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public UIntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)] struct HARDWAREINPUT {
        public uint uMsg;
        public ushort wParamL, wParamH;
    }
    [StructLayout(LayoutKind.Explicit)]
    struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT {
        public uint type;
        public INPUTUNION U;
    }

    delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool GetCursorInfo(ref CURSORINFO info);
    [DllImport("user32.dll", EntryPoint = "LoadCursorW", SetLastError = true)]
    static extern IntPtr LoadCursor(IntPtr instance, IntPtr name);
    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint count, INPUT[] inputs, int size);

    public static IntPtr[] WindowsForPid(int pid) {
        List<IntPtr> found = new List<IntPtr>();
        EnumWindows(delegate(IntPtr hwnd, IntPtr ignored) {
            uint process;
            GetWindowThreadProcessId(hwnd, out process);
            if (process == (uint)pid) found.Add(hwnd);
            return true;
        }, IntPtr.Zero);
        found.Sort(delegate(IntPtr a, IntPtr b) { return a.ToInt64().CompareTo(b.ToInt64()); });
        return found.ToArray();
    }
    public static int WindowPid(IntPtr hwnd) {
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        return (int)pid;
    }
    public static bool Visible(IntPtr hwnd) { return IsWindowVisible(hwnd); }
    public static bool Foreground(IntPtr hwnd) { return GetForegroundWindow() == hwnd; }
    public static bool Rectangle(IntPtr hwnd, out RECT rect) {
        return GetWindowRect(hwnd, out rect);
    }
    public static string Title(IntPtr hwnd) {
        StringBuilder value = new StringBuilder(1024);
        GetWindowText(hwnd, value, value.Capacity);
        return value.ToString();
    }
    public static bool Focus(IntPtr hwnd) {
        IntPtr foreground = GetForegroundWindow();
        uint ignored;
        uint foregroundThread = foreground == IntPtr.Zero ? 0 :
            GetWindowThreadProcessId(foreground, out ignored);
        uint targetThread = GetWindowThreadProcessId(hwnd, out ignored);
        uint currentThread = GetCurrentThreadId();
        bool first = targetThread != currentThread &&
            AttachThreadInput(currentThread, targetThread, true);
        bool second = foregroundThread != 0 && foregroundThread != currentThread &&
            AttachThreadInput(foregroundThread, targetThread, true);
        try {
            ShowWindow(hwnd, 9);
            return SetForegroundWindow(hwnd);
        } finally {
            if (second) AttachThreadInput(foregroundThread, targetThread, false);
            if (first) AttachThreadInput(currentThread, targetThread, false);
        }
    }
    static void Send(INPUT[] input) {
        if (SendInput((uint)input.Length, input, Marshal.SizeOf(typeof(INPUT))) != input.Length) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SendInput failed");
        }
    }
    public static void Key(ushort vk, bool up) {
        INPUT input = new INPUT();
        input.type = 1;
        input.U.ki.wVk = vk;
        input.U.ki.dwFlags = up ? 2u : 0u;
        Send(new INPUT[] { input });
    }
    public static void Unicode(char value, bool up) {
        INPUT input = new INPUT();
        input.type = 1;
        input.U.ki.wScan = (ushort)value;
        input.U.ki.dwFlags = (up ? 2u : 0u) | 4u;
        Send(new INPUT[] { input });
    }
    static int Normalize(int coordinate, int origin, int length) {
        if (length <= 1) return 0;
        long value = (long)(coordinate - origin) * 65535 / (length - 1);
        if (value < 0) return 0;
        if (value > 65535) return 65535;
        return (int)value;
    }
    public static void Pointer(int x, int y, uint flags, uint data) {
        INPUT input = new INPUT();
        input.type = 0;
        input.U.mi.dx = Normalize(x, GetSystemMetrics(76), GetSystemMetrics(78));
        input.U.mi.dy = Normalize(y, GetSystemMetrics(77), GetSystemMetrics(79));
        input.U.mi.dwFlags = flags | 0x0001u | 0x8000u | 0x4000u;
        input.U.mi.mouseData = data;
        Send(new INPUT[] { input });
    }
    public static bool Cursor(out int x, out int y) {
        POINT point;
        bool ok = GetCursorPos(out point);
        x = point.X;
        y = point.Y;
        return ok;
    }
    public static string ClassifyCursor(IntPtr cursor, IntPtr arrow, IntPtr horizontal,
            IntPtr vertical, IntPtr northwest, IntPtr northeast) {
        if (cursor == IntPtr.Zero || arrow == IntPtr.Zero || horizontal == IntPtr.Zero ||
                vertical == IntPtr.Zero || northwest == IntPtr.Zero || northeast == IntPtr.Zero)
            return "unknown";
        if (cursor == arrow) return "arrow";
        if (cursor == horizontal) return "size_we";
        if (cursor == vertical) return "size_ns";
        if (cursor == northwest) return "size_nwse";
        if (cursor == northeast) return "size_nesw";
        return "other";
    }
    public static bool CursorSnapshot(out int x, out int y, out bool showing,
            out string shape, out int error) {
        CURSORINFO info = new CURSORINFO();
        info.Size = (uint)Marshal.SizeOf(typeof(CURSORINFO));
        x = y = error = 0; showing = false; shape = "unknown";
        if (!GetCursorInfo(ref info)) {
            error = Marshal.GetLastWin32Error();
            return false;
        }
        x = info.Position.X; y = info.Position.Y;
        showing = (info.Flags & 1u) != 0 && (info.Flags & 2u) == 0;
        if (showing) {
            // Shared system cursors are borrowed, never destroyed or installed.
            int[] ids = new int[] { 32512, 32644, 32645, 32642, 32643 };
            IntPtr[] stock = new IntPtr[ids.Length];
            for (int i = 0; i < ids.Length; i++) {
                stock[i] = LoadCursor(IntPtr.Zero, new IntPtr(ids[i]));
                if (stock[i] == IntPtr.Zero) {
                    error = Marshal.GetLastWin32Error();
                    return false;
                }
            }
            shape = ClassifyCursor(info.Cursor, stock[0], stock[1], stock[2], stock[3], stock[4]);
        }
        return true;
    }
    public static IntPtr HitWindow(int x, int y) {
        IntPtr hit = WindowFromPoint(new POINT { X = x, Y = y });
        return hit == IntPtr.Zero ? IntPtr.Zero : GetAncestor(hit, 2);
    }
    public static bool HitOwnedWindow(int x, int y, int pid, IntPtr window) {
        IntPtr hit = WindowFromPoint(new POINT { X = x, Y = y });
        return hit != IntPtr.Zero && WindowPid(hit) == pid &&
            GetAncestor(hit, 2) == window && WindowPid(window) == pid;
    }
    public static System.Diagnostics.Process RetainProcess(int pid) {
        var process = System.Diagnostics.Process.GetProcessById(pid);
        try {
            if (process.Handle == IntPtr.Zero) throw new InvalidOperationException("Process handle unavailable");
            return process;
        } catch { process.Dispose(); throw; }
    }
    public static void ReleasePointerButton(uint flags) {
        INPUT input = new INPUT();
        input.type = 0;
        input.U.mi.dwFlags = flags;
        Send(new INPUT[] { input });
    }
    public static void ReleaseModifiers() {
        ushort[] keys = new ushort[] { 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C };
        foreach (ushort key in keys) { try { Key(key, true); } catch {} }
    }
}
'@

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Test-ExactProperties {
    param([object] $Value, [string[]] $Required, [string[]] $Optional = @())
    if ($Value -isnot [pscustomobject]) { return $false }
    $allowed = @($Required) + @($Optional)
    $actual = @($Value.PSObject.Properties.Name)
    $missing = @($Required | Where-Object { $actual -notcontains $_ })
    $unknown = @($actual | Where-Object { $allowed -notcontains $_ })
    return $missing.Count -eq 0 -and $unknown.Count -eq 0
}

function Test-IntegerInRange {
    param([object] $Value, [long] $Minimum, [long] $Maximum)
    if ($Value -isnot [long] -and $Value -isnot [int]) { return $false }
    $number = [long] $Value
    return $number -ge $Minimum -and $number -le $Maximum
}

function Test-NumberInRange {
    param([object] $Value, [double] $Minimum, [double] $Maximum)
    if ($Value -isnot [long] -and $Value -isnot [int] -and
        $Value -isnot [double] -and $Value -isnot [decimal]) { return $false }
    $number = [double] $Value
    return $number -ge $Minimum -and $number -le $Maximum
}

function Assert-ValidSession {
    param([object] $Session)
    if (-not (Test-ExactProperties $Session @(
        'schema_version', 'session_id', 'platform', 'run_id', 'target', 'grants', 'limits'
    ))) { throw 'session has missing or unknown properties' }
    if (-not (Test-IntegerInRange $Session.schema_version 1 1)) {
        throw 'unsupported session schema_version'
    }
    foreach ($name in @('session_id', 'run_id')) {
        $value = $Session.PSObject.Properties[$name].Value
        if ($value -isnot [string] -or $value -notmatch $script:IdentifierPattern) {
            throw "invalid $name"
        }
    }
    if ($Session.platform -ne $script:Platform) { throw 'session platform is not windows' }
    if (-not (Test-ExactProperties $Session.target @('pid') @('window_index'))) {
        throw 'target is invalid'
    }
    if (-not (Test-IntegerInRange $Session.target.pid 1 2147483647)) {
        throw 'target.pid is invalid'
    }
    if ($null -ne $Session.target.PSObject.Properties['window_index'] -and
        -not (Test-IntegerInRange $Session.target.window_index 0 31)) {
        throw 'target.window_index is invalid'
    }
    if ($Session.grants -isnot [array]) { throw 'grants is not an array' }
    foreach ($grant in $Session.grants) {
        if ($grant -isnot [string] -or $script:Grants -notcontains $grant) {
            throw 'grants contains an unknown value'
        }
    }
    if (@($Session.grants | Sort-Object -Unique).Count -ne @($Session.grants).Count) {
        throw 'grants contains a duplicate'
    }
    $limits = $Session.limits
    if (-not (Test-ExactProperties $limits @(
        'maximum_commands', 'command_timeout_ms', 'maximum_artifact_bytes', 'maximum_video_seconds'
    ))) { throw 'limits are invalid' }
    if (-not (Test-IntegerInRange $limits.maximum_commands 1 10000) -or
        -not (Test-IntegerInRange $limits.command_timeout_ms 100 120000) -or
        -not (Test-IntegerInRange $limits.maximum_artifact_bytes 1 1073741824) -or
        -not (Test-IntegerInRange $limits.maximum_video_seconds 1 300)) {
        throw 'limits are out of range'
    }
}

function Assert-Point {
    param([object] $Point)
    if (-not (Test-ExactProperties $Point @('x', 'y') @('coordinate_space'))) {
        throw 'point is invalid'
    }
    if (-not (Test-NumberInRange $Point.x 0 100000) -or
        -not (Test-NumberInRange $Point.y 0 100000)) { throw 'point coordinates are invalid' }
    $space = if ($Point.PSObject.Properties['coordinate_space']) {
        $Point.coordinate_space
    } else { 'physical-screen' }
    if (@('physical-screen', 'target-relative') -notcontains $space) {
        throw 'point coordinate_space is invalid'
    }
}

function Assert-ValidCommand {
    param([object] $Command)
    $payloads = @(
        'key', 'text', 'point', 'destination', 'button', 'duration_ms', 'scroll',
        'wait', 'artifact', 'clipboard', 'video'
    )
    if (-not (Test-ExactProperties $Command @(
        'schema_version', 'session_id', 'sequence', 'operation'
    ) $payloads)) { throw 'command has missing or unknown properties' }
    if (-not (Test-IntegerInRange $Command.schema_version 1 1)) {
        throw 'unsupported command schema_version'
    }
    if ($Command.session_id -isnot [string] -or
        $Command.session_id -notmatch $script:IdentifierPattern) {
        throw 'invalid command session_id'
    }
    if (-not (Test-IntegerInRange $Command.sequence 1 2147483647)) {
        throw 'invalid command sequence'
    }
    $op = $Command.operation
    if ($op -isnot [string] -or $script:Operations -notcontains $op) {
        throw 'unknown operation'
    }
    $required = switch ($op) {
        'key' { @('key') }
        'text' { @('text') }
        'move' { @('point') }
        'click' { @('point') }
        'double-click' { @('point') }
        'drag' { @('point', 'destination') }
        'scroll' { @('scroll') }
        'wait' { @('wait') }
        'screenshot' { @('artifact') }
        'clipboard-set-sentinel' { @('clipboard') }
        'video-start' { @('video') }
        'video-stop' { @() }
        default { @() }
    }
    $allowed = @('schema_version', 'session_id', 'sequence', 'operation') + $required
    if (@('click', 'double-click', 'drag') -contains $op) {
        $allowed += @('button', 'duration_ms')
    }
    foreach ($name in $required) {
        if ($null -eq $Command.PSObject.Properties[$name]) {
            throw 'operation is missing a required payload'
        }
    }
    foreach ($name in $Command.PSObject.Properties.Name) {
        if ($allowed -notcontains $name) { throw 'operation contains unrelated properties' }
    }
    if ($Command.PSObject.Properties['key']) {
        $key = $Command.key
        if (-not (Test-ExactProperties $key @('name') @('character', 'modifiers', 'phase'))) {
            throw 'key payload is invalid'
        }
        $validNames = @(
            'escape', 'tab', 'return', 'space', 'backspace', 'delete', 'home', 'end',
            'page-up', 'page-down', 'up', 'down', 'left', 'right', 'a-z', '0-9'
        )
        if ($validNames -notcontains $key.name) { throw 'key.name is invalid' }
        if (@('a-z', '0-9') -contains $key.name) {
            if ($key.character -isnot [string] -or $key.character.Length -ne 1 -or
                ($key.name -eq 'a-z' -and $key.character -notmatch '^[A-Za-z]$') -or
                ($key.name -eq '0-9' -and $key.character -notmatch '^[0-9]$')) {
                throw 'key.character does not match key.name'
            }
        } elseif ($key.PSObject.Properties['character']) {
            throw 'key.character is only valid for a-z or 0-9'
        }
        $modifiers = if ($key.PSObject.Properties['modifiers']) {
            if ($key.modifiers -isnot [array]) { throw 'key.modifiers is invalid' }
            @($key.modifiers)
        } else { @() }
        foreach ($modifier in $modifiers) {
            if (@('shift', 'control', 'alt', 'command', 'meta') -notcontains $modifier) {
                throw 'key.modifiers is invalid'
            }
        }
        if (@($modifiers | Sort-Object -Unique).Count -ne $modifiers.Count) {
            throw 'key.modifiers contains a duplicate'
        }
        $phase = if ($key.PSObject.Properties['phase']) { $key.phase } else { 'press' }
        if (@('press', 'down', 'up') -notcontains $phase) { throw 'key.phase is invalid' }
    }
    if ($Command.PSObject.Properties['text']) {
        if (-not (Test-ExactProperties $Command.text @('value') @('sensitive'))) {
            throw 'text payload is invalid'
        }
        if ($Command.text.value -isnot [string] -or $Command.text.value.Length -gt 4096) {
            throw 'text.value is invalid'
        }
        if ($Command.text.PSObject.Properties['sensitive'] -and
            $Command.text.sensitive -isnot [bool]) { throw 'text.sensitive is invalid' }
    }
    foreach ($name in @('point', 'destination')) {
        if ($Command.PSObject.Properties[$name]) { Assert-Point $Command.PSObject.Properties[$name].Value }
    }
    if ($Command.PSObject.Properties['button'] -and
        @('primary', 'secondary') -notcontains $Command.button) { throw 'button is invalid' }
    if ($Command.PSObject.Properties['duration_ms'] -and
        -not (Test-IntegerInRange $Command.duration_ms 0 120000)) {
        throw 'duration_ms is invalid'
    }
    if ($Command.PSObject.Properties['scroll']) {
        $scroll = $Command.scroll
        if (-not (Test-ExactProperties $scroll @('delta_x', 'delta_y', 'unit')) -or
            -not (Test-NumberInRange $scroll.delta_x -100000 100000) -or
            -not (Test-NumberInRange $scroll.delta_y -100000 100000) -or
            @('line', 'pixel') -notcontains $scroll.unit) { throw 'scroll payload is invalid' }
    }
    if ($Command.PSObject.Properties['wait']) {
        $wait = $Command.wait
        if (-not (Test-ExactProperties $wait @('condition', 'timeout_ms') @('stable_for_ms')) -or
            @('foreground-target', 'target-visible', 'target-geometry-stable', 'frame-stable') `
                -notcontains $wait.condition -or
            -not (Test-IntegerInRange $wait.timeout_ms 1 120000) -or
            ($wait.PSObject.Properties['stable_for_ms'] -and
                -not (Test-IntegerInRange $wait.stable_for_ms 0 30000))) {
            throw 'wait payload is invalid'
        }
    }
    if ($Command.PSObject.Properties['artifact']) {
        $artifact = $Command.artifact
        if (-not (Test-ExactProperties $artifact @('name') @('scope')) -or
            $artifact.name -isnot [string] -or $artifact.name -notmatch $script:ArtifactPattern) {
            throw 'artifact.name is invalid'
        }
        $scope = if ($artifact.PSObject.Properties['scope']) {
            $artifact.scope
        } else { 'target-window' }
        if (@('target-window', 'guest-display') -notcontains $scope) {
            throw 'artifact.scope is invalid'
        }
    }
    if ($Command.PSObject.Properties['clipboard']) {
        $clipboard = $Command.clipboard
        if (-not (Test-ExactProperties $clipboard @('value') @('verify')) -or
            $clipboard.value -isnot [string] -or
            $clipboard.value -notmatch '^vm-evidence-sentinel:[A-Za-z0-9._-]{1,256}$' -or
            ($clipboard.PSObject.Properties['verify'] -and $clipboard.verify -isnot [bool])) {
            throw 'clipboard payload is invalid'
        }
    }
    if ($Command.PSObject.Properties['video']) {
        $video = $Command.video
        if (-not (Test-ExactProperties $video @('artifact_name', 'maximum_seconds') @(
            'frames_per_second'
        )) -or $video.artifact_name -isnot [string] -or
            $video.artifact_name -notmatch $script:ArtifactPattern -or
            -not (Test-IntegerInRange $video.maximum_seconds 1 300) -or
            ($video.PSObject.Properties['frames_per_second'] -and
                -not (Test-IntegerInRange $video.frames_per_second 1 30))) {
            throw 'video payload is invalid'
        }
    }
}

function Read-JsonFile {
    param([string] $Path, [string] $Kind)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.LinkType) {
        throw "$Kind path is not a regular, non-symlink file"
    }
    if ($item.Length -gt 1048576) { throw "$Kind JSON exceeds 1 MiB" }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-OperationGrant {
    param([string] $Name)
    $map = @{
        observe = 'observe'; focus = 'accessibility'; key = 'keyboard'; text = 'keyboard'
        move = 'pointer'; click = 'pointer'; 'double-click' = 'pointer'; drag = 'pointer'
        scroll = 'wheel'; wait = 'observe'; screenshot = 'screenshot'
        'clipboard-set-sentinel' = 'clipboard-sentinel'; 'video-start' = 'video'
        'video-stop' = 'video'
    }

    return $map[$Name]
}

function Assert-CommandDeadline {
    if ($null -ne $script:CommandDeadline -and
        [DateTimeOffset]::UtcNow -ge $script:CommandDeadline) {
        throw 'command timeout expired'
    }
}

function Get-TargetState {
    param([object] $Session)
    $handles = @([EvidenceNative]::WindowsForPid([int] $Session.target.pid))
    if ($Session.target.PSObject.Properties['window_index']) {
        # Explicit indices keep their original position, including hidden windows.
        $index = [int] $Session.target.window_index
        $handle = if ($index -lt $handles.Count) { $handles[$index] } else { [IntPtr]::Zero }
    } else {
        # Frameworks also own hidden IME/message windows. Never guess between
        # multiple visible windows or silently choose a foreground replacement.
        $candidates = @($handles | Where-Object {
            $candidateRect = New-Object EvidenceNative+RECT
            [EvidenceNative]::WindowPid($_) -eq [int] $Session.target.pid -and
                [EvidenceNative]::Visible($_) -and
                [EvidenceNative]::Rectangle($_, [ref] $candidateRect) -and
                $candidateRect.Right -gt $candidateRect.Left -and
                $candidateRect.Bottom -gt $candidateRect.Top
        })
        if ($candidates.Count -ne 1) {
            throw 'omitted window_index requires exactly one visible positive-area target window'
        }
        $handle = $candidates[0]
    }
    $rect = New-Object EvidenceNative+RECT
    $found = $handle -ne [IntPtr]::Zero -and
        [EvidenceNative]::WindowPid($handle) -eq [int] $Session.target.pid -and
        [EvidenceNative]::Rectangle($handle, [ref] $rect)
    return [pscustomobject]@{
        Handle = $handle
        Found = [bool] $found
        Foreground = if ($found) { [EvidenceNative]::Foreground($handle) } else { $false }
        Visible = if ($found) { [EvidenceNative]::Visible($handle) } else { $false }
        Rect = $rect
    }
}

function Assert-Target {
    param([object] $State, [switch] $Visible, [switch] $Foreground)
    if (-not $State.Found) { throw 'no top-level window belongs to session target PID' }
    if ($Visible -and -not $State.Visible) { throw 'target window is not visible' }
    if ($Foreground -and -not $State.Foreground) { throw 'target window is not foreground' }
}

function Focus-Target {
    param([object] $State)
    Assert-Target $State -Visible
    if (-not [EvidenceNative]::Focus($State.Handle)) {
        throw 'could not make the owned target window foreground'
    }
    Start-Sleep -Milliseconds 40
    if (-not [EvidenceNative]::Foreground($State.Handle)) {
        throw 'owned target window did not remain foreground'
    }
}

function Convert-Point {
    param([object] $Point, [object] $State, [switch] $AllowBackground)
    Assert-Target $State -Visible
    if (-not $AllowBackground) { Assert-Target $State -Foreground }
    $x = [double] $Point.x
    $y = [double] $Point.y
    $space = if ($Point.PSObject.Properties['coordinate_space']) {
        $Point.coordinate_space
    } else { 'physical-screen' }
    if ($space -eq 'target-relative') {
        $x += $State.Rect.Left
        $y += $State.Rect.Top
    }
    if ($x -lt $State.Rect.Left -or $y -lt $State.Rect.Top -or
        $x -ge $State.Rect.Right -or $y -ge $State.Rect.Bottom) {
        throw 'pointer coordinate is outside the owned target window'
    }
    $rounded = @([int][Math]::Round($x), [int][Math]::Round($y))
    if ([EvidenceNative]::HitWindow([int] $rounded[0], [int] $rounded[1]) -ne
        $State.Handle) {
        throw 'native hit-test does not belong to the selected window'
    }
    return $rounded
}

function Assert-CursorOwned {
    param([object] $State)
    $x = 0
    $y = 0
    if (-not [EvidenceNative]::Cursor([ref] $x, [ref] $y)) {
        throw 'could not obtain cursor position'
    }
    if ($x -lt $State.Rect.Left -or $y -lt $State.Rect.Top -or
        $x -ge $State.Rect.Right -or $y -ge $State.Rect.Bottom) {
        throw 'cursor is outside the owned target window'
    }
    if ([EvidenceNative]::HitWindow($x, $y) -ne $State.Handle) {
        throw 'cursor native hit-test does not belong to the selected window'
    }
}

function Test-ObservedCursorPoint {
    param([int] $X, [int] $Y, [object] $State, [object] $Session)
    return $X -ge $State.Rect.Left -and $Y -ge $State.Rect.Top -and
        $X -lt $State.Rect.Right -and $Y -lt $State.Rect.Bottom -and
        [EvidenceNative]::HitOwnedWindow($X, $Y, [int] $Session.target.pid, $State.Handle)
}

function Get-CursorObservation {
    param([object] $State, [object] $Session)
    $result = [ordered]@{ available = $false; shape = 'unknown'; native_error_code = $null }
    $process = $null
    try {
        # Cursor observation is optional. Ordinary observe remains usable when
        # background/off-target; never disclose another window's cursor state.
        $process = [EvidenceNative]::RetainProcess([int] $Session.target.pid)
        $before = Get-TargetState $Session
        Assert-Target $before -Visible -Foreground
        if ($process.HasExited -or $before.Handle -ne $State.Handle) { return $result }
        $beforeX = 0; $beforeY = 0
        if (-not [EvidenceNative]::Cursor([ref] $beforeX, [ref] $beforeY) -or
            -not (Test-ObservedCursorPoint $beforeX $beforeY $before $Session)) { return $result }
        $x = 0; $y = 0; $showing = $false; $shape = 'unknown'; $nativeCode = 0
        if (-not [EvidenceNative]::CursorSnapshot(
                [ref] $x, [ref] $y, [ref] $showing, [ref] $shape, [ref] $nativeCode)) {
            $result.native_error_code = $nativeCode
            return $result
        }
        if (-not $showing -or @('arrow', 'size_we', 'size_ns', 'size_nwse', 'size_nesw', 'other') -notcontains $shape) {
            return $result
        }
        # Validate the exact GetCursorInfo position, not a later separately
        # sampled position that could move away and back between the checks.
        if (-not (Test-ObservedCursorPoint $x $y $before $Session)) { return $result }
        $after = Get-TargetState $Session
        Assert-Target $after -Visible -Foreground
        if ($process.HasExited -or $after.Handle -ne $before.Handle -or
            $after.Rect.Left -ne $before.Rect.Left -or $after.Rect.Top -ne $before.Rect.Top -or
            $after.Rect.Right -ne $before.Rect.Right -or $after.Rect.Bottom -ne $before.Rect.Bottom) {
            return $result
        }
        if (-not (Test-ObservedCursorPoint $x $y $after $Session)) { return $result }
        $currentX = 0; $currentY = 0
        if (-not [EvidenceNative]::Cursor([ref] $currentX, [ref] $currentY) -or
            $currentX -ne $x -or $currentY -ne $y -or
            -not (Test-ObservedCursorPoint $currentX $currentY $after $Session)) { return $result }
        $result.available = $true
        $result.shape = $shape
        $result['x'] = $x; $result['y'] = $y
        return $result
    } catch {
        return $result # No source error text, handle, or off-target coordinates.
    } finally {
        if ($null -ne $process) {
            try { $process.Dispose() } catch {
                $result.available = $false; $result.shape = 'unknown'
                $result.Remove('x'); $result.Remove('y')
            }
        }
    }
}

function Get-Observation {
    param([object] $State, [object] $Session)
    Assert-Target $State
    $result = [ordered]@{
        window_id = ('0x{0:x}' -f $State.Handle.ToInt64())
        title = [EvidenceNative]::Title($State.Handle)
        accessibility = $null
        cursor = Get-CursorObservation $State $Session
    }
    if ($Session.grants -contains 'accessibility') {
        try {
            $element = [System.Windows.Automation.AutomationElement]::FromHandle($State.Handle)
            $children = @()
            $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
            $child = $walker.GetFirstChild($element)
            while ($null -ne $child -and $children.Count -lt 64) {
                $children += [ordered]@{
                    name = $child.Current.Name
                    class_name = $child.Current.ClassName
                    control_type = $child.Current.ControlType.ProgrammaticName
                }
                $child = $walker.GetNextSibling($child)
            }
            $result.accessibility = [ordered]@{
                available = $true
                name = $element.Current.Name
                control_type = $element.Current.ControlType.ProgrammaticName
                children = $children
            }
        } catch {
            $result.accessibility = [ordered]@{
                available = $false
                native_error = $_.Exception.Message.Substring(
                    0, [Math]::Min(512, $_.Exception.Message.Length)
                )
            }
        }
    }
    return $result
}

$script:ModifierVks = @{
    shift = 0xA0; control = 0xA2; alt = 0xA4; command = 0x5B; meta = 0x5B
}
$script:NamedVks = @{
    escape = 0x1B; tab = 0x09; return = 0x0D; space = 0x20; backspace = 0x08
    delete = 0x2E; home = 0x24; end = 0x23; 'page-up' = 0x21; 'page-down' = 0x22
    up = 0x26; down = 0x28; left = 0x25; right = 0x27
}

function Send-KeyCommand {
    param([object] $Key)
    $modifiers = if ($Key.PSObject.Properties['modifiers']) {
        @($Key.modifiers) | ForEach-Object { [int] $script:ModifierVks[$_] }
    } else { @() }
    try {
        foreach ($modifier in $modifiers) {
            Assert-CommandDeadline
            [EvidenceNative]::Key([ushort] $modifier, $false)
        }
        $vk = if ($Key.name -eq 'a-z' -or $Key.name -eq '0-9') {
            [int][char] $Key.character.ToUpperInvariant()[0]
        } else { [int] $script:NamedVks[$Key.name] }
        $phase = if ($Key.PSObject.Properties['phase']) { $Key.phase } else { 'press' }
        if ($phase -eq 'press') {
            [EvidenceNative]::Key([ushort] $vk, $false)
            [EvidenceNative]::Key([ushort] $vk, $true)
        } elseif ($phase -eq 'down') {
            [EvidenceNative]::Key([ushort] $vk, $false)
        } else {
            [EvidenceNative]::Key([ushort] $vk, $true)
        }
    } finally {
        for ($index = $modifiers.Count - 1; $index -ge 0; $index--) {
            [EvidenceNative]::Key([ushort] $modifiers[$index], $true)
        }
        [EvidenceNative]::ReleaseModifiers()
    }
}

function Send-UnicodeText {
    param([string] $Text)
    try {
        foreach ($character in $Text.ToCharArray()) {
            Assert-CommandDeadline
            [EvidenceNative]::Unicode($character, $false)
            [EvidenceNative]::Unicode($character, $true)
        }
    } finally {
        [EvidenceNative]::ReleaseModifiers()
    }
}

function Send-PointerMove {
    param([object] $Point, [object] $State)
    $xy = @(Convert-Point $Point $State)
    [EvidenceNative]::Pointer([int] $xy[0], [int] $xy[1], 0x0001, 0)
}

function Send-Click {
    param([object] $Session, [object] $Point, [string] $Button,
          [int] $Repeat, [int] $DurationMs)
    $down = if ($Button -eq 'secondary') { 0x0008 } else { 0x0002 }
    $up = if ($Button -eq 'secondary') { 0x0010 } else { 0x0004 }
    # Retain the process before selecting a window, so PID reuse cannot adopt
    # another lifetime between the requested button events.
    $process = [EvidenceNative]::RetainProcess([int] $Session.target.pid)
    try {
        $initial = Get-TargetState $Session
        for ($i = 0; $i -lt $Repeat; $i++) {
            $attemptedDown = $false
            $clickFailure = $null
            try {
                Assert-CommandDeadline
                $xy = @(Resolve-ClickPoint $Session $Point $initial $process)
                if ($i -gt 0) { Assert-ClickCursor $xy }
                $attemptedDown = $true
                [EvidenceNative]::Pointer([int] $xy[0], [int] $xy[1], $down, 0)
                if ($DurationMs -gt 0) { Start-Sleep -Milliseconds $DurationMs }
                Assert-CommandDeadline
                # Refuse a changed window even after DOWN. The finally still
                # releases that button, without moving into a foreign window.
                $xy = @(Resolve-ClickPoint $Session $Point $initial $process)
                Assert-ClickCursor $xy
            } catch {
                $clickFailure = $_
                throw
            } finally {
                if ($attemptedDown) {
                    try { [EvidenceNative]::ReleasePointerButton($up) } catch {
                        if ($null -ne $clickFailure) {
                            throw [InvalidOperationException]::new(
                                $clickFailure.Exception.Message + '; matching button release also failed',
                                $_.Exception)
                        }
                        throw
                    }
                }
            }
            if ($i + 1 -lt $Repeat) { Start-Sleep -Milliseconds 80 }
        }
    } finally {
        $process.Dispose()
    }
}

function Assert-ClickCursor {
    param([object[]] $Point)
    $cursorX = 0; $cursorY = 0
    if (-not [EvidenceNative]::Cursor([ref] $cursorX, [ref] $cursorY) -or
        $cursorX -ne $Point[0] -or $cursorY -ne $Point[1]) {
        throw 'click cursor changed from the requested point'
    }
}

function Resolve-ClickPoint {
    param([object] $Session, [object] $Point, [object] $Initial,
          [object] $Process)
    if ($Process.Id -ne [int] $Session.target.pid -or $Process.HasExited) {
        throw 'click target process lifetime ended'
    }
    $state = Get-TargetState $Session
    Assert-Target $state -Visible
    if ($state.Handle -ne $Initial.Handle) { throw 'click target window changed' }
    $xy = @(Convert-Point $Point $state -AllowBackground)
    if (-not [EvidenceNative]::HitOwnedWindow(
            [int] $xy[0], [int] $xy[1], [int] $Session.target.pid, $Initial.Handle)) {
        throw 'click native hit-test is not owned by the selected PID and window'
    }
    if ($Process.HasExited) { throw 'click target process lifetime ended' }
    return $xy
}

function Send-Drag {
    param([object] $Command, [object] $State)
    $start = @(Convert-Point $Command.point $State)
    $end = @(Convert-Point $Command.destination $State)
    $button = if ($Command.PSObject.Properties['button']) { $Command.button } else { 'primary' }
    $down = if ($button -eq 'secondary') { 0x0008 } else { 0x0002 }
    $up = if ($button -eq 'secondary') { 0x0010 } else { 0x0004 }
    $duration = if ($Command.PSObject.Properties['duration_ms']) {
        [int] $Command.duration_ms
    } else { 0 }
    $steps = [Math]::Max(1, [Math]::Min(100, [Math]::Ceiling($duration / 20.0)))
    [EvidenceNative]::Pointer([int] $start[0], [int] $start[1], 0, 0)
    [EvidenceNative]::Pointer([int] $start[0], [int] $start[1], $down, 0)
    try {
        for ($step = 1; $step -le $steps; $step++) {
            Assert-CommandDeadline
            $x = [int][Math]::Round($start[0] + ($end[0] - $start[0]) * $step / $steps)
            $y = [int][Math]::Round($start[1] + ($end[1] - $start[1]) * $step / $steps)
            if ([EvidenceNative]::HitWindow($x, $y) -ne $State.Handle) {
                throw 'drag hit-test changed to another window'
            }
            [EvidenceNative]::Pointer($x, $y, 0, 0)
            if ($duration -gt 0) { Start-Sleep -Milliseconds ([Math]::Max(1, $duration / $steps)) }
        }
    } finally {
        [EvidenceNative]::Pointer([int] $end[0], [int] $end[1], $up, 0)
    }
}

function Send-Wheel {
    param([object] $Scroll)
    $scale = if ($Scroll.unit -eq 'line') { 120.0 } else { 3.0 }
    $vertical = -[int][Math]::Round($Scroll.delta_y * $scale)
    $horizontal = [int][Math]::Round($Scroll.delta_x * $scale)
    foreach ($axis in @(
        [pscustomobject]@{ Value = $vertical; Horizontal = $false },
        [pscustomobject]@{ Value = $horizontal; Horizontal = $true }
    )) {
        $value = [int] $axis.Value
        $horizontalAxis = [bool] $axis.Horizontal
        while ($value -ne 0) {
            Assert-CommandDeadline
            $delta = [Math]::Max(-1200, [Math]::Min(1200, $value))
            $flags = if ($horizontalAxis) { 0x1000 } else { 0x0800 }
            $mouseData = if ($delta -lt 0) { [uint] (0x100000000L + $delta) } else { [uint] $delta }
            $x = 0; $y = 0
            [void][EvidenceNative]::Cursor([ref] $x, [ref] $y)
            [EvidenceNative]::Pointer($x, $y, [uint] $flags, $mouseData)
            $value -= $delta
        }
    }
}

function Get-SafeArtifactPaths {
    param([string] $Root, [string] $Name)
    if ($Name -notmatch $script:ArtifactPattern) { throw 'artifact.name is invalid' }
    if (-not (Test-Path -LiteralPath $Root)) { throw 'artifact directory does not exist' }
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (-not $rootItem.PSIsContainer -or $rootItem.LinkType) {
        throw 'artifact directory is not a safe directory'
    }
    $rootFull = [IO.Path]::GetFullPath($rootItem.FullName)
    $filename = if ($Name.EndsWith('.png', [StringComparison]::OrdinalIgnoreCase)) {
        $Name
    } else { "$Name.png" }
    $final = Join-Path $rootFull $filename
    $partial = Join-Path $rootFull ('.' + $filename + '.partial')
    if ([IO.Path]::GetDirectoryName($final) -ne $rootFull -or
        (Test-Path -LiteralPath $final) -or (Test-Path -LiteralPath $partial)) {
        throw 'artifact destination is unsafe or already exists'
    }
    return [pscustomobject]@{ Final = $final; Partial = $partial }
}

function Get-FrameHash {
    param([object] $State)
    $bitmap = $null
    try {
        $width = [Math]::Max(1, $State.Rect.Right - $State.Rect.Left)
        $height = [Math]::Max(1, $State.Rect.Bottom - $State.Rect.Top)
        $bitmap = [Drawing.Bitmap]::new($width, $height)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen(
                $State.Rect.Left, $State.Rect.Top, 0, 0,
                ([Drawing.Size]::new($width, $height)),
                [Drawing.CopyPixelOperation]::SourceCopy
            )
        } finally {
            $graphics.Dispose()
        }
        $stream = New-Object IO.MemoryStream
        try {
            $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
            $hash = [Security.Cryptography.SHA256]::Create()
            try {
                return ([BitConverter]::ToString($hash.ComputeHash($stream.ToArray()))).Replace('-', '').ToLowerInvariant()
            } finally { $hash.Dispose() }
        } finally { $stream.Dispose() }
    } finally {
        if ($bitmap) { $bitmap.Dispose() }
    }
}

function Capture-Screenshot {
    param([object] $Session, [object] $Command, [object] $State, [string] $ArtifactDirectory)
    Assert-Target $State -Visible
    $paths = Get-SafeArtifactPaths $ArtifactDirectory $Command.artifact.name
    $scope = if ($Command.artifact.PSObject.Properties['scope']) {
        $Command.artifact.scope
    } else { 'target-window' }
    $bitmap = $null
    $graphics = $null
    try {
        if ($scope -eq 'target-window') {
            $bounds = [Drawing.Rectangle]::new(
                $State.Rect.Left, $State.Rect.Top,
                [Math]::Max(1, $State.Rect.Right - $State.Rect.Left),
                [Math]::Max(1, $State.Rect.Bottom - $State.Rect.Top)
            )
        } else {
            $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        }
        $bitmap = [Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen(
            $bounds.X, $bounds.Y, 0, 0, $bounds.Size,
            [Drawing.CopyPixelOperation]::SourceCopy
        )
        $bitmap.Save($paths.Partial, [Drawing.Imaging.ImageFormat]::Png)
        $item = Get-Item -LiteralPath $paths.Partial
        if ($item.Length -gt $Session.limits.maximum_artifact_bytes) {
            throw 'screenshot exceeds maximum_artifact_bytes'
        }
        $sha = (Get-FileHash -LiteralPath $paths.Partial -Algorithm SHA256).Hash.ToLowerInvariant()
        Move-Item -LiteralPath $paths.Partial -Destination $paths.Final
        return [ordered]@{
            name = $Command.artifact.name
            path = $paths.Final
            size = [long] $item.Length
            sha256 = $sha
        }
    } finally {
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
        if (Test-Path -LiteralPath $paths.Partial) {
            Remove-Item -LiteralPath $paths.Partial -Force
        }
    }
}

function Set-ClipboardSentinel {
    param([object] $Clipboard)
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw 'clipboard operations require an STA PowerShell process'
    }
    [Windows.Forms.Clipboard]::SetText($Clipboard.value, [Windows.Forms.TextDataFormat]::UnicodeText)
    $verify = if ($Clipboard.PSObject.Properties['verify']) { $Clipboard.verify } else { $true }
    if ($verify -and
        [Windows.Forms.Clipboard]::GetText([Windows.Forms.TextDataFormat]::UnicodeText) -cne
            $Clipboard.value) {
        throw 'clipboard sentinel verification failed'
    }
    return [ordered]@{ verified = $verify }
}

function Wait-ForCondition {
    param([object] $Session, [object] $Command)
    $requested = [int] $Command.wait.timeout_ms
    $timeout = [Math]::Min($requested, [int] $Session.limits.command_timeout_ms)
    $stable = if ($Command.wait.PSObject.Properties['stable_for_ms']) {
        [int] $Command.wait.stable_for_ms
    } else { 250 }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeout)
    $last = $null
    $stableSince = $null
    while ([DateTime]::UtcNow -le $deadline) {
        $state = Get-TargetState $Session
        $condition = $Command.wait.condition
        $ok = $false
        $current = $null
        if ($condition -eq 'foreground-target') {
            $ok = $state.Found -and $state.Foreground
            $current = $true
        } elseif ($condition -eq 'target-visible') {
            $ok = $state.Found -and $state.Visible
            $current = $true
        } elseif ($condition -eq 'target-geometry-stable') {
            $ok = $state.Found
            if ($ok) {
                $current = '{0},{1},{2},{3}' -f $state.Rect.Left, $state.Rect.Top,
                    $state.Rect.Right, $state.Rect.Bottom
            }
        } else {
            $ok = $state.Found -and $state.Visible
            if ($ok) { $current = Get-FrameHash $state }
        }
        if (@('foreground-target', 'target-visible') -contains $condition -and $ok) {
            return [ordered]@{ condition = $condition; satisfied = $true }
        }
        if (-not $ok) {
            $stableSince = $null
        } elseif ($null -ne $last -and $current -ne $last) {
            $stableSince = [DateTime]::UtcNow
        } elseif ($null -eq $stableSince) {
            $stableSince = [DateTime]::UtcNow
        }
        $last = $current
        if ($ok -and $null -ne $stableSince -and
            ([DateTime]::UtcNow - $stableSince).TotalMilliseconds -ge $stable) {
            return [ordered]@{ condition = $condition; satisfied = $true }
        }
        Start-Sleep -Milliseconds 50
    }
    throw "wait condition timed out: $($Command.wait.condition)"
}

function Get-Capabilities {
    return [ordered]@{
        driver = $script:DriverName
        protocol = 1
        display = 'windows-desktop'
        uia_available = $true
        send_input_available = $true
        copy_from_screen_available = $true
        clipboard_available = (
            [Threading.Thread]::CurrentThread.GetApartmentState() -eq
            [Threading.ApartmentState]::STA
        )
        operations = @($script:Operations | Where-Object {
            @('video-start', 'video-stop') -notcontains $_
        })
        unsupported = [ordered]@{ video = $true }
    }
}

function Invoke-Interaction {
    param([object] $Session, [object] $Command, [string] $ArtifactDirectory)
    $operation = $Command.operation
    if (@('video-start', 'video-stop') -contains $operation) {
        throw [InvalidOperationException]::new('video capture is explicitly unsupported')
    }
    $grant = Get-OperationGrant $operation
    if ($grant -and $Session.grants -notcontains $grant) {
        throw "operation is not granted: $grant"
    }
    if ($operation -eq 'capabilities') {
        return [pscustomobject]@{
            Observation = Get-Capabilities
            Artifacts = @()
            Message = 'capabilities enumerated'
        }
    }
    if ($operation -eq 'wait') {
        if ($Command.wait.condition -eq 'frame-stable' -and
            $Session.grants -notcontains 'screenshot') {
            throw 'frame-stable wait requires screenshot grant'
        }
        return [pscustomobject]@{
            Observation = Wait-ForCondition $Session $Command
            Artifacts = @()
            Message = 'wait satisfied'
        }
    }
    $state = Get-TargetState $Session
    if ($operation -eq 'observe') {
        $observation = Get-Observation $State $Session
        $message = 'observation captured'
    } elseif ($operation -eq 'focus') {
        Focus-Target $state
        $observation = [ordered]@{ focused = $true }
        $message = 'target focused'
    } elseif ($operation -eq 'key') {
        Focus-Target $state
        try { Send-KeyCommand $Command.key } finally { [EvidenceNative]::ReleaseModifiers() }
        $observation = [ordered]@{ key = 'sent' }
        $message = 'key sent'
    } elseif ($operation -eq 'text') {
        Focus-Target $state
        Send-UnicodeText $Command.text.value
        $observation = [ordered]@{ characters = $Command.text.value.Length }
        $message = 'text sent'
    } elseif ($operation -eq 'move') {
        Focus-Target $state
        $state = Get-TargetState $Session
        Send-PointerMove $Command.point $state
        $observation = [ordered]@{ pointer = 'move' }
        $message = 'pointer moved'
    } elseif (@('click', 'double-click') -contains $operation) {
        $button = if ($Command.PSObject.Properties['button']) { $Command.button } else { 'primary' }
        $duration = if ($Command.PSObject.Properties['duration_ms']) {
            [int] $Command.duration_ms
        } else { 0 }
        $repeat = if ($operation -eq 'double-click') { 2 } else { 1 }
        Send-Click $Session $Command.point $button $repeat $duration
        $observation = [ordered]@{ pointer = $operation }
        $message = 'pointer clicked'
    } elseif ($operation -eq 'drag') {
        Focus-Target $state
        Send-Drag $Command (Get-TargetState $Session)
        $observation = [ordered]@{ pointer = 'drag' }
        $message = 'pointer dragged'
    } elseif ($operation -eq 'scroll') {
        Focus-Target $state
        Assert-CursorOwned (Get-TargetState $Session)
        Send-Wheel $Command.scroll
        $observation = [ordered]@{ wheel = 'sent' }
        $message = 'wheel sent'
    } elseif ($operation -eq 'screenshot') {
        $artifacts = @(Capture-Screenshot $Session $Command $state $ArtifactDirectory)
        return [pscustomobject]@{
            Observation = $null
            Artifacts = $artifacts
            Message = 'screenshot captured'
        }
    } elseif ($operation -eq 'clipboard-set-sentinel') {
        $observation = Set-ClipboardSentinel $Command.clipboard
        $message = 'clipboard sentinel set'
    } else {
        throw [InvalidOperationException]::new('operation is unsupported')
    }
    return [pscustomobject]@{
        Observation = $observation
        Artifacts = @()
        Message = $message
    }
}

function Get-TargetDiagnostics {
    param([object] $Session)
    if (-not $Session -or $Session -isnot [pscustomobject] -or
        -not $Session.PSObject.Properties['target'] -or
        $Session.target -isnot [pscustomobject] -or
        -not $Session.target.PSObject.Properties['pid']) {
        return [ordered]@{ pid = 0; window_found = $false; foreground = $false; visible = $false }
    }
    try {
        $state = Get-TargetState $Session
        $diagnostic = [ordered]@{
            pid = [int] $Session.target.pid
            window_found = [bool] $state.Found
            foreground = [bool] $state.Foreground
            visible = [bool] $state.Visible
        }
        if ($state.Found) {
            $diagnostic.window_id = ('0x{0:x}' -f $state.Handle.ToInt64())
            $diagnostic.geometry = [ordered]@{
                x = $state.Rect.Left
                y = $state.Rect.Top
                width = [Math]::Max(0, $state.Rect.Right - $state.Rect.Left)
                height = [Math]::Max(0, $state.Rect.Bottom - $state.Rect.Top)
            }
        }
        return $diagnostic
    } catch {
        $targetPid = if (Test-IntegerInRange $Session.target.pid 0 2147483647) {
            [int] $Session.target.pid
        } else { 0 }
        return [ordered]@{
            pid = $targetPid
            window_found = $false
            foreground = $false
            visible = $false
        }
    }
}

function Write-InteractionResult {
    param([string] $Path, [object] $Result, [string] $ArtifactDirectory)
    $json = $Result | ConvertTo-Json -Depth 16 -Compress
    if (-not $Path) {
        Write-Output $json
        return
    }
    $resolvedArtifact = [IO.Path]::GetFullPath($ArtifactDirectory)
    $resolvedResult = [IO.Path]::GetFullPath($Path)
    if ($resolvedResult.StartsWith(
        $resolvedArtifact.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) { throw 'result path must not be inside artifact directory' }
    if ((Test-Path -LiteralPath $resolvedResult) -and
        (Get-Item -LiteralPath $resolvedResult).LinkType) {
        throw 'result path must not be a symlink'
    }
    $parent = Split-Path -Parent $resolvedResult
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $partial = Join-Path $parent ('.' + (Split-Path -Leaf $resolvedResult) + '.partial')
    if (Test-Path -LiteralPath $partial) { throw 'result temporary path already exists' }
    try {
        [IO.File]::WriteAllText($partial, $json + [Environment]::NewLine)
        [IO.File]::Replace($partial, $resolvedResult, $null)
    } catch [PlatformNotSupportedException] {
        Move-Item -LiteralPath $partial -Destination $resolvedResult -Force
    } catch {
        if (-not (Test-Path -LiteralPath $resolvedResult) -and (Test-Path -LiteralPath $partial)) {
            Move-Item -LiteralPath $partial -Destination $resolvedResult
        } else {
            throw
        }
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}

function Invoke-DrySelfTest {
    $sessionJson = @'
{"schema_version":1,"session_id":"self-test","platform":"windows","run_id":"self-test","target":{"pid":1},"grants":[],"limits":{"maximum_commands":1,"command_timeout_ms":100,"maximum_artifact_bytes":1,"maximum_video_seconds":1}}
'@
    $commandJson = @'
{"schema_version":1,"session_id":"self-test","sequence":1,"operation":"capabilities"}
'@
    Assert-ValidSession ($sessionJson | ConvertFrom-Json)
    Assert-ValidCommand ($commandJson | ConvertFrom-Json)
    foreach ($path in @('../escape', 'bad/name', '.hidden')) {
        if ($path -match $script:ArtifactPattern) { throw 'unsafe artifact name accepted' }
    }
    [ordered]@{
        schema_version = 1
        driver = $script:DriverName
        status = 'pass'
        display_touched = $false
        validated = @('session', 'command', 'paths')
    } | ConvertTo-Json -Depth 8 -Compress
}

if ($SelfTest) {
    if ($SessionPath -or $CommandPath -or $ArtifactDirectory -or $ResultPath) {
        throw '-SelfTest cannot be combined with request paths.'
    }
    Invoke-DrySelfTest
    exit 0
}
if (-not $SessionPath -or -not $CommandPath -or -not $ArtifactDirectory) {
    throw 'SessionPath, CommandPath, and ArtifactDirectory are required.'
}

# Physical-pixel geometry, screenshots and SendInput must share one thread
# context. This affects only this short-lived driver, not display settings.
$previousDpiContext = [EvidenceNative]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
if ($previousDpiContext -eq [IntPtr]::Zero) { throw 'physical-pixel thread context unavailable' }
try {
$started = [DateTimeOffset]::UtcNow
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$session = $null
$command = $null
$status = 'fail'
$message = ''
$nativeError = $null
$observation = $null
$artifacts = @()
try {
    $session = Read-JsonFile $SessionPath 'session'
    Assert-ValidSession $session
    $command = Read-JsonFile $CommandPath 'command'
    Assert-ValidCommand $command
    if ($command.session_id -ne $session.session_id) {
        throw 'command session_id does not match session'
    }
    if ([long] $command.sequence -gt [long] $session.limits.maximum_commands) {
        throw 'command sequence exceeds maximum_commands'
    }
    $durationMs = if ($command.PSObject.Properties['duration_ms']) {
        [long] $command.duration_ms
    } else { 0 }
    $durationMultiplier = if ($command.operation -eq 'double-click') { 2 } else { 1 }
    $doubleClickGap = if ($command.operation -eq 'double-click') { 80 } else { 0 }
    if (($durationMs * $durationMultiplier) + $doubleClickGap -gt
        [long] $session.limits.command_timeout_ms) {
        throw 'duration_ms exceeds command timeout'
    }
    if ($Operation -and $command.operation -ne $Operation) {
        throw 'operation selector does not match command'
    }
    if (-not (Test-Path -LiteralPath $ArtifactDirectory)) {
        New-Item -ItemType Directory -Force -Path $ArtifactDirectory | Out-Null
    }
    $artifactItem = Get-Item -LiteralPath $ArtifactDirectory -Force
    if (-not $artifactItem.PSIsContainer -or $artifactItem.LinkType) {
        throw 'artifact directory must not be a symlink'
    }
    $script:CommandDeadline = [DateTimeOffset]::UtcNow.AddMilliseconds(
        [long] $session.limits.command_timeout_ms
    )
    $execution = Invoke-Interaction $session $command $artifactItem.FullName
    $observation = $execution.Observation
    $artifacts = @($execution.Artifacts)
    $message = $execution.Message
    $status = 'pass'
} catch {
    $message = $_.Exception.Message
    $nativeError = if ($_.Exception.InnerException) {
        $_.Exception.InnerException.Message
    } else { $null }
    $status = if ($_.Exception -is [InvalidOperationException] -and
        $message -match 'explicitly unsupported') { 'unsupported' } else { 'fail' }
} finally {
    $script:CommandDeadline = $null
    $stopwatch.Stop()
}

$sessionId = if ($session -is [pscustomobject] -and
    $session.PSObject.Properties['session_id'] -and
    $session.session_id -is [string] -and
    $session.session_id -match $script:IdentifierPattern) { $session.session_id } else { 'invalid' }
$sequence = if ($command -is [pscustomobject] -and
    $command.PSObject.Properties['sequence'] -and
    (Test-IntegerInRange $command.sequence 1 2147483647)) {
    [int] $command.sequence
} else { 1 }
$operationName = if ($command -is [pscustomobject] -and
    $command.PSObject.Properties['operation'] -and $command.operation -is [string]) {
    $command.operation
} else { 'invalid' }
$result = [ordered]@{
    schema_version = 1
    session_id = $sessionId
    sequence = $sequence
    status = $status
    operation = $operationName
    started_at = $started.ToString('o')
    completed_at = [DateTimeOffset]::UtcNow.ToString('o')
    duration_ms = [long] $stopwatch.ElapsedMilliseconds
    diagnostics = [ordered]@{
        driver = $script:DriverName
        platform = $script:Platform
        target = Get-TargetDiagnostics $session
        message = if ($message.Length -gt 4096) { $message.Substring(0, 4096) } else { $message }
        native_error = if ($null -ne $nativeError -and $nativeError.Length -gt 4096) {
            $nativeError.Substring(0, 4096)
        } else { $nativeError }
        host_guest_clock_skew_ms = $null
        metrics = [ordered]@{ artifacts = $artifacts.Count }
    }
    artifacts = $artifacts
}
if ($null -ne $observation) { $result.observation = $observation }
Write-InteractionResult $ResultPath $result $ArtifactDirectory
} finally {
    if ([EvidenceNative]::SetThreadDpiAwarenessContext($previousDpiContext) -eq [IntPtr]::Zero) {
        throw 'physical-pixel thread context restore failed'
    }
}
