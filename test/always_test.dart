import 'package:test/test.dart';
import 'package:xstate_dart/xstate_dart.dart';

const chooser = '''
{
  "id": "c",
  "initial": "deciding",
  "context": {"n": 0, "detections": 0},
  "states": {
    "deciding": {
      "always": [
        {"target": "low", "guard": "isLow"},
        {"target": "high"}
      ]
    },
    "low": {"on": {"RESET": {"target": "deciding", "actions": "bump"}}},
    "high": {},
    "watch": {"always": {"actions": "detect"}}
  }
}
''';

void main() {
  StateMachine build(int n) => StateMachine.fromJson(
    chooser,
    actions: {
      'bump': (c, e) => c['n'] = 5,
      'detect': (c, e) => c['detections'] = (c['detections'] as int) + 1,
    },
    guards: {'isLow': (c, e, a) => (c['n'] as int) < 3},
  );

  test('choice resolves immediately on initial entry', () {
    expect(build(0).matches('low'), isTrue);
  });

  test('re-entering a choice state re-evaluates with new context', () {
    final m = build(0);
    m.send('RESET'); // bump sets n=5, re-enter deciding -> high
    expect(m.matches('high'), isTrue);
  });

  test('infinite always loop throws', () {
    const loop = '''
    {"id":"l","initial":"a","states":{
      "a":{"always":{"target":"b"}},
      "b":{"always":{"target":"a"}}}}
    ''';
    expect(() => StateMachine.fromJson(loop), throwsStateError);
  });

  test('compound state with no initial and no targeted always throws', () {
    // "parent" has children (so it isn't atomic) but declares neither
    // `initial` nor any targeted `always` to pick one on entry — this must
    // still be a hard configuration error, not silently relaxed by the
    // compound-without-initial-via-always allowance.
    const noInitialNoAlways = '''
    {"id":"n","initial":"parent","states":{
      "parent":{"states":{"child":{}}}
    }}
    ''';
    expect(() => StateMachine.fromJson(noInitialNoAlways), throwsStateError);
  });

  group('target-less always (do-activity)', () {
    const watcher = '''
    {
      "id": "w",
      "initial": "watching",
      "context": {"count": 0, "armed": true},
      "states": {
        "watching": {
          "always": {"actions": "tick", "guard": "armed"},
          "on": {"NOOP": {"actions": "noop"}}
        }
      }
    }
    ''';

    StateMachine buildWatcher({required bool armed}) => StateMachine.fromJson(
      watcher,
      actions: {
        'tick': (c, e) => c['count'] = (c['count'] as int) + 1,
        'noop': (c, e) {},
      },
      guards: {'armed': (c, e, a) => armed},
    );

    test('fires once on initial-entry settle', () {
      final m = buildWatcher(armed: true);
      expect(m.context['count'], 1);
    });

    test('fires once more per subsequent send()', () {
      final m = buildWatcher(armed: true);
      expect(m.context['count'], 1); // initial-entry settle
      m.send('NOOP'); // no target change; settle still runs after send
      expect(m.context['count'], 2);
      m.send('NOOP');
      expect(m.context['count'], 3);
    });

    test('guard false: never fires', () {
      final m = buildWatcher(armed: false);
      expect(m.context['count'], 0);
      m.send('NOOP');
      expect(m.context['count'], 0);
    });
  });
}
