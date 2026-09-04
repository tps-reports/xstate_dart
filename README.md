# xstate_dart

A pure-Dart interpreter for [XState](https://stately.ai/docs)-JSON
statecharts — hierarchical and parallel states, guards, entry/exit/
transition actions, eventless (`always`) transitions, history states,
snapshot save/restore, and delayed (`after`) transitions with time
injected via an explicit `tick` rather than `DateTime.now()` or `Timer`,
so machines stay deterministic and testable.

No Flutter dependency — usable in servers, CLIs, and Flutter apps alike.
Extracted from Coyote Forge's forge_ui framework, where it drives
JSON-defined workflow and UI state.

## Install

```yaml
dependencies:
  xstate_dart: ^0.1.3
```

## Quickstart

The chart is plain XState JSON; actions and guards are Dart functions you
register by name:

```dart
import 'package:xstate_dart/xstate_dart.dart';

const toggleChart = '''
{
  "id": "toggle",
  "initial": "off",
  "context": {"count": 0},
  "states": {
    "off": {"on": {"FLIP": {"target": "on", "actions": "increment"}}},
    "on": {
      "entry": "log",
      "on": {
        "FLIP": "off",
        "LOCKED_FLIP": {"target": "off", "guard": "never"}
      }
    }
  }
}
''';

void main() {
  final machine = StateMachine.fromJson(
    toggleChart,
    actions: {
      'increment': (ctx, event) => ctx['count'] = (ctx['count'] as int) + 1,
      'log': (ctx, event) => print('entered on'),
    },
    guards: {'never': (ctx, event, isActive) => false},
  );

  machine.matches('off');            // true
  final result = machine.send('FLIP');
  result.changed;                    // true
  machine.matches('on');             // true
  machine.context['count'];          // 1
  machine.send('LOCKED_FLIP').changed; // false — guard blocked it
}
```

`send` returns a `StateTransitionResult` telling you whether the
configuration changed; `activeStates` exposes the full ancestor closure of
the current configuration (e.g. `{'player', 'player.aiming'}`), and
`matches(path)` tests any node in it.

## Deterministic time: `tick`

Delayed transitions never read the wall clock. You advance time
explicitly, which makes timed behavior unit-testable and lets a host (a
game loop, a Flutter ticker, a server scheduler) own the clock:

```dart
// "gun": {"cooling": {"after": {"50": "ready"}}}
machine.tick(const Duration(milliseconds: 16)); // still cooling
machine.tick(const Duration(milliseconds: 40)); // 56ms elapsed -> ready
```

Microseconds accumulate across ticks, so sub-millisecond frames don't
truncate away.

## Snapshots

`toSnapshotJson()` serializes the live configuration, context, history,
and pending timers; `restoreSnapshot(json)` validates the structure
(configuration leaves, history values) before adopting it — a malformed
or stale snapshot throws instead of corrupting the machine.

## Supported XState-JSON subset

| Feature | Status |
|---|---|
| Flat, compound (nested), and parallel states | ✅ |
| `on` transitions with `target`, `actions`, `guard` | ✅ |
| `entry` / `exit` actions | ✅ |
| Eventless `always` transitions | ✅ |
| Delayed `after` transitions (injected clock) | ✅ |
| History states | ✅ |
| `context` + named guard/action registration | ✅ |
| Actors / services (`invoke`), spawned machines | ❌ not planned — keep the interpreter pure |

The interpreter is strict where XState is strict: a compound state
without an `initial` (and no `always` route) throws at load, and
transitions re-enter their domain correctly for external self-targets.

## License

BSD 3-Clause — see [LICENSE](LICENSE).
