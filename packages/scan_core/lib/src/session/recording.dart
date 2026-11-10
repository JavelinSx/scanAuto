/// Профиль машины. VIN хранится только на телефоне — в ИИ уходит [forModel].
final class VehicleInfo {
  const VehicleInfo({
    this.title,
    this.vin,
    this.make,
    this.model,
    this.engine,
    this.year,
    this.mileageKm,
    this.transmission,
    this.lpg = false,
    this.catalystRemoved = false,
    this.notes,
  });

  /// Свободное описание, если профиль не заполнен по полям.
  final String? title;
  final String? vin;
  final String? make;
  final String? model;

  /// «1.6 8 кл. ВАЗ-11186, 87 л.с.».
  final String? engine;
  final int? year;
  final int? mileageKm;

  /// «механика», «робот», «автомат».
  final String? transmission;

  /// ГБО и удалённый катализатор меняют картину коррекций и лямбд —
  /// без этих отметок модель примет норму за неисправность.
  final bool lpg;
  final bool catalystRemoved;

  /// Что владелец знает сам: «меняли датчик кислорода», «чип-тюнинг».
  final String? notes;

  String get displayName =>
      [make, model, engine].nonNulls.join(' ').trim().isNotEmpty
      ? [make, model, engine].nonNulls.join(' ')
      : title ?? 'Машина';

  /// То, что уходит в модель: всё, кроме VIN.
  Map<String, Object?> forModel() => {
    if (title != null) 'description': title,
    'make': ?make,
    'model': ?model,
    'engine': ?engine,
    'year': ?year,
    'mileage_km': ?mileageKm,
    'transmission': ?transmission,
    if (lpg)
      'lpg': 'установлено ГБО; запись сделана на бензине, если не указано иное',
    if (catalystRemoved)
      'catalyst': 'катализатор удалён (пламегаситель, прошивка)',
    'owner_notes': ?notes,
  };

  Map<String, Object?> toJson() => {
    'title': title,
    'vin': vin,
    'make': make,
    'model': model,
    'engine': engine,
    'year': year,
    'mileageKm': mileageKm,
    'transmission': transmission,
    'lpg': lpg,
    'catalystRemoved': catalystRemoved,
    'notes': notes,
  };

  factory VehicleInfo.fromJson(Map<String, Object?> json) => VehicleInfo(
    title: json['title'] as String?,
    vin: json['vin'] as String?,
    make: json['make'] as String?,
    model: json['model'] as String?,
    engine: json['engine'] as String?,
    year: (json['year'] as num?)?.toInt(),
    mileageKm: (json['mileageKm'] as num?)?.toInt(),
    transmission: json['transmission'] as String?,
    lpg: json['lpg'] as bool? ?? false,
    catalystRemoved: json['catalystRemoved'] as bool? ?? false,
    notes: json['notes'] as String?,
  );

  VehicleInfo withVin(String? vin) => VehicleInfo(
    title: title,
    vin: vin,
    make: make,
    model: model,
    engine: engine,
    year: year,
    mileageKm: mileageKm,
    transmission: transmission,
    lpg: lpg,
    catalystRemoved: catalystRemoved,
    notes: notes,
  );
}

/// Отрезок записи — этап программы диагностики.
final class RecordingSegment {
  const RecordingSegment({
    required this.key,
    required this.title,
    required this.startMs,
    required this.endMs,
    required this.completed,
    this.note,
  });

  /// 'warmup', 'city', 'highway'.
  final String key;
  final String title;
  final int startMs;
  final int endMs;

  /// Цель этапа достигнута: прогрелся, проехал нужное время.
  final bool completed;
  final String? note;

  bool contains(int tMs) => tMs >= startMs && tMs <= endMs;

  Map<String, Object?> toJson() => {
    'key': key,
    'title': title,
    'startMs': startMs,
    'endMs': endMs,
    'completed': completed,
    'note': note,
  };

  factory RecordingSegment.fromJson(Map<String, Object?> json) =>
      RecordingSegment(
        key: json['key']! as String,
        title: json['title']! as String,
        startMs: (json['startMs']! as num).toInt(),
        endMs: (json['endMs']! as num).toInt(),
        completed: json['completed']! as bool,
        note: json['note'] as String?,
      );
}

/// Ряд значений одного PID. Время — миллисекунды от начала записи.
final class Series {
  Series(this.key);

  final String key;
  final List<int> tMs = [];
  final List<double> values = [];

  int get length => values.length;
  bool get isEmpty => values.isEmpty;
  bool get isNotEmpty => values.isNotEmpty;

