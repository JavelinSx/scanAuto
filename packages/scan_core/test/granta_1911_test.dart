import 'package:scan_core/scan_core.dart';
import 'package:test/test.dart';

/// Ответ Гранты (Итэлма M74 CAN) на 22 00 01 из записи 19.11.2026, полный.
const _granta0001 =
    '620001009000990E38000601EF0098000002E80062809C5FA480003B00CC7794000701A0'
    '4B00000000005AFE8D0020005DFF12990023012940FA4DD2B50100';

List<int> _bytes(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

void main() {
  test('22 00 01 Гранты: напряжение, ОЖ, обороты, коррекция, воздух', () {
    final v = VazBlock0001.decode(_bytes(_granta0001))!;
    expect(v['ecu_voltage'], 14.4);
    expect(v['coolant'], closeTo(66.75, 0.01)); // в журнале прогрев с 67 °C
    expect(v['rpm'], 910);
    expect(v['ltft1'], closeTo(-7.0, 0.1));
    expect(v['iat'], closeTo(8.25, 0.01));
    // Оборванный ответ не расшифровывается.
    expect(VazBlock0001.decode(_bytes(_granta0001).sublist(0, 20)), isNull);
  });

  test('оборванный многокадровый ответ виден по длине', () {
    // 22 00 03: 28 байт, а пришло три кадра из пяти (журнал 19.11).
    const cut = '01C\r0:6200039A2EB9\r1:0CE001F80E0800\r2:EC00760300011C\r\r';
    expect(isoTpMissingBytes(cut), 8);
    const full =
        '01C\r0:6200039B30BA\r1:0CC501F40E0C00\r2:EC00761E000121\r'
        '3:00000898006400\r4:1BAAAAAAAAAAAA\r\r';
    expect(isoTpMissingBytes(full), 0);
    expect(isoTpMissingBytes('410C0DDC\r\r'), 0);
  });

  test(
    'оборванные ответы не пишутся; с паузой между кадрами доходят',
    () async {
      Future<LiveSampler> run({required bool flowControl}) async {
        final elm = Elm327(
          SimulatedElm327(
            latency: Duration.zero,
            dataService: 0x22,
            truncateIsoTp: true,
          ),
        );
        final info = await elm.initialize();
        final rec = Recording(startedAt: DateTime.now());
        final sampler = LiveSampler(
          elm,
          [
            for (final p in standardPids)
              if (info.supportedPids.contains(p.code)) p,
          ],
          rawCommands: const ['220001'],
          rawEveryRounds: 1,
          rawHeader: '7E0',
          rawSetup: flowControl ? const ['ATFCSM1'] : const [],
          rawTeardown: flowControl ? const ['ATFCSM0'] : const [],
          onRaw: rec.addRaw,
        );
        await sampler.run().take(60).drain<void>();
        for (final hex in rec.raw['220001']?.hex ?? const <String>[]) {
          expect(hex.length, 126, reason: 'в запись — только полные');
        }
        await elm.close();
        return sampler;
      }

      final plain = await run(flowControl: false);
      expect(plain.rawIncomplete, greaterThan(0));
      expect(plain.rawComplete, 0);
      final paced = await run(flowControl: true);
      expect(paced.rawIncomplete, 0);
      expect(paced.rawComplete, greaterThan(0));
    },
  );

  test(
    'разведка: управление потоком принято, если адаптер его знает',
    () async {
      final elm = Elm327(
        SimulatedElm327(latency: Duration.zero, dataService: 0x22),
      );
      await elm.initialize();
      final probe = EcuProbe(elm);
      final results = await probe.run(isCan: true);
      expect(probe.flowControl, isTrue);
      expect(results.last.command, 'ATFCSM1');
      await elm.close();
    },
  );

  test(
    'сохранённый CAN молчит (CAN ERROR): сразу ждём шину, без K-Line',
    () async {
      final lines = <String>[];
      final elm = Elm327(
        SimulatedElm327(
          latency: Duration.zero,
          requiredProtocol: '6',
          canErrors: 8,
        ),
        log: lines.add,
        canRetryDelay: Duration.zero,
        canWaitStep: Duration.zero,
      );
      final info = await elm.initialize(preferred: '6');
      expect(info.protocol, 6);
      expect(
        lines,
        contains('PROTOCOL автопоиск и K-Line пропускаем: машина на CAN'),
      );
      expect(lines.where((l) => l == 'TX ATSP0' || l == 'TX ATSP5'), isEmpty);
      expect(lines, contains(startsWith('PROTOCOL CAN ожил на попытке')));
      await elm.close();
    },
  );

  test('тайм-аут адаптера: короче не быстрее — остаётся ATST32', () async {
    final lines = <String>[];
    final elm = Elm327(SimulatedElm327(latency: Duration.zero), log: lines.add);
    await elm.initialize();
    expect(lines, contains(startsWith('PROTOCOL тайм-аут адаптера: ')));
    final sentSt = [
      for (final l in lines)
        if (l.startsWith('TX ATST')) l.substring(3),
    ];
    expect(sentSt.last, 'ATST32');
    await elm.close();
  });

  test('режим 06: 0 при ненулевых пределах — нет результата', () {
    const notRun = MonitorTest(
      mid: 0x01,
      tid: 0x09,
      uasid: 0x10,
      value: 0,
      min: 160,
      max: 2000,
    );
    expect(notRun.noResult, isTrue);
    expect(notRun.describe()['no_result'], isTrue);
    expect(
      const MonitorTestsReport(tMs: 0, tests: [notRun]).lines.single,
      endsWith('нет результата'),
    );
  });
}
