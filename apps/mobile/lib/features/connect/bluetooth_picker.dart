import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/bluetooth_classic.dart';
import '../live/scan_controller.dart';

/// Выбор спаренного адаптера. Сам поиск и спаривание — в настройках Android:
/// у клонов PIN, а системный диалог с этим справляется лучше.
Future<BluetoothTarget?> pickBluetoothAdapter(
  BuildContext context,
  WidgetRef ref,
) => showModalBottomSheet<BluetoothTarget>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => const _Picker(),
);

class _Picker extends ConsumerStatefulWidget {
  const _Picker();

  @override
  ConsumerState<_Picker> createState() => _PickerState();
}

class _PickerState extends ConsumerState<_Picker> {
  late Future<List<BtDevice>> _devices = _load();

  Future<List<BtDevice>> _load() async {
    final bt = ref.read(bluetoothProvider);
    if (!await bt.ensurePermission()) {
      throw BluetoothException(
        'permission_denied',
        'Разрешите приложению «Устройства поблизости», чтобы видеть адаптер.',
      );
    }
    final list = await bt.bondedDevices();
    // Похожие на OBD — сверху.
    return list
      ..sort((a, b) => (b.looksLikeObd ? 1 : 0) - (a.looksLikeObd ? 1 : 0));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Адаптер Bluetooth', style: text.titleLarge),
            const SizedBox(height: 8),
            FutureBuilder(
              future: _devices,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snap.error case final error?) {
                  return Text(
                    error is BluetoothException
                        ? describeScanError(error)
                        : 'Ошибка: $error',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  );
                }
                final devices = snap.data ?? const [];
                if (devices.isEmpty) {
                  return const Text('Спаренных устройств нет.');
                }
                return ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final d in devices)
                        ListTile(
                          leading: Icon(
                            d.looksLikeObd
                                ? Icons.directions_car
                                : Icons.bluetooth,
                          ),
                          title: Text(d.name.isEmpty ? 'Без имени' : d.name),
                          subtitle: Text(d.address),
                          onTap: () => Navigator.pop(
                            context,
                            BluetoothTarget(d.address, d.name),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
            const Divider(height: 24),
            Text(
              'Нет адаптера в списке? Вставьте его в разъём OBD, включите зажигание, '
              'откройте настройки Bluetooth телефона и подключите устройство '
              '«OBDII» (или «OBD2», «ELM327»). PIN обычно 1234 или 0000. '
              'Потом вернитесь сюда и обновите список.',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => ref.read(bluetoothProvider).openSettings(),
                    child: const Text('Настройки Bluetooth'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: () => setState(() => _devices = _load()),
                    child: const Text('Обновить'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
