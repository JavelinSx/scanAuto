import 'package:flutter/material.dart';

/// Данные от адаптера не идут: цифры на экране — последние полученные,
/// а не текущие. Без этой плашки застывшие значения выглядят как живые.
class StaleBanner extends StatelessWidget {
  const StaleBanner({super.key, required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.sync_problem, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Нет данных от адаптера $seconds с — цифры ниже устаревшие. '
                'Если не пойдут, приложение само переподключится.',
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
