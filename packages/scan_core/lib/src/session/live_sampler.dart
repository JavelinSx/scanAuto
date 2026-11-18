import 'dart:math';

import '../elm327/elm327.dart';
import '../elm327/elm_response.dart';
import '../hex.dart';
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
    this.rawCommands = const [],
    this.onRaw,
    this.rawEveryRounds = 4,
    this.rawHeader,
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

  /// Запросы производителя (например, '2101'): раз в [rawEveryRounds] кругов,
  /// ответ — сырой hex в [onRaw]. Расшифровки пока нет, поэтому реже PID.
  final List<String> rawCommands;
  final void Function(String command, DateTime at, String hex)? onRaw;
  final int rawEveryRounds;

  /// Заголовок для запросов производителя (на CAN — '7E0', двигатель); после них
  /// возвращается функциональный 7DF, чтобы обычный опрос шёл как раньше.
  final String? rawHeader;
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
    var rounds = 0;
    var cycle = 0;
    // Заголовок переключён на адрес двигателя и ещё не возвращён на 7DF.
    var headerChanged = false;
    while (true) {
      // Смена заголовка — такой же запрос, как остальные: один потерянный ответ
      // не повод рвать сеанс, считаем подряд вместе с остальными тайм-аутами.
      if (onRaw != null &&
          rawCommands.isNotEmpty &&
          rounds++ % rawEveryRounds == 0) {
        try {
          if (rawHeader case final h?) {
            headerChanged = true;
            await _elm.send('ATSH$h');
          }
          for (final command in rawCommands) {
            try {
              final raw = await _elm.send(command);
              final messages = parseObdResponse(raw, command: command);
              if (messages.isNotEmpty) {
                onRaw!(
                  command,
                  _now(),
                  formatHex(messages.first, spaces: false),
                );
              }
              timeoutsInRow = 0;
            } on ElmException {
              // Блок не ответил на этот раз — следующий круг.
            }
          }
        } on ElmTimeoutException {
          if (++timeoutsInRow >= maxTimeoutsInRow) rethrow;
        }
      }
      if (headerChanged) {
        try {
          await _elm.send('ATSH7DF');
          headerChanged = false;
        } on ElmTimeoutException {
          // Не вернулся — повторим перед следующим кругом.
          if (++timeoutsInRow >= maxTimeoutsInRow) rethrow;
        }
      }
      final slowCount = _slowPerRound(cycle++);
      final round = [
        ...fast,
        for (var i = 0; i < slowCount && slow.isNotEmpty; i++)
          slow[slowIndex++ % slow.length],
      ];
      if (round.isEmpty) return;
      // Пачки по 6 PID, если блок отвечает на несколько сразу, иначе по одному.
      final batch = _elm.info?.multiPid ?? false ? Elm327.maxPidsPerRequest : 1;
      for (var i = 0; i < round.length; i += batch) {
        final chunk = round.sublist(i, min(i + batch, round.length));
        Map<String, double> values;
        try {
          values = await _elm.readPids(chunk);
          timeoutsInRow = 0;
        } on ElmTimeoutException {
          if (++timeoutsInRow >= maxTimeoutsInRow) rethrow;
          continue;
        } on ElmException {
          // STOPPED, CAN ERROR, BUFFER FULL — разовые сбои шины, следующий круг их перекроет.
          continue;
        }
        final at = _now();
        for (final pid in chunk) {
          if (values[pid.key] case final v?) yield Sample(pid.key, at, v);
        }
      }
    }
  }

  /// Медленных PID в круг: по одному запросу на PID — один; пачками — сколько
  /// влезает в последнюю пачку быстрых, а если она полная — целая пачка раз в
  /// три круга, чтобы быстрые не замедлялись вдвое.
  int _slowPerRound(int cycle) {
    if (!(_elm.info?.multiPid ?? false)) return 1;
    const cap = Elm327.maxPidsPerRequest;
    if (fast.isEmpty) return cap;
    final free = (cap - fast.length % cap) % cap;
    if (free > 0) return free;
    return cycle % 3 == 0 ? cap : 0;
  }
}
