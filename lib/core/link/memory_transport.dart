import 'dart:async';
import 'dart:typed_data';

import 'transport.dart';

/// Two transports wired to each other in memory. Used by tests to run the cashier and the
/// terminal in one process, with optional packet loss and disconnects.
class MemoryTransportPair {
  MemoryTransportPair() {
    a = MemoryTransport._('A');
    b = MemoryTransport._('B');
    a._peer = b;
    b._peer = a;
  }

  late final MemoryTransport a;
  late final MemoryTransport b;

  /// Simulates pulling the cable.
  void disconnect() {
    a._setConnected(false);
    b._setConnected(false);
  }

  /// Simulates plugging it back in.
  void reconnect() {
    if (a._running && b._running) {
      a._setConnected(true);
      b._setConnected(true);
    }
  }
}

class MemoryTransport extends TransportBase {
  MemoryTransport._(this._label);

  final String _label;
  late MemoryTransport _peer;
  bool _running = false;
  bool _connected = false;

  /// Drop the next N outgoing sends (they report success, like a lost packet).
  int dropNext = 0;

  List<(Uint8List, Completer<bool>)>? _held;

  /// Like a USB accessory whose host stopped reading: sends neither arrive nor complete
  /// until [unstall].
  void stall() => _held ??= [];

  /// Frames sent while stalled that are still waiting to leave.
  int get heldFrames => _held?.length ?? 0;

  /// Delivers the held frames in order and completes their sends.
  void unstall() {
    final held = _held;
    _held = null;
    for (final (data, done) in held ?? const <(Uint8List, Completer<bool>)>[]) {
      if (_connected && _peer._connected) _peer.emitData(data);
      done.complete(_connected);
    }
  }

  @override
  String get name => 'memory $_label';

  @override
  Future<void> start() async {
    _running = true;
    setState(TransportStatus.waiting);
    if (_peer._running) {
      _setConnected(true);
      _peer._setConnected(true);
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    _setConnected(false);
    _peer._setConnected(false);
    setState(TransportStatus.stopped);
  }

  @override
  Future<bool> send(Uint8List data) async {
    if (!_connected) return false;
    if (dropNext > 0) {
      dropNext--;
      return true;
    }
    final copy = Uint8List.fromList(data);
    final held = _held;
    if (held != null) {
      final done = Completer<bool>();
      held.add((copy, done));
      return done.future;
    }
    scheduleMicrotask(() {
      if (_connected && _peer._connected) _peer.emitData(copy);
    });
    return true;
  }

  @override
  Future<void> reset() async {}

  void _setConnected(bool value) {
    if (_connected == value) return;
    _connected = value;
    if (!value && _held != null) {
      for (final (_, done) in _held!) {
        done.complete(false);
      }
      _held!.clear();
    }
    if (_running) setState(value ? TransportStatus.connected : TransportStatus.waiting);
  }
}
