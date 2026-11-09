import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/link/link_session.dart';
import '../../core/protocol/messages.dart';
import '../../core/protocol/payloads.dart';
import '../../core/util.dart';
import '../../data/transaction_store.dart';

enum CashierPhase {
  idle,
  sending,
  waitingCard,
  processing,
  result,

  /// Terminal refused the sale before any card was read. Safe to charge again.
  failed,

  /// Outcome unknown (link lost, no answer). Never assume declined: check status first.
  attention,
}

/// Cashier (Flex 3) side of a sale.
class CashierController extends ChangeNotifier {
  CashierController({
    required this.session,
    required this.store,
    required this.currency,
    this.log,
    this.noResponseTimeout = const Duration(seconds: 150),
  });

  final LinkSession session;
  final TransactionStore store;
  final String currency;
  final AppLog? log;
  final Duration noResponseTimeout;

  CashierPhase _phase = CashierPhase.idle;
  SaleRequest? _current;
  PaymentStage? _stage;
  SaleResult? _result;
  String? _message;
  String? _terminalState;
  bool _wasConnected = false;
  Timer? _watchdog;
  StreamSubscription<Message>? _messagesSub;
  StreamSubscription<void>? _onlineSub;
  bool _disposed = false;

  CashierPhase get phase => _phase;
  SaleRequest? get current => _current;
  PaymentStage? get stage => _stage;
  SaleResult? get result => _result;
  String? get message => _message;

  /// "idle" or "busy" as last reported by the terminal.
  String? get terminalState => _terminalState;
  bool get canCharge => _phase == CashierPhase.idle && session.isOnline;
  bool get canCancel => _phase == CashierPhase.sending || _phase == CashierPhase.waitingCard;
  bool get inFlight =>
      _phase == CashierPhase.sending || _phase == CashierPhase.waitingCard || _phase == CashierPhase.processing;

  Future<void> start() async {
    final last = store.recent.firstOrNull;
    if (last != null &&
        (last.state == TxnState.pending || last.state == TxnState.inProgress || last.state == TxnState.unknown)) {
      _current = last.request;
      _phase = CashierPhase.attention;
      _message = 'The last sale has no final result yet. Checking with the terminal…';
    }
    _messagesSub = session.messages.listen(_onMessage);
    _onlineSub = session.onOnline.listen((_) => _onOnline());
    session.addListener(_onSessionChanged);
    _wasConnected = session.canSend;
    if (session.isOnline) unawaited(_onOnline());
  }

  @override
  void dispose() {
    _disposed = true;
    _watchdog?.cancel();
    _messagesSub?.cancel();
    _onlineSub?.cancel();
    session.removeListener(_onSessionChanged);
    super.dispose();
  }

  // ---- actions from the cashier screen ----

  Future<void> charge(int amount, {String? reference}) async {
    if (_phase != CashierPhase.idle) return;
    if (!session.isOnline) {
      _setMessage('Terminal not connected');
      return;
    }
    final req = SaleRequest(
      txnId: uuidV4(),
      amount: amount,
      currency: currency,
      reference: reference,
      createdAt: DateTime.now(),
    );
    _current = req;
    _stage = null;
    _result = null;
    _message = null;
    _setPhase(CashierPhase.sending);
    await store.put(TxnRecord(request: req, state: TxnState.pending));
    _armWatchdog();
    final delivered = await session.send(MsgType.saleRequest, req.toJson());
    if (!delivered && _isCurrent(req.txnId) && _phase == CashierPhase.sending) {
      await _markUnknown('The terminal did not confirm the sale. Check status before charging again.');
    }
  }

  Future<void> cancel() async {
    final c = _current;
    if (c == null || !canCancel) return;
    _setMessage('Cancelling…');
    final ok = await session.send(MsgType.cancel, {'txnId': c.txnId});
    if (!ok) _setMessage('Cancel request not delivered');
  }

  Future<void> checkStatus() async {
    final c = _current;
    if (c == null) return;
    if (!session.canSend) {
      _setMessage('Terminal not connected. Status will be checked when it reconnects.');
      return;
    }
    _setMessage('Checking with the terminal…');
    final ok = await session.send(MsgType.txnStatusQuery, {'txnId': c.txnId});
    if (!ok && _isCurrent(c.txnId)) _setMessage('The terminal did not answer. Try again.');
  }

  /// Back to the keypad after a final result or a refusal.
  void newSale() {
    if (_phase != CashierPhase.result && _phase != CashierPhase.failed) return;
    _reset();
  }

  /// Leave an unknown sale after the operator checked the terminal report by hand.
  Future<void> closeUnknown() async {
    final c = _current;
    if (c != null) {
      final r = store.get(c.txnId);
      if (r != null && r.state != TxnState.completed) {
        await store.put(r.copyWith(state: TxnState.unknown, note: 'Closed by cashier without a result'));
      }
    }
    _reset();
  }

  // ---- protocol ----

