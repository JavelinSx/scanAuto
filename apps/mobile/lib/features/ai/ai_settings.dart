import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:scan_core/scan_core.dart';

/// Выбранный провайдер и ключ пользователя (BYOK).
final class AiSettings {
  const AiSettings({
    required this.protocol,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
  });

  factory AiSettings.fromPreset(AiPreset p, {String apiKey = ''}) => AiSettings(
    protocol: p.protocol,
    baseUrl: p.baseUrl,
    model: p.model,
    apiKey: apiKey,
  );

  final AiProtocol protocol;
  final String baseUrl;
  final String model;
  final String apiKey;

  AiProviderConfig toConfig() => AiProviderConfig(
    protocol: protocol,
    baseUrl: baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
    model: model.trim(),
    apiKey: apiKey.trim(),
  );

  Map<String, Object?> _toJson() => {
    'protocol': protocol.name,
    'baseUrl': baseUrl,
    'model': model,
  };

  static AiSettings _fromJson(Map<String, Object?> json, String apiKey) =>
      AiSettings(
        protocol: AiProtocol.values.byName(json['protocol']! as String),
        baseUrl: json['baseUrl']! as String,
        model: json['model']! as String,
        apiKey: apiKey,
      );
}

abstract interface class AiSettingsStore {
  Future<AiSettings?> load();
  Future<void> save(AiSettings settings);
}

/// Настройки и ключ — в Android Keystore. Ключ не попадает ни в логи, ни в экспорт.
final class SecureAiSettingsStore implements AiSettingsStore {
  const SecureAiSettingsStore();

  static const _storage = FlutterSecureStorage();
  static const _settingsKey = 'ai.settings';
  static const _apiKey = 'ai.key';

  @override
  Future<AiSettings?> load() async {
    try {
      final raw = await _storage.read(key: _settingsKey);
      if (raw == null) return null;
      final key = await _storage.read(key: _apiKey) ?? '';
      return AiSettings._fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
        key,
      );
    } on Object {
      // Повреждённые или недоступные настройки — начинаем с пресета.
      return null;
    }
  }

  @override
  Future<void> save(AiSettings settings) async {
    await _storage.write(
      key: _settingsKey,
      value: jsonEncode(settings._toJson()),
    );
    await _storage.write(key: _apiKey, value: settings.apiKey);
  }
}

final aiSettingsStoreProvider = Provider<AiSettingsStore>(
  (ref) => const SecureAiSettingsStore(),
);

/// Подменяется в тестах, чтобы не ходить в сеть.
final aiClientFactoryProvider = Provider<AiClient Function(AiProviderConfig)>(
  (ref) => AiClient.new,
);
