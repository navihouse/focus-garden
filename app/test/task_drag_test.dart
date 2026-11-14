import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/data/backup.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppController c;

  setUp(() async {
    c = AppController()..store = LocalStore.testing(NativeDatabase.memory());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, (_) async => null);
    await c.store.saveGroups(const [
      TaskGroup(id: 'work', name: '工作'),
      TaskGroup(id: 'study', name: '学习'),
      TaskGroup(id: 'empty', name: '新分组'),
    ]);
    for (final (id, group) in [('a', 'work'), ('b', 'study'), ('c', '')]) {
      await c.store.task(TaskItem(
          id: id,
          name: 'Task $id',
          groupId: group,
          notes: '备注 $id',
          subtasks: [SubtaskItem(id: 'step-$id', name: '下一步')],
          sortOrder: 0,
          modified: DateTime.utc(2026)));
    }
    await c.refresh();
  });

  tearDown(() async {
    await c.store.close();
    c.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, null);
  });

  List<String> ids(String group) => c.tasks
      .where((task) => task.groupId == group && task.status != 'done')
      .map((task) => task.id)
      .toList();

  test('moves into empty groups and back, preserving task details and history',
      () async {
    final task = c.tasks.firstWhere((task) => task.id == 'c');
    final start = DateTime.utc(2026);
    final session = FocusSession(
        id: 'record',
        device: 'test',
        taskId: 'c',
        plannedSeconds: 60,
        started: start,
        ended: start.add(const Duration(minutes: 1)),
        spans: [TimeSpan(start, start.add(const Duration(minutes: 1)))],
        completed: true,
        reason: 'completed');
    await c.store.session(session);
    c.selectedTask = 'c';
    await c.moveTaskToGroup('c', 'empty');
    expect(ids('empty'), ['c']);
    expect(ids(''), isEmpty);
    expect(c.selectedTask, 'c');
    final moved = c.tasks.firstWhere((task) => task.id == 'c');
    expect(
        {...moved.toJson()}..removeWhere(
            (key, _) => ['groupId', 'modified', 'sortOrder'].contains(key)),
        {...task.toJson()}..removeWhere(
            (key, _) => ['groupId', 'modified', 'sortOrder'].contains(key)));
    expect(c.sessions.single.toJson(), session.toJson());
    await c.moveTaskToGroup('c', '');
    await c.refresh();
    expect(ids(''), ['c']);
    expect(ids('empty'), isEmpty);
    final restored =
        previewBackup(exportBackup(c.tasks, c.sessions, c.groups), [], [])
            .tasks;
    expect(restored.firstWhere((task) => task.id == 'c').groupId, '');
  });

  test('cross-group and same-group drops insert before or after the target',
      () async {
    await c.moveTaskToGroup('a', 'study', relativeToTaskId: 'b');
    expect(ids('study'), ['a', 'b']);
    expect(ids('work'), isEmpty);
    await c.moveTaskToGroup('a', 'study', relativeToTaskId: 'b', after: true);
    expect(ids('study'), ['b', 'a']);
    await c.moveTaskToGroup('c', 'study', relativeToTaskId: 'a');
    expect(ids('study'), ['b', 'c', 'a']);
    await c.moveTaskToGroup('b', 'study');
    expect(ids('study'), ['c', 'a', 'b']);
    expect(
        c.tasks
            .where((task) => task.groupId == 'study')
            .map((task) => task.sortOrder),
        [0, 1, 2]);
  });

  test('stale targets, missing tasks and completed tasks cannot corrupt groups',
      () async {
    final before = c.tasks.map((task) => task.toJson()).toList();
    await expectLater(c.moveTaskToGroup('a', 'deleted'), throwsStateError);
    await c.moveTaskToGroup('missing', 'study');
    await c.moveTaskToGroup('a', 'study', relativeToTaskId: 'missing');
    await c.moveTaskToGroup('a', 'study', relativeToTaskId: 'a');
    expect(c.tasks.map((task) => task.toJson()), before);
    await c.toggleTaskCompleted('a');
    final completed = c.tasks.firstWhere((task) => task.id == 'a').toJson();
    await c.moveTaskToGroup('a', 'study');
    expect(c.tasks.firstWhere((task) => task.id == 'a').toJson(), completed);
  });

  test('failed move rolls back every target order and original membership',
      () async {
    final before =
        (await c.store.tasks()).map((task) => task.toJson()).toList();
    await c.store.customStatement(
        "CREATE TRIGGER reject_move BEFORE INSERT ON tasks "
        "WHEN NEW.id = 'b' BEGIN SELECT RAISE(FAIL, 'simulated write failure'); END");
    await expectLater(c.moveTaskToGroup('a', 'study', relativeToTaskId: 'b'),
        throwsA(anything));
    expect((await c.store.tasks()).map((task) => task.toJson()), before);
    expect(ids('work'), ['a']);
    expect(ids('study'), ['b']);
  });

  Future<void> waitForMove(WidgetTester tester, bool Function() ready) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && !ready(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(ready(), true, reason: c.message);
  }

  Future<void> showPage(WidgetTester tester, String page,
      {Brightness brightness = Brightness.light,
      Size size = const Size(1180, 1800)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home:
            ListenableBuilder(listenable: c, builder: (_, child) => Home(c))));
    if (page == 'main') await tester.tap(find.text('任务').last);
    await tester.pumpAndSettle();
  }

  Future<void> dropTask(WidgetTester tester, String id, Finder destination,
      {double position = .5}) async {
    final source = find.byKey(ValueKey('task-drag-$id'));
    await tester.ensureVisible(source);
    await tester.pumpAndSettle();
    final bounds = tester.getRect(destination);
    final gesture = await tester.startGesture(tester.getCenter(source),
        kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(-24, 0));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(
        Offset(bounds.center.dx, bounds.top + bounds.height * position));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  for (final page in ['main', 'focus']) {
    for (final brightness in Brightness.values) {
      testWidgets(
          'mouse drag moves into, between and out of groups on $page $brightness',
          (tester) async {
        await showPage(tester, page, brightness: brightness);
        final target = find.byKey(ValueKey('group-drop-$page-empty'));
        await tester.tap(find.byKey(ValueKey('group-title-$page-empty')));
        await tester.pumpAndSettle();
        await dropTask(tester, 'c', target);
        await waitForMove(tester, () => ids('empty').contains('c'));
        expect(find.byKey(const ValueKey('task-card-c')), findsOneWidget,
            reason: '拖入折叠分组后应自动展开');
        final ungrouped = find.byKey(ValueKey('group-drop-$page-'));
        expect(ungrouped, findsOneWidget, reason: '未分组即使为空也应保留移出任务的入口');
        await dropTask(
            tester, 'c', find.byKey(ValueKey('group-drop-$page-study')));
        await waitForMove(tester, () => ids('study').contains('c'));
        expect(ids('study'), ['b', 'c']);
        await dropTask(tester, 'c', find.byKey(const ValueKey('task-card-b')),
            position: .2);
        await waitForMove(tester, () => ids('study').first == 'c');
        expect(ids('study'), ['c', 'b']);
        await dropTask(tester, 'c', find.byKey(const ValueKey('task-card-b')),
            position: .8);
        await waitForMove(tester, () => ids('study').last == 'c');
        await dropTask(tester, 'c', ungrouped);
        await waitForMove(tester, () => ids('').contains('c'));
        expect(ids('empty'), isEmpty);
        expect(ids('study'), ['b']);
        await tester.tap(find.byKey(const ValueKey('task-menu-c')));
        await tester.pumpAndSettle();
        expect(find.text('删除任务'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('cancelled drag leaves the task in its original group',
      (tester) async {
    await showPage(tester, 'main');
    await dropTask(tester, 'c', find.byType(AppBar));
    expect(ids(''), ['c']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drag auto-scrolls long lists while keeping the source alive',
      (tester) async {
    for (var i = 0; i < 15; i++) {
      await c.store.task(TaskItem(
          id: 'long-$i',
          name: 'Long task $i',
          groupId: 'work',
          sortOrder: i + 1,
          modified: DateTime.utc(2026)));
    }
    await c.refresh();
    await showPage(tester, 'main', size: const Size(1180, 700));
    final source = find.byKey(const ValueKey('task-drag-c'));
    final scrollable = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(source, 300, scrollable: scrollable);
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(scrollable);
    final initial = scroll.position.pixels;
    final bounds = tester.getRect(scrollable);
    final gesture = await tester.startGesture(tester.getCenter(source),
        kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(-24, 0));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(Offset(bounds.center.dx, bounds.top + 4));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(scroll.position.pixels, lessThan(initial));
    expect(source, findsOneWidget);
    await gesture.moveTo(tester.getCenter(find.byType(AppBar)));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(ids(''), ['c']);
    expect(tester.takeException(), isNull);
  });
}
