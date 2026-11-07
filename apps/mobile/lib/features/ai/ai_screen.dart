import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:scan_core/scan_core.dart';

import '../live/scan_controller.dart';
import 'ai_settings.dart';

/// Разбор записи моделью по ключу пользователя.
class AiScreen extends ConsumerStatefulWidget {
  const AiScreen({super.key});

  @override
  ConsumerState<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends ConsumerState<AiScreen> {
  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  final _question = TextEditingController();
  var _protocol = AiProtocol.anthropic;
  var _sending = false;
  AiReply? _reply;
  String? _error;

  @override
  void initState() {
    super.initState();
    _apply(AiSettings.fromPreset(aiPresets.first));
    ref.read(aiSettingsStoreProvider).load().then((saved) {
      if (saved != null && mounted) setState(() => _apply(saved));
    });
  }

  void _apply(AiSettings s) {
    _protocol = s.protocol;
    _baseUrl.text = s.baseUrl;
    _model.text = s.model;
    if (s.apiKey.isNotEmpty) _key.text = s.apiKey;
  }

  @override
  void dispose() {
    for (final c in [_baseUrl, _model, _key, _question]) {
      c.dispose();
    }
    super.dispose();
  }

  String _message(Recording rec) =>
      diagnosisUserMessage(AnalysisPacket.build(rec), question: _question.text);

  Future<void> _send(Recording rec) async {
    final settings = AiSettings(
      protocol: _protocol,
      baseUrl: _baseUrl.text,
      model: _model.text,
      apiKey: _key.text,
    );
    final config = settings.toConfig();
    if (config.model.isEmpty || config.baseUrl.isEmpty) {
      setState(() => _error = 'Укажите адрес и модель.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
      _reply = null;
    });
    try {
      await ref.read(aiSettingsStoreProvider).save(settings);
      final client = ref.read(aiClientFactoryProvider)(config);
      final user = _message(rec);
      final scan = ref.read(scanControllerProvider.notifier)
        ..logAi(
          'запрос: ${config.protocol.name} ${Uri.tryParse(config.baseUrl)?.host}, '
          'модель ${config.model}, ${user.length} символов',
        );
      final reply = await client.complete(
        system: diagnosisSystemPrompt,
        user: user,
      );
      scan.logAi(
        'ответ ${reply.model}: вход ${reply.inputTokens}, выход ${reply.outputTokens}'
        '${reply.truncated ? ', обрезан' : ''}\n${reply.text}',
      );
      if (mounted) setState(() => _reply = reply);
    } on AiException catch (e) {
      ref.read(scanControllerProvider.notifier).logAi('ошибка: $e');
      if (mounted) setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  static String _describe(AiException e) => switch (e.kind) {
    AiErrorKind.auth => 'Ключ не подходит: ${e.message}',
    AiErrorKind.rateLimit => 'Слишком много запросов, попробуйте через минуту.',
    AiErrorKind.refusal => 'Модель отказалась отвечать: ${e.message}',
    AiErrorKind.network =>
      'Нет связи с провайдером. Если телефон ещё в сети Wi-Fi адаптера — '
          'отключитесь от неё.',
    AiErrorKind.server =>
      'Сбой у провайдера (${e.statusCode}), попробуйте позже.',
    AiErrorKind.badResponse => 'Провайдер ответил ошибкой: ${e.message}',
  };

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(scanControllerProvider);
    final rec = scan.recording;
    final text = Theme.of(context).textTheme;
    if (rec == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Разбор ИИ')),
        body: const Center(child: Text('Нет записи для разбора.')),
      );
    }
    final size = _message(rec).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Разбор ИИ'),
        leading: BackButton(onPressed: () => context.go('/program/run')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Провайдер', style: text.titleMedium),
          const SizedBox(height: 8),
          DropdownButtonFormField<AiPreset>(
            decoration: const InputDecoration(labelText: 'Пресет'),
            items: [
              for (final p in aiPresets)
                DropdownMenuItem(value: p, child: Text(p.title)),
            ],
            onChanged: (p) {
              if (p != null) {
                setState(() => _apply(AiSettings.fromPreset(p)));
              }
            },
          ),
          TextField(
            controller: _baseUrl,
            decoration: const InputDecoration(labelText: 'Адрес API'),
            keyboardType: TextInputType.url,
          ),
          TextField(
            controller: _model,
            decoration: const InputDecoration(labelText: 'Модель'),
          ),
          TextField(
            controller: _key,
            decoration: const InputDecoration(labelText: 'Ключ API'),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
          ),
          const SizedBox(height: 8),
          Text(
            'Ключ хранится только на телефоне, в защищённом хранилище.',
            style: text.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _question,
            decoration: const InputDecoration(
              labelText: 'Что беспокоит (необязательно)',
              hintText: 'Например: плавают обороты на холостых',
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Уйдёт выбранному провайдеру: профиль машины без VIN, сезон, '
                'этапы, коды ошибок, статистика и графики параметров — '
                '~${(size / 1000).round()} тыс. символов. '
                'Ответ ИИ — подсказка, не диагноз.',
                style: text.bodySmall,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _sending ? null : () => _send(rec),
                  icon: _sending
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  label: Text(_sending ? 'Модель думает…' : 'Отправить'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Скопировать данные для другого чата',
                icon: const Icon(Icons.copy),
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(
                      text: '$diagnosisSystemPrompt\n\n${_message(rec)}',
                    ),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Промпт и данные скопированы'),
                      ),
                    );
                  }
                },
              ),
            ],
          ),
          if (_error case final error?) ...[
            const SizedBox(height: 16),
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_reply case final reply?) ...[
            const SizedBox(height: 16),
            SelectableText(reply.text),
            const SizedBox(height: 8),
            Text(
              '${reply.model} · вход ${reply.inputTokens ?? '?'}, '
              'выход ${reply.outputTokens ?? '?'} токенов'
              '${reply.truncated ? ' · ответ обрезан' : ''}',
              style: text.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}
