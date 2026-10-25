import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';
import 'data/store.dart';
import 'domain/models.dart';
import 'domain/timer_engine.dart';

class AppController extends ChangeNotifier {
  static const native = MethodChannel('focus_garden/native');
  static const uuid = Uuid();
  static Future<bool> playCompletionSound() async {
    try {
      await native.invokeMethod('taskCompleted');
      return true;
    } catch (_) {
      return false;
    }
  }

  late LocalStore store;
  late Directory dataDirectory;
  List<TaskItem> tasks = [];
  List<FocusSession> sessions = [];
  List<Json> tracks = [];
  Settings settings = const Settings();
  String device = '', message = '', recoveryMessage = '';
  String? selectedTask;
  bool focusPinned = false;
  final engine = TimerEngine();
  final clock = Stopwatch()..start();
  Player? player;
  Timer? _ticker;
  int _lastSave = 0, completedCycle = 0;
  bool _busy = false, muted = false, playing = false, shuffle = false;
  bool desktopIntegrationAvailable = false,
      startupEnabled = false,
      startupCurrentPath = false,
      startMenuAvailable = false;
  String repeat = 'all';
  Map<String, dynamic> hotkeyStatus = {};
  double volume = .6;
  int trackIndex = 0;
  Json androidState = {}, permissions = {};
  Future<void> _queue = Future.value();
  bool get android => Platform.isAndroid;
  Phase get phase => android
      ? switch (androidState['phase']) {
          'focus' => Phase.focus,
          'paused' => Phase.paused,
          'rest' => Phase.rest,
          'ended' => Phase.ended,
          _ => Phase.idle,
        }
      : engine.phase;
  bool get isRest => android ? androidState['isRest'] == true : engine.isRest;
  int get remainingMs => android
      ? (!active
          ? settings.focus * 60000
          : (androidState['remainingMs'] as num? ?? settings.focus * 60000)
              .toInt())
      : [Phase.idle, Phase.ended].contains(phase)
          ? settings.focus * 60000
          : engine.remaining(clock.elapsedMilliseconds);
  int get durationMs => !active
      ? settings.focus * 60000
      : android
          ? (androidState['durationMs'] as num? ?? settings.focus * 60000)
              .toInt()
          : isRest
              ? engine.restDurationMs
              : (engine.plannedSeconds > 0
                      ? engine.plannedSeconds
                      : settings.focus * 60) *
                  1000;
  bool get active => [Phase.focus, Phase.paused, Phase.rest].contains(phase);
  // Desktop users can preview imported files before creating a focus record.
  bool get canPlayMusic => phase == Phase.focus || (!android && !active);
  String get currentTaskName => android
      ? androidState['taskName'] as String? ?? '自由专注'
      : active && !isRest
          ? engine.taskName
          : (tasks.where((t) => t.id == selectedTask).firstOrNull?.name ??
              '自由专注');

