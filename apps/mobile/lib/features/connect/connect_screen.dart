import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:scan_core/scan_core.dart';

import '../../core/adapter_store.dart';
import '../live/scan_controller.dart';
import 'bluetooth_picker.dart';

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  var _scenario = SimScenario.vacuumLeak;
  final _host = TextEditingController(text: TcpTransport.defaultHost);
  final _port = TextEditingController(text: '${TcpTransport.defaultPort}');

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _connect(AdapterTarget target) {
    // Подключение идёт в фоне, экран «Данные» показывает его ход.
    ref.read(scanControllerProvider.notifier).connect(target).ignore();
    context.go('/live');
  }

  Future<void> _pickBluetooth() async {
    final target = await pickBluetoothAdapter(context, ref);
    if (target != null && mounted) _connect(target);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final last = ref.watch(lastAdapterProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('scanAuto'),
        actions: [
          IconButton(
            tooltip: 'Журналы сеансов',
            icon: const Icon(Icons.description_outlined),
            onPressed: () => context.go('/logs'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Подключение', style: text.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Адаптер ELM327 вставляется в разъём OBD-II под рулём. '
            'Зажигание должно быть включено.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 16),
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: const Icon(Icons.route),
              title: const Text('Диагностика по программе'),
              subtitle: const Text(
                'Прогрев → город → трасса, потом разбор записи ИИ',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/program'),
            ),
          ),
          Text('Живые данные', style: text.titleMedium),
          const SizedBox(height: 8),
          if (last != null)
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                leading: Icon(
                  last is BluetoothTarget ? Icons.bluetooth : Icons.wifi,
                ),
                title: Text('Подключить ${last.title}'),
                subtitle: const Text('Последний адаптер'),
                trailing: const Icon(Icons.play_arrow),
                onTap: () => _connect(last),
              ),
            ),
          _TargetCard(
            icon: Icons.bluetooth,
            title: 'Bluetooth адаптер',
            subtitle:
                'Адаптер спаривается в настройках Bluetooth телефона, '
                'здесь — выбор из спаренных.',
            action: FilledButton(
              onPressed: _pickBluetooth,
              child: const Text('Выбрать адаптер'),
            ),
          ),
          _TargetCard(
            icon: Icons.science_outlined,
            title: 'Симулятор',
            subtitle: 'Без машины: программный адаптер и двигатель с выбранной неисправностью.',
            action: FilledButton(
              onPressed: () => _connect(SimulatorTarget(_scenario)),
              child: const Text('Запустить'),
            ),
            child: DropdownButtonFormField<SimScenario>(
              initialValue: _scenario,
              decoration: const InputDecoration(labelText: 'Сценарий'),
              items: [
                for (final s in SimScenario.values)
                  DropdownMenuItem(value: s, child: Text(s.title)),
              ],
              onChanged: (s) => setState(() => _scenario = s ?? _scenario),
            ),
          ),
          _TargetCard(
            icon: Icons.wifi,
            title: 'Wi-Fi адаптер',
            subtitle: 'Сначала подключите телефон к сети адаптера в настройках Wi-Fi.',
            action: FilledButton(
              onPressed: () {
                final port = int.tryParse(_port.text.trim());
                if (port == null) return;
                _connect(WifiTarget(_host.text.trim(), port));
              },
              child: const Text('Подключить'),
            ),
            child: Row(
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
          ),
        ],
      ),
    );
  }
}

class _TargetCard extends StatelessWidget {
  const _TargetCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.child,
    this.action,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(icon),
              title: Text(title),
              subtitle: Text(subtitle),
            ),
            ?child,
            if (action case final action?) ...[
              const SizedBox(height: 12),
              Align(alignment: Alignment.centerRight, child: action),
            ],
          ],
        ),
      ),
    );
  }
}
