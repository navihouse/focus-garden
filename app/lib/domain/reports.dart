import 'models.dart';

/// Report dates use a fixed UTC+08:00 civil calendar, independent of device zone.
DateTime beijing(DateTime utcTime) =>
    utcTime.toUtc().add(const Duration(hours: 8));
DateTime civilUtc(DateTime civil) => DateTime.utc(civil.year, civil.month,
        civil.day, civil.hour, civil.minute, civil.second, civil.millisecond)
    .subtract(const Duration(hours: 8));
String dayKey(DateTime civil) =>
    '${civil.year}-${civil.month.toString().padLeft(2, '0')}-${civil.day.toString().padLeft(2, '0')}';

enum PeriodKind { week, month, year }

class ReportPeriod {
  final PeriodKind kind;
  final DateTime start, end;
  ReportPeriod(this.kind, DateTime civil)
      : start = _start(kind, civil),
        end = _end(kind, _start(kind, civil));
  static DateTime _start(PeriodKind k, DateTime d) {
    final day = DateTime.utc(d.year, d.month, d.day);
    return switch (k) {
      PeriodKind.week => day.subtract(Duration(days: day.weekday - 1)),
      PeriodKind.month => DateTime.utc(d.year, d.month),
      PeriodKind.year => DateTime.utc(d.year),
    };
  }

  static DateTime _end(PeriodKind k, DateTime s) => switch (k) {
        PeriodKind.week => s.add(const Duration(days: 7)),
        PeriodKind.month => DateTime.utc(s.year, s.month + 1),
        PeriodKind.year => DateTime.utc(s.year + 1),
      };
  ReportPeriod get previous =>
      ReportPeriod(kind, start.subtract(const Duration(days: 1)));
  ReportPeriod get next => ReportPeriod(kind, end);
  bool isOpen(DateTime now) => beijing(now).isBefore(end);
}

String hourLabel(int hour) =>
    '${hour.toString().padLeft(2, '0')}:00–${(hour + 1).toString().padLeft(2, '0')}:00';

const interruptionStageLabels = ['前 25%', '25%–50%', '50%–75%', '最后 25%'];
const interruptionReasonLabels = {
  'early': '主动提前结束',
  'sleep': '电脑睡眠',
  'exit': '退出应用',
  'interrupted': '异常中断',
};

class HourInvestment {
  final int hour, milliseconds;
  final bool tied;
  const HourInvestment(this.hour, this.milliseconds, this.tied);
}

class SubjectActivity {
  final String name;
  int milliseconds = 0, completed = 0, records = 0;
  final List<int> hourly = List.filled(24, 0);
  SubjectActivity(this.name);
  List<int> get peakHours {
    final max = hourly.reduce((a, b) => a > b ? a : b);
    return [
      for (var h = 0; h < 24; h++)
        if (max > 0 && hourly[h] == max) h
    ];
  }
}

class Report {
  final ReportPeriod period;
  int milliseconds = 0,
      completed = 0,
      interrupted = 0,
      contributingSessions = 0;
  final Map<String, int> daily = {}, category = {}, tasks = {}, weekly = {};
  final List<int> hourly = List.filled(24, 0);
  final List<int> hourlyInterruptions = List.filled(24, 0);
  final List<int> interruptionStages = List.filled(4, 0);
  final Map<String, int> interruptionReasons = {
    for (final reason in interruptionReasonLabels.keys) reason: 0,
  };
  final Map<String, SubjectActivity> subjects = {};
  // A record is a sample if it contributes focus time OR ends in this period.
  int sampleCount = 0;
  Report(this.period);
  bool get enoughSamples => sampleCount >= 5;
  int get unclassifiedRecords => subjects['未分类']?.records ?? 0;
  List<SubjectActivity> get topSubjects {
    final ranked = subjects.values
        .where((s) => s.name != '未分类' && s.completed > 0)
        .toList()
      ..sort((a, b) {
        final count = b.completed.compareTo(a.completed);
        if (count != 0) return count;
        final time = b.milliseconds.compareTo(a.milliseconds);
        return time != 0 ? time : a.name.compareTo(b.name);
      });
    return ranked.take(3).toList();
  }

  bool get hasHourVariation {
    final positive = hourly.where((ms) => ms > 0).toSet();
    return positive.length > 1;
  }

