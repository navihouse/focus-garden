import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/domain/reports.dart';
import 'package:focus_garden/data/backup.dart';

FocusSession record(int ms,
    {String id = 'a',
    String reason = 'early',
    DateTime? start,
    bool excluded = false,
    bool paused = false}) {
  final a = start ?? DateTime.utc(2026, 10, 19, 1);
  final end = a.add(Duration(milliseconds: ms));
  return FocusSession.fromJson(FocusSession(
          id: id,
          device: 'test',
          plannedSeconds: reason == 'completed' ? ms ~/ 1000 : 1500,
          started: a,
          ended: paused ? end.add(const Duration(hours: 1)) : end,
          spans: [TimeSpan(a, end)],
          pauses:
              paused ? [TimeSpan(end, end.add(const Duration(hours: 1)))] : [],
          completed: reason == 'completed',
          reason: reason,
          excluded: excluded)
      .toJson());
}

void main() {
  for (final kind in PeriodKind.values) {
    test('$kind excludes sub-minute data from every aggregation and sample',
        () {
      final rows = [
        for (final reason in [
          'completed',
          'early',
          'sleep',
          'exit',
          'interrupted'
        ])
          record(59000, id: reason, reason: reason),
        record(59999, id: 'fraction'),
        record(0, id: 'zero'),
        record(60000, id: 'excluded', excluded: true)
      ];
      final r =
          buildReport(rows, ReportPeriod(kind, DateTime.utc(2026, 10, 19)));
      expect(r.milliseconds, 0);
      expect(r.count, 0);
      expect(r.sampleCount, 0);
      expect(r.contributingSessions, 0);
      expect(r.completionRate, isNull);
      expect(r.averageMinutes, isNull);
      expect(r.activeDays, 0);
      expect(r.longestStreak, 0);
      expect(r.category, isEmpty);
      expect(r.tasks, isEmpty);
      expect(r.daily, isEmpty);
      expect(r.weekly, isEmpty);
      expect(r.hourly, everyElement(0));
      expect(r.hourlyInterruptions, everyElement(0));
      expect(r.interruptionStages, everyElement(0));
      expect(r.interruptionReasons.values, everyElement(0));
      expect(r.subjects, isEmpty);
      expect(r.enoughSamples, false);
      expect(r.topSubjects, isEmpty);
      // Retain raw history and round-trip backups without marking it user-excluded.
      final restored = previewBackup(exportBackup([], rows), [], []).sessions;
      expect(restored.length, rows.length);
      expect(restored.first.milliseconds, 59000);
      expect(restored.first.excluded, false);
    });
  }
  test('exactly 60 seconds valid, pauses cannot make 59.999 seconds valid', () {
    expect(record(59999, paused: true).isValidFocus, false);
    final completed = record(60000, reason: 'completed');
    expect(completed.countsAsPomodoro, true);
    expect(record(60000, reason: 'completed', excluded: true).countsAsPomodoro,
        false);
    final r = buildReport(
        [completed, record(60000, id: 'paused', paused: true)],
        ReportPeriod(PeriodKind.week, DateTime.utc(2026, 10, 19)));
    expect(r.milliseconds, 120000);
    expect(r.completed, 1);
    expect(r.interrupted, 1);
    expect(r.sampleCount, 2);
    expect(r.averageMinutes, 1);
    expect(r.completionRate, .5);
  });
  test(
      'cross-year minute stays valid even when each clipped part is under a minute',
      () {
    final a = DateTime.utc(2026, 12, 31, 15, 59, 30);
    for (final kind in PeriodKind.values) {
      final old = ReportPeriod(kind, DateTime.utc(2026, 12, 31));
      final next = old.next;
      // For week the same date need not be a boundary; test using its actual end.
      final start = kind == PeriodKind.week
          ? civilUtc(old.end).subtract(const Duration(seconds: 30))
          : a;
      final s = record(60000, start: start, reason: 'completed');
      final invalid =
          record(59000, start: start, id: 'invalid', reason: 'sleep');
      final before = buildReport([s, invalid], old),
          after = buildReport([s, invalid], next);
      expect(before.milliseconds, 30000);
      expect(after.milliseconds, 30000);
      expect(before.completed, 0);
      expect(after.completed, 1);
      expect(before.interrupted + after.interrupted, 0);
    }
  });
}
