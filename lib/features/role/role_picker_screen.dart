import 'package:flutter/material.dart';

import '../../data/settings.dart';
import '../../services/app_services.dart';

/// First launch: choose whether this device is the cashier or the payment terminal.
class RolePickerScreen extends StatelessWidget {
  const RolePickerScreen({super.key, required this.services});

  final AppServices services;

  Future<void> _pick(AppRole role) async {
    await services.settings.setRole(role);
    await services.reconfigure();
  }

  @override
  Widget build(BuildContext context) {
    final suggested = services.suggestedRole;
    final text = Theme.of(context).textTheme;
    final cards = [
      _RoleCard(
        icon: Icons.point_of_sale,
        title: 'Cashier',
        body: 'Enters the amount and sends it to the terminal. Usually the Flex 3. USB host side.',
        suggested: suggested == AppRole.cashier,
        onTap: () => _pick(AppRole.cashier),
      ),
      _RoleCard(
        icon: Icons.contactless_outlined,
        title: 'Payment terminal',
        body: 'Takes the card and sends the result back. Usually the P3. USB accessory side.',
        suggested: suggested == AppRole.terminal,
        onTap: () => _pick(AppRole.terminal),
      ),
    ];
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                children: [
                  Text('How will this device be used?', style: text.headlineSmall, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(services.deviceLabel, style: text.bodyMedium, textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  LayoutBuilder(
                    builder: (context, constraints) => constraints.maxWidth > 560
                        ? IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: cards[0]),
                                const SizedBox(width: 16),
                                Expanded(child: cards[1]),
                              ],
                            ),
                          )
                        : Column(children: [cards[0], const SizedBox(height: 12), cards[1]]),
                  ),
                  const SizedBox(height: 16),
                  Text('You can change this later in Settings.', style: text.bodySmall),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.suggested,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool suggested;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: suggested ? cs.primary : cs.outlineVariant, width: suggested ? 2 : 1),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 36, color: cs.primary),
                  const Spacer(),
                  if (suggested)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(999)),
                      child: Text('Suggested', style: text.labelMedium?.copyWith(color: cs.onPrimaryContainer)),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(title, style: text.titleLarge),
              const SizedBox(height: 6),
              Text(body, style: text.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}
