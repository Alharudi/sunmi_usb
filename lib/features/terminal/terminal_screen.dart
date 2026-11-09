import 'package:flutter/material.dart';

import '../../core/link/link_session.dart';
import '../../core/protocol/payloads.dart';
import '../../core/util.dart';
import '../../services/app_services.dart';
import '../../widgets/link_status.dart';
import '../../widgets/sale_widgets.dart';
import '../history/history_screen.dart';
import '../settings/settings_screen.dart';
import 'terminal_controller.dart';

class TerminalScreen extends StatelessWidget {
  const TerminalScreen({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final controller = services.terminal!;
    final session = services.session!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terminal'),
        actions: [
          LinkStatusChip(session: session),
          PopupMenuButton<String>(
            onSelected: (v) => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    v == 'history' ? HistoryScreen(store: services.store!) : SettingsScreen(services: services),
              ),
            ),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'history', child: Text('History')),
              PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            LinkBanner(session: session),
            if (services.payment?.isSimulator ?? false)
              Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.tertiaryContainer,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Text(
                  'Payment simulator: no real card is charged',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.onTertiaryContainer),
                ),
              ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: ListenableBuilder(
                      listenable: Listenable.merge([controller, session]),
                      builder: (context, _) => _body(context, controller, session),
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

  Widget _body(BuildContext context, TerminalController c, LinkSession session) {
    final cs = Theme.of(context).colorScheme;
    switch (c.phase) {
      case TerminalPhase.idle:
        final (icon, title, message) = switch (session.status) {
          LinkStatus.online => (Icons.point_of_sale, 'Ready', 'Waiting for the cashier to send an amount'),
          LinkStatus.handshaking => (
            Icons.usb,
            'Waiting for the cashier',
            'The link is up. Open POS Link on the cashier device.',
          ),
          LinkStatus.stale => (
            Icons.hourglass_empty,
            'The cashier is not answering',
            'Check that POS Link is open on the cashier device.',
          ),
          LinkStatus.offline => (
            Icons.usb_off,
            'Not connected to the cashier',
            'Connect the cable to the cashier device.',
          ),
        };
        return StatusHero(
          icon: icon,
          color: session.isOnline ? cs.primary : cs.outline,
          title: title,
          message: message,
        );

      case TerminalPhase.waitingCard:
        final req = c.current!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StatusHero(
              icon: Icons.contactless_outlined,
              color: cs.primary,
              title: 'Tap, insert or swipe card',
              amount: formatMoney(req.amount, req.currency),
            ),
            const SizedBox(height: 28),
            if (c.canSimulateCard) ...[
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: () => c.presentCard(approve: true),
                  icon: const Icon(Icons.credit_card),
                  label: const Text('Simulate card: approve'),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 52,
                child: FilledButton.tonalIcon(
                  onPressed: () => c.presentCard(approve: false),
                  icon: const Icon(Icons.credit_card_off),
                  label: const Text('Simulate card: decline'),
                ),
              ),
              const SizedBox(height: 10),
            ],
            OutlinedButton(onPressed: c.cancelOnTerminal, child: const Text('Cancel')),
          ],
        );

      case TerminalPhase.processing:
        final req = c.current!;
        return StatusHero(
          icon: Icons.sync,
          color: cs.primary,
          busy: true,
          title: stageLabel(c.stage ?? PaymentStage.authorizing),
          amount: formatMoney(req.amount, req.currency),
          message: 'Do not remove the card',
        );

      case TerminalPhase.result:
        final r = c.lastResult!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StatusHero(
              icon: outcomeIcon(r.outcome),
              color: outcomeColor(r.outcome, cs),
              title: outcomeLabel(r.outcome),
              amount: formatMoney(r.amount, r.currency),
              message: [
                if (r.authCode != null) 'Auth code ${r.authCode}',
                if (r.maskedPan != null) '${r.cardScheme ?? ''} ${r.maskedPan}'.trim(),
                if (!r.approved && r.message != null) r.message!,
              ].join('\n'),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 52,
              child: FilledButton(onPressed: c.dismissResult, child: const Text('Done')),
            ),
          ],
        );
    }
  }
}
