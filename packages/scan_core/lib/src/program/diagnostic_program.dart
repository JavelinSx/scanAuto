/// Сезон влияет на длительность прогрева и на то, как модель читает данные:
/// зимой холостые после пуска выше, прогрев на ХХ дольше, смесь богаче.
enum Season {
  summer('Лето'),
  winter('Зима');

  const Season(this.title);

  final String title;
}

enum StageKind {
  warmup('Прогрев'),
  city('Город'),
  highway('Трасса');

  const StageKind(this.title);

  final String title;
}

/// Прогон внутри этапа: какие параметры опрашивать в каждом круге.
/// Адаптер выполняет запросы строго по одному (клон по Bluetooth — 10–20 в секунду,
/// на K-Line меньше), поэтому чем короче список, тем чаще замеры этих параметров.
/// Остальные поддерживаемые PID опрашиваются по одному за круг.
final class StageRun {
  const StageRun(this.title, this.fastKeys, {this.duration});

  final String title;
  final Set<String> fastKeys;

  /// null — до конца этапа.
  final Duration? duration;
}

final class StageSpec {
  const StageSpec({
    required this.kind,
    required this.instruction,
    required this.target,
    required this.maxDuration,
    required this.runs,
    this.minDuration = Duration.zero,
  });

  final StageKind kind;

  /// Что делать водителю. Показывается крупно до старта этапа и во время него.
  final String instruction;

  /// Сколько засчитанного времени нужно. На трассе засчитывается только время
  /// на скорости от [DiagnosticProgram.highwaySpeed]. У прогрева цель — температура.
  final Duration target;
  final Duration minDuration;

  /// Этап заканчивается в любом случае: прогрев, не дошедший до температуры
  /// за это время, — уже находка (термостат, мороз).
  final Duration maxDuration;
  final List<StageRun> runs;

  String get title => kind.title;
}

/// Программа диагностики: прогрев → город → трасса.
final class DiagnosticProgram {
  const DiagnosticProgram(this.season, this.stages);

  /// Прогрев закончен, когда ОЖ дошла до этой температуры.
  static const warmCoolant = 80.0;

  /// На трассе засчитывается время только на этой скорости и выше.
  static const highwaySpeed = 70.0;

  /// Если на старте ОЖ уже выше — холодного пуска в записи не будет.
  static const alreadyWarmCoolant = 60.0;

  final Season season;
  final List<StageSpec> stages;

  /// Этапы независимы: [only] — какие проходить (порядок всегда прогрев → город →
  /// трасса). Например, только трасса, если двигатель уже прогрет и город не нужен.
  factory DiagnosticProgram.standard(Season season, {Set<StageKind>? only}) {
    final winter = season == Season.winter;
    final all = DiagnosticProgram(season, [
      StageSpec(
        kind: StageKind.warmup,
        instruction:
            'Заведите холодный двигатель и стойте на месте. Педали не трогайте, '
            'фары, обогрев и кондиционер выключите. Этап закончится сам, когда '
            'двигатель прогреется до ${warmCoolant.round()} °C'
            '${winter ? '. В сильный мороз на холостых он может не прогреться — тогда этап закончится по времени, это тоже результат' : ''}.',
        target: Duration.zero,
        minDuration: const Duration(minutes: 3),
        maxDuration: Duration(minutes: winter ? 20 : 12),
        runs: const [
          StageRun('Холодный пуск', {
            'rpm',
            'coolant',
            'stft1',
            'o2_b1s1',
            'maf',
            'timing',
          }),
        ],
      ),
      const StageSpec(
        kind: StageKind.city,
        instruction:
            'Обычная езда по городу: разгоны, светофоры, остановки на холостых. '
            'В телефон не смотрите — этап закончится сам через 10 минут.',
        target: Duration(minutes: 10),
        maxDuration: Duration(minutes: 10),
        runs: [
          StageRun('Смесь и нагрузка', {
            'rpm',
            'speed',
            'load',
            'throttle',
            'maf',
            'map',
            'stft1',
            'ltft1',
            'o2_b1s1',
          }, duration: Duration(minutes: 5)),
          StageRun('Зажигание и впуск', {
            'rpm',
            'speed',
            'load',
            'throttle',
            'timing',
            'map',
            'iat',
          }),
        ],
      ),
      StageSpec(
        kind: StageKind.highway,
        instruction:
            'Трасса или пустая широкая улица: ровно ${highwaySpeed.round()}–110 км/ч '
            'на высшей передаче, без резких разгонов. Время идёт только на '
            'скорости от ${highwaySpeed.round()} км/ч.',
        target: const Duration(minutes: 5),
        maxDuration: const Duration(minutes: 15),
        runs: const [
          // Короткий частый опрос лямбд: при общем опросе их переключения не видно.
          StageRun('Лямбда-зонды', {
            'o2_b1s1',
            'o2_b1s2',
            'rpm',
            'speed',
          }, duration: Duration(seconds: 45)),
          StageRun('Ровный режим', {
            'rpm',
            'speed',
            'load',
            'maf',
            'stft1',
            'ltft1',
            'o2_b1s2',
            'timing',
            'coolant',
          }),
        ],
      ),
    ]);
    if (only == null) return all;
    return DiagnosticProgram(season, [
      for (final s in all.stages)
        if (only.contains(s.kind)) s,
    ]);
  }
}
