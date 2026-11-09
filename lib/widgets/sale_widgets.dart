import 'package:flutter/material.dart';

import '../core/protocol/payloads.dart';
import '../core/util.dart';

Color outcomeColor(SaleOutcome outcome, ColorScheme cs) => switch (outcome) {
      SaleOutcome.approved => const Color(0xFF16A34A),
      SaleOutcome.cancelled || SaleOutcome.timeout => const Color(0xFFD97706),
      _ => cs.error,
    };

IconData outcomeIcon(SaleOutcome outcome) => switch (outcome) {
      SaleOutcome.approved => Icons.check_circle,
      SaleOutcome.cancelled || SaleOutcome.timeout => Icons.remove_circle,
      _ => Icons.cancel,
    };

/// Big icon + title + amount, used for results, refusals and warnings.
class StatusHero extends StatelessWidget {
  const StatusHero({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.amount,
    this.message,
    this.busy = false,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? amount;
  final String? message;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 96,
          child: Center(
            child: busy
                ? SizedBox(width: 64, height: 64, child: CircularProgressIndicator(strokeWidth: 5, color: color))
                : Icon(icon, size: 88, color: color),
          ),
        ),
        const SizedBox(height: 12),
        if (amount != null)
          Text(amount!, style: text.displaySmall?.copyWith(fontWeight: FontWeight.w600), textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(title, style: text.titleLarge?.copyWith(color: color), textAlign: TextAlign.center),
        if (message != null) ...[
          const SizedBox(height: 12),
          Text(message!, style: text.bodyMedium, textAlign: TextAlign.center),
        ],
      ],
    );
  }
}

/// Key/value list of a sale result.
class ResultDetails extends StatelessWidget {
  const ResultDetails({super.key, required this.result});

  final SaleResult result;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String?)>[
      ('Outcome', outcomeLabel(result.outcome)),
      ('Amount', formatMoney(result.amount, result.currency)),
      ('Response', [result.responseCode, result.message].whereType<String>().join(' · ')),
      ('Auth code', result.authCode),
      ('Card', [result.cardScheme, result.maskedPan].whereType<String>().join(' ')),
      ('RRN', result.rrn),
      ('STAN', result.stan),
      ('Terminal ID', result.terminalId),
      ('Merchant ID', result.merchantId),
      ('Time', formatTime(result.timestamp)),
      ('Transaction', result.txnId),
    ];
    return DetailRows(rows: rows);
  }
}

/// Label/value rows; empty values are skipped.
class DetailRows extends StatelessWidget {
  const DetailRows({super.key, required this.rows});

  final List<(String, String?)> rows;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.outline);
    return Column(
      children: [
        for (final (label, value) in rows)
          if (value != null && value.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 110, child: Text(label, style: muted)),
                  Expanded(child: SelectableText(value, style: text.bodyMedium)),
                ],
              ),
            ),
      ],
    );
  }
}
