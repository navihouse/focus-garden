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
  late List<String> sounds;
  setUp(() async {
    c = AppController()..store = LocalStore.testing(NativeDatabase.memory());
    sounds = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, (call) async {
      sounds.add(call.method);
      return null;
    });
    for (final item in [
      TaskItem(id: 'a', name: 'Review', modified: DateTime.utc(2026, 1, 3)),
      TaskItem(id: 'b', name: 'Practice', modified: DateTime.utc(2026, 1, 2)),
      TaskItem(
          id: 'old',
          name: 'Finished',
          status: 'done',
          modified: DateTime.utc(2026, 1, 1)),
    ]) {
      await c.store.task(item);
    }
    await c.refresh();
  });
  tearDown(() async {
    await c.store.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, null);
  });

  test('completion goes after older completions, persists, and rings only once',
      () async {
    c.selectedTask = 'a';
    await c.toggleTaskCompleted('a');
    expect(c.tasks.map((t) => t.id), ['b', 'old', 'a']);
    expect(c.tasks.last.status, 'done');
    expect(c.selectedTask, isNull);
    expect(sounds, ['taskCompleted']);
    await c.refresh();
    expect(c.tasks.last.id, 'a');
    await c.toggleTaskCompleted('a');
    expect(c.tasks.first.id, 'a');
    expect(c.tasks.first.status, 'todo');
    expect(sounds, ['taskCompleted']);
  });

  test('editing cannot complete a task and does not ring', () async {
    final task = c.tasks.first;
    await expectLater(
        c.saveTask(TaskItem.fromJson({...task.toJson(), 'status': 'done'})),
        throwsStateError);
    await c.saveTask(TaskItem.fromJson(
        {...task.toJson(), 'notes': 'Remember the examples'}));
    expect(c.tasks.first.status, 'todo');
    expect(sounds, isEmpty);
  });

  test('deleting a task keeps historical and running focus snapshots',
      () async {
    final now = DateTime.utc(2026, 1, 3);
    final task = c.tasks.first;
    c.selectedTask = task.id;
    c.engine.start(
        id: 'running',
        device: 'test',
        seconds: 1500,
        now: now,
        tick: c.clock.elapsedMilliseconds,
        task: task);
    await c.store.session(FocusSession(
        id: 'history',
        taskId: task.id,
        taskName: task.name,
        device: 'test',
        started: now,
        ended: now.add(const Duration(minutes: 1)),
        plannedSeconds: 60,
        spans: [TimeSpan(now, now.add(const Duration(minutes: 1)))]));
    await c.deleteTask(task.id);
    expect(c.tasks.any((t) => t.id == task.id), false);
    expect(c.selectedTask, isNull);
    expect(c.sessions.single.taskName, task.name);
    expect(c.currentTaskName, task.name);
    expect(c.engine.phase, Phase.focus);
    expect(
        c.engine.snapshot(now, c.clock.elapsedMilliseconds)!.taskId, task.id);
  });

  test('sound failure keeps completion and leaves focus timer running',
      () async {
    c.engine.start(
        id: 'running',
        device: 'test',
        seconds: 1500,
        now: DateTime.now().toUtc(),
        tick: c.clock.elapsedMilliseconds,
        task: c.tasks.first);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, (_) async {
      throw PlatformException(code: 'TASK_SOUND');
    });
    await c.toggleTaskCompleted('a');
    expect(
        (await c.store.tasks()).firstWhere((t) => t.id == 'a').status, 'done');
    expect(c.engine.phase, Phase.focus);
    expect(c.message, contains('任务已完成'));
  });
}
