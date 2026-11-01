import 'dart:io';

import 'sim_engine.dart';
import 'simulated_elm327.dart';

/// Wi-Fi «адаптер» на TCP: каждое подключение получает свой [SimulatedElm327].
/// В тестах — путь через настоящий сокет; на ПК — адаптер для приложения
/// в эмуляторе (адрес 10.0.2.2) или на телефоне в той же сети (bin/sim_server.dart).
final class SimServer {
  SimServer._(this._server, this.scenario);

  /// [port] 0 — любой свободный.
  static Future<SimServer> start({
    SimScenario scenario = SimScenario.healthy,
    Object? address,
    int port = 0,
    Duration latency = Duration.zero,
  }) async {
    final server = await ServerSocket.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    final sim = SimServer._(server, scenario);
    server.listen((socket) {
      final elm = SimulatedElm327(scenario: scenario, latency: latency);
      sim._connections++;
      elm.input.listen(socket.add, onDone: socket.destroy);
      socket.listen(
        (bytes) => elm.write(bytes),
        onDone: elm.close,
        onError: (Object _) => elm.close(),
      );
    });
    return sim;
  }

  final ServerSocket _server;
  final SimScenario scenario;
  int _connections = 0;

  String get host => _server.address.address;
  int get port => _server.port;
  int get connections => _connections;

  Future<void> close() => _server.close();
}
