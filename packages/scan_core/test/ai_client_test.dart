import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:scan_core/scan_core.dart';
import 'package:test/test.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.status, this.body);

  final int status;
  final Object body;
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

(AiClient, _FakeAdapter) _client(
  AiProviderConfig config,
  int status,
  Object body,
) {
  final adapter = _FakeAdapter(status, body);
  return (AiClient(config, dio: Dio()..httpClientAdapter = adapter), adapter);
}

const _anthropic = AiProviderConfig(
  protocol: AiProtocol.anthropic,
  baseUrl: 'https://api.anthropic.com',
  model: 'claude-opus-5-5',
  apiKey: 'test-key',
);

const _openAi = AiProviderConfig(
  protocol: AiProtocol.openAiCompatible,
  baseUrl: 'https://llm.api.cloud.yandex.net/v1',
  model: 'gpt://folder/yandexgpt/latest',
  apiKey: 'test-key',
);

void main() {
  test('Anthropic: запрос, заголовки, разбор ответа', () async {
    final (client, adapter) = _client(_anthropic, 200, {
      'model': 'claude-opus-5-5',
      'stop_reason': 'end_turn',
      'content': [
        {'type': 'thinking', 'thinking': ''},
        {'type': 'text', 'text': 'Подсос воздуха.'},
      ],
      'usage': {'input_tokens': 1200, 'output_tokens': 300},
    });
    final reply = await client.complete(system: 'S', user: 'U');

    final request = adapter.request!;
    expect(request.uri.toString(), 'https://api.anthropic.com/v1/messages');
    expect(request.headers['x-api-key'], 'test-key');
    expect(request.headers['anthropic-version'], '2026-10-21');
    expect(
      request.headers['anthropic-beta'],
      'server-side-fallback-2026-07-01',
    );
    final body = request.data as Map<String, Object?>;
    expect(body['system'], 'S');
    expect(body['fallbacks'], 'default');
    expect(body['output_config'], {'effort': 'high'});
    expect(body, isNot(contains('temperature')));
    expect(body['messages'], [
      {'role': 'user', 'content': 'U'},
    ]);

    expect(reply.text, 'Подсос воздуха.');
    expect(reply.inputTokens, 1200);
    expect(reply.truncated, isFalse);
  });

  test('Anthropic: effort и фолбэк — только моделям, которые их принимают', () {
    for (final model in [
      'claude-opus-5-5',
      'claude-sonnet-5-5',
      'claude-haiku-5-5',
      'claude-fable-5-1',
      'claude-opus-4-8',
      'claude-opus-4-5-20251101',
      'claude-sonnet-4-6',
    ]) {
      expect(AnthropicClient.supportsEffort(model), isTrue, reason: model);
    }
    for (final model in [
      'claude-haiku-4-5',
      'claude-sonnet-4-5',
      'claude-opus-4-1',
      'claude-sonnet-4-20250514',
      'claude-3-5-haiku-latest',
    ]) {
      expect(AnthropicClient.supportsEffort(model), isFalse, reason: model);
    }

    const haiku = AiProviderConfig(
      protocol: AiProtocol.anthropic,
      baseUrl: 'https://api.anthropic.com',
      model: 'claude-haiku-4-5',
      apiKey: 'test-key',
    );
    final client = AnthropicClient(haiku);
    final body = client.buildRequest(system: 'S', user: 'U');
    expect(body, isNot(contains('output_config')));
    expect(body, isNot(contains('fallbacks')));
    expect(client.buildHeaders(), isNot(contains('anthropic-beta')));
  });

  test('Anthropic: refusal — исключение, а не пустой ответ', () async {
    final (client, _) = _client(_anthropic, 200, {
      'stop_reason': 'refusal',
      'stop_details': {'type': 'refusal', 'explanation': 'нет'},
      'content': <Object>[],
    });
    expect(
      client.complete(system: 'S', user: 'U'),
      throwsA(
        isA<AiException>().having((e) => e.kind, 'kind', AiErrorKind.refusal),
      ),
    );
  });

  test('OpenAI-совместимый: путь, Bearer, разбор', () async {
    final (client, adapter) = _client(_openAi, 200, {
      'model': 'yandexgpt/latest',
      'choices': [
        {
          'message': {'role': 'assistant', 'content': 'Ответ'},
          'finish_reason': 'length',
        },
      ],
      'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
    });
    final reply = await client.complete(system: 'S', user: 'U');

    final request = adapter.request!;
    expect(
      request.uri.toString(),
      'https://llm.api.cloud.yandex.net/v1/chat/completions',
    );
    expect(request.headers['Authorization'], 'Bearer test-key');
    expect((request.data as Map)['messages'], hasLength(2));
    expect(reply.text, 'Ответ');
    expect(reply.outputTokens, 5);
    expect(reply.truncated, isTrue);
  });

  test('401 — ошибка авторизации с текстом провайдера', () async {
    final (client, _) = _client(_openAi, 401, {
      'error': {'message': 'Invalid API key'},
    });
    expect(
      client.complete(system: 'S', user: 'U'),
      throwsA(
        isA<AiException>()
            .having((e) => e.kind, 'kind', AiErrorKind.auth)
            .having((e) => e.message, 'message', 'Invalid API key'),
      ),
    );
  });
}
