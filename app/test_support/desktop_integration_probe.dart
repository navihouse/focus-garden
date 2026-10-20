// Release-mode integration probe. Always use an isolated data directory and
// restore the caller's Run registry value in the external test harness.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/main.dart' show FocusApp;

Future<void> main() async {
  final path = Platform.environment['FOCUS_DESKTOP_PROBE_DIR'];
  if (path == null || Platform.environment['FOCUS_NATIVE_PROBE'] != '1') {
    throw StateError('Explicit isolated probe environment required');
  }
  final folder = Directory(path)..createSync(recursive: true);
  try {
    WidgetsFlutterBinding.ensureInitialized();
    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();
    final c = AppController();
    await c.initialize(directory: Directory('${folder.path}/data'));
    runApp(FocusApp(c));
    await Future<void>.delayed(const Duration(seconds: 2));
    await c.setLaunchAtLogin(true);
    if (!c.startupEnabled || !c.startupCurrentPath) {
      throw StateError('Startup registration did not match this executable');
    }
    File('${folder.path}/enabled.json').writeAsStringSync('{"enabled":true}');
    // The host reads the actual registry command before authorizing disable.
    final proceed = File('${folder.path}/continue');
    for (var i = 0; i < 200 && !proceed.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!proceed.existsSync()) throw StateError('Host handshake timed out');
    await c.setLaunchAtLogin(false);
    if (c.startupEnabled) throw StateError('Startup disable did not persist');
    await c.store.task(TaskItem(
        id: 'desktop-probe-task',
        name: 'Study',
        modified: DateTime.now(),
        notes: 'First review\nThen practice',
        subtasks: const [
          SubtaskItem(id: 'step-1', name: 'Review', completed: true)
        ]));
    final saved = (await c.store.tasks()).single;
    if (!saved.subtasks.single.completed || !saved.notes.contains('\n')) {
      throw StateError('Task details were not persisted');
    }
    File('${folder.path}/result.json').writeAsStringSync(jsonEncode({
      'ok': true,
      'startupEnableDisable': true,
      'startupCurrentPath': true,
      'taskDetailsSqlite': true,
      'idleNoSessions': c.sessions.isEmpty,
    }));
    // Remain alive so the host can verify hidden start and tray restore/quit.
  } catch (e, st) {
    File('${folder.path}/result.json').writeAsStringSync(
        jsonEncode({'ok': false, 'error': '$e', 'stack': '$st'}));
    exitCode = 1;
    exit(1);
  }
}
