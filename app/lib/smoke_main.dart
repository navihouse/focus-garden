// Developer-only native runtime entry point. Never included by normal main.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'app_controller.dart';
import 'domain/timer_engine.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final folder = Directory(
      Platform.environment['FOCUS_SMOKE_DIR'] ?? 'P:/work/runtime-smoke');
  await folder.create(recursive: true);
  final report = File('${folder.path}/result.json');
  final seconds =
      int.parse(Platform.environment['FOCUS_SMOKE_SECONDS'] ?? '1500');
  AppController? c;
  try {
    final samples = 22050;
    final bytes = ByteData(44 + samples * 2);
    void ascii(int offset, String text) {
      for (int i = 0; i < text.length; i++) {
        bytes.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, samples, Endian.little);
    bytes.setUint32(28, samples * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    bytes.setUint32(40, samples * 2, Endian.little);
    for (int i = 0; i < samples; i++) {
      bytes.setInt16(44 + i * 2,
          (sin(2 * pi * 220 * i / samples) * 100).round(), Endian.little);
    }
    final audio = File('${folder.path}/fixture.wav');
    await audio.writeAsBytes(bytes.buffer.asUint8List());
    c = AppController();
    await c.initialize(directory: Directory('${folder.path}/data'));
    c.volume = 0;
    c.tracks = [
      {'id': 'fixture', 'name': 'Test WAV', 'path': audio.path}
    ];
    await c.saveTracks();
    int positionEvents = 0;
    bool everPlaying = false;
    final subscription = c.player!.stream.position.listen((p) {
      if (p.inMilliseconds > 0) positionEvents++;
    });
    final started = DateTime.now().toUtc();
    await c.perform(() => c!.startFocus(testSeconds: seconds));
    final limit = started.add(Duration(seconds: seconds + 30));
    while (c.phase == Phase.focus && DateTime.now().toUtc().isBefore(limit)) {
      await Future<void>.delayed(const Duration(seconds: 5));
      everPlaying = everPlaying || c.playing;
      await File('${folder.path}/progress.json').writeAsString(jsonEncode({
        'started': started.toIso8601String(),
        'remainingMs': c.remainingMs,
        'phase': c.phase.name,
        'musicPlaying': c.playing,
        'positionEvents': positionEvents
      }));
    }
    await subscription.cancel();
    await c.refresh();
    if (c.sessions.isEmpty) throw StateError('No saved session');
    final record = c.sessions.first;
    if (!record.completed ||
        record.milliseconds != seconds * 1000 ||
        !everPlaying ||
        positionEvents < 2) {
      throw StateError(
          'Runtime mismatch: ${record.toJson()}, everPlaying=$everPlaying, positionEvents=$positionEvents, message=${c.message}');
    }
    final stopped = !c.playing;
    await c.shutdown();
    c = null;
    final reopened = AppController();
    await reopened.initialize(directory: Directory('${folder.path}/data'));
    final restored = reopened.sessions.any((s) =>
        s.id == record.id && s.completed && s.milliseconds == seconds * 1000);
    await reopened.shutdown();
    if (!restored || !stopped) {
      throw StateError('Persistence or automatic music stop failed');
    }
    await report.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'passed': true,
      'seconds': seconds,
      'started': started.toIso8601String(),
      'finished': DateTime.now().toUtc().toIso8601String(),
      'savedMilliseconds': record.milliseconds,
      'musicPositionEvents': positionEvents,
      'musicStopped': stopped,
      'reopenedRecord': restored
    }));
    exit(0);
  } catch (e, stack) {
    await report.writeAsString(jsonEncode({
      'passed': false,
      'seconds': seconds,
      'error': '$e',
      'stack': '$stack'
    }));
    try {
      await c?.shutdown();
    } catch (_) {}
    exit(1);
  }
}
