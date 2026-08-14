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
| `provider_metadata <name>` | Emit JSON including provider/version and VM metadata. |

The controller owns SSH/SCP transport, source bundles, relays, adapters, jobs,
results, and manifests. Providers must not interpret product payloads.

`provider_exec_current_user` is required for Windows because SSH does not prove
that evidence ran in the logged-in desktop. Providers without an equivalent
must arrange an installed graphical-session trigger and implement this
function as a narrow activation operation, not arbitrary candidate execution.

A reset is permitted only while external physical devices are disconnected
and no product process is active. Provider snapshots reset guest software; they
never roll back external hardware state.
