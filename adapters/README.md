# Product adapter contract

`vm-evidence-lab` owns VM and transport mechanism. Product repositories own
the commands, payload validation, result interpretation, private-artifact
rules, and acceptance policy.

Each product keeps this directory in its own repository:

```text
scripts/vm-evidence-adapter/
|-- policy.json
|-- linux.sh
|-- macos.sh
`-- windows.ps1
```

`policy.json` has exactly these fields:

```json
{
  "adapter_id": "example",
  "schema_version": 1,
  "modes": ["read-only-evidence"],
  "platforms": ["windows", "linux", "macos"]
}
```

The Unix scripts receive:

```text
<job.json> <source-map.json> <artifact-directory>
```

`windows.ps1` receives `-JobPath`, `-SourceMapPath`, and
`-ArtifactDirectory`.

Adapters must strictly validate `payload`, map each accepted mode to one fixed
repository-owned command, write only beneath the supplied artifact directory,
and return nonzero when product evidence fails. They must not accept commands,
arguments, environment variables, arbitrary paths, or output locations from a
job.

The trusted host config pins `adapter_repository`, `adapter_path`, and a full
`adapter_sha`. The controller reads adapter files with `git show` at that exact
commit, installs only the platform policy and entry point, and writes
`adapter-version.txt`. The relay rejects a job unless its `adapter_sha`
matches the installed marker. Candidate product source is staged separately
from Git bundles and cannot replace its own adapter.
