import 'dart:async';
import 'dart:convert';

import '../hex.dart';
import '../obd/dtc.dart';
import '../obd/pids.dart';
import '../transport/obd_transport.dart';
import 'sim_engine.dart';

/// Программный ELM327 v1.5 на CAN 11/500 с [SimEngine] внутри. Отвечает на AT-команды
/// и режимы 01/03/04/07/09 так же, как настоящий адаптер: с эхом и пробелами до ATE0/ATS0,
/// «SEARCHING...» на первом запросе, многокадровым VIN. Для работы без машины и для тестов.
final class SimulatedElm327 implements ObdTransport {
  SimulatedElm327({
    this.scenario = SimScenario.healthy,
    Duration Function()? clock,
    this.latency = const Duration(milliseconds: 25),
    int seed = 1,
    double ambient = 20,
    this.requiredProtocol,
    this.requiredHeader,
    this.misfires = const {},
    int canErrors = 0,
    this._err94 = false,
    this._noData0120 = 0,
    this.responseCount = true,
    this.multiPid = true,
    this.dataService = 0x21,
  }) : _canErrorsLeft = canErrors,
       _clock = clock ?? _stopwatchClock(),
       _engine = SimEngine(scenario, seed: seed, ambient: ambient),
       _dtcs = [...scenario.dtcs];

  static const vin = 'XTA21900000000001';

  /// Машина отвечает только по этому протоколу, автопоиск её не находит —
  /// как Гранта на K-Line с клоном v1.5. null — обычная машина на CAN.
  final String? requiredProtocol;

  /// И только на этот заголовок (ATSH), например '8110F1'.
  final String? requiredHeader;

  /// Пропуски по цилиндрам за текущую поездку для режима 06 (цилиндр → счёт).
  /// Среднее за 10 поездок симулятор отдаёт как половину.
  final Map<int, int> misfires;

  /// Сколько раз явный CAN ответит `CAN ERROR`, прежде чем шина «оживёт»
  /// (автопоиск в это время не находит протокол) — как неплотный адаптер.
  int _canErrorsLeft;

  /// Адаптер поймал фатальную ошибку CAN (ERR94) при пуске двигателя: CAN
  /// недоступен, пока не придёт ATFE (ATZ запрет не снимает), — как настоящий ELM327.
  bool _err94;

  /// Сколько раз группа PID 0120 ответит NO DATA, хотя 0100 уже ответил —
  /// как занятый блок на неустойчивой шине (Гранта, 17.11).
  int _noData0120;

  /// Понимает цифру числа ответов в конце запроса (`010C1`). Нет — «?», как клон.
  final bool responseCount;

  /// Блок отвечает на несколько PID в одном запросе. Нет — только на первый.
  final bool multiPid;

  /// Каким запросом блок отдаёт данные производителя по адресу 7E0:
  /// 0x21 — KWP `21 01` (Январь), 0x22 — UDS `22 00 01` (Итэлма M74 CAN).
  final int dataService;

  String _protocol = '0';
  String? _header;

  bool get _isCan =>
      requiredProtocol == null || int.parse(requiredProtocol!, radix: 16) >= 6;

  final SimScenario scenario;
  final Duration latency;
  final Duration Function() _clock;
  final SimEngine _engine;
  final List<String> _dtcs;
  final _output = StreamController<List<int>>();
  final _command = StringBuffer();
  bool _echo = true;
  bool _spaces = true;
  bool _protocolFound = false;

  /// Режим движения «машины»: программа диагностики меняет его по этапам.
  SimDrive get drive => _engine.drive;
  set drive(SimDrive value) => _engine.drive = value;

  static Duration Function() _stopwatchClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  @override
  Stream<List<int>> get input => _output.stream;

  @override
  Future<void> write(List<int> bytes) async {
    for (final b in bytes) {
      if (b == 0x0D) {
        final command = _command.toString().trim();
        _command.clear();
        _respond(command);
      } else if (b != 0x0A) {
        _command.writeCharCode(b);
      }
    }
  }

