import 'dart:convert';
import 'hotkey.dart';
import 'note_link.dart';

typedef Json = Map<String, dynamic>;

DateTime utc(String value) => DateTime.parse(value).toUtc();
Json asJson(Object? value) => Map<String, dynamic>.from(value as Map);

class SubtaskItem {
  final String id, name;
  final bool completed;
  const SubtaskItem(
      {required this.id, required this.name, this.completed = false});
  Json toJson() => {'id': id, 'name': name, 'completed': completed};
  factory SubtaskItem.fromJson(Json j) {
    if (j['id'] is! String ||
        j['name'] is! String ||
        j['completed'] is! bool ||
        (j['id'] as String).isEmpty ||
        (j['name'] as String).trim().isEmpty ||
        (j['name'] as String).length > 200) {
      throw const FormatException('子任务字段无效');
    }
    return SubtaskItem(id: j['id'], name: j['name'], completed: j['completed']);
  }
}

class TaskItem {
  final String id, name, category, status;
  final int estimate;
  final DateTime? due;
  final DateTime modified;
  final DateTime? completedAt;
  final String notes;
  final List<NoteFileLink> noteLinks;
  final int? sortOrder;
  final List<SubtaskItem> subtasks;
  const TaskItem(
      {required this.id,
      required this.name,
      this.category = '',
      this.status = 'todo',
      this.estimate = 1,
      this.due,
      this.notes = '',
      this.noteLinks = const [],
      this.sortOrder,
      this.subtasks = const [],
      this.completedAt,
      required this.modified});
  DateTime get completionTime => completedAt ?? modified;
  Json toJson() => {
        'id': id,
        'name': name,
        'category': category,
        'status': status,
        'estimate': estimate,
        'notes': notes,
        'noteLinks': noteLinks.map((link) => link.toJson()).toList(),
        'sortOrder': sortOrder,
        'subtasks': subtasks.map((s) => s.toJson()).toList(),
        'due': due == null
            ? null
            : '${due!.year}-${due!.month.toString().padLeft(2, '0')}-${due!.day.toString().padLeft(2, '0')}',
        'modified': modified.toIso8601String(),
        'completedAt': completedAt?.toIso8601String()
      };
  factory TaskItem.fromJson(Json j) {
    if ((j['notes'] != null && j['notes'] is! String) ||
        (j['subtasks'] != null && j['subtasks'] is! List) ||
        (j['noteLinks'] != null && j['noteLinks'] is! List) ||
        (j['sortOrder'] != null && j['sortOrder'] is! int)) {
      throw const FormatException('任务备注或子任务格式无效');
    }
    final t = TaskItem(
        id: j['id'] as String,
        name: j['name'] as String,
        category: j['category'] as String,
        status: j['status'] as String,
        estimate: j['estimate'] as int,
        notes: j['notes'] as String? ?? '',
        noteLinks: ((j['noteLinks'] as List?) ?? [])
            .map((l) => NoteFileLink.fromJson(asJson(l)))
            .toList(),
        sortOrder: j['sortOrder'] as int?,
        subtasks: ((j['subtasks'] as List?) ?? [])
            .map((s) => SubtaskItem.fromJson(asJson(s)))
            .toList(),
        due: j['due'] == null ? null : DateTime.parse(j['due'] as String),
        completedAt:
            j['completedAt'] == null ? null : utc(j['completedAt'] as String),
        modified: utc(j['modified'] as String));
    if (t.id.isEmpty ||
        t.name.trim().isEmpty ||
        t.name.length > 200 ||
        t.category.length > 100 ||
        t.notes.length > 10000 ||
        t.noteLinks.length > 200 ||
        (t.sortOrder != null && t.sortOrder!.abs() > 9007199254740991) ||
        t.subtasks.length > 200 ||
        t.subtasks.map((s) => s.id).toSet().length != t.subtasks.length ||
        t.estimate < 1 ||
        t.estimate > 999 ||
        !['todo', 'doing', 'done'].contains(t.status)) {
      throw const FormatException('任务字段无效');
    }
    var previousEnd = 0;
    for (final link in t.noteLinks) {
      if (link.start < previousEnd ||
          link.end <= link.start ||
          link.end > t.notes.length ||
          localFilePath(link.target) != link.target) {
        throw const FormatException('备注链接越界、重叠或文件地址无效');
      }
      previousEnd = link.end;
    }
    return t;
  }
  bool sameAs(TaskItem other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());
}

class TimeSpan {
  final DateTime start, end;
  const TimeSpan(this.start, this.end);
  int get milliseconds => end.difference(start).inMilliseconds;
  Json toJson() =>
      {'start': start.toIso8601String(), 'end': end.toIso8601String()};
  factory TimeSpan.fromJson(Json j) {
    final s = TimeSpan(utc(j['start'] as String), utc(j['end'] as String));
    if (s.milliseconds < 0) throw const FormatException('时间区间倒置');
    return s;
  }
}

