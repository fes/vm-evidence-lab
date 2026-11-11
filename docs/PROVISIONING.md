# Deterministic Parallels provisioning

The controller resets and runs already-provisioned VMs; it does not install
guest operating systems. The `provision/lab.py` helper adds a pinned,
host-specific setup path without treating a VM copied from another Mac as a
portable baseline.

## Prepare a host profile

Copy `provision/profiles/m2-pro.example.json` to a private location outside
source checkouts. Pin the exact host model identifier (`sysctl -n hw.model`),
macOS version and build (`sw_vers`), and complete `prlctl --version` output.
Choose an existing, writable data volume for `storage_root`; do not assume the
M2 Pro mini has the same volume names or capacity as another Mac.

For each guest, choose and record the exact OS release/build, installer path,
SHA-256, resource allocation, and a new baseline ID. Use ARM64 installers for
all three guests. Do not use a floating download URL as the version pin. Keep
the installer files and profile private; neither belongs in a source checkout.
The profile is a lockfile: edits to OS builds, images, resource settings, host
macOS, or Parallels require a new baseline ID.

Validate the completed profile and all image hashes on the M2 Pro mini:

```sh
python3 provision/lab.py validate /private/path/m2pro.json
python3 provision/lab.py preflight /private/path/m2pro.json
```

`preflight` compares the actual host model, architecture, macOS version/build,
and Parallels CLI version against the pins; checks free space; verifies all
three installer hashes; and lists name collisions without changing VMs. It
fails closed on a mismatch.

## Create and configure the guests

Create Windows and Linux from the pinned ARM64 ISOs using Parallels
Installation Assistant. Follow the profile exactly for VM names, virtual CPU,
memory, disk size, and OS build, and select `storage_root` as their location.
Keep the installation interactive where licensing or first-boot setup requires
it; do not insert personal accounts,
credentials, or shell startup customizations. For the first qualifying Linux
baseline, use Ubuntu Desktop/GNOME/Xorg as described in the product evidence
requirements.

Create the macOS ARM guest locally from the pinned IPSW:

```sh
python3 provision/lab.py create-macos /private/path/m2pro.json
```

This command requires an exact host match, a verified IPSW, and an unused VM
name. It creates a new macOS VM under `storage_root` with a plain disk of the
pinned size and applies the configured CPU and memory. Start it in Parallels to
finish the OS installation. The macOS guest must use the same major macOS
version as its host; do not copy the M4's `.macvm` as a substitute.

After all three VMs are fully installed and powered off, apply their pinned
resources and disable Shared Profile, Shared Clipboard, and Shared Cloud:

```sh
python3 provision/lab.py harden /private/path/m2pro.json
```

The helper first requires all named VMs to exist and be stopped, then applies
the settings to all three. Also inspect Parallels' Sharing settings and remove
any manually-added shared folders. The CLI flags do not prove that an ad hoc
share is absent. Keep host folder sharing, clipboard sharing, and cloud-folder
integration disabled in each baseline.

## Seal, qualify, and connect the controller

For each guest, finish the clean baseline with only intentional OS updates,
build/runtime prerequisites, a dedicated evidence account, SSH, the
graphical-session relay, and required native UI tools. Install no product
checkout or personal/developer credentials. Make any one-time permission or
activation decisions explicit in the private run record.

Cleanly shut down each VM and create a named Parallels snapshot for its
profile's baseline ID. Record the snapshot ID reported by Parallels in a
separate private copy of `host/config.example.json`. Use distinct M2 Pro VM
names and snapshot IDs; keep the existing M4 configuration and baselines
unchanged. Set `VM_EVIDENCE_CONFIG` to the host-specific config when invoking
the controller.

Keep the profile, installers' hashes, Parallels/macOS version pins, and
qualification results together as the baseline record. Qualify each OS with
the existing exact-commit, clean-restore workflow. A successful VM creation
does not qualify its graphics, native input, desktop session, or evidence
capture. In particular, keep Windows diagnostic until the M2 guest independently
passes the required native-window and graphics checks.

When any pinned input or material guest configuration changes, create a new
profile/baseline version and repeat qualification. Do not update the accepted
snapshot in place or silently retry failed qualification runs.

## Unattended guest builds (verified on an M2 Pro, Parallels)

Interactive installs are not reproducible. These steps were verified end to
end; follow them in order. Secrets stay in a private directory (`0700`) outside
any checkout.

### Seeds

```sh
umask 077
openssl rand -base64 18 > /private/secrets/evidence-password
ssh-keygen -t ed25519 -N '' -C vm-evidence-lab -f ~/.ssh/vm-evidence-lab
python3 provision/make_seeds.py --out /private/seeds \
  --public-key ~/.ssh/vm-evidence-lab.pub \
  --password-file /private/secrets/evidence-password
```

This renders `provision/seeds/*.template` into `seed-linux.iso` (label
`CIDATA`, Ubuntu autoinstall) and `seed-windows.iso` (label `WINSEED`:
`Autounattend.xml`, `setup-evidence.ps1`, Parallels Tools `IGT_ARM64.exe` and
`prl_tg/`, copied from the installed Parallels Desktop app because a seed
without them cannot install Tools). Attach each seed as a second CD-ROM.

### CD-ROM and input quirks

- `prlctl set --device-add cdrom` creates the device disconnected; follow with
  `prlctl set VM --device-set cdromN --connect`. A guest reset or restart can
  disconnect it again, so re-check before relying on a seed.
