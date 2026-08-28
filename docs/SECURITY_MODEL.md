# Security model

## Trusted inputs

Private host configuration controls VM identities, SSH endpoints, artifact
storage, local source repositories, adapter repositories, adapter commits, and
watchdog-safe modes. Protect it outside all repositories.

The controller, relay, provider, and installed adapter are trusted automation.
Candidate product commits and job payloads are untrusted.

## Authority boundaries

- A request names only allowlisted source IDs and exact commits, never local
  paths.
- A guest job cannot name commands, arguments, environment variables, working
  directories, or output destinations.
- The controller installs adapter files from a trusted repository at a pinned
  full commit using `git show`.
- The relay requires the job's adapter commit to match
  `adapter-version.txt`.
- Product adapters reject unknown payload fields and map modes to fixed
  repository-owned entry points.
- Optional host-input plans come only from the configured adapter repository at
  its pinned commit. The controller accepts a narrow set of non-modified keys
  and a left-button click; jobs and candidate source cannot add or alter events.
- Git bundles avoid guest repository credentials.

## Physical devices and persistent state

The shared controller provides one global lock and sequential platform runs,
but it does not authorize physical-device mutation. A product adapter may be
watchdog-safe only when interruption cannot leave persistent external state
partially modified.

ReInk adapters must initially be read-only. EEPROM writes, restores, resets,
acknowledgement constants, and mutation values must never enter the shared job
protocol or unattended relay. VM snapshots cannot restore printer EEPROM.

## Evidence privacy

Keep artifact roots outside source checkouts. Do not commit raw captures,
terminal contents, clipboard contents, printer identities, EEPROM images,
serial numbers, device paths, network addresses, credentials, or host
metadata. Product adapters own sanitization and decide which derivative
evidence may leave private storage.

Disable guest shared folders, shared profile, shared clipboard, and cloud
folder integration. Recheck these controls whenever a baseline changes.

## Deliberate limitations

The controller does not silently retry product failures. It does not execute
opaque commands, install drivers, switch USB drivers, or infer that a
read-only pass authorizes mutation. Provider snapshots are a clean-software
mechanism, not recovery for external hardware state.

Host-input readiness files are candidate-produced evidence, not an independent
focus oracle. Their authority is limited to advancing a fixed, non-destructive
adapter-owned plan inside an already isolated guest. Per-run paths, embedded
run IDs, atomic publication, ordered stages, and bounded deadlines prevent
stale state from advancing a later run.
