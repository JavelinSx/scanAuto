import 'dart:io';

/// Байтовый канал до адаптера: Bluetooth SPP, BLE, Wi-Fi (TCP) или симулятор.
/// [Elm327] подписывается на [input] один раз.
abstract interface class ObdTransport {
  Stream<List<int>> get input;
  Future<void> write(List<int> bytes);
  Future<void> close();
}

/// Wi-Fi адаптер: телефон подключается к сети адаптера, адаптер слушает TCP.
/// У большинства клонов адрес 192.168.0.10:35000.
final class TcpTransport implements ObdTransport {
  TcpTransport._(this._socket);

  static const defaultHost = '192.168.0.10';
  static const defaultPort = 35000;

  static Future<TcpTransport> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return TcpTransport._(socket);
  }

  final Socket _socket;

  @override
  Stream<List<int>> get input => _socket;

  @override
  Future<void> write(List<int> bytes) async {
    _socket.add(bytes);
    await _socket.flush();
  }

  @override
  Future<void> close() async {
    await _socket.close();
    _socket.destroy();
  }
}
