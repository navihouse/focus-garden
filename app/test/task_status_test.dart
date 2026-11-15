import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/domain/timer_engine.dart';
import 'package:focus_garden/task_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppController c;
  var rings = 0;
  setUp(() async {
    c = AppController()..store = LocalStore.testing(NativeDatabase.memory());
    rings = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, (call) async {
      if (call.method == 'taskCompleted') rings++;
      return null;
    });
    await c.store.task(
        TaskItem(id: 'a', name: 'status task', modified: DateTime.utc(2026)));
    await c.refresh();
  });
  tearDown(() async {
    c.dispose();
    await c.store.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, null);
  });
  TaskItem change(TaskItem task, Json fields) =>
      TaskItem.fromJson({...task.toJson(), ...fields});

  test('saving completed records actual completion time and rings exactly once',
      () async {
    c.selectedTask = 'a';
    final before = DateTime.now().toUtc();
    await c.saveTask(change(c.tasks.single, {'status': 'done'}));
    final done = c.tasks.single;
    expect(done.completedAt!.isBefore(before), false);
    expect(done.status, 'done');
    expect(c.selectedTask, isNull);
    expect(rings, 1);
    await c.saveTask(change(done, {'notes': 'edit completed notes'}));
    expect(c.tasks.single.completedAt, done.completedAt);
    expect(rings, 1);
    expect((await c.store.tasks()).single.status, 'done');
  });

  test('completed task can return to doing or todo without another chime',
      () async {
    await c.saveTask(change(c.tasks.single, {'status': 'done'}));
    await c.saveTask(change(c.tasks.single, {'status': 'doing'}));
    expect(c.tasks.single.completedAt, isNull);
    expect(c.tasks.single.status, 'doing');
    await c.saveTask(change(c.tasks.single, {'status': 'todo'}));
    expect(c.tasks.single.completedAt, isNull);
    expect(rings, 1);
  });

  test('new completed task is stored in completed section after pending tasks',
      () async {
    await c.saveTask(TaskItem(
        id: 'new',
        name: 'already finished',
        status: 'done',
        modified: DateTime.utc(2020)));
    expect(c.tasks.map((t) => t.id), ['a', 'new']);
    expect(c.tasks.last.completedAt!.year, DateTime.now().toUtc().year);
    expect(rings, 1);
  });

  test(
      'completion feedback failure keeps saved status and active focus snapshot',
      () async {
    c.selectedTask = 'a';
    await c.startFocus(testSeconds: 90);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, (_) async {
      throw PlatformException(code: 'UNAVAILABLE');
    });
    await c.saveTask(change(c.tasks.single, {'status': 'done'}));
    expect(c.tasks.single.status, 'done');
    expect(c.phase, Phase.focus);
    expect(c.selectedTask, 'a');
    expect(c.currentTaskName, 'status task');
    expect(c.message, contains('提示音暂时无法播放'));
  });

  test('failed save does not play completion sound or mutate selection',
      () async {
    c.selectedTask = 'a';
    await c.store
        .customStatement("CREATE TRIGGER reject_done BEFORE INSERT ON tasks "
            "WHEN json_extract(NEW.data, '\$.status') = 'done' "
            "BEGIN SELECT RAISE(FAIL, 'simulated failure'); END");
    await expectLater(c.saveTask(change(c.tasks.single, {'status': 'done'})),
        throwsA(anything));
    expect((await c.store.tasks()).single.status, 'todo');
    expect(c.selectedTask, 'a');
    expect(rings, 0);
  });

  for (final size in [const Size(1180, 1000), const Size(390, 844)]) {
    for (final brightness in Brightness.values) {
      testWidgets(
          'status dropdown completes, cancels and restores at $size $brightness',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        TaskItem? saved;
        Future<void> showEditor(TaskItem task) async {
          await tester.pumpWidget(MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: Builder(
                  builder: (ctx) => Scaffold(
                      body: TextButton(
                          onPressed: () async {
                            saved = await showDialog<TaskItem>(
                                context: ctx,
                                builder: (_) => TaskEditor(task: task));
                          },
                          child: const Text('open'))))));
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
        }

        Future<void> select(String text) async {
          final field = find.byKey(const ValueKey('task-status'));
          await tester.ensureVisible(field);
          await tester.tap(field);
          await tester.pumpAndSettle();
          expect(find.text('待办').last, findsOneWidget);
          expect(find.text('进行中').last, findsOneWidget);
          expect(find.text('已完成').last, findsOneWidget);
          await tester.tap(find.text(text).last);
          await tester.pumpAndSettle();
        }

        await showEditor(c.tasks.single);
        await select('已完成');
        expect(rings, 0, reason: '草稿不应播放完成提示');
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(saved, isNull);
        expect(c.tasks.single.status, 'todo');
        expect(rings, 0);
        await showEditor(c.tasks.single);
        await select('已完成');
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(saved!.status, 'done');
        expect(rings, 0);
        await tester.runAsync(() => c.saveTask(saved!));
        expect(rings, 1);
        expect(c.tasks.single.completedAt, isNotNull);
        await showEditor(c.tasks.single);
        await select('进行中');
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        await tester.runAsync(() => c.saveTask(saved!));
        expect(c.tasks.single.status, 'doing');
        expect(c.tasks.single.completedAt, isNull);
        expect(rings, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
