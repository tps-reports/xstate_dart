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

const triRegion = '''
{
  "id": "tri",
  "type": "parallel",
  "on": {"PING": {"actions": "bump"}},
  "states": {
    "r1": {"initial": "a", "states": {"a": {}}},
    "r2": {"initial": "a", "states": {"a": {}}},
    "r3": {"initial": "a", "states": {"a": {}}}
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
    final m = StateMachine.fromJson(
      par,
      guards: {'engineRunning': (c, e, isActive) => isActive('engine.running')},
    );
    expect(m.matches('lights.off'), isTrue);
    expect(m.matches('engine.stopped'), isTrue);
  });

  test(
    'regions receive events independently; cross-region guard sees live state',
    () {
      final m = StateMachine.fromJson(
        par,
        guards: {
          'engineRunning': (c, e, isActive) => isActive('engine.running'),
        },
      );
      m.send('TICK');
      expect(m.matches('lights.off'), isTrue); // engine not running yet
      m.send('START');
      m.send('TICK');
      expect(m.matches('lights.on'), isTrue); // guard saw engine.running
    },
  );

  test('a transition whose target lies in another region only exits/enters '
      'within the target region; the source region is untouched', () {
    final exited = <String>[];
    final m = StateMachine.fromJson(
      crossRegion,
      actions: {
        'exitLightsOff': (c, e) => exited.add('lights.off'),
        'exitEngineStopped': (c, e) => exited.add('engine.stopped'),
      },
    );

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

  test('a handler declared on the parallel state itself fires once per '
      'send(), not once per active region leaf', () {
    var count = 0;
    final m = StateMachine.fromJson(
      triRegion,
      actions: {'bump': (c, e) => count++},
    );
    expect(m.matches('r1.a'), isTrue);
    expect(m.matches('r2.a'), isTrue);
    expect(m.matches('r3.a'), isTrue);

    // PING has no handler on any leaf/region, so it bubbles from each of
    // the 3 active leaves up to the SAME `on` entry on the parallel root —
    // without dedup, that's the same (source, transition) pair taken 3x.
    m.send('PING');

    expect(count, 1);
  });
}
