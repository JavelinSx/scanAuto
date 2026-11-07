import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_core/scan_core.dart';
import 'package:scanauto/core/session_log.dart';
import 'package:scanauto/core/wifi_binding.dart';
import 'package:scanauto/features/ai/ai_screen.dart';
import 'package:scanauto/features/ai/ai_settings.dart';
import 'package:scanauto/features/live/scan_controller.dart';

const _granta = VehicleInfo(
  make: 'Lada',
  model: 'Granta',
  engine: '1.6 8 кл. ВАЗ-11186, 87 л.с.',
  mileageKm: 84000,
);

class _NoWifi implements WifiBinding {
  @override
  Future<bool> bind() async => true;

  @override
  Future<void> release() async {}
}

class _MemoryLog implements SessionLog {
  final lines = <String>[];
  Recording? saved;

  @override
  void write(String tag, String message) => lines.add('[$tag] $message');

  @override
  Future<void> saveRecording(Recording recording) async => saved = recording;

  @override
  Future<void> close() async {}
}

class _MemoryStore implements AiSettingsStore {
  AiSettings? saved;

  @override
  Future<AiSettings?> load() async => saved;

  @override
  Future<void> save(AiSettings settings) async => saved = settings;
}

class _FakeAdapter implements HttpClientAdapter {
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromString(
      jsonEncode({
        'model': 'claude-opus-5-5',
        'stop_reason': 'end_turn',
        'content': [
          {'type': 'text', 'text': 'Похоже на подсос воздуха.'},
        ],
        'usage': {'input_tokens': 11000, 'output_tokens': 900},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Состояние «программа пройдена» без адаптера.
class _FinishedScan extends ScanController {
  @override
  ScanState build() => ScanState(
    phase: ScanPhase.finished,
    program: DiagnosticProgram.standard(Season.summer),
    recording: simulateProgramRecording(
      SimScenario.vacuumLeak,
      DiagnosticProgram.standard(Season.summer),
      vehicle: _granta,
      step: const Duration(seconds: 2),
    ),
  );
}

void main() {
  test('программа на ускоренном симуляторе проходит все этапы сама', () async {
    final log = _MemoryLog();
    final container = ProviderContainer(
      overrides: [
        wifiBindingProvider.overrideWithValue(_NoWifi()),
        sessionLogFactoryProvider.overrideWithValue(() async => log),
      ],
    );
    addTearDown(container.dispose);
    final done = Completer<ScanState>();
    container.listen(scanControllerProvider, (_, next) {
      if ((next.phase == ScanPhase.finished ||
              next.phase == ScanPhase.failed) &&
          !done.isCompleted) {
        done.complete(next);
      }
    });

    unawaited(
      container
          .read(scanControllerProvider.notifier)
          .connect(
            const SimulatorTarget(SimScenario.vacuumLeak, speed: 50),
            program: DiagnosticProgram.standard(Season.summer),
            vehicle: _granta,
          ),
    );
    final state = await done.future.timeout(const Duration(seconds: 60));

    expect(state.phase, ScanPhase.finished, reason: state.error);
    final rec = state.recording!;
    expect(rec.segments.map((s) => s.key), ['warmup', 'city', 'highway']);
    expect(
      rec.segments.every((s) => s.completed),
      isTrue,
      reason: [
        for (final s in rec.segments)
          '${s.key} ${s.completed} ${s.note} ${s.endMs - s.startMs}',
      ].join('; '),
    );
    expect(rec.vehicle?.engine, _granta.engine);
    expect(rec.vehicle?.vin, SimulatedElm327.vin);
    expect(rec.dtcs, ['P0171']);
    // Пакет для модели строится из того, что записал сеанс.
    final packet = AnalysisPacket.build(rec);
    expect(packet['stages'], hasLength(3));

    // Журнал: итог каждого этапа, снимки значений, сохранённая запись.
    final stageLines = log.lines.where((l) => l.startsWith('[stage] конец'));
    expect(stageLines.map((l) => RegExp('«(.+?)»').firstMatch(l)![1]), [
      'Прогрев',
      'Город',
      'Трасса',
    ]);
    expect(stageLines.first, contains('coolant_start'));
    expect(log.lines.where((l) => l.startsWith('[snapshot]')), isNotEmpty);
    expect(log.lines, contains(startsWith('[session] профиль')));
    // Запись сохраняется после отключения адаптера — чуть позже смены фазы.
    for (var i = 0; i < 50 && log.saved == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(log.saved, same(rec));
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('разбор ИИ: ключ сохраняется, в модель уходят этапы и профиль', (
    tester,
  ) async {
    // Экран — длинный список: делаем окно высоким, чтобы ответ модели был построен.
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _MemoryStore();
    final adapter = _FakeAdapter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          scanControllerProvider.overrideWith(_FinishedScan.new),
          aiSettingsStoreProvider.overrideWithValue(store),
          aiClientFactoryProvider.overrideWithValue(
            (config) =>
                AiClient(config, dio: Dio()..httpClientAdapter = adapter),
          ),
        ],
        child: const MaterialApp(home: AiScreen()),
      ),
    );
    await tester.pump();

    await tester.enterText(
      find.widgetWithText(TextField, 'Ключ API'),
      'test-key',
    );
    await tester.tap(find.text('Отправить'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Похоже на подсос воздуха.'), findsOneWidget);
    expect(store.saved?.apiKey, 'test-key');
    final body = adapter.request!.data as Map<String, Object?>;
    final user =
        ((body['messages']! as List).single as Map)['content']! as String;
    expect(user, contains('"stages"'));
    expect(user, contains('ВАЗ-11186'));
    expect(body['system'], diagnosisSystemPrompt);
  });
}