  @override
  Future<void> close() => _output.close();

  void _respond(String command) {
    // Эхо зависит от состояния до команды: на ATE0 адаптер ещё повторяет её.
    final echo = _echo;
    final reply = _handle(command.toUpperCase().replaceAll(' ', ''));
    final text = '${echo ? '$command\r' : ''}$reply\r\r>';
    Future<void>.delayed(latency, () {
      if (!_output.isClosed) _output.add(ascii.encode(text));
    });
  }

  String _handle(String c) {
    if (c.startsWith('AT')) return _at(c.substring(2));
    final searching = _protocolFound || _protocol != '0'
        ? ''
        : 'SEARCHING...\r';
    if (_err94) {
      if (_protocol == '0') return '${searching}UNABLE TO CONNECT';
      if (_protocol == '6') return 'CAN ERROR';
    }
    if (_canErrorsLeft > 0) {
      if (_protocol == '0') return '${searching}UNABLE TO CONNECT';
      if (_protocol == '6') {
        _canErrorsLeft--;
        return 'CAN ERROR';
      }
    }
    if (requiredProtocol case final required?) {
      final answers =
          _protocol == required &&
          (requiredHeader == null || _header == requiredHeader);
      if (!answers) {
        // Как настоящий адаптер: автопоиск не нашёл, на K-Line — ошибка инициализации.
        return _protocol == '0'
            ? '${searching}UNABLE TO CONNECT'
            : (_protocol == '4' || _protocol == '5' || _protocol == '3')
            ? 'BUS INIT: ...ERROR'
            : 'UNABLE TO CONNECT';
      }
    }
    _protocolFound = true;
    return searching + _obd(c);
  }

  String _at(String c) {
    switch (c) {
      case 'Z':
        _echo = true;
        _spaces = true;
        _protocol = '0';
        _header = null;
        _protocolFound = false;
        return '\r\rELM327 v1.5';
      case 'I':
        return 'ELM327 v1.5';
      case 'E0' || 'E1':
        _echo = c == 'E1';
        return 'OK';
      case 'S0' || 'S1':
        _spaces = c == 'S1';
        return 'OK';
      case 'DPN':
        if (requiredProtocol case final p?) return _protocol == '0' ? 'A$p' : p;
        return 'A6';
      case 'DP':
        return 'AUTO, ISO 15765-4 (CAN 11/500)';
      case 'RV':
        return '${(_engine.value(0x42, _seconds)! - 0.2).toStringAsFixed(1)}V';
    }
    if (c == 'PC') return 'OK';
    if (c == 'FE') {
      _err94 = false;
      return 'OK';
    }
    if (c == 'CS') return _err94 ? 'T:FF R:00 OFF' : 'T:00 R:00';
    if (RegExp(r'^SP([0-9A-C])$').firstMatch(c) case final m?) {
      _protocol = m.group(1)!;
      _protocolFound = false;
      return 'OK';
    }
    if (RegExp(r'^SH([0-9A-F]{3}|[0-9A-F]{6})$').firstMatch(c) case final m?) {
      _header = m.group(1);
      return 'OK';
    }
    if (RegExp(r'^(L[01]|H[01]|AT[012]|SP[0-9A-C]|ST[0-9A-F]{2}|D)$')
        .hasMatch(c)) {
      return 'OK';
    }
    return '?';
  }

  double get _seconds => _clock().inMilliseconds / 1000;

