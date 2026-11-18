import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scan_core/scan_core.dart';

import '../../core/adapter_store.dart';
import '../../core/background_session.dart';
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
    this.staleSeconds = 0,
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

  /// Сколько секунд от адаптера нет ни одного замера (0 — данные идут).
  /// Значения в [latest] тогда устаревшие, и экран должен это показать.
  final int staleSeconds;

  ScanState copyWith({
    ScanPhase? phase,
    String? error,
    List<String>? dtcs,
    Map<String, double>? latest,
    int? revision,
    ProgramStatus? programStatus,
    int? staleSeconds,
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
    staleSeconds: staleSeconds ?? this.staleSeconds,
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

  /// Столько раз подряд переподключаемся сами, прежде чем показать экран обрыва.
  static const maxAutoReconnects = 3;

  /// Пауза перед автоматическим переподключением: адаптеру нужно закрыть сокет.
  @visibleForTesting
  static Duration autoReconnectDelay = const Duration(seconds: 2);

  /// С этого порога экран показывает, что данные не идут.
  static const staleAfterSeconds = 3;

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

  /// Автоматические переподключения подряд; замер от адаптера обнуляет счёт.
  int _autoReconnects = 0;

  /// Идёт [_finish]: конец сеанса читается один раз.
  bool _finishing = false;

  /// Запросы данных производителя (`21 01`, `22 00 01`), на которые блок ответил
  /// при разведке: их ответы пишутся в запись сырыми, расшифровка — по журналам.
  List<String> _dataBlocks = const [];
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
  late BackgroundSession _background;

  /// Время последнего замера по часам телефона: пауза больше 5 с — в журнал.
  /// Так видно, что Android приостанавливал приложение или адаптер молчал.
  DateTime? _lastSampleWall;
  bool _wifiBound = false;

  @override
  ScanState build() {
    _wifi = ref.read(wifiBindingProvider);
    _bluetooth = ref.read(bluetoothProvider);
    _adapters = ref.read(adapterStoreProvider);
    _openLog = ref.read(sessionLogFactoryProvider);
    _background = ref.read(backgroundSessionProvider);
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
    _autoReconnects = 0;
    _dataBlocks = const [];
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
    _autoReconnects = 0;
    await _reconnect();
  }

  Future<void> _reconnect() async {
    if (_target == null) return;
    final generation = ++_generation;
    await _teardown();
    _log.write('session', 'переподключение');
    await _open(generation);
  }

  bool get canResume => _recording != null && _runner?.finished != true;

  Future<void> _open(int generation) async {
    _finishing = false;
    final target = _target!;
    final program = _program;
    final resume = _recording != null;
    // VIN при продолжении не перечитываем: берём из прошлого подключения.
    final resumedVin = resume ? state.vin : null;
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
          vin: resumedVin,
          dtcs: resume ? state.dtcs : const [],
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
      final preferred = await _adapters.loadProtocol(target);
      final info = await elm.initialize(
        onProgress: status,
        preferred: preferred,
      );
      if (info.protocolKey case final key? when key != preferred) {
        unawaited(_adapters.saveProtocol(target, key));
        _log.write('session', 'протокол $key запомнен для ${target.title}');
      }
      _log.write(
        'elm',
        'адаптер ${info.version}, протокол ${info.protocol} (${info.protocolName})'
            '${info.attempt == null ? ', автопоиск' : ', найден перебором: ${info.attempt}'}'
            ', напряжение ${info.voltage ?? '?'} В, '
            'PID: ${[for (final p in info.supportedPids) hexByte(p)].join(' ')}',
      );
      status('Чтение ошибок…');
      // Связь есть, но шина может быть неустойчивой: коды и VIN не прочитались —
      // не повод обрывать сеанс, опрос параметров важнее.
      Future<T> tolerant<T>(
        String what,
        Future<T> Function() read,
        T empty,
      ) async {
        try {
          return await read();
        } on ElmException catch (e) {
          _log.write('dtc', '$what не прочитаны: ${e.error.name}');
          return empty;
        } on ElmTimeoutException {
          _log.write('dtc', '$what не прочитаны: тайм-аут');
          return empty;
        }
      }

      final vin = resume ? resumedVin : await elm.readVin();
      final dtcs = await tolerant('коды', elm.readDtcs, const <String>[]);
      final pending = await tolerant(
        'ожидающие коды',
        () => elm.readDtcs(mode: 0x07),
        const <String>[],
      );
      _log.write(
        'dtc',
        'сохранённые: ${dtcs.join(', ')}; ожидающие: ${pending.join(', ')}'
            '${vin == null ? '; VIN не прочитан' : '; VIN прочитан'}',
      );
      if (info.isCan && !resume) await _probeEcu(elm, status);
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
      // Пропуски по цилиндрам на старте — чтобы в конце было с чем сравнить.
      if (!resume) {
        await _readMisfires(elm, recording, 'начало');
        status('Готовность самопроверок и бортовые тесты…');
        await _readChecks(elm, recording, 'начало');
      }
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
        rawCommands: _dataBlocks,
        rawHeader: '7E0',
        onRaw: recording.addRaw,
      );
      _sim?.drive = simDriveFor(runner?.stage.kind ?? StageKind.city);
      _lastSampleWall = null;
      unawaited(
        _startBackground(
          runner == null
              ? 'Идёт запись: ${target.title}'
              : 'Программа: ${runner.stage.title}',
        ),
      );
      _samples = sampler.run().listen((s) {
        final wall = DateTime.now();
        final last = _lastSampleWall;
        if (last != null && wall.difference(last).inSeconds >= 5) {
          _log.write(
            'gap',
            'нет замеров ${wall.difference(last).inSeconds} с '
                '(экран выключен без службы, приложение свёрнуто или адаптер молчал)',
          );
        }
        _lastSampleWall = wall;
        _autoReconnects = 0;
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
          if (status.stageChanged) {
            unawaited(_background.start('Программа: ${stage.title}'));
          }
          _log.write(
            'program',
            '${status.stageChanged ? 'этап «${stage.title}», ' : ''}'
                'прогон «${stage.runs[_runIndex].title}»',
          );
        }
        _logStages();
        _logSnapshot(recording);
        final stale = _staleSeconds();
        if (!_dirty && status == null && stale == state.staleSeconds) return;
        _dirty = false;
        if (runner == null) recording.keepLast(liveWindow);
        state = state.copyWith(
          latest: Map.unmodifiable(_latest),
          revision: state.revision + 1,
          programStatus: status,
          staleSeconds: stale,
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

  /// Секунды без замеров по часам телефона; меньше порога — 0, чтобы не
  /// перерисовывать экран каждую секунду, пока всё в порядке.
  int _staleSeconds() {
    final last = _lastSampleWall;
    if (last == null) return 0;
    final seconds = DateTime.now().difference(last).inSeconds;
    return seconds < staleAfterSeconds ? 0 : seconds;
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
    if (state.phase == ScanPhase.live) {
      await _finish(_generation);
      return;
    }
    // Идёт переподключение: бросаем его, записанное остаётся для разбора.
    _generation++;
    await _teardown();
    await _saveRecording();
    if (ref.mounted && _recording != null) {
      _log.write('session', 'конец, этапы: ${_segmentsSummary()}');
      state = state.copyWith(phase: ScanPhase.finished);
    }
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
    // Таймер перерисовки видит «программа закончена» каждые 250 мс, а чтение
    // пропусков и бортовых тестов в конце идёт секунды — второй вызов не нужен.
    if (_finishing) return;
    _finishing = true;
    // Отключаем адаптер сразу: после него (и снятия привязки к Wi-Fi)
    // у приложения снова есть интернет для запроса к модели.
    // Пропуски за поездку — пока адаптер ещё подключён.
    final elm = _elm;
    final rec = _recording;
    if (elm != null && rec != null) {
      await _readMisfires(elm, rec, 'конец');
      await _readChecks(elm, rec, 'конец');
    }
    if (!_isCurrent(generation)) return;
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
    if (_canAutoReconnect(error)) {
      _autoReconnects++;
      _log.write(
        'session',
        'автопереподключение $_autoReconnects из $maxAutoReconnects',
      );
      state = ScanState(
        phase: ScanPhase.connecting,
        target: _target,
        status:
            'Связь с адаптером пропала — переподключаюсь, '
            'попытка $_autoReconnects из $maxAutoReconnects…',
        recording: state.recording,
        program: state.program,
        programStatus: state.programStatus,
        vin: state.vin,
        dtcs: state.dtcs,
        pendingDtcs: state.pendingDtcs,
        info: state.info,
      );
      await Future<void>.delayed(autoReconnectDelay);
      if (!_isCurrent(generation)) return;
      await _reconnect();
      return;
    }
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

  /// Связь пропала посреди записи (адаптер замолчал, Bluetooth оборвался,
  /// приложение замораживали в фоне) — пробуем вернуться сами. Если машина
  /// не отвечает или нет разрешений, переподключение не поможет.
  bool _canAutoReconnect(Object error) =>
      _target is! SimulatorTarget &&
      canResume &&
      _autoReconnects < maxAutoReconnects &&
      switch (error) {
        ElmTimeoutException() || ElmDisconnectedException() => true,
        BluetoothException(:final code) =>
          code != 'permission_denied' && code != 'bluetooth_off',
        SocketException() => true,
        _ => false,
      };

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

  /// Разведка блока двигателя: что он отвечает сверх стандартного OBD. Только
  /// чтение. Не мешает сеансу: любая ошибка — в журнал, опрос идёт как обычно.
  Future<void> _probeEcu(Elm327 elm, void Function(String) status) async {
    status('Опрос блока двигателя…');
    try {
      final probe = EcuProbe(elm);
      for (final r in await probe.run(isCan: true)) {
        _log.write(
          'vaz',
          '${r.title}: ${r.command} → ${r.raw}'
              '${r.positive == null
                  ? ''
                  : r.positive!
                  ? ' [ответил]'
                  : ' [отказ]'}',
        );
      }
      _dataBlocks = List.unmodifiable(probe.dataBlockCommands);
      _log.write(
        'vaz',
        _dataBlocks.isEmpty
            ? 'блок данных производителя не отвечает — пишем только стандартные PID'
            : 'блок данных ${_dataBlocks.join(', ')} пишется в запись сырым '
                  'раз в несколько секунд',
      );
    } on Object catch (e) {
      _log.write('vaz', 'разведка прервана: $e');
      try {
        await elm.send('ATSH7DF');
      } on Object {
        // Адаптер пропал — обычный опрос это покажет.
      }
    }
  }

  /// Счётчики пропусков воспламенения (режим 06): в запись и журнал. Не поддерживает
  /// блок или не ответил за 10 с — только строка в журнале, сеанс идёт дальше.
  Future<void> _readMisfires(Elm327 elm, Recording rec, String when) async {
    try {
      final report = await elm
          .readMisfires(tMs: _nowMs())
          .timeout(const Duration(seconds: 10));
      if (report == null) {
        _log.write(
          'misfire',
          '$when: блок не отдаёт тесты пропусков (режим 06)',
        );
        return;
      }
      rec.misfires.add(report);
      _log.write(
        'misfire',
        '$when: $report (за поездку / среднее за 10 поездок)'
            '${report.total == null ? '' : ', всего ${report.total!.current ?? '—'}'}',
      );
    } on Object catch (e) {
      _log.write('misfire', '$when: не прочитаны ($e)');
    }
  }

  /// Готовность самопроверок (PID 01) и бортовые тесты режима 06 (лямбды,
  /// катализатор…): в запись и журнал. Не ответил блок — строка в журнале.
  Future<void> _readChecks(Elm327 elm, Recording rec, String when) async {
    try {
      final readiness = await elm
          .readReadiness(tMs: _nowMs())
          .timeout(const Duration(seconds: 5));
      if (readiness == null) {
        _log.write('readiness', '$when: блок не ответил на 0101');
      } else {
        rec.readiness.add(readiness);
        _log.write('readiness', '$when: ${readiness.summary}');
      }
    } on Object catch (e) {
      _log.write('readiness', '$when: не прочитана ($e)');
    }
    try {
      final tests = await elm
          .readMonitorTests(tMs: _nowMs())
          .timeout(const Duration(seconds: 20));
      if (tests == null || tests.tests.isEmpty) {
        _log.write('mode06', '$when: бортовых тестов нет');
        return;
      }
      rec.monitorTests.add(tests);
      for (final line in tests.lines) {
        _log.write('mode06', '$when: $line');
      }
    } on Object catch (e) {
      _log.write('mode06', '$when: не прочитаны ($e)');
    }
  }

  /// Запуск службы и её состояние — в журнал: по ним видно, почему приложение
  /// могло замерзать в фоне (служба не запустилась, ограничение батареи, прошивка).
  Future<void> _startBackground(String text) async {
    final error = await _background.start(text);
    if (error != null) _log.write('service', 'не запустилась: $error');
    await Future<void>.delayed(const Duration(seconds: 2));
    final status = await _background.status();
    _log.write('service', status?.toString() ?? 'состояние недоступно');
  }

  /// Сворачивание и разворачивание приложения — в журнал: по нему видно,
  /// отчего в записи пауза.
  void logLifecycle(String state) => _log.write('app', 'состояние $state');

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
    // Не ждём: остановка службы не должна задерживать отключение.
    unawaited(_background.stop());
    if (_wifiBound) {
      _wifiBound = false;
      await _wifi.release();
    }
  }
}

String describeScanError(Object e) => switch (e) {
  ElmException(error: ElmError.unableToConnect) =>
    'Адаптер на связи, но машина не ответила ни по одному протоколу. '
        'Включите зажигание (ключ в положении ON или заведите двигатель) и '
        'проверьте, что адаптер вставлен в разъём до упора. Если не поможет — '
        'пришлите журнал сеанса.',
  ElmException(error: ElmError.canError) =>
    'Шина CAN машины не ответила за полторы минуты: питание у адаптера есть, '
        'а данных нет. Выньте адаптер из разъёма на пару секунд и вставьте снова — '
        'это полностью его перезапускает: если он поймал сбой при пуске двигателя, '
        'это помогает. Лучше вставлять адаптер, когда двигатель уже заведён. '
        'Если Car Scanner в это время подключается — пришлите журнал сеанса.',
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
