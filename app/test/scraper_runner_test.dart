import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/automation_controller.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/domain/automation.dart';
import 'package:focus_garden/domain/timer_engine.dart';
import 'package:focus_garden/study_scraper.dart';
import 'automation_test.dart' show FixtureScraper, scrapeFixture, studyFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PythonStudyScraperRunner runner;
  late AutomationSettings config;
  final payload = scrapeFixture([studyFixture()]);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('focus python 中文 ');
    runner = PythonStudyScraperRunner();
    final cookie = File('${root.path}/测试 cookie.txt');
    await cookie.writeAsString('synthetic-cookie-not-a-real-session');
    final script = File('${root.path}/模拟脚本.py');
    await script.writeAsString('''
import argparse, json, pathlib, sys
p=argparse.ArgumentParser()
p.add_argument('--source'); p.add_argument('--chaoxing-cookie')
p.add_argument('--icourse163-cookie'); p.add_argument('--out-dir')
p.add_argument('--quiet', action='store_true')
p.add_argument('--workers'); p.add_argument('--timeout')
p.add_argument('--ignore-expired-days')
a=p.parse_args()
assert a.source=='chaoxing' and pathlib.Path(a.chaoxing_cookie).is_file()
assert a.quiet and a.workers=='2' and a.timeout=='20'
assert a.ignore_expired_days=='0'
out=pathlib.Path(a.out_dir); out.mkdir(parents=True, exist_ok=True)
(out/'todos.json').write_text(${jsonEncode(payload)}, encoding='utf-8')
''');
    config = AutomationSettings(
        scriptPath: script.path, chaoxingCookiePath: cookie.path, mooc: false);
  });
  tearDown(() async {
    runner.cancel();
    await root.delete(recursive: true);
  });

  test(
      'Python runner handles Unicode paths and passes isolated argument values',
      () async {
    final result = await runner.run(config, Directory('${root.path}/输出 文件夹'));
    expect(result.assignments.single.title, '数学作业');
  });

  test('Python runner forwards the custom expiry window', () async {
    final script = File(config.scriptPath);
    await script.writeAsString((await script.readAsString()).replaceAll(
        "a.ignore_expired_days=='0'", "a.ignore_expired_days=='14'"));
    final result = await runner.run(config.copyWith({'expiredAfterDays': 14}),
        Directory('${root.path}/custom-expiry'));
    expect(result.assignments.length, 1);
  });

  test('failed process cannot import an otherwise valid result', () async {
    await File(config.scriptPath)
        .writeAsString('\nsys.exit(2)\n', mode: FileMode.append);
    await expectLater(
        runner.run(config, Directory('${root.path}/failed')),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'explanation', contains('Cookie'))));
  });

  test('missing Cookie fails before any output directory is created', () async {
    await File(config.chaoxingCookiePath).delete();
    final output = Directory('${root.path}/missing');
    await expectLater(runner.run(config, output), throwsFormatException);
    expect(await output.exists(), false);
  });

  test('runner cancellation terminates its own child and releases files',
      () async {
    await File(config.scriptPath).writeAsString('''
import pathlib, time
pathlib.Path('started').write_text('ready')
time.sleep(60)
''');
    final running = runner.run(config, Directory('${root.path}/cancelled'));
    final expectation = expectLater(running, throwsFormatException);
    for (var i = 0; i < 200; i++) {
      if (await File('${root.path}/started').exists()) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await File('${root.path}/started').exists(), true);
    runner.cancel();
    await expectation;
  });

  test('a slow scrape does not block focus controls or checkpoint writes',
      () async {
    final c = AppController()
      ..store = LocalStore.testing(NativeDatabase.memory());
    final fake = FixtureScraper()..pending = Completer<ScrapePayload>();
    final service = AutomationController(
        store: c.store,
        directory: root,
        tasks: () => c.tasks,
        serialize: (action) => c.perform(action),
        refreshTasks: c.refresh,
        runner: fake,
        supportsScraper: true,
        now: () => DateTime.utc(2026, 11, 13));
    final running = service.runScraper();
    await c.perform(() => c.startFocus(testSeconds: 90));
    expect(c.phase, Phase.focus);
    await c.perform(c.pauseResume);
    expect(c.phase, Phase.paused);
    expect(await c.store.get('checkpoint'), isNotNull);
    expect(service.scraping, true);
    fake.pending!.complete(ScrapePayload.parse(payload));
    await running;
    expect(c.tasks.single.name, '数学作业');
    await service.shutdown();
    service.dispose();
    c.dispose();
    await c.store.close();
  });
}
