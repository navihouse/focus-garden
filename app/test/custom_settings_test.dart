import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/app_background.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/domain/hotkey.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/hotkey_editor.dart';
import 'package:focus_garden/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'history labels invalid sessions and task totals use only valid focus',
      (tester) async {
    tester.view.physicalSize = const Size(1180, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController();
    addTearDown(c.dispose);
    final a = DateTime.utc(2026, 10, 19);
    c.tasks = [TaskItem(id: 'task', name: 'Physics', estimate: 3, modified: a)];
    c.sessions = [
      for (final seconds in [59, 60])
        FocusSession(
            id: '$seconds',
            device: 'test',
            taskId: 'task',
            taskName: 'Physics',
            plannedSeconds: seconds,
            started: a,
            ended: a.add(Duration(seconds: seconds)),
            spans: [TimeSpan(a, a.add(Duration(seconds: seconds)))],
            completed: true,
            reason: 'completed')
    ];
    await tester.pumpWidget(MaterialApp(home: Home(c)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('任务').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('完成 1 / 3 个番茄 · 1.0 分钟'), findsOneWidget);
    await tester.tap(find.text('历史记录').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('无效自习（不足 1 分钟）'), findsOneWidget);
    expect(find.textContaining('有效专注 1.0 分钟'), findsOneWidget);
    await tester.tap(find.text('无效自习'));
    await tester.pumpAndSettle();
    expect(find.text('Physics'), findsOneWidget);
    expect(find.textContaining('有效专注 0.0 分钟'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final brightness in Brightness.values) {
    testWidgets(
        'background controls preview, cancel and save on narrow $brightness screen',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = AppController()
        ..store = LocalStore.testing(NativeDatabase.memory())
        ..settings = const Settings(backgroundPath: 'missing.png');
      addTearDown(c.store.close);
      addTearDown(c.dispose);
      await tester.pumpWidget(
          MaterialApp(theme: ThemeData(brightness: brightness), home: Home(c)));
      Future<void> change() async {
        await tester.tap(find.byTooltip('设置'));
        await tester.pumpAndSettle();
        final slider = find.byKey(const ValueKey('card-transparency'));
        await tester.ensureVisible(slider);
        await tester.pumpAndSettle();
        tester.widget<Slider>(slider).onChanged!(1);
        await tester.pumpAndSettle();
        expect(find.text('卡片透明度 100%'), findsOneWidget);
        final preview = find.byKey(const ValueKey('background-card-preview'));
        expect(Theme.of(tester.element(preview)).cardTheme.color!.a, 0);
      }

      await change();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(c.settings.cardTransparency, .65);
      await change();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(c.settings.cardTransparency, 1);
      expect(
          Settings.fromJson(asJson(await c.store.get('settings')))
              .cardTransparency,
          1);
      expect(tester.takeException(), isNull);
    });
  }
  test('legacy settings default; custom keys and transparency round trip', () {
    final old = const Settings().toJson()
      ..remove('musicHotkey')
      ..remove('timerHotkey')
      ..remove('cardTransparency');
    final restored = Settings.fromJson(old);
    expect(restored.musicHotkey.label, 'Ctrl + Shift + 空格');
    expect(restored.timerHotkey.label, 'Ctrl + Alt + 空格');
    expect(restored.cardTransparency, .65);
    final custom = Settings.fromJson(const Settings(
            cardTransparency: .9,
            musicHotkey: HotkeyBinding(6, 0x4d),
            timerHotkey: HotkeyBinding(3, 0x70))
        .toJson());
    expect(custom.musicHotkey.label, 'Ctrl + Shift + M');
    expect(custom.timerHotkey.label, 'Ctrl + Alt + F1');
    expect(custom.cardTransparency, .9);
    expect(
        HotkeyBinding.fromJson(
                {'modifiers': 8, 'keyCode': 65}, HotkeyBinding.musicDefault)
            .label,
        restored.musicHotkey.label);
  });
  test(
      'recorder restricts reserved/unmodified keys and accepts modifiers and F11',
      () {
    expect(
        bindingForKey(LogicalKeyboardKey.keyM,
                control: true, alt: false, shift: true)!
            .label,
        'Ctrl + Shift + M');
    expect(
        bindingForKey(LogicalKeyboardKey.keyM,
            control: false, alt: false, shift: true),
        isNull);
    expect(
        bindingForKey(LogicalKeyboardKey.f12,
            control: true, alt: false, shift: false),
        isNull);
    expect(
        bindingForKey(LogicalKeyboardKey.f11,
                control: false, alt: true, shift: false)!
            .label,
        'Alt + F11');
  });
  test(
      'registration conflict leaves settings and persisted values unchanged; success survives reload',
      () async {
    final c = AppController()
      ..store = LocalStore.testing(NativeDatabase.memory());
    addTearDown(c.store.close);
    addTearDown(c.dispose);
    var conflict = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, (call) async {
      if (call.method == 'registerHotkeys') {
        return conflict
            ? {
                'accepted': false,
                'music': false,
                'timer': true,
                'restored': {'music': true, 'timer': true}
              }
            : {'accepted': true, 'music': true, 'timer': true};
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, null));
    const custom =
        Settings(cardTransparency: .85, musicHotkey: HotkeyBinding(6, 0x4d));
    await expectLater(c.saveSettings(custom), throwsFormatException);
    expect(c.settings.musicHotkey.label, HotkeyBinding.musicDefault.label);
    expect(await c.store.get('settings'), isNull);
    await expectLater(
        c.saveSettings(const Settings(timerHotkey: HotkeyBinding.musicDefault)),
        throwsFormatException);
    conflict = false;
    await c.saveSettings(custom);
    final saved = Settings.fromJson(asJson(await c.store.get('settings')));
    expect(saved.musicHotkey.label, custom.musicHotkey.label);
    expect(saved.cardTransparency, .85);
  });
  for (final brightness in Brightness.values) {
    for (final transparency in [0.0, .65, 1.0]) {
      testWidgets(
          'wallpaper cards honor $transparency in $brightness, removal restores opacity',
          (tester) async {
        final base = ThemeData(brightness: brightness);
        late ThemeData actual;
        Widget content(String? path) => MaterialApp(
            theme: base,
            home: AppBackground(
                path: path,
                opacity: .8,
                cardTransparency: transparency,
                child: Builder(builder: (context) {
                  actual = Theme.of(context);
                  return const Card(child: Text('Readable'));
                })));
        await tester.pumpWidget(content('missing.png'));
        await tester.pumpAndSettle();
        expect(actual.cardTheme.color!.a, closeTo(1 - transparency, .005));
        expect(actual.cardTheme.surfaceTintColor, Colors.transparent);
        expect(find.text('Readable'), findsOneWidget);
        await tester.pumpWidget(content(null));
        await tester.pumpAndSettle();
        expect(actual.cardTheme.color, base.cardTheme.color);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets(
      'recording suspends active shortcuts, cancel preserves settings, save applies new key',
      (tester) async {
    tester.view.physicalSize = const Size(1180, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController()
      ..store = LocalStore.testing(NativeDatabase.memory());
    addTearDown(c.store.close);
    addTearDown(c.dispose);
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, (call) async {
      calls.add(call.method);
      return {'music': true, 'timer': true, 'accepted': true};
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, null));
    await tester.pumpWidget(MaterialApp(home: Home(c)));
    Future<void> record() async {
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('music-hotkey'));
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: field, matching: find.text('修改')));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    await record();
    expect(find.text('Ctrl + Shift + M'), findsOneWidget);
    expect(calls, ['suspendHotkeys', 'resumeHotkeys']);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(c.settings.musicHotkey.label, HotkeyBinding.musicDefault.label);
    await record();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(c.settings.musicHotkey.label, 'Ctrl + Shift + M');
    expect(calls.last, 'registerHotkeys');
    expect(tester.takeException(), isNull);
  });
}
