import 'dart:ui' show PointerDeviceKind;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/main.dart';
import 'package:focus_garden/task_editor.dart';

void main() {
  Future<void> desktop(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1180, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Finder field(String key) => find.byKey(ValueKey(key));
  FocusNode focus(WidgetTester tester, Finder parent) => tester
      .widget<TextField>(
          find.descendant(of: parent, matching: find.byType(TextField)))
      .focusNode!;

  testWidgets(
      'Enter continues entry, existing Enter advances, dots drag and only delete',
      (tester) async {
    await desktop(tester);
    TaskItem? saved;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (ctx) => TextButton(
                    onPressed: () async {
                      saved = await showDialog<TaskItem>(
                          context: ctx, builder: (_) => const TaskEditor());
                    },
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(field('task-name'), 'Math');
    for (final name in ['First', 'Second', 'Third']) {
      await tester.enterText(field('new-subtask'), name);
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();
      expect(focus(tester, field('new-subtask')).hasFocus, true);
      expect(
          tester.widget<TextFormField>(field('new-subtask')).controller!.text,
          '');
    }
    final names = tester
        .widgetList<TextFormField>(find.byType(TextFormField))
        .where((w) => w.key.toString().contains('step-name-'))
        .toList();
    await tester.showKeyboard(find.byKey(names.first.key!));
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    expect(focus(tester, find.byKey(names[1].key!)).hasFocus, true);
    final handles = find.byType(ReorderableDragStartListener);
    final firstHandle = tester.getCenter(handles.first);
    final lastHandle = tester.getCenter(handles.last);
    final gesture =
        await tester.startGesture(firstHandle, kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(0, 12));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(lastHandle + const Offset(0, 80));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pumpAndSettle();
    final list = tester.widget<ReorderableListView>(field('subtask-list'));
    expect(list.itemCount, 3);
    // A click still opens the menu; it must not start a drag or contain move actions.
    await tester.tap(find.byTooltip('拖动排序，点击删除').first);
    await tester.pumpAndSettle();
    expect(find.text('上移'), findsNothing);
    expect(find.text('下移'), findsNothing);
    expect(find.text('删除子任务'), findsOneWidget);
    await tester.tap(find.text('删除子任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved!.subtasks.map((s) => s.name), ['Third', 'First']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('off-screen empty subtask blocks save without an exception',
      (tester) async {
    await desktop(tester);
    final task = TaskItem(
        id: 'many',
        name: 'Many steps',
        modified: DateTime.utc(2026),
        subtasks:
            List.generate(12, (i) => SubtaskItem(id: 's$i', name: 'Step $i')));
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: TaskEditor(task: task))));
    await tester.enterText(field('step-name-s0'), '');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.drag(field('subtask-list'), const Offset(0, -650));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请填写所有子任务名称'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'only task circle completes, delete is confirmed, pin hides navigation',
      (tester) async {
    await desktop(tester);
    final c = AppController()
      ..store = LocalStore.testing(NativeDatabase.memory());
    addTearDown(c.store.close);
    for (final id in ['a', 'b']) {
      await c.store.task(
          TaskItem(id: id, name: 'Task $id', modified: DateTime.utc(2026)));
    }
    await c.refresh();
    var rings = 0;
    final pinCalls = <bool>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppController.native, (call) async {
      if (call.method == 'taskCompleted') rings++;
      return null;
    });
    const window = MethodChannel('window_manager');
    messenger.setMockMethodCallHandler(window, (call) async {
      if (call.method == 'setAlwaysOnTop') {
        pinCalls.add((call.arguments as Map)['isAlwaysOnTop'] as bool);
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(window, null);
      messenger.setMockMethodCallHandler(AppController.native, null);
    });
    await tester.pumpWidget(MaterialApp(
        home:
            ListenableBuilder(listenable: c, builder: (_, child) => Home(c))));
    await tester.tap(field('focus-pin'));
    await tester.pumpAndSettle();
    expect(pinCalls, [true]);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byTooltip('设置'), findsNothing);
    expect(find.text('开始专注'), findsOneWidget);
    await tester.tap(field('focus-pin'));
    await tester.pumpAndSettle();
    expect(pinCalls, [true, false]);
    expect(find.byType(NavigationRail), findsOneWidget);
    await tester.tap(find.text('任务').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Task a'));
    await tester.pumpAndSettle();
    expect(c.tasks.first.status, 'todo');
    expect(find.text('已完成'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(rings, 0);
    await tester.tap(field('complete-task-a'));
    await tester.pumpAndSettle();
    expect(c.tasks.last.id, 'a');
    expect(c.tasks.last.status, 'done');
    expect(rings, 1);
    await tester.tap(field('task-menu-a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(c.tasks.length, 2);
    await tester.tap(field('task-menu-a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(c.tasks.map((t) => t.id), ['b']);
    expect((await c.store.tasks()).single.id, 'b');
    expect(rings, 1);
    expect(tester.takeException(), isNull);
  });
}