  List<HourInvestment> investmentHours({bool descending = true}) {
    final hours = [
      for (var h = 0; h < 24; h++)
        if (hourly[h] > 0) h
    ]..sort((a, b) {
        final time = descending
            ? hourly[b].compareTo(hourly[a])
            : hourly[a].compareTo(hourly[b]);
        return time != 0 ? time : a.compareTo(b);
      });
    return hours
        .take(3)
        .map((h) => HourInvestment(h, hourly[h],
            hours.where((other) => hourly[other] == hourly[h]).length > 1))
        .toList();
  }

  int get count => completed + interrupted;
  double? get completionRate => count == 0 ? null : completed / count;
  double? get averageMinutes => contributingSessions == 0
      ? null
      : milliseconds / 60000 / contributingSessions;
  int get activeDays => daily.values.where((n) => n > 0).length;
  int get longestStreak {
    int run = 0, best = 0;
    for (var d = period.start;
        d.isBefore(period.end);
        d = d.add(const Duration(days: 1))) {
      run = (daily[dayKey(d)] ?? 0) > 0 ? run + 1 : 0;
      if (run > best) best = run;
    }
    return best;
  }

  List<String> get advice {
    if (!enoughSamples) {
      return ['样本不足：目前有 $sampleCount 次记录；累计至少 5 次后提供规律建议。'];
    }
    final result = <String>[];
    if (count >= 5 && interrupted / count >= .3) {
      result.add(
          '$count 次记录中有 $interrupted 次未完成（${(interrupted / count * 100).round()}%）；可尝试缩短单次专注时长。');
    }
    if (hasHourVariation) {
      final peak = investmentHours().first;
      result.add('投入最多的时段${peak.tied ? '之一' : ''}是 ${hourLabel(peak.hour)}，'
          '共 ${(peak.milliseconds / 60000).toStringAsFixed(1)} 分钟；可作为安排任务的参考。');
    }
    result.add('本周期活跃 $activeDays 天，最长连续专注 $longestStreak 天。');
    return result;
  }
}

Report buildReport(Iterable<FocusSession> sessions, ReportPeriod period) {
  final r = Report(period);
  final low = civilUtc(period.start), high = civilUtc(period.end);
  for (final s in sessions.where((s) => !s.excluded)) {
    final name = s.category.trim().isEmpty ? '未分类' : s.category.trim();
    final subject = SubjectActivity(name);
    final endsInPeriod = !s.ended.isBefore(low) && s.ended.isBefore(high);
    int contribution = 0;
    for (final span in s.spans) {
      var cursor = span.start.isBefore(low) ? low : span.start;
      final stop = span.end.isAfter(high) ? high : span.end;
      while (cursor.isBefore(stop)) {
        final local = beijing(cursor);
        final hourEnd =
            DateTime.utc(local.year, local.month, local.day, local.hour + 1)
                .subtract(const Duration(hours: 8));
        final end = hourEnd.isBefore(stop) ? hourEnd : stop;
        final ms = end.difference(cursor).inMilliseconds;
        final key = dayKey(local);
        final week = dayKey(ReportPeriod(PeriodKind.week, local).start);
        r.daily.update(key, (v) => v + ms, ifAbsent: () => ms);
        r.weekly.update(week, (v) => v + ms, ifAbsent: () => ms);
        r.hourly[local.hour] += ms;
        subject.hourly[local.hour] += ms;
        contribution += ms;
        cursor = end;
      }
    }
    r.milliseconds += contribution;
    if (contribution > 0) {
      r.contributingSessions++;
      r.category
          .update(name, (v) => v + contribution, ifAbsent: () => contribution);
      r.tasks.update(s.taskName, (v) => v + contribution,
          ifAbsent: () => contribution);
    }
    // Ended exactly at midnight belongs to the ending date, as requested.
    if (endsInPeriod) {
      if (s.completed) {
        r.completed++;
        subject.completed++;
      } else {
        r.interrupted++;
        r.hourlyInterruptions[beijing(s.ended).hour]++;
        final stage =
            (s.milliseconds * 4 ~/ (s.plannedSeconds * 1000)).clamp(0, 3);
        r.interruptionStages[stage]++;
        r.interruptionReasons.update(s.reason, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    if (contribution > 0 || endsInPeriod) {
      r.sampleCount++;
      final aggregate =
          r.subjects.putIfAbsent(name, () => SubjectActivity(name));
      aggregate.records++;
      aggregate.milliseconds += contribution;
      aggregate.completed += subject.completed;
      for (var h = 0; h < 24; h++) {
        aggregate.hourly[h] += subject.hourly[h];
      }
    }
  }
  return r;
}

bool overlaps(FocusSession a, FocusSession b) => a.spans.any((x) =>
    b.spans.any((y) => x.start.isBefore(y.end) && y.start.isBefore(x.end)));
