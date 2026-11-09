import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/protocol/payloads.dart';

enum TxnState {
  /// Cashier created it; terminal has not confirmed receiving it yet.
  pending,

  /// Terminal is running the payment.
  inProgress,

  /// Final result known.
  completed,

  /// Outcome not known (link lost, app restarted mid-payment). Must be checked, never assumed.
  unknown,

  /// Terminal refused it before any card was read (busy, never received). No money moved.
  rejected,
}

class TxnRecord {
  TxnRecord({
    required this.request,
    required this.state,
    this.result,
    this.resultDelivered = false,
    this.note,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final SaleRequest request;
  final TxnState state;
  final SaleResult? result;

  /// Terminal side: the cashier acknowledged the SALE_RESULT.
  final bool resultDelivered;
  final String? note;
  final DateTime updatedAt;

  String get txnId => request.txnId;

  TxnRecord copyWith({TxnState? state, SaleResult? result, bool? resultDelivered, String? note}) => TxnRecord(
        request: request,
        state: state ?? this.state,
        result: result ?? this.result,
        resultDelivered: resultDelivered ?? this.resultDelivered,
        note: note ?? this.note,
      );

  Map<String, dynamic> toJson() => {
        'request': request.toJson(),
        'state': state.name,
        if (result != null) 'result': result!.toJson(),
        'resultDelivered': resultDelivered,
        if (note != null) 'note': note,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory TxnRecord.fromJson(Map<String, dynamic> j) => TxnRecord(
        request: SaleRequest.fromJson(Map<String, dynamic>.from(j['request'] as Map)),
        state: TxnState.values.firstWhere((s) => s.name == j['state'], orElse: () => TxnState.unknown),
        result: j['result'] == null ? null : SaleResult.fromJson(Map<String, dynamic>.from(j['result'] as Map)),
        resultDelivered: j['resultDelivered'] as bool? ?? false,
        note: j['note'] as String?,
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '')?.toLocal(),
      );
}

/// Transaction journal, newest first. Persisted as JSON when [file] is given, memory-only otherwise.
/// Both sides keep one: the terminal uses it for duplicate protection and result re-delivery,
/// the cashier for recovery after a disconnect.
class TransactionStore extends ChangeNotifier {
  TransactionStore({this.file, this.capacity = 500});

  final File? file;
  final int capacity;
  final List<TxnRecord> _records = [];
  Future<void> _writing = Future.value();

  List<TxnRecord> get recent => List.unmodifiable(_records);

  TxnRecord? get(String txnId) {
    for (final r in _records) {
      if (r.txnId == txnId) return r;
    }
    return null;
  }

  Future<void> load() async {
    final f = file;
    if (f == null || !await f.exists()) return;
    try {
      final list = jsonDecode(await f.readAsString()) as List;
      _records
        ..clear()
        ..addAll(list.map((e) => TxnRecord.fromJson(Map<String, dynamic>.from(e as Map))));
      notifyListeners();
    } catch (e) {
      debugPrint('Transaction store unreadable, starting empty: $e');
    }
  }

  Future<void> put(TxnRecord record) {
    _records.removeWhere((r) => r.txnId == record.txnId);
    _records.insert(0, record);
    if (_records.length > capacity) _records.removeRange(capacity, _records.length);
    notifyListeners();
    return _persist();
  }

  Future<void> clear() {
    _records.clear();
    notifyListeners();
    return _persist();
  }

  Future<void> _persist() {
    final f = file;
    if (f == null) return Future.value();
    final snapshot = jsonEncode(_records.map((r) => r.toJson()).toList());
    _writing = _writing.then((_) async {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(snapshot, flush: true);
      await tmp.rename(f.path);
    }).catchError((Object e) => debugPrint('Saving transactions failed: $e'));
    return _writing;
  }
}
