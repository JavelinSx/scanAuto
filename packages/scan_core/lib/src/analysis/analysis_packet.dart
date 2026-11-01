import 'dart:math';

import '../obd/dtc.dart';
import '../obd/pids.dart';
import '../session/recording.dart';
import 'lttb.dart';

/// Что уходит в языковую модель вместо сырой записи.
///
/// Модель плохо читает тысячи точек и хорошо — сводки. Поэтому пакет — это
/// статистика по режимам (холостой ход / движение: подсос виден на ХХ и пропадает
/// под нагрузкой), прореженные графики для формы кривой и несколько посчитанных
/// признаков. VIN в пакет не попадает.
abstract final class AnalysisPacket {
  static const version = 1;

  /// [maxPoints] — точек на график после прореживания (LTTB сохраняет пики).
  static Map<String, Object?> build(Recording rec, {int maxPoints = 60}) {
    final idle = _idleClassifier(rec);
    final seriesOut = <Map<String, Object?>>[];
    for (final pid in standardPids) {
      final s = rec.series[pid.key];
      if (s == null || s.isEmpty) continue;
      final digits = pid.decimals + 1;
      final stats = <String, Object?>{'all': _stats(s.values, digits)};
      if (idle != null) {
        final idleValues = <double>[];
        final drivingValues = <double>[];
        for (var i = 0; i < s.length; i++) {
          (idle(s.tMs[i]) ? idleValues : drivingValues).add(s.values[i]);
        }
        if (idleValues.isNotEmpty) stats['idle'] = _stats(idleValues, digits);
        if (drivingValues.isNotEmpty) {
          stats['driving'] = _stats(drivingValues, digits);
        }
      }
      seriesOut.add({
        'key': pid.key,
        'name': pid.name,
        'unit': pid.unit,
        'stats': stats,
        'points': [
          for (final (t, v) in lttb(s.tMs, s.values, maxPoints))
            [_round(t / 1000, 1), _round(v, digits)],
        ],
      });
    }

    return {
      'packet_version': version,
      'vehicle': rec.vehicle?.title,
      'duration_s': rec.duration.inSeconds,
      'dtcs': [
        for (final code in rec.dtcs)
          {'code': code, 'description': describeDtc(code)},
      ],
      'pending_dtcs': [
        for (final code in rec.pendingDtcs)
          {'code': code, 'description': describeDtc(code)},
      ],
      if (idle != null) 'conditions': _conditions(rec, idle),
      'derived': _derived(rec, idle),
      'series': seriesOut,
    };
  }

  /// Холостой ход: скорость < 3 км/ч и обороты < 1100 (если обороты есть).
  /// Без скорости режимы не различить — тогда только общая статистика.
  static bool Function(int tMs)? _idleClassifier(Recording rec) {
    final speed = rec.series['speed'];
    if (speed == null || speed.isEmpty) return null;
    final rpm = rec.series['rpm'];
    return (tMs) {
      if (speed.valueNear(tMs) >= 3) return false;
      return rpm == null || rpm.isEmpty || rpm.valueNear(tMs) < 1100;
    };
  }

  static Map<String, Object?> _conditions(
    Recording rec,
    bool Function(int) idle,
  ) {
    final speed = rec.series['speed']!;
    var idleMs = 0;
    var drivingMs = 0;
    for (var i = 1; i < speed.length; i++) {
      final dt = speed.tMs[i] - speed.tMs[i - 1];
      if (idle(speed.tMs[i])) {
        idleMs += dt;
      } else {
        drivingMs += dt;
      }
    }
    return {'idle_s': idleMs ~/ 1000, 'driving_s': drivingMs ~/ 1000};
  }

  static Map<String, Object?> _derived(
    Recording rec,
    bool Function(int)? idle,
  ) {
    final out = <String, Object?>{};

    final coolant = rec.series['coolant'];
    if (coolant != null && coolant.isNotEmpty) {
      final reached = coolant.values.indexWhere((v) => v >= 80);
      out['coolant'] = {
        'start': _round(coolant.values.first, 0),
        'end': _round(coolant.values.last, 0),
        'max': _round(coolant.values.reduce(max), 0),
        'reached_80c_after_s': reached < 0
            ? null
            : coolant.tMs[reached] ~/ 1000,
      };
    }

    // Исправный узкополосный зонд до катализатора переключается через 0.45 В
    // несколько раз в секунду в замкнутом контуре; ленивый — заметно реже.
    final o2 = rec.series['o2_b1s1'];
    if (o2 != null && o2.length > 1) {
      final rate = <String, Object?>{};
      for (final (name, filter) in [
        ('all', (int _) => true),
        if (idle != null) ('idle', idle),
        if (idle != null) ('driving', (int t) => !idle(t)),
      ]) {
        var crossings = 0;
        var ms = 0;
        for (var i = 1; i < o2.length; i++) {
          if (!filter(o2.tMs[i])) continue;
          ms += o2.tMs[i] - o2.tMs[i - 1];
          if ((o2.values[i] - 0.45).sign != (o2.values[i - 1] - 0.45).sign) {
            crossings++;
          }
        }
        if (ms > 10000) rate[name] = _round(crossings / (ms / 60000), 1);
      }
      final intervals = [
        for (var i = 1; i < o2.length; i++) o2.tMs[i] - o2.tMs[i - 1],
      ]..sort();
      final interval = intervals[intervals.length ~/ 2] / 1000;
      out['o2_b1s1'] = {
        'crossings_per_min': rate,
        'sample_interval_s': _round(interval, 2),
        // Между двумя замерами видно не больше одного пересечения, а быстрые
        // переключения ещё и накладываются (алиасинг): это оценка снизу.
        'max_detectable_per_min': _round(60 / interval, 0),
      };
    }
    return out;
  }

  static Map<String, Object?> _stats(List<double> values, int digits) {
    final sorted = [...values]..sort();
    final mean = values.reduce((a, b) => a + b) / values.length;
    double pct(double p) => sorted[((sorted.length - 1) * p).round()];
    return {
      'min': _round(sorted.first, digits),
      'p10': _round(pct(0.1), digits),
      'median': _round(pct(0.5), digits),
      'p90': _round(pct(0.9), digits),
      'max': _round(sorted.last, digits),
      'mean': _round(mean, digits),
      'n': values.length,
    };
  }

  static num _round(double v, int digits) {
    if (digits <= 0) return v.round();
    final f = pow(10, digits);
    return (v * f).round() / f;
  }
}
