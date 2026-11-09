import 'dart:async';

import '../core/protocol/payloads.dart';
import '../core/util.dart';
import 'payment_adapter.dart';

/// Simulated card payment so the whole flow can be tested without a payment app.
/// The terminal screen calls [presentCard]; tests can set [autoOutcome] instead.
class MockPaymentAdapter extends PaymentAdapter {
  MockPaymentAdapter({
    this.autoOutcome,
    this.cardTimeout = const Duration(seconds: 60),
    this.stepDelay = const Duration(milliseconds: 900),
  });

  /// When set, a card is "presented" automatically with this outcome (approved or declined).
  final SaleOutcome? autoOutcome;
  final Duration cardTimeout;
  final Duration stepDelay;

  _MockSale? _active;

  @override
  String get name => 'Simulator';

  @override
  bool get isSimulator => true;

  bool get waitingForCard => _active != null && !_active!.cardPresented;

  @override
  Stream<PaymentEvent> sale(SaleRequest request) {
    _active?.finish(SaleOutcome.cancelled, message: 'Replaced by a new sale');
    final sale = _MockSale(request, stepDelay, () => _active = null);
    _active = sale;
    sale.controller.add(const PaymentStageChanged(PaymentStage.waitingCard));
    sale.timeout = Timer(cardTimeout, () => sale.finish(SaleOutcome.timeout, message: 'No card presented'));
    final auto = autoOutcome;
    if (auto != null) {
      Timer(stepDelay, () => sale.present(approve: auto == SaleOutcome.approved));
    }
    return sale.controller.stream;
  }

  /// Simulates the customer tapping/inserting a card.
  void presentCard({required bool approve}) => _active?.present(approve: approve);

  @override
  bool cancel(String txnId) {
    final sale = _active;
    if (sale == null || sale.request.txnId != txnId || sale.cardPresented) return false;
    sale.finish(SaleOutcome.cancelled, message: 'Cancelled');
    return true;
  }
}

class _MockSale {
  _MockSale(this.request, this.stepDelay, this.onDone);

  final SaleRequest request;
  final Duration stepDelay;
  final void Function() onDone;
  final controller = StreamController<PaymentEvent>();
  Timer? timeout;
  bool cardPresented = false;
  bool done = false;

  Future<void> present({required bool approve}) async {
    if (cardPresented || done) return;
    cardPresented = true;
    timeout?.cancel();
    for (final stage in [PaymentStage.cardRead, PaymentStage.pinEntry, PaymentStage.authorizing]) {
      if (done) return;
      controller.add(PaymentStageChanged(stage));
      await Future<void>.delayed(stepDelay);
    }
    if (approve) {
      finish(SaleOutcome.approved, responseCode: '00', message: 'Approved', authCode: randomDigits(6));
    } else {
      finish(SaleOutcome.declined, responseCode: '05', message: 'Do not honour');
    }
  }

  void finish(SaleOutcome outcome, {String? responseCode, String? message, String? authCode}) {
    if (done) return;
    done = true;
    timeout?.cancel();
    final carded = cardPresented;
    controller.add(PaymentFinished(SaleResult(
      txnId: request.txnId,
      outcome: outcome,
      amount: request.amount,
      currency: request.currency,
      timestamp: DateTime.now(),
      responseCode: responseCode,
      message: message,
      authCode: authCode,
      rrn: carded ? randomDigits(12) : null,
      stan: carded ? randomDigits(6) : null,
      maskedPan: carded ? '476173******0119' : null,
      cardScheme: carded ? 'VISA' : null,
      terminalId: 'SIM00001',
      merchantId: 'SIMMERCHANT001',
    )));
    controller.close();
    onDone();
  }
}
