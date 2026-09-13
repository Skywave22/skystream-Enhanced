import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/utils/image_fallbacks.dart';
import '../../../sources/presentation/plugin_sources_sheet.dart';
import '../../../sources/presentation/source_sheet_widgets.dart';
import '../tmdb_details_controller.dart';

/// Colours for the frosted panel.
///
/// The glass is a surface of its own rather than a themed one, so the dark
/// values stay the literals the design ships with; the light ones mirror them
/// against a frosted-white panel, where white-on-white would disappear.
class _GlassColors {
  const _GlassColors({
    required this.panel,
    required this.edge,
    required this.outline,
    required this.foreground,
    required this.mutedIcon,
    required this.imageFill,
    required this.focusFill,
    required this.hoverFill,
  });

  /// Tint painted behind the panel's blur.
  final Color panel;

  /// Fresnel hairline around the panel.
  final Color edge;

  /// Border of an unselected season chip.
  final Color outline;

  /// Titles, the focus ring and the chevron once a card is active.
  final Color foreground;

  /// Placeholder glyph shown when an episode still is missing.
  final Color mutedIcon;

  /// Fill behind a still that is loading or missing.
  final Color imageFill;

  final Color focusFill;
  final Color hoverFill;

  static _GlassColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? _dark : _light;

  static final _dark = _GlassColors(
    panel: const Color(0xA6060608), // Frosted glass obsidian tint (65% opacity)
    edge: Colors.white.withValues(alpha: 0.12),
    outline: Colors.white.withValues(alpha: 0.15),
    foreground: Colors.white,
    mutedIcon: Colors.white38,
    imageFill: Colors.white.withValues(alpha: 0.06),
    focusFill: const Color(0xFF242430),
    hoverFill: const Color(0xFF1E1E28).withValues(alpha: 0.70),
  );

  static final _light = _GlassColors(
    panel: const Color(0xA6F4F4F8),
    edge: Colors.black.withValues(alpha: 0.10),
    outline: Colors.black.withValues(alpha: 0.14),
    foreground: const Color(0xFF15151C),
    mutedIcon: Colors.black38,
    imageFill: Colors.black.withValues(alpha: 0.06),
    focusFill: const Color(0xFFE2E2EA),
    hoverFill: const Color(0xFFEBEBF2).withValues(alpha: 0.70),
  );
}

/// Season / episode picker for "Search in Nuvio plugins" on a series.
///
/// Redesigned as a floating Hyprland glass dialog matching [PluginSourcesSheet].
class EpisodePickerSheet extends ConsumerWidget {
  final int movieId;
  final String? source;
  final List<dynamic> seasons;
  final MultimediaItem target;
  final SourcesMode mode;

  /// The screen that opened the picker. The sources sheet is shown from this
  /// context *after* the picker closes — using the picker's own (defunct)
  /// context would silently do nothing.
  final BuildContext hostContext;

  const EpisodePickerSheet({
    super.key,
    required this.movieId,
    required this.seasons,
    required this.target,
    required this.hostContext,
    this.source,
    this.mode = SourcesMode.play,
  });

  static Future<void> open(
    BuildContext context, {
    required int movieId,
    required List<dynamic> seasons,
    required MultimediaItem target,
    String? source,
    SourcesMode mode = SourcesMode.play,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      builder: (_) => EpisodePickerSheet(
        movieId: movieId,
        seasons: seasons,
        target: target,
        hostContext: context,
        source: source,
        mode: mode,
      ),
    );
  }

