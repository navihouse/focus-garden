import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/automation_controller.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/main.dart';
import 'package:focus_garden/task_editor.dart';
import 'automation_test.dart' show FixtureScraper;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppController c;
  late AutomationController service;
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('focus-auto-ui-');
    c = AppController()..store = LocalStore.testing(NativeDatabase.memory());
    c.dataDirectory = root;
    await c.store.saveGroups(const [TaskGroup(id: 'course', name: '课程任务')]);
    await c.store.task(TaskItem(
        id: 'due',
        name: '今天要交',
        due: DateTime.utc(2026, 11, 13),
        modified: DateTime.utc(2026, 11, 12)));
    await c.store.task(TaskItem(
        id: 'late',
        name: '昨天还没做完',
        due: DateTime.utc(2026, 11, 12),
        modified: DateTime.utc(2026, 11, 12)));
    await c.refresh();
    service = AutomationController(
        store: c.store,
        directory: root,
        tasks: () => c.tasks,
        serialize: (action) => action(),
        refreshTasks: c.refresh,
        runner: FixtureScraper(),
        supportsScraper: true,
        now: () => DateTime.utc(2026, 11, 13, 1));
    await service.initialize();
    c.automation = service;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, (_) async => null);
  });
  tearDown(() async {
    await service.shutdown();
    c.automation = null;
    service.dispose();
    c.dispose();
    await c.store.close();
    await root.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, null);
  });

  Future<void> pumpUntil(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 100 && !ready(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(ready(), true, reason: service.error);
  }

  Future<void> openAuto(
      WidgetTester tester, Size size, Brightness brightness) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        locale: const Locale('zh', 'CN'),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN')],
        home: ListenableBuilder(
            listenable: Listenable.merge([c, service]),
            builder: (_, child) => Home(c))));
    final rail = find.byType(NavigationRail);
    if (rail.evaluate().isNotEmpty) {
      expect(
          tester
              .widget<NavigationRail>(rail)
              .destinations
              .map((d) => (d.label as Text).data),
          ['专注', '任务', 'AUTO', '音乐库', '历史记录', '统计报告']);
    } else {
      expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .destinations
              .whereType<NavigationDestination>()
              .map((d) => d.label),
          ['专注', '任务', 'AUTO', '音乐库', '历史记录', '统计报告']);
    }
    await tester.tap(find.text('AUTO').last);
    await tester.pumpAndSettle();
  }

  for (final size in [const Size(1180, 1000), const Size(390, 844)]) {
    for (final brightness in Brightness.values) {
      testWidgets('AUTO inbox unread badge and settings fit $size $brightness',
          (tester) async {
        await openAuto(tester, size, brightness);
        final badge = find.byKey(const ValueKey('auto-unread-badge'));
        expect(tester.widget<Badge>(badge).isLabelVisible, false);
        await tester.tap(find.byKey(const ValueKey('auto-send-morning')));
        await pumpUntil(
            tester,
            () =>
                service.hasUnread &&
                tester
                        .widget<FilledButton>(
                            find.byKey(const ValueKey('auto-send-morning')))
                        .onPressed !=
                    null);
        expect(tester.widget<Badge>(badge).isLabelVisible, true);
        final message = find.byKey(const ValueKey('auto-message-2026-11-13'));
        await tester.ensureVisible(message);
        await tester.tap(message);
        await pumpUntil(
            tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
        expect(service.hasUnread, false);
        expect(tester.widget<Badge>(badge).isLabelVisible, false);
        expect(find.text('今天要交'), findsOneWidget);
        expect(find.text('昨天还没做完'), findsOneWidget);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        await tester
            .ensureVisible(find.byKey(const ValueKey('auto-scraper-tab')));
        await tester.tap(find.byKey(const ValueKey('auto-scraper-tab')));
        await tester.pumpAndSettle();
        final configure = find.byKey(const ValueKey('auto-configure-scraper'));
        await tester.ensureVisible(configure);
        await tester.tap(configure);
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('auto-script-path')),
            'D:/StudyAutomation/study_scraper.py');
        await tester
            .ensureVisible(find.byKey(const ValueKey('auto-chaoxing-cookie')));
        await tester.enterText(
            find.byKey(const ValueKey('auto-chaoxing-cookie')),
            'D:/StudyAutomation/chaoxing.txt');
        await tester
            .ensureVisible(find.byKey(const ValueKey('auto-mooc-cookie')));
        await tester.enterText(find.byKey(const ValueKey('auto-mooc-cookie')),
            'D:/StudyAutomation/mooc.txt');
        await tester
            .ensureVisible(find.byKey(const ValueKey('auto-import-group')));
        await tester.tap(find.byKey(const ValueKey('auto-import-group')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('课程任务').last);
        await tester.pumpAndSettle();
        await tester
            .tap(find.byKey(const ValueKey('auto-save-scraper-config')));
        await tester.pumpAndSettle();
        await pumpUntil(
            tester, () => service.settings.importGroupId == 'course');
        expect(
            service.settings.scriptPath, 'D:/StudyAutomation/study_scraper.py');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('saving task details preserves imported deadline seconds',
      (tester) async {
    final task = TaskItem(
        id: 'exact',
        name: '精确截止时间',
        due: DateTime.utc(2026, 11, 14),
        dueAt: DateTime.utc(2026, 11, 13, 16, 30, 38),
        modified: DateTime.utc(2026, 11, 13));
    TaskItem? saved;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (ctx) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      saved = await showDialog<TaskItem>(
                          context: ctx, builder: (_) => TaskEditor(task: task));
                    },
                    child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved!.dueAt, task.dueAt);
  });
  for (final size in [const Size(1180, 1000), const Size(390, 844)]) {
    testWidgets(
        'custom expiry rules validate, filter pasted text and persist $size',
        (tester) async {
      await openAuto(tester, size, Brightness.dark);
      await tester.tap(find.byKey(const ValueKey('auto-scraper-tab')));
      await tester.pumpAndSettle();
      final configure = find.byKey(const ValueKey('auto-configure-expiry'));
      await tester.ensureVisible(configure);
      await tester.tap(configure);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('auto-expiry-rule')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义过期天数').last);
      await tester.pumpAndSettle();
      final days = find.byKey(const ValueKey('auto-expiry-days'));
      await tester.enterText(days, '4x2');
      expect(tester.widget<TextFormField>(days).controller!.text, '42');
      await tester.enterText(days, '3651');
      await tester.tap(find.byKey(const ValueKey('auto-save-expiry')));
      await tester.pumpAndSettle();
      expect(find.text('填写 0–3650 天'), findsOneWidget);
      await tester.enterText(days, '14');
      await tester.tap(find.byKey(const ValueKey('auto-save-expiry')));
      await tester.pumpAndSettle();
      await pumpUntil(tester, () => service.settings.expiredAfterDays == 14);
      expect(find.text('忽略过期超过 14 天的任务'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
