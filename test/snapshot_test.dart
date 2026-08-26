import 'dart:convert';

import 'package:test/test.dart';
import 'package:xstate_dart/xstate_dart.dart';

const _chart = '''
{"id":"s","initial":"m","context":{"gold":7},"states":{
  "m":{"initial":"a","on":{"OUT":"z"},"states":{
    "a":{"on":{"B":"b"}},"b":{},"hist":{"history":true}}},
  "z":{"on":{"BACK":"m.hist"},"after":{"100":{"target":"m.hist"}}}}}
''';

const _parallelChart = '''
{"id":"p","type":"parallel","states":{
  "a":{"initial":"a1","states":{
    "a1":{"on":{"NEXT_A":"a2"}},
    "a2":{"initial":"x","states":{"x":{"on":{"DEEPER":"y"}},"y":{}}}}},
  "b":{"initial":"b1","states":{"b1":{"on":{"NEXT_B":"b2"}},"b2":{}}}}}
''';

void main() {
  test('snapshot round-trips configuration, context, history, timers', () {
    const chart = _chart;
    final m1 = StateMachine.fromJson(chart);
    m1.send('B');
    m1.send('OUT');
    m1.tick(const Duration(milliseconds: 40));
    final snap = m1.toSnapshotJson();

    final m2 = StateMachine.fromJson(chart)..restoreSnapshot(snap);
    expect(m2.matches('z'), isTrue);
    expect(m2.context['gold'], 7);
    m2.tick(const Duration(milliseconds: 60)); // 40 restored + 60 = 100
    expect(m2.matches('m.b'), isTrue); // via history
  });

  test('snapshot round-trips a nested + parallel configuration', () {
    final m1 = StateMachine.fromJson(_parallelChart);
    m1.send('NEXT_A'); // region a: a1 -> a2, which descends into a2.x
    m1.send('DEEPER'); // region a: a2.x -> a2.y
    m1.send('NEXT_B'); // region b: b1 -> b2
    final snap = m1.toSnapshotJson();

    final m2 = StateMachine.fromJson(_parallelChart)..restoreSnapshot(snap);
    expect(m2.matches('a.a2.y'), isTrue);
    expect(m2.matches('b.b2'), isTrue);
    expect(m2.activeStates, equals(m1.activeStates));
  });

  test('restoreSnapshot rejects a compound (non-leaf) configuration path',
      () {
    final m1 = StateMachine.fromJson(_chart);
    final decoded = jsonDecode(m1.toSnapshotJson()) as Map<String, dynamic>;
    decoded['configuration'] = ['m']; // "m" is compound; "m.a" is the leaf
    final badSnap = jsonEncode(decoded);

    final m2 = StateMachine.fromJson(_chart);
    expect(
      () => m2.restoreSnapshot(badSnap),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          contains('not an atomic (leaf) state'))),
    );
  });

  test('restoreSnapshot rejects a history entry naming an unknown child',
      () {
    final m1 = StateMachine.fromJson(_chart);
    final decoded = jsonDecode(m1.toSnapshotJson()) as Map<String, dynamic>;
    decoded['history'] = {'m': 'bogus'};
    final badSnap = jsonEncode(decoded);

    final m2 = StateMachine.fromJson(_chart);
    expect(
      () => m2.restoreSnapshot(badSnap),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          contains('unknown or invalid child "bogus"'))),
    );
  });

  test('restoreSnapshot rejects a history entry naming a history child', () {
    final m1 = StateMachine.fromJson(_chart);
    final decoded = jsonDecode(m1.toSnapshotJson()) as Map<String, dynamic>;
    decoded['history'] = {'m': 'hist'}; // "hist" is itself the pseudo-state
    final badSnap = jsonEncode(decoded);

    final m2 = StateMachine.fromJson(_chart);
    expect(
      () => m2.restoreSnapshot(badSnap),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          contains('unknown or invalid child "hist"'))),
    );
  });

  test('restoreSnapshot rejects a snapshot missing "configuration"', () {
    final badSnap = jsonEncode({'context': {}, 'history': {}, 'timersMs': {}});

    final m2 = StateMachine.fromJson(_chart);
    expect(
      () => m2.restoreSnapshot(badSnap),
      throwsA(isA<FormatException>()),
    );
  });

  test('restoreSnapshot rejects a "configuration" that is not a list', () {
    final badSnap = jsonEncode({
      'configuration': 'm.a',
      'context': {},
      'history': {},
      'timersMs': {}
    });

    final m2 = StateMachine.fromJson(_chart);
    expect(
      () => m2.restoreSnapshot(badSnap),
      throwsA(isA<FormatException>()),
    );
  });
}
