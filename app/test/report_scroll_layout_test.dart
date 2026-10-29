import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/domain/reports.dart';
import 'package:focus_garden/main.dart';
import 'package:focus_garden/report_charts.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_PREVIEWS');
  setUpAll(() async {
    if (!capture) return;
    final loader = FontLoader('Preview Chinese')
      ..addFont(Future.value(ByteData.sublistView(
          File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync())));
    await loader.load();
  });

  for (final width in [310.0, 1000.0]) {
    testWidgets(
        'drag scrollbar reaches October 31 and changing month resets $width',
        (tester) async {
      tester.view.physicalSize = Size(width + 48, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget page(Map<String, int> values) => MaterialApp(
          home: Scaffold(
              body: Padding(
                  padding: const EdgeInsets.all(24), child: BarChart(values))));
      await tester
          .pumpWidget(page({for (var d = 1; d <= 31; d++) '10/$d': d * 60000}));
      await tester.pumpAndSettle();
      final scrollbar = find.byType(Scrollbar);
      expect(tester.widget<Scrollbar>(scrollbar).thumbVisibility, isTrue);
      final state = tester.state<ScrollableState>(find.byType(Scrollable));
      final track = tester.getRect(scrollbar);
      expect(state.position.maxScrollExtent, greaterThan(0));
      // Use the actual thumb instead of programmatically scrolling the chart.
      await tester.dragFrom(Offset(track.left + 24, track.bottom - 4),
          Offset(track.width - 32, 0));
      await tester.pumpAndSettle();
      expect(state.position.pixels, closeTo(state.position.maxScrollExtent, 1));
      final last = tester.getRect(find.text('10/31'));
      expect(last.center.dx, inInclusiveRange(track.left, track.right));
      await tester.tap(find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == '10/31：31.0 分钟'));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('10/31：31.0 分钟'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(page({for (var d = 1; d <= 28; d++) '2/$d': 0}));
      await tester.pumpAndSettle();
      expect(state.position.pixels, 0);
      expect(find.text('10/31'), findsNothing);
      expect(tester.getRect(find.text('2/1')).center.dx,
          inInclusiveRange(track.left, track.right));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('empty and fitting charts do not advertise scrolling',
      (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: Scaffold(body: BarChart({}))));
    expect(find.text('暂无数据'), findsOneWidget);
    expect(find.byType(Scrollbar), findsNothing);
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BarChart({'一': 0, '二': 60000}))));
    await tester.pumpAndSettle();
    expect(tester.widget<Scrollbar>(find.byType(Scrollbar)).thumbVisibility,
        isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final width in [390.0, 1180.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('monthly heatmap and trend placement $width $brightness',
          (tester) async {
        tester.view.physicalSize = Size(width, 960);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final report = buildReport(
            [], ReportPeriod(PeriodKind.month, DateTime.utc(2026, 10)));
        for (var d = 20; d <= 29; d++) {
          final minutes = [180, 20, 60, 90, 40, 240, 120, 90, 110, 45][d - 20];
          report.daily['2026-10-$d'] = minutes * 60000;
          report.milliseconds += minutes * 60000;
        }
        final boundary = GlobalKey();
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData(
                brightness: brightness,
                colorSchemeSeed: const Color(0xff476e58),
                fontFamily: capture ? 'Preview Chinese' : null),
            home: Scaffold(
                body: SingleChildScrollView(
                    child: RepaintBoundary(
                        key: boundary,
                        child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Card(
                                child: Padding(
                                    padding: const EdgeInsets.all(20),
                                    child: MonthlyFocusOverview(report)))))))));
        await tester.pumpAndSettle();
        final heat = tester.getRect(find.text('本月专注热力图'));
        final trend = tester.getRect(find.text('每日专注趋势（分钟）'));
        if (width > 700) {
          expect(trend.top, closeTo(heat.top, 1));
          expect(trend.left, greaterThan(heat.right));
        } else {
          expect(trend.top,
              greaterThan(tester.getRect(find.byType(Heatmap)).bottom));
        }
        final track = tester.getRect(find.byType(Scrollbar));
        expect(track.right, lessThanOrEqualTo(width));
        expect(tester.widget<Scrollbar>(find.byType(Scrollbar)).thumbVisibility,
            isTrue);
        if (capture) {
          await tester.runAsync(() async {
            final render = boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
            final picture = await render.toImage();
            final bytes =
                await picture.toByteData(format: ui.ImageByteFormat.png);
            final dir = Directory('P:/work/previews/report-layout-1.9.1')
              ..createSync(recursive: true);
            File('${dir.path}/${width.toInt()}-${brightness.name}.png')
                .writeAsBytesSync(bytes!.buffer.asUint8List());
            picture.dispose();
          });
        }
        await tester.dragFrom(Offset(track.left + 24, track.bottom - 4),
            Offset(track.width - 32, 0));
        await tester.pumpAndSettle();
        final last = tester.getRect(find.text('10/31'));
        expect(last.center.dx, inInclusiveRange(track.left, track.right));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
