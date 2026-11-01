// Симулятор Wi-Fi адаптера ELM327 на ПК — проверить подключение по Wi-Fi без машины.
//
//   dart run scan_core:sim_server --scenario vacuumLeak [--port 35000]
//
// В приложении: «Wi-Fi адаптер», адрес 10.0.2.2 для эмулятора Android
// или IP компьютера для телефона в той же сети (и разрешить порт в брандмауэре).
import 'dart:io';

import 'package:scan_core/scan_core.dart';

Future<void> main(List<String> args) async {
  String? option(String name) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final scenario = SimScenario.values.firstWhere(
    (s) => s.name == (option('scenario') ?? 'healthy'),
    orElse: () {
      stderr.writeln(
        'Сценарии: ${SimScenario.values.map((s) => s.name).join(', ')}',
      );
      exit(64);
    },
  );
  final server = await SimServer.start(
    scenario: scenario,
    address: InternetAddress.anyIPv4,
    port: int.tryParse(option('port') ?? '') ?? TcpTransport.defaultPort,
    // Как у настоящего клона: ответ не мгновенный.
    latency: const Duration(milliseconds: 40),
  );
  stdout.writeln(
    'Симулятор ELM327 «${scenario.title}» слушает порт ${server.port}. Ctrl+C — выход.',
  );
}