  String _obd(String c) {
    // Цифра числа ответов: нечётная длина, последняя цифра — сколько ждать.
    // Блок у симулятора один, поэтому ответ тот же.
    if (c.length.isOdd && c.length > 2 && responseCount) {
      c = c.substring(0, c.length - 1);
    }
    final bytes = parseHexBytes(c);
    if (bytes == null || bytes.isEmpty) return '?';
    switch (bytes[0]) {
      case 0x01 when bytes.length == 2 && bytes[1] == 0x20 && _noData0120 > 0:
        _noData0120--;
        return 'NO DATA';
      case 0x01 when bytes.length == 2:
        final data = _engine.mode01(bytes[1], _seconds);
        return data == null ? 'NO DATA' : _message([0x41, bytes[1], ...data]);
      // Несколько PID в одном запросе (CAN, до 6): один ответ со всеми.
      case 0x01 when bytes.length > 2 && bytes.length <= 7 && _isCan:
        final out = <int>[0x41];
        for (final pid in multiPid ? bytes.skip(1) : bytes.skip(1).take(1)) {
          final data = _engine.mode01(pid, _seconds);
          if (data != null) out.addAll([pid, ...data]);
        }
        return out.length == 1 ? 'NO DATA' : _message(out);
      case 0x03 when !_isCan:
        // Старые протоколы: без числа кодов, по три кода на кадр, добито нулями.
        final codes = [for (final d in _dtcs) ...encodeDtc(d)];
        while (codes.length < 6 || codes.length % 6 != 0) {
          codes.add(0);
        }
        return [
          for (var i = 0; i < codes.length; i += 6)
            formatHex([0x43, ...codes.sublist(i, i + 6)], spaces: _spaces),
        ].join('\r');
      case 0x03:
        return _message([
          0x43,
          _dtcs.length,
          for (final d in _dtcs) ...encodeDtc(d),
        ]);
      case 0x07:
        return _message([0x47, 0x00]);
      case 0x0A:
        return _message([0x4A, 0x00]);
      case 0x04:
        _dtcs.clear();
        return _message([0x44]);
      // Заглушка блока данных производителя для тестов разведки и сырой записи:
      // раскладка выдуманная (ОЖ+40, обороты/40), настоящая у ВАЗ — по журналам.
      // UDS 22 00 01, как у Итэлмы M74 CAN: многокадровый ответ. Раскладка
      // выдуманная (напряжение ×10, ОЖ (t+48)/0.75 словом, обороты ×4 словом).
      case 0x22
          when bytes.length == 3 &&
              bytes[1] == 0x00 &&
              bytes[2] == 0x01 &&
              _header == '7E0' &&
              dataService == 0x22:
        final coolant = ((_engine.value(0x05, _seconds)! + 48) / 0.75).round();
        final rpm = (_engine.value(0x0C, _seconds)! * 4).round();
        return _message([
          0x62,
          0x00,
          0x01,
          (_engine.value(0x42, _seconds)! * 10).round().clamp(0, 255),
          coolant >> 8,
          coolant & 0xFF,
          rpm >> 8,
          rpm & 0xFF,
          0x00,
          ((_engine.value(0x0E, _seconds)! + 64) * 2).round().clamp(0, 255),
          0x00,
          0x00,
        ]);
      case 0x22
          when bytes.length == 3 && bytes[1] == 0x00 && dataService == 0x22:
        return _message([0x7F, 0x22, 0x31]);
      case 0x21
          when bytes.length == 2 &&
              bytes[1] == 0x01 &&
              _header == '7E0' &&
              dataService == 0x21:
        return _message([
          0x61,
          0x01,
          (_engine.value(0x05, _seconds)! + 40).round().clamp(0, 255),
          (_engine.value(0x0C, _seconds)! / 40).round().clamp(0, 255),
        ]);
      case 0x21 || 0x22 || 0x1A || 0x10:
        return _message([0x7F, bytes[0], 0x11]);
      // Режим 06: тесты пропусков воспламенения (MID A1 — все, A2…A5 — цилиндры).
      case 0x06 when bytes.length == 2 && _isCan:
        final mid = bytes[1];
        // Цепочка масок до A0, как у блока с лямбдами, катализатором и подогревом.
        if (_mode06Masks[mid] case final mids?) {
          return _message([0x46, mid, ...encodeSupportedPids(mid, mids)]);
        }
        if (_mode06Tests(mid) case final records?) {
          return _message([0x46, for (final r in records) ...r]);
        }
        if (mid == 0xA0) {
          return _message([
            0x46,
            0xA0,
            ...encodeSupportedPids(0xA0, {0xA1, 0xA2, 0xA3, 0xA4, 0xA5}),
          ]);
        }
        if (mid < 0xA1 || mid > 0xA5) return 'NO DATA';
        final current = mid == 0xA1
            ? misfires.values.fold(0, (a, b) => a + b)
            : misfires[mid - 0xA1] ?? 0;
        List<int> record(int tid, int value) => [
          mid,
          tid,
          0x24,
          value >> 8,
          value & 0xFF,
          0x00,
          0x00,
          0xFF,
          0xFF,
        ];
        return _message([
          0x46,
          ...record(0x0B, current ~/ 2),
          ...record(0x0C, current),
        ]);
      case 0x09 when bytes.length == 2 && bytes[1] == 0x02 && !_isCan:
        // Старые протоколы: пять кадров «49 02 N» по 4 байта, первый добит нулями.
        final chars = [0, 0, 0, ...ascii.encode(vin)];
        return [
          for (var i = 0; i < 5; i++)
            formatHex([
              0x49,
              0x02,
              i + 1,
              ...chars.sublist(i * 4, i * 4 + 4),
            ], spaces: _spaces),
        ].join('\r');
      case 0x09 when bytes.length == 2 && bytes[1] == 0x02:
        return _message([0x49, 0x02, 0x01, ...ascii.encode(vin)]);
      default:
        return 'NO DATA';
    }
  }

