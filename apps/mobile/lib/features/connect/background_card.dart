import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/background_session.dart';

/// Предупреждение, если Android может остановить запись в фоне: ограничение батареи
/// не снято. Без него прошивки замораживают приложение, стоит его свернуть.
class BackgroundCard extends ConsumerWidget {
  const BackgroundCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(backgroundStatusProvider).value;
    if (status == null || status.batteryExempt) return const SizedBox.shrink();
    final background = ref.read(backgroundSessionProvider);
    final hint = backgroundHint(status.manufacturer);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Запись может остановиться в фоне',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Android ограничивает приложение ради батареи: стоит его свернуть '
              'или погасить экран — опрос встаёт. Разрешите работу в фоне.'
              '${hint == null ? '' : '\n\n$hint'}',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: background.openAppSettings,
                  child: const Text('Настройки приложения'),
                ),
                FilledButton(
                  onPressed: () async {
                    await background.requestBatteryExemption();
                    ref.invalidate(backgroundStatusProvider);
                  },
                  child: const Text('Разрешить работу в фоне'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
