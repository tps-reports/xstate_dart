# xstate_dart

A pure-Dart interpreter for XState-JSON statecharts — hierarchical and
parallel states, guards, entry/exit/transition actions, eventless
(`always`) transitions, and delayed (`after`) transitions with time
injected via an explicit `tick` rather than `DateTime.now()` or `Timer`,
so machines stay deterministic and testable. Derived from forge_ui's
`lib/util/StateMachine.dart` (fivex project); built for the Elite-A
Flutter port (elite_gpu) and for general use across fivex apps.
