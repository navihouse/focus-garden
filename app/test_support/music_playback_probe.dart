// Native regression for desktop library preview; uses an isolated database.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/domain/timer_engine.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const SizedBox.shrink());
  final folder = Directory(Platform.environment['FOCUS_MUSIC_PROBE_DIR']!)
    ..createSync(recursive: true);
  final result = File('${folder.path}/result.json');
  AppController? controller;
  try {
    final audio = File(Platform.environment['FOCUS_MUSIC_PROBE_FILE']!);
    if (!audio.existsSync()) throw StateError('Source audio file missing');
    final c = AppController();
    controller = c;
    await c.initialize(directory: Directory('${folder.path}/data'));
    final checks = <String, bool>{};
    Future<void> expect(String name, bool Function() condition) async {
      final limit = DateTime.now().add(const Duration(seconds: 6));
      while (!condition() && DateTime.now().isBefore(limit)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      checks[name] = condition();
      if (!checks[name]!) throw StateError('$name: ${c.message}');
    }

    c.volume = 0; // Decode and advance without disturbing the user's speakers.
    c.tracks = [
      {
        'id': 'regression',
        'name': audio.uri.pathSegments.last,
        'path': audio.path
      }
    ];
    await c.saveTracks();
    await c.perform(() => c.music('toggle'));
    await expect('idlePreviewAdvances',
        () => c.playing && c.player!.state.position.inMilliseconds > 500);
    checks['previewCreatesNoRecord'] = !c.active && c.sessions.isEmpty;
    final firstPosition = c.player!.state.position.inMilliseconds;
    await c.perform(() => c.music('toggle'));
    await expect('previewPauses', () => !c.playing);
    await c.perform(() => c.music('toggle'));
    await expect('previewResumes', () => c.playing);
    await c.perform(() => c.startFocus(testSeconds: 30));
    await expect('focusStartsAudio', () => c.playing && c.phase == Phase.focus);
    final before = c.remainingMs;
    await c.perform(() => c.music('toggle'));
    await expect('musicPauseIndependentOfTimer',
        () => !c.playing && c.phase == Phase.focus);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    checks['musicPauseDoesNotPauseTimer'] = c.remainingMs < before;
    await c.perform(() => c.music('toggle'));
    await expect('focusMusicResumes', () => c.playing);
    await c.perform(c.pauseResume);
    await expect(
        'timerPauseStopsAudio', () => !c.playing && c.phase == Phase.paused);
    await c.perform(() => c.music('toggle'));
    checks['pausedPlayShowsExplanation'] =
        !c.playing && c.message.contains('继续专注');
    await c.perform(c.pauseResume);
    await expect(
        'timerResumeRestoresAudio', () => c.playing && c.phase == Phase.focus);
    await c.perform(() => c.end());
    await expect('focusEndStopsAudio', () => !c.playing);
    checks['onlyFocusCreatesRecord'] =
        c.sessions.length == 1 && c.sessions.single.reason == 'early';
    await c.perform(() => c.music('toggle'));
    await expect('previewAfterFocusWorks', () => c.playing && !c.active);
    await c.perform(c.startRest);
    await expect('restStopsAudio', () => !c.playing && c.isRest);
    await c.perform(() => c.music('toggle'));
    checks['restBlocksPlaybackWithExplanation'] =
        !c.playing && c.message.contains('休息');
    await c.perform(() => c.end());
    await c.perform(() => c.music('mute'));
    await c.perform(() => c.music('toggle'));
    checks['mutedPlayShowsExplanation'] =
        !c.playing && c.message.contains('取消静音');
    if (checks.values.any((passed) => !passed)) {
      throw StateError('Regression checks failed: $checks');
    }
    await c.shutdown();
    controller = null;
    await result.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'passed': true,
      'fileName': audio.uri.pathSegments.last,
      'fileBytes': audio.lengthSync(),
      'previewPositionMs': firstPosition,
      'checks': checks,
      'finished': DateTime.now().toUtc().toIso8601String()
    }));
    exit(0);
  } catch (error, stack) {
    try {
      await controller?.shutdown();
    } catch (_) {}
    await result.writeAsString(
        jsonEncode({'passed': false, 'error': '$error', 'stack': '$stack'}));
    exit(1);
  }
}
