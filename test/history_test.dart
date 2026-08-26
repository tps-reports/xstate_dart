import 'package:test/test.dart';
import 'package:xstate_dart/xstate_dart.dart';

const wizard = '''
{
  "id": "w",
  "initial": "method",
  "states": {
    "method": {
      "initial": "cash",
      "on": {"NEXT": "review"},
      "states": {
        "cash": {"on": {"SWITCH_CHECK": "check"}},
        "check": {"on": {"SWITCH_CASH": "cash"}},
        "hist": {"history": true}
      }
    },
    "review": {"on": {"PREVIOUS": "method.hist"}}
  }
}
''';

void main() {
  test('history restores last child on re-entry', () {
    final m = StateMachine.fromJson(wizard);
    m.send('SWITCH_CHECK');
    expect(m.matches('method.check'), isTrue);
    m.send('NEXT');
    expect(m.matches('review'), isTrue);
    m.send('PREVIOUS');
    expect(m.matches('method.check'), isTrue); // not initial "cash"
  });

  test('history falls back to initial when never visited', () {
    final m = StateMachine.fromJson(wizard);
    // jump straight out and back without changing sub-state
    m.send('NEXT');
    m.send('PREVIOUS');
    expect(m.matches('method.cash'), isTrue);
  });
}
