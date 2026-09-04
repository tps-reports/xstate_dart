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
    final m = StateMachine.fromJson(gun, actions: {'shoot': (c, e) => shots++});
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

  test('sub-millisecond tick durations accumulate without truncation', () {
    // Regression: tick() used elapsed.inMilliseconds, so a 1.9ms step
    // accrued only 1ms — nearly halving cadence for fine-grained callers.
    final m = StateMachine.fromJson(gun, actions: {'shoot': (c, e) {}});
    m.send('FIRE');
    // 26 ticks x 1.9ms = 49.4ms < 50ms: must NOT fire yet.
    for (var i = 0; i < 26; i++) {
      m.tick(const Duration(microseconds: 1900));
    }
    expect(m.matches('firing'), isTrue);
    // One more (51.3ms total) crosses the threshold.
    m.tick(const Duration(microseconds: 1900));
    expect(m.matches('wait'), isTrue);
  });

  test('60fps frame steps (16.667ms) carry their fractional remainder', () {
    final m = StateMachine.fromJson(gun, actions: {'shoot': (c, e) {}});
    m.send('FIRE');
    // 3 x 16.667ms = 50.001ms >= 50ms. Truncation (3 x 16 = 48ms) would
    // wrongly leave the machine in "firing" here.
    m.tick(const Duration(microseconds: 16667));
    m.tick(const Duration(microseconds: 16667));
    expect(m.matches('firing'), isTrue); // 33.334ms
    m.tick(const Duration(microseconds: 16667));
    expect(m.matches('wait'), isTrue);
  });

  test(
    'snapshot keeps whole-ms timers; sub-ms remainder is dropped on save',
    () {
      final m = StateMachine.fromJson(gun, actions: {'shoot': (c, e) {}});
      m.send('FIRE');
      m.tick(const Duration(microseconds: 30500)); // 30.5ms accumulated
      final snapshot = m.toSnapshotJson();
      // The serialized format stays "timersMs" (whole milliseconds): the
      // 0.5ms remainder is intentionally dropped at save time (documented,
      // bounded loss), so a restored machine needs the full remaining 20ms.
      final m2 = StateMachine.fromJson(gun, actions: {'shoot': (c, e) {}});
      m2.restoreSnapshot(snapshot);
      m2.tick(const Duration(microseconds: 19500)); // 30 + 19.5 = 49.5 < 50
      expect(m2.matches('firing'), isTrue);
      m2.tick(const Duration(microseconds: 500)); // 50.0ms exactly
      expect(m2.matches('wait'), isTrue);
    },
  );
}
