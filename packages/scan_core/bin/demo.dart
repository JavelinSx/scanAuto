// Разбор записи симулятора на ПК — чтобы подбирать промпт и модель без телефона и машины.
//
//   dart run scan_core:demo --scenario vacuumLeak            пакет для ИИ в stdout
//   dart run scan_core:demo --scenario vacuumLeak --ask      отправить в модель
//   dart run scan_core:demo --program winter --scenario thermostatStuckOpen   программа на Гранте
//
// Модель задаётся переменными окружения:
//   AI_PROTOCOL  anthropic | openai (по умолчанию anthropic)
//   AI_BASE_URL  например https://api.anthropic.com или https://llm.api.cloud.yandex.net/v1
//   AI_MODEL     например claude-opus-5-5
//   AI_API_KEY   ключ; в репозиторий и в чат не попадает
import 'dart:convert';
import 'dart:io';

import 'package:scan_core/scan_core.dart';

Future<void> main(List<String> args) async {
  String? option(String name) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final scenario = SimScenario.values.firstWhere(
    (s) => s.name == (option('scenario') ?? 'vacuumLeak'),
    orElse: () {
      stderr.writeln(
        'Сценарии: ${SimScenario.values.map((s) => s.name).join(', ')}',
      );
      exit(64);
    },
  );
  final minutes = int.tryParse(option('minutes') ?? '') ?? 5;

  // --program summer|winter — вся программа «прогрев → город → трасса» на Гранте.
  final season = Season.values.where((s) => s.name == option('program'));
  final rec = season.isEmpty
      ? (simulateRecording(scenario, duration: Duration(minutes: minutes))
          ..vehicle = const VehicleInfo(
            title: 'Lada Vesta 1.6 16V, 2019, механика',
          ))
      : simulateProgramRecording(
          scenario,
          DiagnosticProgram.standard(season.first),
          vehicle: VehicleInfo(
            make: 'Lada',
            model: 'Granta',
            engine: ladaGrantaEngines.first,
            year: 2019,
            mileageKm: 84000,
            transmission: transmissions.first,
          ),
        );
  final packet = AnalysisPacket.build(rec);
  final user = diagnosisUserMessage(packet, question: option('question'));

  stderr.writeln(
    'Сценарий: ${scenario.title}. '
    'Сообщение ~${user.length} символов, ~${user.length ~/ 3} токенов.',
  );

  if (!args.contains('--ask')) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(packet));
    return;
  }

  final env = Platform.environment;
  final anthropic = (env['AI_PROTOCOL'] ?? 'anthropic') == 'anthropic';
  final config = AiProviderConfig(
    protocol: anthropic ? AiProtocol.anthropic : AiProtocol.openAiCompatible,
    baseUrl:
        env['AI_BASE_URL'] ??
        (anthropic ? 'https://api.anthropic.com' : 'https://api.openai.com/v1'),
    model: env['AI_MODEL'] ?? (anthropic ? 'claude-opus-5-5' : ''),
    apiKey: env['AI_API_KEY'] ?? '',
  );
  if (config.model.isEmpty) {
    stderr.writeln('Задайте AI_MODEL.');
    exit(64);
  }

  try {
    final reply = await AiClient(config)
        .complete(system: diagnosisSystemPrompt, user: user);
    stdout.writeln(reply.text);
    stderr.writeln(
      '\n${reply.model}: вход ${reply.inputTokens ?? '?'}, '
      'выход ${reply.outputTokens ?? '?'} токенов'
      '${reply.truncated ? ', ответ обрезан' : ''}.',
    );
  } on AiException catch (e) {
    stderr.writeln('Ошибка модели: $e');
    exit(1);
  }
}
