import 'package:test/test.dart';
import 'package:xstate_dart/xstate_dart.dart';

void main() {
  test('snapshot round-trips configuration, context, history, timers', () {
    const chart = '''
    {"id":"s","initial":"m","context":{"gold":7},"states":{
      "m":{"initial":"a","on":{"OUT":"z"},"states":{
        "a":{"on":{"B":"b"}},"b":{},"hist":{"history":true}}},
      "z":{"on":{"BACK":"m.hist"},"after":{"100":{"target":"m.hist"}}}}}
    ''';
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
}
