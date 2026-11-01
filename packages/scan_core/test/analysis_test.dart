import 'dart:convert';

import 'package:scan_core/scan_core.dart';
import 'package:test/test.dart';

Map<String, Object?> _series(Map<String, Object?> packet, String key) =>
    (packet['series']! as List).cast<Map<String, Object?>>().firstWhere(
      (s) => s['key'] == key,
    );

num _stat(Map<String, Object?> series, String mode, String stat) =>
    ((series['stats']! as Map)[mode]! as Map)[stat]! as num;

void main() {
  test('LTTB: концы на месте, число точек — как просили', () {
    final t = [for (var i = 0; i < 1000; i++) i * 100];
    final v = [for (var i = 0; i < 1000; i++) i == 500 ? 100.0 : 0.0];
    final out = lttb(t, v, 50);
    expect(out, hasLength(50));
    expect(out.first, (0, 0.0));
    expect(out.last, (99900, 0.0));
    // Одиночный пик не теряется, в отличие от усреднения.
    expect(out.any((p) => p.$2 == 100.0), isTrue);
  });

  test('подсос воздуха: коррекция на ХХ заметно выше, чем в движении', () {
    final packet = AnalysisPacket.build(
      simulateRecording(SimScenario.vacuumLeak),
    );
    final ltft = _series(packet, 'ltft1');
    expect(_stat(ltft, 'idle', 'median'), greaterThan(10));
    expect(_stat(ltft, 'driving', 'median'), lessThan(6));
    expect((packet['dtcs']! as List).single, {
      'code': 'P0171',
      'description': 'Слишком бедная смесь, ряд 1',
    });
  });

  test('исправный двигатель: коррекции около нуля, прогрев до 80 °C', () {
    final packet = AnalysisPacket.build(simulateRecording(SimScenario.healthy));
    expect(
      _stat(_series(packet, 'ltft1'), 'idle', 'median'),
      closeTo(1.6, 0.5),
    );
    final coolant = (packet['derived']! as Map)['coolant']! as Map;
    expect(coolant['reached_80c_after_s'], isNotNull);
    final o2 = (packet['derived']! as Map)['o2_b1s1']! as Map;
    final rate = o2['crossings_per_min']! as Map;
    expect(rate['idle'], greaterThan(10));
    expect(
      rate['driving'],
      lessThanOrEqualTo(o2['max_detectable_per_min']! as num),
    );
  });

  test('открытый термостат: до 80 °C не доходит', () {
    final packet = AnalysisPacket.build(
      simulateRecording(
        SimScenario.thermostatStuckOpen,
        duration: const Duration(minutes: 10),
      ),
    );
    final coolant = (packet['derived']! as Map)['coolant']! as Map;
    expect(coolant['reached_80c_after_s'], isNull);
    expect(coolant['max'], lessThan(75));
  });

  test('пакет без VIN, графики прорежены, режимы посчитаны', () {
    final rec = simulateRecording(SimScenario.healthy)
      ..vehicle = const VehicleInfo(
        title: 'Lada Vesta',
        vin: SimulatedElm327.vin,
      );
    final packet = AnalysisPacket.build(rec, maxPoints: 40);
    final text = jsonEncode(packet);
    expect(text, isNot(contains(SimulatedElm327.vin)));
    expect(packet['vehicle'], 'Lada Vesta');
    expect((_series(packet, 'rpm')['points']! as List), hasLength(40));
    final conditions = packet['conditions']! as Map;
    expect(
      (conditions['idle_s']! as int) + (conditions['driving_s']! as int),
      closeTo(300, 2),
    );
    // Сообщение для модели укладывается в разумный объём.
    expect(diagnosisUserMessage(packet).length, lessThan(60000));
  });

  test('запись: JSON туда и обратно', () {
    final rec = simulateRecording(
      SimScenario.vacuumLeak,
      duration: const Duration(seconds: 10),
    )..vehicle = const VehicleInfo(title: 'Тест', vin: 'X');
    final copy = Recording.fromJson(
      (jsonDecode(jsonEncode(rec.toJson())) as Map).cast<String, Object?>(),
    );
    expect(copy.startedAt, rec.startedAt);
    expect(copy.dtcs, ['P0171']);
    expect(copy.vehicle?.vin, 'X');
    expect(copy.series.keys, rec.series.keys);
    expect(copy.series['rpm']!.values, rec.series['rpm']!.values);
    expect(copy.duration, const Duration(seconds: 10));
  });

  test('Series: поиск по времени и ближайшее значение', () {
    final s = Series('x');
    for (final (t, v) in [(0, 1.0), (1000, 2.0), (2000, 3.0)]) {
      s.tMs.add(t);
      s.values.add(v);
    }
    expect(s.lowerBound(-5), 0);
    expect(s.lowerBound(1000), 1);
    expect(s.lowerBound(1001), 2);
    expect(s.lowerBound(5000), 3);
    expect(s.valueNear(400), 1.0);
    expect(s.valueNear(600), 2.0);
    expect(s.valueNear(9000), 3.0);
  });

  test('keepLast: срезает старое с запасом, время не сдвигает', () {
    final rec = simulateRecording(
      SimScenario.healthy,
      duration: const Duration(minutes: 20),
      step: const Duration(seconds: 1),
    );
    // Старше окна на 5 минут — в пределах запаса, не трогаем.
    rec.keepLast(const Duration(minutes: 15));
    expect(rec.coveredFrom, Duration.zero);

    rec.keepLast(const Duration(minutes: 10));
    expect(rec.coveredFrom, const Duration(minutes: 10));
    expect(rec.duration, const Duration(minutes: 20));
    expect(rec.series['rpm']!.length, 601);
    // Пакет для ИИ строится и по обрезанной записи.
    expect(AnalysisPacket.build(rec)['series'], isNotEmpty);
  });
}
