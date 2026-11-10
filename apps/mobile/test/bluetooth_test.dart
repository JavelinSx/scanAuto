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
  _DroppableTransport() {
    _sim.input.listen((b) {
      if (!_input.isClosed) _input.add(b);
    }, onDone: drop);
  }

  final _sim = SimulatedElm327(
    scenario: SimScenario.vacuumLeak,
    latency: const Duration(milliseconds: 2),
  );
  final _input = StreamController<List<int>>();

  void drop() {
    if (!_input.isClosed) _input.close();
  }

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  Future<void> write(List<int> bytes) => _sim.write(bytes);

  @override
  Future<void> close() async {
    drop();
    await _sim.close();
  }
}

class _FakeBluetooth implements BluetoothClassic {
  final connects = <String>[];
  _DroppableTransport? last;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<List<BtDevice>> bondedDevices() async => const [
    BtDevice('OBDII', '00:1D:A5:68:98:8B'),
  ];

  @override
  Future<ObdTransport> connect(String address) async {
    connects.add(address);
    return last = _DroppableTransport();
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
  const adapter = BluetoothTarget('00:1D:A5:68:98:8B', 'OBDII');
  late _FakeBluetooth bluetooth;
  late _MemoryAdapters adapters;
  late _MemoryLog log;
  late ProviderContainer container;

  setUp(() {
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

  test('обрыв связи и переподключение: та же запись продолжается', () async {
    final controller = container.read(scanControllerProvider.notifier);
    unawaited(controller.connect(adapter));
    final live = await _waitFor(
      container,
      (s) =>
          s.phase == ScanPhase.live &&
          (s.recording?.series['rpm']?.length ?? 0) > 3,
    );
    final recording = live.recording!;
    final before = recording.series['rpm']!.length;

    bluetooth.last!.drop();
    final failed = await _waitFor(
      container,
      (s) => s.phase == ScanPhase.failed,
    );
    expect(failed.error, 'Связь с адаптером потеряна.');
    expect(failed.recording, same(recording));
    expect(controller.canResume, isTrue);

    unawaited(controller.reconnect());
    final again = await _waitFor(
      container,
      (s) =>
          s.phase == ScanPhase.live &&
          recording.series['rpm']!.length > before + 3,
    );
    expect(again.recording, same(recording));
    expect(bluetooth.connects, hasLength(2));
    expect(log.lines, contains('[session] переподключение'));
    expect(log.lines.any((l) => l.startsWith('[error] обрыв')), isTrue);
    await controller.disconnect();
  });

  test('второе подключение идёт по сохранённому протоколу', () async {
    adapters.protocols['bt.${adapter.address}'] = '6';
    final controller = container.read(scanControllerProvider.notifier);
    unawaited(controller.connect(adapter));
    await _waitFor(container, (s) => s.phase == ScanPhase.live);
    expect(log.lines, contains(startsWith('[elm] PROTOCOL сохранённый')));
    expect(log.lines.any((l) => l.contains('[elm] TX ATSP0')), isFalse);
    await controller.disconnect();
  });
}
