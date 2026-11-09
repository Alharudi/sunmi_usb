import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/link/link_session.dart';
import '../../core/protocol/messages.dart';
import '../../core/protocol/payloads.dart';
import '../../core/util.dart';
import '../../data/transaction_store.dart';
import '../../payment/mock_payment_adapter.dart';
import '../../payment/payment_adapter.dart';

enum TerminalPhase { idle, waitingCard, processing, result }

/// Terminal (P3) state machine.
///
/// Rules that protect against double charges:
///  * a txnId is charged at most once; a repeated SALE_REQUEST gets the stored outcome back,
///  * only one sale runs at a time; another txnId meanwhile gets ERROR BUSY,
///  * a result the cashier did not acknowledge is re-sent when the link comes back.
class TerminalController extends ChangeNotifier {
  TerminalController({
    required this.session,
    required this.store,
    required this.payment,
    this.log,
    this.resultHold = const Duration(seconds: 6),
  });

  final LinkSession session;
  final TransactionStore store;
  final PaymentAdapter payment;
  final AppLog? log;
  final Duration resultHold;

  TerminalPhase _phase = TerminalPhase.idle;
  SaleRequest? _current;
  PaymentStage? _stage;
  SaleResult? _lastResult;
  StreamSubscription<Message>? _messagesSub;
  StreamSubscription<void>? _onlineSub;
  StreamSubscription<PaymentEvent>? _paymentSub;
  Timer? _resultTimer;
  bool _disposed = false;

  TerminalPhase get phase => _phase;
  SaleRequest? get current => _current;
  PaymentStage? get stage => _stage;
  SaleResult? get lastResult => _lastResult;
  bool get busy => _phase == TerminalPhase.waitingCard || _phase == TerminalPhase.processing;
  bool get canSimulateCard => payment.isSimulator && _phase == TerminalPhase.waitingCard;

  Future<void> start() async {
    // Payments that were running when the app died have an unknown outcome.
    for (final r in store.recent.where((r) => r.state == TxnState.inProgress)) {
      await store.put(r.copyWith(state: TxnState.unknown, note: 'App restarted during payment'));
    }
    _messagesSub = session.messages.listen(_onMessage);
    _onlineSub = session.onOnline.listen((_) => _onOnline());
  }

  @override
  void dispose() {
    _disposed = true;
    _messagesSub?.cancel();
    _onlineSub?.cancel();
    _paymentSub?.cancel();
    _resultTimer?.cancel();
    super.dispose();
  }

  // ---- actions from the terminal screen ----

  void presentCard({required bool approve}) {
    final p = payment;
    if (p is MockPaymentAdapter) p.presentCard(approve: approve);
  }

  void cancelOnTerminal() {
    final c = _current;
    if (c != null && !payment.cancel(c.txnId)) _log('Too late to cancel: card already presented');
  }

  void dismissResult() {
    if (_phase != TerminalPhase.result) return;
    _resultTimer?.cancel();
    _setPhase(TerminalPhase.idle);
  }

  // ---- protocol ----

  void _onMessage(Message m) {
    switch (m.type) {
      case MsgType.saleRequest:
        _onSaleRequest(SaleRequest.fromJson(m.payload));
      case MsgType.cancel:
        _onCancel(m.txnId ?? '');
      case MsgType.txnStatusQuery:
        _onStatusQuery(m.txnId ?? '');
      default:
        _log('Ignoring ${m.type.name}');
    }
  }

