import 'dart:convert';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/data/backup.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/main.dart';
import 'package:focus_garden/task_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppController c;
  setUp(() async {
    c = AppController()..store = LocalStore.testing(NativeDatabase.memory());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, (_) async => null);
  });
  tearDown(() async {
    await c.store.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, null);
  });

  Future<void> seedTasks() async {
    for (final item in [
      TaskItem(
          id: 'work',
          name: '写周报',
          groupId: 'g1',
          sortOrder: 0,
          modified: DateTime.utc(2026, 1, 5)),
      TaskItem(
          id: 'study',
          name: '复习',
          groupId: 'g2',
          sortOrder: 0,
          modified: DateTime.utc(2026, 1, 4)),
      TaskItem(id: 'loose', name: '散步', modified: DateTime.utc(2026, 1, 3)),
      TaskItem(
          id: 'done',
          name: '已完成',
          status: 'done',
          groupId: 'g1',
          modified: DateTime.utc(2026, 1, 2)),
    ]) {
      await c.store.task(item);
    }
    await c.store.saveGroups([
      const TaskGroup(id: 'g1', name: '工作', color: '#D9605E'),
      const TaskGroup(id: 'g2', name: '学习', color: '#3CAF8B'),
    ]);
    await c.refresh();
  }

  // The dialog persists through the controller queue and a real database, so
  // let real asynchronous work run instead of only pumping fake frames.
  Future<void> waitForIo(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    var settled = false;
    c.perform(() async {
      settled = true;
    });
    for (var i = 0; i < 100 && !settled; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(done(), isTrue,
        reason:
            '数据库写入未完成 (message=${c.message}, groups=${c.groups.map((g) => g.id).toList()})');
  }

  test('group JSON round-trips, normalizes color case, and rejects bad fields',
      () {
    final group =
        TaskGroup.fromJson({'id': 'g1', 'name': ' 工作 ', 'color': '#d9605e'});
    expect(group.name, '工作');
    expect(group.color, '#D9605E');
    expect(TaskGroup.fromJson(group.toJson()).sameAs(group), true);
    for (final bad in [
      {'id': '', 'name': '工作', 'color': '#D9605E'},
      {'id': 'g1', 'name': '  ', 'color': '#D9605E'},
      {'id': 'g1', 'name': '工作', 'color': 'red'},
      {'id': 'g1', 'name': '工' * 41, 'color': '#D9605E'},
      {'id': 'g 1', 'name': '工作', 'color': '#D9605E'},
    ]) {
      expect(() => TaskGroup.fromJson(bad), throwsFormatException);
    }
  });

  test('task groupId survives JSON and rejects malformed ids', () async {
    final task = TaskItem(
        id: 'a', name: 'A', groupId: 'g1', modified: DateTime.utc(2026));
    final restored = TaskItem.fromJson(task.toJson());
    expect(restored.groupId, 'g1');
    // Tasks written before groups existed default to the ungrouped section.
    final legacy = TaskItem(id: 'b', name: 'B', modified: DateTime.utc(2026));
    expect(
        TaskItem.fromJson({...legacy.toJson()}..remove('groupId')).groupId, '');
    expect(() => TaskItem.fromJson({...task.toJson(), 'groupId': 'bad id!'}),
        throwsFormatException);
  });

  test('group drag persists both directions without changing task data',
      () async {
    await seedTasks();
    await c.store.saveGroups([
      ...c.groups,
      const TaskGroup(id: 'g3', name: '生活'),
      const TaskGroup(id: 'g4', name: '其他'),
    ]);
    await c.refresh();
    final original = {for (final task in c.tasks) task.id: task.toJson()};
    await c.reorderGroup('g1', 3);
    expect(c.groups.map((group) => group.id), ['g2', 'g3', 'g4', 'g1']);
    expect((await c.store.groups()).map((group) => group.id),
        ['g2', 'g3', 'g4', 'g1']);
    expect({for (final task in c.tasks) task.id: task.toJson()}, original);
    await c.reorderGroup('g1', 0);
    await c.refresh();
    expect(c.groups.map((group) => group.id), ['g1', 'g2', 'g3', 'g4']);
    expect(c.groups.first.color, '#D9605E');
    expect({for (final task in c.tasks) task.id: task.toJson()}, original);
  });

  test('invalid group drag positions are ignored', () async {
    await seedTasks();
    final original = c.groups.map((group) => group.toJson()).toList();
    await c.reorderGroup('g1', -1);
    await c.reorderGroup('g1', 2);
    await c.reorderGroup('missing', 0);
    await c.reorderGroup('g1', 0);
    expect(c.groups.map((group) => group.toJson()), original);
    expect((await c.store.groups()).map((group) => group.toJson()), original);
  });

  test('failed group reorder keeps persisted and displayed order consistent',
      () async {
    await seedTasks();
    final original = c.groups.map((group) => group.toJson()).toList();
    await c.store.customStatement(
        "CREATE TRIGGER reject_group_order BEFORE INSERT ON state "
        "WHEN NEW.id = 'groups' BEGIN SELECT RAISE(FAIL, 'simulated failure'); END");
    await expectLater(c.reorderGroup('g1', 1), throwsA(anything));
    expect(c.groups.map((group) => group.toJson()), original);
    expect((await c.store.groups()).map((group) => group.toJson()), original);
  });

  test('groups keep manager order and ungrouped tasks stay last', () async {
    await seedTasks();
    expect(c.tasks.map((t) => t.id), ['work', 'study', 'loose', 'done']);
    // Completed tasks still live in their own folded section.
    expect(c.tasks.last.status, 'done');
  });

  test('group management validates names, recolors, and reorders', () async {
    await c.perform(() => c.createGroup('工作', '#D9605E'));
    final first = c.groups.single;
    expect(first.name, '工作');
    await expectLater(c.createGroup(' 工作 ', '#3CAF8B'), throwsStateError);
    await expectLater(c.createGroup('   ', '#3CAF8B'), throwsStateError);
    await c.createGroup('学习', '#3CAF8B');
    expect(c.groups.map((g) => g.name), ['工作', '学习']);
    await c.updateGroup(c.groups.first.id, name: '深度学习', color: '#9A6BD8');
    expect(c.groups.first.name, '深度学习');
    expect(c.groups.first.color, '#9A6BD8');
    expect(c.groups.first.id, first.id);
    await c.moveGroup(c.groups.last.id, -1);
    expect(c.groups.map((g) => g.name), ['学习', '深度学习']);
    // Removing a group returns its tasks to the ungrouped section.
    await c.store.task(TaskItem(
        id: 't',
        name: 'T',
        groupId: c.groups.first.id,
        modified: DateTime.utc(2026)));
    await c.refresh();
    await c.deleteGroup(c.groups.first.id);
    expect(c.groups.single.name, '深度学习');
    expect(c.tasks.single.groupId, '');
  });

  test('saving a task stores its group and drops unknown group ids', () async {
    await c.perform(() => c.createGroup('工作', '#D9605E'));
    final id = c.groups.single.id;
    await c.saveTask(TaskItem(
        id: 't', name: 'T', groupId: id, modified: DateTime.utc(2026)));
    expect(c.tasks.single.groupId, id);
    await c.saveTask(
        TaskItem.fromJson({...c.tasks.single.toJson(), 'groupId': 'ghost'}));
    expect(c.tasks.single.groupId, '');
  });

  test('stale group references are healed on load', () async {
    await c.store.task(TaskItem(
        id: 't', name: 'T', groupId: 'gone', modified: DateTime.utc(2026)));
    await c.refresh();
    expect(c.tasks.single.groupId, '');
    expect((await c.store.tasks()).single.groupId, '');
  });

  test('reordering only renumbers tasks inside the same group', () async {
    await c.perform(() => c.createGroup('工作', '#D9605E'));
    final gid = c.groups.single.id;
    for (final (id, order) in [('a', 0), ('b', 1), ('c', 2)]) {
      await c.store.task(TaskItem(
          id: id,
          name: id,
          groupId: gid,
          sortOrder: order,
          modified: DateTime.utc(2026)));
    }
    await c.store.task(TaskItem(
        id: 'other',
        name: 'other',
        sortOrder: 5,
        modified: DateTime.utc(2026)));
    await c.refresh();
    await c.reorderTask('c', 0, groupId: gid);
    expect(c.tasks.where((t) => t.groupId == gid).map((t) => t.id),
        ['c', 'a', 'b']);
    expect(
        c.tasks.where((t) => t.groupId == gid).map((t) => t.sortOrder).toList(),
        [0, 1, 2]);
    expect(c.tasks.firstWhere((t) => t.id == 'other').sortOrder, 5);
  });

  test('backup version 6 carries groups and imports merge by id and name',
      () async {
    await c.perform(() => c.createGroup('工作', '#D9605E'));
    final localId = c.groups.single.id;
    await c.saveTask(TaskItem(
        id: 't', name: 'T', groupId: localId, modified: DateTime.utc(2026)));
    final text = exportBackup(c.tasks, c.sessions, c.groups);
    final json = asJson(jsonDecode(text));
    expect(json['version'], 6);
    expect((json['groups'] as List).single['name'], '工作');
    expect(previewBackup(text, c.tasks, c.sessions).groups.single.name, '工作');
    // Importing the same file again would add no new tasks or conflicts.
    final preview = previewBackup(text, c.tasks, c.sessions);
    expect(preview.tasks.single.id, 't');
    expect(preview.conflicts, isEmpty);
    expect(preview.groups.single.id, localId);
  });

  test('importing a backup remaps a same-name group from another device',
      () async {
    await c.perform(() => c.createGroup('工作', '#D9605E'));
    final localId = c.groups.single.id;
    final text = exportBackup([
      TaskItem(
          id: 'incoming',
          name: '来自另一台设备',
          groupId: 'remote-g',
          modified: DateTime.utc(2026))
    ], [], [
      const TaskGroup(id: 'remote-g', name: '工作', color: '#3CAF8B')
    ]);
    final preview = previewBackup(text, c.tasks, c.sessions);
    await importBackup(c.store, preview);
    await c.refresh();
    expect(c.groups.single.id, localId);
    expect(c.groups.single.color, '#D9605E');
    expect(c.tasks.single.groupId, localId);
  });

  test('backup rejects groups in old formats and unknown group references', () {
    final task = TaskItem(
        id: 't', name: 'T', groupId: 'g1', modified: DateTime.utc(2026));
    String file(int version, Map<String, Object?> extra) => jsonEncode({
          'format': 'focus-garden',
          'version': version,
          'exportedAt': DateTime.utc(2026).toIso8601String(),
          'tasks': [task.toJson()],
          'sessions': <Object>[],
          ...extra
        });
    expect(() => previewBackup(file(5, {}), [], []), throwsFormatException);
    expect(() => previewBackup(file(6, {'groups': <Object>[]}), [], []),
        throwsFormatException);
    expect(
        () => previewBackup(
            file(6, {
              'groups': [
                {'id': 'g1', 'name': '工作', 'color': '#D9605E'},
                {'id': 'g2', 'name': '工作', 'color': '#3CAF8B'},
              ]
            }),
            [],
            []),
        throwsFormatException);
    // Version 6 with the referenced group and no groups on tasks is fine.
    expect(
        previewBackup(
            file(6, {
              'groups': [
                {'id': 'g1', 'name': '工作', 'color': '#D9605E'}
              ]
            }),
            [],
            []).groups.single.name,
        '工作');
  });

  test('all custom groups remain visible when empty or fully completed',
      () async {
    await seedTasks();
    expect(c.groupSections([]).map((section) => section.$1?.id),
        ['g1', 'g2', null]);
    final sections = c.groupSections(c.tasks
        .where((task) => task.status != 'done' && task.groupId != 'g1')
        .toList());
    expect(sections.map((section) => section.$1?.id), ['g1', 'g2', null]);
    expect(sections.first.$2, isEmpty);
    expect(sections[1].$2.single.id, 'study');
    expect(sections.last.$2.single.id, 'loose');
  });

  testWidgets(
      'click group titles, show newly created empty groups, and assign a new task',
      (tester) async {
    tester.view.physicalSize = const Size(1180, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await seedTasks();
    await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh', 'CN'),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN')],
        home:
            ListenableBuilder(listenable: c, builder: (_, child) => Home(c))));
    await tester.tap(find.text('任务').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-title-main-g1')), findsOneWidget);
    expect(find.byKey(const ValueKey('group-title-main-g2')), findsOneWidget);
    expect(find.byKey(const ValueKey('group-title-main-')), findsOneWidget);
    expect(find.text('写周报'), findsOneWidget);
    // Collapsing a section hides only that section's cards.
    final header = find.byKey(const ValueKey('group-toggle-main-g1'));
    expect(find.descendant(of: header, matching: find.byType(IconButton)),
        findsNothing);
    expect(
        find.descendant(of: header, matching: find.byIcon(Icons.expand_more)),
        findsNothing);
    expect(
        find.descendant(of: header, matching: find.byIcon(Icons.chevron_right)),
        findsNothing);
    await tester.tap(find.byKey(const ValueKey('group-title-main-g1')));
    await tester.pumpAndSettle();
    expect(find.text('写周报'), findsNothing);
    expect(find.text('复习'), findsOneWidget);
    final bounds = tester.getRect(header);
    await tester.tapAt(Offset(bounds.right - 12, bounds.center.dy));
    await tester.pumpAndSettle();
    expect(find.text('写周报'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('manage-groups')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-manager')), findsOneWidget);
    expect(find.byKey(const ValueKey('group-row-g1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('new-group')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('group-name')), '生活');
    await tester.tap(find.byKey(const ValueKey('group-color-#E3A13B')));
    await tester.tap(find.byKey(const ValueKey('group-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-name')), findsNothing,
        reason: '创建对话框应在保存后关闭');
    await waitForIo(tester, () => c.groups.length == 3);
    expect(c.groups.map((g) => g.name), ['工作', '学习', '生活']);
    expect(c.groups.last.color, '#E3A13B');
    await tester.pumpAndSettle();
    expect(
        find.byKey(ValueKey('group-row-${c.groups.last.id}')), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    final groupId = c.groups.last.id;
    expect(find.byKey(ValueKey('group-title-main-$groupId')), findsOneWidget);
    expect(find.byKey(ValueKey('group-empty-main-$groupId')), findsOneWidget);
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    final picker = find.byKey(const ValueKey('task-group'));
    expect(picker.hitTestable(), findsOneWidget, reason: '新建任务时应直接看到分组选项');
    await tester.enterText(find.byKey(const ValueKey('task-name')), '买茶叶');
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('生活').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await waitForIo(tester, () => c.tasks.any((task) => task.name == '买茶叶'));
    expect(c.tasks.firstWhere((task) => task.name == '买茶叶').groupId, groupId);
    expect(find.byKey(ValueKey('group-empty-main-$groupId')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final newTask in [false, true]) {
    for (final brightness in Brightness.values) {
      testWidgets(
          'task editor group selector is visible on narrow screens new=$newTask $brightness',
          (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final task = TaskItem(id: 'a', name: 'A', modified: DateTime.utc(2026));
        TaskItem? result;
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Builder(
                builder: (ctx) => Scaffold(
                    body: TextButton(
                        onPressed: () async {
                          result = await showDialog<TaskItem>(
                              context: ctx,
                              builder: (_) => TaskEditor(
                                      task: newTask ? null : task,
                                      groups: const [
                                        TaskGroup(id: 'g1', name: '工作')
                                      ]));
                        },
                        child: const Text('open'))))));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('task-group')).hitTestable(),
            findsOneWidget);
        if (newTask) {
          await tester.enterText(
              find.byKey(const ValueKey('task-name')), '新任务');
        }
        await tester.tap(find.byKey(const ValueKey('task-group')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('工作').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(result!.groupId, 'g1');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
      'new task without custom groups still displays the group selector',
      (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: Scaffold(body: TaskEditor())));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('task-group')).hitTestable(), findsOneWidget);
    expect(find.text('未分组'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final focus in [false, true]) {
    testWidgets(
        'group headers reorder directly on ${focus ? 'focus' : 'tasks'} page',
        (tester) async {
      tester.view.physicalSize = const Size(1180, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await seedTasks();
      await tester.pumpWidget(MaterialApp(
          home: ListenableBuilder(
              listenable: c, builder: (_, child) => Home(c))));
      if (!focus) await tester.tap(find.text('任务').last);
      await tester.pumpAndSettle();
      final prefix = focus ? 'focus' : 'main';
      final first = find.byKey(ValueKey('group-toggle-$prefix-g1'));
      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(find.text('写周报'), findsNothing);
      expect(find.byKey(ValueKey('group-header-drag-$prefix-')), findsNothing);
      await Scrollable.ensureVisible(tester.element(first), alignment: 0);
      await tester.pumpAndSettle();
      Future<void> drag(String source, String target) async {
        final gesture = await tester.startGesture(
            tester.getCenter(
                find.byKey(ValueKey('group-header-drag-$prefix-$source'))),
            kind: PointerDeviceKind.mouse);
        await gesture.moveBy(const Offset(0, 12));
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.moveTo(tester.getCenter(
            find.byKey(ValueKey('group-header-drop-$prefix-$target'))));
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.up();
        await tester.pumpAndSettle();
      }

      await drag('g1', 'g2');
      await waitForIo(tester, () => c.groups.last.id == 'g1');
      expect(c.groups.map((g) => g.id), ['g2', 'g1']);
      expect(find.text('写周报'), findsNothing, reason: '拖动不应改变已折叠状态');
      await drag('g1', 'g2');
      await waitForIo(tester, () => c.groups.first.id == 'g1');
      await drag('g1', '');
      await waitForIo(tester, () => c.groups.last.id == 'g1');
      final persisted = await tester.runAsync(c.store.groups);
      expect(persisted!.map((g) => g.id), ['g2', 'g1']);
      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(find.text('写周报'), findsOneWidget);
      expect(c.tasks.singleWhere((t) => t.id == 'work').groupId, 'g1');
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(1180, 1000), const Size(390, 844)]) {
    for (final brightness in Brightness.values) {
      testWidgets(
          'mouse drag reorders groups and preserves menus $size $brightness',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await seedTasks();
        await c.store.saveGroups([
          ...c.groups,
          const TaskGroup(id: 'g3', name: '生活'),
          const TaskGroup(id: 'g4', name: '其他'),
        ]);
        await c.refresh();
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData(brightness: brightness),
            locale: const Locale('zh', 'CN'),
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: const [Locale('zh', 'CN')],
            home: ListenableBuilder(
                listenable: c, builder: (_, child) => Home(c))));
        await tester.tap(find.text('任务').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('manage-groups')));
        await tester.pumpAndSettle();
        expect(find.byTooltip('上移分组'), findsNothing);
        expect(find.byTooltip('下移分组'), findsNothing);
        expect(find.byIcon(Icons.arrow_upward), findsNothing);
        expect(find.byIcon(Icons.arrow_downward), findsNothing);
        final source = find.byKey(const ValueKey('group-drag-g1'));
        final destination =
            tester.getBottomRight(find.byKey(const ValueKey('group-row-g4')));
        final start = tester.getCenter(source);
        final gesture =
            await tester.startGesture(start, kind: PointerDeviceKind.mouse);
        await gesture.moveBy(const Offset(0, 12));
        await tester.pump(const Duration(milliseconds: 100));
        final end = destination + const Offset(0, 24);
        for (var step = 1; step <= 20; step++) {
          await gesture.moveTo(Offset.lerp(start, end, step / 20)!);
          await tester.pump(const Duration(milliseconds: 30));
        }
        await tester.pump(const Duration(milliseconds: 400));
        await gesture.up();
        await tester.pumpAndSettle();
        await waitForIo(tester, () => c.groups.last.id == 'g1');
        expect(c.groups.map((group) => group.id), ['g2', 'g3', 'g4', 'g1']);
        final savedGroups = await tester.runAsync(c.store.groups);
        expect(savedGroups!.last.id, 'g1');
        expect(
            tester
                .widget<ReorderableDragStartListener>(
                    find.byKey(const ValueKey('group-drag-g4')))
                .enabled,
            isTrue);
        final upwardStart =
            tester.getCenter(find.byKey(const ValueKey('group-drag-g4')));
        final upwardEnd =
            tester.getTopRight(find.byKey(const ValueKey('group-row-g2'))) -
                const Offset(0, 16);
        final upwardGesture = await tester.startGesture(upwardStart,
            kind: PointerDeviceKind.mouse);
        await upwardGesture.moveBy(const Offset(0, -12));
        await tester.pump(const Duration(milliseconds: 100));
        for (var step = 1; step <= 20; step++) {
          await upwardGesture
              .moveTo(Offset.lerp(upwardStart, upwardEnd, step / 20)!);
          await tester.pump(const Duration(milliseconds: 30));
        }
        await tester.pump(const Duration(milliseconds: 400));
        await upwardGesture.up();
        await tester.pumpAndSettle();
        await waitForIo(tester, () => c.groups.first.id == 'g4');
        expect(c.groups.map((group) => group.id), ['g4', 'g2', 'g3', 'g1']);
        await tester.tap(find.byKey(const ValueKey('group-menu-g1')));
        await tester.pumpAndSettle();
        expect(find.text('重命名与颜色'), findsOneWidget);
        expect(find.text('删除分组'), findsOneWidget);
        await tester.tap(find.text('重命名与颜色'));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey('group-name')), '工作改名');
        await tester.tap(find.byKey(const ValueKey('group-color-#E3A13B')));
        await tester.tap(find.byKey(const ValueKey('group-save')));
        await tester.pumpAndSettle();
        await waitForIo(tester, () => c.groups.last.name == '工作改名');
        expect(c.groups.last.color, '#E3A13B');
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(
            tester
                .getTopLeft(find.byKey(const ValueKey('group-title-main-g2')))
                .dy,
            lessThan(tester
                .getTopLeft(find.byKey(const ValueKey('group-title-main-g1')))
                .dy));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
