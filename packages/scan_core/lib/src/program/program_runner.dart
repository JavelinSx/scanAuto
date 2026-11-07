import 'dart:math';

import '../session/recording.dart';
import 'diagnostic_program.dart';

final class ProgramStatus {
  const ProgramStatus({
    required this.stageIndex,
    required this.runIndex,
    required this.elapsed,
    required this.counted,
    required this.progress,
    required this.finished,
    required this.stageChanged,
    required this.runChanged,
    this.hint,
  });

  final int stageIndex;
  final int runIndex;

  /// Время с начала этапа и засчитанное время (на трассе — только на скорости).
  final Duration elapsed;
  final Duration counted;

  /// 0…1 — для полосы прогресса.
  final double progress;
  final bool finished;

  /// На этом обновлении начался новый этап или прогон: пора сменить набор опроса.
  final bool stageChanged;
  final bool runChanged;

  /// Что показать водителю: «ОЖ 63 °C из 80», «скорость ниже 70 — время стоит».
  final String? hint;
}

/// Ведёт программу по записи: решает, когда этап выполнен, и отмечает этапы
/// отрезками в [Recording.segments]. Время — миллисекунды от начала записи.
/// Без побочных эффектов, кроме записи отрезков: смену опроса делает вызывающий.
class ProgramRunner {
  ProgramRunner(this.program, this.recording) {
    recording.season = program.season.name;
  }

  /// Между двумя замерами скорости больше этого — разрыв связи, не засчитываем.
  static const _maxGapMs = 15000;

  final DiagnosticProgram program;
  final Recording recording;
  int _stage = 0;
  int _run = 0;
  int? _stageStartMs;
  double? _startCoolant;
  bool _finished = false;

  bool get finished => _finished;
  StageSpec get stage => program.stages[min(_stage, program.stages.length - 1)];

  ProgramStatus update(int nowMs) {
    if (_finished) return _status(nowMs, 0, 1, false, false);
    var stageChanged = false;
    if (_stageStartMs == null) {
      _begin(nowMs);
      stageChanged = true;
    }

    final spec = stage;
    final elapsed = nowMs - _stageStartMs!;
    final counted = _counted(spec, nowMs);
    final reached = _reached(spec, elapsed, counted, nowMs);
    if (reached || elapsed >= spec.maxDuration.inMilliseconds) {
      _close(nowMs, completed: reached);
      if (_finished) return _status(nowMs, 0, 1, true, false);
      _begin(nowMs);
      return _status(nowMs, 0, 0, true, true);
    }

    final run = _runAt(spec, elapsed);
    final runChanged = run != _run;
    _run = run;
    return _status(
      nowMs,
      counted,
      _progress(spec, elapsed, counted, nowMs),
      stageChanged,
      runChanged || stageChanged,
    );
  }

  /// Водитель закончил этап раньше: отрезок помечается невыполненным.
  void skip(int nowMs) {
    if (_finished || _stageStartMs == null) return;
    _close(nowMs, completed: false, note: 'закончен водителем досрочно');
    if (!_finished) _begin(nowMs);
  }

  /// Прервать всю программу: текущий отрезок закрывается как есть.
  void abort(int nowMs) {
    if (_finished || _stageStartMs == null) return;
    _close(nowMs, completed: false, note: 'программа прервана');
    _finished = true;
  }

  void _begin(int nowMs) {
    _stageStartMs = nowMs;
    _run = 0;
    _startCoolant = _last('coolant', nowMs - 5000);
  }

  void _close(int nowMs, {required bool completed, String? note}) {
    final spec = stage;
    final warmNote =
        spec.kind == StageKind.warmup &&
            (_startCoolant ?? 0) >= DiagnosticProgram.alreadyWarmCoolant
        ? 'двигатель на старте уже был тёплым (${_startCoolant!.round()} °C)'
        : null;
    final timeNote = !completed && note == null && spec.kind == StageKind.warmup
        ? 'за ${spec.maxDuration.inMinutes} мин ОЖ не дошла до '
              '${DiagnosticProgram.warmCoolant.round()} °C'
        : null;
    recording.segments.add(
      RecordingSegment(
        key: spec.kind.name,
        title: spec.title,
        startMs: _stageStartMs!,
        endMs: nowMs,
        completed: completed,
        note: [warmNote, timeNote, note].nonNulls.join('; ').ifEmptyNull,
      ),
    );
    _stage++;
    if (_stage >= program.stages.length) _finished = true;
  }

