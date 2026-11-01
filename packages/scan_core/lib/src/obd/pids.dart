import '../hex.dart';

/// Параметр режима 01 (текущие данные) по SAE J1979.
final class Pid {
  Pid(
    this.code,
    this.key,
    this.name,
    this.unit,
    this.byteCount,
    this._formula, {
    required this.min,
    required this.max,
    this.decimals = 0,
  });

  final int code;

  /// Стабильный ключ для хранения, экспорта и ИИ: 'rpm', 'ltft1'.
  final String key;
  final String name;
  final String unit;
  final int byteCount;
  final double Function(List<int> b) _formula;

  /// Типичный диапазон — для оси графика, не для оценки «норма / не норма».
  final double min;
  final double max;
  final int decimals;

  String get command => '01${hexByte(code)}';

  double? decode(List<int> data) =>
      data.length < byteCount ? null : _formula(data);
}

double _a(List<int> b) => b[0].toDouble();
double _ab(List<int> b) => (b[0] * 256 + b[1]).toDouble();
double _percent(List<int> b) => b[0] * 100 / 255;
double _temp(List<int> b) => b[0] - 40.0;
double _trim(List<int> b) => b[0] * 100 / 128 - 100;
double _o2(List<int> b) => b[0] / 200;

/// PID, которые приложение умеет читать. Порядок — порядок плиток на экране.
final List<Pid> standardPids = [
  Pid(
    0x0C,
    'rpm',
    'Обороты',
    'об/мин',
    2,
    (b) => _ab(b) / 4,
    min: 0,
    max: 7000,
  ),
  Pid(0x0D, 'speed', 'Скорость', 'км/ч', 1, _a, min: 0, max: 200),
  Pid(0x05, 'coolant', 'Температура ОЖ', '°C', 1, _temp, min: -40, max: 130),
  Pid(0x04, 'load', 'Нагрузка', '%', 1, _percent, min: 0, max: 100),
  Pid(0x11, 'throttle', 'Дроссель', '%', 1, _percent, min: 0, max: 100),
  Pid(
    0x10,
    'maf',
    'Расход воздуха',
    'г/с',
    2,
    (b) => _ab(b) / 100,
    min: 0,
    max: 200,
    decimals: 1,
  ),
  Pid(0x0B, 'map', 'Давление во впуске', 'кПа', 1, _a, min: 0, max: 255),
  Pid(
    0x06,
    'stft1',
    'Краткоср. коррекция, ряд 1',
    '%',
    1,
    _trim,
    min: -25,
    max: 25,
    decimals: 1,
  ),
  Pid(
    0x07,
    'ltft1',
    'Долгоср. коррекция, ряд 1',
    '%',
    1,
    _trim,
    min: -25,
    max: 25,
    decimals: 1,
  ),
  Pid(
    0x08,
    'stft2',
    'Краткоср. коррекция, ряд 2',
    '%',
    1,
    _trim,
    min: -25,
    max: 25,
    decimals: 1,
  ),
  Pid(
    0x09,
    'ltft2',
    'Долгоср. коррекция, ряд 2',
    '%',
    1,
    _trim,
    min: -25,
    max: 25,
    decimals: 1,
  ),
  Pid(
    0x14,
    'o2_b1s1',
    'Лямбда до катализатора',
    'В',
    2,
    _o2,
    min: 0,
    max: 1.1,
    decimals: 2,
  ),
  Pid(
    0x15,
    'o2_b1s2',
    'Лямбда после катализатора',
    'В',
    2,
    _o2,
    min: 0,
    max: 1.1,
    decimals: 2,
  ),
  Pid(
    0x0E,
    'timing',
    'Угол опережения',
    '°',
    1,
    (b) => b[0] / 2 - 64,
    min: -20,
    max: 60,
    decimals: 1,
  ),
  Pid(0x0F, 'iat', 'Температура на впуске', '°C', 1, _temp, min: -40, max: 80),
  Pid(
    0x42,
    'voltage',
    'Напряжение ЭБУ',
    'В',
    2,
    (b) => _ab(b) / 1000,
    min: 10,
    max: 16,
    decimals: 2,
  ),
  Pid(0x5C, 'oil', 'Температура масла', '°C', 1, _temp, min: -40, max: 150),
  Pid(0x2F, 'fuel', 'Уровень топлива', '%', 1, _percent, min: 0, max: 100),
  Pid(0x33, 'baro', 'Атмосферное давление', 'кПа', 1, _a, min: 70, max: 110),
  Pid(
    0x46,
    'ambient',
    'Температура снаружи',
    '°C',
    1,
    _temp,
    min: -40,
    max: 50,
  ),
  Pid(0x1F, 'runtime', 'С момента запуска', 'с', 2, _ab, min: 0, max: 3600),
];

final Map<String, Pid> pidsByKey = {for (final p in standardPids) p.key: p};
final Map<int, Pid> pidsByCode = {for (final p in standardPids) p.code: p};

/// Ответ на 0100 / 0120 / 0140…: 4 байта, старший бит — PID base+1,
/// младший — «есть следующая группа».
Set<int> decodeSupportedPids(int base, List<int> data) => {
  for (var i = 0; i < 32; i++)
    if (data.length > i ~/ 8 && data[i ~/ 8] & (0x80 >> (i % 8)) != 0)
      base + i + 1,
};

List<int> encodeSupportedPids(int base, Set<int> supported) {
  final out = List<int>.filled(4, 0);
  for (final pid in supported) {
    final i = pid - base - 1;
    if (i < 0 || i >= 32) continue;
    out[i ~/ 8] |= 0x80 >> (i % 8);
  }
  return out;
}
