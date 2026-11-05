import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/domain/hotkey.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/domain/music_library.dart';
import 'package:focus_garden/hotkey_editor.dart';
import 'package:focus_garden/main.dart';

class DispatchController extends AppController {
  final commands = <String>[];
  @override
  Future<void> music(String action, [Object? value]) async =>
      commands.add(action);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const status = {
    'accepted': true,
    'music': true,
    'timer': true,
    'previous': true,
    'next': true
  };
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, (_) async => status);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, null);
  });

  test(
      'legacy settings add exact requested arrow defaults and custom keys round trip',
      () {
    final legacy = const Settings().toJson()
      ..remove('previousHotkey')
      ..remove('nextHotkey');
    final restored = Settings.fromJson(legacy);
    expect(restored.previousHotkey.label, 'Ctrl + Shift + →');
    expect(restored.nextHotkey.label, 'Ctrl + Shift + ←');
    final custom = Settings.fromJson(const Settings(
            previousHotkey: HotkeyBinding(3, 0x41),
            nextHotkey: HotkeyBinding(3, 0x42))
        .toJson());
    expect(custom.previousHotkey.label, 'Ctrl + Alt + A');
    expect(custom.nextHotkey.label, 'Ctrl + Alt + B');
  });

  test('recorder maps arrow directions and rejects unmodified arrow', () {
    expect(
        bindingForKey(LogicalKeyboardKey.arrowRight,
                control: true, shift: true, alt: false)!
            .keyCode,
        0x27);
    expect(
        bindingForKey(LogicalKeyboardKey.arrowLeft,
                control: true, shift: true, alt: false)!
            .keyCode,
        0x25);
    expect(
        bindingForKey(LogicalKeyboardKey.arrowLeft,
            control: false, shift: false, alt: false),
        isNull);
  });

  test('all pairs of duplicate shortcuts are rejected before saving', () async {
    final c = AppController()
      ..store = LocalStore.testing(NativeDatabase.memory());
    addTearDown(c.store.close);
    addTearDown(c.dispose);
    final defaults = const Settings().hotkeys.values.toList();
    for (var i = 0; i < 4; i++) {
      for (var j = i + 1; j < 4; j++) {
        final keys = [...defaults];
        keys[j] = keys[i];
        await expectLater(
            c.saveSettings(Settings(
                musicHotkey: keys[0],
                timerHotkey: keys[1],
                previousHotkey: keys[2],
                nextHotkey: keys[3])),
            throwsFormatException);
      }
    }
    expect(await c.store.get('settings'), isNull);
  });

  test(
      'track hotkeys dispatch independently of timer and suppress during capture',
      () async {
    final c = DispatchController();
    addTearDown(c.dispose);
    await c.handleHotkey('previous');
    await c.handleHotkey('next');
    expect(c.commands, ['previous', 'next']);
    expect(c.active, false);
    await c.suspendHotkeys();
    await c.handleHotkey('previous');
    await c.handleHotkey('next');
    expect(c.commands.length, 2);
    await c.resumeHotkeys();
    await c.handleHotkey('next');
    expect(c.commands, ['previous', 'next', 'next']);
  });

  test(
      'new key conflict preserves settings; successful four-key registration persists',
      () async {
    final c = AppController()
      ..store = LocalStore.testing(NativeDatabase.memory());
    addTearDown(c.store.close);
    addTearDown(c.dispose);
    var conflict = true;
    Map<dynamic, dynamic>? sent;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, (call) async {
      sent = call.arguments as Map;
      return conflict
          ? {
              ...status,
              'accepted': false,
              'previous': false,
              'restored': status
            }
          : status;
    });
    const custom = Settings(
        previousHotkey: HotkeyBinding(3, 0x41),
        nextHotkey: HotkeyBinding(3, 0x42));
    await expectLater(
        c.saveSettings(custom),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'label', contains('前一首'))));
    expect(c.settings.previousHotkey.keyCode, 0x27);
    expect(await c.store.get('settings'), isNull);
    conflict = false;
    await c.saveSettings(custom);
    expect(sent!.keys, containsAll(['music', 'timer', 'previous', 'next']));
    final saved = Settings.fromJson(asJson(await c.store.get('settings')));
    expect(saved.previousHotkey.keyCode, 0x41);
    expect(saved.nextHotkey.keyCode, 0x42);
  });

  test('playback modes are exclusive, including after a legacy import',
      () async {
    final old = MusicLibrary.empty().toJson()..['repeat'] = 'off';
    expect(MusicLibrary.fromJson(old).repeat, 'all');
    final legacyConflict = MusicLibrary.fromJson({
      ...old,
      'shuffle': true,
      'repeat': 'all',
    });
    expect(legacyConflict.shuffle, true);
    expect(legacyConflict.repeat, 'off');
    final c = AppController()
      ..store = LocalStore.testing(NativeDatabase.memory());
    addTearDown(c.store.close);
    addTearDown(c.dispose);
    expect(c.repeat, 'all');
    await c.music('repeat');
    expect(c.repeat, 'one');
    expect(c.shuffle, false);
    await c.music('shuffle');
    expect(c.shuffle, true);
    expect(c.repeat, 'off');
    final saved =
        MusicLibrary.fromJson(asJson(await c.store.get('musicLibrary')));
    expect(saved.shuffle, true);
    expect(saved.repeat, 'off');
    await c.music('repeat');
    expect(c.repeat, 'all');
    expect(c.shuffle, false);
    await c.music('shuffle');
    expect(c.repeat, 'off');
    await c.music('shuffle');
    expect(c.shuffle, false);
    expect(
        MusicLibrary.fromJson(asJson(await c.store.get('musicLibrary'))).repeat,
        'all');
  });

  for (final next in [false, true]) {
    testWidgets(
        'arrow shortcut can be captured and saved ${next ? 'next' : 'previous'}',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = AppController()
        ..store = LocalStore.testing(NativeDatabase.memory());
      addTearDown(c.store.close);
      addTearDown(c.dispose);
      await tester.pumpWidget(MaterialApp(home: Home(c)));
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final field =
          find.byKey(ValueKey(next ? 'next-hotkey' : 'previous-hotkey'));
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: field, matching: find.text('修改')));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(
          next ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect((next ? c.settings.nextHotkey : c.settings.previousHotkey).label,
          next ? 'Ctrl + Alt + ←' : 'Ctrl + Alt + →');
      expect(tester.takeException(), isNull);
    });
  }
}
