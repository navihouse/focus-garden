import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/automation_controller.dart';
import 'package:focus_garden/data/backup.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/domain/automation.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/domain/reports.dart';
import 'package:focus_garden/study_scraper.dart';

class FixtureScraper extends StudyScraperRunner {
  int calls = 0;
  bool fail = false;
  Completer<ScrapePayload>? pending;
  ScrapePayload value = ScrapePayload(DateTime.utc(2026), [], []);
  @override
  Future<ScrapePayload> run(
      AutomationSettings settings, Directory output) async {
    calls++;
    if (pending != null) return pending!.future;
    if (fail) throw const FormatException('登录状态失效');
    return value;
  }

  @override
  void cancel() {
    if (pending != null && !pending!.isCompleted) {
      pending!.completeError(const FormatException('采集已取消'));
    }
  }
}

Json studyFixture(
        {String id = 'assignment-1',
        String title = '数学作业',
        String? due = '2026-11-14T00:30:38+08:00'}) =>
    {
      'id': id,
      'title': title,
      'platform': 'chaoxing',
      'kind': '作业',
      'course': '高等数学',
      'status': '待完成',
      'due_at': due,
      'url': 'https://mooc1.chaoxing.com/assignment',
    };

String scrapeFixture(List<Json> todos, {bool partial = false}) => jsonEncode({
      'generated_at': '2026-11-13T07:30:00+08:00',
      'timezone': 'Asia/Shanghai',
      'sources': [
        {'platform': 'chaoxing', 'ok': true, 'warnings': []},
        if (partial)
          {
            'platform': 'icourse163',
            'ok': false,
            'warnings': ['网络失败']
          },
      ],
      'todos': todos,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late Directory directory;
  late AutomationController service;
  late FixtureScraper runner;
  late DateTime clock;
  var rows = <TaskItem>[];

  AutomationController makeService({bool supportsScraper = true}) =>
      AutomationController(
          store: store,
          directory: directory,
          tasks: () => rows,
          serialize: (action) => action(),
          refreshTasks: () async {
            rows = await store.tasks();
          },
          runner: runner,
          supportsScraper: supportsScraper,
          now: () => clock);

  setUp(() async {
    store = LocalStore.testing(NativeDatabase.memory());
    directory = await Directory.systemTemp.createTemp('focus-auto-test-');
    runner = FixtureScraper();
    clock = DateTime.utc(2026, 11, 13, 0);
    rows = [];
    service = makeService();
    await service.initialize();
  });
  tearDown(() async {
    await service.shutdown();
    service.dispose();
    await store.close();
    await directory.delete(recursive: true);
  });

  test(
      'morning snapshot uses Beijing year boundary and agreed overdue definition',
      () {
    final now = DateTime.utc(2026, 12, 31, 23, 59);
    final today = DateTime.utc(2027, 1, 1),
        yesterday = DateTime.utc(2026, 12, 31);
    TaskItem task(String id,
            {DateTime? due,
            DateTime? dueAt,
            String status = 'todo',
            DateTime? completedAt}) =>
        TaskItem(
            id: id,
            name: id,
            due: due,
            dueAt: dueAt,
            status: status,
            completedAt: completedAt,
            modified: DateTime.utc(2026));
    final report = buildMorningMessage([
      task('today', due: today),
      task('exact', due: today, dueAt: DateTime.utc(2026, 12, 31, 16, 30)),
      task('overdue', due: yesterday),
      task('older', due: DateTime.utc(2026, 12, 30)),
      task('done-yesterday',
          status: 'done', completedAt: DateTime.utc(2026, 12, 31, 15, 59)),
      task('done-today',
          due: yesterday,
          status: 'done',
          completedAt: DateTime.utc(2026, 12, 31, 16)),
      task('no-date'),
    ], now);
    expect(report.day, '2027-01-01');
    expect(report.dueToday.map((row) => row['id']), ['exact', 'today']);
    expect(
        report.completedYesterday.map((row) => row['id']), ['done-yesterday']);
    expect(report.unfinishedYesterday.map((row) => row['id']), ['overdue']);
    expect(report.unread, true);
  });

  test('leap day and daily schedule boundaries use fixed UTC+08', () {
    expect(dayKey(beijing(DateTime.utc(2028, 2, 28, 16))), '2028-02-29');
    expect(hasReachedTime(DateTime.utc(2026, 11, 12, 23, 59), 480), false);
    expect(hasReachedTime(DateTime.utc(2026, 11, 13), 480), true);
    expect(nextAutomationRun(clock, 480, finishedDay: '2026-11-13'),
        DateTime.utc(2026, 11, 14));
    expect(() => AutomationSettings.fromJson({'morningMinute': 1440}),
        throwsFormatException);
    expect(
        () => AutomationSettings.fromJson(
            {'scraperEnabled': true, 'chaoxing': false, 'mooc': false}),
        throwsFormatException);
  });

  test('missed morning is generated once; unread status survives reopening',
      () async {
    service.settings = const AutomationSettings(morningEnabled: true);
    clock = DateTime.utc(2026, 11, 13, 9);
    await service.checkSchedule();
    await service.checkSchedule();
    expect(service.messages.length, 1);
    expect(service.hasUnread, true);
    await service.markRead('2026-11-13');
    expect(service.hasUnread, false);
    await store.put('automation.settings', service.settings.toJson());
    await service.shutdown();
    service.dispose();
    service = makeService();
    await service.initialize();
    await service.checkSchedule();
    expect(service.messages.length, 1);
    expect(service.hasUnread, false);
    clock = DateTime.utc(2026, 11, 15, 1);
    await service.checkSchedule();
    expect(service.messages.map((message) => message.day),
        ['2026-11-15', '2026-11-13']);
  });

  test('disabled and future schedules do not send a morning message', () async {
    await service.checkSchedule();
    expect(service.messages, isEmpty);
    service.settings = const AutomationSettings(morningEnabled: true);
    clock = DateTime.utc(2026, 11, 12, 23);
    await service.checkSchedule();
    expect(service.messages, isEmpty);
    clock = DateTime.utc(2026, 11, 13);
    await service.checkSchedule();
    expect(service.messages.single.day, '2026-11-13');
  });

  test(
      'scraper JSON preserves exact deadline and rejects corrupt dates or duplicates',
      () {
    final payload = ScrapePayload.parse(scrapeFixture([studyFixture()]));
    final item = payload.assignments.single;
    expect(item.dueAt, DateTime.utc(2026, 11, 13, 16, 30, 38));
    expect(item.due, DateTime.utc(2026, 11, 14));
    expect(item.createTask(clock).dueAt, item.dueAt);
    for (final invalid in [
      '2026-02-30T12:00:00+08:00',
      '2026-11-14T25:00:00+08:00',
      '2026-11-14T12:00:00'
    ]) {
      expect(
          () =>
              ScrapePayload.parse(scrapeFixture([studyFixture(due: invalid)])),
          throwsFormatException);
    }
    expect(
        () => ScrapePayload.parse(
            scrapeFixture([studyFixture(), studyFixture()])),
        throwsFormatException);
  });

  test(
      'partial source failures preserve successful assignments; submitted work is skipped',
      () {
    final payload = ScrapePayload.parse(scrapeFixture([
      studyFixture(),
      {...studyFixture(id: 'submitted'), 'status': '已提交'},
      {...studyFixture(id: 'failed'), 'platform': 'icourse163'},
    ], partial: true));
    expect(payload.assignments.length, 1);
    expect(payload.incompletePlatforms, ['中国大学MOOC']);
  });

  test(
      'repeated imports deduplicate; manual edits and completed tasks remain intact',
      () async {
    final original = ScrapePayload.parse(scrapeFixture([studyFixture()]));
    final first = await service.importPayload(original);
    expect(first.added, 1);
    final id = rows.single.id;
    expect((await service.importPayload(original)).added, 0);
    final changed = ScrapePayload.parse(scrapeFixture(
        [studyFixture(title: '数学作业更新', due: '2026-11-15T12:20:00+08:00')]));
    await service.importPayload(changed);
    expect(rows.single.name, '数学作业更新');
    expect(rows.single.dueAt, DateTime.utc(2026, 11, 15, 4, 20));
    await store.task(TaskItem.fromJson({
      ...rows.single.toJson(),
      'name': '我自己改的名称',
      'notes': '手写备注',
      'noteLinks': [],
      'subtasks': [const SubtaskItem(id: 'step', name: '先复习').toJson()],
    }));
    await service.importPayload(original);
    expect(rows.single.name, '我自己改的名称');
    expect(rows.single.notes, '手写备注');
    expect(rows.single.subtasks.single.name, '先复习');
    final done = TaskItem.fromJson({
      ...rows.single.toJson(),
      'status': 'done',
      'completedAt': DateTime.utc(2026, 11, 13).toIso8601String(),
    });
    await store.task(done);
    await service.importPayload(changed);
    expect(rows.single.toJson(), done.toJson());
    await store.deleteTask(id);
    await service.importPayload(original);
    expect(rows, isEmpty, reason: '用户删除的自动任务不应反复出现');
  });

  test('deadline overrides and chosen groups survive automatic refresh',
      () async {
    await store.saveGroups(const [TaskGroup(id: 'group', name: '课程')]);
    final payload = ScrapePayload.parse(scrapeFixture([studyFixture()]));
    await service.importPayload(payload, groupId: 'group');
    final overridden = TaskItem.fromJson(
        {...rows.single.toJson(), 'due': '2026-12-01', 'dueAt': null});
    await store.task(overridden);
    await service.importPayload(ScrapePayload.parse(
        scrapeFixture([studyFixture(due: '2026-11-15T12:00:00+08:00')])));
    expect(rows.single.groupId, 'group');
    expect(rows.single.due, DateTime(2026, 12, 1));
    expect(rows.single.dueAt, isNull);
  });

  test('failed batch rolls back imported tasks and deduplication ledger',
      () async {
    final payload = ScrapePayload.parse(
        scrapeFixture([studyFixture(), studyFixture(id: 'second')]));
    final blocked = payload.assignments.last.taskId;
    await store.customStatement(
        "CREATE TRIGGER reject_assignment BEFORE INSERT ON tasks "
        "WHEN NEW.id = '$blocked' BEGIN SELECT RAISE(FAIL, 'simulated failure'); END");
    await expectLater(service.importPayload(payload), throwsA(anything));
    expect(await store.tasks(), isEmpty);
    expect(await store.get('automation.imports'), isNull);
  });

  test(
      'backup v7 round-trips precise deadlines; legacy versions remain compatible',
      () {
    final task = ScrapePayload.parse(scrapeFixture([studyFixture()]))
        .assignments
        .single
        .createTask(clock);
    final data = exportBackup([task], []);
    final decoded = asJson(jsonDecode(data));
    expect(decoded['version'], 7);
    expect(previewBackup(data, [], []).tasks.single.toJson(), task.toJson());
    expect(() => previewBackup(jsonEncode({...decoded, 'version': 6}), [], []),
        throwsFormatException);
    final plain = TaskItem(id: 'plain', name: '普通任务', modified: clock);
    expect(asJson(jsonDecode(exportBackup([plain], [])))['version'], 4);
  });

  test(
      'scheduled runs do not overlap and retry only on request after a failure',
      () async {
    service.settings = const AutomationSettings(scraperEnabled: true);
    runner.pending = Completer<ScrapePayload>();
    await service.checkSchedule();
    expect(service.scraping, true);
    await service.checkSchedule();
    await service.runScraper();
    expect(runner.calls, 1);
    final running = service.runScraper();
    runner.pending!.complete(runner.value);
    await running;
    for (var i = 0; i < 100 && service.scraping; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(service.scraping, false);
    await service.checkSchedule();
    expect(runner.calls, 1);
    runner.pending = null;
    runner.fail = true;
    clock = DateTime.utc(2026, 11, 14);
    await service.runScraper(scheduled: true);
    await service.checkSchedule();
    expect(runner.calls, 2);
    expect(service.error, contains('登录状态失效'));
    runner.fail = false;
    await service.runScraper();
    expect(runner.calls, 3);
  });

  test('shutdown cancels an in-flight scrape and does not import its result',
      () async {
    runner.pending = Completer<ScrapePayload>();
    final running = service.runScraper();
    await service.shutdown();
    await running;
    expect(service.scraping, false);
    expect(await store.tasks(), isEmpty);
  });
  test('expiry settings migrate and validate custom integer days', () async {
    expect(AutomationSettings.fromJson({}).expiredAfterDays, 0);
    for (final days in [-1, 0, 7, 30, 3650]) {
      final value = AutomationSettings(expiredAfterDays: days);
      expect(
          AutomationSettings.fromJson(value.toJson()).expiredAfterDays, days);
    }
    for (final bad in [-2, 3651, 1.5, '7', null]) {
      expect(() => AutomationSettings.fromJson({'expiredAfterDays': bad}),
          throwsFormatException);
    }
    await service.saveSettings(const AutomationSettings(expiredAfterDays: 14));
    expect(
        asJson(await store.get('automation.settings'))['expiredAfterDays'], 14);
  });

  test('expiry uses rolling days, exact boundaries and unknown deadlines', () {
    final now = DateTime.utc(2028, 3, 1);
    expect(shouldIgnoreExpired(now, now, 0), true);
    expect(shouldIgnoreExpired(now.add(const Duration(seconds: 1)), now, 0),
        false);
    expect(shouldIgnoreExpired(now.subtract(const Duration(days: 7)), now, 7),
        false);
    expect(
        shouldIgnoreExpired(
            now.subtract(const Duration(days: 7, seconds: 1)), now, 7),
        true);
    expect(shouldIgnoreExpired(DateTime.utc(2028, 1, 30), now, 30), true);
    expect(shouldIgnoreExpired(DateTime.utc(2028, 1, 31), now, 30), false);
    expect(shouldIgnoreExpired(DateTime.utc(2027), now, -1), false);
    expect(shouldIgnoreExpired(null, now, 7, markedExpired: true), false);
    expect(shouldIgnoreExpired(null, now, 0), false);
    expect(shouldIgnoreExpired(null, now, 0, markedExpired: true), true);
  });

  test('ignored tasks are not tombstoned and relaxation can import them later',
      () async {
    clock = DateTime.utc(2026, 11, 14);
    final payload = ScrapePayload.parse(scrapeFixture([
      studyFixture(id: 'recent', due: '2026-11-10T08:00:00+08:00'),
      studyFixture(id: 'week', due: '2026-11-07T08:00:00+08:00'),
      studyFixture(id: 'old', due: '2026-11-07T07:59:59+08:00'),
      studyFixture(id: 'unknown', due: null),
    ]));
    var result = await service.importPayload(payload);
    expect(result.added, 1);
    expect(result.ignored, 3);
    service.settings = const AutomationSettings(expiredAfterDays: 7);
    result = await service.importPayload(payload);
    expect(result.added, 2);
    expect(result.ignored, 1);
    expect(rows.length, 3);
    service.settings = const AutomationSettings(expiredAfterDays: -1);
    result = await service.importPayload(payload);
    expect(result.added, 1);
    expect(rows.length, 4);
    service.settings = const AutomationSettings(expiredAfterDays: 0);
    await service.importPayload(payload);
    expect(rows.length, 4, reason: '收紧规则不得删除已有任务');
  });

  test(
      'script and importer ignored counts combine; completed records stay excluded',
      () async {
    final data = asJson(jsonDecode(scrapeFixture([
      {...studyFixture(id: 'done'), 'status': '待批阅'},
      {
        ...studyFixture(id: 'scored'),
        'extra': {'completed': true}
      },
      {
        ...studyFixture(id: 'expired', due: '2026-11-01T12:00:00+08:00'),
        'status': '已结束'
      },
    ])));
    data['ignored_expired'] = 6;
    final payload = ScrapePayload.parse(jsonEncode(data));
    expect(payload.assignments.length, 1);
    final result = await service.importPayload(payload);
    expect(result.ignored, 7);
    expect(rows, isEmpty);
    expect(
        () => ScrapePayload.parse(jsonEncode({...data, 'ignored_expired': -1})),
        throwsFormatException);
  });
}
