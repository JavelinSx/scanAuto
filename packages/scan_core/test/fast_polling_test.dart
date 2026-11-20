import 'dart:convert';

import 'package:scan_core/scan_core.dart';
import 'package:test/test.dart';

List<Pid> _supported(ElmInfo info) => [
  for (final p in standardPids)
    if (info.supportedPids.contains(p.code)) p,
];

Iterable<String> _sent(List<String> lines) => lines
    .where((l) => l.startsWith('TX '))
    .map((l) => l.substring(3))
    .where((c) => !c.startsWith('AT'));

void main() {
  group('ускорение опроса', () {
    test('цифра числа ответов и несколько PID в запросе', () async {
      final lines = <String>[];
      final elm = Elm327(
        SimulatedElm327(latency: Duration.zero),
        log: lines.add,
      );
      final info = await elm.initialize();
      expect(info.responders, 1);
      expect(info.responseCount, isTrue);
      expect(info.multiPid, isTrue);
      expect(
        lines,
        contains(
          'PROTOCOL ускорение опроса: блоков ответило 1, '
          'цифра числа ответов — да, несколько PID в запросе — да',
        ),
      );

      lines.clear();
      expect(await elm.readPid(pidsByKey['rpm']!), isNotNull);
      expect(_sent(lines), ['010C1']);

      // Шесть PID — один запрос, ответ многокадровый (ISO-TP).
      lines.clear();
      final six = [
        for (final k in ['rpm', 'speed', 'coolant', 'load', 'maf', 'stft1'])
          pidsByKey[k]!,
      ];
      final values = await elm.readPids(six);
      expect(values.keys, unorderedEquals(six.map((p) => p.key)));
      expect(_sent(lines), ['010C0D05041006']);
      expect(
        lines.any((l) => l.startsWith('RX 0') && l.contains('0:')),
        isTrue,
      );
      expect(values['coolant'], 20);
      await elm.close();
    });

    test('клон без ускорения: опрос как раньше, по одному', () async {
      final lines = <String>[];
      final elm = Elm327(
        SimulatedElm327(
          latency: Duration.zero,
          responseCount: false,
          multiPid: false,
        ),
        log: lines.add,
      );
      final info = await elm.initialize();
      expect(info.responseCount, isFalse);
      expect(info.multiPid, isFalse);

      lines.clear();
      final values = await elm.readPids([
        pidsByKey['rpm']!,
        pidsByKey['speed']!,
      ]);
      expect(values.keys, unorderedEquals(['rpm', 'speed']));
      expect(_sent(lines), ['010C', '010D']);
      await elm.close();
    });

    test('опрос пачками: запросов в несколько раз меньше замеров', () async {
      final lines = <String>[];
      final elm = Elm327(
        SimulatedElm327(latency: Duration.zero),
        log: lines.add,
      );
      final info = await elm.initialize();
      lines.clear();
      final sampler = LiveSampler(elm, _supported(info));
      final samples = await sampler.run().take(120).toList();
      final requests = _sent(lines).where((c) => c.startsWith('01')).length;
      expect(requests, lessThan(40), reason: 'было бы 120 по одному PID');
      expect(samples.map((s) => s.key).toSet(), containsAll(['rpm', 'speed']));
      // Медленные PID тоже доходят.
      expect(samples.map((s) => s.key).toSet(), contains('fuel_sys'));
      await elm.close();
    });
  });

  group('готовность и бортовые тесты', () {
    test('PID 01: Check Engine, коды, незавершённые проверки', () {
      final r = ReadinessReport.parse([0x81, 0x07, 0x65, 0x04])!;
      expect(r.mil, isTrue);
      expect(r.dtcCount, 1);
      expect(r.spark, isTrue);
      expect(
        r.monitors.map((m) => m.key),
        containsAll(['misfire', 'catalyst', 'evap', 'o2_sensor', 'o2_heater']),
      );
      expect(r.monitors.firstWhere((m) => m.key == 'evap').complete, isFalse);
      expect(
        r.monitors.firstWhere((m) => m.key == 'catalyst').complete,
        isTrue,
      );
      expect(r.summary, contains('не завершены: улавливание паров'));
      final back = ReadinessReport.fromJson(
        (jsonDecode(jsonEncode(r.toJson())) as Map).cast<String, Object?>(),
      );
      expect(back.summary, r.summary);
    });

    test('блок: готовность и тесты лямбд из режима 06', () async {
      final elm = Elm327(
        SimulatedElm327(
          scenario: SimScenario.vacuumLeak,
          latency: Duration.zero,
        ),
      );
      await elm.initialize();
      final readiness = (await elm.readReadiness())!;
      expect(readiness.mil, isTrue);
      expect(readiness.dtcCount, 1);

      final report = (await elm.readMonitorTests())!;
      expect(report.tests.map((t) => t.mid).toSet(), {0x01, 0x02, 0x21, 0x41});
      final switchTime = report.tests.firstWhere(
        (t) => t.mid == 0x01 && t.tid == 0x05,
      );
      expect(switchTime.scaled, 70);
      expect(switchTime.unit, 'мс');
      expect(switchTime.outOfRange, isFalse);
      expect(
        report.lines,
        contains(
          'лямбда-зонд ряд 1 датчик 1 / время переключения богато→бедно '
          '= 70 мс (0…100)',
        ),
      );
      final threshold = report.tests.firstWhere(
        (t) => t.mid == 0x01 && t.tid == 0x01,
      );
      expect(threshold.scaled, closeTo(0.45, 0.001));
      await elm.close();
    });

    test('знаковые единицы: предел сравнивается со знаком', () {
      // UASID 0x8A — знаковое напряжение: −0.1 В при пределе −0.5…0.5.
      const t = MonitorTest(
        mid: 0x01,
        tid: 0x80,
        uasid: 0x8A,
        value: 0x10000 - 820,
        min: 0x10000 - 4098,
        max: 4098,
      );
      expect(t.outOfRange, isFalse);
      expect(t.scaled, closeTo(-0.1, 0.001));
    });
  });

  test(
    'разведка: Итэлма M74 CAN отвечает на 22 00 01, ответ пишется сырым',
    () async {
      final lines = <String>[];
      final elm = Elm327(
        SimulatedElm327(latency: Duration.zero, dataService: 0x22),
        log: lines.add,
      );
      final info = await elm.initialize();
      final probe = EcuProbe(elm);
      final results = await probe.run(isCan: true);
      expect(probe.dataBlockCommands, ['220001']);
      expect(results.firstWhere((r) => r.command == '2101').positive, isFalse);
      expect(
        results.firstWhere((r) => r.command == '220002').positive,
        isFalse,
      );
      // Ничего, кроме чтения.
      for (final c in _sent(lines)) {
        expect(
          ['01', '06', '09', '1A', '21', '22'].contains(c.substring(0, 2)),
          isTrue,
          reason: c,
        );
      }

      final rec = Recording(startedAt: DateTime.now());
      final sampler = LiveSampler(
        elm,
        _supported(info),
        rawCommands: probe.dataBlockCommands,
        rawEveryRounds: 2,
        rawHeader: '7E0',
        onRaw: rec.addRaw,
      );
      await sampler.run().take(40).drain<void>();
      expect(rec.raw['220001']!.hex.first, startsWith('620001'));
      expect(rec.raw['220001']!.hex.first.length, 126, reason: '63 байта');
      await elm.close();
    },
  );

  group('пакет для ИИ', () {
    test('коррекции: холостые против движения, только замкнутый контур', () {
      final rec = simulateProgramRecording(
        SimScenario.vacuumLeak,
        DiagnosticProgram.standard(Season.summer),
      );
      final packet = AnalysisPacket.build(rec);
      final derived = packet['derived']! as Map<String, Object?>;
      final trim = derived['fuel_trim']! as Map<String, Object?>;
      expect(trim['note'], contains('замкнутый контур'));
      final idle = trim['idle']! as Map<String, Object?>;
      final driving = trim['driving']! as Map<String, Object?>;
      // Подсос: на холостых коррекция заметно больше, чем в движении.
      expect(
        idle['total']! as num,
        greaterThan((driving['total']! as num) + 3),
      );
      expect(trim['excluded_samples']! as int, greaterThan(0));

      final fuel = derived['fuel_system']! as Map<String, Object?>;
      expect((fuel['shares']! as Map).keys, contains('замкнутый контур'));
      expect(fuel['first_closed_loop_s'], isNotNull);

      // Код состояния не уходит как числовой ряд.
      final keys = [
        for (final s in packet['series']! as List) (s as Map)['key'],
      ];
      expect(keys, isNot(contains('fuel_sys')));
      final stages = packet['stages']! as List;
      final warmup = (stages.first as Map)['derived'] as Map;
      expect(warmup['fuel_system'], isNotNull);
    });

    test('готовность и тесты режима 06 — в пакете и в JSON записи', () {
      final rec = Recording(startedAt: DateTime.utc(2026))
        ..readiness.add(ReadinessReport.parse([0x00, 0x07, 0x65, 0x04])!)
        ..monitorTests.add(
          const MonitorTestsReport(
            tMs: 5000,
            tests: [
              MonitorTest(
                mid: 0x01,
                tid: 0x05,
                uasid: 0x10,
                value: 150,
                min: 0,
                max: 100,
              ),
            ],
          ),
        );
      rec.add('rpm', rec.startedAt, 850);
      final back = Recording.fromJson(
        (jsonDecode(jsonEncode(rec.toJson())) as Map).cast<String, Object?>(),
      );
      expect(
        back.readiness.single.monitors,
        hasLength(rec.readiness.single.monitors.length),
      );
      expect(back.monitorTests.single.tests.single.value, 150);

      final packet = AnalysisPacket.build(back);
      final readiness = packet['readiness']! as Map<String, Object?>;
      final read = (readiness['reads']! as List).single as Map;
      expect(read['incomplete'], ['evap']);
      final tests = packet['monitor_tests']! as Map<String, Object?>;
      final test = (tests['tests']! as List).single as Map;
      expect(test['test'], 'время переключения богато→бедно');
      expect(test['value'], 150);
      expect(test['unit'], 'мс');
      expect(test['out_of_range'], isTrue);
    });

    test('состояние топливной системы — словами', () {
      expect(pidsByKey['fuel_sys']!.display(2), 'замкнутый контур');
      expect(pidsByKey['fuel_sys']!.display(1), 'открытый контур: прогрев');
      expect(pidsByKey['rpm']!.display(850), '850 об/мин');
      expect(pidsByKey['rpm']!.display(null), '—');
    });
  });
}
