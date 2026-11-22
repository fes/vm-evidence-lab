# Windows guest interaction driver

`driver.ps1` is a PowerShell 5.1+/7 driver for a logged-in Windows desktop.
Its embedded C# boundary uses Win32 top-level window enumeration, PID
ownership checks, UI Automation (when the `accessibility` grant is present),
`SendInput`, and `Graphics.CopyFromScreen`. Commands never supply native
window handles. Pointer input is restricted to the selected PID-owned window.
An explicit click may activate a background window only at the requested,
visible, unoccluded point; both the hit window and its top-level ancestor must
belong to the selected PID. A retained process handle and window identity are
rechecked before every button-down and before the ordinary button-up. A matching
button-up is always attempted in failure cleanup without moving the pointer.
Cursor displacement after button-down refuses further click work and still
releases the button at the current cursor position.
Focus does not inject an activation click. Keyboard, movement, drag and wheel
operations retain their foreground requirement.

Run it from an interactive desktop PowerShell process:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\driver.ps1 `
  -SessionPath session.json -CommandPath command.json `
  -ArtifactDirectory artifacts -ResultPath result.json
```

If `-ResultPath` is omitted, the exact interaction-result v1 JSON is written
to stdout. `-SelfTest` validates request and path rules without querying a
window or sending input. A `capabilities` command likewise sends no input and
reports native availability. Video start/stop always return structured
`unsupported` results.

Clipboard sentinel operations require an STA process. Screenshot artifacts
are PNGs beneath `-ArtifactDirectory`, named only with the schema-valid
logical artifact name; existing destinations are not overwritten. Window
focus, screenshots, and accessibility are restricted to the session PID and
its zero-based `window_index`. Modifier keys are explicitly released in
`finally` blocks, including after failed keyboard operations.

No VM is started or stopped by the driver. Native GUI behavior can only be
validated in an actual logged-in Windows desktop; this repository check
does not exercise it.

`observe` also returns optional `cursor` metadata. An available snapshot means
that the displayed global cursor was sampled while the retained selected process,
foreground window, rectangle, pointer position and native point ownership matched
at the before/after checks. The exact snapshot point and the final pointer point
are each checked against the owned rectangle and native point PID/root, including
foreign child-window refusal. This is a snapshot, not an atomic continuity proof. Shape is one of `arrow`, `size_we`, `size_ns`,
`size_nwse`, `size_nesw` or `other`, compared with borrowed stock cursor handles.
Off-target/background, hidden/suppressed, changed or failed observations return
`available: false` and `shape: unknown`; a failed native sample may include only
its numeric error code. Unavailable snapshots omit coordinates and never fail
ordinary window observation. No handle is exported and no cursor is installed.
A resize hit-test or successful pointer movement is not cursor-shape evidence;
actual native hover qualification remains separate from the contract fixtures.