  void _onMessage(Message m) {
    final txnId = m.txnId;
    switch (m.type) {
      case MsgType.status:
        _terminalState = m.payload['state'] as String?;
        _notify();
      case MsgType.readyToPay:
        if (_isCurrent(txnId) && (_phase == CashierPhase.sending || _phase == CashierPhase.attention)) {
          _stage = PaymentStage.waitingCard;
          _message = null;
          _setPhase(CashierPhase.waitingCard);
          _armWatchdog();
          _updateRecordState(txnId!, TxnState.inProgress);
        }
      case MsgType.progress:
        if (_isCurrent(txnId) && _phase != CashierPhase.result) {
          _applyStage(paymentStageFromName(m.payload['stage']));
          _updateRecordState(txnId!, TxnState.inProgress);
        }
      case MsgType.saleResult:
        _applyResult(SaleResult.fromJson(m.payload));
      case MsgType.txnStatus:
        _onTxnStatus(m.payload);
      case MsgType.error:
        _onError(m.payload);
      default:
        _log('Ignoring ${m.type.name}');
    }
  }

  void _applyStage(PaymentStage stage) {
    _stage = stage;
    _message = null;
    _armWatchdog();
    _setPhase(stage == PaymentStage.waitingCard ? CashierPhase.waitingCard : CashierPhase.processing);
  }

  void _applyResult(SaleResult r) {
    final record = store.get(r.txnId);
    if (record != null) {
      store.put(record.copyWith(state: TxnState.completed, result: r));
    } else {
      _log('Result for a sale this cashier does not know: ${r.txnId}');
      store.put(TxnRecord(
        request: SaleRequest(txnId: r.txnId, amount: r.amount, currency: r.currency, createdAt: r.timestamp),
        state: TxnState.completed,
        result: r,
      ));
    }
    if (_isCurrent(r.txnId)) {
      _watchdog?.cancel();
      _result = r;
      _stage = null;
      _message = null;
      _setPhase(CashierPhase.result);
    }
  }

  void _onTxnStatus(Map<String, dynamic> p) {
    final txnId = p['txnId'] as String?;
    final state = txnStatusStateFromName(p['state']);
    if (state == TxnStatusState.completed && p['result'] is Map) {
      _applyResult(SaleResult.fromJson(Map<String, dynamic>.from(p['result'] as Map)));
      return;
    }
    if (!_isCurrent(txnId)) return;
    switch (state) {
      case TxnStatusState.completed:
        break;
      case TxnStatusState.inProgress:
        _applyStage(paymentStageFromName(p['stage'] ?? PaymentStage.waitingCard.name));
      case TxnStatusState.notFound:
        _refuse(txnId!, 'The terminal never received this sale. No money was taken; you can charge again.');
      case TxnStatusState.interrupted:
        _markUnknown("The terminal was restarted during this payment. Check the terminal's transaction report.");
    }
  }

  void _onError(Map<String, dynamic> p) {
    final code = p['code'] as String?;
    final text = p['message'] as String? ?? code ?? 'Terminal error';
    final txnId = p['txnId'] as String?;
    if (!_isCurrent(txnId)) {
      _log('Terminal error for another sale: $code $text');
      return;
    }
    switch (code) {
      case ErrorCodes.busy:
        _refuse(txnId!, 'The terminal is busy with another payment.');
      case ErrorCodes.badRequest:
        _refuse(txnId!, 'The terminal rejected the sale: $text');
      case ErrorCodes.txnInterrupted:
        _markUnknown(text);
      case ErrorCodes.cannotCancel:
        _setMessage('Too late to cancel: the card was already presented.');
      default:
        _setMessage(text);
    }
  }

  Future<void> _onOnline() async {
    _wasConnected = true;
    if (_current != null &&
        (inFlight || _phase == CashierPhase.attention)) {
      await checkStatus();
    }
  }

  void _onSessionChanged() {
    final connected = session.canSend;
    if (_wasConnected && !connected && (inFlight || _phase == CashierPhase.attention)) {
      _setMessage('Connection lost. The payment may still finish on the terminal; '
          'its result will be fetched when the link is back.');
    }
    _wasConnected = connected;
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(noResponseTimeout, () {
      if (inFlight) {
        _markUnknown('No update from the terminal for ${noResponseTimeout.inSeconds}s. Check status.');
      }
    });
  }

  Future<void> _markUnknown(String message) async {
    _watchdog?.cancel();
    final c = _current;
    if (c != null) _updateRecordState(c.txnId, TxnState.unknown);
    _message = message;
    _setPhase(CashierPhase.attention);
  }

  void _refuse(String txnId, String message) {
    _watchdog?.cancel();
    _updateRecordState(txnId, TxnState.rejected, note: message);
    _message = message;
    _setPhase(CashierPhase.failed);
  }

  void _updateRecordState(String txnId, TxnState state, {String? note}) {
    final r = store.get(txnId);
    if (r == null || r.state == TxnState.completed || (r.state == state && note == null)) return;
    store.put(r.copyWith(state: state, note: note));
  }

  void _reset() {
    _watchdog?.cancel();
    _current = null;
    _stage = null;
    _result = null;
    _message = null;
    _setPhase(CashierPhase.idle);
  }

  bool _isCurrent(String? txnId) => txnId != null && _current?.txnId == txnId;

  void _setPhase(CashierPhase p) {
    _phase = p;
    _notify();
  }

  void _setMessage(String? m) {
    _message = m;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _log(String message) => log?.add('cashier', message);
}
