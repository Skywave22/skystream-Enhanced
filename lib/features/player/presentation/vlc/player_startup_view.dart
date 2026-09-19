/// What the player shows until there is a picture.
///
/// One view for the whole wait - the plugin being asked for links, the top
/// links being checked, a link being opened - and for the dead end when none
/// of them played. It used to be three screens that looked alike and swapped
/// under the viewer, with a Skip button whose meaning changed between them.
/// Here the source list is the control: selecting a row plays that row.
///
/// Data in, callbacks out. The screen decides every word; this decides how it
/// looks and owns only what is purely visual - the list's scroll position and
/// where the remote's focus lands.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../core/utils/image_utils.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/custom_widgets.dart';
import '../../domain/source_row_status.dart';
import '../widgets/player_control_components.dart' show PlayerBackButtonSlot;
import 'panel/player_panel_labels.dart'
    show sourcePlayStateLabel, sourceReachabilityLabel;

/// One row of the source list: what the reachability check found, and how
/// playing the source went - two facts, shown in two columns, never merged.
@immutable
class StartupRow {
  const StartupRow({
    required this.label,
    required this.reachability,
    this.playState = SourcePlayState.untried,
  });

  final String label;
  final SourceReachability reachability;
  final SourcePlayState playState;

  @override
  bool operator ==(Object other) =>
      other is StartupRow &&
      other.label == label &&
      other.reachability == reachability &&
      other.playState == playState;

  @override
  int get hashCode => Object.hash(label, reachability, playState);
}

class PlayerStartupView extends StatefulWidget {
  const PlayerStartupView({
    super.key,
    required this.title,
    required this.onPick,
    required this.onBack,
    this.episodeLine,
    this.logoUrl,
    this.backdropUrl,
    this.sourceName,
    this.status,
    this.reason,
    this.attempt,
    this.rows = const <StartupRow>[],
    this.currentIndex,
    this.failed = false,
    this.onRetry,
    this.onDoubleClick,
    this.isTv = false,
  });

  /// The title's own name - the film, or the series an episode belongs to.
  final String title;

  /// `S1 E3 · Episode name`, for an episode.
  final String? episodeLine;

  /// The title's own logo and backdrop artwork.
  final String? logoUrl;
  final String? backdropUrl;

  /// The link being opened, by its plugin's name for it.
  final String? sourceName;

  /// What the rows cannot say: that links are still being fetched, before
  /// there are rows; something unusual about an open, like a torrent still
  /// being prepared; or, once [failed], why nothing played. Null to leave the
  /// line out - with rows up, they say what is happening.
  final String? status;

  /// Why the link before this one was given up on. Quieter than [status].
  final String? reason;

  /// "Source 2 of 9": 1-based index and the total.
  final ({int index, int total})? attempt;

  /// Empty until the plugin has answered.
  final List<StartupRow> rows;

  /// The row being opened, or null while none is.
  final int? currentIndex;

  /// Every link has been tried. Swaps the spinner for an error and offers
  /// [onRetry].
  final bool failed;

  final ValueChanged<int> onPick;
  final VoidCallback onBack;
  final VoidCallback? onRetry;

  /// Toggles full screen. Null where there is no window to full-screen.
  final VoidCallback? onDoubleClick;

  final bool isTv;

  /// Identifies row [index], for tests and for anything that has to find a row
  /// on screen.
  static Key rowKey(int index) => ValueKey<String>('player-startup-row-$index');

  @override
  State<PlayerStartupView> createState() => _PlayerStartupViewState();
}

class _PlayerStartupViewState extends State<PlayerStartupView> {
  /// Retry's node, so the remote can be handed to it when the last link fails:
  /// autofocus alone does nothing while a row still holds focus.
  final FocusNode _retryFocus = FocusNode(debugLabel: 'player-startup-retry');

