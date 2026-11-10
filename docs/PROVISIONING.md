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
