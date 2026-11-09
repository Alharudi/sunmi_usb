import 'package:flutter/material.dart';

/// Calculator-style keypad: digits are appended to the amount in minor units
/// (typing 1 2 5 0 0 in LYD gives 12.500).
class AmountKeypad extends StatelessWidget {
  const AmountKeypad({
    super.key,
    required this.onKey,
    required this.onBackspace,
    required this.onClear,
    this.enabled = true,
  });

  final ValueChanged<String> onKey;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    const rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['00', '0', '⌫'],
    ];
    return Column(
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                for (final key in row)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: _Key(
                        label: key,
                        enabled: enabled,
                        onTap: key == '⌫' ? onBackspace : () => onKey(key),
                        onLongPress: key == '⌫' ? onClear : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.label, required this.enabled, required this.onTap, this.onLongPress});

  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final isBackspace = label == '⌫';
    return SizedBox(
      height: 60,
      child: FilledButton.tonal(
        onPressed: enabled ? onTap : null,
        onLongPress: enabled ? onLongPress : null,
        style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
        child: isBackspace
            ? const Icon(Icons.backspace_outlined, semanticLabel: 'Delete')
            : Text(label, style: Theme.of(context).textTheme.headlineSmall),
      ),
    );
  }
}
