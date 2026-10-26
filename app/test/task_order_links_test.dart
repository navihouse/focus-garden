import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/data/backup.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/domain/note_link.dart';
import 'package:focus_garden/main.dart';
import 'package:focus_garden/notes_controller.dart';
import 'package:focus_garden/notes_editor.dart';
import 'package:focus_garden/task_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'adjacent links and emoji keep independent aliases through insert, delete and undo',
      () {
    final c = NotesController('📚 ', []);
    addTearDown(c.dispose);
    c.selection = TextSelection.collapsed(offset: c.text.length);
    c.insertLink(r'D:\Study\first.pdf', 'First');
    c.insertLink(r'D:\Study\second.pdf', 'Second');
    expect(c.links.map((l) => l.start), [3, 8]);
    c.renameLink(c.links.first, '第一份');
    expect(c.text, '📚 第一份Second');
    expect(c.links.last.start, 6);
    final before = c.value;
    c.value = const TextEditingValue(text: '📚 Second');
    expect(c.links.single.target, r'D:\Study\second.pdf');
    c.value = before;
    expect(c.links.map((l) => l.target),
        [r'D:\Study\first.pdf', r'D:\Study\second.pdf']);
  });
  test(
      'reordering one list cannot change session associations or completed timestamps',
      () async {
    final c = AppController()
      ..store = LocalStore.testing(NativeDatabase.memory());
    addTearDown(c.store.close);
    addTearDown(c.dispose);
    final a = DateTime.utc(2026);
    await c.store.task(TaskItem(id: 'a', name: 'A', modified: a));
    await c.store.task(TaskItem(id: 'b', name: 'B', modified: a));
    final s = FocusSession(
        id: 'session',
        device: 'test',
        taskId: 'a',
        taskName: 'A',
        plannedSeconds: 60,
        started: a,
        ended: a.add(const Duration(minutes: 1)),
        spans: [TimeSpan(a, a.add(const Duration(minutes: 1)))],
        completed: true,
        reason: 'completed');
    await c.store.session(s);
    await c.refresh();
    c.selectedTask = 'a';
    await c.reorderTask('a', 1);
    expect(c.selectedTask, 'a');
    expect(c.sessions.single.toJson(), s.toJson());
    await c.saveTask(
        TaskItem.fromJson({...c.tasks.last.toJson(), 'notes': 'edited'}));
    expect(c.tasks.map((t) => t.id), ['b', 'a']);
  });
  test(
      'manual order persists across refresh, edits, completion and backup merge',
      () async {
    final c = AppController()
      ..store = LocalStore.testing(NativeDatabase.memory());
    addTearDown(c.store.close);
    addTearDown(c.dispose);
    for (final id in ['a', 'b', 'c']) {
      await c.store
          .task(TaskItem(id: id, name: id, modified: DateTime.utc(2026)));
    }
    await c.store.task(TaskItem(
        id: 'done',
        name: 'Finished',
        status: 'done',
        modified: DateTime.utc(2026),
        completedAt: DateTime.utc(2025)));
    await c.refresh();
    await c.reorderTask('a', 2);
    expect(c.tasks.map((t) => t.id), ['b', 'c', 'a', 'done']);
    await c.saveTask(
        TaskItem.fromJson({...c.tasks[0].toJson(), 'name': 'Edited'}));
    await c.refresh();
    expect(c.tasks.map((t) => t.id), ['b', 'c', 'a', 'done']);
    final completedAt = c.tasks.last.completedAt;
    await c.reorderTask('done', 0);
    await c.reorderTask('missing', 0);
    expect(c.tasks.last.completedAt, completedAt);
    final db = LocalStore.testing(NativeDatabase.memory());
    addTearDown(db.close);
    await importBackup(db, previewBackup(exportBackup(c.tasks, []), [], []));
    final other = AppController()..store = db;
    addTearDown(other.dispose);
    await other.refresh();
    expect(other.tasks.map((t) => t.id), ['b', 'c', 'a', 'done']);
    await other.saveTask(
        TaskItem(id: 'new', name: 'New', modified: DateTime.utc(2026)));
    expect(other.tasks.first.id, 'new');
  });
  test(
      'path detection supports spaces, Chinese, quotes and file URIs; no web or commands',
      () {
    const text =
        '阅读\n"D:\\Study\\物理 & 练习 (1).pdf"\nfile:///D:/Study/a%20b.txt\n/storage/emulated/0/a.pdf';
    final links = detectedFileLinks(text, []);
    expect(links.length, 3);
    expect(links.first.target, r'D:\Study\物理 & 练习 (1).pdf');
    expect(links[1].target, r'D:\Study\a b.txt');
    expect(
        text.substring(links.first.start, links.first.end), links.first.target);
    for (final value in [
      'https://example.com/a',
      'cmd /c start a',
      r'\\server\file',
      'relative.pdf',
      'D:\\a\n.txt'
    ]) {
      expect(localFilePath(value), isNull);
    }
  });
  test(
      'renaming and editing around links never change their targets; undo restores ranges',
      () {
    final c = NotesController('阅读\nD:\\Study\\试卷.pdf', []);
    addTearDown(c.dispose);
    final original = c.text;
    final target = c.links.single.target;
    c.renameLink(c.links.single, '物理试卷');
    expect(c.text, '阅读\n物理试卷');
    expect(c.links.single.target, target);
    c.value = TextEditingValue(
        text: '今天${c.text}',
        selection: const TextSelection.collapsed(offset: 2));
    expect(c.links.single.start, 5);
    expect(c.links.single.target, target);
    final aliasText = c.text;
    c.value = const TextEditingValue(text: '清空');
    expect(c.links, isEmpty);
    c.value = TextEditingValue(text: aliasText);
    expect(c.links.single.target, target);
    c.value = TextEditingValue(text: original);
    expect(c.links.single.start, 3);
    c.renameLink(c.links.single, 'same');
    c.selection = TextSelection.collapsed(offset: c.text.length);
    c.insertLink(r'D:\Study\other.pdf', 'same');
    expect(c.links.map((l) => l.target), [target, r'D:\Study\other.pdf']);
    c.renameLink(c.links.first, 'first');
    expect(c.links.last.target, r'D:\Study\other.pdf');
    expect(c.text.substring(c.links.last.start, c.links.last.end), 'same');
  });
  test(
      'backup v4 preserves aliases, target paths and order; invalid ranges reject before writes',
      () {
    final t = TaskItem(
        id: 'a',
        name: 'A',
        notes: '物理试卷',
        noteLinks: const [NoteFileLink(0, 4, r'D:\Study\paper.pdf')],
        sortOrder: 2,
        modified: DateTime.utc(2026));
    final json = jsonDecode(exportBackup([t], [])) as Map;
    expect(json['version'], 4);
    final restored = previewBackup(jsonEncode(json), [], []).tasks.single;
    expect(restored.sameAs(t), true);
    for (final links in [
      [const NoteFileLink(-1, 3, r'D:\a.txt')],
      [const NoteFileLink(0, 9, r'D:\a.txt')],
      [const NoteFileLink(0, 3, 'https://example.com')],
      [
        const NoteFileLink(0, 3, r'D:\a.txt'),
        const NoteFileLink(2, 4, r'D:\b.txt')
      ],
    ]) {
      expect(
          () => TaskItem.fromJson({
                ...t.toJson(),
                'noteLinks': links.map((l) => l.toJson()).toList()
              }),
          throwsFormatException);
    }
    for (final version in [1, 2, 3]) {
      final legacy = t.toJson()
        ..remove('sortOrder')
        ..remove('noteLinks');
      json['version'] = version;
      json['tasks'] = [legacy];
      expect(previewBackup(jsonEncode(json), [], []).tasks.single.noteLinks,
          isEmpty);
    }
  });
  testWidgets(
      'dragging task dots reorders on both pages and click still opens menu',
      (tester) async {
    tester.view.physicalSize = const Size(1180, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController()
      ..store = LocalStore.testing(NativeDatabase.memory());
    addTearDown(c.store.close);
    addTearDown(c.dispose);
    for (final id in ['a', 'b', 'c']) {
      await c.store.task(
          TaskItem(id: id, name: 'Task $id', modified: DateTime.utc(2026)));
    }
    await c.refresh();
    await tester.pumpWidget(MaterialApp(
        home:
            ListenableBuilder(listenable: c, builder: (_, child) => Home(c))));
    await tester.tap(find.text('任务').last);
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('task-drag-a')),
        last = find.byKey(const ValueKey('task-drag-c'));
    final gesture = await tester.startGesture(tester.getCenter(first),
        kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(0, 12));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(tester.getBottomRight(last) + const Offset(0, 140));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.moveBy(const Offset(0, 10));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(c.tasks.map((t) => t.id), ['b', 'c', 'a']);
    await tester.tap(find.text('专注').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('task-card-b')));
    await tester.pumpAndSettle();
    final list = tester.widget<SliverReorderableList>(
        find.byKey(const ValueKey('focus-task-list')));
    list.onReorderItem!(2, 0);
    await tester.pumpAndSettle();
    expect(c.tasks.map((t) => t.id), ['a', 'b', 'c']);
    await tester.tap(find.text('任务').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-menu-a')));
    await tester.pumpAndSettle();
    expect(find.text('删除任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<Offset> linkPoint(WidgetTester tester) async {
    final field = find.byKey(const ValueKey('task-notes'));
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    final editable = tester.state<EditableTextState>(
        find.descendant(of: field, matching: find.byType(EditableText)));
    final box = editable.renderEditable
        .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 1))
        .first
        .toRect();
    return editable.renderEditable.localToGlobal(box.center);
  }

  for (final brightness in Brightness.values) {
    testWidgets(
        'Ctrl click and right-click rename use original target in $brightness',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = NotesController(
          'Physics', const [NoteFileLink(0, 7, r'D:\Study\物理 (1).pdf')]);
      addTearDown(c.dispose);
      final opened = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppController.native, (call) async {
        if (call.method == 'openLocalFile') {
          opened.add((call.arguments as Map)['path'] as String);
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppController.native, null));
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
              body: Center(
                  child: SizedBox(
                      width: 520, child: NotesEditor(controller: c))))));
      await tester.pumpAndSettle();
      await tester.tapAt(await linkPoint(tester));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tapAt(await linkPoint(tester));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(opened, [r'D:\Study\物理 (1).pdf']);
      await tester.tapAt(await linkPoint(tester),
          buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.text('修改链接显示名称'), findsOneWidget);
      await tester.tap(find.text('修改链接显示名称'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('link-name')), 'Review');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(c.text, 'Review');
      expect(c.links.single.target, opened.single);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tapAt(await linkPoint(tester));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(opened.length, 2);
      expect(opened[0], opened[1]);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('missing file shows an error without changing note or target',
      (tester) async {
    final c = NotesController(
        'Missing', const [NoteFileLink(0, 7, r'D:\Study\missing.pdf')]);
    addTearDown(c.dispose);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, (_) async {
      throw PlatformException(code: 'FILE_UNAVAILABLE');
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, null));
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: NotesEditor(controller: c))));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(await linkPoint(tester));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note-link-error')), findsOneWidget);
    expect(c.text, 'Missing');
    expect(c.links.single.target, r'D:\Study\missing.pdf');
  });
  testWidgets('insert and save aliases survive reopening task editor',
      (tester) async {
    TaskItem? saved;
    final original = TaskItem(id: 'a', name: 'A', modified: DateTime.utc(2026));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (ctx) => TextButton(
                    onPressed: () async {
                      saved = await showDialog<TaskItem>(
                          context: ctx,
                          builder: (_) => TaskEditor(task: original));
                    },
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final add = find.byKey(const ValueKey('add-note-link'));
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('link-path')), r'D:\Study\paper.pdf');
    await tester.enterText(
        find.byKey(const ValueKey('link-label')), 'Practice');
    await tester.tap(find.text('插入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved!.notes, 'Practice');
    expect(saved!.noteLinks.single.target, r'D:\Study\paper.pdf');
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: TaskEditor(task: saved))));
    await tester.pumpAndSettle();
    final field =
        tester.widget<TextFormField>(find.byKey(const ValueKey('task-notes')));
    expect(field.controller!.text, 'Practice');
    expect((field.controller as NotesController).links.single.target,
        r'D:\Study\paper.pdf');
  });
}
