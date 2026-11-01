import 'dart:math';

import '../obd/pids.dart';
import '../session/recording.dart';

/// Неисправность, которую изображает симулятор. Нужны, чтобы проверять разбор ИИ
/// на данных с известным ответом.
enum SimScenario {
  healthy('Исправный двигатель', []),
  vacuumLeak('Подсос воздуха: бедная смесь на холостых', ['P0171']),
  thermostatStuckOpen('Термостат открыт: двигатель не прогревается', ['P0128']);

  const SimScenario(this.title, this.dtcs);

  final String title;
  final List<String> dtcs;
}

enum _Phase { idle, accel, cruise, decel }

/// «Двигатель» 1.6 л: значения параметров как функции времени от холодного пуска.
/// Цикл 120 с: холостой ход, разгон до 60 км/ч, движение, торможение, снова ХХ.
final class SimEngine {
  SimEngine(this.scenario, {int seed = 1}) : _random = Random(seed);

  final SimScenario scenario;
  final Random _random;

  /// Как у типичной машины: второго ряда и температуры масла нет.
  static const supportedPids = {
    0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, //
    0x10, 0x11, 0x14, 0x15, 0x1F, 0x2F, 0x33, 0x42, 0x46,
  };

  double _noise(double amplitude) => (_random.nextDouble() * 2 - 1) * amplitude;

  _Phase _phase(double t) {
    final c = t % 120;
    if (c < 30) return _Phase.idle;
    if (c < 45) return _Phase.accel;
    if (c < 90) return _Phase.cruise;
    if (c < 100) return _Phase.decel;
    return _Phase.idle;
  }

  double speed(double t) {
    final c = t % 120;
    return switch (_phase(t)) {
      _Phase.idle => 0,
      _Phase.accel => (c - 30) / 15 * 60,
      _Phase.cruise => 60 + 3 * sin(c / 4),
      _Phase.decel => 60 * (100 - c) / 10,
    };
  }

  double coolant(double t) => switch (scenario) {
    SimScenario.thermostatStuckOpen =>
      72 - 52 * exp(-t / 200) - (_phase(t) == _Phase.cruise ? 4 : 0),
    _ => min(90 - 70 * exp(-t / 150), 91),
  };

  double rpm(double t) {
    final c = t % 120;
    return switch (_phase(t)) {
      // Холодный двигатель держит повышенные холостые.
      _Phase.idle => 780 + max(0, 50 - coolant(t)) * 8,
      _Phase.accel => 1800 + 1700 * (((c - 30) / 5) % 1),
      _Phase.cruise => 2300 + speed(t) * 3,
      _Phase.decel => 1200 + speed(t) * 15,
    };
  }

  double load(double t) => switch (_phase(t)) {
    _Phase.idle => 22,
    _Phase.accel => 72,
    _Phase.cruise => 34,
    _Phase.decel => 12,
  };

  double throttle(double t) => switch (_phase(t)) {
    _Phase.idle => 3,
    _Phase.accel => 48,
    _Phase.cruise => 17,
    _Phase.decel => 0,
  };

  /// Объём 0.8 л за оборот, плотность воздуха 1.2 г/л.
  double maf(double t) => rpm(t) / 60 * 0.8 * 1.2 * load(t) / 100 * 1.1;

  /// Замкнутый контур по лямбде: прогретый зонд, не отсечка и не обогащение.
  bool _closedLoop(double t) =>
      coolant(t) > 40 && _phase(t) != _Phase.decel && _phase(t) != _Phase.accel;

  double stft(double t) {
    if (!_closedLoop(t)) return 0;
    final leak = scenario == SimScenario.vacuumLeak && _phase(t) == _Phase.idle
        ? 3
        : 0;
    return 3 * sin(2 * pi * 0.5 * t) + _noise(1) + leak;
  }

  /// Подсос — постоянный неучтённый воздух: на малом расходе его доля велика,
  /// на большом почти не видна. Поэтому коррекция падает с ростом MAF.
  double ltft(double t) => switch (scenario) {
    SimScenario.vacuumLeak => min(1.5 + 36 / max(maf(t), 2), 25),
    _ => 1.6,
  };

