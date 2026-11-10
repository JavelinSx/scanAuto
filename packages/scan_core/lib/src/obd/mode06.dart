/// Режим 06 — результаты бортовых тестов (SAE J1979 / ISO 15031-5), формат CAN.
///
/// Ответ: `46`, затем записи по 9 байт: OBDMID, TID, UASID (единицы и масштаб),
/// значение, нижний и верхний предел (по 2 байта). Для MID `00`, `20`… `E0` вместо
/// записей — 4 байта маски поддерживаемых MID, как у режима 01.
library;

/// Одна запись теста.
final class MonitorTest {
  const MonitorTest({
    required this.mid,
    required this.tid,
    required this.uasid,
    required this.value,
    required this.min,
    required this.max,
  });

  final int mid;
  final int tid;

  /// Идентификатор единиц и масштаба. 0x24 — штуки («counts»), без масштаба.
  final int uasid;

  /// Сырые 16-битные значения: масштаб зависит от [uasid].
  final int value;
  final int min;
  final int max;

  /// Вне пределов — тест не пройден.
  bool get failed => value < min || value > max;
}

/// Записи из ответа режима 06 на CAN. Неполная запись в конце отбрасывается.
List<MonitorTest> parseMode06(List<int> message) {
  if (message.isEmpty || message[0] != 0x46) return const [];
  final tests = <MonitorTest>[];
  for (var i = 1; i + 9 <= message.length; i += 9) {
    int word(int at) => message[at] << 8 | message[at + 1];
    tests.add(
      MonitorTest(
        mid: message[i],
        tid: message[i + 1],
        uasid: message[i + 2],
        value: word(i + 3),
        min: word(i + 5),
        max: word(i + 7),
      ),
    );
  }
  return tests;
}

/// MID пропусков воспламенения: A1 — все цилиндры, A2… — цилиндры с 1-го.
const misfireGeneralMid = 0xA1;
int misfireCylinderMid(int cylinder) => 0xA1 + cylinder;

/// TID пропусков (J1979): 0B — сглаженное среднее за последние 10 поездок,
/// 0C — счёт за текущую (или последнюю завершённую) поездку.
const misfireEwmaTid = 0x0B;
const misfireCurrentTid = 0x0C;

/// Пропуски по цилиндрам на момент чтения.
final class MisfireReport {
  const MisfireReport({required this.tMs, required this.cylinders, this.total});

  /// Время чтения — миллисекунды от начала записи.
  final int tMs;

  /// Номер цилиндра → (за текущую поездку, среднее за 10 поездок).
  final Map<int, ({int? current, int? ewma})> cylinders;
  final ({int? current, int? ewma})? total;

  static ({int? current, int? ewma}) countsFrom(List<MonitorTest> tests) {
    int? pick(int tid) {
      for (final t in tests) {
        if (t.tid == tid) return t.value;
      }
      return null;
    }

    return (current: pick(misfireCurrentTid), ewma: pick(misfireEwmaTid));
  }

  Map<String, Object?> toJson() => {
    't': tMs,
    if (total case final t?) 'total': {'current': t.current, 'ewma': t.ewma},
    'cylinders': [
      for (final MapEntry(:key, :value) in cylinders.entries)
        {'cylinder': key, 'current': value.current, 'ewma': value.ewma},
    ],
  };

  factory MisfireReport.fromJson(Map<String, Object?> json) {
    ({int? current, int? ewma}) counts(Map<String, Object?> m) => (
      current: (m['current'] as num?)?.toInt(),
      ewma: (m['ewma'] as num?)?.toInt(),
    );
    return MisfireReport(
      tMs: (json['t']! as num).toInt(),
      total: json['total'] == null
          ? null
          : counts((json['total']! as Map).cast<String, Object?>()),
      cylinders: {
        for (final c
            in (json['cylinders']! as List).cast<Map<Object?, Object?>>())
          (c['cylinder']! as num).toInt(): counts(c.cast<String, Object?>()),
      },
    );
  }

  @override
  String toString() => [
    for (final MapEntry(:key, :value) in cylinders.entries)
      'ц$key ${value.current ?? '—'}/${value.ewma ?? '—'}',
  ].join(', ');
}
