import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../features/live/scan_controller.dart';

/// Последний адаптер, к которому удалось подключиться, — чтобы в машине
/// подключаться одной кнопкой. Симулятор не запоминается.
abstract interface class AdapterStore {
  Future<AdapterTarget?> loadLast();
  Future<void> saveLast(AdapterTarget target);
}

final class SecureAdapterStore implements AdapterStore {
  const SecureAdapterStore();

  static const _storage = FlutterSecureStorage();
  static const _key = 'adapter.last';

  @override
  Future<AdapterTarget?> loadLast() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return null;
      return switch ((jsonDecode(raw) as Map).cast<String, Object?>()) {
        {'type': 'bt', 'address': final String a, 'name': final String n} =>
          BluetoothTarget(a, n),
        {'type': 'wifi', 'host': final String h, 'port': final int p} =>
          WifiTarget(h, p),
        _ => null,
      };
    } on Object {
      return null;
    }
  }

  @override
  Future<void> saveLast(AdapterTarget target) async {
    final json = switch (target) {
      BluetoothTarget(:final address, :final name) => {
        'type': 'bt',
        'address': address,
        'name': name,
      },
      WifiTarget(:final host, :final port) => {
        'type': 'wifi',
        'host': host,
        'port': port,
      },
      SimulatorTarget() => null,
    };
    if (json == null) return;
    try {
      await _storage.write(key: _key, value: jsonEncode(json));
    } on Object {
      // Не запомнили — подключатся через выбор, это не повод ронять сеанс.
    }
  }
}

final adapterStoreProvider = Provider<AdapterStore>(
  (ref) => const SecureAdapterStore(),
);

final lastAdapterProvider = FutureProvider<AdapterTarget?>(
  (ref) => ref.watch(adapterStoreProvider).loadLast(),
);