class FocusSession {
  final String id, device, taskName, category, reason;
  final String? taskId;
  final int plannedSeconds;
  final DateTime started, ended;
  final List<TimeSpan> spans, pauses;
  final bool completed, excluded;
  const FocusSession(
      {required this.id,
      required this.device,
      this.taskId,
      this.taskName = '自由专注',
      this.category = '未分类',
      required this.plannedSeconds,
      required this.started,
      required this.ended,
      required this.spans,
      this.pauses = const [],
      this.completed = false,
      this.excluded = false,
      this.reason = 'interrupted'});
  int get milliseconds => spans.fold(0, (sum, s) => sum + s.milliseconds);

  /// Evaluate the entire session before clipping it to a report period.
  /// Pauses and rests are not present in these focus spans.
  bool get isValidFocus => milliseconds >= 60000;
  bool get includedInStatistics => isValidFocus && !excluded;
  bool get countsAsPomodoro => completed && includedInStatistics;
  FocusSession withExcluded(bool value) =>
      FocusSession.fromJson({...toJson(), 'excluded': value});
  Json toJson() => {
        'id': id,
        'device': device,
        'taskId': taskId,
        'taskName': taskName,
        'category': category,
        'plannedSeconds': plannedSeconds,
        'started': started.toIso8601String(),
        'ended': ended.toIso8601String(),
        'spans': spans.map((s) => s.toJson()).toList(),
        'pauses': pauses.map((s) => s.toJson()).toList(),
        'completed': completed,
        'excluded': excluded,
        'reason': reason
      };
  factory FocusSession.fromJson(Json j) {
    final s = FocusSession(
        id: j['id'] as String,
        device: j['device'] as String,
        taskId: j['taskId'] as String?,
        taskName: j['taskName'] as String,
        category: j['category'] as String,
        plannedSeconds: j['plannedSeconds'] as int,
        started: utc(j['started'] as String),
        ended: utc(j['ended'] as String),
        spans: (j['spans'] as List)
            .map((v) => TimeSpan.fromJson(asJson(v)))
            .toList(),
        pauses: (j['pauses'] as List)
            .map((v) => TimeSpan.fromJson(asJson(v)))
            .toList(),
        completed: j['completed'] as bool,
        excluded: j['excluded'] as bool,
        reason: j['reason'] as String);
    if (s.id.isEmpty ||
        s.plannedSeconds < 1 ||
        s.plannedSeconds > 86400 ||
        s.ended.isBefore(s.started) ||
        s.milliseconds > s.plannedSeconds * 1000 ||
        !['completed', 'early', 'interrupted', 'sleep', 'exit']
            .contains(s.reason) ||
        s.completed != (s.reason == 'completed') ||
        (s.completed && s.milliseconds != s.plannedSeconds * 1000)) {
      throw const FormatException('专注记录无效');
    }
    DateTime previous = s.started;
    for (final span in s.spans) {
      if (span.start.isBefore(previous) || span.end.isAfter(s.ended)) {
        throw const FormatException('专注区间重叠或越界');
      }
      previous = span.end;
    }
    previous = s.started;
    for (final pause in s.pauses) {
      if (pause.start.isBefore(previous) || pause.end.isAfter(s.ended)) {
        throw const FormatException('暂停区间重叠或越界');
      }
      for (final span in s.spans) {
        if (pause.start.isBefore(span.end) && span.start.isBefore(pause.end)) {
          throw const FormatException('暂停与专注重叠');
        }
      }
      previous = pause.end;
    }
    return s;
  }
}

class Settings {
  final int focus, shortBreak, longBreak;
  final String theme;
  final String? backgroundPath;
  final double backgroundOpacity;
  final double cardTransparency;
  final HotkeyBinding musicHotkey, timerHotkey;
  final Map<String, int> goals;
  const Settings(
      {this.focus = 25,
      this.shortBreak = 5,
      this.longBreak = 15,
      this.theme = 'system',
      this.backgroundPath,
      this.backgroundOpacity = .2,
      this.cardTransparency = .65,
      this.musicHotkey = HotkeyBinding.musicDefault,
      this.timerHotkey = HotkeyBinding.timerDefault,
      this.goals = const {}});
  Json toJson() => {
        'focus': focus,
        'shortBreak': shortBreak,
        'longBreak': longBreak,
        'theme': theme,
        'backgroundPath': backgroundPath,
        'backgroundOpacity': backgroundOpacity,
        'cardTransparency': cardTransparency,
        'musicHotkey': musicHotkey.toJson(),
        'timerHotkey': timerHotkey.toJson(),
        'goals': goals
      };
  factory Settings.fromJson(Json j) => Settings(
      focus: j['focus'] as int,
      shortBreak: j['shortBreak'] as int,
      longBreak: j['longBreak'] as int,
      theme: j['theme'] as String,
      backgroundPath: j['backgroundPath'] as String?,
      backgroundOpacity: ((j['backgroundOpacity'] as num?)?.toDouble() ?? .2)
          .clamp(.05, 1.0)
          .toDouble(),
      cardTransparency: ((j['cardTransparency'] as num?)?.toDouble() ?? .65)
          .clamp(0, 1)
          .toDouble(),
      musicHotkey:
          HotkeyBinding.fromJson(j['musicHotkey'], HotkeyBinding.musicDefault),
      timerHotkey:
          HotkeyBinding.fromJson(j['timerHotkey'], HotkeyBinding.timerDefault),
      goals: Map<String, int>.from(j['goals'] as Map));
}
