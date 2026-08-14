# Extraction provenance

The initial Parallels provider, host lifecycle, SSH/SCP control, relay queue,
exact-SHA bundle staging, lock, watchdog, and manifest patterns were extracted
from `fes/fesTerm` under `scripts/vm-evidence`.

Relevant fesTerm history includes:

- `e224f27ff258a7eff0f7ab7429ee0fdd8b4e8375` — synchronize relays;
- `ca6a94c8f26f196f67d20ab130b7e8dcde35d90c` — Windows relay bundle access;
- `15be185ed7df4f415a1c405b722f56c6fc076540` — native output capture;
- `c049db0b8c6ea5cfe5e2b738aa88549afb99ef2d` — Windows build environment;
- `b1c55873a54ad7cc3d052bd23b28326af98b5e96` — Linux display configuration.

The extraction deliberately does not copy fesTerm mode implementations,
display/GPU acceptance policy, product commands, or platform-specific
validation assertions. Those remain in a fesTerm adapter.

The ReInk boundary derives from
`reink-results/PARALLELS_CROSS_PLATFORM_TEST_PLAN.md` at commit `2226c4d`.
ReInk contributes the host-wide physical-device lock, sequential manual USB
assignment, strict read-only unattended boundary, and the rule that VM state
cannot recover persistent printer state.
