import 'dart:convert';

import 'package:scan_core/scan_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'разведка: только чтение, блок данных найден, ответы записаны',
    () async {
      final lines = <String>[];
      final elm = Elm327(
        SimulatedElm327(latency: Duration.zero),
        log: lines.add,
      );
      await elm.initialize();
      final probe = EcuProbe(elm);
      final results = await probe.run(isCan: true);

      expect(probe.dataBlockCommand, '2101');
      expect(results.firstWhere((r) => r.command == '2101').positive, isTrue);
      expect(
        results.firstWhere((r) => r.command == '22F190').positive,
        isFalse,
      );
      // Никаких записей и опасных сервисов: только 01/06/09/1A/21/22 и ATSH.
      final sent = lines
          .where((l) => l.startsWith('TX '))
          .map((l) => l.substring(3))
          .where((c) => !c.startsWith('AT'));
      for (final c in sent) {
        expect(
          ['01', '06', '09', '1A', '21', '22'].contains(c.substring(0, 2)),
          isTrue,
          reason: c,
        );
      }
      expect(lines, contains('TX ATSH7E0'));
      await elm.close();
    },
  );

  test('сырой блок пишется в запись и переживает JSON', () async {
    final elm = Elm327(SimulatedElm327(latency: Duration.zero));
    final info = await elm.initialize();
    final rec = Recording(startedAt: DateTime.now());
    final sampler = LiveSampler(
      elm,
      [
        for (final p in standardPids)
          if (info.supportedPids.contains(p.code)) p,
      ],
      rawCommands: const ['2101'],
      rawEveryRounds: 2,
      rawHeader: '7E0',
      onRaw: rec.addRaw,
    );
    await sampler.run().take(40).drain<void>();
    final raw = rec.raw['2101']!;
    expect(raw.hex, isNotEmpty);
    expect(raw.hex.first, startsWith('6101'));

    final copy = Recording.fromJson(
      (jsonDecode(jsonEncode(rec.toJson())) as Map).cast<String, Object?>(),
    );
    expect(copy.raw['2101']!.hex, raw.hex);
    await elm.close();
  });
}
