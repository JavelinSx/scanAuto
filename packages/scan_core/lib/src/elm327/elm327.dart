import 'dart:async';
import 'dart:convert';

import '../hex.dart';
import '../obd/dtc.dart';
import '../obd/pids.dart';
import '../transport/obd_transport.dart';
import 'elm_response.dart';

/// Что адаптер и машина сообщили при подключении.
final class ElmInfo {
  const ElmInfo({
    required this.version,
    required this.protocol,
    required this.supportedPids,
    this.attempt,
    this.voltage,
  });

  /// Как адаптер себя назвал: «ELM327 v1.5». У клонов не значит ничего.
  final String version;

  /// Номер протокола по ATDPN: 6 — CAN 11 бит 500 кбит/с, самый частый с 2008 года.
  final int protocol;
  final Set<int> supportedPids;

  /// Протокол найден не автопоиском, а перебором — какой попыткой.
  final ProtocolAttempt? attempt;

  /// Напряжение на разъёме при подключении (ATRV): с работающим двигателем
  /// обычно 13.5–14.5 В, с выключенным — 12–12.8 В.
  final double? voltage;

  /// Что запомнить для следующего подключения ([Elm327.initialize] `preferred`).
  String? get protocolKey =>
      attempt?.key ??
      (protocol > 0 ? protocol.toRadixString(16).toUpperCase() : null);

  bool get isCan => protocol >= 6;
  String get protocolName => obdProtocolNames[protocol] ?? 'протокол $protocol';
}

/// Явный протокол (ATSP) и, если нужно, заголовок (ATSH) — попытка после неудачного
/// автопоиска.
final class ProtocolAttempt {
  const ProtocolAttempt(this.protocol, this.title, {this.header});

  /// Цифра для ATSP: '5' — ISO 14230 с быстрой инициализацией.
  final String protocol;
  final String title;

  /// Заголовок запроса без пробелов: '8110F1' — блоку двигателя по физическому адресу.
  final String? header;

  /// Короткий ключ для хранения: '6', '5:8110F1'.
  String get key => header == null ? protocol : '$protocol:$header';

  /// Обратное к [key]; null — не похоже на ключ.
  static ProtocolAttempt? fromKey(String key) {
    final m = RegExp(r'^([1-9A-C])(?::([0-9A-F]{6}))?$').firstMatch(key);
    if (m == null) return null;
    return ProtocolAttempt(m.group(1)!, 'сохранённый', header: m.group(2));
  }

  @override
  String toString() =>
      'ATSP$protocol${header == null ? '' : ' + ATSH$header'} ($title)';
}

/// Порядок перебора, если автопоиск (ATSP0) не нашёл протокол. Клоны v1.5 часто
/// не находят K-Line сами. Блокам двигателя ВАЗ (Январь, Bosch M7.9.7, Itelma)
/// на K-Line нужен запрос по физическому адресу: заголовок 81 10 F1 —
/// стандартный функциональный C1 33 F1 они не всегда принимают.
const protocolFallbacks = [
  // CAN первым: на нём все машины примерно с 2008 года, в том числе Гранта после
  // рестайлинга, и ответ «не тот протокол» приходит быстро.
  ProtocolAttempt('6', 'CAN 11 бит, 500 кбит/с'),
  ProtocolAttempt('5', 'ISO 14230 KWP, быстрая инициализация'),
  ProtocolAttempt(
    '5',
    'ISO 14230 KWP, быстрая инициализация, адрес двигателя ВАЗ',
    header: '8110F1',
  ),
  ProtocolAttempt('4', 'ISO 14230 KWP, медленная инициализация'),
  ProtocolAttempt(
    '4',
    'ISO 14230 KWP, медленная инициализация, адрес двигателя ВАЗ',
    header: '8110F1',
  ),
  ProtocolAttempt('3', 'ISO 9141-2'),
];

/// Ошибки «машина не ответила по этому протоколу» — после них пробуем следующий.
const _noAnswer = {
  ElmError.unableToConnect,
  ElmError.busInit,
  ElmError.busError,
  ElmError.canError,
  ElmError.noData,
  ElmError.stopped,
};

