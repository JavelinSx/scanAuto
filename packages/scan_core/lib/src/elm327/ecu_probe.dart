import 'elm327.dart';
import 'elm_response.dart';

/// Один запрос разведки и что ответил блок.
final class ProbeResult {
  const ProbeResult(this.title, this.command, this.raw, {this.positive});

  final String title;
  final String command;

  /// Ответ адаптера как есть (без приглашения) или текст ошибки.
  final String raw;

  /// Блок ответил положительно (байт сервиса +0x40); false — отказ (7F …),
  /// null — нет ответа.
  final bool? positive;
}

/// Разведка блока двигателя: какие запросы сверх стандартного OBD он понимает.
///
/// Только чтение: идентификация (09, 1A, 22 F1xx), блок текущих данных
/// производителя (21 01…03), результаты бортовых тестов (06), в том числе
/// счётчики пропусков по цилиндрам. Ничего не записывается, режимы блока не
/// меняются, кроме стандартного диагностического сеанса по умолчанию (10 81) —
/// и только если блок отказал в 21 01 «не в том сеансе».
///
/// На CAN запросы идут по физическому адресу двигателя 7E0 (ответ с 7E8);
/// в конце заголовок возвращается на функциональный 7DF для обычного опроса.
class EcuProbe {
  EcuProbe(this._elm);

  final Elm327 _elm;

  /// Блок текущих данных производителя, если он отвечает: '2101'.
  /// Его ответы стоит писать в запись сырыми — расшифровка по журналам.
  String? dataBlockCommand;

  Future<List<ProbeResult>> run({required bool isCan}) async {
    final results = <ProbeResult>[];
    Future<ProbeResult> ask(String title, String command) async {
      final r = await _ask(title, command);
      results.add(r);
      return r;
    }

    // Стандартная идентификация — функциональным адресом, как обычный опрос.
    await ask('Номер калибровки', '0904');
    await ask('Контрольная сумма калибровки', '0906');
    await ask('Название блока', '090A');

    if (isCan) await _elm.send('ATSH7E0');

    // Режим 06: поддерживаемые тесты и счётчики пропусков (MID A1 — общий,
    // A2… — по цилиндрам). Стандарт, но есть не у всех блоков.
    await ask('Бортовые тесты: поддерживаемые', '0600');
    await ask('Пропуски: все цилиндры', '06A1');
    for (var cyl = 1; cyl <= 4; cyl++) {
      await ask('Пропуски: цилиндр $cyl', '06A${cyl + 1}');
    }

    // Идентификация производителя: KWP2000 (1A) и UDS (22 F1xx).
    await ask('Идентификация KWP', '1A80');
    for (final (did, title) in const [
      ('F187', 'номер детали'),
      ('F18C', 'серийный номер'),
      ('F190', 'VIN'),
      ('F194', 'версия ПО поставщика'),
      ('F195', 'версия ПО'),
    ]) {
      await ask('UDS $title', '22$did');
    }

    // Блок текущих данных ВАЗ (KWP 21 xx).
    var block = await ask('Данные производителя 21 01', '2101');
    if (block.positive == false && _needsSession(block.raw)) {
      await ask('Сеанс по умолчанию', '1081');
      block = await ask('Данные производителя 21 01 после сеанса', '2101');
    }
    if (block.positive == true) dataBlockCommand = '2101';
    await ask('Данные производителя 21 02', '2102');
    await ask('Данные производителя 21 03', '2103');
    if (isCan) await _elm.send('ATSH7DF');
    return results;
  }

  /// 7F 21 7F/80 — «сервис не поддерживается в текущем сеансе».
  static bool _needsSession(String raw) {
    final clean = raw.replaceAll(RegExp(r'\s'), '').toUpperCase();
    return clean.contains('7F217F') || clean.contains('7F2180');
  }

  Future<ProbeResult> _ask(String title, String command) async {
    final service = int.parse(command.substring(0, 2), radix: 16);
    try {
      final raw = await _elm.send(command, timeout: const Duration(seconds: 3));
      try {
        final messages = parseObdResponse(raw, command: command);
        final first = messages.isEmpty ? null : messages.first;
        final positive = first == null || first.isEmpty
            ? null
            : first[0] == service + 0x40
            ? true
            : first[0] == 0x7F
            ? false
            : null;
        return ProbeResult(title, command, raw.trim(), positive: positive);
      } on ElmException catch (e) {
        return ProbeResult(title, command, e.error.name);
      }
    } on ElmTimeoutException {
      return ProbeResult(title, command, 'тайм-аут');
    }
  }
}
