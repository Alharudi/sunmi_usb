import 'dart:convert';

/// Message types carried in the frame `type` byte. See docs/PROTOCOL.md.
enum MsgType {
  hello(0x01),
  ping(0x03),
  pong(0x04),
  ack(0x05),
  nak(0x06),
  status(0x10),
  saleRequest(0x20),
  readyToPay(0x21),
  progress(0x22),
  saleResult(0x23),
  cancel(0x24),
  txnStatusQuery(0x25),
  txnStatus(0x26),
  error(0x7F);

  const MsgType(this.code);

  final int code;

  /// Link-level messages: never acknowledged, never retried, never delivered to features.
  bool get isLinkLevel => this == hello || this == ping || this == pong || this == ack || this == nak;

  static MsgType? fromCode(int code) {
    for (final t in values) {
      if (t.code == code) return t;
    }
    return null;
  }
}

class Message {
  const Message(this.type, [this.payload = const {}]);

  final MsgType type;
  final Map<String, dynamic> payload;

  String? get txnId => payload['txnId'] as String?;

  @override
  String toString() => '${type.name} ${jsonEncode(payload)}';
}

/// Error codes used in [MsgType.error] and [MsgType.nak] payloads.
abstract final class ErrorCodes {
  static const busy = 'BUSY';
  static const cannotCancel = 'CANNOT_CANCEL';
  static const unknownTxn = 'UNKNOWN_TXN';
  static const txnInterrupted = 'TXN_INTERRUPTED';
  static const badRequest = 'BAD_REQUEST';
  static const unknownType = 'UNKNOWN_TYPE';
  static const badPayload = 'BAD_PAYLOAD';
  static const unsupportedVersion = 'UNSUPPORTED_VERSION';
}
