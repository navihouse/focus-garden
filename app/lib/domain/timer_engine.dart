import 'models.dart';

enum Phase { idle, focus, paused, rest, ended }

/// A monotonic clock drives elapsed time. Wall time is only a segment anchor.
class TimerEngine {
  Phase phase = Phase.idle;
  FocusSession? _base;
  final List<TimeSpan> _closed = [], _pauses = [];
  DateTime? _anchor, _pauseAt;
  int _anchorTick = 0, _restTick = 0, _restSeconds = 0;
  bool _pausedRest = false;
  int _restDurationMs = 0;
  int get restDurationMs => _restDurationMs;
  int get plannedSeconds => _base?.plannedSeconds ?? 0;
  String get taskName => _base?.taskName ?? '自由专注';

  void start(
      {required String id,
      required String device,
      required int seconds,
      required DateTime now,
      required int tick,
      TaskItem? task}) {
    if ([Phase.focus, Phase.paused, Phase.rest].contains(phase)) {
      throw StateError('已有计时进行中');
    }
    _closed.clear();
    _pauses.clear();
    _pauseAt = null;
    _pausedRest = false;
    _base = FocusSession(
        id: id,
        device: device,
        taskId: task?.id,
        taskName: task?.name ?? '自由专注',
        category: task?.category.isNotEmpty == true ? task!.category : '未分类',
        plannedSeconds: seconds,
        started: now.toUtc(),
        ended: now.toUtc(),
        spans: const []);
    _anchor = now.toUtc();
    _anchorTick = tick;
    phase = Phase.focus;
  }

  int elapsed(int tick) {
    final closed = _closed.fold<int>(0, (n, s) => n + s.milliseconds);
    final live = phase == Phase.focus
        ? (tick - _anchorTick).clamp(0, plannedSeconds * 1000)
        : 0;
    return (closed + live).clamp(0, plannedSeconds * 1000);
  }

  int remaining(int tick) => phase == Phase.rest ||
          (phase == Phase.paused && _pausedRest)
      ? (_restSeconds * 1000 - (phase == Phase.rest ? tick - _restTick : 0))
          .clamp(0, _restSeconds * 1000)
      : (plannedSeconds * 1000 - elapsed(tick)).clamp(0, plannedSeconds * 1000);

  void _close(int tick) {
    final used = _closed.fold<int>(0, (n, s) => n + s.milliseconds);
    final ms = (tick - _anchorTick).clamp(0, plannedSeconds * 1000 - used);
    if (ms > 0) {
      _closed.add(TimeSpan(_anchor!, _anchor!.add(Duration(milliseconds: ms))));
    }
    _anchor = null;
  }

  DateTime _ordered(DateTime now) {
    final last = _closed.isEmpty ? _base!.started : _closed.last.end;
    return now.toUtc().isBefore(last) ? last : now.toUtc();
  }

  void pause(DateTime now, int tick) {
    if (phase == Phase.rest) {
      _restSeconds = (remaining(tick) / 1000).ceil();
      _pausedRest = true;
      phase = Phase.paused;
      return;
    }
    if (phase != Phase.focus) return;
    _close(tick);
    _pauseAt = _ordered(now);
    phase = Phase.paused;
  }

  void resume(DateTime now, int tick) {
    if (phase != Phase.paused) return;
    if (_pausedRest) {
      _restTick = tick;
      phase = Phase.rest;
      return;
    }
    _anchor = _ordered(now);
    if (_anchor!.isBefore(_pauseAt!)) _anchor = _pauseAt;
    _pauses.add(TimeSpan(_pauseAt!, _anchor!));
    _pauseAt = null;
    _anchorTick = tick;
    phase = Phase.focus;
  }

  FocusSession? snapshot(DateTime now, int tick,
      {String reason = 'interrupted'}) {
    if (_base == null || phase == Phase.rest || _pausedRest) return null;
    final spans = [..._closed];
    if (phase == Phase.focus) {
      final ms =
          elapsed(tick) - _closed.fold<int>(0, (n, s) => n + s.milliseconds);
      if (ms > 0) {
        spans.add(TimeSpan(_anchor!, _anchor!.add(Duration(milliseconds: ms))));
      }
    }
    var end = _ordered(now);
    if (_pauseAt != null && end.isBefore(_pauseAt!)) end = _pauseAt!;
    if (spans.isNotEmpty && end.isBefore(spans.last.end)) end = spans.last.end;
    final pauses = [..._pauses];
    if (_pauseAt != null) {
      pauses
          .add(TimeSpan(_pauseAt!, end.isBefore(_pauseAt!) ? _pauseAt! : end));
    }
    return FocusSession(
        id: _base!.id,
        device: _base!.device,
        taskId: _base!.taskId,
        taskName: _base!.taskName,
        category: _base!.category,
        plannedSeconds: plannedSeconds,
        started: _base!.started,
        ended: reason == 'completed' && spans.isNotEmpty ? spans.last.end : end,
        spans: spans,
        pauses: pauses,
        completed: reason == 'completed',
        reason: reason);
  }

  FocusSession? finish(DateTime now, int tick, {String reason = 'early'}) {
    final result = snapshot(now, tick, reason: reason);
    phase = Phase.ended;
    _pausedRest = false;
    _base = null;
    return result;
  }

  void startRest(int seconds, int tick) {
    _restDurationMs = seconds * 1000;
    _base = null;
    _pausedRest = false;
    _restSeconds = seconds;
    _restTick = tick;
    phase = Phase.rest;
  }

  bool get isRest =>
      phase == Phase.rest || (phase == Phase.paused && _pausedRest);
}
