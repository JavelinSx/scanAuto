import '../hex.dart';

/// Что ELM327 пишет вместо данных.
enum ElmError {
  /// Запрос ушёл, ЭБУ не ответил: PID не поддерживается или нет такого режима.
  noData,

  /// Адаптер не нашёл протокол: обычно выключено зажигание.
  unableToConnect,
  canError,
  busInit,
  busError,
  bufferFull,

  /// Команда прервана: адаптер получил байт, пока отвечал.
  stopped,

  /// «?» — адаптер не знает команду.
  unknownCommand,
  dataError,
  other,
}

class ElmException implements Exception {
  ElmException(this.error, this.raw);

  final ElmError error;
  final String raw;

  @override
  String toString() => 'ElmException(${error.name}): ${raw.trim()}';
}

class ElmTimeoutException implements Exception {
  ElmTimeoutException(this.command);

  final String command;

  @override
  String toString() => 'ElmTimeoutException: нет ответа на $command';
}

class ElmDisconnectedException implements Exception {
  @override
  String toString() => 'ElmDisconnectedException: адаптер отключился';
}

ElmError? _errorOf(String line) {
  final l = line.toUpperCase();
  if (l == 'NO DATA') return ElmError.noData;
  if (l.startsWith('UNABLE TO CONNECT')) return ElmError.unableToConnect;
  if (l.startsWith('CAN ERROR')) return ElmError.canError;
  if (l.startsWith('BUS INIT') && l.contains('ERROR')) return ElmError.busInit;
  if (l == 'BUS ERROR' || l == 'BUS BUSY') return ElmError.busError;
  if (l == 'BUFFER FULL') return ElmError.bufferFull;
  if (l == 'STOPPED') return ElmError.stopped;
  if (l == '?') return ElmError.unknownCommand;
  if (l.contains('DATA ERROR') || l == 'FB ERROR' || l == 'RX ERROR') {
    return ElmError.dataError;
  }
  if (l == 'ERROR' || l == 'LV RESET' || l.endsWith('ALERT')) {
    return ElmError.other;
  }
  return null;
}

final _lineBreak = RegExp(r'[\r\n]+');
final _isoTpCount = RegExp(r'^[0-9A-Fa-f]{3}$');
final _isoTpFrame = RegExp(r'^([0-9A-Fa-f]):\s*(.*)$');
final _busInitOk = RegExp(r'^BUS INIT:.*OK$', caseSensitive: false);

/// Разбор ответа на OBD-запрос (текст до приглашения «>») в сообщения ЭБУ.
///
/// Каждое сообщение — байты одного ответа, начиная с байта режима (0x41, 0x43…).
/// Многокадровые ответы CAN (ISO-TP: строка с длиной, затем «0: …», «1: …») склеиваются.
/// Если ответили несколько блоков, сообщений будет несколько. Заголовки должны быть
/// выключены (ATH0). Ошибки адаптера бросаются как [ElmException].
List<List<int>> parseObdResponse(String raw, {String? command}) {
  final lines = raw
      .split(_lineBreak)
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  // Эхо команды, если ATE0 ещё не отправлена или клон её игнорирует.
  if (command != null &&
      lines.isNotEmpty &&
      lines.first.replaceAll(' ', '').toUpperCase() ==
          command.replaceAll(' ', '').toUpperCase()) {
    lines.removeAt(0);
  }
  lines.removeWhere(
    (l) => l.toUpperCase().startsWith('SEARCHING') || _busInitOk.hasMatch(l),
  );

  for (final l in lines) {
    final error = _errorOf(l);
    if (error != null) throw ElmException(error, raw);
  }

  final messages = <List<int>>[];
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    // Строка данных всегда чётной длины, поэтому три hex-символа — это длина ISO-TP.
    if (_isoTpCount.hasMatch(line)) {
      final total = int.parse(line, radix: 16);
      final bytes = <int>[];
      i++;
      while (i < lines.length) {
        final frame = _isoTpFrame.firstMatch(lines[i]);
        if (frame == null) break;
        final b = parseHexBytes(frame.group(2)!);
        if (b == null) throw ElmException(ElmError.dataError, raw);
        bytes.addAll(b);
        i++;
      }
      messages.add(bytes.length > total ? bytes.sublist(0, total) : bytes);
      continue;
    }
    final b = parseHexBytes(line);
    if (b == null) throw ElmException(ElmError.dataError, raw);
    messages.add(b);
    i++;
  }
  return messages;
}

/// Данные режима 01 для [pid]: байты после «41 PID». Берём первый ответивший блок —
/// без заголовков не отличить двигатель от коробки, а PID двигателя отдаёт двигатель.
List<int>? mode01Data(List<List<int>> messages, int pid) {
  for (final m in messages) {
    if (m.length >= 2 && m[0] == 0x41 && m[1] == pid) return m.sublist(2);
  }
  return null;
}
