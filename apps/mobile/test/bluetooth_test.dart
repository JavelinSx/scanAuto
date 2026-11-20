import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_core/scan_core.dart';
import 'package:scanauto/core/adapter_store.dart';
import 'package:scanauto/core/bluetooth_classic.dart';
import 'package:scanauto/core/session_log.dart';
import 'package:scanauto/features/live/scan_controller.dart';

/// Адаптер «по Bluetooth»: симулятор, у которого можно оборвать связь.
class _DroppableTransport implements ObdTransport {
  _DroppableTransport({int canErrors = 0})
    : _sim = SimulatedElm327(
        scenario: SimScenario.vacuumLeak,
        latency: const Duration(milliseconds: 2),
        requiredProtocol: canErrors > 0 ? '6' : null,
        canErrors: canErrors,
      ) {
    _sim.input.listen((b) {
      if (!_input.isClosed) _input.add(b);
    }, onDone: drop);
  }

  final SimulatedElm327 _sim;
  final _input = StreamController<List<int>>();

  void drop() {
    if (!_input.isClosed) _input.close();
  }

  /// Запись больше не возвращается — как Bluetooth после заморозки в фоне.
  bool hung = false;

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  Future<void> write(List<int> bytes) =>
      hung ? Completer<void>().future : _sim.write(bytes);

  @override
  Future<void> close() async {
    drop();
    await _sim.close();
  }
}

class _FakeBluetooth implements BluetoothClassic {
  final connects = <String>[];
  _DroppableTransport? last;

  /// Адаптер «неплотно в разъёме»: столько раз CAN ERROR.
  int canErrors = 0;

  /// Адаптер пропал совсем: подключение не проходит.
  bool unreachable = false;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<List<BtDevice>> bondedDevices() async => const [
    BtDevice('OBDII', '00:1D:A5:68:98:8B'),
  ];

  @override
  Future<ObdTransport> connect(String address) async {
    connects.add(address);
    if (unreachable) {
      throw BluetoothException('connect_failed', 'нет ответа');
    }
    return last = _DroppableTransport(canErrors: canErrors);
  }

  @override
  Future<void> openSettings() async {}
}

class _MemoryAdapters implements AdapterStore {
  AdapterTarget? saved;

  @override
  Future<AdapterTarget?> loadLast() async => saved;

  @override
  Future<void> saveLast(AdapterTarget target) async => saved = target;

  final protocols = <String, String>{};

  @override
  Future<String?> loadProtocol(AdapterTarget target) async =>
      protocols[adapterId(target)];

  @override
  Future<void> saveProtocol(AdapterTarget target, String key) async =>
      protocols[adapterId(target)!] = key;
}

class _MemoryLog implements SessionLog {
  final lines = <String>[];
  Recording? saved;
  var closed = false;

  @override
  void write(String tag, String message) => lines.add('[$tag] $message');

  @override
  Future<void> saveRecording(Recording recording) async => saved = recording;

  @override
  Future<void> close() async => closed = true;
}

Future<ScanState> _waitFor(
  ProviderContainer container,
  bool Function(ScanState) test, {
  Duration timeout = const Duration(seconds: 10),
}) {
  final done = Completer<ScanState>();
  final sub = container.listen(scanControllerProvider, (_, next) {
    if (test(next) && !done.isCompleted) done.complete(next);
  }, fireImmediately: true);
  return done.future.timeout(timeout).whenComplete(sub.close);
}

