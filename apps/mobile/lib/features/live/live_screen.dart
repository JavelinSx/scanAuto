import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:scan_core/scan_core.dart';

import 'pid_chart.dart';
import 'scan_controller.dart';

class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen> {
  String _selected = 'rpm';

  void _disconnect() {
    ref.read(scanControllerProvider.notifier).disconnect().ignore();
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(scanControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(scan.target?.title ?? 'Данные'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Отключиться',
          onPressed: _disconnect,
        ),
      ),
      body: switch (scan.phase) {
        ScanPhase.connecting ||
        ScanPhase.disconnected => _Connecting(scan.status),
        ScanPhase.failed => _Failed(
          scan.error ?? '',
          onBack: _disconnect,
          onRetry: () =>
              ref.read(scanControllerProvider.notifier).reconnect().ignore(),
        ),
        ScanPhase.finished => _Failed(
          'Запись остановлена.',
          onBack: _disconnect,
        ),
        ScanPhase.live => _Live(
          scan: scan,
          selected: _selected,
          onSelect: (key) => setState(() => _selected = key),
        ),
      },
    );
  }
}

class _Connecting extends StatelessWidget {
  const _Connecting(this.status);

  final String? status;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(status ?? ''),
        ],
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed(this.error, {required this.onBack, this.onRetry});

  final String error;
  final VoidCallback onBack;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.link_off,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            if (onRetry case final retry?)
              FilledButton(
                onPressed: retry,
                child: const Text('Переподключить'),
              ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: onBack, child: const Text('Назад')),
          ],
        ),
      ),
    );
  }
}

class _Live extends StatelessWidget {
  const _Live({
    required this.scan,
    required this.selected,
    required this.onSelect,
  });

  final ScanState scan;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final info = scan.info!;
    final recording = scan.recording!;
    final pids = [
      for (final p in standardPids)
        if (info.supportedPids.contains(p.code)) p,
    ];
    final pid = pidsByKey[selected] ?? pids.first;
    final value = scan.latest[pid.key];
    final text = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '${info.protocolName} · ${info.version}'
          '${scan.vin != null ? '\nVIN ${scan.vin}' : ''}'
          '\nЗапись: ${_duration(recording.duration)}'
          '${recording.coveredFrom > Duration.zero ? ', в памяти последние ${ScanController.liveWindow.inHours} ч' : ''}',
          style: text.bodySmall,
        ),
        const SizedBox(height: 12),
        _DtcCard(dtcs: scan.dtcs, pending: scan.pendingDtcs),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 8),
                  child: Text(
                    '${pid.name}: ${_format(pid, value)}',
                    style: text.titleMedium,
                  ),
                ),
                PidChart(pid: pid, series: recording.series[pid.key]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 2.4,
          children: [
            for (final p in pids)
              _PidTile(
                pid: p,
                value: scan.latest[p.key],
                selected: p.key == pid.key,
                onTap: () => onSelect(p.key),
              ),
          ],
        ),
      ],
    );
  }

  static String _duration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final mmss = '${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
    return d.inHours > 0 ? '${d.inHours}:$mmss' : mmss;
  }
}

String _format(Pid pid, double? value) =>
    value == null ? '—' : '${value.toStringAsFixed(pid.decimals)} ${pid.unit}';

class _PidTile extends StatelessWidget {
  const _PidTile({
    required this.pid,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final Pid pid;
  final double? value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Material(
      color: selected
          ? scheme.primaryContainer
          : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                pid.name,
                style: text.labelSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(_format(pid, value), style: text.titleMedium),
            ],
          ),
        ),
      ),
    );
  }
}

class _DtcCard extends ConsumerWidget {
  const _DtcCard({required this.dtcs, required this.pending});

  final List<String> dtcs;
  final List<String> pending;

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Сбросить ошибки?'),
        content: const Text(
          'Заглушите двигатель, зажигание оставьте включённым. Сброс стирает коды, '
          'стоп-кадры и готовность систем самодиагностики: перед техосмотром '
          'машине придётся снова проехать цикл. Причина ошибки от сброса не исчезнет.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Сбросить'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(scanControllerProvider.notifier).clearDtcs();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Не удалось сбросить: ${describeScanError(e)}'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    if (dtcs.isEmpty && pending.isEmpty) {
      return Card(
        child: ListTile(
          leading: Icon(Icons.check_circle_outline, color: scheme.primary),
          title: const Text('Ошибок нет'),
        ),
      );
    }
    return Card(
      child: Column(
        children: [
          for (final code in dtcs)
            ListTile(
              leading: Icon(Icons.warning_amber, color: scheme.error),
              title: Text(code),
              subtitle: Text(describeDtc(code)),
            ),
          for (final code in pending)
            ListTile(
              leading: const Icon(Icons.schedule),
              title: Text('$code · ожидающая'),
              subtitle: Text(describeDtc(code)),
            ),
          if (dtcs.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: OutlinedButton(
                  onPressed: () => _confirmClear(context, ref),
                  child: const Text('Сбросить ошибки'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
