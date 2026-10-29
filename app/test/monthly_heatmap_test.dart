import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/domain/reports.dart';
import 'package:focus_garden/main.dart';

FocusSession session(String id, DateTime start, DateTime end,
        {bool excluded = false, List<TimeSpan>? spans}) =>
    FocusSession(
        id: id,
        device: 'fixture',
        plannedSeconds: 1500,
        started: start,
        ended: end,
        spans: spans ?? [TimeSpan(start, end)],
        completed: false,
        reason: 'early',
        excluded: excluded);

void main() {
  const capture = bool.fromEnvironment('CAPTURE_PREVIEWS');
  setUpAll(() async {
    if (!capture) return;
    final loader = FontLoader('Preview Chinese')
      ..addFont(Future.value(ByteData.sublistView(
          File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync())));
    await loader.load();
  });

  test('monthly daily values clip Beijing midnight and omit invalid records',
      () {
    final start = DateTime.parse('2024-02-29T15:50:00Z');
    final end = start.add(const Duration(minutes: 20));
    final rows = [
      session('cross-month', start, end),
      session('paused', DateTime.parse('2024-02-15T00:00:00Z'),
          DateTime.parse('2024-02-15T00:20:00Z'),
          spans: [
            TimeSpan(DateTime.parse('2024-02-15T00:00:00Z'),
                DateTime.parse('2024-02-15T00:05:00Z')),
            TimeSpan(DateTime.parse('2024-02-15T00:15:00Z'),
                DateTime.parse('2024-02-15T00:20:00Z')),
          ]),
      session('short', start, start.add(const Duration(seconds: 59))),
      session('excluded', start, end, excluded: true),
    ];
    final february = buildReport(
        rows, ReportPeriod(PeriodKind.month, DateTime.utc(2024, 2)));
    expect(february.daily, {'2024-02-15': 600000, '2024-02-29': 600000});
    final march = buildReport(
        rows, ReportPeriod(PeriodKind.month, DateTime.utc(2024, 3)));
    expect(march.daily, {'2024-03-01': 600000});
  });

  for (final month in [
    DateTime.utc(2024, 2),
    DateTime.utc(2026, 2),
    DateTime.utc(2026, 4),
    DateTime.utc(2026, 3)
  ]) {
    testWidgets('month grid contains exactly the dates in $month',
        (tester) async {
      final period = ReportPeriod(PeriodKind.month, month);
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: Heatmap(buildReport([], period)))));
      final cells = find.byWidgetPredicate((widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('heatmap-'));
      expect(cells, findsNWidgets(period.end.difference(period.start).inDays));
      expect(find.byKey(ValueKey('heatmap-${dayKey(period.start)}')),
          findsOneWidget);
      final last = period.end.subtract(const Duration(days: 1));
      expect(find.byKey(ValueKey('heatmap-${dayKey(last)}')), findsOneWidget);
      expect(find.textContaining('本月暂无有效专注记录'), findsOneWidget);
      // Columns are weeks, rows run Monday to Sunday, including blank padding.
      final firstRect =
          tester.getRect(find.byKey(ValueKey('heatmap-${dayKey(month)}')));
      final mondayRect = tester.getRect(find.text('一'));
      expect(firstRect.center.dy - mondayRect.center.dy,
          closeTo((month.weekday - 1) * 35, 1));
      await tester.tap(find.byKey(ValueKey('heatmap-${dayKey(last)}')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('${dayKey(last)}：0.0 分钟'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [390.0, 1180.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('heatmap colors and tap details at $width $brightness',
          (tester) async {
        tester.view.physicalSize = Size(width, 500);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final period = ReportPeriod(PeriodKind.month, DateTime.utc(2026, 3));
        final report = buildReport([], period)
          ..daily.addAll({'2026-03-01': 600000, '2026-03-02': 1200000})
          ..milliseconds = 1800000;
        final boundary = GlobalKey();
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData(
                brightness: brightness,
                colorSchemeSeed: const Color(0xff476e58),
                fontFamily: capture ? 'Preview Chinese' : null),
            home: Scaffold(
                body: RepaintBoundary(
                    key: boundary,
                    child: Card(
                        child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('本月专注热力图 · 2026 年 3 月'),
                                  const SizedBox(height: 18),
                                  Heatmap(report)
                                ])))))));
        await tester.pumpAndSettle();
        final zero = tester.widget<Container>(
            find.byKey(const ValueKey('heatmap-2026-03-03')));
        final low = tester.widget<Container>(
            find.byKey(const ValueKey('heatmap-2026-03-01')));
        final high = tester.widget<Container>(
            find.byKey(const ValueKey('heatmap-2026-03-02')));
        expect((zero.decoration! as BoxDecoration).color,
            isNot((low.decoration! as BoxDecoration).color));
        expect((high.decoration! as BoxDecoration).color!.a,
            greaterThan((low.decoration! as BoxDecoration).color!.a));
        for (var day = 1; day <= 31; day++) {
          final rect = tester.getRect(find.byKey(
              ValueKey('heatmap-2026-03-${day.toString().padLeft(2, '0')}')));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
        }
        if (capture) {
          await tester.runAsync(() async {
            final render = boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
            final picture = await render.toImage();
            final bytes =
                await picture.toByteData(format: ui.ImageByteFormat.png);
            final dir = Directory('P:/work/previews/heatmap-1.9.0')
              ..createSync(recursive: true);
            File('${dir.path}/${width.toInt()}-${brightness.name}.png')
                .writeAsBytesSync(bytes!.buffer.asUint8List());
            picture.dispose();
          });
        }
        await tester.tap(find.byKey(const ValueKey('heatmap-2026-03-02')));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('2026-03-02：20.0 分钟'), findsOneWidget);
        await tester.pump(const Duration(seconds: 3));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('report switching and historical navigation refresh heatmap',
      (tester) async {
    final c = AppController();
    addTearDown(c.dispose);
    final current = ReportPeriod(PeriodKind.month, beijing(DateTime.now()));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ReportsPage(c))));
    final scrollable = find.byType(Scrollable).first;
    await tester.tap(find.text('月报'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('本月专注热力图'), 300,
        scrollable: scrollable);
    expect(tester.widget<Heatmap>(find.byType(Heatmap)).report.period.start,
        current.start);
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('上一周期'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('本月专注热力图'), 300,
        scrollable: scrollable);
    expect(tester.widget<Heatmap>(find.byType(Heatmap)).report.period.start,
        current.previous.start);
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('本期'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('年报'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('全年专注热力图'), 300,
        scrollable: scrollable);
    expect(tester.widget<Heatmap>(find.byType(Heatmap)).report.period.kind,
        PeriodKind.year);
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('周报'));
    await tester.pumpAndSettle();
    expect(find.byType(Heatmap), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