- Delete CD-ROMs one `--device-del` per call; passing several fails.
- Set boot order with `--device-bootorder`; detach installers and seeds after
  install.
- `prlctl` can send keys (`send-key-event -s <scancode> -d <ms>`) but not mouse
  input. `prlctl capture` may return before the file exists; retry.
- `prlctl exec` on Windows runs as SYSTEM.

### Linux: Ubuntu Desktop 24.04.5 ARM64

- Use 24.04.5, not 26.04: 26.04 has no GNOME Xorg session, which the product
  requires. The seed disables Wayland and enables autologin for `evidence`.
- Give the guest 8192 MiB RAM and add an 8 GB swapfile (plus fstab entry).
  6 GiB with a 4 GB swap was OOM-killed by `ld` during `cargo bench` builds.
- After the autoinstall powers off, detach the installer and seed, attach
  `prl-tools-lin-arm.iso` (from the Parallels app `Resources/Tools`), boot, and
  copy `relay/` and `provision/guest-setup-linux.sh` to the guest. Then run
  `sudo ./guest-setup-linux.sh <path-to-relay>`. It installs packages (including
  `screen`), the 8 GB swapfile, rustup, Parallels Tools, GNOME quieting, the
  relay, and verifies the result. It is idempotent. Verified from scratch on
  an M2 Pro: a fresh VM built this way had working Rust, swap, Tools and relay.

### Windows 11 ARM64

- Always install onto a fresh, empty disk. A partially installed disk makes
  Setup ask "upgrade or clean install", which the unattended file cannot
  answer. Press Space repeatedly at boot to pass "Press any key".
- The OOBE EULA page may still need one mouse click (not scriptable with
  `prlctl`); expect one manual click.
- After first boot, ensure the seed CD is connected and run
  `setup-evidence.ps1` (via `prlctl exec`) if it did not run automatically. It
  installs OpenSSH, installs the controller key, sets the firewall rule to
  `-Profile Any` (Parallels Shared networking reports Public), and marks the
  network Private. Remove stale `known_hosts` entries when rebuilding.
- Copy `relay/` and `provision/guest-setup-windows.ps1` to the guest and run it
  elevated from a logged-in session (winget is unreliable from SYSTEM):
  `powershell -ExecutionPolicy Bypass -File guest-setup-windows.ps1 -RelayDir <relay>`.
  It winget-installs `Git.Git`, `jqlang.jq`, `Rustlang.Rustup` and VS 2022
  Build Tools (ARM64, x64, Clang/LLVM, Windows 11 SDK 26100), sets the Rust
  default to `stable-aarch64-pc-windows-msvc`, installs the relay, and
  verifies the result. Only the already-installed (idempotent) path has been
  exercised; a from-scratch run is unproven.
- The fesTerm adapter uses `clang-cl` when present, else `clang`. Plain
  `clang` as `CC` breaks cc-rs on MSVC targets.
- Leave OpenSSH's default shell as `cmd.exe`. The controller sends
  `powershell.exe -Command "..."`; with PowerShell as the SSH default shell the
  outer shell expands `$_` and `$vars` and every controller command breaks.
- Verify autologon survives `prlctl restart`.

### macOS (same major version as the host)

- Run Setup Assistant by hand: user `evidence`, the generated password,
  enable Remote Login (System Settings > General > Sharing).
- Install the controller key with `ssh-copy-id` (use an `SSH_ASKPASS` helper
  when scripting). Install Command Line Tools headlessly: create
  `/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress`, then
  `softwareupdate -i` the listed CLT label.
- Install rustup (quote `"=https"` in zsh), then `relay/install-macos.sh`.
- Install Parallels Tools with `installer -pkg ".../Install.mpkg" -target /`
  from the mounted Tools ISO.
- Autologin: `sysadminctl -autologin` fails over SSH. Write `/etc/kcpassword`
  (password XOR key `7d 89 52 23 d2 bc dd ea a3 b9 1f`, NUL-padded to a
  multiple of 12 bytes, mode 0600) and
  `defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser
  evidence`. Verify `stat -f %Su /dev/console` is `evidence` after a reboot.
- `prlctl` does not report the macOS guest IP; use a DHCP reservation or fixed
  addresses in the controller config.
- Native UI jobs may need Accessibility and Screen Recording approval in the
  guest GUI; record those decisions in the run record.

### Baseline, snapshot, and controller

1. Power off, detach installer/seed CDs, set boot order to the hard disk, run
   `lab.py harden`.
2. Snapshot each VM, named by its baseline ID (for example
   `m2pro-linux-v3`), with the VM stopped. On a baseline change create a new
   snapshot, delete the old one after the new one qualifies, and update the
   snapshot ID in the private controller config.
3. Create the private controller config (`0600`) from
   `host/config.example.json`. `adapter_sha` pins the product adapter; any
   adapter change needs a commit and a new pin in the config and in each
   request's `sources`.
4. Run a request: `VM_EVIDENCE_CONFIG=/private/config.json host/controller.sh
   run <platform> <request.json>`. Requests need `schema_version`,
   `adapter_id`, `adapter_schema_version`, `mode`, `sources`, and `payload`.
5. Run `native-smoke` on each platform first as a readiness check.

### Known gaps

- If the adapter is killed (for example by the OOM killer) the guest result
  stays `running` and the controller only ends at its overall timeout. Check
  guest kernel logs (`journalctl -k -b -1`) before assuming a product fault.
- Running all three VMs concurrently needs about 24 GB of host RAM.
