/// Typed payloads for the messages in messages.dart.
/// Amounts are always integers in the currency's minor unit (LYD: 12.500 → 12500).
library;

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

enum PaymentStage { waitingCard, cardRead, pinEntry, authorizing, printing }

enum SaleOutcome { approved, declined, cancelled, timeout, error }

/// Answer to a TXN_STATUS_QUERY.
enum TxnStatusState { notFound, inProgress, completed, interrupted }

class SaleRequest {
  const SaleRequest({
    required this.txnId,
    required this.amount,
    required this.currency,
    required this.createdAt,
    this.reference,
  });

  final String txnId;
  final int amount;
  final String currency;
  final String? reference;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'txnId': txnId,
        'amount': amount,
        'currency': currency,
        if (reference != null) 'reference': reference,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  factory SaleRequest.fromJson(Map<String, dynamic> j) => SaleRequest(
        txnId: j['txnId'] as String? ?? '',
        amount: (j['amount'] as num?)?.toInt() ?? 0,
        currency: j['currency'] as String? ?? '',
        reference: j['reference'] as String?,
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '')?.toLocal() ?? DateTime.now(),
      );

  String? validate() {
    if (txnId.isEmpty) return 'txnId is required';
    if (amount <= 0) return 'amount must be positive';
    if (currency.length != 3) return 'currency must be an ISO 4217 code';
    return null;
  }
}

class SaleResult {
  const SaleResult({
    required this.txnId,
    required this.outcome,
    required this.amount,
    required this.currency,
    required this.timestamp,
    this.responseCode,
    this.message,
    this.authCode,
    this.rrn,
    this.stan,
    this.maskedPan,
    this.cardScheme,
    this.terminalId,
    this.merchantId,
  });

  final String txnId;
  final SaleOutcome outcome;
  final int amount;
  final String currency;
  final DateTime timestamp;
  final String? responseCode;
  final String? message;
  final String? authCode;
  final String? rrn;
  final String? stan;

  /// Masked only (e.g. 476173******0119). Full card data must never cross the link.
  final String? maskedPan;
  final String? cardScheme;
  final String? terminalId;
  final String? merchantId;

  bool get approved => outcome == SaleOutcome.approved;

  Map<String, dynamic> toJson() => {
        'txnId': txnId,
        'outcome': outcome.name,
        'amount': amount,
        'currency': currency,
        'timestamp': timestamp.toUtc().toIso8601String(),
        if (responseCode != null) 'responseCode': responseCode,
        if (message != null) 'message': message,
        if (authCode != null) 'authCode': authCode,
        if (rrn != null) 'rrn': rrn,
        if (stan != null) 'stan': stan,
        if (maskedPan != null) 'maskedPan': maskedPan,
        if (cardScheme != null) 'cardScheme': cardScheme,
        if (terminalId != null) 'terminalId': terminalId,
        if (merchantId != null) 'merchantId': merchantId,
      };

  factory SaleResult.fromJson(Map<String, dynamic> j) => SaleResult(
        txnId: j['txnId'] as String? ?? '',
        outcome: _enumByName(SaleOutcome.values, j['outcome'], SaleOutcome.error),
        amount: (j['amount'] as num?)?.toInt() ?? 0,
        currency: j['currency'] as String? ?? '',
        timestamp: DateTime.tryParse(j['timestamp'] as String? ?? '')?.toLocal() ?? DateTime.now(),
        responseCode: j['responseCode'] as String?,
        message: j['message'] as String?,
        authCode: j['authCode'] as String?,
        rrn: j['rrn'] as String?,
        stan: j['stan'] as String?,
        maskedPan: j['maskedPan'] as String?,
        cardScheme: j['cardScheme'] as String?,
        terminalId: j['terminalId'] as String?,
        merchantId: j['merchantId'] as String?,
      );
}

PaymentStage paymentStageFromName(Object? name) =>
    _enumByName(PaymentStage.values, name, PaymentStage.authorizing);

TxnStatusState txnStatusStateFromName(Object? name) =>
    _enumByName(TxnStatusState.values, name, TxnStatusState.notFound);

String stageLabel(PaymentStage stage) => switch (stage) {
      PaymentStage.waitingCard => 'Waiting for card',
      PaymentStage.cardRead => 'Card read',
      PaymentStage.pinEntry => 'Customer entering PIN',
      PaymentStage.authorizing => 'Authorizing…',
      PaymentStage.printing => 'Printing receipt…',
    };

String outcomeLabel(SaleOutcome outcome) => switch (outcome) {
      SaleOutcome.approved => 'Approved',
      SaleOutcome.declined => 'Declined',
      SaleOutcome.cancelled => 'Cancelled',
      SaleOutcome.timeout => 'Timed out',
      SaleOutcome.error => 'Failed',
    };
