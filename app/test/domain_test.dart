import 'dart:convert';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/domain/timer_engine.dart';
import 'package:focus_garden/domain/reports.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/data/backup.dart';

FocusSession session(String id, String start, int seconds,
    {bool completed = true, String device = 'test'}) {
  final a = DateTime.parse(start).toUtc(),
      b = DateTime.parse(start).toUtc().add(Duration(seconds: seconds));
  return FocusSession(
      id: id,
      device: device,
      started: a,
      ended: b,
      plannedSeconds: completed ? seconds : seconds + 60,
      spans: [TimeSpan(a, b)],
      completed: completed,
      reason: completed ? 'completed' : 'early');
}

TaskItem task(String name) =>
    TaskItem(id: 't1', name: name, modified: DateTime.utc(2026));

void main() {
  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  test('legacy task JSON loads without notes or subtasks', () {
    final legacy = task('old').toJson()
      ..remove('notes')
      ..remove('subtasks');
    final parsed = TaskItem.fromJson(legacy);
    expect(parsed.notes, '');
    expect(parsed.subtasks, isEmpty);
  });
  test(
      'task notes and ordered completion state survive JSON and status changes',
      () {
    final t = TaskItem(
        id: 'steps',
        name: '大学物理',
        modified: DateTime.utc(2026),
        notes: '先复习概念\n再整理错题',
        subtasks: const [
          SubtaskItem(id: 'ppt', name: '复习PPT', completed: true),
          SubtaskItem(id: 'notes', name: '整理笔记'),
        ]);
    final parsed = TaskItem.fromJson({...t.toJson(), 'status': 'doing'});
    expect(parsed.notes, t.notes);
    expect(parsed.subtasks.map((s) => s.name), ['复习PPT', '整理笔记']);
    expect(parsed.subtasks.map((s) => s.completed), [true, false]);
    expect(parsed.status, 'doing');
    expect(parsed.sameAs(t), false);
  });
  test('malformed or duplicate subtasks and excessive notes are rejected', () {
    final original = task('invalid').toJson();
    expect(() => TaskItem.fromJson({...original, 'subtasks': 'bad'}),
        throwsFormatException);
    expect(() => TaskItem.fromJson({...original, 'notes': 'x' * 10001}),
        throwsFormatException);
    expect(
        () => TaskItem.fromJson({
              ...original,
              'subtasks': [
                {'id': 'same', 'name': 'one', 'completed': false},
                {'id': 'same', 'name': 'two', 'completed': true}
              ]
            }),
        throwsFormatException);
    expect(
        () =>
            SubtaskItem.fromJson({'id': 'x', 'name': ' ', 'completed': false}),
        throwsFormatException);
  });
  test(
      'v3 backups preserve task details while v1 and v2 remain importable',
      () async {
    final db = LocalStore.testing(NativeDatabase.memory());
    addTearDown(db.close);
    final rich = TaskItem(
        id: 'rich',
        name: '大学物理',
        notes: '周末前完成',
        subtasks: const [
          SubtaskItem(id: 'homework', name: '完成作业', completed: true)
        ],
        modified: DateTime.utc(2026));
    final payload = exportBackup([rich], []);
    expect(jsonDecode(payload)['version'], 3);
    await importBackup(db, previewBackup(payload, [], []));
    final reopened = (await db.tasks()).single;
    expect(reopened.notes, rich.notes);
    expect(reopened.subtasks.single.completed, true);
    final version2 = asJson(jsonDecode(payload))..['version'] = 2;
    (version2['tasks'] as List).single.remove('completedAt');
    expect(previewBackup(jsonEncode(version2), [], []).tasks.single.notes, rich.notes);
    final legacy = asJson(jsonDecode(exportBackup([task('legacy')], [])));
    legacy['version'] = 1;
    (legacy['tasks'] as List).single
      ..remove('notes')
      ..remove('subtasks');
    final preview = previewBackup(jsonEncode(legacy), [], []);
    expect(preview.tasks.single.notes, '');
    expect(preview.tasks.single.subtasks, isEmpty);
    final conflicting = previewBackup(
        exportBackup([
          TaskItem.fromJson({...rich.toJson(), 'notes': '导入备注'})
        ], []),
        [rich],
        []);
    expect(conflicting.conflicts.single.id, 'rich');
    await importBackup(db, conflicting);
    expect((await db.tasks()).single.notes, '周末前完成');
    await importBackup(db, conflicting, useImportedTaskIds: {'rich'});
    expect((await db.tasks()).single.notes, '导入备注');
  });
  test('task due dates preserve the same civil day after roundtrip', () {
    final t = TaskItem(
        id: 'due',
        name: 'deadline',
        due: DateTime(2026, 10, 19),
        modified: DateTime.utc(2026));
    final parsed = TaskItem.fromJson(t.toJson());
    expect(parsed.due!.day, 19);
    expect(t.toJson()['due'], '2026-10-19');
  });
  test('clock change while paused cannot put pause beyond session end', () {
    final t = TimerEngine();
    final now = DateTime.utc(2026);
    t.start(id: 'pause-clock', device: 'test', seconds: 60, now: now, tick: 0);
    t.pause(now.add(const Duration(hours: 1)), 10000);
    final saved = t.snapshot(now.subtract(const Duration(hours: 1)), 10000)!;
    expect(FocusSession.fromJson(saved.toJson()).milliseconds, 10000);
  });
  test(
      '25-minute focus caps elapsed; pauses do not count; clock changes do not inflate time',
      () {
    final timer = TimerEngine();
    final start = DateTime.utc(2026, 10, 19);
    timer.start(id: 'a', device: 'test', seconds: 1500, now: start, tick: 100);
    timer.pause(start.add(const Duration(minutes: 10)), 600100);
    expect(timer.elapsed(999999), 600000);
    timer.resume(start.add(const Duration(minutes: 12)), 720100);
    final done = timer.finish(start.add(const Duration(hours: 2)), 1620100,
        reason: 'completed')!;
    expect(done.milliseconds, 1500000);
    expect(done.pauses.single.milliseconds, 120000);
    expect(FocusSession.fromJson(done.toJson()).completed, true);
  });
  test(
      'partial snapshot only keeps confirmed elapsed and snapshots are immutable',
      () {
    final t = TimerEngine();
    final now = DateTime.utc(2026);
    t.start(id: 'b', device: 'test', seconds: 1500, now: now, tick: 0);
    final checkpoint = t.snapshot(now.add(const Duration(seconds: 15)), 15000)!;
    t.finish(now.add(const Duration(hours: 1)), 20000);
    expect(checkpoint.milliseconds, 15000);
    expect(checkpoint.completed, false);
  });
  test('rest pause/resume creates no focus session', () {
    final t = TimerEngine();
    final now = DateTime.utc(2026);
    t.startRest(300, 0);
    t.pause(now, 60000);
    expect(t.remaining(90000), 240000);
    t.resume(now, 90000);
    expect(t.remaining(150000), 180000);
    expect(t.finish(now, 150000), isNull);
  });
  test(
      'backwards wall-clock change cannot create inverted focus or pause spans',
      () {
    final t = TimerEngine();
    final now = DateTime.utc(2026);
    t.start(id: 'clock', device: 'test', seconds: 60, now: now, tick: 0);
    t.pause(now.subtract(const Duration(hours: 1)), 10000);
    t.resume(now.subtract(const Duration(hours: 2)), 15000);
    final result = t.finish(now.subtract(const Duration(hours: 3)), 20000)!;
    expect(FocusSession.fromJson(result.toJson()).milliseconds, 15000);
  });
  test('Beijing midnight splits time while completion belongs to end date', () {
    final s = session('midnight', '2026-12-31T15:50:00Z', 1200);
    final a =
        buildReport([s], ReportPeriod(PeriodKind.year, DateTime.utc(2026)));
    final b =
        buildReport([s], ReportPeriod(PeriodKind.year, DateTime.utc(2027)));
    expect(a.milliseconds, 600000);
    expect(b.milliseconds, 600000);
    expect(a.completed, 0);
    expect(b.completed, 1);
    expect(a.averageMinutes, 10);
    expect(b.averageMinutes, 10);
  });
  test('week begins Monday across year; leap day and empty baselines work', () {
    final period = ReportPeriod(PeriodKind.week, DateTime.utc(2027, 1, 1));
    expect(period.start, DateTime.utc(2026, 12, 28));
    final r = buildReport([session('leap', '2024-02-29T01:00:00Z', 1500)],
        ReportPeriod(PeriodKind.month, DateTime.utc(2024, 2)));
    expect(r.daily['2024-02-29'], 1500000);
    expect(r.activeDays, 1);
    final empty = buildReport([], period);
    expect(empty.averageMinutes, null);
    expect(empty.completionRate, null);
  });
  test('different planned durations, exclusions and rule thresholds', () {
    final rows = List.generate(
        5,
        (i) => session('$i', '2026-10-19T0$i:00:00Z', i.isEven ? 600 : 1500,
            completed: i >= 2));
    final period = ReportPeriod(PeriodKind.week, DateTime.utc(2026, 10, 19));
    final r = buildReport(rows, period);
    expect(r.completed, 3);
    expect(r.interrupted, 2);
    expect(r.completionRate, .6);
    expect(r.advice.any((s) => s.contains('40%')), true);
    expect(
        buildReport([rows.first.withExcluded(true)], period).milliseconds, 0);
    expect(
        buildReport(rows.take(4), period).advice.single.contains('至少 5'), true);
  });
  test(
      'backup previews duplicates, task conflict and overlapping fresh sessions',
      () {
    final a = session('one', '2026-10-19T00:00:00Z', 1500);
    final b = session('two', '2026-10-19T00:10:00Z', 1500);
    final preview = previewBackup(
        exportBackup([task('remote')], [a, b]), [task('local')], [a]);
    expect(preview.duplicateRecords, 1);
    expect(preview.conflicts.length, 1);
    expect(preview.overlapsExisting, contains('two'));
  });
  test(
      'corrupt backup and inconsistent completed records are rejected before mutation',
      () {
    final s = session('bad', '2026-10-19T00:00:00Z', 1500);
    final bad = s.toJson()..['plannedSeconds'] = 100;
    expect(() => FocusSession.fromJson(bad), throwsFormatException);
    expect(() => previewBackup('{', [], []), throwsFormatException);
    final payload = jsonDecode(exportBackup([], [s])) as Map;
    payload['version'] = 99;
    expect(() => previewBackup(jsonEncode(payload), [], []),
        throwsFormatException);
  });
  test(
      'SQLite recovery, repeat imports, bidirectional merging and transaction rollback',
      () async {
    final db = LocalStore.testing(NativeDatabase.memory());
    addTearDown(db.close);
    final a = session('a', '2026-10-19T00:00:00Z', 1500);
    final b = session('b', '2026-10-20T00:00:00Z', 1500);
    await db.task(task('local'));
    await db.session(a);
    final backup = exportBackup([task('remote')], [a, b]);
    for (int i = 0; i < 2; i++) {
      await importBackup(
          db, previewBackup(backup, await db.tasks(), await db.sessions()));
    }
    expect((await db.sessions()).length, 2);
    expect((await db.tasks()).single.name, 'local');
    await importBackup(
        db, previewBackup(backup, await db.tasks(), await db.sessions()),
        useImportedTaskIds: {'t1'});
    expect((await db.tasks()).single.name, 'remote');
    await expectLater(db.transaction(() async {
      await db.task(task('rollback'));
      throw StateError('disk failure simulation');
    }), throwsStateError);
    expect((await db.tasks()).single.name, 'remote');
    await db.commitCheckpoint(a);
    final recovered = FocusSession.fromJson(asJson(await db.get('checkpoint')));
    await db.commitSession(recovered);
    expect(await db.get('checkpoint'), null);
    expect((await db.sessions()).length, 2);
    final other = LocalStore.testing(NativeDatabase.memory());
    addTearDown(other.close);
    await other.session(b);
    await importBackup(
        other,
        previewBackup(exportBackup(await db.tasks(), await db.sessions()),
            await other.tasks(), await other.sessions()));
    expect((await other.sessions()).map((s) => s.id).toSet(), {'a', 'b'});
  });
}
