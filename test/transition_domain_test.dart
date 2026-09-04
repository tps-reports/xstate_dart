import 'package:test/test.dart';
import 'package:xstate_dart/xstate_dart.dart';

// Covers the "external re-entry" fix: a transition whose resolved target IS
// the transition domain itself (so `_chainDownTo(target, domain)` would
// otherwise return an empty chain and silently drop `target` from the
// configuration instead of re-entering it). Three reachable shapes:
//   1. leaf self-transition (a -> a)
//   2. child targeting its own ancestor (c1 -> parent p)
//   3. region-root target inside a parallel machine

const selfAndAncestorChart = '''
{
  "id": "d",
  "initial": "p",
  "states": {
    "p": {
      "entry": "enterP",
      "exit": "exitP",
      "initial": "c1",
      "states": {
        "c1": {
          "entry": "enterC1",
          "exit": "exitC1",
          "on": {
            "SELF": "c1",
            "TO_PARENT": "p"
          }
        },
        "c2": {}
      }
    }
  }
}
''';

const parallelRegionRootChart = '''
{
  "id": "pr",
  "type": "parallel",
  "on": {"RESTART_R1": "r1"},
  "states": {
    "r1": {
      "entry": "enterR1",
      "exit": "exitR1",
      "initial": "r1a",
      "states": {
        "r1a": {"on": {"BUMP": "r1b"}},
        "r1b": {"entry": "enterR1b"}
      }
    },
    "r2": {
      "entry": "enterR2",
      "initial": "r2a",
      "states": {"r2a": {}, "r2b": {}}
    }
  }
}
''';

void main() {
  List<String> log = [];
  StateMachine buildSelfAndAncestor() {
    log = [];
    ActionFn logAs(String tag) =>
        (c, e) => log.add(tag);
    return StateMachine.fromJson(
      selfAndAncestorChart,
      actions: {
        'enterP': logAs('enterP'),
        'exitP': logAs('exitP'),
        'enterC1': logAs('enterC1'),
        'exitC1': logAs('exitC1'),
      },
    );
  }

  test(
    'leaf self-transition: entry+exit actions both fire, state stays active',
    () {
      final m = buildSelfAndAncestor();
      expect(m.matches('p.c1'), isTrue);
      log.clear();

      final r = m.send('SELF');

      expect(log, ['exitC1', 'enterC1']);
      expect(m.matches('p.c1'), isTrue); // still active, fully re-entered
      expect(r.changed, isFalse); // configuration set is the same before/after
    },
  );

  test(
    'child targeting its own ancestor re-enters through the initial chain',
    () {
      final m = buildSelfAndAncestor();
      expect(m.matches('p.c1'), isTrue);
      log.clear();

      m.send('TO_PARENT'); // c1 -> p (p is c1's own ancestor)

      // p was fully exited (bottom-up: c1 then p) and fully re-entered
      // (top-down: p then, via its own `initial`, c1 again).
      expect(log, ['exitC1', 'exitP', 'enterP', 'enterC1']);
      expect(m.matches('p.c1'), isTrue);
    },
  );

  test('region-root target inside a parallel machine restarts that region at '
      'its initial child; other regions are untouched', () {
    final log = <String>[];
    final m = StateMachine.fromJson(
      parallelRegionRootChart,
      actions: {
        'enterR1': (c, e) => log.add('enterR1'),
        'exitR1': (c, e) => log.add('exitR1'),
        'enterR1b': (c, e) => log.add('enterR1b'),
        'enterR2': (c, e) => log.add('enterR2'),
      },
    );
    expect(log, ['enterR1', 'enterR2']); // initial entry, both regions
    m.send('BUMP'); // r1: r1a -> r1b
    expect(m.matches('r1.r1b'), isTrue);
    log.clear();

    // RESTART_R1 is handled by the parallel root itself, targeting the
    // region root "r1" directly — this is the case where `_lca` IS the
    // parallel node and `_transitionDomains`' parallel branch sets
    // domain == exitDomain == the target region root == the target itself.
    m.send('RESTART_R1');

    // Region r1 fully exited (from wherever it was, r1b) and fully
    // re-entered, landing back on its `initial` child (r1a) — not stuck
    // re-entering r1b, and not silently vanishing from the configuration
    // (the bug: an empty entry chain would exit r1 and never re-enter it).
    expect(log, ['exitR1', 'enterR1']);
    expect(m.matches('r1.r1a'), isTrue);
    expect(m.matches('r1.r1b'), isFalse);

    // The untouched region: still active, no actions fired for it at all.
    expect(m.matches('r2.r2a'), isTrue);
  });
}
