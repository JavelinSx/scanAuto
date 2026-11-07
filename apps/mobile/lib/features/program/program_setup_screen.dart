import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:scan_core/scan_core.dart';

import '../../core/adapter_store.dart';
import '../connect/bluetooth_picker.dart';
import '../live/scan_controller.dart';

/// Подготовка программы диагностики: сезон, профиль машины, адаптер.
class ProgramSetupScreen extends ConsumerStatefulWidget {
  const ProgramSetupScreen({super.key});

  @override
  ConsumerState<ProgramSetupScreen> createState() => _ProgramSetupScreenState();
}

const _otherEngine = 'Другой — опишу в заметках';

enum _Adapter { bluetooth, wifi, simulator }

class _ProgramSetupScreenState extends ConsumerState<ProgramSetupScreen> {
  var _season = DateTime.now().month >= 4 && DateTime.now().month <= 10
      ? Season.summer
      : Season.winter;
  final _make = TextEditingController(text: 'Lada');
  final _model = TextEditingController(text: 'Granta');
  var _engine = ladaGrantaEngines.first;
  final _year = TextEditingController();
  final _mileage = TextEditingController();
  var _transmission = transmissions.first;
  var _lpg = false;
  var _catalystRemoved = false;
  final _notes = TextEditingController();

  var _adapter = _Adapter.bluetooth;
  BluetoothTarget? _bluetooth;
  bool _lastApplied = false;
  var _scenario = SimScenario.vacuumLeak;
  var _fastSimulator = true;
  final _host = TextEditingController(text: TcpTransport.defaultHost);
  final _port = TextEditingController(text: '${TcpTransport.defaultPort}');

