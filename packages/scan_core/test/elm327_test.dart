import 'dart:async';

import 'package:scan_core/scan_core.dart';
import 'package:test/test.dart';

void main() {
  late Duration now;
  Elm327 connect(SimScenario scenario) {
    now = Duration.zero;
    return Elm327(
      SimulatedElm327(
        scenario: scenario,
        clock: () => now,
        latency: Duration.zero,
      ),
    );
  }

  test('инициализация: версия, CAN, поддерживаемые PID', () async {
    final elm = connect(SimScenario.healthy);
    final info = await elm.initialize();
    expect(info.version, 'ELM327 v1.5');
    expect(info.protocol, 6);
    expect(info.isCan, isTrue);
    // Вторая группа (0x21–0x40) и третья (0x41–0x60) тоже прочитаны.
    expect(info.supportedPids, containsAll([0x0C, 0x2F, 0x42, 0x46]));
    expect(info.supportedPids, isNot(contains(0x5C)));
    await elm.close();
  });

  test('чтение PID, VIN, напряжения', () async {
    final elm = connect(SimScenario.healthy);
    await elm.initialize();
    // Холодный пуск: ОЖ 20 °C, повышенные холостые.
    expect(await elm.readPid(pidsByKey['coolant']!), 20);
    expect(await elm.readPid(pidsByKey['rpm']!), closeTo(1020, 15));
    expect(await elm.readPid(pidsByKey['oil']!), isNull);
    now = const Duration(minutes: 10);
    expect(await elm.readPid(pidsByKey['coolant']!), inInclusiveRange(88, 91));
    expect(await elm.readVin(), SimulatedElm327.vin);
    expect(await elm.readBatteryVoltage(), closeTo(13.9, 0.2));
    await elm.close();
  });

  test('коды: чтение и сброс', () async {
    final elm = connect(SimScenario.vacuumLeak);
    await elm.initialize();
    expect(await elm.readDtcs(), ['P0171']);
    expect(await elm.readDtcs(mode: 0x07), isEmpty);
    await elm.clearDtcs();
    expect(await elm.readDtcs(), isEmpty);
    await elm.close();
  });

  test('команды не перемешиваются при параллельных вызовах', () async {
    final elm = connect(SimScenario.healthy);
    await elm.initialize();
    final results = await Future.wait([
      elm.readPid(pidsByKey['coolant']!),
      elm.readPid(pidsByKey['speed']!),
      elm.readPid(pidsByKey['fuel']!),
    ]);
    expect(results, [20, 0, closeTo(62, 0.5)]);
    await elm.close();
  });

  test('после закрытия запросы падают с ElmDisconnectedException', () async {
    final elm = connect(SimScenario.healthy);
    await elm.initialize();
    await elm.close();
    expect(() => elm.send('0100'), throwsA(isA<ElmDisconnectedException>()));
  });

  test('LiveSampler: быстрые PID каждый круг, медленные по очереди', () async {
    final elm = connect(SimScenario.healthy);
    final info = await elm.initialize();
    final pids = [
      for (final p in standardPids)
        if (info.supportedPids.contains(p.code)) p,
    ];
    final sampler = LiveSampler(elm, pids);
    final samples = await sampler.run().take(60).toList();
    final keys = samples.map((s) => s.key).toList();
    final rpmCount = keys.where((k) => k == 'rpm').length;
    final coolantCount = keys.where((k) => k == 'coolant').length;
    expect(rpmCount, greaterThan(coolantCount));
    expect(keys.toSet(), containsAll(['rpm', 'speed', 'coolant']));
    await elm.close();
  });

  test('журнал обмена: команды, ответы, отключение', () async {
    final lines = <String>[];
    final elm = Elm327(SimulatedElm327(latency: Duration.zero), log: lines.add);
    await elm.initialize();
    expect(lines.first, 'TX ATZ');
    expect(lines, contains('TX 0100'));
    expect(
      lines.any((l) => l.startsWith('RX ') && l.contains('ELM327')),
      isTrue,
    );
    expect(lines.any((l) => l.contains('\r')), isFalse);
    await elm.close();
  });

  test(
    'K-Line: автопоиск не находит, перебор находит протокол 5 с адресом ВАЗ',
    () async {
      final lines = <String>[];
      final progress = <String>[];
      final elm = Elm327(
        SimulatedElm327(
          scenario: SimScenario.vacuumLeak,
          latency: Duration.zero,
          requiredProtocol: '5',
          requiredHeader: '8110F1',
        ),
        log: lines.add,
      );
      final info = await elm.initialize(onProgress: progress.add);
      expect(info.protocol, 5);
      expect(info.isCan, isFalse);
      expect(info.attempt?.header, '8110F1');
      expect(info.voltage, isNotNull);
      expect(info.supportedPids, contains(0x0C));
      expect(
        progress,
        hasLength(4),
      ); // автопоиск, CAN, K-Line, K-Line с адресом ВАЗ
      expect(lines, contains(startsWith('PROTOCOL автопоиск не нашёл')));
      expect(lines, contains(startsWith('PROTOCOL ответила')));
      // На K-Line коды и VIN приходят в формате старых протоколов.
      expect(await elm.readDtcs(), ['P0171']);
      expect(await elm.readVin(), SimulatedElm327.vin);
      expect(await elm.readPid(pidsByKey['coolant']!), isNotNull);
      await elm.close();
    },
  );

  test(
    'машина молчит на всех протоколах — понятная ошибка после перебора',
    () async {
      final lines = <String>[];
      final elm = Elm327(
        SimulatedElm327(latency: Duration.zero, requiredProtocol: '1'),
        log: lines.add,
      );
      await expectLater(
        elm.initialize(),
        throwsA(
          isA<ElmException>().having(
            (e) => e.error,
            'error',
            ElmError.unableToConnect,
          ),
        ),
      );
      expect(
        lines.where((l) => l.startsWith('PROTOCOL попытка')),
        hasLength(protocolFallbacks.length),
      );
      await elm.close();
    },
  );

  test('сохранённый протокол: сразу на нём, без автопоиска', () async {
    final lines = <String>[];
    final elm = Elm327(
      SimulatedElm327(
        latency: Duration.zero,
        requiredProtocol: '5',
        requiredHeader: '8110F1',
      ),
      log: lines.add,
    );
    final info = await elm.initialize(preferred: '5:8110F1');
    expect(info.protocol, 5);
    expect(info.protocolKey, '5:8110F1');
    expect(lines.where((l) => l == 'TX 0100'), hasLength(1));
    expect(lines.any((l) => l.contains('автопоиск')), isFalse);
    await elm.close();
  });

  test('сохранённый протокол не ответил — обычный поиск', () async {
    final lines = <String>[];
    final elm = Elm327(
      SimulatedElm327(latency: Duration.zero, requiredProtocol: '6'),
      log: lines.add,
    );
    final info = await elm.initialize(preferred: '5:8110F1');
    expect(info.protocol, 6);
    expect(info.protocolKey, '6');
    expect(lines, contains(startsWith('PROTOCOL сохранённый не ответил')));
    await elm.close();
  });

  test(
    'короткий CAN ERROR: повторы с закрытием протокола находят CAN',
    () async {
      final lines = <String>[];
      final progress = <String>[];
      final elm = Elm327(
        SimulatedElm327(latency: Duration.zero, canErrors: 2),
        log: lines.add,
        canRetryDelay: Duration.zero,
      );
      final info = await elm.initialize(onProgress: progress.add);
      expect(info.protocol, 6);
      expect(
        lines.where((l) => l.startsWith('PROTOCOL CAN ERROR, повтор')),
        hasLength(2),
      );
      expect(lines.where((l) => l == 'TX ATPC'), hasLength(2));
      expect(progress, contains(startsWith('Шина CAN не отвечает')));
      // До K-Line не дошло: CAN ожил на повторе.
      expect(lines.any((l) => l == 'TX ATSP5'), isFalse);
      await elm.close();
    },
  );

  test('сохранённый CAN с коротким CAN ERROR — без автопоиска', () async {
    final lines = <String>[];
    final elm = Elm327(
      SimulatedElm327(latency: Duration.zero, canErrors: 1),
      log: lines.add,
      canRetryDelay: Duration.zero,
    );
    final info = await elm.initialize(preferred: '6');
    expect(info.protocol, 6);
    expect(lines.any((l) => l == 'TX ATSP0'), isFalse);
    await elm.close();
  });

  test(
    'CAN ERROR не проходит — ошибка про шину CAN, а не «машина молчит»',
    () async {
      final elm = Elm327(
        SimulatedElm327(
          latency: Duration.zero,
          requiredProtocol: '6',
          canErrors: 1000,
        ),
        canRetryDelay: Duration.zero,
        canWaitStep: Duration.zero,
        canWaitTries: 5,
      );
      await expectLater(
        elm.initialize(),
        throwsA(
          isA<ElmException>().having(
            (e) => e.error,
            'error',
            ElmError.canError,
          ),
        ),
      );
      await elm.close();
    },
  );

  test('шина CAN оживает через минуту — дожидаемся, как Car Scanner', () async {
    final lines = <String>[];
    final progress = <String>[];
    final elm = Elm327(
      // Быстрый проход съедает 4 CAN ERROR (попытка и 3 повтора), ещё 8 — ожидание.
      SimulatedElm327(
        latency: Duration.zero,
        requiredProtocol: '6',
        canErrors: 12,
      ),
      log: lines.add,
      canRetryDelay: Duration.zero,
      canWaitStep: Duration.zero,
    );
    final info = await elm.initialize(onProgress: progress.add);
    expect(info.protocol, 6);
    expect(info.protocolKey, '6');
    expect(lines, contains('PROTOCOL CAN ожил на попытке 9 из 45'));
    expect(progress, contains(startsWith('Жду шину CAN машины… осталось')));
    // Раз в 5 попыток — полный сброс адаптера.
    expect(lines.where((l) => l == 'TX ATZ').length, greaterThan(6));
    await elm.close();
  });

  test('ERR94 после пуска двигателя: ATFE снимает запрет CAN сразу', () async {
    final lines = <String>[];
    final elm = Elm327(
      SimulatedElm327(latency: Duration.zero, err94: true),
      log: lines.add,
    );
    final info = await elm.initialize();
    expect(info.protocol, 6);
    // Автопоиск нашёл CAN с первого раза: ATFE ушёл сразу после ATZ.
    expect(lines.any((l) => l.contains('автопоиск не нашёл')), isFalse);
    final sent = [
      for (final l in lines)
        if (l.startsWith('TX ')) l.substring(3),
    ];
    expect(sent.indexOf('ATFE'), greaterThan(sent.indexOf('ATZ')));
    expect(sent.indexOf('ATFE'), lessThan(sent.indexOf('0100')));
    await elm.close();
  });

  test('при CAN ERROR состояние CAN адаптера пишется в журнал', () async {
    final lines = <String>[];
    final elm = Elm327(
      SimulatedElm327(latency: Duration.zero, canErrors: 2),
      log: lines.add,
      canRetryDelay: Duration.zero,
    );
    await elm.initialize();
    expect(
      lines.where((l) => l.startsWith('PROTOCOL состояние CAN адаптера:')),
      hasLength(1),
    );
    await elm.close();
  });

  test(
    '0100 ответил, 0120 — NO DATA: повтор, подключение не обрывается',
    () async {
      final lines = <String>[];
      final elm = Elm327(
        SimulatedElm327(latency: Duration.zero, noData0120: 2),
        log: lines.add,
      );
      final info = await elm.initialize();
      // Третья попытка 0120 удалась — вторая группа PID прочитана.
      expect(info.supportedPids, containsAll([0x0C, 0x2F]));
      expect(lines, contains('PROTOCOL 0120: noData, попытка 2 из 3'));
      await elm.close();
    },
  );

  test('0120 не отвечает совсем — работаем с первой группой PID', () async {
    final lines = <String>[];
    final elm = Elm327(
      SimulatedElm327(latency: Duration.zero, noData0120: 100),
      log: lines.add,
    );
    final info = await elm.initialize();
    expect(info.protocol, 6);
    expect(info.supportedPids, contains(0x0C));
    expect(info.supportedPids, isNot(contains(0x2F)));
    expect(
      lines,
      contains('PROTOCOL группа 20 не прочитана — работаем без неё'),
    );
    expect(await elm.readPid(pidsByKey['rpm']!), isNotNull);
    await elm.close();
  });

  test('зависшая отправка — тайм-аут, а не вечное ожидание', () async {
    // Гранта, 18.11: приложение заморозили в фоне посреди записи в Bluetooth,
    // запись не вернулась, и опрос встал навсегда — тайм-аут ждал только ответа.
    final transport = _HangingTransport(
      SimulatedElm327(latency: Duration.zero),
    );
    final lines = <String>[];
    final elm = Elm327(transport, log: lines.add);
    await elm.initialize();
    transport.hang = true;
    await expectLater(
      elm.send('010C', timeout: const Duration(milliseconds: 100)),
      throwsA(isA<ElmTimeoutException>()),
    );
    expect(lines, contains('TIMEOUT 010C (100 мс)'));
    // Отправка снова проходит — опрос продолжается.
    transport.hang = false;
    expect(await elm.readPid(pidsByKey['rpm']!), isNotNull);
    await elm.close();
  });

  test('ключ протокола туда и обратно', () {
    expect(ProtocolAttempt.fromKey('6')?.key, '6');
    expect(ProtocolAttempt.fromKey('5:8110F1')?.header, '8110F1');
    expect(ProtocolAttempt.fromKey('мусор'), isNull);
  });

  test('Wi-Fi: настоящий TCP-сокет до симулятора', () async {
    final server = await SimServer.start(scenario: SimScenario.vacuumLeak);
    final elm = Elm327(await TcpTransport.connect(server.host, server.port));
    final info = await elm.initialize();
    expect(info.isCan, isTrue);
    expect(await elm.readDtcs(), ['P0171']);
    expect(await elm.readVin(), SimulatedElm327.vin);
    await elm.close();
    await server.close();
    expect(server.connections, 1);
  });
}

/// Транспорт, у которого запись может зависнуть навсегда, как Bluetooth
/// после заморозки приложения.
class _HangingTransport implements ObdTransport {
  _HangingTransport(this._inner);

  final ObdTransport _inner;
  bool hang = false;

  @override
  Stream<List<int>> get input => _inner.input;

  @override
  Future<void> write(List<int> bytes) =>
      hang ? Completer<void>().future : _inner.write(bytes);

  @override
  Future<void> close() => _inner.close();
}
