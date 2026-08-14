# QEMU/KVM provider plan

**Research date:** 2026-08-14
**Recommendation:** add Linux-hosted QEMU/KVM as a second provider for Linux
and Windows guests. Do not treat it as a replacement for the Mac/Parallels
path required for supported macOS evidence.

## Scope

The shared controller, relay, adapter, schema, exact-source, lock, and manifest
contracts do not need a QEMU-specific fork. Add a provider implementation and
host configuration only.

Use:

- libvirt and `virsh` on `qemu:///system` for lifecycle and host resources;
- virt-manager only for baseline provisioning and diagnosis;
- QMP only as a narrow screenshot/input fallback.

Avoid raw QEMU command-line passthrough as the primary control surface.
Libvirt warns that opaque QEMU arguments weaken its security modeling and may
require host security-policy exceptions.[libvirt-passthrough]

## Provider mapping

| Shared operation | QEMU/KVM implementation |
| --- | --- |
| `provider_require` | Require `virsh`, `qemu-img`, and a working `qemu:///system` connection. |
| `provider_vm_exists` | Use `virsh dominfo <name>`. |
| `provider_reset` | Recreate a per-run qcow2 overlay and fresh firmware vars from an immutable powered-off baseline. |
| `provider_wait_for_restore` | Wait until storage/vars replacement completes and the domain is inactive. |
| `provider_start` | Use `virsh start <name>`. |
| `provider_stop` | Request `virsh shutdown`; after a bounded wait, destroy only the throwaway guest instance if needed. |
| `provider_capture` | Prefer `virsh screenshot`; fall back to QMP `screendump`. |
| `provider_exec_current_user` | Trigger a preinstalled interactive scheduled task in Windows; do not expose arbitrary QGA execution. |
| `provider_metadata` | Record libvirt/QEMU versions, URI, UUID, architecture, machine type, firmware, graphics, storage baseline, and attached host devices. |

Libvirt documents `qemu:///system` as the system instance used for privileged
host resources such as block, PCI, and USB devices.[libvirt-qemu]

## Deterministic reset model

Do not base qualifying evidence on live snapshot reversion. Libvirt notes that
running disk snapshots are generally crash-consistent rather than clean, and
full-system and disk-only snapshots have different semantics.[libvirt-snapshot]

Use a cold immutable baseline:

1. Provision and cleanly shut down the baseline guest.
2. Preserve its base qcow2 and pristine UEFI vars/NVRAM.
3. Before each run, create a fresh qcow2 overlay and fresh vars copy.
4. Start the domain only after those per-run files are installed.
5. Destroy the overlay and vars after evidence retention completes.

This resets guest software deterministically. It never rolls back a physical
printer or other external persistent state.

## Logged-in GUI evidence

SSH/SCP remain the control plane, not proof of graphical-session execution.

### Linux

Run `relay/unix.sh` from the logged-in user's systemd session. Keep qualifying
fesTerm evidence on Xorg initially; treat Wayland as a separately identified
target because input injection, focus, and host observation differ.

### Windows

Install one Task Scheduler task under the evidence user with interactive-token
logon semantics. After publishing a job, the provider may invoke only the
narrow task activation command. Microsoft documents interactive-token tasks
as requiring an already logged-in user and running in that interactive
session.[task-security][task-logon]

OpenSSH Server remains the source and result transport.[openssh]

### Host-side screenshot and input

Prefer:

- `virsh screenshot`, with QMP `screendump` as fallback;
- `virsh send-key`, with QMP `send-key` as fallback;
- QMP `input-send-event` only when pointer input is required.

QEMU's current QMP schema documents `screendump`, `send-key`, and
`input-send-event`; older packaged QEMU versions may require PPM rather than
PNG output.[qemu-qmp]

## ReInk USB lifecycle

Start with operator-supervised assignment, not unattended hotplug:

1. Acquire the host-wide lab lock.
2. Confirm no ReInk or print job is active.
3. Reset and start the guest while the printer is disconnected.
4. Stage the pinned relay, adapter, and exact product commits.
5. Have the operator assign the printer to exactly one guest.
6. Run `usb-presence-probe`, then `read-only-evidence`.
7. Have the operator detach the printer.
8. Stop the guest and release the lock.

