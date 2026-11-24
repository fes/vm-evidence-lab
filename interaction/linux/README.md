# Linux guest interaction driver

`driver.sh` is the fixed launcher for `driver.py`. It supports X11 only:
`xdotool`, `wmctrl`, and `xwininfo` identify and operate the PID-owned
top-level window. `import` is preferred for screenshots, with `scrot` as a
fallback. Clipboard sentinels use `xclip` or `xsel`. AT-SPI observation is
included when Python GI/AT-SPI bindings are present; its absence is reported
without failing ordinary observation.

Invocation:

```sh
./driver.sh --session session.json --command command.json \
  --artifact-directory artifacts --result result.json
```

If `--result` is omitted, the exact v1 result object is written to stdout.
Run `./driver.sh --self-test` for a request/schema/path check that never
queries a display or sends input. A `capabilities` command also performs no
input, but intentionally queries X11 and installed tool availability.

Wayland-only sessions and video produce structured `unsupported` results.
The driver derives the window solely from the session PID and `window_index`;
commands cannot supply window IDs. Pointer coordinates must remain within
the owned foreground window, and screenshots can only be written to the
supplied artifact directory using a schema-valid name. Existing artifacts
are never overwritten. Modifier keys are released after keyboard operations.

Requirements: Python 3, an X11 desktop, `xdotool`, `wmctrl`, and `xwininfo`.
Screenshots, clipboard, wheel, and AT-SPI additionally depend on the tools
described above. No VM or display is started by this driver.


## Optional cursor-only observation

`{"schema_version":1,"session_id":"example","sequence":1,"operation":"observe","cursor":true}`
adds a single bounded `observation.cursor` sample under the existing observe
grant. Omitted/false leaves ordinary observation unchanged and never samples
the cursor. Host validation requires an explicit Linux/macOS session.
The target must be foreground, visible and own the pointer hit before and after
the read; PID/window/geometry/pointer changes discard all image data.
A supported sample contains dimensions/hotspot, `name_hint: "unknown"`, SHA256
and base64 premultiplied ARGB32 bytes in big-endian channel order. Images are
limited to 128×128/65,536 output bytes; names are not shape authority. Failure
returns only `supported:false` and a finite reason. No subscriptions or input.

Existing X11 display authorization and optional already-installed `libX11.so.6`/
`libXfixes.so.3` are required; missing APIs/extensions return an unsupported sample.
Pixels use Xlib unsigned-long storage and are normalized to four ARGB bytes,
including on LP64. No cursor-name string is read.
