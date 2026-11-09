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
      expect(progress, hasLength(2));
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
