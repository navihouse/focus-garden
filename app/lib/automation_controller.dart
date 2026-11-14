import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'data/store.dart';
import 'domain/automation.dart';
import 'domain/models.dart';
import 'domain/reports.dart';
import 'study_scraper.dart';

class AssignmentImportResult {
  final int added, updated, preserved, ignored;
  const AssignmentImportResult(this.added, this.updated, this.preserved,
      [this.ignored = 0]);
  String get label =>
      '新增 $added 个，更新 $updated 个，保留 $preserved 个，忽略过期 $ignored 个';
}

class AutomationController extends ChangeNotifier {
  final LocalStore store;
  final Directory directory;
  final List<TaskItem> Function() tasks;
  final Future<void> Function(Future<void> Function()) serialize;
  final Future<void> Function() refreshTasks;
  final StudyScraperRunner runner;
  final DateTime Function() now;
  final bool supportsScraper;
  AutomationSettings settings;
  List<MorningMessage> messages = [];
  Json scrapeStatus = {};
  String error = '';
  bool scraping = false, _checking = false, _closed = false;
  String? _attemptedDay;
  Timer? _timer;
  Future<void>? _activeRun;

  AutomationController(
      {required this.store,
      required this.directory,
      required this.tasks,
      required this.serialize,
      required this.refreshTasks,
      required this.runner,
      required this.supportsScraper,
      AutomationSettings initialSettings = const AutomationSettings(),
      DateTime Function()? now})
      : settings = initialSettings,
        now = now ?? DateTime.now;

  bool get hasUnread => messages.any((message) => message.unread);
  String? get lastScheduledDay => scrapeStatus['scheduledDay'] as String?;
  DateTime? get nextMorning => !settings.morningEnabled
      ? null
      : nextAutomationRun(now(), settings.morningMinute,
          finishedDay: messages.any((m) => m.day == dayKey(beijing(now())))
              ? dayKey(beijing(now()))
              : null);
  DateTime? get nextScrape => !settings.scraperEnabled || !supportsScraper
      ? null
      : nextAutomationRun(now(), settings.scraperMinute,
          finishedDay: lastScheduledDay);

  Future<void> initialize() async {
    try {
      final saved = await store.get('automation.settings');
      if (saved != null) settings = AutomationSettings.fromJson(asJson(saved));
      messages = _decodeMessages(await store.get('automation.inbox'));
      scrapeStatus = asJson(await store.get('automation.scrapeStatus') ?? {});
    } catch (_) {
      error = '自动化数据读取失败，请检查本机数据或重新保存设置。';
    }
    _notify();
  }

  List<MorningMessage> _decodeMessages(Object? raw) => ((raw as List?) ?? [])
      .map((j) => MorningMessage.fromJson(asJson(j)))
      .toList()
    ..sort((a, b) => b.day.compareTo(a.day));

