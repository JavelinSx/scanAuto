import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Направляет сокеты приложения в сеть Wi-Fi адаптера на время сеанса.
/// Без этого при включённых мобильных данных Android шлёт трафик в мобильную сеть,
/// и адаптер по 192.168.0.10 недоступен. Пока привязка действует, интернета через
/// мобильную сеть у приложения нет — запросы к ИИ после [release].
abstract interface class WifiBinding {
  /// true — привязались; false — Wi-Fi нет или Android не дал привязать.
  /// Подключаться к адаптеру можно в любом случае: без мобильных данных это и не нужно.
  Future<bool> bind();
  Future<void> release();
}

final wifiBindingProvider = Provider<WifiBinding>(
  (ref) => const MethodChannelWifiBinding(),
);

final class MethodChannelWifiBinding implements WifiBinding {
  const MethodChannelWifiBinding();

  static const _channel = MethodChannel('ru.scanauto/wifi');

  /// Wi-Fi без интернета Android может объявить не сразу; дольше не ждём.
  static const _timeout = Duration(seconds: 5);

  @override
  Future<bool> bind() async {
    try {
      return await _channel.invokeMethod<bool>('bind').timeout(_timeout) ??
          false;
    } on Exception {
      // Тайм-аут, нет реализации на платформе: снимаем запрос сети и идём без привязки.
      await release();
      return false;
    }
  }

  @override
  Future<void> release() async {
    try {
      await _channel.invokeMethod<void>('release');
    } on Exception {
      // Нечего снимать.
    }
  }
}
