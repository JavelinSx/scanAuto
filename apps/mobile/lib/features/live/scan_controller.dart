import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scan_core/scan_core.dart';

import '../../core/adapter_store.dart';
import '../../core/bluetooth_classic.dart';
import '../../core/session_log.dart';
import '../../core/wifi_binding.dart';

/// К чему подключаемся. BLE — позже.
sealed class AdapterTarget {
  const AdapterTarget();

  String get title;
}

final class SimulatorTarget extends AdapterTarget {
  const SimulatorTarget(this.scenario, {this.speed = 1});

  final SimScenario scenario;

  /// Ускорение времени: 20 — программа диагностики проходит примерно за минуту.
  final int speed;

  @override
  String get title => speed > 1 ? 'Симулятор ×$speed' : 'Симулятор';
}

final class WifiTarget extends AdapterTarget {
  const WifiTarget(this.host, this.port);

  final String host;
  final int port;

  @override
  String get title => 'Wi-Fi $host';
}

/// Спаренный в настройках Android адаптер Bluetooth Classic.
final class BluetoothTarget extends AdapterTarget {
  const BluetoothTarget(this.address, this.name);

  final String address;
  final String name;

  @override
  String get title => name.isEmpty ? address : name;
}

/// [finished] — адаптер отключён, запись осталась: программа пройдена или
/// остановлена, можно отправлять на разбор.
enum ScanPhase { disconnected, connecting, live, finished, failed }

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
    this.program,
    this.programStatus,
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

  /// Программа диагностики, если сеанс идёт по ней.
  final DiagnosticProgram? program;
  final ProgramStatus? programStatus;

  ScanState copyWith({
    ScanPhase? phase,
    String? error,
    List<String>? dtcs,
    Map<String, double>? latest,
    int? revision,
    ProgramStatus? programStatus,
  }) => ScanState(
    phase: phase ?? this.phase,
    target: target,
    status: status,
    error: error ?? this.error,
    info: info,
    vin: vin,
    dtcs: dtcs ?? this.dtcs,
    pendingDtcs: pendingDtcs,
    latest: latest ?? this.latest,
    recording: recording,
    revision: revision ?? this.revision,
    program: program,
    programStatus: programStatus ?? this.programStatus,
  );
}

