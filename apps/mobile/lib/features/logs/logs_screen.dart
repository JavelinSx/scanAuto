import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/session_log.dart';

/// Журналы сеансов и записи в JSON. Отсюда их пересылают (Telegram, почта)
/// для разбора реального прогона на компьютере.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  late Future<(String, List<File>)> _files = _load();

  Future<(String, List<File>)> _load() async =>
      ((await FileSessionLog.directory()).path, await FileSessionLog.list());

  /// Журнал и запись одного сеанса уходят вместе.
  Future<void> _share(File log) async {
    final json = File(log.path.replaceFirst(RegExp(r'\.log$'), '.json'));
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(log.path, mimeType: 'text/plain'),
          if (await json.exists())
            XFile(json.path, mimeType: 'application/json'),
        ],
        subject: 'scanAuto: ${log.uri.pathSegments.last}',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Журналы сеансов'),
        leading: BackButton(onPressed: () => context.go('/')),
      ),
      body: FutureBuilder(
        future: _files,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Журналы недоступны: ${snap.error}'));
          }
          final (dir, files) = snap.data!;
          final logs = [
            for (final f in files)
              if (f.path.endsWith('.log')) f,
          ];
          return RefreshIndicator(
            onRefresh: () async {
              setState(() => _files = _load());
              await _files;
            },
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'В журнале — весь обмен с адаптером, этапы программы и ошибки; '
                  'рядом — запись в JSON. VIN и ключ ИИ туда не попадают. '
                  'Нажмите «Поделиться» и отправьте себе, '
                  'или заберите по USB из папки:\n$dir',
                  style: text.bodySmall,
                ),
                const SizedBox(height: 12),
                if (logs.isEmpty) const Text('Журналов пока нет.'),
                for (final f in logs)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.description_outlined),
                    title: Text(f.uri.pathSegments.last),
                    subtitle: Text(
                      '${(f.lengthSync() / 1024).toStringAsFixed(0)} КБ',
                    ),
                    trailing: IconButton(
                      tooltip: 'Поделиться',
                      icon: const Icon(Icons.share),
                      onPressed: () => _share(f),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
