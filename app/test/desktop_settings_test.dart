import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/main.dart';

void main() {
  testWidgets('Windows startup setting applies on save, not cancel',
      (tester) async {
    tester.view.physicalSize = const Size(1180, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController()
      ..store = LocalStore.testing(NativeDatabase.memory())
      ..desktopIntegrationAvailable = true;
    addTearDown(c.store.close);
    final writes = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, (call) async {
      if (call.method == 'setLaunchAtLogin') {
        writes.add((call.arguments as Map)['enabled'] as bool);
      }
      if (call.method == 'getDesktopIntegration') {
        return {
          'startupEnabled': writes.last,
          'startupCurrentPath': true,
          'shortcutExists': true,
          'shortcutCurrentPath': true
        };
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, null));
    await tester.pumpWidget(MaterialApp(home: Home(c)));
    Future<void> toggle() async {
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('launch-at-login'));
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.pumpAndSettle();
    }

    await toggle();
    expect(writes, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    expect(c.startupEnabled, false);
    await toggle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(writes, [true]);
    expect(c.startupEnabled, true);
    expect(tester.takeException(), isNull);
  });
}
