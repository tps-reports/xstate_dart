# Changelog

## 0.1.3

- Add a CD-player example (`example/main.dart`) — the classic Harel
  statechart — exercising hierarchy, guarded alternative transitions,
  deterministic `after` timers via `tick`, history resume after eject,
  and snapshot save/restore, backed by an acceptance test suite.
- Apply `dart format` across the package.

## 0.1.2

Initial public release.

- Hierarchical (compound) and parallel states with XState-JSON-compatible
  configuration loaded via `StateMachine.fromJson`.
- Guards, entry/exit/transition actions, and eventless (`always`)
  transitions.
- Delayed (`after`) transitions driven by an explicit `tick(Duration)`
  clock — no `DateTime.now()` or `Timer`, so machines stay deterministic
  and unit-testable; `tick` accumulates microseconds so sub-millisecond
  durations do not truncate.
- History states, external re-entry for domain-target transitions, and
  strict validation of compound states without an `initial`.
- Snapshot save/restore (`toSnapshotJson` / `restoreSnapshot`) with
  structural validation of configurations and history values at restore.
