import 'dart:io';
import 'dart:ui' as ui;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/main.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/domain/models.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_PREVIEWS');
  setUpAll(() async {
    // Each test uses a separate in-memory database, not shared executors.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    if (capture && File('C:/Windows/Fonts/msyh.ttc').existsSync()) {
      final loader = FontLoader('Preview Chinese');
      loader.addFont(Future.value(ByteData.sublistView(
          File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync())));
      await loader.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(Future.value(ByteData.sublistView(File(
              'P:/work/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf')
          .readAsBytesSync())));
      await icons.load();
    }
  });
  for (final variant in [
    (const Size(1180, 900), Brightness.light),
    (const Size(390, 844), Brightness.light),
    (const Size(390, 844), Brightness.dark)
  ]) {
    final size = variant.$1;
    testWidgets(
        'five pages and year heatmap fit ${size.width} ${variant.$2.name}',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = AppController()
        ..store = LocalStore.testing(NativeDatabase.memory());
      addTearDown(c.store.close);
      c.tasks = [
        TaskItem(
            id: 'task',
            name: '学习数学',
            category: '数学',
            modified: DateTime.utc(2026))
      ];
      final boundary = GlobalKey();
      Future<void> screenshot(String page) async {
        if (!capture) return;
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final render = boundary.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
          final image = await render.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final folder = Directory('P:/work/previews')
            ..createSync(recursive: true);
          File('${folder.path}/$page-${size.width.toInt()}-${variant.$2.name}.png')
              .writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      await tester.pumpWidget(RepaintBoundary(
          key: boundary,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                  useMaterial3: true,
                  brightness: variant.$2,
                  colorSchemeSeed: const Color(0xff476e58),
                  fontFamily: capture ? 'Preview Chinese' : null,
                  scaffoldBackgroundColor: variant.$2 == Brightness.light
                      ? const Color(0xfff6f7f2)
                      : const Color(0xff141a17)),
              locale: const Locale('zh', 'CN'),
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              supportedLocales: const [Locale('zh', 'CN')],
              home: Home(c))));
      expect(find.text('开始专注'), findsOneWidget);
      await screenshot('focus');
      for (final page in ['任务', '音乐库', '历史记录', '统计报告']) {
        await tester.tap(find.text(page).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (page == '任务') {
          await tester.tap(find.text('学习数学'));
          await tester.pumpAndSettle();
          await tester.enterText(
              find.byKey(const ValueKey('new-subtask')), '复习PPT');
          await tester.tap(find.byTooltip('添加子任务'));
          await tester.pump();
          await tester.enterText(
              find.byKey(const ValueKey('new-subtask')), '整理笔记');
          await tester.tap(find.byTooltip('添加子任务'));
          await tester.pump();
          await tester.tap(find.byType(Checkbox).first);
          await tester.ensureVisible(find.byKey(const ValueKey('task-notes')));
          await tester.enterText(
              find.byKey(const ValueKey('task-notes')), '先复习概念\n再完成课后练习');
          await tester.pumpAndSettle();
          await screenshot('task-details');
          await tester.tap(find.text('保存'));
          await tester.pumpAndSettle();
          expect(c.tasks.single.subtasks.length, 2);
          expect(c.tasks.single.subtasks.first.completed, true);
          expect(c.tasks.single.notes, '先复习概念\n再完成课后练习');
          expect((await c.store.tasks()).single.subtasks.last.name, '整理笔记');
          expect(tester.takeException(), isNull);
        }
      }
      await screenshot('reports');
      await tester.tap(find.text('年报'));
      await tester.pumpAndSettle();
      expect(find.text('累计专注'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('专注').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('专注设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
