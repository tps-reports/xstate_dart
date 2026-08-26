import 'package:test/test.dart';
import 'package:xstate_dart/xstate_dart.dart';

const nestedChart = '''
{
  "id": "n",
  "initial": "a",
  "on": {"RESET": "a"},
  "states": {
    "a": {
      "entry": "enterA",
      "initial": "a1",
      "on": {"GO_B": "b"},
      "states": {
        "a1": {"entry": "enterA1", "exit": "exitA1", "on": {"IN": ".a2", "OUT": "a2"}},
        "a2": {"on": {"DEEP": "b.b1.b1x"}}
      }
    },
    "b": {
      "initial": "b1",
      "exit": "exitB",
      "states": {
        "b1": {
          "initial": "b1x",
          "states": {"b1x": {}, "b1y": {}}
        }
      }
    }
  }
}
''';

void main() {
  List<String> log = [];
  StateMachine build() {
    log = [];
    ActionFn logAs(String tag) => (ctx, e) => log.add(tag);
    return StateMachine.fromJson(nestedChart, actions: {
      'enterA': logAs('enterA'),
      'enterA1': logAs('enterA1'),
      'exitA1': logAs('exitA1'),
      'exitB': logAs('exitB'),
    });
  }

  test('initial entry descends to leaf, entry actions top-down', () {
    final m = build();
    expect(m.matches('a'), isTrue);
    expect(m.matches('a.a1'), isTrue);
    expect(log, ['enterA', 'enterA1']);
  });

  test('relative .child target', () {
    final m = build();
    m.send('IN'); // a.a1 -> a.a2 via ".a2" (child of source's PARENT a — see note)
    expect(m.matches('a.a2'), isTrue);
  });

  test('sibling bare-name target', () {
    final m = build();
    m.send('OUT'); // a.a1 -> a.a2 via sibling name
    expect(m.matches('a.a2'), isTrue);
    expect(log, contains('exitA1'));
  });

  test('absolute deep target enters through initials of remainder', () {
    final m = build();
    m.send('OUT');
    m.send('DEEP'); // a.a2 -> b.b1.b1x by absolute path
    expect(m.matches('b.b1.b1x'), isTrue);
    expect(m.matches('a'), isFalse);
  });

  test('event handled by ancestor when leaf has no handler', () {
    final m = build();
    m.send('GO_B'); // handled by "a" while leaf is a.a1
    expect(m.matches('b.b1.b1x'), isTrue);
  });

  test('previousStates is the ancestor closure, same shape as activeStates', () {
    final m = build();
    final r = m.send('OUT'); // a.a1 -> a.a2
    // Before the transition the active leaf was "a.a1" — previousStates
    // must include its ancestor "a" too, exactly like activeStates does for
    // the current configuration, not just the raw leaf path.
    expect(r.previousStates, {'a', 'a.a1'});
    expect(r.activeStates, {'a', 'a.a2'});
  });

  test('exit actions run bottom-up on leaving a compound state', () {
    final m = build();
    m.send('GO_B');
    log.clear();
    // Top-level "on" (RESET) is the only way back out of "b" in this chart;
    // added specifically so this test can drive an exit of "b" and assert
    // exitB actually fires, bottom-up, before entry actions on the way back
    // into "a" run.
    m.send('RESET');
    expect(log, ['exitB', 'enterA', 'enterA1']);
    expect(m.matches('a'), isTrue);
  });
}
