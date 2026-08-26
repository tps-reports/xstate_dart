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
  StateMachine build(int n) => StateMachine.fromJson(chooser,
      actions: {
        'bump': (c, e) => c['n'] = 5,
        'detect': (c, e) => c['detections'] = (c['detections'] as int) + 1,
      },
      guards: {'isLow': (c, e, a) => (c['n'] as int) < 3});

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
}
