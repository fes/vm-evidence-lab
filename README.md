# VM Evidence Lab

Shared, product-neutral infrastructure for deterministic evidence from clean
Windows, Linux, and macOS virtual machines.

The lab separates four trust domains:

1. the pinned host controller and provider;
2. the pinned graphical-session relay;
3. a pinned, installed product adapter; and
4. candidate product source staged at exact commits through Git bundles.

Candidate source cannot provide commands to the relay or replace its adapter.
The shared repository owns lifecycle, transport, locks, queueing, exact-source
staging, watchdogs, failure classification, and manifests. Product repositories
own accepted modes, payload validation, fixed command mapping, artifact policy,
and acceptance decisions.

## Current implementation

- Parallels lifecycle, snapshot, capture, metadata, and current-user execution;
- SSH/SCP control transport;
- exact-commit Git-bundle staging for up to eight source repositories;
- atomic job publication, claim, results, and stale-job quarantine;
- one host-wide lock suitable for an exclusive physical device;
- Unix and Windows relays with pinned adapters;
- versioned JSON schemas and fake-adapter contract tests.

This is an extraction baseline, not evidence that a product has migrated.
Keep existing fesTerm automation operational until parity has been established.

## Repository layout

```text
adapters/    product adapter contract
docs/        protocol, security, migration, and provider plans
host/        controller and private configuration example
providers/   hypervisor-specific operations
relay/       Unix and Windows guest relays
schemas/     external versioned contracts
tests/       schema, relay, lock, exact-SHA, and provider tests
```

## Validation

On Linux or macOS:

```sh
./tests/run.sh
```

On Windows:

```powershell
./tests/run-windows.ps1
```

## Mac continuation

Start with [`docs/MAC_HANDOFF.md`](docs/MAC_HANDOFF.md). It describes how to
pin this repository separately, create fesTerm and ReInk adapters, configure
Parallels guests, and migrate without breaking the existing lab.

QEMU/KVM is a planned alternate provider for Linux and Windows hosts and
guests. See [`docs/QEMU_KVM_PORT.md`](docs/QEMU_KVM_PORT.md).
