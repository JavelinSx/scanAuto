import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:scan_core/scan_core.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../live/scan_controller.dart';

/// Ход программы: крупно, чтобы читалось с держателя на панели.
class ProgramRunScreen extends ConsumerStatefulWidget {
  const ProgramRunScreen({super.key});

  @override
  ConsumerState<ProgramRunScreen> createState() => _ProgramRunScreenState();
}

class _ProgramRunScreenState extends ConsumerState<ProgramRunScreen> {
  @override
  void initState() {
    super.initState();
    // Экран не гаснет: на погасшем экране Android может остановить приложение.
    unawaited(WakelockPlus.enable().catchError((Object _) {}));
  }

  @override
  void dispose() {
    unawaited(WakelockPlus.disable().catchError((Object _) {}));
    super.dispose();
  }

  void _home() {
    ref.read(scanControllerProvider.notifier).disconnect().ignore();
    context.go('/');
  }

  Future<void> _confirmStop() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Остановить программу?'),
        content: const Text(
          'Записанное сохранится, его можно будет отправить на разбор.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Продолжить'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Остановить'),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(scanControllerProvider.notifier).stop();
  }

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(scanControllerProvider);
    final program = scan.program;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          program == null
              ? 'Программа'
              : 'Программа · ${program.season.title.toLowerCase()}',
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'На главную',
          onPressed: _home,
        ),
      ),
      body: switch (scan.phase) {
        ScanPhase.disconnected || ScanPhase.connecting => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(scan.status ?? ''),
            ],
          ),
        ),
        ScanPhase.live => _Running(scan: scan, onStop: _confirmStop),
        ScanPhase.finished || ScanPhase.failed => _Summary(scan: scan),
      },
    );
  }
}

class _Running extends ConsumerWidget {
  const _Running({required this.scan, required this.onStop});

  final ScanState scan;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final program = scan.program!;
    final status = scan.programStatus;
    final text = Theme.of(context).textTheme;
    if (status == null) {
      return const Center(child: Text('Первые замеры…'));
    }
    final stage = program.stages[status.stageIndex];
    final run = stage.runs[status.runIndex];

    String value(String key) {
      final pid = pidsByKey[key]!;
      final v = scan.latest[key];
      return v == null ? '—' : '${v.toStringAsFixed(pid.decimals)} ${pid.unit}';
    }

    final shown = switch (stage.kind) {
      StageKind.warmup => ['coolant', 'rpm'],
      StageKind.city => ['speed', 'rpm'],
      StageKind.highway => ['speed', 'rpm'],
    };

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (final (i, s) in program.stages.indexed)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Chip(
                      label: Text(s.title),
                      avatar: i < status.stageIndex
                          ? const Icon(Icons.check, size: 18)
                          : null,
                      backgroundColor: i == status.stageIndex
                          ? Theme.of(context).colorScheme.primaryContainer
                          : null,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Text(stage.title, style: text.displaySmall),
          const SizedBox(height: 8),
          Text(stage.instruction, style: text.titleMedium),
          const SizedBox(height: 24),
          LinearProgressIndicator(value: status.progress, minHeight: 12),
          const SizedBox(height: 8),
          Text(
            '${_mmss(status.elapsed)} · прогон «${run.title}»',
            style: text.bodyLarge,
          ),
          if (status.hint case final hint?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(hint, style: text.titleLarge),
            ),
          const SizedBox(height: 24),
          Row(
            children: [
              for (final key in shown)
                Expanded(
                  child: Column(
                    children: [
                      Text(pidsByKey[key]!.name, style: text.bodyMedium),
                      Text(value(key), style: text.headlineMedium),
                    ],
                  ),
                ),
            ],
          ),
          if (scan.dtcs.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Ошибки в памяти: ${scan.dtcs.join(', ')}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () =>
                      ref.read(scanControllerProvider.notifier).skipStage(),
                  child: const Text('Закончить этап'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: onStop,
                  child: const Text('Остановить'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Summary extends ConsumerWidget {
  const _Summary({required this.scan});

  final ScanState scan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(scanControllerProvider.notifier);
    final failed = scan.phase == ScanPhase.failed;
    final rec = scan.recording;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final hasData = rec != null && rec.series.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          scan.phase == ScanPhase.failed ? 'Программа прервалась' : 'Готово',
          style: text.headlineSmall,
        ),
        if (scan.error case final error?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(error, style: TextStyle(color: scheme.error)),
          ),
        const SizedBox(height: 16),
        for (final seg in rec?.segments ?? const <RecordingSegment>[])
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              seg.completed ? Icons.check_circle : Icons.remove_circle_outline,
              color: seg.completed ? scheme.primary : scheme.outline,
            ),
            title: Text(
              '${seg.title} · ${_mmss(Duration(milliseconds: seg.endMs - seg.startMs))}',
            ),
            subtitle: seg.note == null ? null : Text(seg.note!),
          ),
        if (scan.dtcs.isNotEmpty)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.warning_amber, color: scheme.error),
            title: Text('Ошибки: ${scan.dtcs.join(', ')}'),
          ),
        const SizedBox(height: 16),
        if (failed && controller.canResume) ...[
          FilledButton.icon(
            onPressed: () => controller.reconnect().ignore(),
            icon: const Icon(Icons.refresh),
            label: const Text('Переподключить и продолжить'),
          ),
          const SizedBox(height: 4),
          Text(
            'Программа продолжится с того же этапа, записанное сохранится.',
            style: text.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
        ],
        (failed ? OutlinedButton.icon : FilledButton.icon)(
          onPressed: hasData
              ? () async {
                  await controller.finalize();
                  if (context.mounted) context.go('/ai');
                }
              : null,
          icon: const Icon(Icons.auto_awesome),
          label: Text(failed ? 'Разобрать записанное' : 'Разобрать с ИИ'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => context.go('/logs'),
          icon: const Icon(Icons.description_outlined),
          label: const Text('Журнал сеанса'),
        ),
        if (!hasData)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Данных не записано — разбирать нечего.'),
          ),
      ],
    );
  }
}

String _mmss(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
