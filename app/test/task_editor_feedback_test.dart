import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/task_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => messenger.setMockMethodCallHandler(
      AppController.native, (_) async => null));
  tearDown(
      () => messenger.setMockMethodCallHandler(AppController.native, null));
  testWidgets('task name stays visible when the detail body scrolls',
      (tester) async {
    tester.view.physicalSize = const Size(390, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = TaskItem(
        id: 'task',
        name: '一周任务：大学物理复习和练习',
        modified: DateTime.utc(2026),
        subtasks: List.generate(
            8, (i) => SubtaskItem(id: 's$i', name: '复习第 ${i + 1} 章')));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (ctx) => TextButton(
                    onPressed: () => showDialog<void>(
                        context: ctx, builder: (_) => TaskEditor(task: task)),
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('选择日期'));
    await tester.pumpAndSettle();
    final field = tester.getRect(find.byKey(const ValueKey('task-name')));
    final title = tester.getRect(find.text('任务详情'));
    expect(field.top, greaterThanOrEqualTo(title.bottom));
    expect(field.bottom, lessThan(650));
    expect(tester.takeException(), isNull);
  });

  for (final variant in [
    (const Size(1180, 900), Brightness.light, 1.0, 0.0),
    (const Size(390, 650), Brightness.dark, 1.0, 0.0),
    (const Size(460, 700), Brightness.light, 1.5, 220.0),
  ]) {
    testWidgets(
        'long name and label remain visible ${variant.$1} ${variant.$2}',
        (tester) async {
      tester.view.physicalSize = variant.$1;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final longName = List.filled(10, '课程复习与练习计划 ').join();
      final task =
          TaskItem(id: 'long', name: longName, modified: DateTime.utc(2026));
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(useMaterial3: true, brightness: variant.$2),
          builder: (ctx, child) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(
                  textScaler: TextScaler.linear(variant.$3),
                  viewInsets: EdgeInsets.only(bottom: variant.$4)),
              child: child!),
          home: Scaffold(
              body: Builder(
                  builder: (ctx) => TextButton(
                      onPressed: () => showDialog<void>(
                          context: ctx, builder: (_) => TaskEditor(task: task)),
                      child: const Text('Open'))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('选择日期'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('task-name'));
      final bounds = tester.getRect(field);
      expect(bounds.top, greaterThan(tester.getRect(find.text('任务详情')).bottom));
      expect(bounds.bottom, lessThan(variant.$1.height - variant.$4));
      expect(tester.widget<TextFormField>(field).controller!.text, longName);
      expect(tester.getRect(find.text('任务名称')).top,
          greaterThan(tester.getRect(find.text('任务详情')).bottom));
      expect(tester.takeException(), isNull);
    });
  }

  Future<void> openEditor(WidgetTester tester, void Function(TaskItem?) save,
      {bool completed = false}) async {
    tester.view.physicalSize = const Size(1180, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = TaskItem(
        id: 'task',
        name: 'Study',
        modified: DateTime.utc(2026),
        subtasks: [
          SubtaskItem(id: 'step', name: 'Review', completed: completed)
        ]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (ctx) => TextButton(
                    onPressed: () async {
                      save(await showDialog<TaskItem>(
                          context: ctx,
                          builder: (_) => TaskEditor(task: task)));
                    },
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('estimate filters keyboard and pasted text and validates range',
      (tester) async {
    TaskItem? saved;
    await openEditor(tester, (task) => saved = task);
    final field = find.byKey(const ValueKey('task-estimate'));
    await tester.ensureVisible(field);
    for (final (input, expected) in [
      ('abc中文１２３', ''),
      ('-12', '12'),
      ('1.5', '15'),
      ('a1中2.3-4', '123'),
      ('12345', '123'),
      ('999', '999'),
    ]) {
      await tester.enterText(field, input);
      expect(tester.widget<TextFormField>(field).controller!.text, expected);
    }
    // Exercise the real clipboard paste action as well as platform text entry.
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 'a4中5.6-7'};
      if (call.method == 'Clipboard.hasStrings') return {'value': true};
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.enterText(field, '');
    final editable = tester.state<EditableTextState>(
        find.descendant(of: field, matching: find.byType(EditableText)));
    await editable.pasteText(SelectionChangedCause.toolbar);
    await tester.pump();
    expect(tester.widget<TextFormField>(field).controller!.text, '456');
    for (final invalid in ['', '0', '000']) {
      await tester.enterText(field, invalid);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      await tester.ensureVisible(field);
      expect(find.text('填写 1–999'), findsOneWidget);
    }
    await tester.enterText(field, '999');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved!.estimate, 999);
  });

  testWidgets(
      'subtask rings only on completion, saves once, and leaves parent incomplete',
      (tester) async {
    var rings = 0;
    TaskItem? saved;
    messenger.setMockMethodCallHandler(AppController.native, (call) async {
      if (call.method == 'taskCompleted') rings++;
      return null;
    });
    await openEditor(tester, (task) => saved = task, completed: true);
    expect(rings, 0);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(rings, 0);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(rings, 1);
    await tester.enterText(
        find.byKey(const ValueKey('step-name-step')), 'Review and practice');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(rings, 1);
    expect(saved!.subtasks.single.completed, true);
    expect(saved!.status, 'todo');
  });

  testWidgets('sound failure keeps subtask checked and saveable',
      (tester) async {
    TaskItem? saved;
    messenger.setMockMethodCallHandler(AppController.native, (_) async {
      throw PlatformException(code: 'AUDIO_UNAVAILABLE');
    });
    await openEditor(tester, (task) => saved = task);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, true);
    expect(find.byKey(const ValueKey('subtask-sound-error')), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved!.subtasks.single.completed, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fixed header name remains part of form validation',
      (tester) async {
    TaskItem? saved;
    await openEditor(tester, (task) => saved = task);
    await tester.enterText(find.byKey(const ValueKey('task-name')), ' ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请填写任务名称'), findsOneWidget);
    expect(saved, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'late sound failure after cancel does not touch a disposed editor',
      (tester) async {
    final pending = Completer<Object?>();
    messenger.setMockMethodCallHandler(
        AppController.native, (_) => pending.future);
    TaskItem? saved;
    await openEditor(tester, (task) => saved = task);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    pending.completeError(PlatformException(code: 'AUDIO_UNAVAILABLE'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(tester.takeException(), isNull);
  });
}