  int _runAt(StageSpec spec, int elapsedMs) {
    var end = 0;
    for (var i = 0; i < spec.runs.length; i++) {
      final d = spec.runs[i].duration;
      if (d == null) return i;
      end += d.inMilliseconds;
      if (elapsedMs < end) return i;
    }
    return spec.runs.length - 1;
  }

  int _counted(StageSpec spec, int nowMs) {
    final elapsed = nowMs - _stageStartMs!;
    if (spec.kind != StageKind.highway) return elapsed;
    final speed = recording.series['speed'];
    if (speed == null || speed.isEmpty) return elapsed;
    var counted = 0;
    for (
      var i = max(speed.lowerBound(_stageStartMs!), 1);
      i < speed.length;
      i++
    ) {
      final dt = speed.tMs[i] - speed.tMs[i - 1];
      if (dt > _maxGapMs) continue;
      if (speed.values[i] >= DiagnosticProgram.highwaySpeed &&
          speed.values[i - 1] >= DiagnosticProgram.highwaySpeed) {
        counted += dt;
      }
    }
    return counted;
  }

  bool _reached(StageSpec spec, int elapsedMs, int countedMs, int nowMs) {
    if (spec.kind == StageKind.warmup) {
      if (elapsedMs < spec.minDuration.inMilliseconds) return false;
      final coolant = _last('coolant', _stageStartMs!);
      return coolant != null && coolant >= DiagnosticProgram.warmCoolant;
    }
    return countedMs >= spec.target.inMilliseconds;
  }

  double _progress(StageSpec spec, int elapsedMs, int countedMs, int nowMs) {
    if (spec.kind == StageKind.warmup) {
      final coolant = _last('coolant', _stageStartMs!);
      final start = _startCoolant;
      final byTime = elapsedMs / spec.maxDuration.inMilliseconds;
      if (coolant == null || start == null) return byTime.clamp(0, 1);
      final span = DiagnosticProgram.warmCoolant - start;
      final byTemp = span <= 0 ? 1.0 : (coolant - start) / span;
      // Даже прогретому двигателю нужно отстоять минимум.
      final byMin = elapsedMs / spec.minDuration.inMilliseconds;
      return min(byTemp, byMin).clamp(0, 1).toDouble();
    }
    return (countedMs / spec.target.inMilliseconds).clamp(0, 1).toDouble();
  }

  double? _last(String key, int sinceMs) {
    final s = recording.series[key];
    if (s == null || s.isEmpty || s.tMs.last < sinceMs) return null;
    return s.values.last;
  }

  ProgramStatus _status(
    int nowMs,
    int countedMs,
    double progress,
    bool stageChanged,
    bool runChanged,
  ) {
    final elapsed = _finished || _stageStartMs == null
        ? 0
        : nowMs - _stageStartMs!;
    return ProgramStatus(
      stageIndex: min(_stage, program.stages.length - 1),
      runIndex: _run,
      elapsed: Duration(milliseconds: elapsed),
      counted: Duration(milliseconds: countedMs),
      progress: progress,
      finished: _finished,
      stageChanged: stageChanged,
      runChanged: runChanged,
      hint: _finished ? null : _hint(nowMs),
    );
  }

  String? _hint(int nowMs) {
    switch (stage.kind) {
      case StageKind.warmup:
        final c = _last('coolant', _stageStartMs ?? 0);
        return c == null
            ? null
            : 'ОЖ ${c.round()} °C из ${DiagnosticProgram.warmCoolant.round()}';
      case StageKind.highway:
        final v = _last('speed', nowMs - 10000);
        if (v != null && v < DiagnosticProgram.highwaySpeed) {
          return 'Скорость ниже ${DiagnosticProgram.highwaySpeed.round()} км/ч — время стоит';
        }
        return null;
      case StageKind.city:
        return null;
    }
  }
}

extension on String {
  String? get ifEmptyNull => isEmpty ? null : this;
}
