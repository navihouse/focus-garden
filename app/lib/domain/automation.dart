import 'models.dart';
import 'reports.dart';

class AutomationSettings {
  final bool morningEnabled, scraperEnabled, chaoxing, mooc;
  final int morningMinute, scraperMinute;
  final String pythonPath, scriptPath, chaoxingCookiePath, moocCookiePath;
  final String importGroupId;
  const AutomationSettings({
    this.morningEnabled = false,
    this.scraperEnabled = false,
    this.morningMinute = 8 * 60,
    this.scraperMinute = 7 * 60 + 30,
    this.pythonPath = 'python',
    this.scriptPath = '',
    this.chaoxingCookiePath = '',
    this.moocCookiePath = '',
    this.chaoxing = true,
    this.mooc = true,
    this.importGroupId = '',
  });

  Json toJson() => {
        'morningEnabled': morningEnabled,
        'scraperEnabled': scraperEnabled,
        'morningMinute': morningMinute,
        'scraperMinute': scraperMinute,
        'pythonPath': pythonPath,
        'scriptPath': scriptPath,
        'chaoxingCookiePath': chaoxingCookiePath,
        'moocCookiePath': moocCookiePath,
        'chaoxing': chaoxing,
        'mooc': mooc,
        'importGroupId': importGroupId,
      };

  factory AutomationSettings.fromJson(Json value) {
    final defaults = const AutomationSettings().toJson();
    for (final key in defaults.keys) {
      if (value.containsKey(key) &&
          value[key].runtimeType != defaults[key].runtimeType) {
        throw const FormatException('自动化设置格式无效');
      }
    }
    final j = {...defaults, ...value};
    for (final key in ['morningMinute', 'scraperMinute']) {
      if ((j[key] as int) < 0 || (j[key] as int) > 1439) {
        throw const FormatException('定时时间无效');
      }
    }
    for (final key in [
      'pythonPath',
      'scriptPath',
      'chaoxingCookiePath',
      'moocCookiePath'
    ]) {
      final text = j[key] as String;
      if (text.length > 4096 || text.contains('\u0000')) {
        throw const FormatException('自动化文件地址无效');
      }
    }
    if (j['scraperEnabled'] == true &&
        j['chaoxing'] != true &&
        j['mooc'] != true) {
      throw const FormatException('请选择至少一个采集平台');
    }
    return AutomationSettings(
      morningEnabled: j['morningEnabled'],
      scraperEnabled: j['scraperEnabled'],
      morningMinute: j['morningMinute'],
      scraperMinute: j['scraperMinute'],
      pythonPath: j['pythonPath'],
      scriptPath: j['scriptPath'],
      chaoxingCookiePath: j['chaoxingCookiePath'],
      moocCookiePath: j['moocCookiePath'],
      chaoxing: j['chaoxing'],
      mooc: j['mooc'],
      importGroupId: j['importGroupId'],
    );
  }

  AutomationSettings copyWith(Json values) =>
      AutomationSettings.fromJson({...toJson(), ...values});
}

String minuteLabel(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

bool hasReachedTime(DateTime utcNow, int minute) {
  final civil = beijing(utcNow);
  return civil.hour * 60 + civil.minute >= minute;
}

DateTime nextAutomationRun(DateTime utcNow, int minute, {String? finishedDay}) {
  final civil = beijing(utcNow);
  var date = DateTime.utc(
      civil.year, civil.month, civil.day, minute ~/ 60, minute % 60);
  if (finishedDay == dayKey(civil)) {
    date = date.add(const Duration(days: 1));
  } else if (date.isBefore(civil)) {
    return utcNow.toUtc();
  }
  return civilUtc(date);
}

String taskDeadlineText(TaskItem task) {
  final precise = task.dueAt;
  if (precise != null) {
    final civil = beijing(precise);
    return '${dayKey(civil)} ${minuteLabel(civil.hour * 60 + civil.minute)}';
  }
  return task.due == null ? '未设截止日期' : dayKey(task.due!);
}

class MorningMessage {
  final String day;
  final DateTime generatedAt;
  final DateTime? readAt;
  final List<Json> dueToday, completedYesterday, unfinishedYesterday;
  const MorningMessage(
      {required this.day,
      required this.generatedAt,
      this.readAt,
      required this.dueToday,
      required this.completedYesterday,
      required this.unfinishedYesterday});
  bool get unread => readAt == null;
  Json toJson() => {
        'day': day,
        'generatedAt': generatedAt.toUtc().toIso8601String(),
        'readAt': readAt?.toUtc().toIso8601String(),
        'dueToday': dueToday,
        'completedYesterday': completedYesterday,
        'unfinishedYesterday': unfinishedYesterday,
      };
  factory MorningMessage.fromJson(Json j) => MorningMessage(
        day: j['day'] as String,
        generatedAt: utc(j['generatedAt'] as String),
        readAt: j['readAt'] == null ? null : utc(j['readAt'] as String),
        dueToday: (j['dueToday'] as List).map(asJson).toList(),
        completedYesterday:
            (j['completedYesterday'] as List).map(asJson).toList(),
        unfinishedYesterday:
            (j['unfinishedYesterday'] as List).map(asJson).toList(),
      );
  MorningMessage markRead(DateTime now) => MorningMessage.fromJson(
      {...toJson(), 'readAt': now.toUtc().toIso8601String()});
}

MorningMessage buildMorningMessage(List<TaskItem> tasks, DateTime now) {
  final today = dayKey(beijing(now));
  final yesterday = dayKey(beijing(now).subtract(const Duration(days: 1)));
  String? dueDay(TaskItem task) => task.dueAt != null
      ? dayKey(beijing(task.dueAt!))
      : task.due == null
          ? null
          : dayKey(task.due!);
  final due = tasks.where((task) => dueDay(task) == today).toList();
  final completed = tasks
      .where((task) =>
          task.status == 'done' &&
          dayKey(beijing(task.completionTime)) == yesterday)
      .toList()
    ..sort((a, b) => b.completionTime.compareTo(a.completionTime));
  final unfinished = tasks
      .where((task) => task.status != 'done' && dueDay(task) == yesterday)
      .toList();
  int byDeadline(TaskItem a, TaskItem b) {
    final time = (a.dueAt ?? DateTime.utc(9999))
        .compareTo(b.dueAt ?? DateTime.utc(9999));
    return time == 0 ? a.name.compareTo(b.name) : time;
  }

  due.sort(byDeadline);
  unfinished.sort(byDeadline);
  Json snapshot(TaskItem task) => {
        'id': task.id,
        'name': task.name,
        'category': task.category,
        'status': task.status,
        'deadline': taskDeadlineText(task),
      };
  return MorningMessage(
      day: today,
      generatedAt: now.toUtc(),
      dueToday: due.map(snapshot).toList(),
      completedYesterday: completed.map(snapshot).toList(),
      unfinishedYesterday: unfinished.map(snapshot).toList());
}
