import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:focus_garden/main.dart' show FocusApp;
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/domain/timer_engine.dart';

void main() {
  final folder = Directory(Platform.environment['FOCUS_NATIVE_PROBE_DIR'] ??
      'P:/work/native-probe-results')
    ..createSync(recursive: true);
  final result = File('${folder.path}/result.json');
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1140, 820));
    final errors = <String>[];
    FlutterError.onError = (details) => errors.add(details.exceptionAsString());
    final c = AppController();
    await c.initialize(directory: Directory('${folder.path}/data'));
    final boundary = GlobalKey();
    runApp(RepaintBoundary(key: boundary, child: FocusApp(c)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      windowManager.hide();
    });
    await Future<void>.delayed(const Duration(seconds: 5));
    final render =
        boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await render.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('${folder.path}/native-desktop.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
    final codecResults = <String, dynamic>{};
    final fixtureFolder = Directory('${folder.path}/fixtures');
    for (final extension in ['wav', 'mp3', 'flac', 'm4a']) {
      final file = File('${fixtureFolder.path}/fixture.$extension');
      if (!await file.exists()) throw StateError('Missing fixture: $extension');
      c.tracks = [
        {'id': extension, 'name': 'Fixture $extension', 'path': file.path}
      ];
      c.volume = 0;
      await c.saveTracks();
      await c.perform(() => c.startFocus(testSeconds: 30));
      await Future<void>.delayed(const Duration(seconds: 3));
      final position = await c.player!.stream.position.first;
      if (!c.playing || position.inMilliseconds == 0) {
        throw StateError('Decode failed $extension: ${c.message}');
      }
      await c.perform(c.pauseResume);
      if (c.phase != Phase.paused || c.playing) {
        throw StateError('Pause failed $extension');
      }
      final before = c.remainingMs;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (c.remainingMs != before) throw StateError('Paused time changed');
      await c.perform(c.pauseResume);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await c.perform(() => c.end());
      codecResults[extension] = {
        'played': true,
        'positionMs': position.inMilliseconds,
        'pauseResume': true,
        'savedIncomplete': c.sessions.first.reason == 'early'
      };
    }
    if (errors.isNotEmpty) throw StateError(errors.join('\n'));
    await c.music('repeat'); // all -> one
    await c.music('repeat'); // one -> off
    await c.music('shuffle');
    await c.saveTracks();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final retained = c.player!.state.playlistMode == PlaylistMode.none &&
        c.player!.state.shuffle;
    if (!retained) throw StateError('Playlist edit reset repeat/shuffle modes');
    await c.shutdown();
    await trayManager.destroy();
    await result.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'passed': true,
      'uiStartup': true,
      'playlistModesRetained': retained,
      'codecs': codecResults,
      'flutterErrors': errors,
      'finished': DateTime.now().toUtc().toIso8601String()
    }));
    exit(0);
  }, (e, stack) {
    result.writeAsStringSync(
        jsonEncode({'passed': false, 'error': '$e', 'stack': '$stack'}));
    exit(1);
  });
}
