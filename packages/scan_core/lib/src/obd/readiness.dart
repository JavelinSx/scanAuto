/// Готовность бортовых самопроверок — PID 01 режима 01 (SAE J1979).
///
/// Байт A: старший бит — горит ли «Check Engine», остальные — число кодов.
/// Байт B: бит 3 — 0 у бензинового двигателя; биты 0–2 — есть ли постоянные
/// проверки (пропуски, топливная система, компоненты), биты 4–6 — не завершены.
/// Байты C и D (бензин): какие проверки есть и какие ещё не завершены — по битам.
///
/// После сброса ошибок или снятия клеммы все проверки становятся незавершёнными,
/// пока блок не прогонит их в поездках. «Завершена» не значит «исправно»:
/// исправность — в кодах и в режиме 06.
library;

/// Проверка и её состояние.
final class MonitorReadiness {
  const MonitorReadiness(this.key, this.title, {required this.complete});

  /// Стабильный ключ для ИИ: 'catalyst', 'o2_sensor'.
  final String key;
  final String title;
  final bool complete;

  Map<String, Object?> toJson() => {'key': key, 'complete': complete};
}

final class ReadinessReport {
  const ReadinessReport({
    required this.tMs,
    required this.mil,
    required this.dtcCount,
    required this.spark,
    required this.monitors,
  });

  /// Байты A–D ответа на 0101. null — ответ короче.
  static ReadinessReport? parse(List<int> data, {int tMs = 0}) {
    if (data.length < 4) return null;
    final [a, b, c, d, ...] = data;
    final spark = b & 0x08 == 0;
    final monitors = <MonitorReadiness>[];
    void add(int available, int incomplete, int bit, String key, String t) {
      if (available & (1 << bit) != 0) {
        monitors.add(
          MonitorReadiness(key, t, complete: incomplete & (1 << bit) == 0),
        );
      }
    }

    // Постоянные проверки: доступность в битах 0–2, незавершённость в 4–6.
    add(b, b >> 4, 0, 'misfire', 'пропуски воспламенения');
    add(b, b >> 4, 1, 'fuel_system', 'топливная система');
    add(b, b >> 4, 2, 'components', 'компоненты');
    if (spark) {
      for (final (bit, key, title) in _sparkMonitors) {
        add(c, d, bit, key, title);
      }
    }
    return ReadinessReport(
      tMs: tMs,
      mil: a & 0x80 != 0,
      dtcCount: a & 0x7F,
      spark: spark,
      monitors: monitors,
    );
  }

  static const _sparkMonitors = [
    (0, 'catalyst', 'катализатор'),
    (1, 'heated_catalyst', 'подогрев катализатора'),
    (2, 'evap', 'улавливание паров бензина (адсорбер)'),
    (3, 'secondary_air', 'вторичный воздух'),
    (5, 'o2_sensor', 'лямбда-зонды'),
    (6, 'o2_heater', 'подогрев лямбда-зондов'),
    (7, 'egr', 'рециркуляция выхлопных газов'),
  ];

  /// Миллисекунды от начала записи.
  final int tMs;

  /// Горит «Check Engine».
  final bool mil;

  /// Сколько кодов неисправностей подтверждено.
  final int dtcCount;

  /// Бензиновый двигатель (для дизеля байты C и D значат другое — не разбираем).
  final bool spark;
  final List<MonitorReadiness> monitors;

  /// Для журнала: «Check Engine не горит, кодов 0; не завершены: катализатор».
  String get summary {
    final incomplete = [
      for (final m in monitors)
        if (!m.complete) m.title,
    ];
    return 'Check Engine ${mil ? 'горит' : 'не горит'}, кодов $dtcCount; '
        '${incomplete.isEmpty ? 'все проверки завершены' : 'не завершены: ${incomplete.join(', ')}'} '
        '(всего проверок ${monitors.length})';
  }

  Map<String, Object?> toJson() => {
    't': tMs,
    'mil': mil,
    'dtc_count': dtcCount,
    'spark': spark,
    'monitors': [for (final m in monitors) m.toJson()],
  };

  factory ReadinessReport.fromJson(Map<String, Object?> json) {
    final titles = {
      for (final (_, key, title) in _sparkMonitors) key: title,
      'misfire': 'пропуски воспламенения',
      'fuel_system': 'топливная система',
      'components': 'компоненты',
    };
    return ReadinessReport(
      tMs: (json['t'] as num? ?? 0).toInt(),
      mil: json['mil'] == true,
      dtcCount: (json['dtc_count'] as num? ?? 0).toInt(),
      spark: json['spark'] != false,
      monitors: [
        for (final m in (json['monitors'] as List? ?? const []))
          if (m case {'key': final String key, 'complete': final bool done})
            MonitorReadiness(key, titles[key] ?? key, complete: done),
      ],
    );
  }
}
