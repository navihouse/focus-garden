import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/deadline_picker.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/domain/reports.dart';
import 'package:focus_garden/task_editor.dart';

void main() {
  Future<void> open(WidgetTester tester,
      {TaskItem? task, required void Function(TaskItem?) saved}) async {
    await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh', 'CN'),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN')],
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async => saved(await showDialog<TaskItem>(
                        context: context,
                        builder: (_) => TaskEditor(task: task))),
                    child: const Text('编辑'))))));
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    if (task == null) {
      await tester.enterText(find.byKey(const ValueKey('task-name')), '日期测试');
    }
  }

  Future<void> chooseDate(WidgetTester tester) async {
    final edit = find.byKey(const ValueKey('task-deadline-edit'));
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '确定'));
    await tester.pumpAndSettle();
    expect(find.byType(DeadlineTimeDialog), findsOneWidget);
    expect(find.byKey(const ValueKey('deadline-all-day')), findsOneWidget);
  }

  for (final size in [const Size(1180, 1000), const Size(390, 844)]) {
    for (final allDay in [true, false]) {
      testWidgets(
          'date automatically opens time and saves allDay=$allDay at $size',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        TaskItem? result;
        await open(tester, saved: (value) => result = value);
        await chooseDate(tester);
        if (allDay) {
          await tester.tap(find.byKey(const ValueKey('deadline-all-day')));
          await tester.pumpAndSettle();
          expect(
              tester
                  .widget<TextFormField>(
                      find.byKey(const ValueKey('deadline-hour')))
                  .enabled,
              false);
        } else {
          await tester.enterText(
              find.byKey(const ValueKey('deadline-hour')), '09');
          await tester.enterText(
              find.byKey(const ValueKey('deadline-minute')), '30');
        }
        await tester.tap(find.byKey(const ValueKey('deadline-confirm')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await tester.pumpAndSettle();
        expect(result!.due, isNotNull);
        if (allDay) {
          expect(result!.dueAt, isNull);
        } else {
          expect(beijing(result!.dueAt!).hour, 9);
          expect(beijing(result!.dueAt!).minute, 30);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('cancelled time selection preserves the original exact deadline',
      (tester) async {
    final original = TaskItem(
        id: 'exact',
        name: '截止',
        due: DateTime.utc(2026, 11, 14),
        dueAt: DateTime.utc(2026, 11, 14, 1, 30, 38),
        modified: DateTime.utc(2026));
    TaskItem? result;
    await open(tester, task: original, saved: (value) => result = value);
    await chooseDate(tester);
    await tester.tap(find.widgetWithText(TextButton, '取消').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(result!.dueAt, original.dueAt);
  });
  testWidgets('invalid hour is rejected; all-day skips time validation',
      (tester) async {
    TaskItem? result;
    await open(tester, saved: (value) => result = value);
    await chooseDate(tester);
    await tester.enterText(find.byKey(const ValueKey('deadline-hour')), '24');
    await tester.enterText(find.byKey(const ValueKey('deadline-minute')), '60');
    await tester.tap(find.byKey(const ValueKey('deadline-confirm')));
    await tester.pumpAndSettle();
    expect(find.byType(DeadlineTimeDialog), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('deadline-all-day')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('deadline-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(result!.dueAt, isNull);
    expect(result!.due, isNotNull);
  });
}
