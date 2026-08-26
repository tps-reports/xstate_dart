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

const crossRegion = '''
{
  "id": "cr",
  "type": "parallel",
  "states": {
    "lights": {
      "initial": "off",
      "states": {
        "off": {"exit": "exitLightsOff", "on": {"JUMP": {"target": "engine.running"}}},
        "on": {}
      }
    },
    "engine": {
      "initial": "stopped",
      "states": {
        "stopped": {"exit": "exitEngineStopped"},
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

  test(
      'a transition whose target lies in another region only exits/enters '
      'within the target region; the source region is untouched', () {
    final exited = <String>[];
    final m = StateMachine.fromJson(crossRegion, actions: {
      'exitLightsOff': (c, e) => exited.add('lights.off'),
      'exitEngineStopped': (c, e) => exited.add('engine.stopped'),
    });

    m.send('JUMP'); // handled by lights.off, targets engine.running

    // Source region's active leaf is unchanged.
    expect(m.matches('lights.off'), isTrue);
    expect(m.matches('lights.on'), isFalse);

    // Target region has exactly its one new active leaf.
    expect(m.matches('engine.running'), isTrue);
    expect(m.matches('engine.stopped'), isFalse);

    // Target region's previous leaf was exited; source region's leaf was
    // NOT exited (it's still active, so it couldn't have been).
    expect(exited, ['engine.stopped']);
  });
}
