import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../protocol/frame.dart';
import '../protocol/messages.dart';
import '../util.dart';
import 'transport.dart';

enum LinkStatus {
  /// Transport not connected (cable out, socket closed).
  offline,

  /// Transport connected, waiting for the other app's HELLO.
  handshaking,

  /// Both apps talking.
  online,

  /// Connected but the peer stopped answering heartbeats.
  stale,
}

class LinkConfig {
  const LinkConfig({
    this.ackTimeout = const Duration(milliseconds: 1500),
    this.maxRetries = 3,
    this.heartbeatInterval = const Duration(seconds: 3),
    this.staleAfter = const Duration(seconds: 10),
  });

  final Duration ackTimeout;
  final int maxRetries;
  final Duration heartbeatInterval;
  final Duration staleAfter;
}

class PeerInfo {
  PeerInfo(this.payload);

  final Map<String, dynamic> payload;

  String get role => payload['role'] as String? ?? '?';
  String get sessionId => payload['sessionId'] as String? ?? '';
  String get appVersion => payload['appVersion'] as String? ?? '?';
  String get description {
    final parts = [payload['manufacturer'], payload['model']].whereType<String>().where((s) => s.isNotEmpty);
    return parts.isEmpty ? 'Unknown device' : parts.join(' ');
  }
}

class LinkStats {
  int framesSent = 0;
  int framesReceived = 0;
  int retries = 0;
  int failedSends = 0;
  int duplicates = 0;

  /// Heartbeats skipped because the previous frames had not left the device yet.
  int heldHeartbeats = 0;
}

/// Reliable message channel on top of a [Transport].
///
/// * HELLO handshake (protocol version, role, device, session id) whenever the transport connects.
/// * Every application message is ACKed by sequence number and retried until acknowledged.
/// * Duplicates (retries whose ACK was lost) are ACKed again but delivered only once.
/// * PING every [LinkConfig.heartbeatInterval]; [LinkStatus.stale] after [LinkConfig.staleAfter]
///   of silence, and the transport is reset after twice that.
/// * Back-pressure: a USB accessory write blocks while the peer isn't reading. Heartbeats
///   (HELLO, PING, PONG) are skipped while earlier link frames are still in flight, and each
///   message has at most one copy in flight. A peer that comes back late gets a few frames, not
///   a backlog of every heartbeat it missed.
class LinkSession extends ChangeNotifier {
  LinkSession({required this.transport, required this.localInfo, this.config = const LinkConfig(), this.log});

  final Transport transport;
  final LinkConfig config;

  /// Sent to the peer in HELLO: role, manufacturer, model, appVersion.
  final Map<String, dynamic> localInfo;
  final AppLog? log;
  final String sessionId = uuidV4();
  final LinkStats stats = LinkStats();

  final _messages = StreamController<Message>.broadcast();
  final _online = StreamController<void>.broadcast();
  final _decoder = FrameDecoder();
  final Map<int, _PendingSend> _pending = {};
  final Queue<int> _recentSeqs = Queue<int>();
  final Set<int> _recentSet = <int>{};
  final List<StreamSubscription<dynamic>> _subs = [];

  LinkStatus _status = LinkStatus.offline;
  PeerInfo? _peer;
  String? _problem;
  int _nextSeq = 0;
  DateTime _lastRx = DateTime.now();
  bool _resetRequested = false;
  int _inFlight = 0;
  int _linkEpoch = 0;
  int _heldTicks = 0;
  Timer? _heartbeat;
  bool _started = false;
  bool _disposed = false;

  LinkStatus get status => _status;
  bool get isOnline => _status == LinkStatus.online;
  bool get canSend => _status == LinkStatus.online || _status == LinkStatus.stale;
  PeerInfo? get peer => _peer;

  /// A configuration problem that blocks the link (e.g. both devices set to the same role).
  String? get problem => _problem;
  TransportState get transportState => transport.state;
  int get crcErrors => _decoder.crcErrors;

  /// Application messages from the peer, each delivered once.
  Stream<Message> get messages => _messages.stream;

