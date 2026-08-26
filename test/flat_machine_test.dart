import 'package:test/test.dart';
import 'package:xstate_dart/xstate_dart.dart';

const flatChart = '''
{
  "id": "toggle",
  "initial": "off",
  "context": {"count": 0},
  "states": {
    "off": {"on": {"FLIP": {"target": "on", "actions": "increment"}}},
    "on": {
      "entry": "log",
      "exit": "log",
      "on": {
        "FLIP": "off",
        "LOCKED_FLIP": {"target": "off", "guard": "never"}
      }
    }
  }
}
''';

void main() {
  StateMachine build(List<String> logbook) => StateMachine.fromJson(
        flatChart,
        actions: {
          'increment': (ctx, event) =>
              ctx['count'] = (ctx['count'] as int) + 1,
          'log': (ctx, event) => logbook.add('log'),
        },
        guards: {'never': (ctx, event, isActive) => false},
      );

  test('starts in initial state', () {
    final m = build([]);
    expect(m.matches('off'), isTrue);
    expect(m.activeStates, {'off'});
  });

  test('transitions on event and runs transition action', () {
    final m = build([]);
    final r = m.send('FLIP');
    expect(r.changed, isTrue);
    expect(m.matches('on'), isTrue);
    expect(m.context['count'], 1);
  });

  test('entry and exit actions fire', () {
    final logbook = <String>[];
    final m = build(logbook);
    m.send('FLIP'); // enters on -> entry log
    m.send('FLIP'); // exits on -> exit log
    expect(logbook, ['log', 'log']);
  });

  test('failed guard blocks transition', () {
    final m = build([]);
    m.send('FLIP');
    final r = m.send('LOCKED_FLIP');
    expect(r.changed, isFalse);
    expect(m.matches('on'), isTrue);
  });

  test('unknown event is a no-op', () {
    final m = build([]);
    expect(m.send('NOPE').changed, isFalse);
  });

  test('event payload flows through to both guards and actions, alongside type', () {
    const payloadChart = '''
    {
      "id": "pl",
      "initial": "idle",
      "states": {
        "idle": {"on": {"GO": {"target": "done", "guard": "hasFoo", "actions": "capture"}}},
        "done": {}
      }
    }
    ''';
    Map<String, dynamic>? seen;
    final m = StateMachine.fromJson(payloadChart, actions: {
      'capture': (ctx, event) => seen = Map.of(event),
    }, guards: {
      'hasFoo': (ctx, event, isActive) => event['foo'] == 'bar',
    });

    final blocked = m.send('GO', {'foo': 'nope'});
    expect(blocked.changed, isFalse); // guard read the payload and rejected it
    expect(m.matches('idle'), isTrue);

    final r = m.send('GO', {'foo': 'bar'});
    expect(r.changed, isTrue);
    expect(m.matches('done'), isTrue);
    expect(seen, {'type': 'GO', 'foo': 'bar'}); // action saw type + payload
  });
}
