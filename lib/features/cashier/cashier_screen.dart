import 'package:flutter/material.dart';

import '../../core/protocol/payloads.dart';
import '../../core/util.dart';
import '../../services/app_services.dart';
import '../../widgets/amount_keypad.dart';
import '../../widgets/link_status.dart';
import '../../widgets/sale_widgets.dart';
import '../history/history_screen.dart';
import '../settings/settings_screen.dart';
import 'cashier_controller.dart';

class CashierScreen extends StatefulWidget {
  const CashierScreen({super.key, required this.services});

  final AppServices services;

  @override
  State<CashierScreen> createState() => _CashierScreenState();
}

class _CashierScreenState extends State<CashierScreen> {
  static const _maxDigits = 10;
  String _digits = '';

  int get _amount => int.tryParse(_digits) ?? 0;

  void _onKey(String key) {
    if (_digits.length + key.length > _maxDigits) return;
    setState(() => _digits = (_digits + key).replaceFirst(RegExp(r'^0+'), ''));
  }

  void _onBackspace() {
    if (_digits.isEmpty) return;
    setState(() => _digits = _digits.substring(0, _digits.length - 1));
  }

  void _clearAmount() => setState(() => _digits = '');

  @override
  Widget build(BuildContext context) {
    final services = widget.services;
    final controller = services.cashier!;
    final session = services.session!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cashier'),
        actions: [
          LinkStatusChip(session: session),
          IconButton(
            tooltip: 'History',
            icon: const Icon(Icons.receipt_long),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => HistoryScreen(store: services.store!),
            )),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => SettingsScreen(services: services),
            )),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            LinkBanner(session: session),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: ListenableBuilder(
                      listenable: Listenable.merge([controller, session]),
                      builder: (context, _) => _body(context, controller),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, CashierController c) {
    final cs = Theme.of(context).colorScheme;
    final currency = c.currency;
    final amountText = c.current == null ? null : formatMoney(c.current!.amount, c.current!.currency);

    switch (c.phase) {
      case CashierPhase.idle:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Amount', style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                formatMoney(_amount, currency),
                style: Theme.of(context).textTheme.displayMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            if (c.message != null) ...[
              const SizedBox(height: 8),
              Text(c.message!, textAlign: TextAlign.center, style: TextStyle(color: cs.error)),
            ],
            const SizedBox(height: 20),
            AmountKeypad(onKey: _onKey, onBackspace: _onBackspace, onClear: _clearAmount),
            const SizedBox(height: 16),
            SizedBox(
              height: 64,
              child: FilledButton.icon(
                onPressed: _amount > 0 && c.canCharge ? () => c.charge(_amount) : null,
                icon: const Icon(Icons.contactless_outlined),
                label: Text(
                  c.canCharge ? 'Charge ${formatMoney(_amount, currency)}' : 'Terminal not connected',
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ),
          ],
        );

      case CashierPhase.sending || CashierPhase.waitingCard || CashierPhase.processing:
        final title = switch (c.phase) {
          CashierPhase.sending => 'Sending to terminal…',
          CashierPhase.waitingCard => 'Customer: tap, insert or swipe card on the terminal',
          _ => stageLabel(c.stage ?? PaymentStage.authorizing),
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StatusHero(
              icon: Icons.contactless_outlined,
              color: cs.primary,
              busy: true,
              title: title,
              amount: amountText,
              message: c.message,
            ),
            const SizedBox(height: 28),
            OutlinedButton(
              onPressed: c.canCancel ? c.cancel : null,
              child: const Text('Cancel payment'),
            ),
          ],
        );

      case CashierPhase.result:
        final r = c.result!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StatusHero(
              icon: outcomeIcon(r.outcome),
              color: outcomeColor(r.outcome, cs),
              title: outcomeLabel(r.outcome),
              amount: formatMoney(r.amount, r.currency),
              message: r.approved ? null : r.message,
            ),
            const SizedBox(height: 16),
            Card(child: Padding(padding: const EdgeInsets.all(16), child: ResultDetails(result: r))),
            const SizedBox(height: 16),
            SizedBox(
              height: 56,
              child: FilledButton(
                onPressed: () {
                  _clearAmount();
                  c.newSale();
                },
                child: const Text('New sale'),
              ),
            ),
          ],
        );

      case CashierPhase.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StatusHero(
              icon: Icons.block,
              color: cs.error,
              title: 'Not charged',
              amount: amountText,
              message: c.message,
            ),
            const SizedBox(height: 24),
            SizedBox(height: 56, child: FilledButton(onPressed: c.newSale, child: const Text('Back'))),
          ],
        );

      case CashierPhase.attention:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StatusHero(
              icon: Icons.warning_amber_rounded,
              color: const Color(0xFFD97706),
              title: 'Payment status unknown',
              amount: amountText,
              message: c.message,
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: c.session.canSend ? c.checkStatus : null,
                icon: const Icon(Icons.refresh),
                label: const Text('Check status'),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => _confirmCloseUnknown(context, c),
              child: const Text('Close without a result…'),
            ),
          ],
        );
    }
  }

  Future<void> _confirmCloseUnknown(BuildContext context, CashierController c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close without a result?'),
        content: const Text(
          "Only do this after checking the terminal's transaction report. "
          'If the customer was charged, record the payment manually. '
          'The sale stays in History as "unknown".',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep checking')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Close')),
        ],
      ),
    );
    if (ok == true) {
      _clearAmount();
      await c.closeUnknown();
    }
  }
}
