import 'dart:io';
import 'dart:ui' as ui;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/app_background.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/data/backup.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/domain/timer_engine.dart';
import 'package:focus_garden/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppController c;
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('focus-theme-test-');
    c = AppController();
    c.dataDirectory = temp;
    c.store = LocalStore.testing(NativeDatabase.memory());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(AppController.native, (_) async => null);
  });
  tearDown(() async {
    await c.store.close(); c.dispose();
    await temp.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(AppController.native, null);
  });
  test('completion time survives edits, recovery, backup; re-completion gets a new time', () async {
    await c.store.task(TaskItem(id: 'a', name: 'A', modified: DateTime.utc(2026)));
    await c.refresh(); await c.toggleTaskCompleted('a');
    final completed = c.tasks.single.completedAt;
    expect(completed, isNotNull);
    await c.saveTask(TaskItem.fromJson({...c.tasks.single.toJson(), 'notes': 'Edited', 'modified': DateTime.utc(2030).toIso8601String()}));
    expect(c.tasks.single.completedAt, completed);
    final imported = previewBackup(exportBackup(c.tasks, []), [], []).tasks.single;
    expect(imported.completedAt, completed);
    await c.refresh(); expect(c.tasks.single.completedAt, completed);
    await c.toggleTaskCompleted('a'); expect(c.tasks.single.completedAt, isNull);
    await c.toggleTaskCompleted('a'); expect(c.tasks.single.completedAt!.isBefore(completed!), false);
  });
  test('legacy completed task falls back to modified without inventing a timestamp', () {
    final legacy = TaskItem(id: 'old', name: 'Old', status: 'done', modified: DateTime.utc(2020)).toJson()..remove('completedAt');
    final task = TaskItem.fromJson(legacy);
    expect(task.completedAt, isNull); expect(task.completionTime, DateTime.utc(2020));
  });
  test('old settings load default background, custom settings survive restart', () async {
    final old = const Settings().toJson()..remove('backgroundPath')..remove('backgroundOpacity');
    expect(Settings.fromJson(old).backgroundPath, isNull);
    expect(Settings.fromJson(old).backgroundOpacity, .2);
    await c.saveSettings(const Settings(theme: 'dark', backgroundOpacity: .6));
    final restored = Settings.fromJson(asJson(await c.store.get('settings')));
    expect(restored.theme, 'dark'); expect(restored.backgroundOpacity, .6);
  });
  test('background imports as owned PNG; deleting source does not break it', () async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.green, BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(8, 8);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose(); picture.dispose();
    final source = File('${temp.path}/source.png');
    await source.writeAsBytes(bytes!.buffer.asUint8List());
    final path = await c.importBackground(source.path);
    await source.delete(); expect(await File(path).exists(), true);
    await c.saveSettings(Settings(backgroundPath: path));
    await c.discardUnusedBackground(path); expect(await File(path).exists(), true);
    await c.saveSettings(const Settings()); expect(await File(path).exists(), false);
  });
  test('invalid background does not change saved settings or delete external files', () async {
    final file = File('${temp.path}/not-an-image.png'); await file.writeAsString('broken');
    await expectLater(c.importBackground(file.path), throwsA(anything));
    await c.discardUnusedBackground(file.path); expect(await file.exists(), true);
    expect(c.settings.backgroundPath, isNull);
  });
  test('timer shortcut does not start idle timer, toggles active timer independently', () async {
    await c.handleHotkey('timer'); expect(c.phase, Phase.idle);
    c.engine.start(id: 'clock', device: 'test', seconds: 1500,
      now: DateTime.now().toUtc(), tick: c.clock.elapsedMilliseconds);
    await c.handleHotkey('timer'); expect(c.phase, Phase.paused);
    await c.handleHotkey('timer'); expect(c.phase, Phase.focus);
    expect(c.sessions, isEmpty);
  });
  testWidgets('completed tasks start folded and show newest first on both pages', (tester) async {
    tester.view.physicalSize = const Size(1180, 2000); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    for (var i = 0; i < 3; i++) await c.store.task(TaskItem(id: '$i', name: 'Finished $i', status: 'done',
      modified: DateTime.utc(2030 - i), completedAt: DateTime.utc(2026, 1, i + 1)));
    await c.refresh();
    await tester.pumpWidget(MaterialApp(home: ListenableBuilder(listenable: c, builder: (_, child) => Home(c))));
    for (final (page, key) in [('任务', 'completed-tasks'), ('专注', 'completed-focus')]) {
      await tester.tap(find.text(page).last); await tester.pumpAndSettle();
      final button = find.byKey(ValueKey(key)); await tester.ensureVisible(button);
      expect(find.text('Finished 2'), findsNothing);
      await tester.tap(button); await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Finished 0')); await tester.pumpAndSettle();
      final order = tester.widgetList<ListTile>(find.byType(ListTile)).map((w) => (w.title as Text).data).toList();
      expect(order.where((v) => v?.startsWith('Finished') == true), ['Finished 2', 'Finished 1', 'Finished 0']);
      await tester.ensureVisible(button); await tester.tap(button); await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets('unavailable wallpaper falls back without hiding application content', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AppBackground(path: 'missing.png', opacity: .5,
      child: Scaffold(backgroundColor: Colors.transparent, body: Text('Visible')))));
    await tester.pumpAndSettle(); expect(find.text('Visible'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
