import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'domain/automation.dart';
import 'domain/models.dart';
import 'domain/note_link.dart';
import 'domain/reports.dart';

const scraperPlatforms = {'chaoxing': '学习通', 'icourse163': '中国大学MOOC'};

DateTime scraperTime(String value) {
  final match = RegExp(
          r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$')
      .firstMatch(value);
  if (match == null) throw const FormatException('采集时间缺少时区或格式无效');
  final year = int.parse(match[1]!),
      month = int.parse(match[2]!),
      day = int.parse(match[3]!);
  final date = DateTime.utc(year, month, day);
  final zone = match[7]!;
  if (date.year != year ||
      date.month != month ||
      date.day != day ||
      int.parse(match[4]!) > 23 ||
      int.parse(match[5]!) > 59 ||
      int.parse(match[6]!) > 59 ||
      (zone != 'Z' &&
          (int.parse(zone.substring(1, 3)) > 14 ||
              int.parse(zone.substring(4)) > 59))) {
    throw const FormatException('采集日期或时间超出范围');
  }
  return utc(value);
}

class StudyAssignment {
  final String sourceId, platform, kind, title, course, remoteStatus;
  final String? url;
  final DateTime? dueAt;
  const StudyAssignment(
      {required this.sourceId,
      required this.platform,
      required this.kind,
      required this.title,
      required this.course,
      required this.remoteStatus,
      this.url,
      this.dueAt});
  String get taskId => const Uuid()
      .v5(Namespace.url.value, 'focus-garden:study:$platform:$sourceId');
  DateTime? get due {
    if (dueAt == null) return null;
    final civil = beijing(dueAt!);
    return DateTime.utc(civil.year, civil.month, civil.day);
  }

  Json get sourceFields => {
        'name': title,
        'category': course,
        'due': due == null ? null : dayKey(due!),
        'dueAt': dueAt?.toUtc().toIso8601String(),
      };
  TaskItem createTask(DateTime now, {String groupId = '', int sortOrder = 0}) {
    var notes = '来源：${scraperPlatforms[platform]!}\n类型：$kind';
    if (remoteStatus.isNotEmpty) notes += '\n平台状态：$remoteStatus';
    final links = <NoteFileLink>[];
    if (url != null) {
      notes += '\n';
      final start = notes.length;
      notes += '打开原任务';
      links.add(NoteFileLink(start, notes.length, url!));
    }
    return TaskItem.fromJson(TaskItem(
            id: taskId,
            name: title,
            category: course,
            groupId: groupId,
            due: due,
            dueAt: dueAt,
            notes: notes,
            noteLinks: links,
            sortOrder: sortOrder,
            modified: now.toUtc())
        .toJson());
  }
}

class ScrapePayload {
  final DateTime generatedAt;
  final List<StudyAssignment> assignments;
  final List<String> incompletePlatforms;
  final int ignoredExpired;
  const ScrapePayload(
      this.generatedAt, this.assignments, this.incompletePlatforms,
      {this.ignoredExpired = 0});
  factory ScrapePayload.parse(String text) {
    if (text.length > 10 * 1024 * 1024) {
      throw const FormatException('采集结果超过 10 MB');
    }
    final data = asJson(jsonDecode(text));
    final generated = scraperTime(data['generated_at'] as String);
    if (data['timezone'] != 'Asia/Shanghai' ||
        data['sources'] is! List ||
        data['todos'] is! List ||
        (data['todos'] as List).length > 5000) {
      throw const FormatException('采集结果格式无效');
    }
    final successful = <String>{}, incomplete = <String>[];
    final seenPlatforms = <String>{};
    for (final value in data['sources'] as List) {
      final source = asJson(value), platform = source['platform'];
      if (!scraperPlatforms.containsKey(platform) ||
          !seenPlatforms.add(platform as String) ||
          source['ok'] is! bool) {
        throw const FormatException('采集平台信息无效');
      }
      if (source['ok'] == true) successful.add(platform);
      if (source['ok'] != true ||
          (source['warnings'] as List? ?? []).isNotEmpty) {
        incomplete.add(scraperPlatforms[platform]!);
      }
    }
    if (successful.isEmpty) {
      throw const FormatException('采集平台均未成功，请检查登录状态和网络');
    }
    final assignments = <StudyAssignment>[];
    final seen = <String>{};
    for (final value in data['todos'] as List) {
      final item = asJson(value), platform = item['platform'];
      if (!successful.contains(platform)) continue;
      String field(String key, int limit, {bool empty = false}) {
        final value = item[key];
        if (value is! String ||
            value.trim().length > limit ||
            (!empty && value.trim().isEmpty)) {
          throw const FormatException('采集任务字段无效');
        }
        return value.trim();
      }

      final id = field('id', 1000), title = field('title', 200);
      if (!seen.add('$platform:$id')) {
        throw const FormatException('采集结果包含重复任务编号');
      }
      final kind = field('kind', 20);
      if (!['作业', '测验', '测试', '考试'].contains(kind)) continue;
      final status = field('status', 100, empty: true);
      if (['已完成', '已提交', '已批阅', '已交', '待批阅', '已评', '已阅', '查看答案']
              .any(status.contains) ||
          (item['extra'] is Map && asJson(item['extra'])['completed'] == true)) {
        continue;
      }
      final rawUrl = field('url', 4096, empty: true);
      final url = rawUrl.isEmpty ? null : webLinkUrl(rawUrl);
      if (rawUrl.isNotEmpty && url == null) {
        throw const FormatException('采集任务链接无效');
      }
      assignments.add(StudyAssignment(
          sourceId: id,
          platform: platform,
          title: title,
          course: field('course', 100, empty: true),
          kind: kind,
          remoteStatus: status,
          url: url,
          dueAt: item['due_at'] == null
              ? null
              : scraperTime(item['due_at'] as String)));
    }
    final ignored = data['ignored_expired'] ?? 0;
    if (ignored is! int || ignored < 0 || ignored > 1000000) {
      throw const FormatException('忽略任务数量无效');
    }
    return ScrapePayload(generated, assignments, incomplete,
        ignoredExpired: ignored);
  }
}

abstract class StudyScraperRunner {
  Future<ScrapePayload> run(AutomationSettings settings, Directory output);
  void cancel();
}

class PythonStudyScraperRunner implements StudyScraperRunner {
  Process? _process;
  bool _cancelled = false;
  @override
  Future<ScrapePayload> run(
      AutomationSettings settings, Directory output) async {
    _cancelled = false;
    if (!settings.chaoxing && !settings.mooc) {
      throw const FormatException('请先选择学习通或中国大学MOOC');
    }
    if (settings.scriptPath.isEmpty ||
        !await File(settings.scriptPath).exists()) {
      throw const FormatException('找不到采集脚本，请在 AUTO 中重新选择');
    }
    for (final path in [
      if (settings.chaoxing) settings.chaoxingCookiePath,
      if (settings.mooc) settings.moocCookiePath,
    ]) {
      if (path.isEmpty || !await File(path).exists()) {
        throw const FormatException('请先配置所选平台的 Cookie 文件');
      }
    }
    if (_cancelled) throw const FormatException('采集已取消');
    await output.create(recursive: true);
    final source = settings.chaoxing && settings.mooc
        ? 'all'
        : settings.chaoxing
            ? 'chaoxing'
            : 'icourse163';
    try {
      _process = await Process.start(
          settings.pythonPath,
          [
            settings.scriptPath,
            '--source',
            source,
            '--chaoxing-cookie',
            settings.chaoxingCookiePath,
            '--icourse163-cookie',
            settings.moocCookiePath,
            '--out-dir',
            output.path,
            '--quiet',
            '--ignore-expired-days',
            '${settings.expiredAfterDays}',
            '--workers',
            '2',
            '--timeout',
            '20',
          ],
          workingDirectory: p.dirname(settings.scriptPath),
          runInShell: false,
          environment: {'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'});
      if (_cancelled) _process!.kill();
      final process = _process!;
      // Drain private platform output without retaining credentials, URLs or logs.
      final out = process.stdout.drain<void>(),
          err = process.stderr.drain<void>();
      final exit = await process.exitCode.timeout(const Duration(minutes: 10),
          onTimeout: () {
        process.kill();
        throw const FormatException('采集超过 10 分钟，请检查网络后重试');
      });
      await Future.wait([out, err]);
      if (_cancelled) throw const FormatException('采集已取消');
      if (exit != 0) {
        throw FormatException(exit == 2
            ? '采集未成功，请检查 Cookie 是否过期、所选平台和网络'
            : '脚本运行失败，请确认 Python、requests 依赖及输出目录可用');
      }
      final file = File(p.join(output.path, 'todos.json'));
      if (!await file.exists() || await file.length() > 10 * 1024 * 1024) {
        throw const FormatException('脚本未产生有效的 todos.json');
      }
      return ScrapePayload.parse(await file.readAsString());
    } on ProcessException {
      throw const FormatException('无法启动 Python，请选择正确的 Python 程序');
    } finally {
      _process?.kill();
      _process = null;
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    _process?.kill();
  }
}
