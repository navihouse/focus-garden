// Explicit opt-in entry point with an isolated database, never production data.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/domain/hotkey.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/domain/timer_engine.dart';

class ProbeController extends AppController {
  final actions = <String>[];
  @override
  Future<void> handleHotkey(String action) async {
    actions.add(action);
    await super.handleHotkey(action);
  }
}

Future<void> main() async {
  final directory = Platform.environment['FOCUS_SETTINGS_PROBE_DIR'];
  if (directory == null || Platform.environment['FOCUS_NATIVE_PROBE'] != '1') {
    throw StateError('Explicit isolated probe environment required');
  }
  final folder = Directory(directory)..createSync(recursive: true);
  final c = ProbeController();
  Future<void> marker(String name) =>
      File('${folder.path}/$name').writeAsString('{}');
  Future<void> waitFor(bool Function() predicate) async {
    final timer = Stopwatch()..start();
    while (!predicate()) {
      if (timer.elapsedMilliseconds > 30000) {
        throw StateError('Probe timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  try {
    WidgetsFlutterBinding.ensureInitialized();
    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();
    await c.initialize(directory: Directory('${folder.path}/data'));
    runApp(const MaterialApp(
        home: Scaffold(body: Text('Isolated settings validation'))));
    const custom = Settings(
        musicHotkey: HotkeyBinding(6, 0x78),
        timerHotkey: HotkeyBinding(3, 0x78),
        cardTransparency: .8);
    await c.saveSettings(custom);
    c.engine.start(
        id: 'probe',
        device: c.device,
        seconds: 1500,
        now: DateTime.now().toUtc(),
        tick: c.clock.elapsedMilliseconds);
    await windowManager.hide();
    await marker('ready');
    await waitFor(() => c.actions.length >= 2);
    if (c.actions.join(',') != 'music,timer' || c.phase != Phase.paused) {
      throw StateError('Global dispatch failed');
    }
    await marker('reserve-conflict');
    await waitFor(() => File('${folder.path}/conflict-reserved').existsSync());
    bool rejected = false;
    try {
      await c.saveSettings(const Settings(
          musicHotkey: HotkeyBinding(6, 0x79),
          timerHotkey: HotkeyBinding(3, 0x79)));
    } on FormatException {
      rejected = true;
    }
    if (!rejected || !c.settings.musicHotkey.sameAs(custom.musicHotkey)) {
      throw StateError('Conflict rollback failed');
    }
    await marker('rollback-ready');
    await waitFor(() => c.actions.length >= 3);
    if (c.phase != Phase.focus) {
      throw StateError('Original key was not restored');
    }
    await marker('swap-ready');
    await waitFor(() => File('${folder.path}/conflict-released').existsSync());
    await c.saveSettings(const Settings(
        musicHotkey: HotkeyBinding(6, 0x79),
        timerHotkey: HotkeyBinding(3, 0x79),
        cardTransparency: .9));
    await marker('swapped');
    await waitFor(() => c.actions.length >= 4);
    if (c.phase != Phase.paused) throw StateError('New key did not pause');
    final saved = Settings.fromJson(asJson(await c.store.get('settings')));
    if (saved.cardTransparency != .9 || saved.timerHotkey.keyCode != 0x79) {
      throw StateError('Settings were not persisted');
    }
    await c.perform(c.end);
    await c.shutdown();
    await File('${folder.path}/result.json').writeAsString(jsonEncode({
      'ok': true,
      'globalMusicAndTimer': true,
      'conflictRollback': true,
      'newBindingDispatched': true,
      'persisted': true,
    }));
    exit(0);
  } catch (e, stack) {
    await File('${folder.path}/result.json').writeAsString(
        jsonEncode({'ok': false, 'error': '$e', 'stack': '$stack'}));
    exit(1);
  }
}
