import 'dart:math';

import 'package:flutter/foundation.dart';

/// Number of minor units per currency. LYD and TND use 3 decimals (1 dinar = 1000 dirham/millime).
const Map<String, int> currencyExponents = {'LYD': 3, 'TND': 3, 'USD': 2, 'EUR': 2, 'EGP': 2};

int currencyExponent(String currency) => currencyExponents[currency] ?? 2;

/// 1234500 minor units of LYD → "1,234.500 LYD".
String formatMoney(int minor, String currency, {bool withCode = true}) {
  final exp = currencyExponent(currency);
  final negative = minor < 0;
  final abs = minor.abs();
  final unit = pow(10, exp).toInt();
  final whole = (abs ~/ unit).toString();
  final grouped = whole.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  final fraction = exp == 0 ? '' : '.${(abs % unit).toString().padLeft(exp, '0')}';
  return '${negative ? '-' : ''}$grouped$fraction${withCode ? ' $currency' : ''}';
}

final Random _random = Random.secure();

/// RFC 4122 version 4 UUID.
String uuidV4() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0F) | 0x40;
  b[8] = (b[8] & 0x3F) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

String randomDigits(int count) => List.generate(count, (_) => _random.nextInt(10)).join();

String formatTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

class LogEntry {
  LogEntry(this.source, this.message) : time = DateTime.now();

  final DateTime time;
  final String source;
  final String message;

  @override
  String toString() => '${formatTime(time)} [$source] $message';
}

/// In-memory ring buffer shown on the diagnostics screen.
class AppLog extends ChangeNotifier {
  AppLog({this.capacity = 400});

  final int capacity;
  final List<LogEntry> _entries = [];

  List<LogEntry> get entries => List.unmodifiable(_entries);

  void add(String source, String message) {
    final entry = LogEntry(source, message);
    debugPrint(entry.toString());
    _entries.add(entry);
    if (_entries.length > capacity) _entries.removeRange(0, _entries.length - capacity);
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}
