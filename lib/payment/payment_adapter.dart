import '../core/protocol/payloads.dart';

sealed class PaymentEvent {
  const PaymentEvent();
}

class PaymentStageChanged extends PaymentEvent {
  const PaymentStageChanged(this.stage);
  final PaymentStage stage;
}

class PaymentFinished extends PaymentEvent {
  const PaymentFinished(this.result);
  final SaleResult result;
}

/// The thing on the terminal that actually charges the card.
///
/// Implementations planned:
///  * [MockPaymentAdapter] – simulator, available now.
///  * Bank / acquirer payment app – launched by Intent or AIDL, result mapped to [SaleResult].
///  * Sunmi PayLib – own EMV kernel (needs keys and certification).
abstract class PaymentAdapter {
  String get name;

  /// True for the simulator: the terminal screen then shows "simulate card" buttons.
  bool get isSimulator => false;

  /// Runs one sale. Emits stage changes and ends with exactly one [PaymentFinished].
  Stream<PaymentEvent> sale(SaleRequest request);

  /// Cancels the running sale if no card has been presented yet. Returns false if too late.
  bool cancel(String txnId);
}
