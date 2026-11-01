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
  });

  /// Как адаптер себя назвал: «ELM327 v1.5». У клонов не значит ничего.
  final String version;

  /// Номер протокола по ATDPN: 6 — CAN 11 бит 500 кбит/с, самый частый с 2008 года.
  final int protocol;
  final Set<int> supportedPids;

  bool get isCan => protocol >= 6;
  String get protocolName => obdProtocolNames[protocol] ?? 'протокол $protocol';
}

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
  Elm327(this._transport) {
    _subscription = _transport.input.listen(
      _onData,
      onError: _failPending,
      onDone: () {
        _disconnected = true;
        _failPending(ElmDisconnectedException());
      },
    );
  }

  final ObdTransport _transport;
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
    await _transport.write(ascii.encode('$command\r'));
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
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
        if (pending != null && !pending.isCompleted) pending.complete(text);
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

  /// Сброс адаптера, настройка и поиск протокола. Бросает [ElmException]
  /// с [ElmError.unableToConnect], если машина не отвечает (зажигание выключено).
  Future<ElmInfo> initialize() async {
    final reset = await send('ATZ', timeout: const Duration(seconds: 5));
    await _expectOk('ATE0');
    await _expectOk('ATL0');
    // Пробелы, заголовки и адаптивные тайминги: разбор работает и без них,
    // а часть клонов v1.5 эти команды не знает.
    for (final c in const ['ATS0', 'ATH0', 'ATAT1']) {
      await send(c);
    }
    await _expectOk('ATSP0');
    final version =
        _versionPattern.firstMatch(reset)?.group(0) ??
        (await send('ATI')).trim();

    // Первый OBD-запрос запускает поиск протокола: на старых машинах до 10+ секунд.
    final supported = <int>{};
    var base = 0x00;
    var raw = await send('0100', timeout: const Duration(seconds: 15));
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
    );
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
