# Interactive desktop evidence

The interactive layer drives the **logged-in guest desktop** and records what
the operating system observed. It does not give a product job a remote shell.
Normal controller jobs remain the mechanism for staging exact candidate
sources and running fixed, allowlisted adapters.

Interactive requests are operator-controlled infrastructure. They are kept
separate from `job-v1`, never accepted from candidate product source, and never
forwarded from a job's `payload`.

## Capability model

An evidence run must probe capabilities and report them rather than assume every
provider or guest exposes the same surface.

| Capability | Parallels host | macOS guest driver | X11 guest driver | Windows guest driver |
| --- | --- | --- | --- | --- |
| VM display capture | Supported | Supported with TCC | Supported | Supported |
| Keyboard | Virtual scan codes | Native events | xdotool | SendInput |
| Pointer and drag | Not exposed by `prlctl` | Native events | xdotool | SendInput |
| Wheel | Not exposed by `prlctl` | Native scroll events | xdotool wheel buttons | SendInput wheel |
| Focus and geometry | Not exposed by `prlctl` | Accessibility | X11 window tools | Win32/UI Automation |
| Text/accessibility observation | None | Accessibility | AT-SPI when installed | UI Automation |
| Video | Host observer | Diagnostic guest capture | Diagnostic guest capture | Not yet qualified |

Wayland is deliberately not treated as X11. A Wayland result is
`unsupported` until a reviewed portal or platform-native driver exists.
Clipboard content sharing between the host and guest remains disabled.

## Controller commands

The following commands are operator infrastructure, not product-job modes:

```sh
# Reads only provider configuration and hypervisor capability metadata.
host/controller.sh interaction-capabilities macos

# Requires an already-running VM; installs the pinned driver for this checkout.
host/controller.sh interaction-install macos

# Fully offline schema and grant validation; does not contact a VM.
host/controller.sh interaction-dry-run session.json command.json

# Requires an already-running VM and a fresh host output directory.
host/controller.sh interaction linux session.json command.json \
  /private/artifacts/interaction-001
```

Interactive controller calls acquire the same global lab lock as normal
evidence runs. `interaction` and `interaction-install` fail when the VM is
stopped instead of starting it. An already-running lab owned by another agent
therefore blocks this command rather than being disturbed.

The install command copies only the reviewed drivers in this checkout,
compiles the macOS application when needed, and runs a no-input self-test.
Installation is explicit because rebuilding the ad-hoc-signed macOS bundle
can invalidate its TCC identity. A production deployment must use a stable
Developer ID/team signature and keep the bundle path unchanged.

`run_interaction` returns a schema-validated result and copies every reported
artifact to the `artifacts/` subdirectory after checking it remains beneath
the configured guest artifact root. It removes the uploaded session and command
on every exit path. Screenshots and results remain private.

For exact Parallels-window observation or bounded video on the host, use the
standalone [`interaction/host-observer/`](../interaction/host-observer/).
It is independent of guest interaction and requires only its own stable
Screen Recording grant.

## Session contract

`interaction-session-v1.json` names an existing guest process, the permitted
capability grants, and hard limits. It never names an executable or shell
command. `interaction-command-v1.json` then provides one bounded operation:

- observation and waits;
- focus, key, text, pointer, click, double-click and drag;
- line- or pixel-unit wheel scrolling;
- owned-window or full-display screenshots;
- controlled clipboard sentinels; and
- bounded video start/stop.

Every command is assigned a monotonically increasing sequence. The driver
rejects missing, duplicate or out-of-order sequences. Artifact names are
single path components; guest drivers accept an artifact root from trusted
installation state, not from a request.

`interaction-result-v1.json` reports pass, failure, or structured
`unsupported`. It includes target ownership, focus/visibility, geometry,
duration, native error detail, TCC state, artifact names/sizes/hashes, and
bounded metrics. Sensitive text is not copied into the result.

## Observe, act, acknowledge

Use `observe` before and after every mutating operation. Pointer operations
must identify the target PID, locate its owned window, resolve the requested
point in physical screen coordinates, and hit-test that coordinate before
posting input. Keyboard operations require the target to remain foreground.
Drivers release modifiers and restore normal input state during failure and
cleanup.

Do not synchronize primarily with fixed sleeps. Use the typed `wait`
conditions:

- `foreground-target`;
- `target-visible`;
- `target-geometry-stable`; and
- `frame-stable`.

If a wait expires, preserve one diagnostic screenshot and the first failing
observation. The host must not silently retry a failed interactive step.

## Screenshots and video

`prlctl capture` remains the default host-side whole-guest capture because it
does not depend on the Parallels window being visible. The macOS host observer
adds exact-window PNG capture and bounded ScreenCaptureKit video for local
diagnosis.

Video is opt-in, duration- and size-bounded, and disabled for qualifying
evidence by default. A recording manifest associates monotonic action sequence
numbers, timestamps, target geometry and the video hash. Microphone and system
audio are not recorded.

## Privacy and TCC

Accessibility and Screen Recording grants apply to a responsible executable,
not just a shell script. The macOS drivers are therefore installed as stable
signed bundles. A signing identity, bundle path or binary change requires a
new capability check and may require a new TCC approval.

The baseline must:

- use a dedicated ordinary test account;
- keep host/guest clipboard, profile and folder sharing off;
- grant only the pinned macOS driver bundle Accessibility access;
- grant Screen Recording only when host/guest visual capture is required;
- keep artifact roots outside candidate checkouts; and
- retain raw screenshots/video only in private evidence storage.

## Failure classification

Use `provisioning` when the interactive agent, desktop session, permissions,
tools, or required display backend are absent. Use `infrastructure` when the
provider transport or capture path fails. Use `product` only after the
owned-window, focus and observation prerequisites pass and a product
expectation is violated. An `unsupported` result is never a pass.

## Offline and live qualification

The repository tests verify schemas, strict command fields, paths, grants,
driver diagnostics, fake transport behavior and installer layout without
starting a VM. Live qualification still requires each guest to prove:

1. a logged-in desktop relay owns the interaction process;
2. TCC or equivalent native permissions are present;
3. process/window ownership and foreground state are checked;
4. wheel events move the intended Settings scroll area in both directions;
5. a pointer cannot target an unrelated or occluded window;
6. screenshot and optional video artifacts have matching hashes;
7. cleanup releases input state and removes only the session's files; and
8. seven consecutive, non-retried runs preserve the same capabilities.
