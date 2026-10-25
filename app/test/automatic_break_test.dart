import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/domain/timer_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppController c;
  late List<String> cues;
  var suspended = false, failAlerts = false;
  setUp(() async {
    c = AppController()..store = LocalStore.testing(NativeDatabase.memory());
    c.clock.stop();
    c.settings = const Settings(shortBreak: 3, longBreak: 9);
    cues = [];
    suspended = false;
    failAlerts = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, (call) async {
      if (call.method == 'takeSuspend') return suspended;
      if (call.method == 'timerSound') {
        cues.add((call.arguments as Map)['kind'] as String);
      }
      if (failAlerts && ['timerSound', 'notify'].contains(call.method)) {
        throw PlatformException(code: 'DEVICE_UNAVAILABLE');
      }
      return null;
    });
  });
  tearDown(() async {
    await c.store.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, null);
  });
  void expiredFocus(String id) {
    c.engine.start(
        id: id,
        device: 'test',
        seconds: 60,
        now: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
        tick: c.clock.elapsedMilliseconds - 60000);
  }

  test(
      'focus finishes once, saves exact time, and automatically starts configured short rest',
      () async {
    expiredFocus('one');
    await c.tick();
    expect(c.phase, Phase.rest);
    expect(c.remainingMs, 180000);
    expect(c.sessions.single.completed, true);
    expect(c.sessions.single.milliseconds, 60000);
    expect(c.completedCycle, 1);
    expect(await c.store.get('checkpoint'), isNull);
    expect(await c.store.get('cycle'), 1);
    await c.tick();
    expect(c.sessions.length, 1);
    expect(cues, ['focus']);
  });

  test('sub-minute completed session stays in history without advancing cycle',
      () async {
    c.engine.start(
        id: 'invalid',
        device: 'test',
        seconds: 1,
        now: DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
        tick: c.clock.elapsedMilliseconds - 1000);
    await c.tick();
    expect(c.sessions.single.isValidFocus, false);
    expect(c.sessions.single.countsAsPomodoro, false);
    expect(c.completedCycle, 0);
    expect(c.durationMs, 180000);
    expect(c.phase, Phase.rest);
  });

  test('fourth completion automatically starts long rest', () async {
    for (var i = 1; i <= 4; i++) {
      expiredFocus('session-$i');
      await c.tick();
      expect(c.phase, Phase.rest);
      expect(c.durationMs, i == 4 ? 540000 : 180000);
      await c.end();
    }
    expect(c.completedCycle, 4);
    expect(c.sessions.length, 4);
    expect(cues, ['focus', 'focus', 'focus', 'focus']);
  });

  test('rest ends with a different cue and waits indefinitely for manual focus',
      () async {
    expiredFocus('one');
    await c.tick();
    c.engine.startRest(1, c.clock.elapsedMilliseconds - 1000);
    await c.tick();
    expect(c.phase, Phase.ended);
    expect(c.active, false);
    for (var i = 0; i < 3; i++) {
      await c.tick();
    }
    expect(c.phase, Phase.ended);
    expect(c.completedCycle, 1);
    expect(c.sessions.length, 1);
    expect(cues, ['focus', 'rest']);
    await c.startFocus(testSeconds: 1);
    expect(c.phase, Phase.focus);
  });

  test(
      'early focus and early rest endings do not play deadline cues or start another phase',
      () async {
    c.engine.start(
        id: 'early',
        device: 'test',
        seconds: 60,
        now: DateTime.now().toUtc(),
        tick: c.clock.elapsedMilliseconds);
    await c.end();
    expect(c.phase, Phase.ended);
    expect(c.sessions.single.completed, false);
    expect(c.completedCycle, 0);
    await c.startRest();
    await c.end();
    expect(c.phase, Phase.ended);
    expect(cues, isEmpty);
  });

  test(
      'alert failures cannot undo saved focus or prevent automatic rest and rest ending',
      () async {
    failAlerts = true;
    expiredFocus('one');
    await c.tick();
    expect(c.phase, Phase.rest);
    expect(c.sessions.single.completed, true);
    expect(c.message, contains('提示音暂时无法播放'));
    c.engine.startRest(1, c.clock.elapsedMilliseconds - 1000);
    await c.tick();
    expect(c.phase, Phase.ended);
    expect(c.completedCycle, 1);
  });

  test('sleep wins over an elapsed deadline and never starts automatic rest',
      () async {
    expiredFocus('sleep');
    await c.store.commitCheckpoint(c.engine.snapshot(
        DateTime.now().toUtc(), c.clock.elapsedMilliseconds - 59500)!);
    suspended = true;
    await c.tick();
    expect(c.phase, Phase.ended);
    expect(c.sessions.single.reason, 'sleep');
    expect(c.sessions.single.completed, false);
    expect(c.sessions.single.milliseconds, 500);
    expect(cues, isEmpty);
  });
}
