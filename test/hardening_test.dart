import 'package:test/test.dart';
import 'package:xstate_dart/xstate_dart.dart';

// Small coverage bonus for the "minor" findings in the final-review fix
// wave that don't warrant their own file: malformed entry/exit now fails
// loudly (finding 6), a root-level `after` is rejected at parse time
// (finding 8), and StateNode.children is unmodifiable post-parse (finding 7).

void main() {
  test('malformed "entry" (not a string/list/null) throws FormatException', () {
    const badEntry = '{"id":"b","initial":"s","states":{"s":{"entry":42}}}';
    expect(() => StateMachine.fromJson(badEntry), throwsFormatException);
  });

  test('malformed "exit" (not a string/list/null) throws FormatException', () {
    const badExit = '{"id":"b","initial":"s","states":{"s":{"exit":42}}}';
    expect(() => StateMachine.fromJson(badExit), throwsFormatException);
  });

  test('a root-level "after" is rejected at parse time', () {
    const rootAfter =
        '{"id":"r","initial":"s","after":{"100":"s"},"states":{"s":{}}}';
    expect(() => StateMachine.fromJson(rootAfter), throwsFormatException);
  });

  test('StateNode.children is unmodifiable after parse', () {
    const chart = '{"id":"c","initial":"s","states":{"s":{}}}';
    final m = StateMachine.fromJson(chart);
    expect(
      () => m.root.children['new'] = m.root.children['s']!,
      throwsUnsupportedError,
    );
  });
}