void main() {
  const adapter = BluetoothTarget('00:1D:A5:68:98:8B', 'OBDII');
  late _FakeBluetooth bluetooth;
  late _MemoryAdapters adapters;
  late _MemoryLog log;
  late ProviderContainer container;

  setUp(() {
    ScanController.autoReconnectDelay = const Duration(milliseconds: 10);
    bluetooth = _FakeBluetooth();
    adapters = _MemoryAdapters();
    log = _MemoryLog();
    container = ProviderContainer(
      overrides: [
        bluetoothProvider.overrideWithValue(bluetooth),
        adapterStoreProvider.overrideWithValue(adapters),
        sessionLogFactoryProvider.overrideWithValue(() async => log),
      ],
    );
  });

  tearDown(() => container.dispose());

  test(
    'Bluetooth: подключение, адаптер запоминается, обмен в журнале',
    () async {
      final controller = container.read(scanControllerProvider.notifier);
      unawaited(controller.connect(adapter));
      final live = await _waitFor(
        container,
        (s) => s.phase == ScanPhase.live && s.latest.isNotEmpty,
      );

      expect(bluetooth.connects, [adapter.address]);
      expect(live.dtcs, ['P0171']);
      expect((adapters.saved! as BluetoothTarget).address, adapter.address);
      expect(log.lines, contains('[elm] TX ATZ'));
      // Разведка блока: симулятор отвечает на 21 01 — блок пишется в запись.
      expect(log.lines, contains(startsWith('[vaz] блок данных 2101')));
      // Ускорение опроса, готовность и бортовые тесты — в журнале.
      expect(
        log.lines,
        contains(
          startsWith('[elm] PROTOCOL ускорение опроса: блоков ответило 1'),
        ),
      );
      expect(
        log.lines,
        contains(startsWith('[readiness] начало: Check Engine')),
      );
      expect(
        log.lines,
        contains(startsWith('[mode06] начало: лямбда-зонд ряд 1 датчик 1')),
      );
      expect(live.recording!.readiness, isNotEmpty);
      expect(live.recording!.monitorTests, isNotEmpty);
      expect(
        log.lines.any((l) => l.startsWith('[elm] адаптер ELM327')),
        isTrue,
      );

      // Протокол запомнен: следующее подключение — сразу на нём.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(adapters.protocols['bt.${adapter.address}'], '6');

      await controller.disconnect();
      expect(log.closed, isTrue);
      expect(
        log.saved,
        isNotNull,
        reason: 'запись сохраняется рядом с журналом',
      );
    },
  );

  Future<(ScanController, Recording, int)> startLive() async {
    final controller = container.read(scanControllerProvider.notifier);
    unawaited(controller.connect(adapter));
    final live = await _waitFor(
      container,
      (s) =>
          s.phase == ScanPhase.live &&
          (s.recording?.series['rpm']?.length ?? 0) > 3,
    );
    final recording = live.recording!;
    return (controller, recording, recording.series['rpm']!.length);
  }

  test(
    'обрыв связи: переподключается сам, та же запись продолжается',
    () async {
      final (controller, recording, before) = await startLive();

      bluetooth.last!.drop();
      final again = await _waitFor(
        container,
        (s) =>
            s.phase == ScanPhase.live &&
            recording.series['rpm']!.length > before + 3,
      );
      expect(again.recording, same(recording));
      expect(bluetooth.connects, hasLength(2));
      expect(log.lines, contains('[session] автопереподключение 1 из 3'));
      expect(log.lines, contains('[session] переподключение'));
      expect(log.lines.any((l) => l.startsWith('[error] обрыв')), isTrue);
      await controller.disconnect();
    },
  );

  test(
    'запись в адаптер зависла: плашка «нет данных», потом переподключение',
    () async {
      final (controller, recording, before) = await startLive();

      // Гранта, 18.11: после заморозки в фоне отправка не вернулась никогда.
      bluetooth.last!.hung = true;
      final stale = await _waitFor(container, (s) => s.staleSeconds > 0);
      expect(stale.staleSeconds, greaterThanOrEqualTo(3));

      // 5 тайм-аутов по 2 с (и по 0.3 с на сброс после каждого) + переподключение.
      final again = await _waitFor(
        container,
        (s) =>
            s.phase == ScanPhase.live &&
            s.staleSeconds == 0 &&
            recording.series['rpm']!.length > before + 3,
        timeout: const Duration(seconds: 30),
      );
      expect(again.recording, same(recording));
      expect(bluetooth.connects, hasLength(2));
      expect(log.lines, contains(startsWith('[elm] TIMEOUT')));
      expect(log.lines, contains('[session] автопереподключение 1 из 3'));
      await controller.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('адаптер пропал совсем: три попытки, потом экран обрыва', () async {
    final (controller, recording, _) = await startLive();

    bluetooth.unreachable = true;
    bluetooth.last!.drop();
    final failed = await _waitFor(
      container,
      (s) => s.phase == ScanPhase.failed,
    );
    expect(failed.recording, same(recording));
    expect(failed.error, contains('Не удалось подключиться'));
    expect(bluetooth.connects, hasLength(1 + ScanController.maxAutoReconnects));
    expect(log.lines, contains('[session] автопереподключение 3 из 3'));
    expect(controller.canResume, isTrue);

    // Кнопка «Переподключиться» снова даёт три попытки.
    bluetooth.unreachable = false;
    unawaited(controller.reconnect());
    await _waitFor(container, (s) => s.phase == ScanPhase.live);
    await controller.disconnect();
  });

  test('«Остановить» во время переподключения: запись остаётся', () async {
    ScanController.autoReconnectDelay = const Duration(seconds: 5);
    final (controller, recording, _) = await startLive();

    bluetooth.last!.drop();
    await _waitFor(
      container,
      (s) =>
          s.phase == ScanPhase.connecting &&
          (s.status ?? '').contains('переподключаюсь'),
    );
    await controller.stop();
    final state = container.read(scanControllerProvider);
    expect(state.phase, ScanPhase.finished);
    expect(state.recording, same(recording));
    expect(log.saved, same(recording));
    // Отложенное переподключение не запустилось после остановки.
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(bluetooth.connects, hasLength(1));
    expect(container.read(scanControllerProvider).phase, ScanPhase.finished);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('второе подключение идёт по сохранённому протоколу', () async {
    adapters.protocols['bt.${adapter.address}'] = '6';
    final controller = container.read(scanControllerProvider.notifier);
    unawaited(controller.connect(adapter));
    await _waitFor(container, (s) => s.phase == ScanPhase.live);
    expect(log.lines, contains(startsWith('[elm] PROTOCOL сохранённый')));
    expect(log.lines.any((l) => l.contains('[elm] TX ATSP0')), isFalse);
    await controller.disconnect();
  });

  test('шина CAN отвечает не сразу — подключение её дожидается', () async {
    // 4 CAN ERROR уходят на быстрый проход, ещё 2 — на ожидание шины.
    bluetooth.canErrors = 6;
    final controller = container.read(scanControllerProvider.notifier);
    unawaited(controller.connect(adapter));
    final done = Completer<ScanState>();
    final sub = container.listen(scanControllerProvider, (_, next) {
      if ((next.phase == ScanPhase.live || next.phase == ScanPhase.failed) &&
          !done.isCompleted) {
        done.complete(next);
      }
    });
    final state = await done.future.timeout(const Duration(seconds: 40));
    sub.close();
    expect(state.phase, ScanPhase.live, reason: state.error);
    expect(log.lines, contains('[elm] PROTOCOL CAN ожил на попытке 3 из 150'));
    await controller.disconnect();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'адаптер вынули и вставили, пока ждали шину, — подключается сам',
    () async {
      // Совет на экране ожидания: выньте адаптер на 5 секунд и вставьте снова.
      bluetooth.canErrors = 1000;
      final controller = container.read(scanControllerProvider.notifier);
      unawaited(controller.connect(adapter));
      await _waitFor(
        container,
        (s) => (s.status ?? '').startsWith('Жду шину CAN'),
        timeout: const Duration(seconds: 30),
      );
      bluetooth.canErrors = 0;
      bluetooth.last!.drop();
      final live = await _waitFor(
        container,
        (s) => s.phase == ScanPhase.live,
        timeout: const Duration(seconds: 30),
      );
      expect(live.recording, isNotNull);
      expect(bluetooth.connects, hasLength(2));
      expect(log.lines, contains('[session] автопереподключение 1 из 6'));
      await controller.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('сообщение про шину CAN', () {
    expect(
      describeScanError(ElmException(ElmError.canError, 'CAN ERROR')),
      allOf(contains('Шина CAN'), contains('Выньте его из разъёма')),
    );
  });
}
