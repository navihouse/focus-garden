// Run only with the explicit isolated probe environment.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/notes_controller.dart';

Future<void> main() async {
  final directory = Platform.environment['FOCUS_LINK_PROBE_DIR'];
  if (directory == null || Platform.environment['FOCUS_NATIVE_PROBE'] != '1') {
    throw StateError('Explicit isolated probe environment required');
  }
  try {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(const MaterialApp(
        home: Scaffold(body: Text('Isolated local-file validation'))));
    final path = File('$directory/target-path.txt').readAsStringSync();
    final notes = NotesController(path, []);
    notes.renameLink(notes.links.single, '课堂讲义');
    if (notes.links.single.target != path) {
      throw StateError('Alias changed target');
    }
    await AppController.native
        .invokeMethod('openLocalFile', {'path': notes.links.single.target});
    final timer = Stopwatch()..start();
    while (!File('$directory/opened.json').existsSync()) {
      if (timer.elapsedMilliseconds > 20000) {
        throw StateError('System file association did not launch');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final opened =
        jsonDecode(File('$directory/opened.json').readAsStringSync()) as Map;
    if (opened['path'] != path || !File(path).existsSync()) {
      throw StateError('System opened another target');
    }
    int rejected = 0;
    for (final invalid in [
      '$directory/missing.txt',
      'https://example.com/file',
      r'\\server\file'
    ]) {
      try {
        await AppController.native
            .invokeMethod('openLocalFile', {'path': invalid});
      } catch (_) {
        rejected++;
      }
    }
    if (rejected != 3) throw StateError('Invalid file targets accepted');
    await File('$directory/result.json').writeAsString(jsonEncode({
      'ok': true,
      'nativeAssociatedFileOpened': true,
      'aliasKeepsTarget': true,
      'unicodeAndSpaces': true,
      'invalidTargetsRejected': rejected,
    }));
    notes.dispose();
    exit(0);
  } catch (e, stack) {
    await File('$directory/result.json').writeAsString(
        jsonEncode({'ok': false, 'error': '$e', 'stack': '$stack'}));
    exit(1);
  }
}
