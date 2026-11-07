import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:scan_core/scan_core.dart';

/// Журнал сеанса для разбора реальных прогонов: подключение, весь обмен с ELM327
/// (TX — команда, RX — сырой ответ), этапы программы, ошибки, запрос к ИИ.
/// Рядом сохраняется запись в JSON (`scanauto.recording`), её читает demo и MCP.
/// Ключ ИИ и VIN в журнал не пишутся.
abstract interface class SessionLog {
  void write(String tag, String message);
  Future<void> saveRecording(Recording recording);
  Future<void> close();
}

final class NoopSessionLog implements SessionLog {
  const NoopSessionLog();

  @override
  void write(String tag, String message) {}

  @override
  Future<void> saveRecording(Recording recording) async {}

  @override
  Future<void> close() async {}
}

final class FileSessionLog implements SessionLog {
  FileSessionLog._(this.file, this._sink) {
    // Сбрасываем на диск регулярно: при падении приложения журнал нужнее всего.
    _flush = Timer.periodic(const Duration(seconds: 3), (_) => _sink.flush());
  }

  /// Папка доступна с компьютера по USB: Android/data/ru.scanauto/files/logs.
  static Future<Directory> directory() async {
    final base =
        await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    return Directory('${base.path}/logs').create(recursive: true);
  }

  static Future<FileSessionLog> create() async {
    final dir = await directory();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final name =
        'scanauto-${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final file = File('${dir.path}/$name.log');
    return FileSessionLog._(file, file.openWrite(mode: FileMode.append));
  }

  /// Журналы и записи, новые сверху.
  static Future<List<File>> list() async {
    final dir = await directory();
    final files = await dir.list().where((e) => e is File).cast<File>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  final File file;
  final IOSink _sink;
  late final Timer _flush;
  final _started = DateTime.now();
  bool _closed = false;

  @override
  void write(String tag, String message) {
    if (_closed) return;
    final now = DateTime.now();
    final t = (now.difference(_started).inMilliseconds / 1000).toStringAsFixed(
      3,
    );
    _sink.writeln('${now.toIso8601String()} +${t}s [$tag] $message');
  }

  @override
  Future<void> saveRecording(Recording recording) async {
    final out = File(file.path.replaceFirst(RegExp(r'\.log$'), '.json'));
    final json = recording.toJson();
    // VIN — персональные данные: в файлы, которые пересылают, не кладём.
    if (json['vehicle'] case final Map<String, Object?> vehicle) {
      vehicle['vin'] = null;
    }
    await out.writeAsString(jsonEncode(json));
    write('session', 'запись сохранена: ${out.path}');
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _flush.cancel();
    await _sink.flush();
    await _sink.close();
  }
}

/// Не открылся файл (нет хранилища, тесты) — журнал молча выключается.
final sessionLogFactoryProvider = Provider<Future<SessionLog> Function()>(
  (ref) => () async {
    try {
      return await FileSessionLog.create();
    } on Object {
      return const NoopSessionLog();
    }
  },
);