  static const _mode06Masks = {
    0x00: {0x01, 0x02, 0x20},
    0x20: {0x21, 0x40},
    0x40: {0x41, 0x60},
    0x60: {0x80},
    0x80: {0xA0},
  };

  /// Записи тестов: MID, TID, UASID, значение, мин, макс (по 2 байта).
  List<List<int>>? _mode06Tests(int mid) {
    List<int> record(int tid, int uasid, int value, int lo, int hi) => [
      mid,
      tid,
      uasid,
      value >> 8,
      value & 0xFF,
      lo >> 8,
      lo & 0xFF,
      hi >> 8,
      hi & 0xFF,
    ];
    return switch (mid) {
      // Передний зонд: порог 0.45 В (0.122 мВ на единицу), переключения в мс.
      0x01 => [
        record(0x01, 0x0A, 3689, 0, 0xFFFF),
        record(0x05, 0x10, 70, 0, 100),
        record(0x06, 0x10, 80, 0, 100),
      ],
      0x02 => [record(0x07, 0x0A, 820, 0, 3300)],
      0x21 => [record(0x80, 0x01, 30, 0, 100)],
      0x41 => [record(0x81, 0x10, 25, 0, 60)],
      _ => null,
    };
  }

  /// Ответ CAN без заголовков: до 7 байт — одной строкой, длиннее — как ISO-TP
  /// («014», «0: …» с 6 байтами, дальше по 7).
  String _message(List<int> bytes) {
    String hex(List<int> b) => formatHex(b, spaces: _spaces);
    if (bytes.length <= 7) return hex(bytes);
    final lines = [
      bytes.length.toRadixString(16).padLeft(3, '0').toUpperCase(),
    ];
    lines.add('0: ${hex(bytes.sublist(0, 6))}');
    var index = 1;
    for (var i = 6; i < bytes.length; i += 7) {
      final end = i + 7 < bytes.length ? i + 7 : bytes.length;
      lines.add(
        '${(index++ % 16).toRadixString(16).toUpperCase()}: ${hex(bytes.sublist(i, end))}',
      );
    }
    return lines.join('\r');
  }
}
