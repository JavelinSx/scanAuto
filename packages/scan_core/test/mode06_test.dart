import 'dart:convert';

import 'package:scan_core/scan_core.dart';
import 'package:test/test.dart';

void main() {
  test('разбор записей режима 06 на CAN', () {
    final tests = parseMode06([
      0x46,
      0xA2, 0x0B, 0x24, 0x00, 0x03, 0x00, 0x00, 0xFF, 0xFF, //
      0xA2, 0x0C, 0x24, 0x00, 0x07, 0x00, 0x00, 0x00, 0x05,
      0xA2, // неполная запись — отброшена
    ]);
    expect(tests, hasLength(2));
    expect(tests[0].tid, misfireEwmaTid);
    expect(tests[0].value, 3);
    expect(tests[1].value, 7);
    expect(tests[1].failed, isTrue);
    expect(MisfireReport.countsFrom(tests), (current: 7, ewma: 3));
  });

  test('пропуски по цилиндрам через симулятор и в пакете для ИИ', () async {
    final elm = Elm327(
      SimulatedElm327(latency: Duration.zero, misfires: const {3: 12}),
    );
    await elm.initialize();
    final report = (await elm.readMisfires(tMs: 5000))!;
    expect(report.cylinders.keys, [1, 2, 3, 4]);
    expect(report.cylinders[3], (current: 12, ewma: 6));
    expect(report.cylinders[1], (current: 0, ewma: 0));
    expect(report.total?.current, 12);
    expect(report.toString(), contains('ц3 12/6'));

    final rec = Recording(startedAt: DateTime.utc(2026))..misfires.add(report);
    final copy = Recording.fromJson(
      (jsonDecode(jsonEncode(rec.toJson())) as Map).cast<String, Object?>(),
    );
    expect(copy.misfires.single.cylinders[3], (current: 12, ewma: 6));
    final packet = AnalysisPacket.build(rec);
    expect(jsonEncode(packet['misfires']), contains('"current":12'));
    await elm.close();
  });

  test('не CAN или нет поддержки — null, а не ошибка', () async {
    final kline = Elm327(
      SimulatedElm327(latency: Duration.zero, requiredProtocol: '5'),
    );
    await kline.initialize();
    expect(await kline.readMisfires(), isNull);
    await kline.close();
  });
}
