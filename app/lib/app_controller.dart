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
import 'automation_controller.dart';
import 'domain/automation.dart';
import 'study_scraper.dart';
import 'domain/models.dart';
import 'domain/music_library.dart';
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
  List<TaskGroup> groups = [];
  List<FocusSession> sessions = [];
  AutomationController? automation;
  MusicLibrary musicLibrary = MusicLibrary.empty();
  List<MusicPlaylist> get playlists => musicLibrary.playlists;
  MusicPlaylist get currentPlaylist => musicLibrary.current;
  List<Json> get tracks => currentPlaylist.tracks;
  set tracks(List<Json> value) {
    currentPlaylist.tracks = value;
    trackIndex = musicLibrary.index;
  }

  Settings settings = const Settings();
  String device = '', message = '', recoveryMessage = '';
  String? selectedTask;
  bool focusPinned = false;
  final engine = TimerEngine();
  final clock = Stopwatch()..start();
  Player? player;
  Timer? _ticker;
  int _lastSave = 0, completedCycle = 0;
  bool _busy = false, muted = false, playing = false;
  bool desktopIntegrationAvailable = false,
      startupEnabled = false,
      startupCurrentPath = false,
      startMenuAvailable = false;
  String get repeat => musicLibrary.repeat;
  bool get shuffle => musicLibrary.shuffle;
  Map<String, dynamic> hotkeyStatus = {};
  bool _capturingHotkey = false;
  double volume = .6;
  int get trackIndex => musicLibrary.index;
  set trackIndex(int value) => musicLibrary.index =
      tracks.isEmpty ? 0 : value.clamp(0, tracks.length - 1);
  bool _syncingMusicQueue = false;
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
    await loadMusicLibrary();
    volume = (await store.get('volume') as num?)?.toDouble() ?? .6;
    await refresh();
    if (android) {
      await native.invokeMethod('timerSettings', _breakSettings);
      await native.invokeMethod('recover');
      await pollAndroid();
      permissions = asJson(await native.invokeMethod('permissions'));
      await syncMusicQueue(keepPosition: true, resume: playing);
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
        if (_syncingMusicQueue || !queueMatchesPlaylist(v)) return;
        if (v.index >= 0 && v.index < v.medias.length) {
          trackIndex = canonicalTrackIndex(v.medias[v.index].uri);
        }
        notifyListeners();
      });
      try {
        await syncMusicQueue();
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
          hotkeyStatus = await registerHotkeys(settings, initial: true);
          if (settings.hotkeys.keys.any((key) => hotkeyStatus[key] != true)) {
            message = '部分全局快捷键被其他程序占用，请在设置中查看。';
          }
        } catch (e) {
          message = 'Windows 启动设置未完成，可在设置中重试：$e';
        }
      }
    }
    try {
      await initializeAutomation(start: false);
    } catch (_) {
      message = '自动化初始化未完成，可在 AUTO 中重试。';
    }
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_busy) return;
      unawaited(perform(tick));
    });
    automation?.start();
    notifyListeners();
  }

  Future<void> initializeAutomation({bool start = true}) async {
    final managed =
        File(p.join(dataDirectory.path, 'integrations', 'study_scraper.py'));
    await managed.parent.create(recursive: true);
    final bundled = await rootBundle.loadString('assets/study_scraper.py');
    if (!await managed.exists() || await managed.readAsString() != bundled) {
      await managed.writeAsString(bundled, flush: true);
    }
    const supplied = r'D:\Pomodoro Technique\study-scraper\study_scraper.py';
    final script = await File(supplied).exists() ? supplied : managed.path;
    final defaults = AutomationSettings(
        scriptPath: script,
        chaoxingCookiePath:
            p.join(p.dirname(script), 'cookies', 'chaoxing.txt'),
        moocCookiePath: p.join(p.dirname(script), 'cookies', 'icourse163.txt'));
    final next = AutomationController(
        store: store,
        directory: dataDirectory,
        tasks: () => tasks,
        serialize: _serializeAutomation,
        refreshTasks: refresh,
        runner: PythonStudyScraperRunner(),
        supportsScraper: Platform.isWindows,
        initialSettings: defaults);
    await next.initialize();
    automation?.removeListener(notifyListeners);
    automation?.dispose();
    automation = next;
    next.addListener(notifyListeners);
    if (start) next.start();
    notifyListeners();
  }

  Future<void> _serializeAutomation(Future<void> Function() action) {
    final result = Completer<void>();
    unawaited(perform(() async {
      try {
        await action();
        result.complete();
      } catch (e, stack) {
        result.completeError(e, stack);
      }
    }));
    return result.future;
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
    groups = await store.groups();
    tasks = await store.tasks();
    final known = {for (final group in groups) group.id};
    final stray =
        tasks.where((t) => t.groupId.isNotEmpty && !known.contains(t.groupId));
    if (stray.isNotEmpty) {
      // A removed or hand-edited group must not hide its tasks.
      await store.transaction(() async {
        for (final task in stray) {
          await store
              .task(TaskItem.fromJson({...task.toJson(), 'groupId': ''}));
        }
      });
      tasks = await store.tasks();
    }
    final rank = {for (final (i, group) in groups.indexed) group.id: i};
    tasks.sort((a, b) {
      final group =
          (a.status == 'done' ? 1 : 0).compareTo(b.status == 'done' ? 1 : 0);
      if (group != 0) return group;
      // Custom groups keep their manager order; ungrouped tasks come last.
      final section = (rank[a.groupId] ?? groups.length)
          .compareTo(rank[b.groupId] ?? groups.length);
      if (section != 0) return section;
      // Completed tasks live in a folded group, newest completion first.
      final time = a.status == 'done'
          ? b.completionTime.compareTo(a.completionTime)
          : a.sortOrder != null || b.sortOrder != null
              ? a.sortOrder == null
                  ? 1
                  : b.sortOrder == null
                      ? -1
                      : a.sortOrder!.compareTo(b.sortOrder!)
              : b.modified.compareTo(a.modified);
      return time != 0 ? time : a.id.compareTo(b.id);
    });
    sessions = await store.sessions();
    sessions.sort((a, b) => b.started.compareTo(a.started));
    notifyListeners();
  }

  /// Active tasks split into display sections; a null group means ungrouped.
  List<(TaskGroup?, List<TaskItem>)> groupSections(List<TaskItem> active) {
    final known = {for (final group in groups) group.id};
    return [
      for (final group in groups)
        (group, active.where((t) => t.groupId == group.id).toList()),
      (null, active.where((t) => !known.contains(t.groupId)).toList()),
    ];
  }

  String? groupNameError(String? value, {String? exceptId}) {
    final name = (value ?? '').trim();
    if (name.isEmpty) return '请填写分组名称';
    if (name.length > 40) return '分组名称最多 40 字';
    if (groups.any((g) => g.id != exceptId && g.name == name)) {
      return '已有同名分组';
    }
    return null;
  }

  Future<void> saveGroups() async {
    await store.saveGroups(groups);
    await refresh();
  }

  Future<void> createGroup(String name, String color) async {
    final error = groupNameError(name);
    if (error != null) throw StateError(error);
    groups.add(TaskGroup(id: uuid.v4(), name: name.trim(), color: color));
    await saveGroups();
  }

  Future<void> updateGroup(String id,
      {required String name, required String color}) async {
    final index = groups.indexWhere((g) => g.id == id);
    if (index < 0) throw StateError('分组已不存在');
    final error = groupNameError(name, exceptId: id);
    if (error != null) throw StateError(error);
    groups[index] = TaskGroup(id: id, name: name.trim(), color: color);
    await saveGroups();
  }

  Future<void> moveGroup(String id, int delta) async {
    final index = groups.indexWhere((g) => g.id == id);
    if (index < 0) return;
    await reorderGroup(id, index + delta);
  }

  Future<void> reorderGroup(String id, int newIndex) async {
    final oldIndex = groups.indexWhere((group) => group.id == id);
    if (oldIndex < 0 ||
        newIndex < 0 ||
        newIndex >= groups.length ||
        oldIndex == newIndex) {
      return;
    }
    final reordered = List<TaskGroup>.from(groups);
    reordered.insert(newIndex, reordered.removeAt(oldIndex));
    await store.saveGroups(reordered);
    await refresh();
  }

  Future<void> deleteGroup(String id) async {
    // Tasks survive the group: they return to the ungrouped section.
    final modified = DateTime.now().toUtc().toIso8601String();
    await store.transaction(() async {
      for (final task in tasks.where((t) => t.groupId == id)) {
        await store.task(TaskItem.fromJson(
            {...task.toJson(), 'groupId': '', 'modified': modified}));
      }
    });
    groups.removeWhere((g) => g.id == id);
    await saveGroups();
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
    await store.task(TaskItem.fromJson({
      ...task.toJson(),
      'groupId': groups.any((g) => g.id == task.groupId) ? task.groupId : '',
      'sortOrder': previous != null
          ? previous.sortOrder
          : task.sortOrder ??
              (tasks
                      .where((t) => t.sortOrder != null)
                      .fold<int>(0, (n, t) => math.min(n, t.sortOrder!)) -
                  1),
      'completedAt': task.status == 'done'
          ? (previous?.completionTime ?? task.completionTime).toIso8601String()
          : null,
    }));
    await refresh();
  }

  Future<void> moveTaskToGroup(String id, String groupId,
      {String? relativeToTaskId, bool after = false}) async {
    if (groupId.isNotEmpty && !groups.any((group) => group.id == groupId)) {
      throw StateError('目标分组已不存在');
    }
    final task = tasks.where((task) => task.id == id).firstOrNull;
    if (task == null || task.status == 'done' || relativeToTaskId == id) return;
    final peers = tasks
        .where((peer) =>
            peer.id != id && peer.status != 'done' && peer.groupId == groupId)
        .toList();
    var index = peers.length;
    if (relativeToTaskId != null) {
      index = peers.indexWhere((peer) => peer.id == relativeToTaskId);
      if (index < 0) return;
      if (after) index++;
    }
    peers.insert(index, task);
    final modified = DateTime.now().toUtc().toIso8601String();
    await store.transaction(() async {
      for (var i = 0; i < peers.length; i++) {
        final peer = peers[i];
        if (peer.groupId == groupId && peer.sortOrder == i) continue;
        await store.task(TaskItem.fromJson({
          ...peer.toJson(),
          'groupId': groupId,
          'sortOrder': i,
          'modified': modified,
        }));
      }
    });
    await refresh();
  }

  Future<void> reorderTask(String id, int newIndex,
      {String groupId = ''}) async {
    // Each visible section is its own reorderable list, so only renumber peers.
    final peers =
        tasks.where((t) => t.status != 'done' && t.groupId == groupId).toList();
    final oldIndex = peers.indexWhere((t) => t.id == id);
    if (oldIndex < 0 ||
        newIndex < 0 ||
        newIndex >= peers.length ||
        oldIndex == newIndex) {
      return;
    }
    peers.insert(newIndex, peers.removeAt(oldIndex));
    final modified = DateTime.now().toUtc().toIso8601String();
    await store.transaction(() async {
      for (var i = 0; i < peers.length; i++) {
        await store.task(TaskItem.fromJson(
            {...peers[i].toJson(), 'sortOrder': i, 'modified': modified}));
      }
    });
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
    if (androidState['playlistId'] == null ||
        androidState['playlistId'] == '' ||
        androidState['playlistId'] == currentPlaylist.id) {
      trackIndex = (androidState['trackIndex'] as num?)?.toInt() ?? 0;
    }
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
      if (s.countsAsPomodoro) {
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
    if (!value.validHotkeys) {
      throw const FormatException('四组快捷键必须不同，且包含 Ctrl 或 Alt 和一个受支持的按键。');
    }
    final oldSettings = settings;
    final hotkeysChanged = value.hotkeys.entries
        .any((entry) => !entry.value.sameAs(settings.hotkeys[entry.key]!));
    if (Platform.isWindows &&
        (hotkeysChanged || hotkeyStatus.values.contains(false))) {
      final status = await registerHotkeys(value);
      if (status['accepted'] != true) {
        hotkeyStatus = asJson(status['restored']);
        notifyListeners();
        const labels = {
          'music': '音乐播放 / 暂停',
          'timer': '计时',
          'previous': '前一首',
          'next': '后一首'
        };
        final failed = labels.entries
            .where((e) => status[e.key] == false)
            .map((e) => e.value)
            .join('、');
        throw FormatException('$failed快捷键被系统或其他程序占用，请换一组按键。原设置已保留。');
      }
      hotkeyStatus = status;
    }
    final oldBackground = settings.backgroundPath;
    try {
      await store.put('settings', value.toJson());
    } catch (_) {
      if (Platform.isWindows && hotkeysChanged) {
        hotkeyStatus = await registerHotkeys(oldSettings, initial: true);
      }
      rethrow;
    }
    settings = value;
    if (android) await native.invokeMethod('timerSettings', _breakSettings);
    notifyListeners();
    await discardUnusedBackground(oldBackground);
  }

  Future<void> handleHotkey(String action) async {
    if (_capturingHotkey) return;
    if (action == 'music') await music('toggle');
    if (action == 'previous' || action == 'next') await music(action);
    if (action == 'timer' && active) await pauseResume();
  }

  Future<Json> registerHotkeys(Settings value, {bool initial = false}) async =>
      asJson(await native.invokeMethod('registerHotkeys', {
        for (final entry in value.hotkeys.entries)
          entry.key: entry.value.toJson(),
        'initial': initial,
      }));

  Future<void> suspendHotkeys() async {
    _capturingHotkey = true;
    try {
      await native.invokeMethod('suspendHotkeys');
    } catch (_) {
      _capturingHotkey = false;
      rethrow;
    }
  }

  Future<void> resumeHotkeys() async {
    try {
      hotkeyStatus = asJson(await native.invokeMethod('resumeHotkeys'));
      if (settings.hotkeys.keys.any((key) => hotkeyStatus[key] == false)) {
        message = '部分快捷键被其他程序占用，请在设置中重新设置。';
      }
    } finally {
      _capturingHotkey = false;
      notifyListeners();
    }
  }

  Future<String> importBackground(String source) async {
    final file = File(source);
    if (await file.length() > 20 * 1024 * 1024) {
      throw const FormatException('背景图片不能超过 20 MB');
    }
    final buffer =
        await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes());
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final scale =
          math.min(1.0, 2560 / math.max(descriptor.width, descriptor.height));
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
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<void> discardUnusedBackground(String? path) async {
    if (path == null || path == settings.backgroundPath) return;
    if (p.dirname(p.normalize(path)) !=
        p.join(dataDirectory.path, 'backgrounds')) {
      return;
    }
    try {
      await File(path).delete();
    } catch (_) {/* A cached file may still be in use. */}
  }

  Future<void> loadMusicLibrary() async {
    final saved = await store.get('musicLibrary');
    if (saved == null) {
      final legacy =
          ((await store.get('tracks') as List?) ?? []).map(asJson).toList();
      final migrated = MusicLibrary.legacy(legacy);
      await store.put('musicLibrary', migrated.toJson());
      musicLibrary = migrated;
    } else {
      musicLibrary = MusicLibrary.fromJson(asJson(saved));
    }
  }

  String? playlistNameError(String? value, {String? exceptId}) {
    final name = value?.trim() ?? '';
    if (name.isEmpty || name.length > 80) return '填写 1–80 字的歌单名称';
    if (playlists.any((p) =>
        p.id != exceptId && p.name.toLowerCase() == name.toLowerCase())) {
      return '已有同名歌单';
    }
    return null;
  }

  Future<void> _applyMusicLibrary(MusicLibrary value,
      {bool reload = true, bool? resume}) async {
    final oldId = currentPlaylist.id;
    final oldPath = tracks.isEmpty ? null : tracks[trackIndex]['path'];
    final wasPlaying = playing;
    await store.put('musicLibrary', value.toJson());
    musicLibrary = value;
    if (reload) {
      try {
        await syncMusicQueue(
            resume: resume ?? wasPlaying,
            keepPosition: oldId == currentPlaylist.id &&
                tracks.isNotEmpty &&
                oldPath == tracks[trackIndex]['path']);
      } catch (_) {
        playing = false;
        try {
          if (android) {
            await native.invokeMethod('music', {'action': 'stop'});
          } else {
            await player?.stop();
          }
        } catch (_) {/* Report the load failure without changing the clock. */}
        message = '歌单已保存，音乐暂时无法加载，请检查文件后重试。计时继续。';
      }
    }
    notifyListeners();
  }

  Future<String> createPlaylist(String name) async {
    final error = playlistNameError(name);
    if (error != null) throw FormatException(error);
    final next = musicLibrary.copy();
    final id = uuid.v4();
    next.playlists.add(MusicPlaylist(id: id, name: name.trim()));
    next.selectedId = id;
    next.index = 0;
    await _applyMusicLibrary(next, resume: false);
    return id;
  }

  Future<void> renamePlaylist(String id, String name) async {
    final error = playlistNameError(name, exceptId: id);
    if (error != null) throw FormatException(error);
    final next = musicLibrary.copy();
    next.playlists.firstWhere((p) => p.id == id).name = name.trim();
    await _applyMusicLibrary(next, reload: false);
  }

  Future<void> selectPlaylist(String id) async {
    if (id == currentPlaylist.id) return;
    if (!playlists.any((p) => p.id == id)) throw const FormatException('歌单不存在');
    final next = musicLibrary.copy();
    next.selectedId = id;
    next.index = 0;
    await _applyMusicLibrary(next);
  }

  Future<void> deletePlaylist(String id) async {
    final next = musicLibrary.copy();
    if (!next.playlists.any((p) => p.id == id)) return;
    final wasCurrent = id == next.selectedId;
    next.playlists.removeWhere((p) => p.id == id);
    if (next.playlists.isEmpty) {
      next.playlists.add(MusicPlaylist(id: uuid.v4(), name: '默认歌单'));
    }
    if (wasCurrent) {
      next.selectedId = next.playlists.first.id;
      next.index = 0;
    }
    await _applyMusicLibrary(next, reload: wasCurrent, resume: false);
  }

  String _musicPathKey(String value) => musicMediaKey(value);
  void _retainSelectedTrack(MusicLibrary next, String? id) {
    final index = next.current.tracks.indexWhere((t) => t['id'] == id);
    next.index = next.current.tracks.isEmpty
        ? 0
        : index >= 0
            ? index
            : next.index.clamp(0, next.current.tracks.length - 1);
  }

  Future<void> importMusicFiles(String playlistId, List<Json> files) async {
    final next = musicLibrary.copy();
    final target = next.playlists.firstWhere((p) => p.id == playlistId);
    int added = 0;
    for (final file in files) {
      final source = file['path'] as String, name = file['name'] as String;
      Json? shared;
      if (android) {
        for (final list in next.playlists) {
          shared = list.tracks
              .where((t) => t['sourcePath'] == source || t['path'] == source)
              .firstOrNull;
          if (shared != null && await File(shared['path'] as String).exists()) {
            break;
          }
          shared = null;
        }
      }
      var path = shared?['path'] as String? ?? source;
      if (target.tracks.any(
          (t) => _musicPathKey(t['path'] as String) == _musicPathKey(path))) {
        continue;
      }
      if (android && shared == null) {
        final folder = await Directory(p.join(dataDirectory.path, 'music'))
            .create(recursive: true);
        path = p.join(folder.path, '${uuid.v4()}${p.extension(name)}');
        await File(source).copy(path);
      }
      target.tracks.add({
        'id': uuid.v4(),
        'name': name,
        'path': path,
        if (android) 'sourcePath': source
      });
      added++;
    }
    message =
        added == 0 ? '当前歌单中已有这些歌曲，未重复添加。' : '已向“${target.name}”添加 $added 首歌曲。';
    await _applyMusicLibrary(next, reload: playlistId == currentPlaylist.id);
  }

  Future<void> removeTrack(String playlistId, String trackId) async {
    final selectedId =
        tracks.isEmpty ? null : tracks[trackIndex]['id'] as String;
    final next = musicLibrary.copy();
    next.playlists
        .firstWhere((p) => p.id == playlistId)
        .tracks
        .removeWhere((t) => t['id'] == trackId);
    _retainSelectedTrack(next, selectedId);
    await _applyMusicLibrary(next, reload: playlistId == currentPlaylist.id);
  }

  Future<void> transferTrack(String fromId, String trackId, String toId,
      {required bool copy}) async {
    if (fromId == toId) return;
    final selectedId =
        tracks.isEmpty ? null : tracks[trackIndex]['id'] as String;
    final next = musicLibrary.copy();
    final source = next.playlists.firstWhere((p) => p.id == fromId);
    final destination = next.playlists.firstWhere((p) => p.id == toId);
    final track = source.tracks.firstWhere((t) => t['id'] == trackId);
    if (!destination.tracks.any((t) =>
        _musicPathKey(t['path'] as String) ==
        _musicPathKey(track['path'] as String))) {
      destination.tracks.add({...track, 'id': uuid.v4()});
    }
    if (!copy) source.tracks.removeWhere((t) => t['id'] == trackId);
    _retainSelectedTrack(next, selectedId);
    await _applyMusicLibrary(next,
        reload: (!copy && fromId == currentPlaylist.id) ||
            toId == currentPlaylist.id);
  }

  // Compatibility for isolated native probes; normal UI edits clone the library.
  Future<void> saveTracks() => _applyMusicLibrary(musicLibrary.copy());

  Future<void> syncMusicQueue(
      {bool resume = false, bool keepPosition = false}) async {
    final canResume = resume && canPlayMusic && !muted && tracks.isNotEmpty;
    _syncingMusicQueue = true;
    try {
      if (android) {
        await native.invokeMethod('playlist', {
          'playlistId': currentPlaylist.id,
          'tracks': tracks,
          'index': trackIndex,
          'volume': volume,
          'play': canResume,
          'keepPosition': keepPosition,
          'shuffle': shuffle,
          'repeat': repeat,
          'muted': muted
        });
        await pollAndroid();
      } else if (player != null) {
        final position = keepPosition ? player!.state.position : Duration.zero;
        await player!.pause();
        if (tracks.isEmpty) {
          await player!.stop();
          playing = false;
          return;
        }
        await player!.open(
            Playlist(tracks.map((t) => Media(t['path'] as String)).toList(),
                index: trackIndex),
            play: false);
        await player!.setVolume(volume * 100);
        await _applyDesktopMusicMode();
        if (position > Duration.zero) await player!.seek(position);
        if (canResume) await player!.play();
        playing = canResume;
      }
    } finally {
      _syncingMusicQueue = false;
    }
  }

  Future<void> _applyDesktopMusicMode() async {
    final p = player!;
    switch (musicLibrary.mode) {
      case MusicPlaybackMode.shuffle:
        await p.setPlaylistMode(PlaylistMode.none);
        await p.setShuffle(true);
      case MusicPlaybackMode.playlistLoop:
      case MusicPlaybackMode.singleLoop:
        await p.setShuffle(false);
        await p.setPlaylistMode(
            repeat == 'one' ? PlaylistMode.single : PlaylistMode.loop);
    }
  }

  String musicMediaKey(String value) {
    if (value.startsWith('file:')) {
      try {
        value = Uri.parse(value).toFilePath(windows: Platform.isWindows);
      } catch (_) {}
    }
    if (Platform.isWindows) {
      value = value.replaceAll('\\', '/');
      if (value.startsWith('//?/')) value = value.substring(4);
      if (value.startsWith('UNC/')) value = '//${value.substring(4)}';
      return p.windows.normalize(value).toLowerCase();
    }
    return p.posix.normalize(value);
  }

  int canonicalTrackIndex(String uri) => tracks.indexWhere(
      (t) => musicMediaKey(t['path'] as String) == musicMediaKey(uri));

  bool queueMatchesPlaylist(Playlist queue) {
    if (queue.medias.length != tracks.length) return false;
    final allowed = <String, int>{};
    for (final track in tracks) {
      final key = musicMediaKey(track['path'] as String);
      allowed.update(key, (n) => n + 1, ifAbsent: () => 1);
    }
    for (final media in queue.medias) {
      final key = musicMediaKey(media.uri),
          count = allowed[musicMediaKey(media.uri)] ?? 0;
      if (count == 0) return false;
      allowed[key] = count - 1;
    }
    return true;
  }

  Future<void> music(String action, [Object? value]) async {
    if (tracks.isEmpty &&
        ['toggle', 'next', 'previous', 'select'].contains(action)) {
      message = '当前歌单没有歌曲，请先在音乐库添加。';
      return;
    }
    if (action == 'volume') {
      volume = value as double;
      await store.put('volume', volume);
    }
    if (action == 'shuffle' || action == 'repeat') {
      final updated = musicLibrary.copy();
      updated.mode = action == 'shuffle'
          ? (shuffle
              ? MusicPlaybackMode.playlistLoop
              : MusicPlaybackMode.shuffle)
          : (repeat == 'all'
              ? MusicPlaybackMode.singleLoop
              : MusicPlaybackMode.playlistLoop);
      await store.put('musicLibrary', updated.toJson());
      musicLibrary.mode = updated.mode;
    }
    if (action == 'mute') muted = !muted;
    if (action == 'select') {
      if (value is! int || value < 0 || value >= tracks.length) return;
      trackIndex = value;
      await store.put('musicLibrary', musicLibrary.toJson());
    }
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
    if (['toggle', 'next', 'previous', 'select'].contains(action) &&
        !queueMatchesPlaylist(player!.state.playlist)) {
      await syncMusicQueue();
    }
    if (['next', 'previous', 'select'].contains(action) &&
        (!canPlayMusic || muted)) {
      if (action != 'select') {
        final queue = player!.state.playlist;
        final next = (queue.index + (action == 'next' ? 1 : -1));
        final index = repeat == 'all'
            ? next % queue.medias.length
            : next.clamp(0, queue.medias.length - 1);
        trackIndex = canonicalTrackIndex(queue.medias[index].uri);
      }
      await store.put('musicLibrary', musicLibrary.toJson());
      await syncMusicQueue();
      return;
    }
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
        final uri = musicMediaKey(tracks[value as int]['path'] as String);
        final index = player!.state.playlist.medias
            .indexWhere((m) => musicMediaKey(m.uri) == uri);
        if (index < 0) throw const FormatException('歌曲不在当前歌单中');
        await player!.jump(index);
        if (canPlayMusic && !muted) {
          await player!.play();
        } else {
          await player!.pause();
        }
      case 'volume':
        await player!.setVolume(volume * 100);
      case 'shuffle':
      case 'repeat':
        await _applyDesktopMusicMode();
      case 'mute':
        if (muted) {
          await player!.pause();
        } else if (canPlayMusic) {
          await player!.play();
        }
    }
    if (!canPlayMusic || muted) await player!.pause();
  }

  Future<void> shutdown() async {
    _ticker?.cancel();
    await automation?.shutdown();
    if (!android) await perform(() => end(reason: 'exit'));
    await player?.dispose();
    await store.close();
  }

  @override
  void dispose() {
    automation?.removeListener(notifyListeners);
    automation?.dispose();
    super.dispose();
  }
}
