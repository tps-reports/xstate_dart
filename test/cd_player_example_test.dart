// Acceptance test for the CD player example chart (example/main.dart) —
// keeps the published example honest: if the interpreter or the chart
// drifts, this fails before the example lies to a reader.
import 'package:test/test.dart';

import '../example/main.dart';

void main() {
  test('closing an empty tray goes to empty, not loaded', () {
    final p = buildCdPlayer();
    expect(p.matches('trayOpen'), isTrue);
    p.send('CLOSE');
    expect(p.matches('empty'), isTrue);
  });

  test('insert + close lands in loaded.stopped with track reset', () {
    final p = buildCdPlayer();
    p.send('INSERT_DISC');
    p.send('CLOSE');
    expect(p.matches('loaded.stopped'), isTrue);
    expect(p.context['track'], 1);
  });

  test('a 4-minute tick auto-advances the track and restarts the timer', () {
    final log = <String>[];
    final p = buildCdPlayer(log: log);
    p.send('INSERT_DISC');
    p.send('CLOSE');
    p.send('PLAY');
    expect(log, ['laser on (track 1)']);

    p.tick(const Duration(minutes: 4));
    expect(p.matches('loaded.playing'), isTrue);
    expect(p.context['track'], 2);
    // External self-transition re-entered playing: laser cycled.
    expect(log, ['laser on (track 1)', 'laser off', 'laser on (track 2)']);

    // Timer restarted: 3 more minutes is not enough for track 2 to end.
    p.tick(const Duration(minutes: 3));
    expect(p.context['track'], 2);
  });

  test('finishing the last track stops and resets to track 1', () {
    final p = buildCdPlayer();
    p.send('INSERT_DISC');
    p.send('CLOSE');
    p.send('PLAY');
    p.send('NEXT');
    p.send('NEXT'); // track 3 of 3
    expect(p.context['track'], 3);
    p.send('NEXT'); // guard hasNextTrack blocks
    expect(p.context['track'], 3);
    p.tick(const Duration(minutes: 4));
    expect(p.matches('loaded.stopped'), isTrue);
    expect(p.context['track'], 1); // stopped's entry resetTrack
  });

  test('PREV is guarded on track 1 and works above it', () {
    final p = buildCdPlayer();
    p.send('INSERT_DISC');
    p.send('CLOSE');
    p.send('PLAY');
    p.send('PREV'); // guard notFirstTrack blocks
    expect(p.context['track'], 1);
    p.send('NEXT');
    expect(p.context['track'], 2);
    // Note: `changed` stays false here — NEXT/PREV are external
    // self-transitions, and `changed` reports configuration change, not
    // re-entry. The observable effects are the context and the entry/exit
    // actions (covered in the auto-advance test above).
    p.send('PREV');
    expect(p.context['track'], 1);
    expect(p.matches('loaded.playing'), isTrue);
  });

  test(
    'eject mid-pause, close again: history resumes paused at same track',
    () {
      final p = buildCdPlayer();
      p.send('INSERT_DISC');
      p.send('CLOSE');
      p.send('PLAY');
      p.send('NEXT');
      p.send('PAUSE');
      p.send('OPEN'); // parent-level handler exits the whole loaded subtree
      expect(p.matches('trayOpen'), isTrue);
      p.send('CLOSE'); // guard hasDisc -> loaded.hist
      expect(p.matches('loaded.paused'), isTrue);
      expect(p.context['track'], 2);
    },
  );

  test('removing the disc makes CLOSE fall through to empty', () {
    final p = buildCdPlayer();
    p.send('INSERT_DISC');
    p.send('REMOVE_DISC');
    p.send('CLOSE');
    expect(p.matches('empty'), isTrue);
  });

  test('snapshot restores paused configuration and track', () {
    final p = buildCdPlayer();
    p.send('INSERT_DISC');
    p.send('CLOSE');
    p.send('PLAY');
    p.send('NEXT');
    p.send('PAUSE');
    final memo = p.toSnapshotJson();

    p.send('STOP');
    expect(p.matches('loaded.stopped'), isTrue);
    expect(p.context['track'], 1);

    p.restoreSnapshot(memo);
    expect(p.matches('loaded.paused'), isTrue);
    expect(p.context['track'], 2);
  });
}
