# macOS GUI interaction driver

This directory contains a Swift 5+ driver for a logged-in macOS graphical
session. It accepts one interaction-session-v1 document at startup and strict
interaction-command-v1 JSON objects, one per standard-input line. Each command
produces one interaction-result-v1 JSON object on standard output. Input,
clipboard, and artifact contents are not logged.

## Prerequisites

* macOS 13 or newer with Xcode command-line tools (`swiftc`).
* A logged-in graphical console user. SSH-only and host-TCC-bypass use are
  unsupported.
* Grant the installed, stable
  `FesTermVMEvidenceInteraction.app` identity Accessibility for keyboard and
  pointer input and Screen Recording for screenshots/frame observation.
  Granting permission to Terminal, `swiftc`, or a host process does not grant
  permission to this bundle. The driver never requests or modifies TCC state.
* An existing target PID/window selected by the session. The driver does not
  launch, terminate, or enumerate unrelated applications for an action.
* A pre-created canonical, non-symlink artifact directory owned by the
  graphical user.

Clipboard commands are intentionally limited to values of the form
`vm-evidence-sentinel:<bounded-token>`. Clipboard values are never returned.

## Build and install

Build an ad-hoc-signed development bundle:

```sh
./build.sh
./driver.sh --self-test
```

Install to `/Applications` (or pass an installation-parent argument):

```sh
./install.sh
```

For a signing identity, pass it as the second argument to either script:

```sh
./build.sh "$PWD/.build" "Developer ID Application: Example (TEAMID)"
```

Always grant TCC to the installed bundle at its final path. Re-signing or
moving the bundle can invalidate an existing grant. The bundle identifier is
`com.fes.FesTermVMEvidenceInteraction`, and its executable name is stable.

## Run

```sh
./driver.sh --session session.json --artifact-root /private/path/to/artifacts \
  < command.json > result.json
```

The host controller's installed `driver-command.sh` launches the stable bundle
through LaunchServices (`open -n -g -W`), so its own Accessibility grant applies
rather than the remote transport's identity. It uses private per-command files,
refuses a concurrent helper, and bounds startup plus exact-child cleanup. The
operation's declared timeout remains unchanged; the host allows another 15
seconds for transport and cleanup. A cleanup failure retains private evidence
and fails closed. This path neither requests permissions nor re-signs the app.

Only the `capabilities`, `observe`, `focus`, `key`, `text`, `move`, `click`,
`double-click`, `drag`, `scroll`, `wait`, `screenshot`, and
`clipboard-set-sentinel` operations perform work. `video-start` and
`video-stop` always return a structured `unsupported` result with an
explanation. `--self-test` checks only local codecs/key mappings and neither
posts events nor inspects another application.

## Limitations

* Coordinates use CG global screen points; `target-relative` offsets are
  added to the selected window's top-left corner.
* Pointer clicks, drags, scrolls, focus, and window screenshots are refused if
  the selected PID-owned window is missing or obscured at the action point.
* Standard input contains exactly one complete JSON command (pretty printing
  is supported), and standard output contains exactly one result. The host
  controller is responsible for session sequence state.
* macOS `screencapture` is used for screenshots. Guest-display capture records
  the current default display, while target-window capture uses the selected
  window ID.
* No video implementation is provided. The driver does not provide a host TCC
  bypass, launch targets, read arbitrary clipboard content, or write outside
  the artifact root.
