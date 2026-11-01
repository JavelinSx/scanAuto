import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_core/scan_core.dart';
import 'package:scanauto/core/wifi_binding.dart';
import 'package:scanauto/features/live/scan_controller.dart';

class _FakeWifiBinding implements WifiBinding {
  final calls = <String>[];

  @override
  Future<bool> bind() async {
    calls.add('bind');
    return true;
  }

  @override
  Future<void> release() async => calls.add('release');
}

Future<ScanState> _waitFor(
  ProviderContainer container,
  bool Function(ScanState) test,
) {
  final done = Completer<ScanState>();
  final sub = container.listen(scanControllerProvider, (_, next) {
    if (test(next) && !done.isCompleted) done.complete(next);
  }, fireImmediately: true);
  return done.future
      .timeout(const Duration(seconds: 10))
      .whenComplete(sub.close);
}

void main() {
  late _FakeWifiBinding wifi;
  late ProviderContainer container;

  setUp(() {
    wifi = _FakeWifiBinding();
    container = ProviderContainer(
      overrides: [wifiBindingProvider.overrideWithValue(wifi)],
    );
  });

  tearDown(() => container.dispose());

  test(
    'Wi-Fi: привязка к сети на время сеанса, снятие при отключении',
    () async {
      final server = await SimServer.start(scenario: SimScenario.vacuumLeak);
      final controller = container.read(scanControllerProvider.notifier);

      unawaited(controller.connect(WifiTarget(server.host, server.port)));
      final live = await _waitFor(container, (s) => s.phase == ScanPhase.live);
      expect(live.dtcs, ['P0171']);
      expect(wifi.calls, ['bind']);

      await controller.disconnect();
      expect(wifi.calls, ['bind', 'release']);
      await server.close();
    },
  );

  test('Wi-Fi: адаптер недоступен — ошибка и привязка снята', () async {
    // Порт, на котором никто не слушает.
    final server = await SimServer.start();
    final port = server.port;
    await server.close();

    final controller = container.read(scanControllerProvider.notifier);
    unawaited(controller.connect(WifiTarget('127.0.0.1', port)));
    final failed = await _waitFor(
      container,
      (s) => s.phase == ScanPhase.failed,
    );
    expect(failed.error, contains('Wi-Fi'));
    expect(wifi.calls, ['bind', 'release']);
  });

  test('симулятор Wi-Fi не трогает', () async {
    final controller = container.read(scanControllerProvider.notifier);
    unawaited(controller.connect(const SimulatorTarget(SimScenario.healthy)));
    await _waitFor(container, (s) => s.phase == ScanPhase.live);
    await controller.disconnect();
    expect(wifi.calls, isEmpty);
  });
}
