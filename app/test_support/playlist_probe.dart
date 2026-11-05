// Opt-in native playback test with generated fixtures and an isolated database.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart' show MediaKit, PlaylistMode;
import 'package:focus_garden/app_controller.dart';
import 'package:focus_garden/domain/timer_engine.dart';

class PlaylistProbeController extends AppController {
  final hotkeyActions = <String>[];
  @override
  Future<void> handleHotkey(String action) async {
    hotkeyActions.add(action);
    await super.handleHotkey(action);
  }
}

Future<void> main() async {
  final directory = Platform.environment['FOCUS_PLAYLIST_PROBE_DIR'];
  if (directory == null || Platform.environment['FOCUS_NATIVE_PROBE'] != '1') {
    throw StateError('Explicit isolated probe environment required');
  }
  final checks = <String, bool>{};
  AppController? controller;
  Future<void> waitFor(String name, bool Function() condition) async {
    final watch = Stopwatch()..start();
    while (!condition() && watch.elapsedMilliseconds < 10000) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    checks[name] = condition();
    if (!checks[name]!) {
      final c = controller;
      final playlist = c?.player?.state.playlist;
      throw StateError(
          '$name; canonical=${c?.trackIndex}; native=${playlist?.index}; '
          'uris=${playlist?.medias.map((m) => m.uri).toList()}; repeat=${c?.repeat}; shuffle=${c?.shuffle}; message=${c?.message}; hotkeyActions=${c is PlaylistProbeController ? c.hotkeyActions : null}');
    }
  }

  try {
    WidgetsFlutterBinding.ensureInitialized();
    MediaKit.ensureInitialized();
    runApp(const SizedBox.shrink());
    final c = PlaylistProbeController();
    controller = c;
    await c.initialize(directory: Directory('$directory/data'));
    c.volume = 0;
    final first = c.currentPlaylist.id;
    final a = File('$directory/a.wav').path,
        b = File('$directory/b.wav').path,
        outside = File('$directory/outside.wav').path;
    List<String> queue() => c.player!.state.playlist.medias
        .map((m) => c.musicMediaKey(m.uri))
        .toList();
    String? current() {
      final p = c.player!.state.playlist;
      return p.index >= 0 && p.index < p.medias.length
          ? c.musicMediaKey(p.medias[p.index].uri)
          : null;
    }

    await c.perform(() => c.importMusicFiles(first, [
          {'name': 'A', 'path': a},
          {'name': 'B', 'path': b}
        ]));
    final second = await c.createPlaylist('环境音');
    await c.perform(() => c.importMusicFiles(second, [
          {'name': 'Outside', 'path': outside}
        ]));
    await c.perform(() => c.selectPlaylist(first));
    await c.perform(() => c.music('toggle'));
    await waitFor('firstFolderPlays',
        () => c.playing && c.player!.state.position.inMilliseconds > 200);
    await waitFor(
        'automaticNextStaysInFolder', () => current() == c.musicMediaKey(b));
    await waitFor(
        'folderLoopReturnsToFirst', () => current() == c.musicMediaKey(a));
    await waitFor(
        'secondCycleReachesLast', () => current() == c.musicMediaKey(b));
    await waitFor(
        'secondCycleReturnsToFirst', () => current() == c.musicMediaKey(a));
    if (Platform.environment['FOCUS_PROBE_SKIP_SHORTCUTS'] != '1') {
      if (c.hotkeyStatus['previous'] != true ||
          c.hotkeyStatus['next'] != true) {
        throw StateError(
            'Track hotkeys unavailable; no keyboard input will be sent');
      }
      await File('$directory/shortcut-previous-ready').writeAsString('{}');
      await waitFor(
          'rightArrowDispatchesPrevious',
          () =>
              c.hotkeyActions.contains('previous') &&
              current() == c.musicMediaKey(b));
      await File('$directory/shortcut-next-ready').writeAsString('{}');
      await waitFor(
          'leftArrowDispatchesNext',
          () =>
              c.hotkeyActions.contains('next') &&
              current() == c.musicMediaKey(a));
    }
    await c.perform(() => c.music('repeat')); // list -> single
    await c.perform(() => c.music('select', 1));
    await waitFor(
        'singleLoopNearsEnd',
        () =>
            current() == c.musicMediaKey(b) &&
            c.player!.state.position.inMilliseconds > 3200);
    await waitFor(
        'singleLoopRestartsSameTrack',
        () =>
            current() == c.musicMediaKey(b) &&
            c.player!.state.position.inMilliseconds < 700 &&
            c.playing);
    await c.perform(() => c.music('repeat')); // single -> list, never off
    checks['outsideNotQueued'] =
        !queue().contains(c.musicMediaKey(outside)) && queue().length == 2;
    await c.perform(() => c.music('shuffle'));
    final player = c.player!;
    checks['shuffleDisablesLoop'] =
        player.state.shuffle && player.state.playlistMode == PlaylistMode.none;
    checks['shuffleKeepsSelectedFolder'] =
        queue().toSet().containsAll([c.musicMediaKey(a), c.musicMediaKey(b)]) &&
            queue().length == 2;
    final shuffledFirst = queue().first, shuffledLast = queue().last;
    await c
        .perform(() => c.music('select', c.canonicalTrackIndex(shuffledFirst)));
    await waitFor(
        'shufflePlaysFirst', () => c.playing && current() == shuffledFirst);
    await waitFor(
        'shuffleAdvances', () => c.playing && current() == shuffledLast);
    await waitFor(
        'shuffleStopsAtEnd', () => !c.playing && player.state.completed);
    await c.perform(() => c.music('repeat'));
    checks['listLoopDisablesShuffle'] =
        !player.state.shuffle && player.state.playlistMode == PlaylistMode.loop;
    await c.perform(() => c.music('select', 1));
    await waitFor('listLoopPlaysAgain',
        () => c.playing && current() == c.musicMediaKey(b));
    await waitFor('listLoopWrapsAgain',
        () => c.playing && current() == c.musicMediaKey(a));
    await c.perform(() => c.selectPlaylist(second));
    await waitFor(
        'switchReplacesQueue',
        () =>
            queue().length == 1 &&
            current() == c.musicMediaKey(outside) &&
            c.playing);
    final empty = await c.createPlaylist('空歌单');
    await waitFor('emptyClearsQueue', () => queue().isEmpty && !c.playing);
    await c.perform(() => c.music('toggle'));
    checks['emptyCannotPlayPreviousFolder'] = !c.playing && queue().isEmpty;
    await c.perform(() => c.selectPlaylist(first));
    await c.perform(() => c.music('toggle'));
    await c.perform(() => c.startFocus(testSeconds: 90));
    await c.perform(c.pauseResume);
    await c.perform(() => c.handleHotkey('next'));
    checks['pausedTrackShortcutKeepsTimerPaused'] =
        !c.playing && c.phase == Phase.paused;
    await c.perform(() => c.selectPlaylist(second));
    await c.perform(() => c.music('select', 0));
    await waitFor(
        'pausedSwitchDoesNotPlay',
        () =>
            !c.playing &&
            c.phase == Phase.paused &&
            current() == c.musicMediaKey(outside));
    await c.perform(c.pauseResume);
    await waitFor(
        'resumeUsesSelectedFolder',
        () =>
            c.playing &&
            queue().length == 1 &&
            current() == c.musicMediaKey(outside));
    await c.perform(() => c.renamePlaylist(second, '环境音改名'));
    await c.perform(() => c.deletePlaylist(first));
    checks['inactiveDeleteKeepsAudio'] =
        c.playing && current() == c.musicMediaKey(outside);
    final track = c.tracks.single['id'] as String;
    await c.perform(() => c.transferTrack(second, track, empty, copy: true));
    checks['copyDoesNotSwitchQueue'] =
        c.playing && c.currentPlaylist.id == second && queue().length == 1;
    await c.perform(() => c.transferTrack(second, track, empty, copy: false));
    await waitFor('movingLastSongStopsOnlyCurrentFolder',
        () => queue().isEmpty && !c.playing && c.currentPlaylist.id == second);
    await c.perform(() => c.selectPlaylist(empty));
    await c.perform(() => c.music('toggle'));
    await waitFor('destinationPlaysMovedSong',
        () => c.playing && current() == c.musicMediaKey(outside));
    await c
        .perform(() => c.removeTrack(empty, c.tracks.single['id'] as String));
    await waitFor(
        'removingLastSongClearsQueue', () => queue().isEmpty && !c.playing);
    await c.perform(() => c.end());
    await c.perform(() => c.music('shuffle'));
    await c.shutdown();
    controller = null;
    final restored = AppController();
    controller = restored;
    await restored.initialize(directory: Directory('$directory/data'));
    checks['restartKeepsSelectedFolder'] =
        restored.currentPlaylist.id == empty &&
            restored.tracks.isEmpty &&
            restored.playlists.length == 2;
    checks['modesPersist'] = restored.shuffle && restored.repeat == 'off';
    checks['sourceFilesUnchanged'] =
        [a, b, outside].every((path) => File(path).existsSync());
    await restored.shutdown();
    controller = null;
    if (checks.values.any((ok) => !ok)) {
      throw StateError('Playback checks failed');
    }
    await File('$directory/result.json')
        .writeAsString(jsonEncode({'ok': true, 'checks': checks}));
    exit(0);
  } catch (e, stack) {
    try {
      await controller?.shutdown();
    } catch (_) {}
    await File('$directory/result.json').writeAsString(jsonEncode(
        {'ok': false, 'checks': checks, 'error': '$e', 'stack': '$stack'}));
    exit(1);
  }
}
