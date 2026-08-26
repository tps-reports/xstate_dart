import 'package:test/test.dart';
import 'package:xstate_dart/xstate_dart.dart';

const gun = '''
{
  "id": "g",
  "initial": "wait",
  "states": {
    "wait": {"on": {"FIRE": "firing"}},
    "firing": {"entry": "shoot", "after": {"50": {"target": "wait"}}}
  }
}
''';

void main() {
  test('after fires when accumulated game time passes threshold', () {
    var shots = 0;
    final m = StateMachine.fromJson(gun,
        actions: {'shoot': (c, e) => shots++});
    m.send('FIRE');
    expect(m.matches('firing'), isTrue);
    m.tick(const Duration(milliseconds: 30));
    expect(m.matches('firing'), isTrue); // 30 < 50
    m.tick(const Duration(milliseconds: 30));
    expect(m.matches('wait'), isTrue); // 60 >= 50
    expect(shots, 1);
  });

  test('re-entry resets the timer', () {
    final m = StateMachine.fromJson(gun, actions: {'shoot': (c, e) {}});
    m.send('FIRE');
    m.tick(const Duration(milliseconds: 40));
    m.tick(const Duration(milliseconds: 20)); // fires -> wait
    m.send('FIRE'); // re-enter firing
    m.tick(const Duration(milliseconds: 40));
    expect(m.matches('firing'), isTrue); // timer restarted
  });
}
