import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Служба переднего плана (`RecordingService.kt`) на время сеанса с адаптером:
/// без неё Android замораживает приложение при выключенном экране, и в записи
/// остаются дыры на минуты. Ошибки глотаются — сеанс без службы лучше, чем никакого.
abstract interface class BackgroundSession {
  /// Повторный вызов обновляет текст уведомления.
  /// Возвращает текст ошибки, если Android не дал запустить службу.
  Future<String?> start(String text);
  Future<void> stop();
  Future<BackgroundStatus?> status();

  /// Системный запрос на снятие ограничений батареи. true — уже сняты.
  Future<bool> requestBatteryExemption();
  Future<void> openAppSettings();
}

/// Состояние службы и телефона — для журнала и подсказки в интерфейсе.
final class BackgroundStatus {
  const BackgroundStatus({
    required this.running,
    required this.notifications,
    required this.batteryExempt,
    required this.manufacturer,
    required this.model,
    required this.release,
    this.error,
  });

  factory BackgroundStatus.fromMap(Map<Object?, Object?> m) => BackgroundStatus(
    running: m['running'] == true,
    error: m['error'] as String?,
    notifications: m['notifications'] == true,
    batteryExempt: m['batteryExempt'] == true,
    manufacturer: m['manufacturer'] as String? ?? '',
    model: m['model'] as String? ?? '',
    release: m['release'] as String? ?? '',
  );

  final bool running;
  final String? error;
  final bool notifications;
  final bool batteryExempt;
  final String manufacturer;
  final String model;
  final String release;

  @override
  String toString() =>
      'служба ${running ? 'работает' : 'не работает'}'
      '${error == null ? '' : ' ($error)'}, '
      'уведомления ${notifications ? 'разрешены' : 'запрещены'}, '
      'ограничение батареи ${batteryExempt ? 'снято' : 'действует'}; '
      '$manufacturer $model, Android $release';
}

/// Подсказка, где ещё снять ограничения: у многих прошивок системного запроса мало.
String? backgroundHint(String manufacturer) {
  final m = manufacturer.toLowerCase();
  if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
    return 'Xiaomi: Настройки → Приложения → scanAuto → «Контроль активности» → '
        '«Нет ограничений», и включите «Автозапуск».';
  }
  if (m.contains('huawei') || m.contains('honor')) {
    return 'Huawei/Honor: Настройки → Батарея → Запуск приложений → scanAuto → '
        'вручную, включите все три переключателя.';
  }
  if (m.contains('samsung')) {
    return 'Samsung: Настройки → Приложения → scanAuto → Батарея → «Без ограничений».';
  }
  if (m.contains('oppo') || m.contains('realme') || m.contains('oneplus')) {
    return 'Настройки → Приложения → scanAuto → Использование батареи → '
        'разрешите работу в фоне.';
  }
  if (m.contains('vivo') || m.contains('iqoo')) {
    return 'Настройки → Батарея → Фоновое энергопотребление → scanAuto → разрешить.';
  }
  return null;
}

final backgroundSessionProvider = Provider<BackgroundSession>(
  (ref) => const MethodChannelBackgroundSession(),
);

/// Для подсказки на экранах; обновляется при возврате в приложение.
final backgroundStatusProvider = FutureProvider<BackgroundStatus?>(
  (ref) => ref.watch(backgroundSessionProvider).status(),
);

final class MethodChannelBackgroundSession implements BackgroundSession {
  const MethodChannelBackgroundSession();

  static const _channel = MethodChannel('ru.scanauto/service');

  @override
  Future<String?> start(String text) async {
    try {
      await _channel.invokeMethod<void>('start', {'text': text});
      return null;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } on Object catch (e) {
      // Нет платформы (тесты).
      return '$e';
    }
  }

  @override
  Future<BackgroundStatus?> status() async {
    try {
      final m = await _channel.invokeMapMethod<Object?, Object?>('status');
      return m == null ? null : BackgroundStatus.fromMap(m);
    } on Object {
      return null;
    }
  }

  @override
  Future<bool> requestBatteryExemption() async {
    try {
      return await _channel.invokeMethod<bool>('requestBatteryExemption') ??
          false;
    } on Object {
      return false;
    }
  }

  @override
  Future<void> openAppSettings() async {
    try {
      await _channel.invokeMethod<void>('openAppSettings');
    } on Object {
      // Нет платформы.
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on Object {
      // См. start.
    }
  }
}