  @override
  void dispose() {
    for (final c in [_make, _model, _year, _mileage, _notes, _host, _port]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _text(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  void _start() {
    final AdapterTarget target;
    switch (_adapter) {
      case _Adapter.simulator:
        target = SimulatorTarget(_scenario, speed: _fastSimulator ? 20 : 1);
      case _Adapter.wifi:
        final port = int.tryParse(_port.text.trim());
        if (port == null) return;
        target = WifiTarget(_host.text.trim(), port);
      case _Adapter.bluetooth:
        final bt = _bluetooth;
        if (bt == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Выберите адаптер Bluetooth')),
          );
          return;
        }
        target = bt;
    }
    final vehicle = VehicleInfo(
      make: _text(_make),
      model: _text(_model),
      engine: _engine == _otherEngine ? null : _engine,
      year: int.tryParse(_year.text.trim()),
      mileageKm: int.tryParse(_mileage.text.replaceAll(' ', '')),
      transmission: _transmission,
      lpg: _lpg,
      catalystRemoved: _catalystRemoved,
      notes: _text(_notes),
    );
    ref
        .read(scanControllerProvider.notifier)
        .connect(
          target,
          program: DiagnosticProgram.standard(_season),
          vehicle: vehicle,
        )
        .ignore();
    context.go('/program/run');
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final program = DiagnosticProgram.standard(_season);
    // Последний адаптер подставляется один раз, дальше выбор за пользователем.
    final last = ref.watch(lastAdapterProvider).value;
    if (!_lastApplied && last != null) {
      _lastApplied = true;
      switch (last) {
        case BluetoothTarget():
          _adapter = _Adapter.bluetooth;
          _bluetooth = last;
        case WifiTarget(:final host, :final port):
          _adapter = _Adapter.wifi;
          _host.text = host;
          _port.text = '$port';
        case SimulatorTarget():
          break;
      }
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Диагностика по программе'),
        leading: BackButton(onPressed: () => context.go('/')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Сезон', style: text.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<Season>(
            segments: [
              for (final s in Season.values)
                ButtonSegment(value: s, label: Text(s.title)),
            ],
            selected: {_season},
            onSelectionChanged: (s) => setState(() => _season = s.first),
          ),
          const SizedBox(height: 16),
          Text('Программа', style: text.titleMedium),
          for (final (i, stage) in program.stages.indexed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(child: Text('${i + 1}')),
              title: Text('${stage.title} · ${_duration(stage)}'),
              subtitle: Text(stage.instruction),
            ),
          const Divider(height: 32),
          Text('Машина', style: text.titleMedium),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _make,
                  decoration: const InputDecoration(labelText: 'Марка'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _model,
                  decoration: const InputDecoration(labelText: 'Модель'),
                ),
              ),
            ],
          ),
          DropdownButtonFormField<String>(
            initialValue: _engine,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Двигатель'),
            items: [
              for (final e in [...ladaGrantaEngines, _otherEngine])
                DropdownMenuItem(value: e, child: Text(e)),
            ],
            onChanged: (e) => setState(() => _engine = e ?? _engine),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _year,
                  decoration: const InputDecoration(labelText: 'Год'),
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _mileage,
                  decoration: const InputDecoration(labelText: 'Пробег, км'),
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
          DropdownButtonFormField<String>(
            initialValue: _transmission,
            decoration: const InputDecoration(labelText: 'Коробка'),
            items: [
              for (final t in transmissions)
                DropdownMenuItem(value: t, child: Text(t)),
            ],
            onChanged: (t) =>
                setState(() => _transmission = t ?? _transmission),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Установлено ГБО'),
            subtitle: const Text('Записывайте на бензине'),
            value: _lpg,
            onChanged: (v) => setState(() => _lpg = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Катализатор удалён'),
            value: _catalystRemoved,
            onChanged: (v) => setState(() => _catalystRemoved = v),
          ),
          TextField(
            controller: _notes,
            decoration: const InputDecoration(
              labelText: 'Заметки владельца',
              hintText: 'Что меняли, что беспокоит, тюнинг',
            ),
            maxLines: 2,
          ),
          const Divider(height: 32),
          Text('Адаптер', style: text.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<_Adapter>(
            segments: const [
              ButtonSegment(
                value: _Adapter.bluetooth,
                label: Text('Bluetooth'),
              ),
              ButtonSegment(value: _Adapter.wifi, label: Text('Wi-Fi')),
              ButtonSegment(
                value: _Adapter.simulator,
                label: Text('Симулятор'),
              ),
            ],
            selected: {_adapter},
            onSelectionChanged: (s) => setState(() => _adapter = s.first),
          ),
          if (_adapter == _Adapter.bluetooth)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bluetooth),
              title: Text(_bluetooth?.title ?? 'Адаптер не выбран'),
              subtitle: _bluetooth == null ? null : Text(_bluetooth!.address),
              trailing: TextButton(
                onPressed: () async {
                  final picked = await pickBluetoothAdapter(context, ref);
                  if (picked != null) setState(() => _bluetooth = picked);
                },
                child: const Text('Выбрать'),
              ),
            )
          else if (_adapter == _Adapter.simulator) ...[
            DropdownButtonFormField<SimScenario>(
              initialValue: _scenario,
              decoration: const InputDecoration(labelText: 'Сценарий'),
              items: [
                for (final s in SimScenario.values)
                  DropdownMenuItem(value: s, child: Text(s.title)),
              ],
              onChanged: (s) => setState(() => _scenario = s ?? _scenario),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Ускорить в 20 раз'),
              subtitle: const Text('Вся программа примерно за полторы минуты'),
              value: _fastSimulator,
              onChanged: (v) => setState(() => _fastSimulator = v),
            ),
          ] else
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _host,
                    decoration: const InputDecoration(labelText: 'Адрес'),
                    keyboardType: TextInputType.url,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _port,
                    decoration: const InputDecoration(labelText: 'Порт'),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _start, child: const Text('Начать')),
          const SizedBox(height: 8),
          Text(
            'Этапы переключаются сами. Во время езды в телефон не смотрите.',
            style: text.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  static String _duration(StageSpec s) => switch (s.kind) {
    StageKind.warmup =>
      'до ${DiagnosticProgram.warmCoolant.round()} °C, '
          '${s.minDuration.inMinutes}–${s.maxDuration.inMinutes} мин',
    _ => '${s.target.inMinutes} мин',
  };
}
