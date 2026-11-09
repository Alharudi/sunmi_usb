import 'package:flutter/material.dart';

import '../../core/protocol/payloads.dart';
import '../../core/util.dart';
import '../../data/transaction_store.dart';
import '../../widgets/sale_widgets.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key, required this.store});

  final TransactionStore store;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final records = store.recent;
          if (records.isEmpty) {
            return const Center(child: Text('No transactions yet'));
          }
          return ListView.separated(
            itemCount: records.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => _tile(context, records[i]),
          );
        },
      ),
    );
  }

  Widget _tile(BuildContext context, TxnRecord r) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color, label) = switch (r.state) {
      TxnState.completed => (
          outcomeIcon(r.result!.outcome),
          outcomeColor(r.result!.outcome, cs),
          outcomeLabel(r.result!.outcome),
        ),
      TxnState.pending || TxnState.inProgress => (Icons.hourglass_top, cs.primary, 'In progress'),
      TxnState.unknown => (Icons.warning_amber_rounded, const Color(0xFFD97706), 'Unknown: check terminal'),
      TxnState.rejected => (Icons.block, cs.outline, 'Not charged'),
    };
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(formatMoney(r.request.amount, r.request.currency)),
      subtitle: Text('${formatTime(r.request.createdAt)} · $label'),
      trailing: Text(r.txnId.substring(0, 8), style: Theme.of(context).textTheme.labelSmall),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: r.result != null
                ? ResultDetails(result: r.result!)
                : DetailRows(rows: [
                    ('Status', label),
                    ('Amount', formatMoney(r.request.amount, r.request.currency)),
                    ('Note', r.note),
                    ('Created', formatTime(r.request.createdAt)),
                    ('Updated', formatTime(r.updatedAt)),
                    ('Transaction', r.txnId),
                  ]),
          ),
        ),
      ),
    );
  }
}