  /// Индекс первого замера не раньше [t]; [length], если таких нет.
  int lowerBound(int t) {
    var lo = 0;
    var hi = length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (tMs[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Значение ближайшего по времени замера: PID опрашиваются по очереди,
  /// моменты замеров разных параметров не совпадают.
  double valueNear(int t) {
    final i = lowerBound(t);
    if (i == length) return values.last;
    if (i > 0 && t - tMs[i - 1] < tMs[i] - t) return values[i - 1];
    return values[i];
  }

  void trimBefore(int t) {
    final i = lowerBound(t);
    if (i == 0) return;
    tMs.removeRange(0, i);
    values.removeRange(0, i);
  }
}

/// Сырые ответы на запрос производителя (например, `21 01` блока ВАЗ): что значат
/// байты, ещё не известно — их сопоставляют с обычными PID по записям.
final class RawSeries {
  RawSeries(this.command);

  final String command;
  final List<int> tMs = [];
  final List<String> hex = [];
}

/// Запись: временные ряды по PID и коды, прочитанные за сеанс.
/// Формат JSON (format/version) — это и файл экспорта для MCP-сервера.
final class Recording {
  Recording({required this.startedAt, this.vehicle});

  static const format = 'scanauto.recording';
  static const version = 1;

  final DateTime startedAt;
  VehicleInfo? vehicle;
  final Map<String, Series> series = {};

  /// Сырые ответы на запросы производителя, по команде. В пакет для ИИ не идут.
  final Map<String, RawSeries> raw = {};

  void addRaw(String command, DateTime at, String hex) {
    final s = raw.putIfAbsent(command, () => RawSeries(command));
    s.tMs.add(at.difference(startedAt).inMilliseconds);
    s.hex.add(hex);
  }

  List<String> dtcs = [];
  List<String> pendingDtcs = [];

  /// Заполняются программой диагностики; у обычной записи пусты.
  String? season;
  final List<RecordingSegment> segments = [];

  void add(String key, DateTime at, double value) {
    final s = series.putIfAbsent(key, () => Series(key));
    s.tMs.add(at.difference(startedAt).inMilliseconds);
    s.values.add(value);
  }

  Duration get duration {
    var maxMs = 0;
    for (final s in series.values) {
      if (s.tMs.isNotEmpty && s.tMs.last > maxMs) maxMs = s.tMs.last;
    }
    return Duration(milliseconds: maxMs);
  }

  /// Самый ранний замер, который ещё хранится: после [keepLast] — не начало записи.
  Duration get coveredFrom {
    int? minMs;
    for (final s in series.values) {
      if (s.isNotEmpty && (minMs == null || s.tMs.first < minMs)) {
        minMs = s.tMs.first;
      }
    }
    return Duration(milliseconds: minMs ?? 0);
  }

  /// Хранить только последние [window]. Срезает с запасом [slack], чтобы не сдвигать
  /// списки на каждом замере. Живой буфер, пока записи не хранятся в базе (этап 2).
  void keepLast(
    Duration window, {
    Duration slack = const Duration(minutes: 5),
  }) {
    final from = duration - window;
    if (coveredFrom >= from - slack) return;
    for (final s in series.values) {
      s.trimBefore(from.inMilliseconds);
    }
  }

  Map<String, Object?> toJson() => {
    'format': format,
    'version': version,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'vehicle': vehicle?.toJson(),
    'dtcs': dtcs,
    'pendingDtcs': pendingDtcs,
    'season': season,
    'segments': [for (final s in segments) s.toJson()],
    'series': {
      for (final s in series.values) s.key: {'t': s.tMs, 'v': s.values},
    },
    if (raw.isNotEmpty)
      'raw': {
        for (final r in raw.values) r.command: {'t': r.tMs, 'hex': r.hex},
      },
  };

  factory Recording.fromJson(Map<String, Object?> json) {
    if (json['format'] != format) {
      throw FormatException('Это не запись scanAuto', json['format']);
    }
    final vehicle = json['vehicle'];
    final rec = Recording(
      startedAt: DateTime.parse(json['startedAt']! as String),
      vehicle: vehicle == null
          ? null
          : VehicleInfo.fromJson((vehicle as Map).cast<String, Object?>()),
    );
    rec.dtcs = [...(json['dtcs'] as List? ?? const []).cast<String>()];
    rec.pendingDtcs = [
      ...(json['pendingDtcs'] as List? ?? const []).cast<String>(),
    ];
    rec.season = json['season'] as String?;
    rec.segments.addAll([
      for (final s in (json['segments'] as List? ?? const []))
        RecordingSegment.fromJson((s as Map).cast<String, Object?>()),
    ]);
    for (final MapEntry(:key, :value)
        in ((json['raw'] as Map?) ?? const {})
            .cast<String, Object?>()
            .entries) {
      final m = (value! as Map).cast<String, Object?>();
      final r = rec.raw[key] = RawSeries(key);
      r.tMs.addAll((m['t']! as List).cast<num>().map((e) => e.toInt()));
      r.hex.addAll((m['hex']! as List).cast<String>());
    }
    final series = (json['series']! as Map).cast<String, Object?>();
    for (final MapEntry(:key, :value) in series.entries) {
      final m = (value! as Map).cast<String, Object?>();
      final s = rec.series[key] = Series(key);
      s.tMs.addAll((m['t']! as List).cast<num>().map((e) => e.toInt()));
      s.values.addAll((m['v']! as List).cast<num>().map((e) => e.toDouble()));
    }
    return rec;
  }
}