  void start() {
    if (_closed) return;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(checkSchedule());
    });
    unawaited(checkSchedule());
  }

  Future<void> saveSettings(AutomationSettings value) async {
    final validated = AutomationSettings.fromJson(value.toJson());
    await serialize(() async {
      await store.put('automation.settings', validated.toJson());
      settings = validated;
    });
    error = '';
    _notify();
    unawaited(checkSchedule());
  }

  Future<void> checkSchedule() async {
    if (_closed || _checking) return;
    _checking = true;
    try {
      final current = now().toUtc();
      final today = dayKey(beijing(current));
      if (settings.morningEnabled &&
          hasReachedTime(current, settings.morningMinute) &&
          !messages.any((message) => message.day == today)) {
        await generateMorning();
      }
      final scraperNow = now().toUtc();
      final scraperDay = dayKey(beijing(scraperNow));
      if (!_closed &&
          supportsScraper &&
          settings.scraperEnabled &&
          !scraping &&
          _attemptedDay != scraperDay &&
          lastScheduledDay != scraperDay &&
          hasReachedTime(scraperNow, settings.scraperMinute)) {
        unawaited(runScraper(scheduled: true));
      }
    } catch (_) {
      error = '自动化执行未完成，数据已保留，可稍后重试。';
      _notify();
    } finally {
      _checking = false;
    }
  }

  Future<void> generateMorning() async {
    if (_closed) return;
    final current = now().toUtc();
    final today = dayKey(beijing(current));
    await serialize(() async {
      List<MorningMessage>? next;
      await store.transaction(() async {
        final saved = _decodeMessages(await store.get('automation.inbox'));
        if (!saved.any((message) => message.day == today)) {
          saved.insert(0, buildMorningMessage(tasks(), current));
          await store.put(
              'automation.inbox', saved.map((m) => m.toJson()).toList());
        }
        next = saved;
      });
      messages = next!;
    });
    _notify();
  }

  Future<void> markRead(String day) async {
    if (_closed) return;
    await serialize(() async {
      final saved = _decodeMessages(await store.get('automation.inbox'));
      final next = saved
          .map((m) => m.day == day && m.unread ? m.markRead(now().toUtc()) : m)
          .toList();
      await store.put('automation.inbox', next.map((m) => m.toJson()).toList());
      messages = next;
    });
    _notify();
  }

  Future<AssignmentImportResult> importPayload(ScrapePayload payload,
      {String? groupId, int? expiredAfterDays}) async {
    if (_closed) throw StateError('自动化已关闭');
    final days = expiredAfterDays ?? settings.expiredAfterDays;
    final currentTime = now().toUtc();
    var added = 0, updated = 0, preserved = 0, ignored = payload.ignoredExpired;
    await serialize(() async {
      await store.transaction(() async {
        final current = {for (final task in await store.tasks()) task.id: task};
        final ledger = asJson(await store.get('automation.imports') ?? {});
        final groups = await store.groups();
        final requestedGroup = groupId ?? settings.importGroupId;
        final target =
            groups.any((g) => g.id == requestedGroup) ? requestedGroup : '';
        var order = current.values.fold<int>(
                0, (value, task) => math.min(value, task.sortOrder ?? 0)) -
            payload.assignments.length;
        for (final entry in payload.assignments) {
          if (shouldIgnoreExpired(entry.dueAt, currentTime, days,
              markedExpired: ['已过期', '已截止', '已结束', '已关闭', '不可作答']
                  .any(entry.remoteStatus.contains))) {
            ignored++;
            continue;
          }
          final id = entry.taskId, old = current[id];
          final previous = ledger[id] == null ? null : asJson(ledger[id]);
          if (old == null && previous == null) {
            final task =
                entry.createTask(now(), groupId: target, sortOrder: order++);
            await store.task(task);
            current[id] = task;
            added++;
          } else if (old == null || old.status == 'done' || previous == null) {
            preserved++;
          } else {
            final fields = old.toJson();
            for (final key in ['name', 'category']) {
              if (fields[key] == previous[key]) {
                fields[key] = entry.sourceFields[key];
              }
            }
            if (fields['due'] == previous['due'] &&
                fields['dueAt'] == previous['dueAt']) {
              fields['due'] = entry.sourceFields['due'];
              fields['dueAt'] = entry.sourceFields['dueAt'];
            }
            final candidate = TaskItem.fromJson(fields);
            if (!candidate.sameAs(old)) {
              await store.task(TaskItem.fromJson({
                ...candidate.toJson(),
                'modified': now().toUtc().toIso8601String()
              }));
              updated++;
            } else {
              preserved++;
            }
          }
          ledger[id] = entry.sourceFields;
        }
        await store.put('automation.imports', ledger);
      });
      await refreshTasks();
    });
    _notify();
    return AssignmentImportResult(added, updated, preserved, ignored);
  }

  Future<void> runScraper({bool scheduled = false}) {
    if (_closed || scraping) return Future.value();
    if (!supportsScraper) {
      error = 'Python 定时采集在 Windows 上运行，可在手机上导入采集结果。';
      _notify();
      return Future.value();
    }
    scraping = true;
    error = '';
    if (scheduled) _attemptedDay = dayKey(beijing(now()));
    _notify();
    return _activeRun = _scrape(scheduled);
  }

  Future<void> _scrape(bool scheduled) async {
    final started = now().toUtc(), config = settings;
    final today = dayKey(beijing(started));
    final output =
        Directory(p.join(directory.path, 'automation-runs', const Uuid().v4()));
    String detail;
    var failure = '';
    try {
      final payload = await runner.run(config, output);
      if (_closed) return;
      final result = await importPayload(payload,
          groupId: config.importGroupId,
          expiredAfterDays: config.expiredAfterDays);
      detail = result.label;
      if (payload.incompletePlatforms.isNotEmpty) {
        failure = '${payload.incompletePlatforms.join('、')}采集不完整，请检查登录状态和网络。';
      }
    } catch (e) {
      if (_closed) return;
      detail = '本次采集未导入任务';
      failure = e is FormatException ? e.message : '采集或保存失败，请检查本机环境后重试。';
    } finally {
      // Each run owns this fresh directory. Only the two known output files
      // are removed, leaving user-selected script and cookie files untouched.
      for (final name in ['todos.json', 'todos.md']) {
        try {
          final file = File(p.join(output.path, name));
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      try {
        if (await output.exists()) await output.delete();
      } catch (_) {}
      if (_closed) scraping = false;
    }
    if (_closed) return;
    final next = {
      ...scrapeStatus,
      'lastRunAt': now().toUtc().toIso8601String(),
      'summary': detail,
      'error': failure,
      if (scheduled || hasReachedTime(started, config.scraperMinute))
        'scheduledDay': today,
    };
    try {
      await serialize(() async {
        await store.put('automation.scrapeStatus', next);
        scrapeStatus = next;
      });
    } catch (_) {
      failure = '采集状态保存失败，可手动重试。';
    }
    error = failure;
    scraping = false;
    _notify();
  }

  void cancelScraper() {
    if (scraping) runner.cancel();
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> shutdown() async {
    _closed = true;
    _timer?.cancel();
    runner.cancel();
    await _activeRun;
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    runner.cancel();
    super.dispose();
  }
}
