# Mac migration handoff

Read [`PARALLELS_PLATFORM_NOTES.md`](PARALLELS_PLATFORM_NOTES.md) first if you
are provisioning a new Apple Silicon host or debugging a guest that never
runs a job -- it covers hardware-bound macOS VM images, missing
Xcode-CLT/Rust on fresh macOS guests, a `prlctl exec` argv-flattening quirk on
macOS, session-persistence differences between Windows and macOS across
snapshot reverts, and a PowerShell native-stderr gotcha.

## 1. Pin the shared checkout

Clone this repository next to the products, check out a reviewed full commit,
and keep it separate rather than using a Git submodule:

```sh
git clone https://github.com/fes/vm-evidence-lab.git
git -C vm-evidence-lab checkout --detach <full-sha>
```

Copy `host/config.example.json` to
`~/.config/vm-evidence-lab/config.json`. Fill in Parallels VM names, clean
snapshot IDs, SSH details, guest spool/install roots, and a private artifact
root. Do not commit this file.

## 2. Add product adapters

Create `scripts/vm-evidence-adapter/` in each product repository according to
[`../adapters/README.md`](../adapters/README.md).

For fesTerm, preserve these initial modes:

- `native-smoke`;
- `os-input-smoke`;
- `optional-validation`.

The adapter should call existing repository-owned validation scripts. Keep
display, Xorg/Wayland, focus, screenshot, GPU, and acceptance policy in
fesTerm.

For ReInk, initially allow only:

- `readiness-probe`;
- `usb-presence-probe`;
- `read-only-evidence`.

The adapter belongs in `reink-results`, because that repository owns the
evidence runners. It may stage both `reink-rust` and `reink-results` source
IDs. It must reject mutation switches, write/reset values, acknowledgement
strings, ambiguous selectors, arbitrary paths, and unknown fields.

Pin each adapter's product-repository commit as `adapter_sha` in host config.
The candidate source commits in a request may differ from the trusted adapter
commit.

## 3. Install graphical-session relays

Create the guest spool, repository, adapter, and relay roots shown in config.
Install a graphical-session trigger for `relay/unix.sh` on Linux/macOS. On
Windows, the controller invokes `relay/windows.ps1` with
`prlctl exec --current-user`.

Keep the Linux qualifying path in the logged-in graphical user's systemd
session. Keep macOS in the console user's LaunchAgent domain. Do not run GUI
evidence through an SSH-only session.

The controller synchronizes relay code and the selected product adapter after
each clean snapshot restore.

## 4. Establish fesTerm parity

Do not delete `fesTerm/scripts/vm-evidence` yet.

1. Run the old and shared controllers against the same clean baseline and
   exact fesTerm commit using a readiness-only job.
2. Compare VM lifecycle, source resolution, relay phase transitions, provider
   metadata, screenshots, and terminal classification.
3. Repeat with each existing product mode.
4. Switch fesTerm only after behavior matches; preserve stable scenario and
   acceptance IDs in fesTerm documentation.

## 5. Add ReInk read-only campaigns

Hold the global lab lock, restore/start guests only while the printer is
disconnected, and require the operator to assign USB manually to one
environment at a time. Run macOS natively on the host unless macOS-guest USB
has separately proven reliable.

Qualify at least seven consecutive read-only campaigns per platform without
silent retry before treating the lab as acceptance infrastructure. Persistent
operations remain interactive and outside this shared relay.

## 6. Remove duplication last

Only remove the old fesTerm controller/relay after both adapters are stable,
manifests include all infrastructure/product versions, and failure
classification remains equivalent.
