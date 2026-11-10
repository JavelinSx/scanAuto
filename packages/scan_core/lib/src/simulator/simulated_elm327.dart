import 'dart:async';
import 'dart:convert';

import '../hex.dart';
import '../obd/dtc.dart';
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
  }) : _clock = clock ?? _stopwatchClock(),
       _engine = SimEngine(scenario, seed: seed, ambient: ambient),
       _dtcs = [...scenario.dtcs];

  static const vin = 'XTA21900000000001';

  /// Машина отвечает только по этому протоколу, автопоиск её не находит —
  /// как Гранта на K-Line с клоном v1.5. null — обычная машина на CAN.
  final String? requiredProtocol;

  /// И только на этот заголовок (ATSH), например '8110F1'.
  final String? requiredHeader;

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
    final bytes = parseHexBytes(c);
    if (bytes == null || bytes.isEmpty) return '?';
    switch (bytes[0]) {
      case 0x01 when bytes.length == 2:
        final data = _engine.mode01(bytes[1], _seconds);
        return data == null ? 'NO DATA' : _message([0x41, bytes[1], ...data]);
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
      case 0x21 when bytes.length == 2 && bytes[1] == 0x01 && _header == '7E0':
        return _message([
          0x61,
          0x01,
          (_engine.value(0x05, _seconds)! + 40).round().clamp(0, 255),
          (_engine.value(0x0C, _seconds)! / 40).round().clamp(0, 255),
        ]);
      case 0x21 || 0x22 || 0x1A || 0x10:
        return _message([0x7F, bytes[0], 0x11]);
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
