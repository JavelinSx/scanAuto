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

  /// Значение вне пределов, заданных блоком. У знаковых единиц (UASID
  /// 0x81…0xFE) сравнение со знаком. Это не обязательно неисправность: в начале
  /// поездки тест часто ещё не выполнялся (см. [noResult]), а пределы ВАЗ для
  /// лямбд в режиме 06 не документированы — неисправность подтверждает код.
  bool get outOfRange {
    final v = _signed(value), lo = _signed(min), hi = _signed(max);
    return v < lo || v > hi;
  }

  /// Значение 0 при ненулевых пределах: тест, скорее всего, ещё не выполнялся
  /// в этой поездке (Гранта 19.11: «время между переключениями» 0 мс в начале
  /// и 1920 мс в конце).
  bool get noResult => value == 0 && (min != 0 || max != 0);

  bool get _isSigned => uasid >= 0x81 && uasid <= 0xFE;
  int _signed(int raw) => _isSigned && raw >= 0x8000 ? raw - 0x10000 : raw;

  /// Значение в физических единицах, если масштаб [uasid] известен.
  double? get scaled => _scale(_signed(value));
  double? get scaledMin => _scale(_signed(min));
  double? get scaledMax => _scale(_signed(max));
  String? get unit => _uasids[_isSigned ? uasid - 0x80 : uasid]?.$2;

  double? _scale(int raw) {
    final u = _uasids[_isSigned ? uasid - 0x80 : uasid];
    return u == null ? null : raw * u.$1;
  }

  /// Масштаб и единицы самых частых UASID (J1979, приложение E);
  /// у остальных в пакет уходит сырое значение.
  static const _uasids = <int, (double, String)>{
    0x01: (1, ''),
    0x02: (0.1, ''),
    0x03: (0.01, ''),
    0x04: (0.001, ''),
    0x0A: (0.000122, 'В'),
    0x0B: (0.001, 'В'),
    0x0C: (0.01, 'В'),
    0x10: (1, 'мс'),
    0x11: (100, 'мс'),
    0x12: (1, 'с'),
    0x24: (1, 'шт'),
  };

  Map<String, Object?> toJson() => {
    'mid': mid,
    'tid': tid,
    'uasid': uasid,
    'value': value,
    'min': min,
    'max': max,
  };

  factory MonitorTest.fromJson(Map<String, Object?> json) => MonitorTest(
    mid: (json['mid']! as num).toInt(),
    tid: (json['tid']! as num).toInt(),
    uasid: (json['uasid']! as num).toInt(),
    value: (json['value']! as num).toInt(),
    min: (json['min']! as num).toInt(),
    max: (json['max']! as num).toInt(),
  );

  /// Для ИИ: что за тест, значение с единицами, пределы, пройден ли.
  Map<String, Object?> describe() {
    num? round(double? v) =>
        v == null ? null : (v * 10000).roundToDouble() / 10000;
    return {
      'monitor': monitorTitle(mid),
      'test': testTitle(mid, tid),
      'mid': mid.toRadixString(16).padLeft(2, '0').toUpperCase(),
      'tid': tid.toRadixString(16).padLeft(2, '0').toUpperCase(),
      if (scaled != null) ...{
        'value': round(scaled),
        'min': round(scaledMin),
        'max': round(scaledMax),
        'unit': unit,
      } else ...{
        'raw': value,
        'raw_min': min,
        'raw_max': max,
        'uasid': uasid,
      },
      'out_of_range': outOfRange,
      if (noResult) 'no_result': true,
    };
  }
}

