import '../obd/pids.dart';
import '../session/recording.dart';
import '../simulator/sim_engine.dart';
import 'diagnostic_program.dart';
import 'program_runner.dart';

/// Режим «машины» симулятора на этапе программы.
SimDrive simDriveFor(StageKind kind) => switch (kind) {
  StageKind.warmup => SimDrive.idle,
  StageKind.city => SimDrive.city,
  StageKind.highway => SimDrive.highway,
};

/// Вся программа диагностики на симуляторе без адаптера, мгновенно: все PID каждые
/// [step], этапы отмечает [ProgramRunner]. Для отладки промпта (bin/demo.dart) и тестов.
Recording simulateProgramRecording(
  SimScenario scenario,
  DiagnosticProgram program, {
  VehicleInfo? vehicle,
  Duration step = const Duration(milliseconds: 500),
  int seed = 1,
}) {
  final engine = SimEngine(
    scenario,
    seed: seed,
    ambient: program.season == Season.winter ? -10 : 20,
  );
  final start = DateTime.utc(2026, 11, 1, 9);
  final rec = Recording(startedAt: start, vehicle: vehicle)
    ..dtcs = [...scenario.dtcs];
  final runner = ProgramRunner(program, rec);
  // Предел на случай ошибки в условиях этапов: сумма максимумов с запасом.
  final limitMs = program.stages.fold(
    0,
    (sum, s) => sum + s.maxDuration.inMilliseconds + 60000,
  );
  engine.drive = simDriveFor(program.stages.first.kind);
  for (var ms = 0; ms <= limitMs; ms += step.inMilliseconds) {
    // Как в приложении: сначала замеры, потом решение по этапу.
    for (final pid in standardPids) {
      final raw = engine.mode01(pid.code, ms / 1000);
      final v = raw == null ? null : pid.decode(raw);
      if (v != null) rec.add(pid.key, start.add(Duration(milliseconds: ms)), v);
    }
    if (runner.update(ms).finished) break;
    engine.drive = simDriveFor(runner.stage.kind);
  }
  return rec;
}
