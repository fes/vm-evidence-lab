# Controller, relay, and adapter protocol

## Versioned flow

1. The operator gives the controller a private `host-request-v1` document.
2. The controller validates adapter/mode policy from private host config.
3. Source IDs resolve to trusted local repositories from that config.
4. The controller proves each requested full commit, creates Git bundles, and
   builds a `job-v1` document.
5. Bundles are published with temporary names and atomically renamed before
   the job.
6. The graphical-session relay atomically claims the job and checks the
   installed adapter policy and `adapter-version.txt`.
7. Each bundle is checked out detached; requested and resolved commits must
   match exactly.
8. The relay invokes the fixed adapter entry point.
9. Atomic `result-v1` updates report phases and terminal classification.
10. The host records provider metadata and a `manifest-v1`.

Unknown root fields are rejected. Source and bundle IDs are unique and bounded.
Jobs contain no command, argument, environment, working-directory, or output
path field.

## Phases and failure classes

Phases are `queued`, `preflight`, `checkout`, `adapter`, and `complete`.
Failures are classified as configuration, provisioning, artifact, product, or
infrastructure. The host may enforce phase deadlines only for adapter modes
explicitly marked watchdog-safe in private configuration.

Adapters classify product behavior by returning nonzero. They may write
product-specific structured results beneath the supplied artifact directory;
the shared relay does not reinterpret acceptance policy.

## Atomicity and replay

The host uploads bundles first and the job last. Relays claim jobs by rename
and use one lock directory per job. Result documents are written to a partial
path and renamed. Existing result IDs are never overwritten. Before each run,
the controller quarantines old unclaimed jobs instead of retrying them.

## Version identity

Every manifest records the controller commit, relay tree commit, adapter
commit, adapter schema version, requested product commits, and guest-resolved
product commits. Infrastructure, trusted adapter code, and candidate source
therefore remain independently attributable.
