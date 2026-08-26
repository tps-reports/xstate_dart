import 'dart:io';
import 'package:test/test.dart';
import 'package:xstate_dart/xstate_dart.dart';

void main() {
  late Map<String, dynamic> env; // fake game environment
  late int fireCount;
  late List<String> moves;

  StateMachine build() {
    env = {'present': false, 'x': 0.5, 'canLeft': true, 'canRight': true};
    fireCount = 0;
    moves = [];
    final json = File('test/fixtures/agent_one.json').readAsStringSync();
    return StateMachine.fromJson(json, actions: {
      'updateColliding': (c, e) =>
          (c['CD'] as Map)['colliding'] = env['present'],
      'moveLeft': (c, e) => moves.add('L'),
      'moveRight': (c, e) => moves.add('R'),
      'stopShip': (c, e) => moves.add('STOP'),
      'setLastDirLeft': (c, e) => c['lastDir'] = 'LEFT',
      'setLastDirRight': (c, e) => c['lastDir'] = 'RIGHT',
      'fireWeapon': (c, e) => fireCount++,
    }, guards: {
      'isEnvNotNull': (c, e, a) => true,
      'isCollidingPresent': (c, e, a) => (c['CD'] as Map)['colliding'] == true,
      'isCollidingNotPresent': (c, e, a) => (c['CD'] as Map)['colliding'] != true,
      'shouldMoveLeft': (c, e, a) =>
          c['lastDir'] == 'RIGHT' && env['canLeft'] == true,
      'isRightCollisionOrBlocked': (c, e, a) =>
          a('BorderDetection.RightCollision') || env['canRight'] != true,
      'isLeftCollisionOrBlocked': (c, e, a) =>
          a('BorderDetection.LeftCollision') || env['canLeft'] != true,
      'canFire': (c, e, a) => (c['CD'] as Map)['colliding'] == true,
      'hasHitLeftBorder': (c, e, a) => (env['x'] as double) < 0.01,
      'hasHitRightBorder': (c, e, a) => (env['x'] as double) > 0.9,
      'hasLeftBorderCleared': (c, e, a) => (env['x'] as double) >= 0.01,
      'hasRightBorderCleared': (c, e, a) => (env['x'] as double) <= 0.9,
    });
  }

  void step(StateMachine m, {int ms = 16}) {
    m.send('TICK');
    m.tick(Duration(milliseconds: ms));
  }

  test('all four regions come up', () {
    final m = build();
    step(m);
    expect(m.matches('CollisionDetection'), isTrue);
    expect(m.matches('Steering'), isTrue);
    expect(m.matches('GunControl.Wait'), isTrue);
    expect(m.matches('BorderDetection.Center'), isTrue);
  });

  test('colliding target triggers move-left (lastDir RIGHT) and firing', () {
    final m = build();
    step(m); // regions leave Idle
    env['present'] = true;
    step(m); // Detection records colliding; Steering -> Move -> Left; Gun -> Fire
    step(m);
    expect(m.matches('Steering.Active.Move.Left'), isTrue);
    expect(moves, contains('L'));
    expect(fireCount, greaterThan(0));
  });

  test('gun refire cadence honours after(50ms)', () {
    final m = build();
    step(m);
    env['present'] = true;
    step(m);
    step(m); // context written by do-activity actions is visible to guards from the next TICK
    final before = fireCount;
    step(m, ms: 10); // 10ms: still in Fire
    expect(fireCount, before);
    step(m, ms: 50); // past 50ms: Fire->Wait, next TICK can fire again
    step(m);
    expect(fireCount, greaterThan(before));
  });

  test('right border flips steering to Left and exit stops ship', () {
    final m = build();
    step(m);
    env['present'] = true;
    step(m);
    env['x'] = 0.95; // hit right border
    step(m);
    expect(m.matches('BorderDetection.RightCollision'), isTrue);
    expect(m.matches('Steering.Active.Move.Left'), isTrue);
    env['present'] = false; // target gone -> Move exits -> stopShip
    step(m);
    step(m); // context written by do-activity actions is visible to guards from the next TICK
    expect(m.matches('Steering.Active.HoldPosition'), isTrue);
    expect(moves.last, 'STOP');
  });
}
