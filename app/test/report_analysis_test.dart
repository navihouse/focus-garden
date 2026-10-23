import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/domain/reports.dart';

final week = ReportPeriod(PeriodKind.week, DateTime.utc(2026, 10, 19));

FocusSession row(String id, String start,
    {int seconds = 600,
    int? planned,
    String category = '数学',
    String reason = 'completed',
    bool excluded = false,
    List<TimeSpan>? spans,
    List<TimeSpan> pauses = const [],
    DateTime? ended}) {
  final a = DateTime.parse(start).toUtc();
  final b = ended ?? a.add(Duration(seconds: seconds));
  // Go through the persisted-record validator, including span/pause invariants.
  return FocusSession.fromJson(FocusSession(
    id: id,
    device: 'test',
    category: category,
    started: a,
    ended: b,
    plannedSeconds: planned ?? seconds,
    spans: spans ?? [TimeSpan(a, b)],
    pauses: pauses,
    reason: reason,
    completed: reason == 'completed',
    excluded: excluded,
  ).toJson());
}

void main() {
  test('hourly focus splits across Beijing hours and preserves total', () {
    final r = buildReport([
      row('a', '2026-10-19T01:50:00Z', seconds: 1200),
      row('b', '2026-10-19T03:00:00Z', seconds: 1800),
    ], week);
    expect(r.hourly[9], 600000);
    expect(r.hourly[10], 600000);
    expect(r.hourly[11], 1800000);
    expect(r.hourly.reduce((a, b) => a + b), r.milliseconds);
    expect(r.investmentHours().map((h) => h.hour), [11, 9, 10]);
    expect(
        r.investmentHours(descending: false).map((h) => h.hour), [9, 10, 11]);
    expect(r.investmentHours()[1].tied, true);
    expect(r.hasHourVariation, true);
    expect(r.subjects['数学']!.hourly, r.hourly);
    expect(r.subjects['数学']!.peakHours, [11]);
  });

  test('zero hours excluded; all equal or single hour has no variation', () {
    final empty = buildReport([], week);
    expect(empty.investmentHours(), isEmpty);
    expect(empty.hasHourVariation, false);
    final equal = buildReport(
        List.generate(4, (i) => row('$i', '2026-10-19T0$i:00:00Z')), week);
    expect(equal.hasHourVariation, false);
    expect(equal.investmentHours().length, 3);
    expect(equal.investmentHours().every((h) => h.tied), true);
    expect(
        buildReport([row('a', '2026-10-19T01:00:00Z')], week).hasHourVariation,
        false);
  });

  test('interruptions use end hour and separate all four reasons', () {
    final rows = [
      for (var i = 0; i < 4; i++)
        row('$i', '2026-10-19T11:50:00Z',
            seconds: 1200,
            planned: 1800,
            reason: interruptionReasonLabels.keys.elementAt(i))
    ];
    final r = buildReport([
      ...rows,
      row('done', '2026-10-19T12:00:00Z'),
      row('excluded', '2026-10-19T12:00:00Z', reason: 'early', excluded: true),
    ], week);
    expect(r.hourlyInterruptions[19], 0);
    expect(r.hourlyInterruptions[20], 4);
    expect(r.hourlyInterruptions.reduce((a, b) => a + b), 4);
    expect(r.interruptionReasons.values, everyElement(1));
    expect(r.interrupted, 4);
    expect(r.completed, 1);
    expect(r.sampleCount, 5);
  });

  test('progress boundaries and different plans use actual focus proportion',
      () {
    final r = buildReport([
      for (final (index, actual)
          in [0, 249, 250, 499, 500, 749, 750, 1000].indexed)
        row('$index', '2026-10-19T01:00:00Z',
            seconds: actual, planned: 1000, reason: 'early'),
      row('long', '2026-10-19T02:00:00Z',
          seconds: 900, planned: 3600, reason: 'early'),
    ], week);
    expect(r.interruptionStages, [2, 3, 2, 2]);
  });

  test('paused time never increases focus or interruption progress', () {
    final a = DateTime.parse('2026-10-19T01:00:00Z');
    final r = buildReport([
      row('pause', a.toIso8601String(),
          planned: 1200,
          reason: 'early',
          ended: a.add(const Duration(hours: 2)),
          spans: [
            TimeSpan(a, a.add(const Duration(minutes: 2)))
          ],
          pauses: [
            TimeSpan(a.add(const Duration(minutes: 2)),
                a.add(const Duration(hours: 2)))
          ])
    ], week);
    expect(r.milliseconds, 120000);
    expect(r.interruptionStages, [1, 0, 0, 0]);
    expect(r.hourlyInterruptions[11], 1);
    expect(r.hourly[10], 0);
  });

  test(
      'cross period counts by end, progress by entire session not clipped part',
      () {
    final s = row('year', '2026-12-31T15:50:00Z',
        seconds: 1200, planned: 1500, reason: 'sleep');
    final old =
        buildReport([s], ReportPeriod(PeriodKind.year, DateTime.utc(2026)));
    final next =
        buildReport([s], ReportPeriod(PeriodKind.year, DateTime.utc(2027)));
    expect(old.hourly[23], 600000);
    expect(next.hourly[0], 600000);
    expect(old.interrupted, 0);
    expect(next.interrupted, 1);
    expect(next.interruptionStages, [0, 0, 0, 1]);
    expect(old.sampleCount, 1);
    expect(next.sampleCount, 1);
  });

  test('ended exactly at week boundary counts only in following period', () {
    final s = row('boundary', '2026-10-25T15:50:00Z', seconds: 600);
    final r = buildReport([s], week);
    final next = buildReport([s], week.next);
    expect(r.completed, 0);
    expect(next.completed, 1);
    expect(next.topSubjects.single.milliseconds, 0);
    expect(next.topSubjects.single.records, 1);
    expect(next.hourly.every((n) => n == 0), true);
  });

  test('top subjects rank by completed count then duration then name', () {
    final rows = [
      for (var i = 0; i < 2; i++)
        row('math$i', '2026-10-19T01:00:00Z', category: '数学'),
      row('physics', '2026-10-19T02:00:00Z', category: '物理', seconds: 1200),
      row('physicsEarly', '2026-10-19T03:00:00Z',
          category: '物理', seconds: 300, planned: 1200, reason: 'early'),
      row('a', '2026-10-19T04:00:00Z', category: 'A'),
      row('b', '2026-10-19T05:00:00Z', category: 'B'),
      row('none', '2026-10-19T06:00:00Z', category: '', seconds: 3600),
      row('unfinishedOnly', '2026-10-19T06:00:00Z',
          category: '仅中断', seconds: 3600, reason: 'early'),
    ];
    final r = buildReport(rows, week);
    expect(r.topSubjects.map((s) => s.name), ['数学', '物理', 'A']);
    expect(r.topSubjects[1].completed, 1);
    expect(r.topSubjects[1].milliseconds, 1500000);
    expect(r.topSubjects[1].hourly[11], 300000);
    expect(r.unclassifiedRecords, 1);
    expect(r.category['未分类'], 3600000);
  });

  test('incomplete only, excluded, and empty periods have no false rankings',
      () {
    final r = buildReport([
      row('a', '2026-10-19T01:00:00Z', reason: 'early'),
      row('b', '2026-10-19T02:00:00Z', excluded: true),
    ], week);
    expect(r.topSubjects, isEmpty);
    expect(r.sampleCount, 1);
    expect(r.subjects['数学']!.records, 1);
    final empty = buildReport([], week);
    expect(empty.topSubjects, isEmpty);
    expect(empty.interruptionStages, [0, 0, 0, 0]);
    expect(empty.advice.single, contains('样本不足'));
  });

  test('month and leap day share hourly and completed-count semantics', () {
    final r = buildReport([row('leap', '2024-02-29T15:50:00Z', seconds: 1200)],
        ReportPeriod(PeriodKind.month, DateTime.utc(2024, 2)));
    expect(r.milliseconds, 600000);
    expect(r.hourly[23], 600000);
    expect(r.completed, 0);
    expect(r.topSubjects, isEmpty);
  });
}
