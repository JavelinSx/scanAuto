import 'dart:convert';

import 'package:scan_core/scan_core.dart';
import 'package:test/test.dart';

const _granta = VehicleInfo(
  make: 'Lada',
  model: 'Granta',
  engine: '1.6 8 кл. ВАЗ-11186, 87 л.с.',
  year: 2019,
  mileageKm: 84000,
  transmission: 'механика',
  vin: SimulatedElm327.vin,
);

Map<String, Object?> _stage(Map<String, Object?> packet, String key) =>
    (packet['stages']! as List).cast<Map<String, Object?>>().firstWhere(
      (s) => s['key'] == key,
    );

num _median(Map<String, Object?> stage, String pid) =>
    ((stage['stats']! as Map)[pid]! as Map)['median']! as num;

void main() {
  test('лето, исправный: три этапа по порядку, цели достигнуты', () {
    final rec = simulateProgramRecording(
      SimScenario.healthy,
      DiagnosticProgram.standard(Season.summer),
      vehicle: _granta,
    );
    expect(rec.season, 'summer');
    expect(rec.segments.map((s) => s.key), ['warmup', 'city', 'highway']);
    expect(rec.segments.every((s) => s.completed), isTrue);

    final [warmup, city, highway] = rec.segments;
    final warmupS = (warmup.endMs - warmup.startMs) / 1000;
    expect(warmupS, inInclusiveRange(180, 12 * 60));
    expect((city.endMs - city.startMs) / 1000, closeTo(600, 1));
    // На трассе симулятор едет ровно 90 км/ч — засчитывается почти всё время.
    expect((highway.endMs - highway.startMs) / 1000, closeTo(300, 2));
  });

  test('зима, открытый термостат: прогрев заканчивается по времени', () {
    final rec = simulateProgramRecording(
      SimScenario.thermostatStuckOpen,
      DiagnosticProgram.standard(Season.winter),
    );
    final warmup = rec.segments.first;
    expect(warmup.completed, isFalse);
    expect(warmup.note, contains('не дошла до 80'));
    expect(warmup.endMs - warmup.startMs, closeTo(20 * 60000, 1000));
  });

  test('пакет: этапы, сезон, профиль без VIN, признаки прогрева', () {
    final rec = simulateProgramRecording(
      SimScenario.vacuumLeak,
      DiagnosticProgram.standard(Season.summer),
      vehicle: _granta,
    );
    final packet = AnalysisPacket.build(rec);
    final text = jsonEncode(packet);
    expect(text, isNot(contains(SimulatedElm327.vin)));
    expect(packet['season'], 'summer');
    expect((packet['vehicle']! as Map)['engine'], contains('11186'));

    final warmup = _stage(packet, 'warmup');
    final derived = warmup['derived']! as Map;
    expect(derived['coolant_start'], 20);
    expect(derived['reached_80c_after_s'], isNotNull);
    // Холодные холостые выше прогретых.
    expect(
      derived['rpm_first_minute']! as num,
      greaterThan(derived['rpm_last_minute']! as num),
    );

    // Подсос: коррекция на холостых прогрева выше, чем на трассе.
    expect(_median(warmup, 'ltft1'), greaterThan(10));
    expect(_median(_stage(packet, 'highway'), 'ltft1'), lessThan(6));

    final message = diagnosisUserMessage(packet);
    expect(message.length, lessThan(80000));
  });

  test('прогоны трассы: сначала лямбды 45 с, потом ровный режим', () {
    final program = DiagnosticProgram.standard(Season.summer);
    final rec = Recording(startedAt: DateTime.utc(2026));
    final runner = ProgramRunner(program, rec);
    final seen = <(int, int)>[];
    var ms = 0;
    void tick(double coolant, double speed) {
      rec.add(
        'coolant',
        rec.startedAt.add(Duration(milliseconds: ms)),
        coolant,
      );
      rec.add('speed', rec.startedAt.add(Duration(milliseconds: ms)), speed);
      final s = runner.update(ms);
      if (s.runChanged) seen.add((s.stageIndex, s.runIndex));
      ms += 1000;
    }

    // Прогрев: тёплый двигатель, этап закончится по минимуму в 3 минуты.
    for (var i = 0; i < 200; i++) {
      tick(85, 0);
    }
    expect(rec.segments.single.note, contains('уже был тёплым'));
    // Город 10 минут, трасса 5 минут на 90 км/ч.
    for (var i = 0; i < 600; i++) {
      tick(90, 30);
    }
    for (var i = 0; i < 400 && !runner.finished; i++) {
      tick(90, 90);
    }
    expect(runner.finished, isTrue);
    expect(seen, [(0, 0), (1, 0), (1, 1), (2, 0), (2, 1)]);
  });

  test('трасса: медленная езда не засчитывается, досрочный конец отмечен', () {
    final program = DiagnosticProgram.standard(Season.summer);
    final rec = Recording(startedAt: DateTime.utc(2026));
    final runner = ProgramRunner(program, rec);
    var ms = 0;
    ProgramStatus tick(double speed) {
      rec.add('coolant', rec.startedAt.add(Duration(milliseconds: ms)), 90);
      rec.add('speed', rec.startedAt.add(Duration(milliseconds: ms)), speed);
      final s = runner.update(ms);
      ms += 1000;
      return s;
    }

    tick(0);
    runner.skip(ms); // прогрев
    tick(0);
    runner.skip(ms); // город
    ProgramStatus? last;
    for (var i = 0; i < 120; i++) {
      last = tick(50);
    }
    expect(last!.counted, Duration.zero);
    expect(last.hint, contains('ниже 70'));
    runner.abort(ms);
    expect(rec.segments.map((s) => s.completed), [false, false, false]);
    expect(rec.segments.last.note, 'программа прервана');
  });

  test('LiveSampler.setFocus меняет быстрый набор', () {
    final sampler = LiveSampler(
      Elm327(SimulatedElm327()),
      standardPids,
      focus: {'rpm', 'speed'},
    );
    expect(sampler.fast.map((p) => p.key), ['rpm', 'speed']);
    sampler.setFocus({'o2_b1s1'});
    expect(sampler.fast.map((p) => p.key), ['o2_b1s1']);
    expect(sampler.slow, hasLength(standardPids.length - 1));
  });

  test('профиль и этапы переживают JSON', () {
    final rec = simulateProgramRecording(
      SimScenario.healthy,
      DiagnosticProgram.standard(Season.summer),
      vehicle: _granta,
      step: const Duration(seconds: 2),
    );
    final copy = Recording.fromJson(
      (jsonDecode(jsonEncode(rec.toJson())) as Map).cast<String, Object?>(),
    );
    expect(copy.season, 'summer');
    expect(copy.segments.map((s) => s.key), ['warmup', 'city', 'highway']);
    expect(copy.vehicle?.engine, _granta.engine);
    expect(copy.vehicle?.mileageKm, 84000);
  });
}