const obdProtocolNames = <int, String>{
  1: 'SAE J1850 PWM',
  2: 'SAE J1850 VPW',
  3: 'ISO 9141-2',
  4: 'ISO 14230-4 KWP (медленная инициализация)',
  5: 'ISO 14230-4 KWP (быстрая инициализация)',
  6: 'ISO 15765-4 CAN (11 бит, 500 кбит/с)',
  7: 'ISO 15765-4 CAN (29 бит, 500 кбит/с)',
  8: 'ISO 15765-4 CAN (11 бит, 250 кбит/с)',
  9: 'ISO 15765-4 CAN (29 бит, 250 кбит/с)',
  10: 'SAE J1939 CAN',
  11: 'CAN пользователя 1',
  12: 'CAN пользователя 2',
};

final _versionPattern = RegExp(r'ELM327\s*v?[\d.]+', caseSensitive: false);
final _protocolPattern = RegExp(r'([0-9A-Ca-c])\s*$');
final _voltagePattern = RegExp(r'(\d+(?:\.\d+)?)\s*V', caseSensitive: false);

/// Разговор с ELM327 поверх любого [ObdTransport].
///
/// Команды идут строго по одной: байт, пришедший адаптеру во время ответа,
/// прерывает его (STOPPED). Ответ — весь текст до приглашения «>».
class Elm327 {
  /// [log] получает каждую строку обмена: «TX 010C», «RX 41 0C 1A F8⏎⏎»,
  /// тайм-ауты и отброшенные ответы — для журнала реальных прогонов.
  Elm327(this._transport, {this.log}) {
    _subscription = _transport.input.listen(
      _onData,
      onError: _failPending,
      onDone: () {
        log?.call('DISCONNECTED');
        _disconnected = true;
        _failPending(ElmDisconnectedException());
      },
    );
  }

  final ObdTransport _transport;
  final void Function(String line)? log;
  late final StreamSubscription<List<int>> _subscription;
  final _buffer = StringBuffer();
  Completer<String>? _pending;
  Future<void> _tail = Future.value();
  bool _needsResync = false;
  bool _disconnected = false;
  bool _closed = false;

  ElmInfo? _info;
  ElmInfo? get info => _info;

  Future<String> send(
    String command, {
    Duration timeout = const Duration(seconds: 2),
  }) {
    final result = _tail.then((_) => _exchange(command, timeout));
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<String> _exchange(String command, Duration timeout) async {
    if (_disconnected || _closed) throw ElmDisconnectedException();
    if (_needsResync) {
      // Ответ на брошенную по тайм-ауту команду может прийти сейчас: пропускаем его.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      _needsResync = false;
    }
    _buffer.clear();
    final completer = _pending = Completer<String>();
    log?.call('TX $command');
    await _transport.write(ascii.encode('$command\r'));
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      log?.call('TIMEOUT $command (${timeout.inMilliseconds} мс)');
      _needsResync = true;
      throw ElmTimeoutException(command);
    } finally {
      _pending = null;
    }
  }

  void _onData(List<int> bytes) {
    for (final b in bytes) {
      if (b == 0x3E) {
        final text = _buffer.toString();
        _buffer.clear();
        final pending = _pending;
        _pending = null;
        final shown = text.replaceAll('\r', '⏎').replaceAll('\n', '');
        if (pending != null && !pending.isCompleted) {
          log?.call('RX $shown');
          pending.complete(text);
        } else {
          // Опоздавший ответ на брошенную по тайм-ауту команду.
          log?.call('DROP $shown');
        }
      } else if (b != 0) {
        // Некоторые клоны шлют NUL перед приглашением.
        _buffer.writeCharCode(b);
      }
    }
  }

