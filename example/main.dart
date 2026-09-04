// The classic Harel-style CD player, as an XState-JSON chart.
//
// Demonstrates:
// - hierarchy: `loaded` handles OPEN for all of its children
// - guarded alternatives: CLOSE goes to `loaded` or `empty` by `hasDisc`
// - context actions: track number lives in context, mutated by actions
// - deterministic `after`: a 4-minute track "plays" instantly under
//   `tick(Duration(minutes: 4))` — no Timer, no waiting
// - history: eject mid-pause, close the tray, and resume exactly there
// - snapshots: save while paused, stop, restore, and be paused again
//
// ignore_for_file: avoid_print

import 'package:xstate_dart/xstate_dart.dart';

const cdPlayerChart = '''
{
  "id": "cdPlayer",
  "initial": "trayOpen",
  "context": {"hasDisc": false, "track": 1, "totalTracks": 3},
  "states": {
    "trayOpen": {
      "on": {
        "INSERT_DISC": {"actions": "acceptDisc"},
        "REMOVE_DISC": {"actions": "removeDisc"},
        "CLOSE": [
          {"target": "loaded.hist", "guard": "hasDisc"},
          {"target": "empty"}
        ]
      }
    },
    "empty": {"on": {"OPEN": "trayOpen"}},
    "loaded": {
      "initial": "stopped",
      "on": {"OPEN": "trayOpen"},
      "states": {
        "stopped": {
          "entry": "resetTrack",
          "on": {"PLAY": "playing"}
        },
        "playing": {
          "entry": "laserOn",
          "exit": "laserOff",
          "on": {
            "PAUSE": "paused",
            "STOP": "stopped",
            "NEXT": {"target": "playing", "guard": "hasNextTrack",
                     "actions": "nextTrack"},
            "PREV": {"target": "playing", "guard": "notFirstTrack",
                     "actions": "prevTrack"}
          },
          "after": {
            "240000": [
              {"target": "playing", "guard": "hasNextTrack",
               "actions": "nextTrack"},
              {"target": "stopped"}
            ]
          }
        },
        "paused": {"on": {"PLAY": "playing", "STOP": "stopped"}},
        "hist": {"history": true}
      }
    }
  }
}
''';

/// Build the CD player. [log] collects laser on/off entry/exit firings so
/// tests (and curious readers) can observe them.
StateMachine buildCdPlayer({List<String>? log}) => StateMachine.fromJson(
  cdPlayerChart,
  actions: {
    'acceptDisc': (ctx, event) => ctx['hasDisc'] = true,
    'removeDisc': (ctx, event) => ctx['hasDisc'] = false,
    'resetTrack': (ctx, event) => ctx['track'] = 1,
    'nextTrack': (ctx, event) => ctx['track'] = (ctx['track'] as int) + 1,
    'prevTrack': (ctx, event) => ctx['track'] = (ctx['track'] as int) - 1,
    'laserOn': (ctx, event) => log?.add('laser on (track ${ctx['track']})'),
    'laserOff': (ctx, event) => log?.add('laser off'),
  },
  guards: {
    'hasDisc': (ctx, event, isActive) => ctx['hasDisc'] == true,
    'hasNextTrack': (ctx, event, isActive) =>
        (ctx['track'] as int) < (ctx['totalTracks'] as int),
    'notFirstTrack': (ctx, event, isActive) => (ctx['track'] as int) > 1,
  },
);

void main() {
  final player = buildCdPlayer();
  void show(String what) => print(
    '$what -> ${player.activeStates.reduce((a, b) => a.length > b.length ? a : b)}'
    ' (track ${player.context['track']})',
  );

  show('power on'); // trayOpen
  player.send('CLOSE');
  show('close empty tray'); // empty — no disc
  player.send('OPEN');
  player.send('INSERT_DISC');
  player.send('CLOSE');
  show('insert disc, close'); // loaded.stopped
  player.send('PLAY');
  show('play'); // loaded.playing, track 1

  // The clock is injected: four minutes pass in zero wall time.
  player.tick(const Duration(minutes: 4));
  show('4 minutes later'); // track 2 auto-advanced
  player.send('NEXT');
  show('skip'); // track 3 (last)
  player.tick(const Duration(minutes: 4));
  show('last track finishes'); // loaded.stopped, track 1

  player.send('PLAY');
  player.send('NEXT');
  player.send('PAUSE');
  show('pause on track 2'); // loaded.paused

  final memo = player.toSnapshotJson(); // snapshot mid-pause
  player.send('OPEN');
  show('eject'); // trayOpen
  player.send('CLOSE');
  show('close again'); // history: paused, track 2

  player.send('STOP');
  show('stop'); // stopped, track reset
  player.restoreSnapshot(memo);
  show('restore snapshot'); // paused, track 2 again
}
