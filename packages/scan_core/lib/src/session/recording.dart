/// Машина, как её описал владелец. VIN хранится только на телефоне: в ИИ уходит [title].
final class VehicleInfo {
  const VehicleInfo({this.title, this.vin});

  /// «Lada Vesta 1.6 2019, механика» — марка, двигатель, год своими словами.
  final String? title;
  final String? vin;

  Map<String, Object?> toJson() => {'title': title, 'vin': vin};

  factory VehicleInfo.fromJson(Map<String, Object?> json) =>
      VehicleInfo(title: json['title'] as String?, vin: json['vin'] as String?);
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

/// Запись: временные ряды по PID и коды, прочитанные за сеанс.
/// Формат JSON (format/version) — это и файл экспорта для MCP-сервера.
final class Recording {
  Recording({required this.startedAt, this.vehicle});

  static const format = 'scanauto.recording';
  static const version = 1;

  final DateTime startedAt;
  VehicleInfo? vehicle;
  final Map<String, Series> series = {};
  List<String> dtcs = [];
  List<String> pendingDtcs = [];

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
    'series': {
      for (final s in series.values) s.key: {'t': s.tMs, 'v': s.values},
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
