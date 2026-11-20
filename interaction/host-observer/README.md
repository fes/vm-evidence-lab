# macOS Parallels host observer

This directory is a standalone, macOS-only host-side recorder. It never starts or
controls a VM, reads the Clipboard or Accessibility APIs, requests TCC on behalf
of the user, or uses a TCC bypass. The installed application has the pinned
bundle identifier `org.vm-evidence-lab.host-observer`.

## Build, test, and install

```sh
./build.sh
swift test
./dist/'VM Evidence Host Observer.app'/Contents/MacOS/vm-host-observer --self-test
./install.sh              # $HOME/Applications and $HOME/.local/bin
./install.sh /some/prefix # PREFIX/Applications and PREFIX/.local/bin
```

The build script supports `ARCHES=arm64`, `ARCHES=x86_64`, and
`ARCHES=universal`. It uses only SwiftPM/Xcode SDK frameworks and signs the
distribution bundle. The source repository wrapper is
`bin/vm-host-observer`; rebuild it before use.

Ad-hoc signing (`CODESIGN_IDENTITY=-`) is sufficient for local development but
may cause macOS to treat rebuilds as a new code identity for TCC. Deployments
must set `CODESIGN_IDENTITY` to a stable Developer ID Application identity,
hardened-runtime signature, or other provisioned team certificate. Keep the
bundle ID and signing team stable, notarize if distributed, and reinstall at the
same app path. Never delete/reset TCC to suppress a permission failure. A
signature change may require an explicit new Screen Recording grant.

## Permission and target policy

Run `capabilities` first. It reports `authorized` or `not-authorized` without
prompting. Listing uses only CoreGraphics window metadata. It does not read
window pixels. If permission is missing, grant **Screen Recording** to `VM
Evidence Host Observer` in System Settings; then quit and relaunch the app
command. The observer intentionally does not call the TCC request API.

Every capture config is strict JSON:

```json
{
  "owner": "prl_client_app",
  "pid": 12345,
  "title": "Evidence Linux",
  "windowId": 67890
}
```

`owner` is one of the exact current English process owner strings
`prl_client_app` or `Parallels Desktop`; `title` is exact. `pid` and `windowId`
are optional but strongly recommended to prevent ambiguity. The live list
contains them:

```sh
vm-host-observer capabilities
vm-host-observer list
vm-host-observer capture \
  --config target.json --artifact-root ./artifacts --output run/snapshot.png
```

Selection fails unless exactly one record matches all supplied fields, the
window is at layer zero, onscreen, and no earlier window intersects its bounds.
`capture` revalidates the exact CoreGraphics window ID/PID through
ScreenCaptureKit immediately before capturing. This is a conservative
occlusion/minimized check: overlap with an above window is detectable, but
alpha transparency, hidden ownership, and occlusion changing after the check
cannot be proven. Consequently automation should capture only an unobscured
foreground target.

## Bounded recording

```sh
vm-host-observer record \
  --config target.json --artifact-root ./artifacts --output run/clip.mov \
  --fps 15 --max-duration-seconds 20 --max-bytes 104857600 \
  --marker 1250:'clicked Start' --marker 6400:'saw terminal prompt'
```

Frame rate is clamped by validation to 1–30. Duration defaults to 30 seconds
(hard CLI maximum 300), and bytes default to 500 MiB (hard maximum 1 GiB).
The output is an H.264 `.mov` written only within the artifact root. Existing
outputs, absolute paths, parent traversal, and output-parent symlinks are
rejected. A final size over the configured byte limit is a failure and partial
movie/sidecar files are removed.

The JSON sidecar is `OUTPUT.mov.markers.json`; each scheduled marker is emitted
at the next observer tick and records actual elapsed milliseconds, label, and
exact selected-window metadata. Start/stop lifecycle markers are always present.
The command result includes SHA-256 hashes for PNG and movie files.

ScreenCaptureKit video is used directly; `screencapture` is deliberately not a
fallback because it would weaken the window-identity, frame-rate, and byte-bound
guarantees.

## Automated and host validation

`--self-test` only exercises parsers, exact selection, fail-closed ambiguity and
occlusion, path containment, and the 30 fps bound. It does not call window
enumeration, capture pixels, or require TCC. `swift test` is similarly
deterministic and adds CLI/record-limit coverage.

Remaining validation requires a macOS host with a real Parallels installation
and is intentionally not automated here:

1. Grant Screen Recording to the stable signed bundle and confirm `capabilities`
   reports authorization; deny it and confirm capture/record fail closed.
2. Confirm the actual Parallels owner/title vocabulary and exact window ID/PID
   for the target VM on the deployment's localized macOS version.
3. Run `list`, then PNG `capture`, and independently compare the PNG hash and
   visible VM window; exercise minimized and partially covered windows.
4. Run a bounded recording at 30 fps and longer than the limit; verify actual
   duration, MOV readability, marker timing/contents, byte limit, and cleanup on
   forced over-limit failure.
5. Exercise artifact-root symlink and concurrent file replacement attacks on
   the target deployment filesystem, plus both foreground/background invocation.
6. Validate a developer/team-signed, notarized release across an upgrade to
   ensure its TCC identity remains stable.
7. Repeat on supported Intel and Apple Silicon hosts. The current build was
   compiled against the locally available macOS 27.2 SDK; a clean CI matrix on
   macOS 14/15/26/27 is not yet present.