  /// Fires when the link becomes usable (first HELLO, or the peer app restarted).
  Stream<void> get onOnline => _online.stream;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _subs
      ..add(transport.states.listen(_onTransportState))
      ..add(transport.incoming.listen(_onBytes))
      ..add(transport.logs.listen((m) => log?.add(transport.name, m)));
    _heartbeat = Timer.periodic(config.heartbeatInterval, (_) => _tick());
    log?.add('link', 'Starting ${transport.name}');
    await transport.start();
    _onTransportState(transport.state);
  }

  Future<void> stop() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    await transport.stop();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _failAllPending();
    _setStatus(LinkStatus.offline);
  }

  @override
  void dispose() {
    _disposed = true;
    _heartbeat?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _failAllPending();
    _messages.close();
    _online.close();
    super.dispose();
  }

  /// Sends an application message. Completes with true once the peer acknowledged it,
  /// false if the link is down or no ACK arrived after all retries.
  Future<bool> send(MsgType type, [Map<String, dynamic> payload = const {}]) {
    assert(!type.isLinkLevel, 'Link-level messages are sent by the session itself');
    if (!canSend) {
      stats.failedSends++;
      _logLine('Not sent, link is ${_status.name}: ${type.name}');
      return Future.value(false);
    }
    final seq = _allocSeq();
    final pending = _PendingSend(type, encodeFrame(Frame(type: type.code, seq: seq, payload: _encode(payload))));
    _pending[seq] = pending;
    _logLine('→ ${type.name} #$seq ${jsonEncode(payload)}');
    _transmit(seq, pending);
    return pending.completer.future;
  }

  // ---------------------------------------------------------------------------

  void _transmit(int seq, _PendingSend p) {
    p.attempts++;
    // A retry only helps if the previous copy actually left; if it is still queued (peer not
    // reading), adding another copy just grows the backlog.
    if (!p.writing) {
      p.writing = true;
      _write(p.bytes, () => p.writing = false);
    }
    p.timer = Timer(config.ackTimeout, () {
      if (!identical(_pending[seq], p)) return;
      if (p.attempts > config.maxRetries) {
        _pending.remove(seq);
        stats.failedSends++;
        _logLine('✗ ${p.type.name} #$seq not acknowledged after ${p.attempts} attempts');
        p.complete(false);
        _notify();
      } else {
        stats.retries++;
        _logLine('↻ retry ${p.type.name} #$seq');
        _transmit(seq, p);
      }
    });
  }

  void _sendLinkLevel(MsgType type, int seq, [Map<String, dynamic> payload = const {}]) {
    _write(encodeFrame(Frame(type: type.code, seq: seq, payload: _encode(payload))));
  }

  /// Every write goes through here so [_backlogged] knows whether the pipe is draining.
  void _write(Uint8List bytes, [void Function()? onDone]) {
    stats.framesSent++;
    final epoch = _linkEpoch;
    _inFlight++;
    void done(Object? _) {
      if (epoch == _linkEpoch) _inFlight--;
      onDone?.call();
    }

    transport.send(bytes).then(done, onError: done);
  }

  /// Earlier frames have not left the device yet; heartbeats are only worth sending when the pipe drains.
  bool get _backlogged => _inFlight > 0;

  /// Forgets in-flight bookkeeping when the transport connects or drops; late completions from
  /// the previous connection are ignored.
  void _resetFlowControl() {
    _linkEpoch++;
    _inFlight = 0;
    _heldTicks = 0;
  }

  void _sendHello({required bool needReply}) {
    _sendLinkLevel(MsgType.hello, 0, {
      ...localInfo,
      'protocol': kProtocolVersion,
      'sessionId': sessionId,
      'needReply': needReply,
    });
  }

  void _onTransportState(TransportState s) {
    if (_disposed) return;
    if (s.isConnected) {
      if (_status == LinkStatus.offline) {
        _resetFlowControl();
        _decoder.reset();
        _lastRx = DateTime.now();
        _resetRequested = false;
        _setStatus(LinkStatus.handshaking);
        _sendHello(needReply: true);
      }
    } else if (_status != LinkStatus.offline) {
      _logLine('Link down (${s.detail ?? s.status.name})');
      _resetFlowControl();
      _setStatus(LinkStatus.offline);
      _failAllPending();
    }
    _notify();
  }

  void _onBytes(Uint8List data) {
    if (_disposed) return;
    if (_status == LinkStatus.offline && transport.state.isConnected) _onTransportState(transport.state);
    _lastRx = DateTime.now();
    _resetRequested = false;
    if (_status == LinkStatus.stale) {
      _logLine('Peer is answering again');
      _setStatus(LinkStatus.online);
    }
    final crcBefore = _decoder.crcErrors;
    for (final frame in _decoder.add(data)) {
      _onFrame(frame);
    }
    if (_decoder.crcErrors != crcBefore) {
      _logLine('Dropped ${_decoder.crcErrors - crcBefore} corrupted frame(s)');
      _notify();
    }
  }

  void _onFrame(Frame f) {
    stats.framesReceived++;
    final type = MsgType.fromCode(f.type);
    if (f.version != kProtocolVersion) {
      _logLine('Frame with protocol v${f.version} rejected');
      if (type == null || !type.isLinkLevel) {
        _sendLinkLevel(MsgType.nak, f.seq, {'code': ErrorCodes.unsupportedVersion});
      }
      return;
    }
    if (type == null) {
      _logLine('Unknown message type 0x${f.type.toRadixString(16)}');
      _sendLinkLevel(MsgType.nak, f.seq, {'code': ErrorCodes.unknownType});
      return;
    }
    switch (type) {
      case MsgType.ack:
        _pending.remove(f.seq)?.complete(true);
      case MsgType.nak:
        final p = _pending.remove(f.seq);
        _logLine('NAK for #${f.seq}: ${_decode(f.payload)}');
        p?.complete(false);
      case MsgType.ping:
        if (_backlogged) {
          stats.heldHeartbeats++;
        } else {
          _sendLinkLevel(MsgType.pong, f.seq);
        }
      case MsgType.pong:
        break;
      case MsgType.hello:
        _onHello(_decode(f.payload));
      default:
        _onAppFrame(type, f);
    }
  }

  void _onHello(Map<String, dynamic>? payload) {
    if (payload == null) return;
    final peer = PeerInfo(payload);
    if (payload['protocol'] != kProtocolVersion) {
      _setProblem(
        'The other device speaks protocol v${payload['protocol']}, this one v$kProtocolVersion. Update both apps.',
      );
      return;
    }
    if (peer.role == localInfo['role']) {
      _setProblem('Both devices are set to "${peer.role}". Change one of them in Settings.');
      return;
    }
    _setProblem(null);
    final newSession = _peer?.sessionId != peer.sessionId;
    _peer = peer;
    if (newSession) {
      _recentSeqs.clear();
      _recentSet.clear();
      _logLine('Peer: ${peer.description}, role ${peer.role}, app ${peer.appVersion}');
    }
    // While our frames are backlogged the peer will still get our earlier HELLO when it drains.
    if (payload['needReply'] == true) {
      if (_backlogged) {
        stats.heldHeartbeats++;
      } else {
        _sendHello(needReply: false);
      }
    }
    final wasOnline = _status == LinkStatus.online;
    _setStatus(LinkStatus.online);
    if (!wasOnline || newSession) _online.add(null);
    _notify();
  }

  void _onAppFrame(MsgType type, Frame f) {
    final payload = _decode(f.payload);
    if (payload == null) {
      _logLine('Bad JSON in ${type.name} #${f.seq}');
      _sendLinkLevel(MsgType.nak, f.seq, {'code': ErrorCodes.badPayload});
      return;
    }
    // Always ACK, even duplicates: the earlier ACK may have been lost.
    _sendLinkLevel(MsgType.ack, f.seq);
    if (_recentSet.contains(f.seq)) {
      stats.duplicates++;
      _logLine('Duplicate ${type.name} #${f.seq} ignored');
      return;
    }
    _recentSeqs.addLast(f.seq);
    _recentSet.add(f.seq);
    while (_recentSeqs.length > 256) {
      _recentSet.remove(_recentSeqs.removeFirst());
    }
    final message = Message(type, payload);
    _logLine('← ${type.name} #${f.seq} ${jsonEncode(payload)}');
    _messages.add(message);
  }

  void _tick() {
    if (_disposed || !transport.state.isConnected || _status == LinkStatus.offline) return;
    if (_backlogged) {
      stats.heldHeartbeats++;
      if (++_heldTicks == 2) _logLine('The other device is not reading the link; holding heartbeats');
    } else {
      _heldTicks = 0;
      switch (_status) {
        case LinkStatus.handshaking:
          _sendHello(needReply: true);
        case LinkStatus.online || LinkStatus.stale:
          _sendLinkLevel(MsgType.ping, 0);
        case LinkStatus.offline:
          return;
      }
    }
    final silence = DateTime.now().difference(_lastRx);
    if (_status == LinkStatus.online && silence > config.staleAfter) {
      _logLine('No answer from the other device for ${silence.inSeconds}s');
      _setStatus(LinkStatus.stale);
    }
    if (silence > config.staleAfter * 2 && !_resetRequested) {
      _resetRequested = true;
      _logLine('Resetting ${transport.name}');
      transport.reset();
    }
  }

  int _allocSeq() {
    _nextSeq = _nextSeq % 0xFFFF + 1; // 1..65535; 0 is used by link-level frames
    return _nextSeq;
  }

  void _failAllPending() {
    for (final p in _pending.values) {
      p.complete(false);
    }
    _pending.clear();
  }

  void _setStatus(LinkStatus s) {
    if (_status == s) return;
    _status = s;
    _notify();
  }

  void _setProblem(String? problem) {
    if (_problem == problem) return;
    _problem = problem;
    if (problem != null) _logLine(problem);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _logLine(String message) => log?.add('link', message);

  static Uint8List _encode(Map<String, dynamic> payload) =>
      payload.isEmpty ? Uint8List(0) : Uint8List.fromList(utf8.encode(jsonEncode(payload)));

  static Map<String, dynamic>? _decode(Uint8List bytes) {
    if (bytes.isEmpty) return <String, dynamic>{};
    try {
      final v = jsonDecode(utf8.decode(bytes));
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } on FormatException {
      return null;
    }
  }
}

class _PendingSend {
  _PendingSend(this.type, this.bytes);

  final MsgType type;
  final Uint8List bytes;
  final Completer<bool> completer = Completer<bool>();
  int attempts = 0;
  bool writing = false;
  Timer? timer;

  void complete(bool value) {
    timer?.cancel();
    if (!completer.isCompleted) completer.complete(value);
  }
}