  double o2Upstream(double t) {
    if (coolant(t) < 40) return 0.45 + _noise(0.02);
    return switch (_phase(t)) {
      _Phase.decel => 0.05 + _noise(0.02),
      _Phase.accel => 0.85 + _noise(0.02),
      final phase => () {
        final f = phase == _Phase.idle ? 0.6 : 1.2;
        final lean = scenario == SimScenario.vacuumLeak && phase == _Phase.idle
            ? -0.1
            : 0.0;
        final wave = sin(2 * pi * f * t);
        return (0.45 + lean + 0.4 * _tanh(3 * wave)).clamp(0.02, 1.0);
      }(),
    };
  }

  static double _tanh(double x) {
    final e = exp(2 * x);
    return (e - 1) / (e + 1);
  }

  double o2Downstream(double t) => coolant(t) < 40 ? 0.45 : 0.68 + _noise(0.03);

  double timing(double t) => switch (_phase(t)) {
    _Phase.idle => 10 + _noise(2),
    _Phase.accel => 16 + _noise(1),
    _Phase.cruise => 32 + _noise(1),
    _Phase.decel => 25,
  };

  /// Значение PID в момент [t] (секунды от пуска) в физических единицах.
  double? value(int pid, double t) => switch (pid) {
    0x04 => load(t),
    0x05 => coolant(t),
    0x06 => stft(t),
    0x07 => ltft(t),
    0x0B => 22 + load(t) * 0.85,
    0x0C => rpm(t) + _noise(10),
    0x0D => speed(t),
    0x0E => timing(t),
    0x0F => 18 + (_phase(t) == _Phase.idle ? 6 : 0),
    0x10 => maf(t),
    0x11 => throttle(t),
    0x14 => o2Upstream(t),
    0x15 => o2Downstream(t),
    0x1F => t,
    0x2F => 62 - t / 600,
    0x33 => 99,
    0x42 => 14.1 + _noise(0.05),
    0x46 => 12,
    _ => null,
  };

  /// Сырые байты ответа на 01PID — обратные формулы к [standardPids].
  List<int>? mode01(int pid, double t) {
    if (pid % 0x20 == 0) {
      return encodeSupportedPids(pid, {
        ...supportedPids,
        // Бит «есть следующая группа».
        for (var next = 0x20; next <= 0xE0; next += 0x20)
          if (supportedPids.any((p) => p > next)) next,
      });
    }
    if (!supportedPids.contains(pid)) return null;
    final v = value(pid, t)!;
    int byte(num x) => x.round().clamp(0, 255);
    List<int> word(num x) {
      final w = x.round().clamp(0, 0xFFFF);
      return [w >> 8, w & 0xFF];
    }

    return switch (pid) {
      0x0C => word(v * 4),
      0x10 => word(v * 100),
      0x1F => word(v),
      0x42 => word(v * 1000),
      0x05 || 0x0F || 0x46 || 0x5C => [byte(v + 40)],
      0x04 || 0x11 || 0x2F => [byte(v * 255 / 100)],
      0x06 || 0x07 || 0x08 || 0x09 => [byte((v + 100) * 128 / 100)],
      0x0E => [byte((v + 64) * 2)],
      0x14 || 0x15 => [byte(v * 200), 0x80],
      _ => [byte(v)],
    };
  }
}

/// Готовая запись без адаптера: все поддерживаемые PID каждые [step].
/// Для отладки промпта и разбора ИИ на ПК (bin/demo.dart).
Recording simulateRecording(
  SimScenario scenario, {
  Duration duration = const Duration(minutes: 5),
  Duration step = const Duration(milliseconds: 500),
  DateTime? startedAt,
  int seed = 1,
}) {
  final engine = SimEngine(scenario, seed: seed);
  final start = startedAt ?? DateTime.utc(2026, 11, 1, 9);
  final rec = Recording(startedAt: start)..dtcs = [...scenario.dtcs];
  for (var ms = 0; ms <= duration.inMilliseconds; ms += step.inMilliseconds) {
    for (final pid in standardPids) {
      final raw = engine.mode01(pid.code, ms / 1000);
      final v = raw == null ? null : pid.decode(raw);
      if (v != null) rec.add(pid.key, start.add(Duration(milliseconds: ms)), v);
    }
  }
  return rec;
}
