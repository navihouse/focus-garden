import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/domain/timer_engine.dart';
import 'package:focus_garden/main.dart' show FocusApp, Home;
import 'package:focus_garden/task_editor.dart';

Future<void> main() async {
  final path = Platform.environment['FOCUS_WORKFLOW_PROBE_DIR'];
  if (path == null || Platform.environment['FOCUS_NATIVE_PROBE'] != '1') {
    throw StateError('Explicit isolated probe environment required');
  }
  final folder = Directory(path)..createSync(recursive: true);
  try {
    WidgetsFlutterBinding.ensureInitialized();
    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(900, 950));
    final c = AppController();
    await c.initialize(directory: Directory('${folder.path}/data'));
    for (final id in ['first', 'second']) {
      await c.saveTask(TaskItem(
          id: id,
          name: id == 'first' ? '本周学习任务：复习课程与完成练习' : 'Task $id',
          notes: 'Probe task',
          subtasks: const [SubtaskItem(id: 's1', name: 'Review examples')],
          modified: DateTime.utc(2026)));
    }
    final boundary = GlobalKey();
    runApp(RepaintBoundary(key: boundary, child: FocusApp(c)));
    await Future<void>.delayed(const Duration(seconds: 2));
    await c.setFocusPinned(true);
    if (!await windowManager.isAlwaysOnTop()) {
      throw StateError('Native pin did not take effect');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final render =
        boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final screenshot = await render.toImage();
    final png = await screenshot.toByteData(format: ui.ImageByteFormat.png);
    File('${folder.path}/pinned.png')
        .writeAsBytesSync(png!.buffer.asUint8List());
    screenshot.dispose();
    File('${folder.path}/pinned.json').writeAsStringSync('{"pinned":true}');
    final proceed = File('${folder.path}/continue');
    for (var i = 0; i < 300 && !proceed.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!proceed.existsSync()) throw StateError('Host handshake timed out');
    Element? findElement(bool Function(Widget) matches) {
      Element? found;
      void visit(Element element) {
        if (found != null) return;
        if (matches(element.widget)) {
          found = element;
          return;
        }
        element.visitChildElements(visit);
      }

      boundary.currentContext!.visitChildElements(visit);
      return found;
    }

    Future<void> editorScreenshot(String name) async {
      final render =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final shot = await render.toImage();
      final bytes = await shot.toByteData(format: ui.ImageByteFormat.png);
      File('${folder.path}/$name.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
      shot.dispose();
    }

    final task = c.tasks.firstWhere((t) => t.id == 'first');
    final edited = showDialog<TaskItem>(
        context: findElement((w) => w is Home)!,
        builder: (_) => TaskEditor(task: task));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final checkbox = findElement((w) => w is Checkbox)!.widget as Checkbox;
    checkbox.onChanged!(true);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (findElement((w) => w.key == const ValueKey('subtask-sound-error')) !=
        null) {
      throw StateError('Subtask completion sound failed');
    }
    await editorScreenshot('editor-completed');
    await Scrollable.ensureVisible(
        findElement((w) => w is Text && w.data == '选择日期')!);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final nameBox = findElement((w) => w.key == const ValueKey('task-name'))!
        .findRenderObject() as RenderBox;
    if (nameBox.localToGlobal(Offset.zero).dy < 0) {
      throw StateError('Task name scrolled out of view');
    }
    await editorScreenshot('editor-scrolled');
    final save = findElement((w) =>
            w is FilledButton &&
            w.child is Text &&
            (w.child as Text).data == '保存')!
        .widget as FilledButton;
    save.onPressed!();
    final updated = await edited;
    if (updated == null ||
        !updated.subtasks.single.completed ||
        updated.name != task.name) {
      throw StateError(
          'Subtask editor did not preserve the task name and completion');
    }
    await c.saveTask(updated);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await c.toggleTaskCompleted('first');
    if (c.message.isNotEmpty ||
        c.tasks.last.id != 'first' ||
        c.tasks.last.status != 'done') {
      throw StateError('Completion or native bell failed: ${c.message}');
    }
    await c.setFocusPinned(false);
    if (await windowManager.isAlwaysOnTop()) {
      throw StateError('Native pin did not clear');
    }
    await c.deleteTask('second');
    final saved = await c.store.tasks();
    if (saved.length != 1 || saved.single.status != 'done') {
      throw StateError('SQLite task update failed');
    }
    c.settings = const Settings(shortBreak: 1, longBreak: 2);
    c.completedCycle = 3;
    await c.perform(() => c.startFocus(testSeconds: 1));
    Future<void> waitFor(Phase phase) async {
      final timeout = Stopwatch()..start();
      while (c.phase != phase && timeout.elapsedMilliseconds < 8000) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (c.phase != phase) {
        throw StateError('Expected $phase, found ${c.phase}: ${c.message}');
      }
    }

    await waitFor(Phase.rest);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (c.durationMs != 120000 ||
        c.completedCycle != 4 ||
        c.playing ||
        c.message.contains('暂时')) {
      throw StateError('Automatic long rest or focus cue failed: ${c.message}');
    }
    // Shorten only the isolated probe's break, without altering production settings.
    await c.perform(() async {
      c.engine.startRest(1, c.clock.elapsedMilliseconds);
    });
    await waitFor(Phase.ended);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (c.active ||
        c.sessions.length != 1 ||
        !c.sessions.single.completed ||
        c.message.contains('暂时')) {
      throw StateError('Rest cue or manual-focus waiting failed: ${c.message}');
    }
    File('${folder.path}/result.json').writeAsStringSync(jsonEncode({
      'ok': true,
      'nativePinEnabledDisabled': true,
      'completionBellDispatched': true,
      'subtaskCompletionBellDispatched': true,
      'taskNameVisibleAfterScroll': true,
      'editedSubtaskPersisted': true,
      'completedTaskLast': true,
      'taskDeletionPersisted': true,
      'automaticLongRest': true,
      'restEndsAndWaitsForManualFocus': true,
      'timerCuesDispatched': true,
      'onlyFocusRecorded': c.sessions.length == 1,
    }));
    // The host validates window styles and exits via the real tray command.
  } catch (e, stack) {
    File('${folder.path}/result.json').writeAsStringSync(
        jsonEncode({'ok': false, 'error': '$e', 'stack': '$stack'}));
    exit(1);
  }
}