/// Версия сборки: релизный CI передаёт её через `--dart-define=APP_VERSION`.
/// Нужна, чтобы по журналу понять, какой сборкой сделан прогон.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

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
  SimulatedElm327? _sim;
  final _latest = <String, double>{};
  bool _dirty = false;

  // Сеанс: переживает обрыв связи, чтобы переподключиться и продолжить
  // ту же запись и ту же программу.
  AdapterTarget? _target;
  DiagnosticProgram? _program;
  VehicleInfo? _vehicle;
  Recording? _recording;
  ProgramRunner? _runner;
  int _runIndex = 0;
  int _loggedSegments = 0;
  int _lastSnapshotMs = 0;
  int _lastSnapshotSamples = 0;
  bool _recordingSaved = false;
  SessionLog _log = const NoopSessionLog();

  /// Время записи. У ускоренного симулятора идёт быстрее настоящего —
  /// этапы программы меряются именно им.
  Stopwatch? _watch;
  int _speed = 1;
  Duration _elapsed() => (_watch?.elapsed ?? Duration.zero) * _speed;
  int _nowMs() => _elapsed().inMilliseconds;

  /// Номер подключения: продолжения старого подключения после отмены не трогают состояние.
  int _generation = 0;

  bool _isCurrent(int generation) => ref.mounted && generation == _generation;

  // Берём в build: в onDispose пользоваться ref уже нельзя.
  late WifiBinding _wifi;
  late BluetoothClassic _bluetooth;
  late AdapterStore _adapters;
  late Future<SessionLog> Function() _openLog;
  bool _wifiBound = false;

  @override
  ScanState build() {
    _wifi = ref.read(wifiBindingProvider);
    _bluetooth = ref.read(bluetoothProvider);
    _adapters = ref.read(adapterStoreProvider);
    _openLog = ref.read(sessionLogFactoryProvider);
    ref.onDispose(() async {
      await _teardown();
      await _closeLog();
    });
    return const ScanState();
  }

  /// Новый сеанс. С [program] он идёт по программе диагностики: этапы сменяются сами,
  /// по окончании адаптер отключается, запись остаётся для разбора.
  Future<void> connect(
    AdapterTarget target, {
    DiagnosticProgram? program,
    VehicleInfo? vehicle,
  }) async {
    final generation = ++_generation;
    await _teardown();
    await _closeLog();
    _target = target;
    _program = program;
    _vehicle = vehicle;
    _recording = null;
    _runner = null;
    _runIndex = 0;
    _loggedSegments = 0;
    _lastSnapshotMs = 0;
    _lastSnapshotSamples = 0;
    _recordingSaved = false;
    _speed = target is SimulatorTarget ? target.speed : 1;
    _watch = Stopwatch()..start();
    _log = await _openLog();
    _log.write(
      'session',
      'старт: ${target.title}'
          '${program == null ? '' : ', программа ${program.season.name}'}'
          '${vehicle == null ? '' : ', ${vehicle.displayName}'}'
          ', версия приложения $appVersion',
    );
    if (vehicle != null) {
      _log.write('session', 'профиль ${jsonEncode(vehicle.forModel())}');
    }
    if (program != null) {
      _log.write(
        'program',
        [
          for (final s in program.stages)
            '${s.title}: цель ${s.target.inSeconds} с, '
                'от ${s.minDuration.inSeconds} до ${s.maxDuration.inSeconds} с, '
                'прогоны ${[for (final r in s.runs) '«${r.title}» ${r.fastKeys.join(',')}'].join('; ')}',
        ].join(' | '),
      );
    }
    if (!_isCurrent(generation)) return;
    await _open(generation);
  }

  /// Переподключиться к тому же адаптеру после обрыва. Запись и программа
  /// продолжаются; время без связи этапы не засчитывают.
  Future<void> reconnect() async {
    if (_target == null) return;
    final generation = ++_generation;
    await _teardown();
    _log.write('session', 'переподключение');
    await _open(generation);
  }

  bool get canResume => _recording != null && _runner?.finished != true;

  Future<void> _open(int generation) async {
    final target = _target!;
    final program = _program;
    final resume = _recording != null;
    void status(String text) {
      _log.write('status', text);
      if (_isCurrent(generation)) {
        state = ScanState(
          phase: ScanPhase.connecting,
          target: target,
          status: text,
          program: program,
          recording: _recording,
          programStatus: resume ? state.programStatus : null,
        );
      }
    }

    try {
      if (target is WifiTarget) {
        status('Подключение к сети адаптера…');
        _wifiBound = true;
        final bound = await _wifi.bind();
        _log.write('wifi', 'привязка к сети адаптера: $bound');
      }
      status('Подключение к адаптеру…');
      final ObdTransport transport = switch (target) {
        SimulatorTarget(:final scenario) => _sim = SimulatedElm327(
          scenario: scenario,
          clock: _elapsed,
          latency: Duration(milliseconds: _speed > 1 ? 5 : 25),
          ambient: program?.season == Season.winter ? -10 : 20,
        ),
        WifiTarget(:final host, :final port) => await TcpTransport.connect(
          host,
          port,
        ),
        BluetoothTarget(:final address) => await _bluetooth.connect(address),
      };
      if (transport is BluetoothTransport) {
        _log.write('bt', 'сокет открыт способом ${transport.method}');
      }
      if (!_isCurrent(generation)) {
        await transport.close();
        return;
      }
      final elm = _elm = Elm327(transport, log: (l) => _log.write('elm', l));

      status('Поиск протокола машины… до 15 секунд');
      final info = await elm.initialize();
      _log.write(
        'elm',
        'адаптер ${info.version}, протокол ${info.protocol} (${info.protocolName}), '
            'PID: ${[for (final p in info.supportedPids) hexByte(p)].join(' ')}',
      );
      status('Чтение ошибок…');
      final vin = resume ? state.vin : await elm.readVin();
      final dtcs = await elm.readDtcs();
      final pending = await elm.readDtcs(mode: 0x07);
      _log.write(
        'dtc',
        'сохранённые: ${dtcs.join(', ')}; ожидающие: ${pending.join(', ')}'
            '${vin == null ? '; VIN не прочитан' : '; VIN прочитан'}',
      );
      if (!_isCurrent(generation)) return;
      unawaited(
        _adapters.saveLast(target).then((_) {
          if (ref.mounted) ref.invalidate(lastAdapterProvider);
        }),
      );

      final Recording recording;
      if (resume) {
        recording = _recording!..dtcs = dtcs;
      } else {
        // Время записи — с этого момента: у симулятора и «двигатель» стартует здесь.
        _watch!.reset();
        recording = _recording =
            Recording(
                startedAt: DateTime.now(),
                vehicle: _vehicle?.withVin(vin) ?? VehicleInfo(vin: vin),
              )
              ..dtcs = dtcs
              ..pendingDtcs = pending;
        _runner = program == null ? null : ProgramRunner(program, recording);
      }
      final runner = _runner;
      DateTime now() => recording.startedAt.add(_elapsed());

      state = ScanState(
        phase: ScanPhase.live,
        target: target,
        info: info,
        vin: vin,
        dtcs: dtcs,
        pendingDtcs: pending,
        recording: recording,
        program: program,
        programStatus: resume ? state.programStatus : null,
      );

      final pids = [
        for (final p in standardPids)
          if (info.supportedPids.contains(p.code)) p,
      ];
      final sampler = LiveSampler(
        elm,
        pids,
        focus: runner?.stage.runs[_runIndex].fastKeys ?? LiveSampler.fastKeys,
        now: now,
      );
      _sim?.drive = simDriveFor(runner?.stage.kind ?? StageKind.city);
      _samples = sampler.run().listen((s) {
        recording.add(s.key, s.at, s.value);
        _latest[s.key] = s.value;
        _dirty = true;
      }, onError: (Object e) => _fail(generation, e));

      // Перерисовка 4 раза в секунду, а не на каждый ответ адаптера.
      _publish = Timer.periodic(const Duration(milliseconds: 250), (_) {
        // Этапы считаем, когда пришли первые замеры: прогреву нужна стартовая
        // температура, иначе не понять, был ли двигатель холодным.
        final status =
            runner != null &&
                (recording.series.containsKey('coolant') || _nowMs() > 10000)
            ? runner.update(_nowMs())
            : null;
        if (status != null && status.runChanged && !status.finished) {
          final stage = runner!.stage;
          _runIndex = status.runIndex;
          sampler.setFocus(stage.runs[_runIndex].fastKeys);
          _sim?.drive = simDriveFor(stage.kind);
          _log.write(
            'program',
            '${status.stageChanged ? 'этап «${stage.title}», ' : ''}'
                'прогон «${stage.runs[_runIndex].title}»',
          );
        }
        _logStages();
        _logSnapshot(recording);
        if (!_dirty && status == null) return;
        _dirty = false;
        if (runner == null) recording.keepLast(liveWindow);
        state = state.copyWith(
          latest: Map.unmodifiable(_latest),
          revision: state.revision + 1,
          programStatus: status,
        );
        if (status?.finished ?? false) unawaited(_finish(generation));
      });
    } catch (e, st) {
      _log.write('error', '$e\n$st');
      await _fail(generation, e);
    }
  }

  /// Итог каждого закрытого этапа — в журнал сразу, не дожидаясь конца программы:
  /// если связь оборвётся или приложение упадёт, пройденные этапы уже записаны.
  void _logStages() {
    final rec = _recording;
    if (rec == null) return;
    while (_loggedSegments < rec.segments.length) {
      final seg = rec.segments[_loggedSegments++];
      final summary = AnalysisPacket.stage(rec, seg);
      final medians = [
        for (final MapEntry(:key, :value)
            in (summary['stats']! as Map<String, Object?>).entries)
          '$key=${(value! as Map)['median']}',
      ].join(' ');
      _log.write(
        'stage',
        'конец «${seg.title}»: ${(seg.endMs - seg.startMs) ~/ 1000} с, '
            '${seg.completed ? 'цель достигнута' : 'цель не достигнута'}'
            '${seg.note == null ? '' : ' (${seg.note})'}; '
            'признаки ${jsonEncode(summary['derived'])}; медианы $medians',
      );
    }
  }

  /// Снимок последних значений раз в 30 с времени записи и сколько замеров
  /// пришло за это время — по нему видно скорость адаптера и провалы связи.
  void _logSnapshot(Recording rec) {
    final now = _nowMs();
    if (now - _lastSnapshotMs < 30000) return;
    var samples = 0;
    for (final s in rec.series.values) {
      samples += s.length;
    }
    final perSecond =
        (samples - _lastSnapshotSamples) / ((now - _lastSnapshotMs) / 1000);
    _lastSnapshotMs = now;
    _lastSnapshotSamples = samples;
    final runner = _runner;
    final where = runner == null || runner.finished
        ? ''
        : '${runner.stage.title}/${runner.stage.runs[_runIndex].title}, ';
    final values = [
      for (final MapEntry(:key, :value) in _latest.entries)
        '$key=${value.toStringAsFixed(pidsByKey[key]?.decimals ?? 1)}',
    ].join(' ');
    _log.write(
      'snapshot',
      '${where}t=${now ~/ 1000} с, ${perSecond.toStringAsFixed(1)} замеров/с; $values',
    );
  }

  /// Водитель закончил текущий этап раньше.
  void skipStage() {
    _log.write('program', 'этап закончен водителем');
    _runner?.skip(_nowMs());
    _logStages();
  }

  /// Остановить программу или запись: адаптер отключается, запись остаётся.
  Future<void> stop() async {
    _log.write('program', 'остановлено водителем');
    _runner?.abort(_nowMs());
    _logStages();
    await _finish(_generation);
  }

  /// После обрыва — не переподключаться, а разбирать то, что есть.
  Future<void> finalize() async {
    _runner?.abort(_nowMs());
    _logStages();
    await _saveRecording();
    if (ref.mounted && state.phase == ScanPhase.failed) {
      state = state.copyWith(phase: ScanPhase.finished);
    }
  }

  Future<void> _finish(int generation) async {
    if (!_isCurrent(generation) || state.phase != ScanPhase.live) return;
    // Отключаем адаптер сразу: после него (и снятия привязки к Wi-Fi)
    // у приложения снова есть интернет для запроса к модели.
    state = state.copyWith(phase: ScanPhase.finished);
    _logStages();
    _log.write('session', 'конец, этапы: ${_segmentsSummary()}');
    await _teardown();
    await _saveRecording();
  }

  Future<void> _fail(int generation, Object error) async {
    if (!_isCurrent(generation)) return;
    _log.write('error', 'обрыв: ${describeScanError(error)} ($error)');
    await _teardown();
    if (!_isCurrent(generation)) return;
    // Запись до обрыва сохраняется: можно переподключиться и продолжить
    // или разобрать то, что есть.
    state = ScanState(
      phase: ScanPhase.failed,
      target: _target,
      error: describeScanError(error),
      recording: state.recording,
      program: state.program,
      programStatus: state.programStatus,
      vin: state.vin,
      dtcs: state.dtcs,
      pendingDtcs: state.pendingDtcs,
      info: state.info,
    );
  }

  String _segmentsSummary() => [
    for (final s in _recording?.segments ?? const <RecordingSegment>[])
      '${s.key} ${(s.endMs - s.startMs) ~/ 1000} с'
          '${s.completed ? '' : ' (не выполнен${s.note == null ? '' : ': ${s.note}'})'}',
  ].join('; ');

  /// Запись в JSON рядом с журналом — один раз за сеанс.
  Future<void> _saveRecording() async {
    final rec = _recording;
    if (rec == null || rec.series.isEmpty || _recordingSaved) return;
    _recordingSaved = true;
    try {
      await _log.saveRecording(rec);
    } on Object catch (e) {
      _log.write('error', 'запись не сохранилась: $e');
    }
  }

  /// Для журнала: что ушло в модель и что вернулось (без ключа).
  void logAi(String message) => _log.write('ai', message);

  /// Сброс ошибок встаёт в очередь команд между запросами опроса.
  Future<void> clearDtcs() async {
    final elm = _elm;
    if (elm == null) return;
    _log.write('dtc', 'сброс ошибок');
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
    await _saveRecording();
    await _closeLog();
    _recording = null;
    _runner = null;
    _target = null;
  }

  Future<void> _closeLog() async {
    final log = _log;
    _log = const NoopSessionLog();
    await log.close();
  }

  Future<void> _teardown() async {
    _publish?.cancel();
    _publish = null;
    final samples = _samples;
    final elm = _elm;
    _samples = null;
    _elm = null;
    _sim = null;
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
  BluetoothException(code: 'bluetooth_off') => 'Включите Bluetooth.',
  BluetoothException(code: 'permission_denied') =>
    'Нет разрешения на Bluetooth. Разрешите «Устройства поблизости» '
        'в настройках приложения.',
  BluetoothException(code: 'connect_failed') =>
    'Не удалось подключиться к адаптеру по Bluetooth. Проверьте, что он в разъёме, '
        'зажигание включено и адаптер не занят другим приложением.',
  BluetoothException(:final message) => 'Bluetooth: $message',
  _ => 'Ошибка: $e',
};
