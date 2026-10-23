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

  testWidgets('count chart uses counts and percentage instead of minutes',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BarChart({'13时': 2}, counts: true, total: 4))));
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, '13时：2 次（50.0%）');
    await tester.tap(find.byType(Tooltip));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('13时：2 次（50.0%）'), findsOneWidget);
    expect(find.textContaining('分钟'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: BarChart(
      {for (var h = 0; h < 24; h++) '$h时': h == 20 ? 2 : 0},
      counts: true,
      compact: true,
      total: 2,
    ))));
    await tester.pumpAndSettle();
    for (final tooltip in find.byType(Tooltip).evaluate()) {
      final box = tester.getRect(find.byWidget(tooltip.widget));
      expect(box.left, greaterThanOrEqualTo(0));
      expect(box.right, lessThanOrEqualTo(390));
    }
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(1180, 900), const Size(390, 844)]) {
    for (final brightness in Brightness.values) {
      testWidgets('period analysis fits $size $brightness', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = AppController();
        addTearDown(controller.dispose);
        final monday =
            ReportPeriod(PeriodKind.week, beijing(DateTime.now())).start;
        final start =
            civilUtc(monday).add(const Duration(hours: 9, minutes: 50));
        controller.sessions = List.generate(8, (i) {
          final a = start.add(Duration(hours: i));
          final done = i < 4;
          final duration = Duration(minutes: done ? 25 : 5 * (i - 3));
          final b = a.add(duration);
          return FocusSession.fromJson(FocusSession(
            id: 'fixture$i',
            device: 'fixture',
            category: ['数学', '物理', '英语', '数学'][i % 4],
            plannedSeconds: 1500,
            started: a,
            ended: b,
            spans: [TimeSpan(a, b)],
            completed: done,
            reason: done
                ? 'completed'
                : interruptionReasonLabels.keys.elementAt(i - 4),
          ).toJson());
        });
        final boundary = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                  useMaterial3: true,
                  brightness: brightness,
                  colorSchemeSeed: const Color(0xff476e58),
                  fontFamily: capture ? 'Preview Chinese' : null),
              home: Scaffold(body: ReportsPage(controller)),
            )));
        final scrollable = find.byType(Scrollable).first;
        for (final period in ['周报', '月报', '年报']) {
          tester.state<ScrollableState>(scrollable).position.jumpTo(0);
          await tester.pumpAndSettle();
          await tester.tap(find.text(period));
          await tester.pumpAndSettle();
          for (final title in ['活跃与低投入时段', '中断发生在什么时候', '完整番茄数前三科目 / 项目']) {
            await tester.scrollUntilVisible(find.text(title), 400,
                scrollable: scrollable);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            if (capture && period == '周报') {
              await tester.runAsync(() async {
                final render = boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
                final picture = await render.toImage();
                final bytes =
                    await picture.toByteData(format: ui.ImageByteFormat.png);
                final directory = Directory('P:/work/previews/analysis-1.4.0')
                  ..createSync(recursive: true);
                final section = title == '活跃与低投入时段'
                    ? 'activity'
                    : title == '中断发生在什么时候'
                        ? 'interruptions'
                        : 'subjects';
                File('${directory.path}/$section-${size.width.toInt()}-${brightness.name}.png')
                    .writeAsBytesSync(bytes!.buffer.asUint8List());
                picture.dispose();
              });
            }
          }
          expect(find.text('完整番茄数前三科目 / 项目'), findsOneWidget);
          await tester.scrollUntilVisible(find.text('基于记录的观察'), 300,
              scrollable: scrollable);
          expect(tester.takeException(), isNull);
        }
        // Removing all records updates every panel without stale subject ranks.
        controller.sessions = [];
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(body: ReportsPage(controller))));
        await tester.scrollUntilVisible(find.text('活跃与低投入时段'), 400,
            scrollable: find.byType(Scrollable).first);
        expect(find.textContaining('样本不足：本期 0 次'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('本期暂无未完成记录'), 300,
            scrollable: find.byType(Scrollable).first);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
