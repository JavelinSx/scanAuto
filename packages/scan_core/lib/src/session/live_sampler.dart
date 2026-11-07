import '../elm327/elm327.dart';
import '../elm327/elm_response.dart';
import '../obd/pids.dart';

final class Sample {
  const Sample(this.key, this.at, this.value);

  final String key;
  final DateTime at;
  final double value;
}

/// Опрос PID по кругу. Быстрые параметры — в каждом круге, медленные (температуры,
/// топливо, напряжение) — по одному за круг: клон ELM327 по Bluetooth отвечает
/// 10–20 раз в секунду, на всё сразу частоты не хватит.
class LiveSampler {
  LiveSampler(
    this._elm,
    this._pids, {
    Set<String> focus = fastKeys,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    setFocus(focus);
  }

  static const fastKeys = {
    'rpm',
    'speed',
    'load',
    'throttle',
    'maf',
    'map',
    'stft1',
    'stft2',
    'o2_b1s1',
    'timing',
  };

  /// Столько тайм-аутов подряд — и считаем, что адаптер пропал.
  static const maxTimeoutsInRow = 5;

  final Elm327 _elm;
  final List<Pid> _pids;
  List<Pid> fast = const [];
  List<Pid> slow = const [];
  final DateTime Function() _now;

  /// Сменить набор быстрых параметров — со следующего круга.
  /// Программа диагностики меняет его по прогонам этапа.
  void setFocus(Set<String> keys) {
    fast = [
      for (final p in _pids)
        if (keys.contains(p.key)) p,
    ];
    slow = [
      for (final p in _pids)
        if (!keys.contains(p.key)) p,
    ];
  }

  /// Бесконечный поток значений; опрос останавливается отменой подписки.
  /// Ошибки отдельных запросов пропускаются, отключение адаптера — ошибка потока.
  Stream<Sample> run() async* {
    var slowIndex = 0;
    var timeoutsInRow = 0;
    while (true) {
      final round = [
        ...fast,
        if (slow.isNotEmpty) slow[slowIndex++ % slow.length],
      ];
      if (round.isEmpty) return;
      for (final pid in round) {
        double? value;
        try {
          value = await _elm.readPid(pid);
          timeoutsInRow = 0;
        } on ElmTimeoutException {
          if (++timeoutsInRow >= maxTimeoutsInRow) rethrow;
          continue;
        } on ElmException {
          // STOPPED, CAN ERROR, BUFFER FULL — разовые сбои шины, следующий круг их перекроет.
          continue;
        }
        if (value != null) yield Sample(pid.key, _now(), value);
      }
    }
  }
}
