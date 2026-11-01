import 'package:dio/dio.dart';

/// Два протокола покрывают почти всех: OpenAI-совместимый Chat Completions
/// (OpenAI, YandexGPT, DeepSeek, OpenRouter, локальные Ollama и LM Studio)
/// и родной Anthropic Messages API.
enum AiProtocol { openAiCompatible, anthropic }

/// Куда и с каким ключом ходить. Ключ — пользователя (BYOK), хранится на телефоне.
final class AiProviderConfig {
  const AiProviderConfig({
    required this.protocol,
    required this.baseUrl,
    required this.model,
    this.apiKey = '',
    this.extraHeaders = const {},
  });

  final AiProtocol protocol;

  /// Без завершающего «/»: 'https://api.openai.com/v1', 'https://api.anthropic.com'.
  final String baseUrl;
  final String model;
  final String apiKey;
  final Map<String, String> extraHeaders;
}

/// Готовые настройки для экрана выбора. [model] пустой там, где имя модели
/// у провайдера часто меняется — пользователь вписывает его сам.
final class AiPreset {
  const AiPreset(
    this.title,
    this.protocol,
    this.baseUrl,
    this.model,
    this.hint,
  );

  final String title;
  final AiProtocol protocol;
  final String baseUrl;
  final String model;
  final String hint;
}

const aiPresets = [
  AiPreset(
    'Claude (Anthropic)',
    AiProtocol.anthropic,
    'https://api.anthropic.com',
    'claude-opus-5-5',
    'Ключ из platform.claude.com. Из России API недоступен.',
  ),
  AiPreset(
    'YandexGPT',
    AiProtocol.openAiCompatible,
    'https://llm.api.cloud.yandex.net/v1',
    'gpt://<ID каталога>/yandexgpt/latest',
    'API-ключ сервисного аккаунта с ролью ai.languageModels.user.',
  ),
  AiPreset(
    'OpenAI',
    AiProtocol.openAiCompatible,
    'https://api.openai.com/v1',
    '',
    'Ключ из platform.openai.com.',
  ),
  AiPreset(
    'DeepSeek',
    AiProtocol.openAiCompatible,
    'https://api.deepseek.com/v1',
    'deepseek-chat',
    'Ключ из platform.deepseek.com.',
  ),
  AiPreset(
    'OpenRouter',
    AiProtocol.openAiCompatible,
    'https://openrouter.ai/api/v1',
    '',
    'Один ключ — сотни моделей разных компаний.',
  ),
  AiPreset(
    'Ollama / LM Studio',
    AiProtocol.openAiCompatible,
    'http://192.168.1.2:11434/v1',
    '',
    'Модель на своём компьютере в той же сети. Ключ не нужен.',
  ),
];

final class AiReply {
  const AiReply({
    required this.text,
    required this.model,
    this.inputTokens,
    this.outputTokens,
    this.truncated = false,
  });

  final String text;
  final String model;
  final int? inputTokens;
  final int? outputTokens;

  /// Ответ упёрся в лимит токенов.
  final bool truncated;
}

enum AiErrorKind { auth, rateLimit, refusal, server, network, badResponse }

class AiException implements Exception {
  AiException(this.kind, this.message, {this.statusCode});

  final AiErrorKind kind;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'AiException(${kind.name}, $statusCode): $message';
}

/// Клиент модели. Один запрос — один ответ: история диалога и потоковая выдача — этап 4.
sealed class AiClient {
  AiClient._(this.config, Dio? dio)
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              // Модели с рассуждением думают над разбором минуту и больше.
              receiveTimeout: const Duration(minutes: 5),
            ),
          );

  factory AiClient(AiProviderConfig config, {Dio? dio}) =>
      switch (config.protocol) {
        AiProtocol.openAiCompatible => OpenAiCompatibleClient(config, dio: dio),
        AiProtocol.anthropic => AnthropicClient(config, dio: dio),
      };

  final AiProviderConfig config;
  final Dio _dio;

  Map<String, Object?> buildRequest({
    required String system,
    required String user,
  });
  Map<String, String> buildHeaders();
  String get path;
  AiReply parseResponse(Map<String, Object?> body);

  Future<AiReply> complete({
    required String system,
    required String user,
  }) async {
    final Response<Map<String, Object?>> response;
    try {
      response = await _dio.post<Map<String, Object?>>(
        '${config.baseUrl}$path',
        data: buildRequest(system: system, user: user),
        options: Options(
          headers: {...buildHeaders(), ...config.extraHeaders},
          contentType: Headers.jsonContentType,
          responseType: ResponseType.json,
        ),
      );
    } on DioException catch (e) {
      throw _mapError(e);
    }
    final body = response.data;
    if (body == null) {
      throw AiException(AiErrorKind.badResponse, 'Пустой ответ');
    }
    return parseResponse(body);
  }

  static AiException _mapError(DioException e) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    // И OpenAI-совместимые, и Anthropic отдают {"error": {"message": "..."}}.
    final message = switch (data) {
      {'error': {'message': final String m}} => m,
      {'message': final String m} => m,
      _ => e.message ?? e.type.name,
    };
    final kind = switch (status) {
      null => AiErrorKind.network,
      401 || 403 => AiErrorKind.auth,
      429 => AiErrorKind.rateLimit,
      >= 500 => AiErrorKind.server,
      _ => AiErrorKind.badResponse,
    };
    return AiException(kind, message, statusCode: status);
  }
}

