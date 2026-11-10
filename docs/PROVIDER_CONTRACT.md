# Provider contract

Providers are sourced by `host/controller.sh` after `host/lib.sh`. A provider
must implement:

| Function | Contract |
| --- | --- |
| `provider_require` | Fail unless required host tooling is available. |
| `provider_vm_exists <name>` | Return success only for an exact VM name. |
| `provider_reset <name> <baseline>` | Restore the configured clean baseline. |
| `provider_wait_for_restore <name> <seconds>` | Wait boundedly for restore completion. |
| `provider_start <name>` | Start unless already running. |
| `provider_stop <name>` | Stop the guest after evidence collection. |
| `provider_capture <name> <path>` | Capture the guest display from the host. |
| `provider_exec_current_user <name> ...` | Execute only trusted controller commands in the logged-in guest session. |
| `provider_send_input_event <name> <type> <code>` | Optionally inject one controller-validated event from a pinned adapter plan. |
| `provider_metadata <name>` | Emit JSON including provider/version and VM metadata. |

The controller owns SSH/SCP transport, source bundles, relays, adapters, jobs,
results, and manifests. Providers must not interpret product payloads.

`provider_exec_current_user` is required for Windows because SSH does not prove
that evidence ran in the logged-in desktop. Providers without an equivalent
must arrange an installed graphical-session trigger and implement this
function as a narrow activation operation, not arbitrary candidate execution.

For Parallels Windows guests, `prlctl exec --current-user` requires an already
logged-in console desktop. SSH reachability alone is insufficient; a logon or
password-expiration screen is an infrastructure prerequisite failure, not a
product test failure. The controller does not repair credentials or enable
automatic logon.

The current-user operation runs asynchronously on the host. A completed nonzero
provider exit fails result polling promptly as infrastructure, even for modes
without host input; the original exit status is retained. A zero exit alone
does not replace the guest's terminal result: result polling continues within
the existing deadlines. Terminal-result arrival is also followed by the
activation status check.

Cleanup retains `relay-activation.log` and the completed
`relay-activation.status`, when present, in the private run artifact directory
before deleting the controller-owned staging directory, on success, failure,
timeout, or cancellation. A detected activation failure also retains
`relay-activation-failure.json` with its infrastructure classification and
provider exit status. Each retained activation file is limited to its first
64 KiB and created owner-only; treat it as private, unsanitized provider output.
Cancellation of an unfinished activation may leave a log but no completed
status. These files do not certify a graphical logon or successful product run.

`provider_send_input_event` is required only when a pinned adapter includes a
`host-input.json` plan for the selected mode. Providers must reject unsupported
event types. The controller validates codes against a deliberately narrow
allowlist before VM startup; providers never accept events from the job or
candidate source.

A reset is permitted only while external physical devices are disconnected
and no product process is active. Provider snapshots reset guest software; they
never roll back external hardware state.