  Future<void> initialize({Directory? directory}) async {
    dataDirectory = directory ?? await getApplicationSupportDirectory();
    await dataDirectory.create(recursive: true);
    store = LocalStore(File(p.join(dataDirectory.path, 'focus.sqlite')));
    final saved = await store.get('settings');
    if (saved != null) settings = Settings.fromJson(asJson(saved));
    device = (await store.get('device') as String?) ??
        '${Platform.operatingSystem}-${uuid.v4()}';
    await store.put('device', device);
    completedCycle = (await store.get('cycle') as int?) ?? 0;
    tracks = ((await store.get('tracks') as List?) ?? []).map(asJson).toList();
    volume = (await store.get('volume') as num?)?.toDouble() ?? .6;
    await refresh();
    if (android) {
      await native.invokeMethod('timerSettings', _breakSettings);
      await native.invokeMethod('recover');
      await pollAndroid();
      permissions = asJson(await native.invokeMethod('permissions'));
      await native.invokeMethod('playlist',
          {'tracks': tracks, 'index': trackIndex, 'volume': volume});
    } else {
      player = Player();
      player!.stream.error.listen((e) {
        message = '音乐播放失败：$e';
        notifyListeners();
      });
      player!.stream.playing.listen((v) {
        playing = v;
        notifyListeners();
      });
      player!.stream.playlist.listen((v) {
        trackIndex = v.index;
        notifyListeners();
      });
      try {
        await _loadWindowsPlaylist();
      } catch (e) {
        message = '音乐加载失败，请在音乐库重新添加文件：$e';
      }
      final checkpoint = await store.get('checkpoint');
      if (checkpoint != null) {
        await store.commitSession(FocusSession.fromJson(asJson(checkpoint)));
        recoveryMessage = '上次计时意外中断，已保留最后检查点的专注时间。';
        await refresh();
      }
      native.setMethodCallHandler((call) async {
        if (call.method == 'suspend') {
          await perform(() => end(reason: 'sleep', useCheckpoint: true));
        } else if (call.method == 'hotkey') {
          await perform(() => handleHotkey(call.arguments as String));
        }
      });
      if (Platform.isWindows) {
        try {
          // Isolated validation runs must not install a test shortcut.
          if (directory == null) {
            await native.invokeMethod('createStartMenuShortcut');
          }
          await refreshDesktopIntegration();
          hotkeyStatus = asJson(await native.invokeMethod('registerHotkeys'));
          if (hotkeyStatus['music'] != true || hotkeyStatus['timer'] != true) {
            message = '部分全局快捷键被其他程序占用，请在设置中查看。';
          }
        } catch (e) {
          message = 'Windows 启动设置未完成，可在设置中重试：$e';
        }
      }
    }
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_busy) return;
      unawaited(perform(tick));
    });
    notifyListeners();
  }

  Future<void> perform(Future<void> Function() action) {
    final future = _queue.then((_) async {
      _busy = true;
      try {
        await action();
      } catch (e) {
        message = '操作未完成：$e';
      } finally {
        _busy = false;
        notifyListeners();
      }
    });
    _queue = future;
    return future;
  }

  Future<void> refresh() async {
    tasks = await store.tasks();
    tasks.sort((a, b) {
      final group =
          (a.status == 'done' ? 1 : 0).compareTo(b.status == 'done' ? 1 : 0);
      if (group != 0) return group;
      // Completed tasks live in a folded group, newest completion first.
      final time = a.status == 'done'
          ? b.completionTime.compareTo(a.completionTime)
          : b.modified.compareTo(a.modified);
      return time != 0 ? time : a.id.compareTo(b.id);
    });
    sessions = await store.sessions();
    sessions.sort((a, b) => b.started.compareTo(a.started));
    notifyListeners();
  }

  Future<void> setFocusPinned(bool pinned) async {
    if (!Platform.isWindows) return;
    await windowManager.setAlwaysOnTop(pinned);
    focusPinned = pinned;
    notifyListeners();
  }

  Future<void> saveTask(TaskItem task) async {
    // Completion is only available from the list's circular button.
    final previous = tasks.where((t) => t.id == task.id).firstOrNull;
    if (task.status == 'done' && previous?.status != 'done') {
      throw StateError('请点击任务左侧圆环完成任务');
    }
    await store.task(TaskItem.fromJson({...task.toJson(),
      'completedAt': task.status == 'done'
          ? (previous?.completionTime ?? task.completionTime).toIso8601String()
          : null,
    }));
    await refresh();
  }

  Future<void> toggleTaskCompleted(String id) async {
    final task = tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return;
    final done = task.status != 'done';
    await store.task(TaskItem.fromJson({
      ...task.toJson(),
      'status': done ? 'done' : 'todo',
      'completedAt': done ? DateTime.now().toUtc().toIso8601String() : null,
      'modified': DateTime.now().toUtc().toIso8601String(),
    }));
    if (done && selectedTask == id && !active) selectedTask = null;
    await refresh();
    if (done && !await playCompletionSound()) {
      // Audio failure must not undo the saved task or stop a focus timer.
      message = '任务已完成，提示音暂时无法播放。';
    }
  }

  Future<void> deleteTask(String id) async {
    await store.deleteTask(id);
    if (selectedTask == id) selectedTask = null;
    await refresh();
  }

  Future<void> refreshDesktopIntegration() async {
    if (!Platform.isWindows) return;
    final state = asJson(await native.invokeMethod('getDesktopIntegration'));
    startupEnabled = state['startupEnabled'] == true;
    startupCurrentPath = state['startupCurrentPath'] == true;
    startMenuAvailable = state['shortcutCurrentPath'] == true;
    desktopIntegrationAvailable = true;
    notifyListeners();
  }

  Future<void> setLaunchAtLogin(bool enabled) async {
    await native.invokeMethod('setLaunchAtLogin', {'enabled': enabled});
    await refreshDesktopIntegration();
  }

  Future<void> createStartMenuShortcut() async {
    await native.invokeMethod('createStartMenuShortcut');
    await refreshDesktopIntegration();
    message = '开始菜单入口已添加，可按 Win 键搜索 FocusGarden 或专注花园。';
  }

  Future<void> pollAndroid() async {
    androidState = asJson(await native.invokeMethod('state'));
    playing = androidState['musicPlaying'] == true;
    trackIndex = (androidState['trackIndex'] as num?)?.toInt() ?? 0;
    final error = androidState['error'] as String? ?? '';
    if (error.isNotEmpty) message = error;
    final events =
        ((androidState['events'] as List?) ?? []).map(asJson).toList();
    bool changed = false;
    for (final event in events) {
      final s = FocusSession.fromJson(asJson(event['session']));
      await store.session(s);
      await native.invokeMethod('ack', {'id': event['id']});
      changed = true;
      if (s.reason == 'interrupted') recoveryMessage = '上次后台计时中断，已保留最后检查点的时间。';
    }
    if (changed) await refresh();
    completedCycle = (androidState['cycle'] as int?) ?? completedCycle;
  }

  Future<void> tick() async {
    if (android) {
      await pollAndroid();
      return;
    }
    if (await native.invokeMethod<bool>('takeSuspend') == true) {
      if (active) {
        await end(reason: 'sleep', useCheckpoint: true);
        message = '电脑进入睡眠，已保留最后检查点的专注时间。';
      }
      return;
    }
    final tick = clock.elapsedMilliseconds;
    if ([Phase.focus, Phase.rest].contains(phase) && remainingMs == 0) {
      if (phase == Phase.focus) {
        await end(reason: 'completed');
        await startRest();
        message = '本次专注已完成，已自动开始${completedCycle % 4 == 0 ? '长' : '短'}休息。';
        await _deadlineAlert('focus');
      } else {
        engine.finish(DateTime.now().toUtc(), tick);
        message = '休息结束，可以开始下一次专注。';
        await _deadlineAlert('rest');
      }
    }
    if (phase == Phase.focus && tick - _lastSave >= 15000) {
      final s = engine.snapshot(DateTime.now().toUtc(), tick);
      if (s != null) await store.commitCheckpoint(s);
      _lastSave = tick;
    }
  }

  Future<void> _deadlineAlert(String kind) async {
    // Persist and switch phases first. Each alert channel can fail independently.
    try {
      await native.invokeMethod('timerSound', {'kind': kind});
    } catch (_) {
      message += ' 提示音暂时无法播放。';
    }
    try {
      await native.invokeMethod('notify', {'text': message});
    } catch (_) {
      message += ' 系统通知暂时无法显示。';
    }
  }

  Json get _breakSettings => {
        'shortBreakSeconds': settings.shortBreak * 60,
        'longBreakSeconds': settings.longBreak * 60,
      };

  Future<void> _pauseMusicSafely() async {
    try {
      await player?.pause();
    } catch (_) {
      message = '音乐暂停失败，请检查音频设备；计时继续。';
    }
  }

  Future<void> startFocus({int? testSeconds}) async {
    if (active) return;
    final task = tasks.where((t) => t.id == selectedTask).firstOrNull;
    if (android) {
      await native.invokeMethod('start', {
        ..._breakSettings,
        'id': uuid.v4(),
        'device': device,
        'taskId': task?.id,
        'taskName': task?.name ?? '自由专注',
        'category': task?.category.isNotEmpty == true ? task!.category : '未分类',
        'seconds': testSeconds ?? settings.focus * 60
      });
      await pollAndroid();
    } else {
      engine.start(
          id: uuid.v4(),
          device: device,
          seconds: testSeconds ?? settings.focus * 60,
          now: DateTime.now().toUtc(),
          tick: clock.elapsedMilliseconds,
          task: task);
      await store.commitCheckpoint(
          engine.snapshot(DateTime.now().toUtc(), clock.elapsedMilliseconds)!);
      _lastSave = clock.elapsedMilliseconds;
      if (!muted && tracks.isNotEmpty) await player!.play();
    }
    if (task != null && task.status == 'todo') {
      await store.task(TaskItem.fromJson({
        ...task.toJson(),
        'status': 'doing',
        'modified': DateTime.now().toUtc().toIso8601String()
      }));
      await refresh();
    }
  }

  Future<void> pauseResume() async {
    if (!active) return;
    if (android) {
      await native.invokeMethod(phase == Phase.paused ? 'resume' : 'pause');
      await pollAndroid();
      return;
    }
    if (phase == Phase.paused) {
      engine.resume(DateTime.now().toUtc(), clock.elapsedMilliseconds);
      if (!isRest && !muted && tracks.isNotEmpty) await player!.play();
    } else {
      engine.pause(DateTime.now().toUtc(), clock.elapsedMilliseconds);
      await player?.pause();
    }
    final s =
        engine.snapshot(DateTime.now().toUtc(), clock.elapsedMilliseconds);
    if (s != null) await store.commitCheckpoint(s);
  }

  Future<void> end(
      {String reason = 'early', bool useCheckpoint = false}) async {
    if (!active) return;
    if (android) {
      await native.invokeMethod('end', {'reason': reason});
      await pollAndroid();
      return;
    }
    FocusSession? s;
    if (useCheckpoint && !isRest) {
      final saved = await store.get('checkpoint');
      if (saved != null) {
        s = FocusSession.fromJson(
            {...asJson(saved), 'reason': reason, 'completed': false});
      }
      engine.finish(DateTime.now().toUtc(), clock.elapsedMilliseconds);
    } else {
      s = engine.finish(DateTime.now().toUtc(), clock.elapsedMilliseconds,
          reason: reason);
    }
    if (s != null) {
      await store.commitSession(s);
      if (s.completed) {
        completedCycle++;
        await store.put('cycle', completedCycle);
      }
      await refresh();
    } else {
      await store.remove('checkpoint');
    }
    await _pauseMusicSafely();
  }

  Future<void> startRest() async {
    if (active) return;
    final seconds = (completedCycle > 0 && completedCycle % 4 == 0
            ? settings.longBreak
            : settings.shortBreak) *
        60;
    if (android) {
      await native.invokeMethod('rest', {'seconds': seconds});
      await pollAndroid();
    } else {
      engine.startRest(seconds, clock.elapsedMilliseconds);
      await _pauseMusicSafely();
    }
  }

  Future<void> saveSettings(Settings value) async {
    final oldBackground = settings.backgroundPath;
    settings = value;
    await store.put('settings', value.toJson());
    if (android) await native.invokeMethod('timerSettings', _breakSettings);
    notifyListeners();
    await discardUnusedBackground(oldBackground);
  }

  Future<void> handleHotkey(String action) async {
    if (action == 'music') await music('toggle');
    if (action == 'timer' && active) await pauseResume();
  }

  Future<String> importBackground(String source) async {
    final file = File(source);
    if (await file.length() > 20 * 1024 * 1024) {
      throw const FormatException('背景图片不能超过 20 MB');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes());
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final scale = math.min(1.0, 2560 / math.max(descriptor.width, descriptor.height));
      codec = await descriptor.instantiateCodec(
          targetWidth: math.max(1, (descriptor.width * scale).round()),
          targetHeight: math.max(1, (descriptor.height * scale).round()));
      if (codec.frameCount != 1) throw const FormatException('请选择静态图片');
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const FormatException('无法读取图片');
      final folder = Directory(p.join(dataDirectory.path, 'backgrounds'));
      await folder.create(recursive: true);
      final destination = File(p.join(folder.path, '${uuid.v4()}.png'));
      await destination.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return destination.path;
    } finally {
      image?.dispose(); codec?.dispose(); descriptor?.dispose(); buffer.dispose();
    }
  }

  Future<void> discardUnusedBackground(String? path) async {
    if (path == null || path == settings.backgroundPath) return;
    if (p.dirname(p.normalize(path)) != p.join(dataDirectory.path, 'backgrounds')) return;
    try { await File(path).delete(); } catch (_) { /* A cached file may still be in use. */ }
  }

  Future<void> saveTracks() async {
    await store.put('tracks', tracks);
    if (android) {
      await native.invokeMethod('playlist',
          {'tracks': tracks, 'index': trackIndex, 'volume': volume});
    } else {
      await _loadWindowsPlaylist();
    }
  }

  Future<void> _loadWindowsPlaylist() async {
    if (tracks.isEmpty) {
      await player?.stop();
      return;
    }
    final wasPlaying = playing;
    await player!.open(
        Playlist(tracks.map((t) => Media(t['path'] as String)).toList(),
            index: trackIndex.clamp(0, tracks.length - 1)),
        play: wasPlaying && canPlayMusic && !muted);
    await player!.setVolume(volume * 100);
    await player!.setPlaylistMode(repeat == 'one'
        ? PlaylistMode.single
        : repeat == 'all'
            ? PlaylistMode.loop
            : PlaylistMode.none);
    await player!.setShuffle(shuffle);
  }

  Future<void> music(String action, [Object? value]) async {
    if (action == 'volume') {
      volume = value as double;
      await store.put('volume', volume);
    }
    if (action == 'shuffle') shuffle = !shuffle;
    if (action == 'repeat') {
      repeat = repeat == 'all'
          ? 'one'
          : repeat == 'one'
              ? 'off'
              : 'all';
    }
    if (action == 'mute') muted = !muted;
    if (android) {
      await native.invokeMethod('music', {
        'action': action,
        'value': value,
        'shuffle': shuffle,
        'repeat': repeat,
        'muted': muted
      });
      await pollAndroid();
      return;
    }
    if (player == null || tracks.isEmpty) return;
    switch (action) {
      case 'toggle':
        if (playing) {
          await player!.pause();
        } else if (muted) {
          message = '音乐已静音，请先点击取消静音。';
        } else if (canPlayMusic) {
          message = '';
          await player!.play();
        } else {
          message = '计时暂停或休息期间音乐已暂停，继续专注后可播放。';
        }
      case 'next':
        await player!.next();
      case 'previous':
        await player!.previous();
      case 'select':
        await player!.jump(value as int);
      case 'volume':
        await player!.setVolume(volume * 100);
      case 'shuffle':
        await player!.setShuffle(shuffle);
      case 'repeat':
        await player!.setPlaylistMode(repeat == 'one'
            ? PlaylistMode.single
            : repeat == 'all'
                ? PlaylistMode.loop
                : PlaylistMode.none);
      case 'mute':
        if (muted) {
          await player!.pause();
        } else if (canPlayMusic) {
          await player!.play();
        }
    }
    if (!canPlayMusic) await player!.pause();
  }

  Future<void> shutdown() async {
    _ticker?.cancel();
    if (!android) await perform(() => end(reason: 'exit'));
    await player?.dispose();
    await store.close();
  }
}