  /// Season numbers as published by TMDB, specials excluded.
  List<int> get _seasonNumbers {
    final numbers = <int>[];
    for (final season in seasons) {
      final value = season is Map ? season['season_number'] : null;
      final number = value is num ? value.toInt() : int.tryParse('$value');
      if (number != null && number > 0) numbers.add(number);
    }
    if (numbers.isEmpty) numbers.add(1);
    numbers.sort();
    return numbers;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final glass = _GlassColors.of(context);
    final provider = tmdbDetailsControllerProvider(movieId, source: source);
    final state = ref.watch(provider);
    final numbers = _seasonNumbers;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      elevation: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 580,
                    maxHeight: 680,
                  ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.50),
                  blurRadius: 50,
                  spreadRadius: 0,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 1. LAYERED TRANSLUCENT OBSIDIAN/CHARCOAL BLACK BASE WITH BACKDROP BLUR
                  Positioned.fill(
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 22.0, sigmaY: 22.0),
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: glass.panel),
                      ),
                    ),
                  ),
                  // Hairline edge on the glass. It used to be wrapped in a full-bleed
                  // ShaderMask that faded the line out over the top and bottom 15% of
                  // the panel: a BlendMode.dstIn mask costs an offscreen surface the
                  // size of the whole sheet, and what it bought was a gradient between
                  // "0.5 dp line at 12% ink" and "no line at all" - a transition
                  // between two states that are already at the edge of visible. The
                  // line itself is kept, and now closes around the top and bottom
                  // corners as well.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: glass.edge, width: 0.5),
                        ),
                      ),
                    ),
                  ),
                  // Main content
                  Positioned.fill(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                    // Header Bar
                    Padding(
                      // Trimmed by the 8dp the standard-density close button
                      // adds below, so the header block keeps its height and
                      // the icon its centre.
                      padding: const EdgeInsets.fromLTRB(18, 10, 8, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Select Episode',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: glass.foreground,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  target.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                    fontSize: 11.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Close button
                          IconButton(
                            tooltip: 'Close',
                            // Compact density would make this a 40dp target,
                            // and desktop picks compact by default; pinning
                            // standard keeps 48dp on every platform.
                            visualDensity: VisualDensity.standard,
                            icon: const Icon(
                              Icons.close_rounded,
                              size: 20,
                              color: Color(0xFFEF4444),
                            ),
                            hoverColor:
                                const Color(0xFFEF4444).withValues(alpha: 0.15),
                            highlightColor:
                                const Color(0xFFEF4444).withValues(alpha: 0.2),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                    ),

                    // Season Filter Chips Rail
                    SizedBox(
                      height: 34,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: numbers.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 6),
                        itemBuilder: (context, index) {
                          final season = numbers[index];
                          final selected = state.selectedSeason == season;
                          return FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: Text(
                              'Season $season',
                              style: TextStyle(
                                fontSize: 11,
                                color: selected
                                    ? cs.onPrimary
                                    : cs.onSurfaceVariant,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                            selected: selected,
                            selectedColor: cs.primary,
                            side: BorderSide(
                              color: selected
                                  ? Colors.transparent
                                  : glass.outline,
                              width: 1,
                            ),
                            backgroundColor: Colors.transparent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                            onSelected: (_) => ref
                                .read(provider.notifier)
                                .fetchEpisodes(season, source: source),
                          );
                        },
                      ),
                    ),

                    const SizedBox(height: 8),

                    // Episode List
                    Expanded(
                      child: FutureBuilder<Map<String, dynamic>?>(
                        future: state.episodesFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          final episodes = List<Map<String, dynamic>>.from(
                            (snapshot.data?['episodes'] as List?) ??
                                const <dynamic>[],
                          );
                          if (episodes.isEmpty) {
                            return Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  'No episodes listed for this season.',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            );
                          }
                          return ListView.separated(
                            padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
                            itemCount: episodes.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final raw = episodes[index];
                              final number = (raw['episode_number'] as num?)
                                      ?.toInt() ??
                                  index + 1;
                              final name = (raw['name'] as String?)?.trim();
                              final displayTitle = name?.isNotEmpty == true
                                  ? name!
                                  : 'Episode $number';
                              final overview =
                                  (raw['overview'] as String?)?.trim() ?? '';
                              final imageUrl = AppImageFallbacks.tmdbStill(
                                raw['still_path'] as String?,
                                label: displayTitle,
                              );
                              final voteAverage = (raw['vote_average'] as num?)
                                      ?.toDouble() ??
                                  0.0;
                              final runtime =
                                  (raw['runtime'] as int?) ?? 0;
                              final hours = runtime ~/ 60;
                              final minutes = runtime % 60;
                              final runtimeText = hours > 0
                                  ? '${hours}h ${minutes}m'
                                  : '${minutes}m';

                              void selectEpisode() {
                                final episode = Episode(
                                  name: displayTitle,
                                  url: '',
                                  season: state.selectedSeason,
                                  episode: number,
                                );
                                Navigator.of(context).pop();
                                PluginSourcesSheet.open(
                                  hostContext,
                                  target,
                                  episode: episode,
                                  mode: mode,
                                );
                              }

                              return _EpisodeItemCard(
                                key: ValueKey('ep_${state.selectedSeason}_$number'),
                                number: number,
                                title: displayTitle,
                                overview: overview,
                                imageUrl: imageUrl,
                                voteAverage: voteAverage,
                                runtimeText: runtimeText,
                                autofocus: index == 0,
                                onSelect: selectEpisode,
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
),
),
),
),
);
  }
}

