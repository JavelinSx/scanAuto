import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scan_core/scan_core.dart';

import '../../core/wifi_binding.dart';

/// К чему подключаемся. Bluetooth Classic и BLE — этап 1.
sealed class AdapterTarget {
  const AdapterTarget();

  String get title;
}

final class SimulatorTarget extends AdapterTarget {
  const SimulatorTarget(this.scenario);

  final SimScenario scenario;

  @override
  String get title => 'Симулятор';
}

final class WifiTarget extends AdapterTarget {
  const WifiTarget(this.host, this.port);

  final String host;
  final int port;

  @override
  String get title => 'Wi-Fi $host';
}

enum ScanPhase { disconnected, connecting, live, failed }

@immutable
final class ScanState {
  const ScanState({
    this.phase = ScanPhase.disconnected,
    this.target,
    this.status,
    this.error,
    this.info,
    this.vin,
    this.dtcs = const [],
    this.pendingDtcs = const [],
    this.latest = const {},
    this.recording,
    this.revision = 0,
  });

  final ScanPhase phase;
  final AdapterTarget? target;
  final String? status;
  final String? error;
  final ElmInfo? info;
  final String? vin;
  final List<String> dtcs;
  final List<String> pendingDtcs;

  /// Последнее значение каждого PID.
  final Map<String, double> latest;

  /// Запись копится с момента подключения. Изменяется на месте,
  /// поэтому перерисовку запускает [revision].
  final Recording? recording;
  final int revision;

  ScanState copyWith({
    List<String>? dtcs,
    Map<String, double>? latest,
    int? revision,
  }) => ScanState(
    phase: phase,
    target: target,
    status: status,
    error: error,
    info: info,
    vin: vin,
    dtcs: dtcs ?? this.dtcs,
    pendingDtcs: pendingDtcs,
    latest: latest ?? this.latest,
    recording: recording,
    revision: revision ?? this.revision,
  );
}

final scanControllerProvider = NotifierProvider<ScanController, ScanState>(
  ScanController.new,
);

class ScanController extends Notifier<ScanState> {
  /// Сколько живых данных держим в памяти, пока записи не хранятся в базе (этап 2).
  /// Около 15 замеров в секунду — за 2 часа ~100 тыс. точек, единицы мегабайт.
  static const liveWindow = Duration(hours: 2);

  Elm327? _elm;
  StreamSubscription<Sample>? _samples;
  Timer? _publish;
  final _latest = <String, double>{};
  bool _dirty = false;

  /// Номер подключения: продолжения старого подключения после отмены не трогают состояние.
  int _generation = 0;

  bool _isCurrent(int generation) => ref.mounted && generation == _generation;

  /// Берём в build: в onDispose пользоваться ref уже нельзя.
  late WifiBinding _wifi;
  bool _wifiBound = false;

  @override
  ScanState build() {
    _wifi = ref.read(wifiBindingProvider);
    ref.onDispose(_teardown);
    return const ScanState();
  }

  Future<void> connect(AdapterTarget target) async {
    await _teardown();
    final generation = ++_generation;
    void status(String text) {
      if (_isCurrent(generation)) {
        state = ScanState(
          phase: ScanPhase.connecting,
          target: target,
          status: text,
        );
      }
    }

    try {
      if (target is WifiTarget) {
        status('Подключение к сети адаптера…');
        _wifiBound = true;
        await _wifi.bind();
      }
      status('Подключение к адаптеру…');
      final ObdTransport transport = switch (target) {
        SimulatorTarget(:final scenario) => SimulatedElm327(scenario: scenario),
        WifiTarget(:final host, :final port) => await TcpTransport.connect(
          host,
          port,
        ),
      };
      if (!_isCurrent(generation)) {
        await transport.close();
        return;
      }
      final elm = _elm = Elm327(transport);

      status('Поиск протокола машины… до 15 секунд');
      final info = await elm.initialize();
      status('Чтение VIN и ошибок…');
      final vin = await elm.readVin();
      final dtcs = await elm.readDtcs();
      final pending = await elm.readDtcs(mode: 0x07);
      if (!_isCurrent(generation)) return;

      final recording =
          Recording(
              startedAt: DateTime.now(),
              vehicle: VehicleInfo(vin: vin),
            )
            ..dtcs = dtcs
            ..pendingDtcs = pending;
      state = ScanState(
        phase: ScanPhase.live,
        target: target,
        info: info,
        vin: vin,
        dtcs: dtcs,
        pendingDtcs: pending,
        recording: recording,
      );

      final pids = [
        for (final p in standardPids)
          if (info.supportedPids.contains(p.code)) p,
      ];
      _samples = LiveSampler(elm, pids).run().listen((s) {
        recording.add(s.key, s.at, s.value);
        _latest[s.key] = s.value;
        _dirty = true;
      }, onError: (Object e) => _fail(generation, target, e));
      // Перерисовка 4 раза в секунду, а не на каждый ответ адаптера.
      _publish = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!_dirty) return;
        _dirty = false;
        recording.keepLast(liveWindow);
        state = state.copyWith(
          latest: Map.unmodifiable(_latest),
          revision: state.revision + 1,
        );
      });
    } catch (e) {
      await _fail(generation, target, e);
    }
  }

  Future<void> _fail(int generation, AdapterTarget target, Object error) async {
    if (!_isCurrent(generation)) return;
    await _teardown();
    if (!_isCurrent(generation)) return;
    state = ScanState(
      phase: ScanPhase.failed,
      target: target,
      error: describeScanError(error),
    );
  }

  /// Сброс ошибок встаёт в очередь команд между запросами опроса.
  Future<void> clearDtcs() async {
    final elm = _elm;
    if (elm == null) return;
    await elm.clearDtcs();
    final dtcs = await elm.readDtcs();
    if (!ref.mounted || elm != _elm) return;
    state.recording?.dtcs = dtcs;
    state = state.copyWith(dtcs: dtcs);
  }

  Future<void> disconnect() async {
    _generation++;
    state = const ScanState();
    await _teardown();
  }

  Future<void> _teardown() async {
    _publish?.cancel();
    _publish = null;
    final samples = _samples;
    final elm = _elm;
    _samples = null;
    _elm = null;
    _latest.clear();
    _dirty = false;
    // Закрываем адаптер, не дожидаясь отмены: ждущий запрос опроса падает сразу,
    // иначе отмена ждала бы его ответа или тайм-аута. Эта ошибка приходит
    // в future отмены — обработчик вешаем до закрытия.
    final cancelled = samples?.cancel().catchError((Object _) {});
    await elm?.close();
    await cancelled;
    if (_wifiBound) {
      _wifiBound = false;
      await _wifi.release();
    }
  }
}

String describeScanError(Object e) => switch (e) {
  ElmException(error: ElmError.unableToConnect) =>
    'Машина не отвечает. Включите зажигание и проверьте, что адаптер '
        'вставлен в разъём OBD до упора.',
  ElmException(:final error) => 'Адаптер ответил ошибкой: ${error.name}.',
  ElmTimeoutException() =>
    'Адаптер перестал отвечать. Переподключите его к разъёму.',
  ElmDisconnectedException() => 'Связь с адаптером потеряна.',
  SocketException() =>
    'Не удалось подключиться по Wi-Fi. Подключите телефон к сети адаптера '
        '(обычно «OBDII» или «WiFi_OBDII») и проверьте адрес.',
  _ => 'Ошибка: $e',
};
