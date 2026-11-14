import 'dart:convert';
import '../domain/models.dart';
import '../domain/reports.dart';
import 'store.dart';

class BackupPreview {
  final List<TaskItem> tasks;
  final List<FocusSession> sessions;
  final List<TaskItem> conflicts;
  final Set<String> overlapsExisting;
  final int duplicateRecords;
  final List<TaskGroup> groups;
  BackupPreview(this.tasks, this.sessions, this.conflicts,
      this.overlapsExisting, this.duplicateRecords,
      [this.groups = const []]);
}

String exportBackup(List<TaskItem> tasks, List<FocusSession> sessions,
    [List<TaskGroup> groups = const []]) {
  final known = {for (final group in groups) group.id};
  // A stale group reference would make the file fail import validation.
  final exported = [
    for (final task in tasks)
      known.contains(task.groupId)
          ? task
          : TaskItem.fromJson({...task.toJson(), 'groupId': ''}),
  ];
  final hasGroups =
      groups.isNotEmpty || exported.any((task) => task.groupId.isNotEmpty);
  final hasDeadline = exported.any((task) => task.dueAt != null);
  return const JsonEncoder.withIndent('  ').convert({
    'format': 'focus-garden',
    'version': hasDeadline
        ? 7
        : hasGroups
            ? 6
            : exported.any((task) => task.noteLinks.any((link) => link.isWeb))
                ? 5
                : 4,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    if (hasGroups || hasDeadline)
      'groups': groups.map((group) => group.toJson()).toList(),
    'tasks': exported.map((t) => t.toJson()).toList(),
    'sessions': sessions.map((s) => s.toJson()).toList()
  });
}

BackupPreview previewBackup(String text, List<TaskItem> existingTasks,
    List<FocusSession> existingSessions) {
  if (text.length > 50 * 1024 * 1024) {
    throw const FormatException('备份超过 50 MB 限制');
  }
  final j = asJson(jsonDecode(text));
  final version = j['version'];
  if (j['format'] != 'focus-garden' ||
      version is! int ||
      version < 1 ||
      version > 7) {
    throw const FormatException('不支持的备份格式或版本');
  }
  utc(j['exportedAt'] as String);
  final tasks =
      (j['tasks'] as List).map((x) => TaskItem.fromJson(asJson(x))).toList();
  if (version < 7 && tasks.any((task) => task.dueAt != null)) {
    throw const FormatException('精确截止时间需要第 7 版备份格式');
  }
  if (version < 5 &&
      tasks.any((task) => task.noteLinks.any((link) => link.isWeb))) {
    throw const FormatException('网页链接需要第 5 版备份格式');
  }
  final groups = version >= 6
      ? ((j['groups'] as List?) ??
              (throw const FormatException('第 6 版备份缺少分组数据')))
          .map((x) => TaskGroup.fromJson(asJson(x)))
          .toList()
      : <TaskGroup>[];
  if (version < 6 &&
      (groups.isNotEmpty || tasks.any((t) => t.groupId.isNotEmpty))) {
    throw const FormatException('任务分组需要第 6 版备份格式');
  }
  if (groups.map((g) => g.id).toSet().length != groups.length ||
      groups.map((g) => g.name).toSet().length != groups.length) {
    throw const FormatException('备份内含重复分组');
  }
  final groupIds = {for (final g in groups) g.id};
  if (tasks.any((t) => t.groupId.isNotEmpty && !groupIds.contains(t.groupId))) {
    throw const FormatException('备份中的任务引用了不存在的分组');
  }
  final sessions = (j['sessions'] as List)
      .map((x) => FocusSession.fromJson(asJson(x)))
      .toList();
  if (tasks.map((t) => t.id).toSet().length != tasks.length ||
      sessions.map((s) => s.id).toSet().length != sessions.length) {
    throw const FormatException('备份内含重复编号');
  }
  final oldTasks = {for (final t in existingTasks) t.id: t};
  final oldSessions = {for (final s in existingSessions) s.id: s};
  final fresh = sessions.where((s) => !oldSessions.containsKey(s.id)).toList();
  final overlapIds = <String>{};
  final candidates = [...existingSessions.where((s) => !s.excluded)];
  for (final s in fresh) {
    if (!s.excluded && candidates.any((old) => overlaps(s, old))) {
      overlapIds.add(s.id);
    }
    if (!s.excluded) candidates.add(s);
  }
  return BackupPreview(
      tasks,
      fresh,
      tasks
          .where(
              (t) => oldTasks.containsKey(t.id) && !oldTasks[t.id]!.sameAs(t))
          .toList(),
      overlapIds,
      sessions.length - fresh.length,
      groups);
}

Future<void> importBackup(LocalStore store, BackupPreview preview,
    {Set<String> useImportedTaskIds = const {},
    Set<String> excludeSessionIds = const {}}) async {
  await store.transaction(() async {
    final groups = await store.groups();
    // Groups merge by id; an id clash keeps the local name and color, while a
    // same-name group from another device is reused so names stay unique.
    final remap = <String, String>{};
    for (final group in preview.groups) {
      if (groups.any((g) => g.id == group.id)) continue;
      final sameName = groups.where((g) => g.name == group.name).firstOrNull;
      if (sameName != null) {
        remap[group.id] = sameName.id;
      } else {
        groups.add(group);
      }
    }
    if (preview.groups.isNotEmpty) await store.saveGroups(groups);
    final existing = {for (final t in await store.tasks()) t.id: t};
    for (final t in preview.tasks) {
      if (existing.containsKey(t.id) && !useImportedTaskIds.contains(t.id)) {
        continue;
      }
      final groupId = remap[t.groupId] ?? t.groupId;
      await store.task(groupId == t.groupId
          ? t
          : TaskItem.fromJson({...t.toJson(), 'groupId': groupId}));
    }
    for (final s in preview.sessions) {
      await store
          .session(excludeSessionIds.contains(s.id) ? s.withExcluded(true) : s);
    }
  });
}