The provider must never install, replace, detach, or rebind a host or guest
printer driver. ReInk persistent operations remain interactive and outside
the shared relay.

After stable manual campaigns, an optional helper may use libvirt host-device
XML with `attach-device` and `detach-device`. Bind by reviewed physical USB
port rather than transient device address. QEMU documents `hostbus` plus
`hostport` as the stable physical-port selector and warns that `hostaddr`
changes after replug.[qemu-usb]

QEMU still describes Linux-host USB passthrough as experimental and notes that
some devices may require unplug/replug after a guest exits.[qemu-usb] Treat
this path as supervised evidence infrastructure, not unattended hardware
recovery.

## Architecture and qualification

- x86-64 KVM host with x86-64 Linux or Windows guest: eligible for qualifying
  evidence after product-specific reliability gates.
- Arm64 KVM host with Arm64 guests: separately eligible after equivalent
  qualification.
- Cross-architecture TCG/emulation: diagnostic only.

Record host and guest architecture, acceleration mode, machine type, and CPU
model in every provider manifest. Do not use an emulated Windows result as the
sole oracle for an architecture-specific defect.

## macOS boundary

Do not scope Linux-hosted macOS guests into this provider. Apple's supported
virtualization documentation describes macOS virtualization on Mac hardware
and Apple silicon.[apple-virtualization][apple-macos-vm] Review the applicable
macOS software license before provisioning any macOS VM.[apple-sla]

Keep macOS evidence on a Mac through Parallels or Apple's virtualization
stack. Prefer native macOS-host ReInk evidence unless macOS guest USB
assignment has independently qualified.

## Configuration additions

A future `providers/libvirt-qemu.sh` should consume trusted host configuration
for:

```json
{
  "provider": "libvirt-qemu",
  "provider_options": {
    "connection_uri": "qemu:///system",
    "baseline_image": "/private/path/base.qcow2",
    "overlay_root": "/private/path/overlays",
    "nvram_template": "/private/path/guest_VARS.fd",
    "screenshot_format": "png"
  }
}
```

Physical USB selectors, VM UUIDs, paths, and addresses remain private host
configuration and must not be committed.

## Implementation sequence

1. Implement the provider contract using fake `virsh`/`qemu-img` tests.
2. Prove cold overlay/NVRAM reset with a Linux guest.
3. Prove logged-in Linux relay and host screenshot/input.
4. Prove Windows interactive scheduled-task activation.
5. Add manual ReInk USB assignment and presence-only evidence.
6. Run product-specific read-only reliability qualification.
7. Consider reviewed automated USB attach/detach only afterward.

QEMU/KVM can complement Parallels for Linux and Windows and may be preferable
on a dedicated Linux evidence host. It cannot replace the Mac path while
supported macOS evidence remains required.

## Sources

- [libvirt QEMU driver][libvirt-qemu]
- [libvirt snapshot format and semantics][libvirt-snapshot]
- [libvirt QEMU passthrough security][libvirt-passthrough]
- [QEMU USB emulation and host passthrough][qemu-usb]
- [QEMU QMP UI and input schema][qemu-qmp]
- [Microsoft OpenSSH Server][openssh]
- [Task Scheduler security contexts][task-security]
- [Task Scheduler logon types][task-logon]
- [Apple Virtualization framework][apple-virtualization]
- [Virtualize macOS on a Mac][apple-macos-vm]
- [Apple software license agreements][apple-sla]

[libvirt-qemu]: https://libvirt.org/drvqemu.html
[libvirt-snapshot]: https://libvirt.org/formatsnapshot.html
[libvirt-passthrough]: https://libvirt.org/kbase/qemu-passthrough-security.html
[qemu-usb]: https://www.qemu.org/docs/master/system/devices/usb.html
[qemu-qmp]: https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html
[openssh]: https://learn.microsoft.com/windows-server/administration/openssh/openssh-overview
[task-security]: https://learn.microsoft.com/windows/win32/taskschd/security-contexts-for-running-tasks
[task-logon]: https://learn.microsoft.com/windows/win32/api/taskschd/ne-taskschd-task_logon_type
[apple-virtualization]: https://developer.apple.com/documentation/virtualization
[apple-macos-vm]: https://developer.apple.com/documentation/virtualization/virtualize_macos_on_a_mac
[apple-sla]: https://www.apple.com/legal/sla/
