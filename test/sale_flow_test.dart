import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sunmi_usb/core/link/link_session.dart';
import 'package:sunmi_usb/core/link/memory_transport.dart';
import 'package:sunmi_usb/core/protocol/messages.dart';
import 'package:sunmi_usb/core/protocol/payloads.dart';
import 'package:sunmi_usb/data/transaction_store.dart';
import 'package:sunmi_usb/features/cashier/cashier_controller.dart';
import 'package:sunmi_usb/features/terminal/terminal_controller.dart';
import 'package:sunmi_usb/payment/mock_payment_adapter.dart';
import 'package:sunmi_usb/payment/payment_adapter.dart';

const _fast = LinkConfig(
  ackTimeout: Duration(milliseconds: 50),
  maxRetries: 3,
  heartbeatInterval: Duration(milliseconds: 50),
  staleAfter: Duration(milliseconds: 600),
);

class CountingPayment extends MockPaymentAdapter {
  CountingPayment({super.autoOutcome})
      : super(stepDelay: const Duration(milliseconds: 10), cardTimeout: const Duration(seconds: 5));

  int sales = 0;

  @override
  Stream<PaymentEvent> sale(SaleRequest request) {
    sales++;
    return super.sale(request);
  }
}

Future<void> waitFor(bool Function() condition, {String? reason}) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > const Duration(seconds: 3)) {
      throw TimeoutException('Condition not met${reason == null ? '' : ': $reason'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class Harness {
  Harness({SaleOutcome? auto = SaleOutcome.approved}) : payment = CountingPayment(autoOutcome: auto);

  final pair = MemoryTransportPair();
  final CountingPayment payment;
  final cashierStore = TransactionStore();
  final terminalStore = TransactionStore();
  late final LinkSession cashierLink;
  late final LinkSession terminalLink;
  late final CashierController cashier;
  late final TerminalController terminal;

  Future<void> start() async {
    cashierLink = LinkSession(transport: pair.a, localInfo: {'role': 'cashier', 'model': 'FLEX 3'}, config: _fast);
    terminalLink = LinkSession(transport: pair.b, localInfo: {'role': 'terminal', 'model': 'P3'}, config: _fast);
    terminal = TerminalController(
      session: terminalLink,
      store: terminalStore,
      payment: payment,
      resultHold: const Duration(milliseconds: 100),
    );
    cashier = CashierController(session: cashierLink, store: cashierStore, currency: 'LYD');
    await terminal.start();
    await cashier.start();
    await terminalLink.start();
    await cashierLink.start();
    await waitFor(() => cashierLink.isOnline && terminalLink.isOnline, reason: 'handshake');
  }

  Future<void> dispose() async {
    await cashierLink.stop();
    await terminalLink.stop();
    cashier.dispose();
    terminal.dispose();
  }
}

void main() {
  test('handshake exchanges device info', () async {
    final h = Harness();
    await h.start();
    expect(h.cashierLink.peer!.role, 'terminal');
    expect(h.terminalLink.peer!.description, 'FLEX 3');
    await h.dispose();
  });

  test('approved sale end to end', () async {
    final h = Harness();
    await h.start();
    await h.cashier.charge(12500);
    await waitFor(() => h.cashier.phase == CashierPhase.result, reason: 'result');

    final result = h.cashier.result!;
    expect(result.outcome, SaleOutcome.approved);
    expect(result.amount, 12500);
    expect(result.currency, 'LYD');
    expect(result.authCode, isNotNull);
    expect(h.cashierStore.get(result.txnId)!.state, TxnState.completed);
    await waitFor(() => h.terminalStore.get(result.txnId)!.resultDelivered, reason: 'delivered flag');
    await h.dispose();
  });

  test('declined sale', () async {
    final h = Harness(auto: SaleOutcome.declined);
    await h.start();
    await h.cashier.charge(1000);
    await waitFor(() => h.cashier.phase == CashierPhase.result);
    expect(h.cashier.result!.outcome, SaleOutcome.declined);
    expect(h.cashier.result!.responseCode, '05');
    await h.dispose();
  });

  test('a repeated SALE_REQUEST returns the stored result and does not charge again', () async {
    final h = Harness();
    await h.start();
    await h.cashier.charge(5000);
    await waitFor(() => h.cashier.phase == CashierPhase.result);
    final txnId = h.cashier.result!.txnId;

    final results = <Message>[];
    final sub = h.cashierLink.messages.where((m) => m.type == MsgType.saleResult).listen(results.add);
    final req = h.cashierStore.get(txnId)!.request;
    expect(await h.cashierLink.send(MsgType.saleRequest, req.toJson()), isTrue);
    await waitFor(() => results.isNotEmpty);

    expect(results.single.txnId, txnId);
    expect(h.payment.sales, 1);
    await sub.cancel();
    await h.dispose();
  });

  test('cancel before the card is presented', () async {
    final h = Harness(auto: null);
    await h.start();
    await h.cashier.charge(2000);
    await waitFor(() => h.cashier.phase == CashierPhase.waitingCard);
    await h.cashier.cancel();
    await waitFor(() => h.cashier.phase == CashierPhase.result);
    expect(h.cashier.result!.outcome, SaleOutcome.cancelled);
    await h.dispose();
  });

  test('a busy terminal refuses a second sale', () async {
    final h = Harness(auto: null);
    await h.start();
    await h.cashier.charge(2000);
    await waitFor(() => h.terminal.phase == TerminalPhase.waitingCard);

    final errors = <Message>[];
    final sub = h.cashierLink.messages.where((m) => m.type == MsgType.error).listen(errors.add);
    final other = SaleRequest(txnId: 'other-sale', amount: 1, currency: 'LYD', createdAt: DateTime.now());
    await h.cashierLink.send(MsgType.saleRequest, other.toJson());
    await waitFor(() => errors.isNotEmpty);

    expect(errors.single.payload['code'], ErrorCodes.busy);
    expect(h.payment.sales, 1);
    await sub.cancel();
    await h.dispose();
  });

  test('lost frames are retried transparently', () async {
    final h = Harness();
    await h.start();
    h.pair.a.dropNext = 2;
    await h.cashier.charge(750);
    await waitFor(() => h.cashier.phase == CashierPhase.result);
    expect(h.cashier.result!.approved, isTrue);
    expect(h.cashierLink.stats.retries, greaterThanOrEqualTo(1));
    expect(h.payment.sales, 1);
    await h.dispose();
  });

  test('result reaches the cashier after the cable is pulled mid-payment', () async {
    final h = Harness(auto: null);
    await h.start();
    await h.cashier.charge(9900);
    await waitFor(() => h.terminal.phase == TerminalPhase.waitingCard);

    h.pair.disconnect();
    await waitFor(() => h.cashierLink.status == LinkStatus.offline);
    h.terminal.presentCard(approve: true);
    await waitFor(() => h.terminal.phase == TerminalPhase.result || h.terminal.phase == TerminalPhase.idle);
    final txnId = h.cashier.current!.txnId;
    expect(h.terminalStore.get(txnId)!.resultDelivered, isFalse);
    expect(h.cashier.phase, isNot(CashierPhase.result));

    h.pair.reconnect();
    await waitFor(() => h.cashier.phase == CashierPhase.result, reason: 'recovered result');
    expect(h.cashier.result!.approved, isTrue);
    expect(h.cashierStore.get(txnId)!.state, TxnState.completed);
    await waitFor(() => h.terminalStore.get(txnId)!.resultDelivered);
    await h.dispose();
  });

  test('no acknowledgement → status unknown, then recovered with a status query', () async {
    final h = Harness();
    await h.start();
    h.pair.b.dropNext = 1 << 30; // terminal hears everything, but nothing it sends arrives
    await h.cashier.charge(4321);
    await waitFor(() => h.cashier.phase == CashierPhase.attention, reason: 'unknown state');
    final txnId = h.cashier.current!.txnId;
    expect(h.cashierStore.get(txnId)!.state, TxnState.unknown);

    await waitFor(() => h.terminalStore.get(txnId)?.state == TxnState.completed, reason: 'terminal finished');
    h.pair.b.dropNext = 0;
    await h.cashier.checkStatus();
    await waitFor(() => h.cashier.phase == CashierPhase.result, reason: 'status query result');
    expect(h.cashier.result!.approved, isTrue);
    expect(h.payment.sales, 1);
    await h.dispose();
  });

  test('a peer that stops reading gets a few frames, not a backlog of heartbeats', () async {
    final pair = MemoryTransportPair();
    // The terminal's writes go nowhere, like USB when the cashier side isn't reading.
    pair.b.stall();
    final terminal = LinkSession(transport: pair.b, localInfo: {'role': 'terminal'}, config: _fast);
    final cashier = LinkSession(transport: pair.a, localInfo: {'role': 'cashier'}, config: _fast);
    await terminal.start();
    await cashier.start();

    await Future<void>.delayed(_fast.heartbeatInterval * 12);
    expect(pair.b.heldFrames, 1, reason: 'only the first HELLO is waiting, no heartbeat pile-up');
    expect(terminal.stats.heldHeartbeats, greaterThan(5));
    expect(cashier.isOnline, isFalse);

    pair.b.unstall();
    await waitFor(() => cashier.isOnline && terminal.isOnline, reason: 'handshake after the pipe drains');
    await cashier.stop();
    await terminal.stop();
  });

  test('a message is never queued twice while the pipe is blocked', () async {
    final h = Harness(auto: null);
    await h.start();
    h.pair.a.stall();
    final sent = h.cashierLink.send(MsgType.cancel, {'txnId': 'nothing-running'});
    await Future<void>.delayed(_fast.ackTimeout * 2.5);
    expect(h.pair.a.heldFrames, 1, reason: 'retries wait for the first copy to leave');
    h.pair.a.unstall();
    expect(await sent, isTrue);
    await h.dispose();
  });

  test('two devices with the same role do not go online', () async {
    final pair = MemoryTransportPair();
    final a = LinkSession(transport: pair.a, localInfo: {'role': 'cashier'}, config: _fast);
    final b = LinkSession(transport: pair.b, localInfo: {'role': 'cashier'}, config: _fast);
    await a.start();
    await b.start();
    await waitFor(() => a.problem != null && b.problem != null);
    expect(a.isOnline, isFalse);
    expect(b.isOnline, isFalse);
    await a.stop();
    await b.stop();
  });
}
