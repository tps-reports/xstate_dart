import 'package:test/test.dart';
import 'package:xstate_dart/xstate_dart.dart';

const par = '''
{
  "id": "p",
  "type": "parallel",
  "states": {
    "lights": {
      "initial": "off",
      "states": {
        "off": {"on": {"TICK": {"target": "on", "guard": "engineRunning"}}},
        "on": {}
      }
    },
    "engine": {
      "initial": "stopped",
      "states": {
        "stopped": {"on": {"START": "running"}},
        "running": {}
      }
    }
  }
}
''';

void main() {
  test('entering parallel root activates every region', () {
    final m = StateMachine.fromJson(par,
        guards: {'engineRunning': (c, e, isActive) => isActive('engine.running')});
    expect(m.matches('lights.off'), isTrue);
    expect(m.matches('engine.stopped'), isTrue);
  });

  test('regions receive events independently; cross-region guard sees live state', () {
    final m = StateMachine.fromJson(par,
        guards: {'engineRunning': (c, e, isActive) => isActive('engine.running')});
    m.send('TICK');
    expect(m.matches('lights.off'), isTrue); // engine not running yet
    m.send('START');
    m.send('TICK');
    expect(m.matches('lights.on'), isTrue); // guard saw engine.running
  });
}