  @override
  void didUpdateWidget(PlayerStartupView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isTv && widget.failed && !oldWidget.failed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _retryFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _retryFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final size = MediaQuery.sizeOf(context);
    final backdrop = widget.backdropUrl;
    // As before the libVLC move: a phone's short side cannot give a backdrop
    // and a centred column room to both be read.
    final showBackdrop =
        backdrop != null &&
        backdrop.isNotEmpty &&
        (widget.isTv || size.shortestSide >= 600);

    return Stack(
      fit: StackFit.expand,
      children: [
        // Opaque first, so a backdrop still loading - or never arriving -
        // leaves black, not the video surface underneath.
        const ColoredBox(color: Colors.black),
        if (showBackdrop)
          CachedNetworkImage(
            imageUrl: backdrop,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            memCacheWidth: ImageUtils.coverDecodeWidth(
              context,
              width: size.width,
              height: size.height,
              sourceAspectRatio: ImageUtils.backdropAspectRatio,
            ),
            placeholder: (_, _) => const SizedBox.shrink(),
            errorWidget: (_, _, _) => const SizedBox.shrink(),
          ),
        // A paint, not a layer. No blur either: this sits over a platform
        // view on Android, and a window-sized filter layer there is the cost
        // the opening overlay was written to avoid.
        if (showBackdrop) const ColoredBox(color: Color(0x80000000)),
        // Beneath everything that takes a click, never above it: a
        // double-tap recogniser holds the gesture arena after the first
        // click, so as an ancestor it would delay every row and button by the
        // double-tap timeout. The read-only text above is IgnorePointer so a
        // double-click on it falls through to here.
        if (widget.onDoubleClick != null)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: widget.onDoubleClick,
          ),
        SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: _content(l10n, constraints.maxHeight - 48),
                ),
              ),
            ),
          ),
        ),
        PlayerBackButtonSlot(
          isTv: widget.isTv,
          // Only while nothing else is there to land on: the list takes the
          // remote once it has rows, and Retry once everything has failed.
          autofocus: widget.rows.isEmpty && !widget.failed,
          onPressed: widget.onBack,
        ),
      ],
    );
  }

  /// The logo's height for a column [height] tall, or 0 to leave it out.
  ///
  /// The list is the one part that can shrink, and on a phone held sideways
  /// the logo would take the room it needs.
  double _logoHeight(double height) {
    if (height >= 700) return widget.isTv ? 100 : 80;
    if (height >= 480) return 56;
    return 0;
  }

  Widget _content(AppLocalizations l10n, double height) {
    final logo = widget.logoUrl;
    final logoHeight = _logoHeight(height);
    final attempt = widget.attempt;
    final episodeLine = widget.episodeLine;
    final sourceName = widget.sourceName;
    final status = widget.status;
    final reason = widget.reason;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IgnorePointer(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (logo != null && logo.isNotEmpty && logoHeight > 0) ...[
                _Logo(url: logo, height: logoHeight),
                const SizedBox(height: 20),
              ],
              if (widget.failed)
                Icon(
                  Icons.error_outline_rounded,
                  color: Colors.red.shade300,
                  size: 42,
                )
              else
                const SizedBox.square(
                  dimension: 42,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
              const SizedBox(height: 16),
              Text(
                widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                ),
              ),
              if (episodeLine != null && episodeLine.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  episodeLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ],
              if (sourceName != null && sourceName.isNotEmpty) ...[
                const SizedBox(height: 8),
                // One line: a plugin's name for a link can run to a
                // paragraph, and this column has no room to give on a phone.
                Text(
                  sourceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontSize: 14,
                  ),
                ),
              ],
              if (status != null && status.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  status,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.62),
                    fontSize: 14,
                    height: 1.3,
                  ),
                ),
              ],
              if (reason != null && reason.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  reason,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                ),
              ],
              if (attempt != null) ...[
                const SizedBox(height: 12),
                _Pill(text: l10n.sourceAttempt(attempt.index, attempt.total)),
              ],
            ],
          ),
        ),
        if (widget.failed && widget.onRetry != null) ...[
          const SizedBox(height: 18),
          CustomButton(
            isPrimary: true,
            autofocus: widget.isTv,
            focusNode: _retryFocus,
            onPressed: widget.onRetry,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.refresh_rounded, size: 18),
                  const SizedBox(width: 8),
                  Text(l10n.retry),
                ],
              ),
            ),
          ),
        ],
        if (widget.rows.isNotEmpty) ...[
          const SizedBox(height: 18),
          Flexible(
            child: _SourceList(
              rows: widget.rows,
              currentIndex: widget.currentIndex,
              isTv: widget.isTv,
              onPick: widget.onPick,
            ),
          ),
        ],
      ],
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.url, required this.height});

  final String url;
  final double height;

  @override
  Widget build(BuildContext context) {
    final fallback = SizedBox(height: height);
    if (url.toLowerCase().endsWith('.svg')) {
      return SvgPicture.network(
        url,
        height: height,
        fit: BoxFit.contain,
        placeholderBuilder: (_) => fallback,
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      height: height,
      fit: BoxFit.contain,
      placeholder: (_, _) => fallback,
      errorWidget: (_, _, _) => fallback,
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          text,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.78),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// The rows, following the one being opened.
class _SourceList extends StatefulWidget {
  const _SourceList({
    required this.rows,
    required this.currentIndex,
    required this.isTv,
    required this.onPick,
  });

  final List<StartupRow> rows;
  final int? currentIndex;
  final bool isTv;
  final ValueChanged<int> onPick;

  @override
  State<_SourceList> createState() => _SourceListState();
}

class _SourceListState extends State<_SourceList> {
  /// One row plus its divider. Fixed, so a row's offset is arithmetic.
  static const double _rowExtent = 47;

  final ScrollController _scroll = ScrollController();
  final List<FocusNode> _nodes = <FocusNode>[];

  @override
  void initState() {
    super.initState();
    _syncNodes();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _follow(animate: false);
      // The list is the first thing worth landing on, and it arrives after
      // Back has taken the remote for the wait before it.
      if (widget.isTv) {
        final target = widget.currentIndex ?? 0;
        if (target < _nodes.length) _nodes[target].requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(_SourceList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncNodes();
    // Only when the row being opened changes. Every status that lands on any
    // row rebuilds this, and following on each of those would drag the list
    // back from wherever the viewer had scrolled it.
    if (widget.currentIndex != oldWidget.currentIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _follow(animate: true);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _syncNodes() {
    while (_nodes.length < widget.rows.length) {
      _nodes.add(FocusNode(debugLabel: 'player-startup-row-${_nodes.length}'));
    }
    while (_nodes.length > widget.rows.length) {
      _nodes.removeLast().dispose();
    }
  }

  /// Puts the row being opened second from the top, so the one before it -
  /// usually the link that just failed - stays in view above it.
  void _follow({required bool animate}) {
    final current = widget.currentIndex;
    if (current == null || !_scroll.hasClients) return;
    final target = ((current - 1) * _rowExtent).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    if (animate) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  /// Narrower than this and the two status columns become icons: labelled,
  /// they would take most of a portrait phone's list, and the source's own
  /// name is what the viewer is choosing by.
  static const double _compactBelow = 400;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: LayoutBuilder(
            builder: (context, constraints) => ListView.builder(
              controller: _scroll,
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              itemExtent: _rowExtent,
              itemCount: widget.rows.length,
              itemBuilder: (context, index) => _SourceRow(
                key: PlayerStartupView.rowKey(index),
                row: widget.rows[index],
                compact: constraints.maxWidth < _compactBelow,
                isCurrent: index == widget.currentIndex,
                isLast: index == widget.rows.length - 1,
                focusNode: _nodes[index],
                onTap: () => widget.onPick(index),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    super.key,
    required this.row,
    required this.compact,
    required this.isCurrent,
    required this.isLast,
    required this.focusNode,
    required this.onTap,
  });

  final StartupRow row;

  /// Icons for both columns rather than words; see
  /// [_SourceListState._compactBelow].
  final bool compact;
  final bool isCurrent;
  final bool isLast;
  final FocusNode focusNode;
  final VoidCallback onTap;

  /// Wide enough for "Unreachable" beside its icon, so the column lines up
  /// down the list; a longer translation ellipsises rather than pushing it.
  static const double _reachabilityWidth = 104;

  /// Wide enough for "Opening…". Kept even when empty, so the reachability
  /// column stays in the same place on a row nobody has opened.
  static const double _playStateWidth = 72;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final reachability = sourceReachabilityLabel(l10n, row.reachability);
    final playState = sourcePlayStateLabel(l10n, row.playState);
    // Null for a source nobody has checked, which leaves its column blank:
    // here a blank already reads as "not asked yet", and every row past the
    // top three saying so would be noise. The Sources panel still says it.
    final reachLook = _reachabilityLook(row.reachability);
    final playColour = _playStateColour(row.playState);

    return DecoratedBox(
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
              ),
      ),
      child: Material(
        color: isCurrent
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.transparent,
        child: InkWell(
          focusNode: focusNode,
          onTap: onTap,
          focusColor: Colors.white.withValues(alpha: 0.18),
          hoverColor: Colors.white.withValues(alpha: 0.06),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              // The name, then what the check found, then how playing went -
              // nothing in front of the name, which only repeated the last.
              children: [
                Expanded(
                  child: Text(
                    row.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (compact) ...[
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 20,
                    child: reachLook == null
                        ? null
                        : Center(
                            child: reachLook.$1(semanticLabel: reachability),
                          ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 20,
                    child: Center(
                      child: _playStateIcon(
                        row.playState,
                        semanticLabel: playState,
                      ),
                    ),
                  ),
                ] else ...[
                  const SizedBox(width: 12),
                  // First column: what the check found.
                  SizedBox(
                    width: _reachabilityWidth,
                    child: reachLook == null
                        ? null
                        : Row(
                            children: [
                              reachLook.$1(semanticLabel: null),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  reachability,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: reachLook.$2,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(width: 8),
                  // Second column: how playing it went, blank until it has
                  // been opened.
                  SizedBox(
                    width: _playStateWidth,
                    child: playState == null
                        ? null
                        : Text(
                            playState,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            // Against the row's end rather than after an empty
                            // stretch of the column; the words still line up,
                            // on their right edge.
                            textAlign: TextAlign.end,
                            style: TextStyle(
                              color: playColour,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Widget _spinner({required Color colour, String? semanticLabel}) =>
      SizedBox.square(
        dimension: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          semanticsLabel: semanticLabel,
          valueColor: AlwaysStoppedAnimation<Color>(colour),
        ),
      );

  /// The check's icon, built with or without a label for a screen reader,
  /// and the colour its word is drawn in - or null when there is nothing to
  /// show, which is a source nobody has checked.
  static (Widget Function({required String? semanticLabel}), Color)?
  _reachabilityLook(SourceReachability reachability) {
    Widget icon(IconData data, Color colour, String? label) =>
        Icon(data, size: 14, color: colour, semanticLabel: label);
    return switch (reachability) {
      SourceReachability.checking => (
        ({required semanticLabel}) =>
            _spinner(colour: Colors.white70, semanticLabel: semanticLabel),
        Colors.white70,
      ),
      SourceReachability.reachable => (
        ({required semanticLabel}) =>
            icon(Icons.check_rounded, Colors.green.shade300, semanticLabel),
        Colors.green.shade300,
      ),
      SourceReachability.unreachable => (
        ({required semanticLabel}) => icon(
          Icons.help_outline_rounded,
          Colors.amber.shade300,
          semanticLabel,
        ),
        Colors.amber.shade300,
      ),
      SourceReachability.notChecked => null,
    };
  }

  /// How playing went, as an icon, for the narrow layout's second column.
  /// Nothing for a source nobody has opened, as the wide layout says nothing.
  static Widget? _playStateIcon(
    SourcePlayState state, {
    String? semanticLabel,
  }) => switch (state) {
    SourcePlayState.untried => null,
    SourcePlayState.opening => _spinner(
      colour: Colors.white,
      semanticLabel: semanticLabel,
    ),
    SourcePlayState.playing => Icon(
      Icons.check_circle,
      size: 16,
      color: Colors.green.shade300,
      semanticLabel: semanticLabel,
    ),
    SourcePlayState.failed => Icon(
      Icons.close_rounded,
      size: 16,
      color: Colors.red.shade300,
      semanticLabel: semanticLabel,
    ),
  };

  static Color _playStateColour(SourcePlayState state) => switch (state) {
    SourcePlayState.untried || SourcePlayState.opening => Colors.white,
    SourcePlayState.playing => Colors.green.shade300,
    SourcePlayState.failed => Colors.red.shade300,
  };
}
