# Windows guest interaction driver

`driver.ps1` is a PowerShell 5.1+/7 driver for a logged-in Windows desktop.
Its embedded C# boundary uses Win32 top-level window enumeration, PID
ownership checks, UI Automation (when the `accessibility` grant is present),
`SendInput`, and `Graphics.CopyFromScreen`. Commands never supply native
window handles. Input is rejected unless its pointer lies inside the selected
PID-owned, foreground window.

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