  void _failPending(Object error, [StackTrace? stackTrace]) {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error, stackTrace);
    }
  }

  /// Сброс адаптера, настройка и поиск протокола: сначала автопоиск, при неудаче —
  /// перебор [protocolFallbacks]. [onProgress] — что показать пользователю.
  /// Бросает [ElmException] с [ElmError.unableToConnect], если машина не ответила
  /// ни по одному протоколу (зажигание выключено или адаптер не умеет её протокол).
  ///
  /// [preferred] — протокол, на котором эта машина уже отвечала (ключ
  /// [ProtocolAttempt.key]): пробуется первым, без автопоиска. Не ответила —
  /// обычный порядок. Ключ найденного протокола — в [ElmInfo.protocolKey].
  Future<ElmInfo> initialize({
    void Function(String status)? onProgress,
    String? preferred,
  }) async {
    final reset = await _reset();
    final version =
        _versionPattern.firstMatch(reset)?.group(0) ??
        (await send('ATI')).trim();
    double? voltage;
    try {
      voltage = await readBatteryVoltage();
    } on Object {
      // Не все клоны знают ATRV — не повод отказываться от подключения.
    }

    final saved = preferred == null ? null : ProtocolAttempt.fromKey(preferred);
    if (saved != null) {
      onProgress?.call('Подключение по сохранённому протоколу…');
      log?.call('PROTOCOL сохранённый: $saved');
      try {
        await send('ATSP${saved.protocol}');
        if (saved.header case final header?) await send('ATSH$header');
        final raw = await _firstRequest(const Duration(seconds: 10));
        log?.call('PROTOCOL ответила: $saved');
        return await _finishInit(raw, version, voltage, saved);
      } on ElmException catch (e) {
        if (!_noAnswer.contains(e.error)) rethrow;
        log?.call('PROTOCOL сохранённый не ответил: ${e.error.name}');
      } on ElmTimeoutException {
        log?.call('PROTOCOL сохранённый не ответил: тайм-аут');
      }
      await _reset();
    }

    await _expectOk('ATSP0');
    onProgress?.call('Поиск протокола машины… до 15 секунд');
    // Первый OBD-запрос запускает поиск протокола: на старых машинах до 10+ секунд.
    ProtocolAttempt? attempt;
    String raw;
    try {
      raw = await _firstRequest(const Duration(seconds: 15));
    } on ElmException catch (e) {
      if (!_noAnswer.contains(e.error)) rethrow;
      log?.call('PROTOCOL автопоиск не нашёл протокол: ${e.error.name}');
      (raw, attempt) = await _tryFallbacks(e, onProgress);
    }
    return _finishInit(raw, version, voltage, attempt);
  }

  /// Поддерживаемые PID и номер протокола после того, как машина ответила на 0100.
  Future<ElmInfo> _finishInit(
    String first,
    String version,
    double? voltage,
    ProtocolAttempt? attempt,
  ) async {
    var raw = first;
    final supported = <int>{};
    var base = 0x00;
    while (true) {
      final command = '01${hexByte(base)}';
      final data = mode01Data(parseObdResponse(raw, command: command), base);
      if (data == null || data.length < 4) break;
      supported.addAll(decodeSupportedPids(base, data));
      final next = base + 0x20;
      if (next > 0xE0 || !supported.contains(next)) break;
      base = next;
      raw = await send('01${hexByte(base)}');
    }

    final dpn = await send('ATDPN');
    final protocol =
        int.tryParse(
          _protocolPattern.firstMatch(dpn.trim())?.group(1) ?? '',
          radix: 16,
        ) ??
        0;

    return _info = ElmInfo(
      version: version,
      protocol: protocol,
      supportedPids: supported,
      attempt: attempt,
      voltage: voltage,
    );
  }

  /// ATZ и настройка: после него сброшены протокол и заголовок.
  Future<String> _reset() async {
    final reset = await send('ATZ', timeout: const Duration(seconds: 5));
    await _expectOk('ATE0');
    await _expectOk('ATL0');
    // Пробелы, заголовки и адаптивные тайминги: разбор работает и без них,
    // а часть клонов v1.5 эти команды не знает.
    for (final c in const ['ATS0', 'ATH0', 'ATAT1']) {
      await send(c);
    }
    return reset;
  }

  /// 0100 с разбором: ошибка адаптера — исключение, иначе сырой ответ.
  Future<String> _firstRequest(Duration timeout) async {
    final raw = await send('0100', timeout: timeout);
    parseObdResponse(raw, command: '0100');
    return raw;
  }

  Future<(String, ProtocolAttempt)> _tryFallbacks(
    ElmException first,
    void Function(String status)? onProgress,
  ) async {
    var last = first;
    for (final (i, a) in protocolFallbacks.indexed) {
      onProgress?.call(
        'Пробуем протокол ${i + 1} из ${protocolFallbacks.length}: ${a.title}',
      );
      log?.call('PROTOCOL попытка $a');
      // С нуля: заголовок прошлой попытки не должен остаться.
      await _reset();
      await send('ATSP${a.protocol}');
      if (a.header case final header?) await send('ATSH$header');
      try {
        final raw = await _firstRequest(const Duration(seconds: 10));
        log?.call('PROTOCOL ответила: $a');
        return (raw, a);
      } on ElmException catch (e) {
        if (!_noAnswer.contains(e.error)) rethrow;
        log?.call('PROTOCOL нет ответа: ${e.error.name}');
        last = e;
      } on ElmTimeoutException {
        log?.call('PROTOCOL нет ответа: тайм-аут');
      }
    }
    throw ElmException(ElmError.unableToConnect, last.raw);
  }

  Future<void> _expectOk(String command) async {
    final r = await send(command);
    if (!r.toUpperCase().contains('OK')) {
      throw ElmException(ElmError.unknownCommand, r);
    }
  }

  /// Значение PID или null, если машина его не отдаёт.
  Future<double?> readPid(Pid pid) async {
    try {
      final raw = await send(pid.command);
      final data = mode01Data(
        parseObdResponse(raw, command: pid.command),
        pid.code,
      );
      return data == null ? null : pid.decode(data);
    } on ElmException catch (e) {
      if (e.error == ElmError.noData) return null;
      rethrow;
    }
  }

  /// Коды неисправностей: 0x03 — сохранённые, 0x07 — ожидающие, 0x0A — постоянные.
  Future<List<String>> readDtcs({int mode = 0x03}) async {
    final command = hexByte(mode);
    try {
      final raw = await send(command, timeout: const Duration(seconds: 5));
      return parseDtcResponse(
        parseObdResponse(raw, command: command),
        mode: mode,
        isCan: _info?.isCan ?? true,
      );
    } on ElmException catch (e) {
      if (e.error == ElmError.noData) return const [];
      rethrow;
    }
  }

  /// Режим 04: стирает коды, стоп-кадры и готовность мониторов.
  /// Только при включённом зажигании и заглушенном двигателе, после подтверждения.
  Future<void> clearDtcs() async {
    final raw = await send('04', timeout: const Duration(seconds: 5));
    final messages = parseObdResponse(raw, command: '04');
    if (!messages.any((m) => m.isNotEmpty && m[0] == 0x44)) {
      throw ElmException(ElmError.other, raw);
    }
  }

  /// VIN (режим 09, PID 02). Есть не у всех машин, особенно до 2005 года.
  Future<String?> readVin() async {
    try {
      final raw = await send('0902', timeout: const Duration(seconds: 5));
      final bytes = <int>[
        for (final m in parseObdResponse(raw, command: '0902'))
          if (m.length > 3 && m[0] == 0x49 && m[1] == 0x02) ...m.sublist(3),
      ];
      // На старых протоколах первый кадр добит нулями.
      final vin = String.fromCharCodes(
        bytes.where(
          (b) => (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A),
        ),
      );
      return vin.length == 17 ? vin : null;
    } on ElmException {
      return null;
    }
  }

  /// Напряжение на разъёме OBD, которое меряет сам адаптер (ATRV).
  Future<double?> readBatteryVoltage() async {
    final m = _voltagePattern.firstMatch(await send('ATRV'));
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _failPending(ElmDisconnectedException());
    await _subscription.cancel();
    await _transport.close();
  }
}
