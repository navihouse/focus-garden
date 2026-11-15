import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/automation_controller.dart';
import 'package:focus_garden/data/backup.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/domain/automation.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/study_scraper.dart';
import 'automation_test.dart' show FixtureScraper, scrapeFixture, studyFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppController c;
  late AutomationController service;
  late Directory directory;
  final now = DateTime.utc(2026, 11, 15);
  AutomationController makeService() => AutomationController(
      store: c.store,
      directory: directory,
      tasks: () => c.tasks,
      serialize: (action) => action(),
      refreshTasks: c.refresh,
      runner: FixtureScraper(),
      supportsScraper: true,
      initialSettings: const AutomationSettings(expiredAfterDays: -1),
      now: () => now);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('focus-import-order-');
    c = AppController()..store = LocalStore.testing(NativeDatabase.memory());
    service = makeService();
    await service.initialize();
  });
  tearDown(() async {
    await service.shutdown();
    service.dispose();
    c.dispose();
    await c.store.close();
    await directory.delete(recursive: true);
  });
  Json item(String name, String? due, {bool mooc = false}) => {
        ...studyFixture(id: name, title: name, due: due),
        if (mooc) 'platform': 'icourse163',
      };
  ScrapePayload payload(List<Json> items) => ScrapePayload.parse(jsonEncode({
        ...asJson(jsonDecode(scrapeFixture(items))),
        'sources': [
          {'platform': 'chaoxing', 'ok': true, 'warnings': []},
          {'platform': 'icourse163', 'ok': true, 'warnings': []},
        ],
      }));
  List<String> active({String? group}) => c.tasks
      .where((t) => t.status != 'done' && (group == null || t.groupId == group))
      .map((t) => t.name)
      .toList();
  Future<void> edit(String name, Json changes) async {
    final task = c.tasks.singleWhere((t) => t.name == name);
    await c.store.task(TaskItem.fromJson({...task.toJson(), ...changes}));
    await c.refresh();
  }

  test(
      'mixed platforms sort by exact deadline, unknown last, ties remain stable',
      () async {
    final items = [
      item('unknown', null),
      item('late', '2026-11-20T10:00:00+08:00', mooc: true),
      item('early', '2026-11-16T09:00:00+08:00'),
      item('overdue', '2026-11-14T09:00:00+08:00'),
      item('tie', '2026-11-16T09:00:00+08:00', mooc: true)
    ];
    await service.importPayload(payload(items));
    expect(active(), ['overdue', 'early', 'tie', 'late', 'unknown']);
    final before = c.tasks.map((t) => t.toJson()).toList();
    final repeated =
        await service.importPayload(payload(items.reversed.toList()));
    expect(repeated.added, 0);
    expect(c.tasks.map((t) => t.toJson()).toList(), before);
  });

  test(
      'incremental collection merges deadlines with earlier collected tasks and local overrides',
      () async {
    await service.importPayload(payload([
      item('unknown', null),
      item('middle', '2026-11-18T09:00:00+08:00'),
      item('late', '2026-11-20T09:00:00+08:00')
    ]));
    await service
        .importPayload(payload([item('urgent', '2026-11-16T09:00:00+08:00')]));
    expect(active(), ['urgent', 'middle', 'late', 'unknown']);
    await edit('middle', {
      'due': '2026-12-03',
      'dueAt': '2026-12-03T01:00:00Z',
      'notes': 'local note',
      'noteLinks': []
    });
    await service
        .importPayload(payload([item('middle', '2026-11-17T09:00:00+08:00')]));
    expect(active(), ['urgent', 'late', 'middle', 'unknown']);
    expect(c.tasks.singleWhere((t) => t.name == 'middle').notes, 'local note');
  });

  test('sorting keeps group order, manual slots and completed task data',
      () async {
    await c.store.saveGroups(const [
      TaskGroup(id: 'one', name: 'one'),
      TaskGroup(id: 'two', name: 'two')
    ]);
    await service.importPayload(
        payload([
          item('unknown', null),
          item('late', '2026-11-20T09:00:00+08:00'),
          item('soon', '2026-11-16T09:00:00+08:00')
        ]),
        groupId: 'one');
    await c.store.task(TaskItem(
        id: 'manual',
        name: 'manual',
        groupId: 'one',
        sortOrder: 1,
        modified: now));
    await c.refresh();
    await edit('unknown', {'sortOrder': 0});
    await edit('soon', {'sortOrder': 3});
    await edit(
        'late', {'status': 'done', 'completedAt': now.toIso8601String()});
    final completed = c.tasks.singleWhere((t) => t.name == 'late').toJson();
    await service.importPayload(
        payload([
          item('second-unknown', null),
          item('second-dated', '2026-11-19T09:00:00+08:00')
        ]),
        groupId: 'two');
    expect(active(group: 'one'), ['soon', 'manual', 'unknown']);
    expect(active(group: 'two'), ['second-dated', 'second-unknown']);
    expect(c.groups.map((g) => g.id), ['one', 'two']);
    expect(c.tasks.singleWhere((t) => t.id == 'manual').modified, now);
    expect(c.tasks.singleWhere((t) => t.name == 'late').toJson(), completed);
  });

  test(
      'old collected tasks reorder on reopening and retain order through backup',
      () async {
    await service.importPayload(payload([
      item('unknown', null),
      item('late', '2026-11-20T09:00:00+08:00'),
      item('soon', '2026-11-16T09:00:00+08:00')
    ]));
    await edit('unknown', {'sortOrder': 0});
    await edit('late', {'sortOrder': 1});
    await edit('soon', {'sortOrder': 2});
    expect(active(), ['unknown', 'late', 'soon']);
    await service.shutdown();
    service.dispose();
    service = makeService();
    await service.initialize();
    expect(active(), ['soon', 'late', 'unknown']);
    final restored = previewBackup(exportBackup(c.tasks, []), [], []).tasks
      ..sort(comparePendingTaskOrder);
    expect(restored.map((t) => t.name), active());
  });

  test('date-only deadlines use end of Beijing day instead of becoming undated',
      () async {
    final data = payload([
      item('all-day', '2026-11-16T09:00:00+08:00'),
      item('exact', '2026-11-16T23:00:00+08:00'),
      item('unknown', null)
    ]);
    await service.importPayload(data);
    await edit('all-day', {'dueAt': null});
    await service.importPayload(data);
    expect(active(), ['exact', 'all-day', 'unknown']);
    expect(c.tasks.singleWhere((t) => t.name == 'all-day').dueAt, isNull);
  });

  test(
      'failure while saving sorted positions rolls back tasks and source ledger',
      () async {
    await service.importPayload(payload([
      item('dated', '2026-11-20T09:00:00+08:00'),
      item('old-unknown', null)
    ]));
    final before = c.tasks.map((t) => t.toJson()).toList();
    final ledger = await c.store.get('automation.imports');
    final blocked = c.tasks.first.id;
    await c.store.customStatement(
        "CREATE TRIGGER reject_order BEFORE INSERT ON tasks "
        "WHEN NEW.id = '$blocked' AND json_extract(NEW.data, '\$.sortOrder') = 0 "
        "BEGIN SELECT RAISE(FAIL, 'simulated order failure'); END");
    await expectLater(
        service.importPayload(payload([item('new-unknown', null)])),
        throwsA(anything));
    await c.refresh();
    expect(c.tasks.map((t) => t.toJson()).toList(), before);
    expect(await c.store.get('automation.imports'), ledger);
  });
}