/// Episode Card with smooth mouse hover expansion and D-Pad focus highlight,
/// matching the CardsWrapper interaction in SkyStream's details screen.
class _EpisodeItemCard extends StatefulWidget {
  final int number;
  final String title;
  final String overview;
  final String? imageUrl;
  final double voteAverage;
  final String runtimeText;
  final bool autofocus;
  final VoidCallback onSelect;

  const _EpisodeItemCard({
    super.key,
    required this.number,
    required this.title,
    required this.overview,
    required this.imageUrl,
    required this.voteAverage,
    required this.runtimeText,
    required this.autofocus,
    required this.onSelect,
  });

  @override
  State<_EpisodeItemCard> createState() => _EpisodeItemCardState();
}

class _EpisodeItemCardState extends State<_EpisodeItemCard> {
  bool _isHovered = false;

  void _setHovered(bool hovered) {
    if (_isHovered == hovered) return;
    setState(() => _isHovered = hovered);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final glass = _GlassColors.of(context);

    // The row is a hand-built button — a bare [InkWell] reports a tap action
    // but no role — and its own text supplies the label.
    return SourceActionSemantics(
      enabled: true,
      child: MouseRegion(
        onEnter: (_) => _setHovered(true),
        onExit: (_) => _setHovered(false),
        cursor: SystemMouseCursors.click,
        child: DpadFocusable(
          autofocus: widget.autofocus,
          onSelect: widget.onSelect,
          child: const SizedBox.shrink(),
          builder: (context, dpadState, _) {
            final isFocused = dpadState.focused;
            return Material(
              color: isFocused
                  ? glass.focusFill
                  : (_isHovered ? glass.hoverFill : Colors.transparent),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                // DpadFocusable above already owns this row's focus node;
                // without this the row is two stops on the D-pad.
                canRequestFocus: false,
                onTap: widget.onSelect,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isFocused
                          ? glass.foreground
                          : (_isHovered
                              ? cs.primary.withValues(alpha: 0.65)
                              : Colors.transparent),
                      width: 1.5,
                    ),
                    boxShadow: _isHovered || isFocused
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Left-side episode thumbnail
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 120,
                          height: 68,
                          child: widget.imageUrl != null &&
                                  widget.imageUrl!.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: widget.imageUrl!,
                                  fit: BoxFit.cover,
                                  placeholder: (_, _) =>
                                      ColoredBox(color: glass.imageFill),
                                  errorWidget: (_, _, _) => ColoredBox(
                                    color: glass.imageFill,
                                    child: Center(
                                      child: Icon(
                                        Icons.movie_outlined,
                                        size: 24,
                                        color: glass.mutedIcon,
                                      ),
                                    ),
                                  ),
                                )
                              : ColoredBox(
                                  color: glass.imageFill,
                                  child: Center(
                                    child: Icon(
                                      Icons.movie_outlined,
                                      size: 24,
                                      color: glass.mutedIcon,
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),

                      // Details column (Title, [E# · Rating · Runtime], Overview)
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: glass.foreground,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: cs.primary.withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    'E${widget.number}',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                      color: cs.primary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (widget.voteAverage > 0) ...[
                                  const Icon(
                                    Icons.star_rounded,
                                    size: 13,
                                    color: Colors.amber,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    widget.voteAverage.toStringAsFixed(1),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                ],
                                if (widget.runtimeText.isNotEmpty &&
                                    widget.runtimeText != '0m')
                                  Text(
                                    widget.runtimeText,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: cs.onSurfaceVariant,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                              ],
                            ),
                            if (widget.overview.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                widget.overview,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: cs.onSurfaceVariant.withValues(
                                    alpha: 0.8,
                                  ),
                                  fontSize: 11,
                                  height: 1.25,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),

                      // Chevron arrow
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: _isHovered || isFocused
                            ? glass.foreground
                            : cs.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
