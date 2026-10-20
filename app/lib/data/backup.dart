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
  BackupPreview(this.tasks, this.sessions, this.conflicts,
      this.overlapsExisting, this.duplicateRecords);
}

String exportBackup(List<TaskItem> tasks, List<FocusSession> sessions) =>
    const JsonEncoder.withIndent('  ').convert({
      'format': 'focus-garden',
      'version': 2,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'tasks': tasks.map((t) => t.toJson()).toList(),
      'sessions': sessions.map((s) => s.toJson()).toList()
    });

BackupPreview previewBackup(String text, List<TaskItem> existingTasks,
    List<FocusSession> existingSessions) {
  if (text.length > 50 * 1024 * 1024) {
    throw const FormatException('备份超过 50 MB 限制');
  }
  final j = asJson(jsonDecode(text));
  if (j['format'] != 'focus-garden' || ![1, 2].contains(j['version'])) {
    throw const FormatException('不支持的备份格式或版本');
  }
  utc(j['exportedAt'] as String);
  final tasks =
      (j['tasks'] as List).map((x) => TaskItem.fromJson(asJson(x))).toList();
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
      sessions.length - fresh.length);
}

Future<void> importBackup(LocalStore store, BackupPreview preview,
    {Set<String> useImportedTaskIds = const {},
    Set<String> excludeSessionIds = const {}}) async {
  await store.transaction(() async {
    final existing = {for (final t in await store.tasks()) t.id: t};
    for (final t in preview.tasks) {
      if (!existing.containsKey(t.id) || useImportedTaskIds.contains(t.id)) {
        await store.task(t);
      }
    }
    for (final s in preview.sessions) {
      await store
          .session(excludeSessionIds.contains(s.id) ? s.withExcluded(true) : s);
    }
  });
}