final class OpenAiCompatibleClient extends AiClient {
  OpenAiCompatibleClient(AiProviderConfig config, {Dio? dio})
    : super._(config, dio);

  @override
  String get path => '/chat/completions';

  // Лимит токенов не задаём: новые модели OpenAI не принимают max_tokens,
  // а max_completion_tokens не знают остальные. Серверный лимит по умолчанию хватает.
  @override
  Map<String, Object?> buildRequest({
    required String system,
    required String user,
  }) => {
    'model': config.model,
    'messages': [
      {'role': 'system', 'content': system},
      {'role': 'user', 'content': user},
    ],
  };

  @override
  Map<String, String> buildHeaders() => {
    if (config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}',
  };

  @override
  AiReply parseResponse(Map<String, Object?> body) {
    final choice = switch (body['choices']) {
      [final Map<String, Object?> first, ...] => first,
      _ => throw AiException(AiErrorKind.badResponse, 'В ответе нет choices'),
    };
    final message = choice['message'] as Map<String, Object?>?;
    final text = message?['content'] as String? ?? '';
    final finish = choice['finish_reason'] as String?;
    if (finish == 'content_filter') {
      throw AiException(
        AiErrorKind.refusal,
        'Провайдер отклонил запрос фильтром',
      );
    }
    final usage = body['usage'] as Map<String, Object?>?;
    return AiReply(
      text: text,
      model: body['model'] as String? ?? config.model,
      inputTokens: (usage?['prompt_tokens'] as num?)?.toInt(),
      outputTokens: (usage?['completion_tokens'] as num?)?.toInt(),
      truncated: finish == 'length',
    );
  }
}

/// Anthropic Messages API. Сырые HTTP-запросы: официального SDK для Dart нет.
final class AnthropicClient extends AiClient {
  AnthropicClient(AiProviderConfig config, {Dio? dio, this.effort = 'high'})
    : super._(config, dio);

  static const apiVersion = '2026-10-21';

  /// Модели, у которых при отказе классификатора безопасности сервер сам повторяет
  /// запрос на подходящей модели (`fallbacks: "default"`).
  static const _serverFallbackModels = {
    'claude-fable-5-1',
    'claude-opus-5-5',
    'claude-opus-5',
    'claude-sonnet-5-5',
  };

  /// Модели, которые принимают `output_config.effort`. Haiku 4.5, Sonnet 4.5 и более
  /// старые отвечают на него ошибкой 400; поколения с пятого — принимают.
  static final _effortModels = RegExp(
    r'^claude-(fable|mythos)-'
    r'|^claude-(opus|sonnet|haiku)-([5-9]|\d{2,})'
    r'|^claude-opus-4-[5-9]'
    r'|^claude-sonnet-4-[6-9]',
  );

  static bool supportsEffort(String model) => _effortModels.hasMatch(model);

  /// Глубина рассуждения: разбор данных — задача на внимательность, поэтому high.
  /// Отправляется только моделям из [supportsEffort]; null — не отправлять никогда.
  final String? effort;

  String? get _effort =>
      effort != null && supportsEffort(config.model) ? effort : null;

  bool get _serverFallback => _serverFallbackModels.contains(config.model);

  @override
  String get path => '/v1/messages';

  // temperature/top_p/top_k не отправляем: на версии API 2026-10-21 это ошибка 400.
  @override
  Map<String, Object?> buildRequest({
    required String system,
    required String user,
  }) => {
    'model': config.model,
    'max_tokens': 16000,
    'system': system,
    'messages': [
      {'role': 'user', 'content': user},
    ],
    if (_effort case final effort?) 'output_config': {'effort': effort},
    if (_serverFallback) 'fallbacks': 'default',
  };

  @override
  Map<String, String> buildHeaders() => {
    'x-api-key': config.apiKey,
    'anthropic-version': apiVersion,
    if (_serverFallback) 'anthropic-beta': 'server-side-fallback-2026-07-01',
  };

  @override
  AiReply parseResponse(Map<String, Object?> body) {
    final stop = body['stop_reason'] as String?;
    if (stop == 'refusal') {
      final details = body['stop_details'] as Map<String, Object?>?;
      throw AiException(
        AiErrorKind.refusal,
        details?['explanation'] as String? ?? 'Модель отказалась отвечать',
      );
    }
    // Кроме text бывают блоки thinking — их пропускаем.
    final text = [
      for (final block
          in (body['content'] as List? ?? const [])
              .cast<Map<String, Object?>>())
        if (block['type'] == 'text') block['text'] as String,
    ].join();
    final usage = body['usage'] as Map<String, Object?>?;
    return AiReply(
      text: text,
      model: body['model'] as String? ?? config.model,
      inputTokens: (usage?['input_tokens'] as num?)?.toInt(),
      outputTokens: (usage?['output_tokens'] as num?)?.toInt(),
      truncated: stop == 'max_tokens',
    );
  }
}
