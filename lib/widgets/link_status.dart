import 'package:flutter/material.dart';

import '../core/link/link_session.dart';
import '../core/link/transport.dart';

enum _Tone { good, warn, bad, neutral }

({_Tone tone, String label}) _describe(LinkSession s) {
  if (s.problem != null) return (tone: _Tone.bad, label: 'Setup problem');
  switch (s.status) {
    case LinkStatus.online:
      return (tone: _Tone.good, label: 'Connected');
    case LinkStatus.stale:
      return (tone: _Tone.warn, label: 'Not responding');
    case LinkStatus.handshaking:
      return (tone: _Tone.warn, label: 'Waiting for app');
    case LinkStatus.offline:
      return switch (s.transportState.status) {
        TransportStatus.permission => (tone: _Tone.warn, label: 'Allow USB access'),
        TransportStatus.connecting => (tone: _Tone.warn, label: 'Connecting…'),
        TransportStatus.error => (tone: _Tone.bad, label: 'Link error'),
        _ => (tone: _Tone.neutral, label: 'Not connected'),
      };
  }
}

Color _toneColor(_Tone tone, ColorScheme cs) => switch (tone) {
      _Tone.good => const Color(0xFF16A34A),
      _Tone.warn => const Color(0xFFD97706),
      _Tone.bad => cs.error,
      _Tone.neutral => cs.outline,
    };

/// Compact link indicator for the app bar.
class LinkStatusChip extends StatelessWidget {
  const LinkStatusChip({super.key, required this.session});

  final LinkSession session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final d = _describe(session);
        final color = _toneColor(d.tone, cs);
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(d.label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color)),
            ],
          ),
        );
      },
    );
  }
}

/// Explains why the link is not online, with the transport's own detail text.
class LinkBanner extends StatelessWidget {
  const LinkBanner({super.key, required this.session});

  final LinkSession session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        if (session.isOnline && session.problem == null) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        final d = _describe(session);
        final color = _toneColor(d.tone, cs);
        final detail = session.problem ??
            switch (session.status) {
              LinkStatus.handshaking => 'Cable connected. Open POS Link on the other device.',
              LinkStatus.stale => 'The other device stopped answering. Reconnecting…',
              _ => session.transportState.detail ?? 'Waiting for connection',
            };
        return Material(
          color: color.withValues(alpha: 0.10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(d.tone == _Tone.bad ? Icons.error_outline : Icons.usb, color: color, size: 20),
                const SizedBox(width: 12),
                Expanded(child: Text(detail, style: Theme.of(context).textTheme.bodyMedium)),
              ],
            ),
          ),
        );
      },
    );
  }
}