  Future<void> _onSaleRequest(SaleRequest req) async {
    final invalid = req.validate();
    if (invalid != null) {
      await _sendError(ErrorCodes.badRequest, invalid, req.txnId);
      return;
    }

    final existing = store.get(req.txnId);
    if (existing != null) {
      switch (existing.state) {
        case TxnState.completed:
          _log('Duplicate sale ${req.txnId}: re-sending stored result, card NOT charged again');
          await _deliverResult(existing.result!);
        case TxnState.inProgress || TxnState.pending:
          if (_current?.txnId == req.txnId) {
            await session.send(MsgType.progress, {'txnId': req.txnId, 'stage': (_stage ?? PaymentStage.waitingCard).name});
          }
        case TxnState.unknown || TxnState.rejected:
          await _sendError(ErrorCodes.txnInterrupted,
              'This sale was interrupted on the terminal. Check the terminal report before retrying.', req.txnId);
      }
      return;
    }

    if (busy) {
      await _sendError(ErrorCodes.busy, 'Terminal is busy with another payment', req.txnId);
      return;
    }

    _resultTimer?.cancel();
    _current = req;
    _stage = PaymentStage.waitingCard;
    _lastResult = null;
    _setPhase(TerminalPhase.waitingCard);
    await store.put(TxnRecord(request: req, state: TxnState.inProgress));
    unawaited(session.send(MsgType.readyToPay, {'txnId': req.txnId, 'amount': req.amount, 'currency': req.currency}));
    unawaited(_sendStatus());

    _paymentSub = payment.sale(req).listen((event) {
      switch (event) {
        case PaymentStageChanged(:final stage):
          _stage = stage;
          _setPhase(stage == PaymentStage.waitingCard ? TerminalPhase.waitingCard : TerminalPhase.processing);
          unawaited(session.send(MsgType.progress, {'txnId': req.txnId, 'stage': stage.name}));
        case PaymentFinished(:final result):
          unawaited(_finish(req, result));
      }
    });
  }

  Future<void> _finish(SaleRequest req, SaleResult result) async {
    _paymentSub = null;
    _current = null;
    _stage = null;
    _lastResult = result;
    await store.put(TxnRecord(request: req, state: TxnState.completed, result: result));
    _setPhase(TerminalPhase.result);
    _resultTimer = Timer(resultHold, dismissResult);
    await _deliverResult(result);
    unawaited(_sendStatus());
  }

  Future<void> _deliverResult(SaleResult result) async {
    final ok = await session.send(MsgType.saleResult, result.toJson());
    final record = store.get(result.txnId);
    if (ok && record != null && !record.resultDelivered) {
      await store.put(record.copyWith(resultDelivered: true));
    }
    if (!ok) _log('Result for ${result.txnId} not acknowledged; will re-send when the cashier reconnects');
  }

  Future<void> _onCancel(String txnId) async {
    if (_current?.txnId == txnId) {
      // On success the payment stream finishes with CANCELLED and the result goes out normally.
      if (!payment.cancel(txnId)) {
        await _sendError(ErrorCodes.cannotCancel, 'Card already presented; wait for the result', txnId);
      }
      return;
    }
    final r = store.get(txnId);
    if (r?.state == TxnState.completed) {
      await _deliverResult(r!.result!);
    } else {
      await _sendError(ErrorCodes.unknownTxn, 'No running sale with this id', txnId);
    }
  }

  Future<void> _onStatusQuery(String txnId) async {
    final r = store.get(txnId);
    final state = switch (r?.state) {
      null => TxnStatusState.notFound,
      TxnState.completed => TxnStatusState.completed,
      TxnState.inProgress || TxnState.pending => TxnStatusState.inProgress,
      TxnState.unknown || TxnState.rejected => TxnStatusState.interrupted,
    };
    final ok = await session.send(MsgType.txnStatus, {
      'txnId': txnId,
      'state': state.name,
      if (state == TxnStatusState.completed) 'result': r!.result!.toJson(),
      if (state == TxnStatusState.inProgress && _stage != null) 'stage': _stage!.name,
    });
    if (ok && state == TxnStatusState.completed && !r!.resultDelivered) {
      await store.put(r.copyWith(resultDelivered: true));
    }
  }

  Future<void> _onOnline() async {
    await _sendStatus();
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    final undelivered = store.recent
        .where((r) => r.state == TxnState.completed && !r.resultDelivered && r.updatedAt.isAfter(cutoff))
        .take(10)
        .toList();
    for (final r in undelivered) {
      _log('Re-sending undelivered result for ${r.txnId}');
      await _deliverResult(r.result!);
    }
  }

  Future<void> _sendStatus() => session.send(MsgType.status, {'state': busy ? 'busy' : 'idle'});

  Future<void> _sendError(String code, String message, String? txnId) =>
      session.send(MsgType.error, {'code': code, 'message': message, 'txnId': ?txnId});

  void _setPhase(TerminalPhase p) {
    _phase = p;
    if (!_disposed) notifyListeners();
  }

  void _log(String message) => log?.add('terminal', message);
}
