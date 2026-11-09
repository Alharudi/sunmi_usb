import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'transport.dart';

/// Wi-Fi / LAN fallback link, also handy for testing on two ordinary phones.
/// The terminal listens ([TcpTransport.server]); the cashier connects ([TcpTransport.client]).
class TcpTransport extends TransportBase {
  TcpTransport.server({required this.port})
      : host = null,
        isServer = true;

  TcpTransport.client({required String this.host, required this.port}) : isServer = false;

  final String? host;
  final int port;
  final bool isServer;

  ServerSocket? _server;
  Socket? _socket;
  bool _running = false;
  Timer? _retry;

  @override
  String get name => isServer ? 'Wi-Fi (listening on :$port)' : 'Wi-Fi ($host:$port)';

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    if (isServer) {
      await _listen();
    } else {
      unawaited(_connect());
    }
  }

  Future<void> _listen() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      setState(TransportStatus.waiting, 'Waiting for the cashier on port $port');
      _server!.listen((socket) {
        if (_socket != null) {
          log('New cashier connection replaces the old one');
          _socket!.destroy();
        }
        _attach(socket);
      });
    } on SocketException catch (e) {
      setState(TransportStatus.error, 'Cannot listen on port $port: ${e.message}');
    }
  }

  Future<void> _connect() async {
    if (!_running || _socket != null) return;
    setState(TransportStatus.connecting, 'Connecting to $host:$port…');
    try {
      final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
      if (!_running) {
        socket.destroy();
        return;
      }
      _attach(socket);
    } on SocketException catch (e) {
      setState(TransportStatus.waiting, 'Terminal not reachable at $host:$port (${e.osError?.message ?? e.message})');
      _scheduleReconnect();
    }
  }

  void _attach(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    setState(TransportStatus.connected, 'Connected to ${socket.remoteAddress.address}');
    socket.listen(
      emitData,
      onError: (Object e) => log('Socket error: $e'),
      onDone: () => _onClosed(socket),
      cancelOnError: true,
    );
  }

  void _onClosed(Socket socket) {
    if (_socket != socket) return;
    _socket = null;
    if (!_running) return;
    if (isServer) {
      setState(TransportStatus.waiting, 'Cashier disconnected');
    } else {
      setState(TransportStatus.waiting, 'Connection lost');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), _connect);
  }

  @override
  Future<bool> send(Uint8List data) async {
    final s = _socket;
    if (s == null) return false;
    try {
      s.add(data);
      return true;
    } catch (e) {
      log('Send failed: $e');
      return false;
    }
  }

  @override
  Future<void> reset() async {
    _socket?.destroy();
  }

  @override
  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    _socket?.destroy();
    _socket = null;
    await _server?.close();
    _server = null;
    setState(TransportStatus.stopped);
  }
}