/// Название группы тестов по OBDMID (J1979).
String monitorTitle(int mid) {
  if (mid >= 0x01 && mid <= 0x08) {
    return 'лямбда-зонд ряд ${(mid - 1) ~/ 4 + 1} датчик ${(mid - 1) % 4 + 1}';
  }
  if (mid >= 0x21 && mid <= 0x24) return 'катализатор ряд ${mid - 0x20}';
  if (mid >= 0x31 && mid <= 0x38) return 'рециркуляция выхлопа (EGR)';
  if (mid >= 0x39 && mid <= 0x3D) return 'улавливание паров бензина (EVAP)';
  if (mid >= 0x41 && mid <= 0x48) {
    return 'подогрев лямбда-зонда ряд ${(mid - 0x41) ~/ 4 + 1} '
        'датчик ${(mid - 0x41) % 4 + 1}';
  }
  if (mid >= 0x71 && mid <= 0x74) return 'вторичный воздух';
  if (mid >= 0x81 && mid <= 0x84) return 'топливная система ряд ${mid - 0x80}';
  if (mid == misfireGeneralMid) return 'пропуски воспламенения, все цилиндры';
  if (mid > misfireGeneralMid && mid <= 0xAD) {
    return 'пропуски воспламенения, цилиндр ${mid - misfireGeneralMid}';
  }
  return 'тест MID ${mid.toRadixString(16).toUpperCase()}';
}

/// Стандартные TID лямбда-зондов (J1979; у производителя смысл может отличаться,
/// TID 80 и выше — свои у каждого производителя).
String testTitle(int mid, int tid) {
  if (mid >= 0x01 && mid <= 0x08) {
    final title = switch (tid) {
      0x01 => 'порог переключения богато→бедно',
      0x02 => 'порог переключения бедно→богато',
      0x03 => 'нижнее напряжение для расчёта времени переключения',
      0x04 => 'верхнее напряжение для расчёта времени переключения',
      0x05 => 'время переключения богато→бедно',
      0x06 => 'время переключения бедно→богато',
      0x07 => 'минимальное напряжение зонда',
      0x08 => 'максимальное напряжение зонда',
      0x09 => 'время между переключениями',
      0x0A => 'период переключения',
      _ => null,
    };
    if (title != null) return title;
  }
  if (mid >= misfireGeneralMid && mid <= 0xAD) {
    if (tid == misfireEwmaTid) return 'среднее за 10 поездок';
    if (tid == misfireCurrentTid) return 'за текущую поездку';
  }
  return tid >= 0x80
      ? 'тест производителя ${tid.toRadixString(16).toUpperCase()}'
      : 'тест ${tid.toRadixString(16).toUpperCase()}';
}

/// Все бортовые тесты, прочитанные разом (в начале и в конце сеанса).
final class MonitorTestsReport {
  const MonitorTestsReport({required this.tMs, required this.tests});

  /// Миллисекунды от начала записи.
  final int tMs;
  final List<MonitorTest> tests;

  Map<String, Object?> toJson() => {
    't': tMs,
    'tests': [for (final t in tests) t.toJson()],
  };

  factory MonitorTestsReport.fromJson(Map<String, Object?> json) =>
      MonitorTestsReport(
        tMs: (json['t'] as num? ?? 0).toInt(),
        tests: [
          for (final t in (json['tests'] as List? ?? const []))
            MonitorTest.fromJson((t as Map).cast<String, Object?>()),
        ],
      );

  /// Для журнала: «лямбда-зонд ряд 1 датчик 1 / время переключения богато→бедно
  /// = 68 мс (0…100)».
  List<String> get lines => [
    for (final t in tests)
      '${monitorTitle(t.mid)} / ${testTitle(t.mid, t.tid)} = '
          '${t.scaled == null ? 'сырое ${t.value} (UASID ${t.uasid.toRadixString(16)})' : '${_fmt(t.scaled!)} ${t.unit}'.trim()} '
          '(${t.scaled == null ? '${t.min}…${t.max}' : '${_fmt(t.scaledMin!)}…${_fmt(t.scaledMax!)}'})'
          '${t.noResult
              ? ' нет результата'
              : t.outOfRange
              ? ' вне пределов'
              : ''}',
  ];

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(3);
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
