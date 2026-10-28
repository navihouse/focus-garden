import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/data/backup.dart';
import 'package:focus_garden/data/store.dart';
import 'package:focus_garden/domain/models.dart';
import 'package:focus_garden/domain/music_library.dart';
import 'package:focus_garden/domain/timer_engine.dart';
import 'package:focus_garden/main.dart';
import 'package:focus_garden/music_library_page.dart';

Json song(String id) =>
    {'id': id, 'name': '$id.wav', 'path': 'D:/StudyMusic/$id.wav'};

class QueueController extends AppController {
  final queues = <List<String>>[];
  @override
  Future<void> syncMusicQueue(
      {bool resume = false, bool keepPosition = false}) async {
    queues.add(tracks.map((t) => t['path'] as String).toList());
    playing = resume && canPlayMusic && !muted && tracks.isNotEmpty;
  }
}

class RejectingStore extends LocalStore {
  bool reject = false;
  RejectingStore() : super.testing(NativeDatabase.memory());
  @override
  Future<void> put(String id, Object value) {
    if (reject && id == 'musicLibrary') {
      throw StateError('simulated disk write failure');
    }
    return super.put(id, value);
  }
}

class AndroidMusicController extends AppController {
  @override
  bool get android => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> waitForUi(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 60 && !ready(); i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)));
    }
    expect(ready(), true);
    await tester.pumpAndSettle();
  }

  late QueueController c;
  setUp(() {
    c = QueueController()..store = LocalStore.testing(NativeDatabase.memory());
  });
  tearDown(() async {
    await c.store.close();
    c.dispose();
  });
  test(
      'legacy library migrates once without copying, dropping or duplicating songs',
      () async {
    final legacy = [song('one'), song('two')];
    await c.store.put('tracks', legacy);
    await c.loadMusicLibrary();
    expect(c.playlists.single.name, '默认歌单');
    expect(c.tracks, legacy);
    expect(await c.store.get('tracks'), legacy);
    final id = await c.createPlaylist('钢琴');
    await c.importMusicFiles(id, [song('three')]);
    final other = QueueController()..store = c.store;
    addTearDown(other.dispose);
    await other.loadMusicLibrary();
    expect(other.currentPlaylist.id, id);
    expect(other.tracks.single['name'], 'three.wav');
    expect(other.playlists.first.tracks, legacy);
    expect(other.playlists.length, 2);
  });
  test(
      'switch, repeat preferences, rename, remove and delete stay within selected playlist',
      () async {
    c.tracks = [song('a'), song('b')];
    await c.saveTracks();
    final first = c.currentPlaylist.id;
    final second = await c.createPlaylist('雨声');
    await c.importMusicFiles(second, [song('rain')]);
    c.shuffle = true;
    c.repeat = 'one';
    c.playing = true;
    await c.selectPlaylist(first);
    expect(c.queues.last, ['D:/StudyMusic/a.wav', 'D:/StudyMusic/b.wav']);
    expect(c.playing, true);
    expect(c.trackIndex, 0);
    expect(c.shuffle, true);
    expect(c.repeat, 'one');
    final reloads = c.queues.length;
    await c.renamePlaylist(first, '轻音乐');
    expect(c.queues.length, reloads);
    await c.deletePlaylist(second);
    expect(c.queues.length, reloads);
    expect(c.playing, true);
    await c.removeTrack(first, 'a');
    expect(c.queues.last, ['D:/StudyMusic/b.wav']);
    await c.deletePlaylist(first);
    expect(c.queues.last, isEmpty);
    expect(c.playing, false);
    expect(c.playlists.single.name, '默认歌单');
    expect(c.tracks, isEmpty);
  });
  test(
      'empty playlist stops audio; paused timer and rests never resume after switching',
      () async {
    c.tracks = [song('a')];
    await c.saveTracks();
    final first = c.currentPlaylist.id;
    final empty = await c.createPlaylist('空歌单');
    c.playing = true;
    await c.selectPlaylist(first);
    await c.selectPlaylist(empty);
    expect(c.queues.last, isEmpty);
    expect(c.playing, false);
    c.engine.start(
        id: 'focus',
        device: 'test',
        seconds: 1500,
        now: DateTime.now().toUtc(),
        tick: 0);
    c.engine.pause(DateTime.now().toUtc(), 0);
    c.playing = true;
    await c.selectPlaylist(first);
    expect(c.phase, Phase.paused);
    expect(c.playing, false);
    c.engine.finish(DateTime.now().toUtc(), 0);
    c.engine.startRest(300, 0);
    c.playing = true;
    await c.selectPlaylist(empty);
    await c.selectPlaylist(first);
    expect(c.phase, Phase.rest);
    expect(c.playing, false);
    expect(c.sessions, isEmpty);
  });
  test('moving and copying songs do not mix queues or remove referenced files',
      () async {
    final dir = await Directory.systemTemp.createTemp('playlist-fixture-');
    addTearDown(() => dir.delete(recursive: true));
    final file = await File('${dir.path}/sample.wav').writeAsString('fixture');
    await c.importMusicFiles(c.currentPlaylist.id, [
      {'name': 'Sample', 'path': file.path}
    ]);
    final first = c.currentPlaylist.id, track = c.tracks.single['id'] as String;
    final second = await c.createPlaylist('第二份');
    await c.transferTrack(first, track, second, copy: true);
    expect(c.tracks.length, 1);
    await c.transferTrack(first, track, second, copy: true);
    expect(c.tracks.length, 1);
    await c.transferTrack(first, track, second, copy: false);
    expect(c.playlists.first.tracks, isEmpty);
    expect(c.tracks.length, 1);
    expect(await file.readAsString(), 'fixture');
    await c.deletePlaylist(second);
    expect(await file.exists(), true);
  });
  test(
      'duplicate paths skip import; invalid names and corrupt libraries preserve existing data',
      () async {
    final first = c.currentPlaylist.id;
    await c.importMusicFiles(first, [song('a'), song('a')]);
    expect(c.tracks.length, 1);
    await expectLater(c.createPlaylist('  '), throwsFormatException);
    await expectLater(c.createPlaylist('默认歌单'), throwsFormatException);
    await expectLater(c.createPlaylist('x' * 81), throwsFormatException);
    await c.store.put('musicLibrary', {'version': 99});
    await expectLater(c.loadMusicLibrary(), throwsFormatException);
    expect(c.tracks.length, 1);
    expect(await c.store.get('musicLibrary'), {'version': 99});
    final bad = MusicLibrary.empty().toJson()..['selectedId'] = 'missing';
    expect(() => MusicLibrary.fromJson(bad), throwsFormatException);
    expect(exportBackup([], []), isNot(contains('playlists')));
  });
  test(
      'failed persistence leaves current playlist and playback queue unchanged',
      () async {
    final db = RejectingStore();
    final other = QueueController()..store = db;
    addTearDown(db.close);
    addTearDown(other.dispose);
    other.tracks = [song('a')];
    await other.saveTracks();
    final saved = await db.get('musicLibrary');
    db.reject = true;
    await expectLater(other.createPlaylist('No save'), throwsStateError);
    expect(other.playlists.length, 1);
    expect(other.tracks.single['id'], 'a');
    expect(await db.get('musicLibrary'), saved);
    expect(other.queues.length, 1);
  });
  test(
      'shuffle queue order maps song identity; out-of-folder queues are rejected',
      () {
    c.tracks = [song('a'), song('b'), song('c')];
    final shuffled = Playlist([
      Media(song('c')['path']),
      Media(song('a')['path']),
      Media(song('b')['path'])
    ], index: 0);
    expect(c.queueMatchesPlaylist(shuffled), true);
    expect(c.canonicalTrackIndex(shuffled.medias[0].uri), 2);
    expect(c.queueMatchesPlaylist(Playlist([Media('D:/other.wav')])), false);
  });
  test('Windows extended paths, file URIs and raw paths identify the same song',
      () {
    c.tracks = [song('a'), song('b')];
    final key = c.musicMediaKey('D:/StudyMusic/a.wav');
    expect(c.musicMediaKey(r'\\?\D:\StudyMusic\a.wav'), key);
    expect(c.musicMediaKey('//?/d:/StudyMusic/a.wav'), key);
    expect(c.musicMediaKey('file:///D:/StudyMusic/a.wav'), key);
    expect(c.canonicalTrackIndex('//?/D:/StudyMusic/b.wav'), 1);
    expect(
        c.queueMatchesPlaylist(Playlist(
            [Media('D:/StudyMusic/a.wav'), Media('D:/StudyMusic/a.wav')])),
        false);
  }, skip: !Platform.isWindows);
  test(
      'Android channel receives only selected folder and explicit playback/mode rules',
      () async {
    final android = AndroidMusicController()
      ..store = LocalStore.testing(NativeDatabase.memory());
    addTearDown(android.store.close);
    addTearDown(android.dispose);
    final sent = <Json>[];
    Json state = {
      'phase': 'focus',
      'musicPlaying': true,
      'trackIndex': 0,
      'events': []
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, (call) async {
      if (call.method == 'playlist') {
        final args = asJson(call.arguments);
        sent.add(args);
        state = {
          ...state,
          'playlistId': args['playlistId'],
          'musicPlaying': args['play']
        };
      }
      if (call.method == 'state') return state;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.native, null));
    android.androidState = state;
    android.tracks = [song('a')];
    await android.saveTracks();
    final first = android.currentPlaylist.id;
    final second = await android.createPlaylist('Only rain');
    android.tracks = [song('rain')];
    await android.saveTracks();
    android.playing = true;
    android.shuffle = true;
    android.repeat = 'off';
    await android.selectPlaylist(first);
    expect((sent.last['tracks'] as List).single['id'], 'a');
    expect(sent.last['play'], true);
    expect(sent.last['shuffle'], true);
    expect(sent.last['repeat'], 'off');
    android.androidState = {...state, 'phase': 'rest', 'isRest': true};
    android.playing = true;
    await android.selectPlaylist(second);
    expect(sent.last['play'], false);
    expect((sent.last['tracks'] as List).single['id'], 'rain');
    await android.deletePlaylist(second);
    expect(sent.last['play'], false);
  });

  for (final size in [const Size(1180, 1000), const Size(390, 844)]) {
    for (final brightness in Brightness.values) {
      testWidgets(
          'folder management and selected-song view fit $size $brightness',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final first = c.currentPlaylist.id;
        c.tracks = [song('first-song')];
        await c.saveTracks();
        final second = await c.createPlaylist('轻爵士与钢琴的专注歌单');
        c.tracks = [song('rain-song')];
        await c.saveTracks();
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
                body: MusicLibraryPage(c,
                    playerBuilder: () => const Text('Playback controls')))));
        await tester.pumpAndSettle();
        expect(find.text('rain-song.wav'), findsOneWidget);
        expect(find.text('first-song.wav'), findsNothing);
        final folder = find.byKey(ValueKey('playlist-$first'));
        await tester.ensureVisible(folder);
        await tester.tap(folder);
        await waitForUi(tester, () => c.currentPlaylist.id == first);
        await tester.pumpAndSettle();
        expect(c.currentPlaylist.id, first);
        expect(find.text('first-song.wav'), findsOneWidget);
        expect(find.text('rain-song.wav'), findsNothing);
        final menu = find.byKey(ValueKey('song-menu-first-song'));
        await tester.ensureVisible(menu);
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text('复制到歌单'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('transfer-to-$second')));
        await waitForUi(
            tester,
            () =>
                c.playlists.firstWhere((p) => p.id == second).tracks.length ==
                2);
        await tester.pumpAndSettle();
        expect(c.playlists.firstWhere((p) => p.id == second).tracks.length, 2);
        await tester.ensureVisible(find.byKey(const ValueKey('new-playlist')));
        await tester.tap(find.byKey(const ValueKey('new-playlist')));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey('playlist-name')), '环境音');
        await tester.tap(find.text('创建并打开'));
        await waitForUi(tester, () => c.currentPlaylist.name == '环境音');
        await tester.pumpAndSettle();
        expect(c.currentPlaylist.name, '环境音');
        expect(c.tracks, isEmpty);
        expect(find.textContaining('这个歌单还没有歌曲'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('focus page can choose playlist while timer remains active',
      (tester) async {
    tester.view.physicalSize = const Size(1180, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final first = c.currentPlaylist.id;
    c.tracks = [song('a')];
    await c.saveTracks();
    await c.createPlaylist('钢琴');
    c.tracks = [song('piano')];
    await c.saveTracks();
    c.engine.start(
        id: 'focus',
        device: 'test',
        seconds: 1500,
        now: DateTime.now().toUtc(),
        tick: c.clock.elapsedMilliseconds);
    await tester.pumpWidget(MaterialApp(
        home:
            ListenableBuilder(listenable: c, builder: (_, child) => Home(c))));
    await tester.pumpAndSettle();
    final dropdown =
        find.byKey(ValueKey('playing-playlist-${c.currentPlaylist.id}'));
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('默认歌单').last);
    await waitForUi(tester, () => c.currentPlaylist.id == first);
    await tester.pumpAndSettle();
    expect(c.currentPlaylist.id, first);
    expect(c.phase, Phase.focus);
    expect(
        c.engine
            .snapshot(DateTime.now().toUtc(), c.clock.elapsedMilliseconds)!
            .id,
        'focus');
  });
}
