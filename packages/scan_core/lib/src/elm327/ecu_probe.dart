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
/// производителя (KWP 21 01…03 и, как у Итэлмы M74 CAN, UDS 22 00 01…03),
/// результаты бортовых тестов (06). Ничего не записывается, режимы блока не
/// меняются, кроме стандартного диагностического сеанса по умолчанию (10 81) —
/// и только если блок отказал в данных «не в том сеансе». Сервисы управления
/// (2F — вентилятор, муфта кондиционера и т. п.) не используются никогда.
///
/// На CAN запросы идут по физическому адресу двигателя 7E0 (ответ с 7E8);
/// в конце заголовок возвращается на функциональный 7DF для обычного опроса.
class EcuProbe {
  EcuProbe(this._elm);

  final Elm327 _elm;

  /// Запросы данных производителя, на которые блок ответил: '2101', '220001'.
  /// Их ответы стоит писать в запись сырыми — расшифровка по журналам.
  final List<String> dataBlockCommands = [];

  /// Первый из [dataBlockCommands] — для совместимости.
  String? get dataBlockCommand =>
      dataBlockCommands.isEmpty ? null : dataBlockCommands.first;

  /// Блоки данных производителя: KWP (Январь, M7.9.7…) и UDS-идентификаторы
  /// Итэлмы M74 CAN — на Гранте с ним 22 00 01 отдаёт многокадровый ответ
  /// (напряжение, температура, обороты…, по форумам владельцев).
  static const dataBlocks = [
    ('2101', 'Данные производителя 21 01'),
    ('2102', 'Данные производителя 21 02'),
    ('2103', 'Данные производителя 21 03'),
    ('220001', 'Данные ВАЗ 22 00 01'),
    ('220002', 'Данные ВАЗ 22 00 02'),
    ('220003', 'Данные ВАЗ 22 00 03'),
  ];

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
    // Сами счётчики пропусков читает Elm327.readMisfires — с расшифровкой.
    await ask('Бортовые тесты A1–C0: поддерживаемые', '06A0');

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

    // Блоки текущих данных ВАЗ: KWP 21 xx и UDS 22 00 xx.
    var sessionTried = false;
    for (final (command, title) in dataBlocks) {
      var block = await ask(title, command);
      if (block.positive == false &&
          !sessionTried &&
          _needsSession(block.raw, command)) {
        sessionTried = true;
        await ask('Сеанс по умолчанию', '1081');
        block = await ask('$title после сеанса', command);
      }
      if (block.positive == true) dataBlockCommands.add(command);
    }
    if (isCan) await _elm.send('ATSH7DF');
    return results;
  }

  /// 7F <сервис> 7F/80 — «сервис не поддерживается в текущем сеансе».
  static bool _needsSession(String raw, String command) {
    final clean = raw.replaceAll(RegExp(r'\s'), '').toUpperCase();
    final service = command.substring(0, 2).toUpperCase();
    return clean.contains('7F${service}7F') || clean.contains('7F${service}80');
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
