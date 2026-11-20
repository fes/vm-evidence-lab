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
