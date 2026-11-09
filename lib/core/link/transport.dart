import 'dart:async';
import 'dart:typed_data';

enum TransportStatus { stopped, waiting, permission, connecting, connected, error }

class TransportState {
  const TransportState(this.status, [this.detail]);

  static const stopped = TransportState(TransportStatus.stopped);

  final TransportStatus status;
  final String? detail;

  bool get isConnected => status == TransportStatus.connected;

  @override
  String toString() => detail == null ? status.name : '${status.name}: $detail';
}

/// A raw, ordered byte pipe to the other device (USB accessory, TCP, in-memory).
/// Framing, acknowledgements and heartbeats are handled above it by LinkSession.
abstract class Transport {
  String get name;
  TransportState get state;
  Stream<TransportState> get states;
  Stream<Uint8List> get incoming;
  Stream<String> get logs;

  Future<void> start();
  Future<void> stop();

  /// Returns false when the bytes could not be handed to the link.
  Future<bool> send(Uint8List data);

  /// Drop the current connection and reconnect (used when the peer stops answering).
  Future<void> reset();
}

/// Shared stream plumbing for transports.
abstract class TransportBase implements Transport {
  final _states = StreamController<TransportState>.broadcast();
  final _incoming = StreamController<Uint8List>.broadcast();
  final _logs = StreamController<String>.broadcast();
  TransportState _state = TransportState.stopped;

  @override
  TransportState get state => _state;
  @override
  Stream<TransportState> get states => _states.stream;
  @override
  Stream<Uint8List> get incoming => _incoming.stream;
  @override
  Stream<String> get logs => _logs.stream;

  void setState(TransportStatus status, [String? detail]) {
    if (status == _state.status && detail == _state.detail) return;
    _state = TransportState(status, detail);
    if (!_states.isClosed) _states.add(_state);
  }

  void emitData(Uint8List data) {
    if (!_incoming.isClosed) _incoming.add(data);
  }

  void log(String message) {
    if (!_logs.isClosed) _logs.add(message);
  }

  Future<void> closeStreams() async {
    await _states.close();
    await _incoming.close();
    await _logs.close();
  }
}
