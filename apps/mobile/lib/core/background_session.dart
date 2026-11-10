import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Служба переднего плана (`RecordingService.kt`) на время сеанса с адаптером:
/// без неё Android замораживает приложение при выключенном экране, и в записи
/// остаются дыры на минуты. Ошибки глотаются — сеанс без службы лучше, чем никакого.
abstract interface class BackgroundSession {
  /// Повторный вызов обновляет текст уведомления.
  Future<void> start(String text);
  Future<void> stop();
}

final backgroundSessionProvider = Provider<BackgroundSession>(
  (ref) => const MethodChannelBackgroundSession(),
);

final class MethodChannelBackgroundSession implements BackgroundSession {
  const MethodChannelBackgroundSession();

  static const _channel = MethodChannel('ru.scanauto/service');

  @override
  Future<void> start(String text) async {
    try {
      await _channel.invokeMethod<void>('start', {'text': text});
    } on Object {
      // Нет платформы (тесты) или Android не дал запустить службу.
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
