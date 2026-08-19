import 'package:flutter/material.dart';

import '../../../core/addons/services/link_probe_service.dart';

/// Why a sources sheet was opened. Both actions stay on every row; the mode
/// only decides the default tap action and the initial filtering.
enum SourcesMode { play, download }

/// Small coloured pill used for quality/source tags.
class SourceTag extends StatelessWidget {
  final String text;
  final Color color;
  const SourceTag({super.key, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Working / dead / testing indicator driven by [LinkProbeService].
class ProbeBadge extends StatelessWidget {
  final LinkProbeResult? probe;
  final bool probing;
  final bool isPeerToPeer;

  const ProbeBadge({
    super.key,
    required this.probe,
    required this.probing,
    this.isPeerToPeer = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    if (isPeerToPeer) {
      return Text(
        'P2P',
        style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
      );
    }
    if (probing) {
      return SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: cs.primary),
      );
    }
    final result = probe;
    if (result == null) return const SizedBox.shrink();
    if (result.reachable) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.verified_rounded, size: 12, color: Colors.green),
          const SizedBox(width: 2),
          Text(
            'Working',
            style: theme.textTheme.labelSmall?.copyWith(color: Colors.green),
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline_rounded, size: 12, color: cs.error),
        const SizedBox(width: 2),
        Text(
          result.failureReason ?? 'Dead link',
          style: theme.textTheme.labelSmall?.copyWith(color: cs.error),
        ),
      ],
    );
  }
}

/// Title block shared by the sources sheets.
class SourceSheetHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? trailing;

  const SourceSheetHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Best-guess container extension for a link, used when naming downloads.
String extensionForUrl(String url) {
  final clean = url.split('?').first.toLowerCase();
  for (final ext in const ['.mp4', '.mkv', '.webm', '.avi', '.mov']) {
    if (clean.endsWith(ext)) return ext;
  }
  return '.mp4';
}
