import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scan_core/scan_core.dart';

/// Спаренное устройство из настроек Android.
final class BtDevice {
  const BtDevice(this.name, this.address);

  final String name;
  final String address;

  /// Клоны называются «OBDII», «OBD2», «ELM327», «V-LINK» — их показываем первыми.
  bool get looksLikeObd => RegExp(
    r'obd|elm|v-?link|vgate|icar|konnwei|scan',
    caseSensitive: false,
  ).hasMatch(name);
}

class BluetoothException implements Exception {
  BluetoothException(this.code, this.message);

  /// 'bluetooth_off', 'no_bluetooth', 'permission_denied', 'connect_failed'.
  final String code;
  final String message;

  @override
  String toString() => 'BluetoothException($code): $message';
}

/// Bluetooth Classic до ELM327 — модуль `BluetoothSpp` в Kotlin.
abstract interface class BluetoothClassic {
  /// Android 12+ спрашивает разрешение на подключение; false — пользователь отказал.
  Future<bool> ensurePermission();
  Future<List<BtDevice>> bondedDevices();

  /// Открывает SPP-сокет. Способ, который сработал, — в [BluetoothTransport.method].
  Future<ObdTransport> connect(String address);
  Future<void> openSettings();
}

final bluetoothProvider = Provider<BluetoothClassic>(
  (ref) => const MethodChannelBluetooth(),
);

final class MethodChannelBluetooth implements BluetoothClassic {
  const MethodChannelBluetooth();

  static const _method = MethodChannel('ru.scanauto/bt');
  static const _input = EventChannel('ru.scanauto/bt/input');

  static BluetoothException _wrap(PlatformException e) =>
      BluetoothException(e.code, e.message ?? e.code);

  @override
  Future<bool> ensurePermission() async {
    try {
      return await _method.invokeMethod<bool>('ensurePermission') ?? false;
    } on PlatformException catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<List<BtDevice>> bondedDevices() async {
    try {
      final list = await _method.invokeListMethod<Map<Object?, Object?>>(
        'bondedDevices',
      );
      return [
        for (final d in list ?? const <Map<Object?, Object?>>[])
          BtDevice(d['name']! as String, d['address']! as String),
      ];
    } on PlatformException catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<ObdTransport> connect(String address) async {
    if (!await ensurePermission()) {
      throw BluetoothException(
        'permission_denied',
        'Нет разрешения на Bluetooth',
      );
    }
    // Слушаем вход до подключения, чтобы не потерять первые байты.
    final transport = BluetoothTransport._(_input.receiveBroadcastStream());
    try {
      transport.method = await _method.invokeMethod<String>('connect', {
        'address': address,
      });
      return transport;
    } on PlatformException catch (e) {
      await transport._closeInput();
      throw _wrap(e);
    }
  }

  @override
  Future<void> openSettings() => _method.invokeMethod<void>('openSettings');
}

/// Байты адаптера из EventChannel. Обрыв (ошибка `disconnected`) закрывает поток —
/// [Elm327] увидит это как отключение.
final class BluetoothTransport implements ObdTransport {
  BluetoothTransport._(Stream<Object?> events) {
    _sub = events.listen(
      (data) {
        if (data is Uint8List && !_input.isClosed) _input.add(data);
      },
      onError: (Object e) {
        disconnectReason = e is PlatformException ? e.message : '$e';
        _closeInput();
      },
      onDone: _closeInput,
    );
  }

  static const _method = MethodChannel('ru.scanauto/bt');

  final _input = StreamController<List<int>>();
  late final StreamSubscription<Object?> _sub;

  /// Какой сокет открылся: 'secure', 'insecure', 'channel1' — для лога.
  String? method;

  /// Что сообщил Android при обрыве — для лога.
  String? disconnectReason;

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  Future<void> write(List<int> bytes) async {
    try {
      await _method.invokeMethod<void>('write', {
        'bytes': Uint8List.fromList(bytes),
      });
    } on PlatformException catch (e) {
      throw BluetoothException(e.code, e.message ?? e.code);
    }
  }

  Future<void> _closeInput() async {
    await _sub.cancel();
    if (!_input.isClosed) await _input.close();
  }

  @override
  Future<void> close() async {
    await _closeInput();
    await _method.invokeMethod<void>('disconnect');
  }
}
