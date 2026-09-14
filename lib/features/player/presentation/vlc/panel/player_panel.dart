/// The player's side panel: Sources, Audio, Subtitles, Episodes and Files in
/// one right-anchored drawer instead of four bottom sheets. The shape lives in
/// player_panel_shell.dart.
///
/// Opening moves focus onto the row that is selected now, not row one. Closing
/// returns focus to the control that opened the panel, which falls out of the
/// panel being a route: the scope below keeps its focused child and gets it
/// back when this one is popped. That is also why the chrome must be held open
/// while the panel is up - the button focus returns to has to still be there.
/// Every row is one focus stop ([PanelRow]), the tab strip is ordinary
/// focusable buttons rather than a scrollable [TabBar], and nothing here
/// hand-routes an arrow key.
///
/// Data is live: the screen publishes a [PanelData] through a
/// `ValueListenable` and the panel rebuilds from it, so a failover, a late
/// probe or a torrent poll moves the tick, the chips and the badges in place.
/// The row a list opens on and focuses is decided once, from the value at
/// open, and a later value never scrolls or refocuses.
///
/// Every size, inset and text alpha comes from [PlayerPanelMetrics], installed
/// once here and read off the context by the rows, badges, subheaders and tabs
/// below. The television ramp is about 1.2x the type, a 48 dp overscan inset
/// and paddings that make a row and a tab one whole focus target.
///
/// The panel is drawn over a platform view. It animates in with a
/// [SlideTransition] - a transform, not a window-sized opacity layer - and its
/// surface is opaque, with no blur anywhere. The five rules in
/// vlc_player_controls.dart apply here in full.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../../../core/domain/entity/multimedia_item.dart';
import '../../../../../l10n/generated/app_localizations.dart';
import '../../widgets/hotstar_player_style.dart';
import '../torrent_file_sheet.dart';
import 'player_episodes_tab.dart';
import 'player_files_tab.dart';
import 'player_panel_data.dart';
import 'player_panel_metrics.dart';
import 'player_panel_row.dart';
import 'player_panel_shell.dart';
import 'player_sources_tab.dart';
import 'player_tracks_tab.dart';

export 'player_panel_data.dart'
    show EpisodeProgress, EpisodeProgressLookup, PanelData;

/// The panel's tabs, in the order they are shown.
enum PlayerPanelTab { sources, audio, subtitles, episodes, files }

/// Which tabs the panel would show for these lists. The panel strip and the
/// bottom-bar buttons both read this, so a button can never open a tab that
/// does not exist.
///
/// Audio and Subtitles are always present: an empty list is still something to
/// say. One episode or one file is not a choice, so neither gets a tab.
Set<PlayerPanelTab> availablePanelTabs({
  required int sourceCount,
  required int episodeCount,
  required int fileCount,
}) => <PlayerPanelTab>{
  if (sourceCount > 0) PlayerPanelTab.sources,
  PlayerPanelTab.audio,
  PlayerPanelTab.subtitles,
  if (episodeCount > 1) PlayerPanelTab.episodes,
  if (fileCount > 1) PlayerPanelTab.files,
};

/// Opens the panel over the player and resolves when it closes.
///
/// The caller holds the chrome open for the life of the future
/// (`ChromeVisibilityController.whileHeld`), so the bars cannot vanish
/// underneath a panel and the control that opened it is still on screen to
/// take focus back.
///
/// [data] is live: the panel follows a new [PanelData] without being reopened.
///
/// [onOpened] hands back the panel's own context so the screen can register it
/// with its one guarded Back path. On a television Back arrives both as a
/// route pop and as a key event, and without a single owner one press can
/// close the panel and leave playback in the same frame.
///
/// [episodeProgress] is how the Episodes tab knows which episodes have been
/// seen. It is a function rather than data because the panel has no
/// `ProviderScope` to read the repositories from and because the answer must
/// not be computed for rows nobody scrolled to.
Future<void> showPlayerPanel(
  BuildContext context, {
  required VlcPlayerController controller,
  required PlayerPanelTab initialTab,
  required ValueListenable<PanelData> data,
  bool isTv = false,
  bool focusOnOpen = false,
  ValueChanged<int>? onPickSource,
  ValueChanged<Episode>? onPickEpisode,
  ValueChanged<TorrentFile>? onPickFile,
  ValueChanged<BuildContext>? onOpened,
  EpisodeProgressLookup? episodeProgress,
}) {
  return Navigator.of(context).push<void>(
    _PlayerPanelRoute(
      isTv: isTv,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      builder: (routeContext) {
        onOpened?.call(routeContext);
        return PlayerPanel(
          controller: controller,
          initialTab: initialTab,
          data: data,
          isTv: isTv,
          focusOnOpen: focusOnOpen,
          onPickSource: onPickSource,
          onPickEpisode: onPickEpisode,
          onPickFile: onPickFile,
          episodeProgress: episodeProgress,
          onClose: () => Navigator.of(routeContext).pop(),
        );
      },
    ),
  );
}

/// A modal that leaves the video playing behind it.
///
/// [PopupRoute] rather than `showModalBottomSheet`: this one has to keep the
/// route below built and visible, own its own transition (a slide, never a
/// window-sized fade), and take its shape from the window.
class _PlayerPanelRoute extends PopupRoute<void> {
  _PlayerPanelRoute({
    required this.builder,
    required this.isTv,
    required this.barrierLabel,
  });

  final WidgetBuilder builder;
  final bool isTv;

  @override
  final String barrierLabel;

  /// A plain colour, drawn by the framework's own barrier: a [ColoredBox], not
  /// an opacity layer over the video.
  @override
  Color get barrierColor => const Color(0x8A000000);

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => HotstarPlayerStyle.panelMotionDuration;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return builder(context);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final shape = playerPanelShapeFor(MediaQuery.sizeOf(context), isTv: isTv);
    return SlideTransition(
      position:
          Tween<Offset>(
            begin: playerPanelSlideFrom(shape),
            end: Offset.zero,
          ).animate(
            CurvedAnimation(parent: animation, curve: Curves.fastOutSlowIn),
          ),
      child: child,
    );
  }
}

/// The panel's content. Split from the route so a test can pump it directly.
class PlayerPanel extends StatefulWidget {
  const PlayerPanel({
    required this.controller,
    required this.initialTab,
    required this.data,
    required this.onClose,
    this.isTv = false,
    this.focusOnOpen = false,
    this.onPickSource,
    this.onPickEpisode,
    this.onPickFile,
    this.episodeProgress,
    super.key,
  });

  final VlcPlayerController controller;
  final PlayerPanelTab initialTab;

  /// What the panel shows, live. Read once at open for the anchor row; every
  /// later value redraws the tick, chips and badges in place.
  final ValueListenable<PanelData> data;

  final VoidCallback onClose;
  final bool isTv;

  /// Whether a row takes focus as the panel opens. False on touch, where a
  /// focus ring nobody asked for is just a mark on the screen.
  final bool focusOnOpen;

  final ValueChanged<int>? onPickSource;
  final ValueChanged<Episode>? onPickEpisode;
  final ValueChanged<TorrentFile>? onPickFile;

  /// Which episodes have been seen, asked one built row at a time. Not part of
  /// [data]: a closure has no `==`, and [PanelData]'s equality is what keeps
  /// the panel still under the screen's republishes.
  final EpisodeProgressLookup? episodeProgress;

  @override
  State<PlayerPanel> createState() => _PlayerPanelState();
}

class _PlayerPanelState extends State<PlayerPanel> {
  /// The data as it stood when the panel opened. The row each list opens on
  /// and focuses is decided from this and never revisited, so a failover or a
  /// torrent poll after open ticks a different row rather than scrolling the
  /// list or moving focus.
  late final PanelData _opened = widget.data.value;

  /// The tab the viewer is on - the one they opened, or the one they picked.
  late PlayerPanelTab _tab;

  /// The tab actually on screen. Usually [_tab]; while live data has taken
  /// that tab away (Files after the torrent stopped) it is the first tab that
  /// is left, and [_tab] is remembered so the viewer's own tab comes back if
  /// the data does.
  late PlayerPanelTab _shown;

  late Future<_PanelTracks> _tracks;

  /// The engine's track revision the list was last read under. The engine owns
  /// both the list and the selection, so when the revision moves - a side-car
  /// landing after the panel opened, a stream announcing its audio late - the
  /// list is re-read here without a Retry. The panel holds no selection state.
  late int _seenRevision;

  /// Whether the viewer has switched tab. Only the tab the panel opened on
  /// autofocuses a row: after a switch, focus belongs on the tab button that
  /// was just pressed.
  bool _switchedTab = false;

  /// Whether the track list has been re-read since the last tab switch. A
  /// reload swaps the Future and the spinner unmounts every row, the focused
  /// one included, so on a switched-to tab nothing would claim focus again;
  /// after a reload the rows may autofocus once more, landing on the active
  /// row.
  bool _reloadedSinceSwitch = false;

  @override
  void initState() {
    super.initState();
    final tabs = _tabsOf(_opened);
    _tab = tabs.contains(widget.initialTab) ? widget.initialTab : tabs.first;
    _shown = _tab;
    _seenRevision = widget.controller.value.trackRevision;
    widget.controller.addListener(_onEngine);
    _tracks = _loadTracks();
  }

  @override
  void didUpdateWidget(covariant PlayerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onEngine);
      widget.controller.addListener(_onEngine);
      _seenRevision = widget.controller.value.trackRevision;
      _reloadTracks();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onEngine);
    super.dispose();
  }

  /// Every controller notification, most of them position ticks. Only a moved
  /// revision does anything: the tick itself is the tab's business.
  void _onEngine() {
    final revision = widget.controller.value.trackRevision;
    if (revision == _seenRevision || !mounted) return;
    _seenRevision = revision;
    _reloadTracks();
  }

  /// Read when the viewer asks for them, the only point at which the engine's
  /// answer is reliable.
  Future<_PanelTracks> _loadTracks() async {
    final audio = await widget.controller.getAudioTracks();
    final subtitle = await widget.controller.getSubtitleTracks();
    VlcMediaInfo? info;
    try {
      info = await widget.controller.getMediaInfo();
    } catch (_) {
      // Detail only. A track list without codecs is still a track list.
      info = null;
    }
    return _PanelTracks(audio: audio, subtitle: subtitle, info: info);
  }

  /// Re-reads the lists, from Retry or from the engine's revision moving. The
  /// rows remount and re-anchor on the active one.
  void _reloadTracks() {
    // Block body on purpose: `=> setState(() => _tracks = _loadTracks())`
    // returns the assigned Future out of the callback, which trips setState's
    // own assertion before it ever calls markNeedsBuild.
    setState(() {
      _tracks = _loadTracks();
      _reloadedSinceSwitch = true;
    });
  }

  /// The tabs [data] would show, in enum order - the same helper the bottom
  /// bar reads.
  List<PlayerPanelTab> _tabsOf(PanelData data) {
    final tabs = data.tabs;
    return PlayerPanelTab.values.where(tabs.contains).toList(growable: false);
  }

  void _select(PlayerPanelTab tab) {
    // Both, not just [_shown]: while live data has substituted a tab, pressing
    // the tab on screen is the viewer choosing it. Returning early would leave
    // [_tab] on the vanished tab, and the panel would switch itself back the
    // moment the data returned.
    if (tab == _tab && tab == _shown) return;
    setState(() {
      _tab = tab;
      _shown = tab;
      _switchedTab = true;
      _reloadedSinceSwitch = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final shape = playerPanelShapeFor(
      MediaQuery.sizeOf(context),
      isTv: widget.isTv,
    );
    // The panel is a PopupRoute and inherits nothing from the screen's tree,
    // so its type scale, insets and text alphas are installed once here and
    // everything below reads them off the context.
    final metrics = PlayerPanelMetrics.forTv(widget.isTv);

    return Actions(
      actions: <Type, Action<Intent>>{
        // Escape, from a desktop keyboard. Back is deliberately not handled
        // here: on Android it arrives as a route pop the Navigator already
        // owns, and taking it twice would close the panel and the player.
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            widget.onClose();
            return null;
          },
        ),
      },
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: PlayerPanelMetricsScope(
          metrics: metrics,
          child: PlayerPanelShell(
            shape: shape,
            metrics: metrics,
            // One builder around strip and body together, so both read the
            // same value and the strip can never offer a tab the body cannot
            // show.
            child: ValueListenableBuilder<PanelData>(
              valueListenable: widget.data,
              builder: (context, data, _) {
                final tabs = _tabsOf(data);
                // Computed, not set: the value that took a tab away arrives
                // from a listener, where setState would be a rebuild inside a
                // build.
                final shown = tabs.contains(_tab) ? _tab : tabs.first;
                if (shown != _shown) {
                  // The data, not the viewer, changed what is on screen. The
                  // rows are gone either way, so the remount is a fresh open
                  // rather than a switch: on a remote the new list must take
                  // focus or nothing in the panel holds it.
                  _shown = shown;
                  _switchedTab = false;
                  _reloadedSinceSwitch = false;
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _header(l10n, tabs, shown),
                    Divider(height: 1, thickness: 1, color: metrics.divider),
                    Expanded(
                      // A key per tab so switching gives the new list a fresh
                      // viewport rather than the previous tab's scroll offset,
                      // and the same element across data rebuilds of one tab so
                      // scroll position, centring and row focus survive.
                      child: KeyedSubtree(
                        key: ValueKey<PlayerPanelTab>(shown),
                        child: _body(l10n, data, shown),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Tab strip plus close. A [Row] of ordinary buttons, not a [TabBar]: a
  /// scrollable strip traps directional focus, and a Material tab is two nodes
  /// where a remote needs one.
  ///
  /// The tabs sit in a [Wrap], not in a row of [Expanded]s. Five equal columns
  /// of a drawer give each tab about 62 dp of text, which ellipsises
  /// `Subtitles` in English and cannot hold the Hindi or Kannada labels at
  /// all. Intrinsically-sized tabs take the width their word needs and fall
  /// onto a second line when the words run out of room, still one focus stop
  /// per tab and still no [Scrollable].
  Widget _header(
    AppLocalizations l10n,
    List<PlayerPanelTab> tabs,
    PlayerPanelTab shown,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 4, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Wrap(
              spacing: 4,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                for (final tab in tabs)
                  _PanelTabButton(
                    label: _tabLabel(l10n, tab),
                    selected: tab == shown,
                    onPressed: () => _select(tab),
                  ),
              ],
            ),
          ),
          _PanelIconButton(
            icon: Icons.close_rounded,
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  String _tabLabel(AppLocalizations l10n, PlayerPanelTab tab) => switch (tab) {
    PlayerPanelTab.sources => l10n.sources,
    PlayerPanelTab.audio => l10n.audio,
    PlayerPanelTab.subtitles => l10n.subtitles,
    PlayerPanelTab.episodes => l10n.episodes,
    PlayerPanelTab.files => l10n.playerFiles,
  };

  /// Position in the opening episode list of the episode that was playing
  /// then; the first row when nothing was.
  int get _openedEpisodeAnchor {
    final current = _opened.currentEpisode;
    return current == null ? 0 : _opened.episodes.indexOf(current);
  }

  Widget _body(AppLocalizations l10n, PanelData data, PlayerPanelTab shown) {
    // Still true across the first few rebuilds on purpose: the track lists
    // arrive from the engine a frame or two after the panel does, and the row
    // to land on does not exist until they do.
    final autofocus = widget.focusOnOpen && !_switchedTab;

    // Live data for the tick, the chips and the badges; the anchor - where the
    // list opens and focus lands - from the value at open, so neither moves
    // when the screen publishes.
    switch (shown) {
      case PlayerPanelTab.sources:
        return PlayerSourcesTab(
          sources: data.sources,
          currentIndex: data.currentSourceIndex,
          anchorIndex: _opened.currentSourceIndex,
          probes: data.probes,
          qualityFilteredFallback: data.qualityFilteredFallback,
          autofocus: autofocus,
          // Close first, then pick: on a television the panel covers the
          // video, and the viewer wants to see whether the new source plays.
          onPick: (index) {
            widget.onClose();
            widget.onPickSource?.call(index);
          },
        );
      case PlayerPanelTab.audio:
      case PlayerPanelTab.subtitles:
        // A reload unmounts every row, so on a switched-to tab the list may
        // autofocus again.
        return _tracksTab(
          l10n,
          data,
          isAudio: shown == PlayerPanelTab.audio,
          autofocus:
              widget.focusOnOpen && (!_switchedTab || _reloadedSinceSwitch),
        );
      case PlayerPanelTab.episodes:
        return PlayerEpisodesTab(
          episodes: data.episodes,
          currentEpisode: data.currentEpisode,
          anchorIndex: _openedEpisodeAnchor,
          autofocus: autofocus,
          episodeProgress: widget.episodeProgress,
          onPick: (episode) {
            widget.onClose();
            widget.onPickEpisode?.call(episode);
          },
        );
      case PlayerPanelTab.files:
        return PlayerFilesTab(
          files: data.files,
          currentIndex: data.currentFileIndex,
          // A server id, like currentIndex. No file playing at open means an
          // id no file has, which the tab reads as "the first row".
          anchorIndex: _opened.currentFileIndex ?? -1,
          autofocus: autofocus,
          onPick: (file) {
            widget.onClose();
            widget.onPickFile?.call(file);
          },
        );
    }
  }

  Widget _tracksTab(
    AppLocalizations l10n,
    PanelData data, {
    required bool isAudio,
    required bool autofocus,
  }) {
    // The Future is a State field: a data rebuild reuses it rather than asking
    // the engine again.
    return FutureBuilder<_PanelTracks>(
      future: _tracks,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return PanelEmpty(
            text: l10n.playerCouldNotReadTracks('${snapshot.error}'),
          );
        }
        final tracks = snapshot.data!;
        return PlayerTracksTab(
          controller: widget.controller,
          kind: isAudio ? PlayerTrackKind.audio : PlayerTrackKind.subtitle,
          tracks: isAudio ? tracks.audio : tracks.subtitle,
          trackInfo: isAudio
              ? tracks.info?.audioTracks ?? const <VlcMediaTrackInfo>[]
              : tracks.info?.subtitleTracks ?? const <VlcMediaTrackInfo>[],
          target: data.subtitleTarget,
          isTv: widget.isTv,
          autofocus: autofocus,
          onTracksChanged: _reloadTracks,
        );
      },
    );
  }
}

/// One track list read, as the engine sees it.
class _PanelTracks {
  const _PanelTracks({required this.audio, required this.subtitle, this.info});

  final List<VlcTrackDescription> audio;
  final List<VlcTrackDescription> subtitle;

  /// Null when the engine would not answer. Only ever used for detail.
  final VlcMediaInfo? info;
}

/// A tab header: one focus stop, activated by tap or Select.
class _PanelTabButton extends StatefulWidget {
  const _PanelTabButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<_PanelTabButton> createState() => _PanelTabButtonState();
}

class _PanelTabButtonState extends State<_PanelTabButton> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected;
    final metrics = PlayerPanelMetrics.of(context);
    return Semantics(
      button: true,
      selected: active,
      label: widget.label,
      child: Focus(
        onFocusChange: (value) => setState(() => _focused = value),
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.space ||
              key == LogicalKeyboardKey.gameButtonA) {
            widget.onPressed();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            // A floor on the width, because a Wrap gives a tab exactly the
            // width of its word: `Files` is 37 dp of Roboto at the touch ramp's
            // 13 sp, and three of those 4 dp apart is a mis-tap rather than a
            // tab strip.
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: metrics.tabMinWidth),
              child: AnimatedContainer(
                duration: HotstarPlayerStyle.fastMotionDuration,
                padding: EdgeInsets.symmetric(
                  horizontal: metrics.tabHorizontalPadding,
                  vertical: metrics.tabVerticalPadding,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: _focused
                      ? HotstarPlayerStyle.focus
                      : (_hovered
                            ? const Color(0xFF151A22)
                            : Colors.transparent),
                  border: Border(
                    bottom: BorderSide(
                      color: active
                          ? HotstarPlayerStyle.accent
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Text(
                  widget.label,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active
                        ? HotstarPlayerStyle.primaryText
                        : metrics.secondaryText,
                    fontSize: metrics.tabLabelSize,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w600,
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

/// The close button. Its own widget for the same reason the rows are: an
/// [IconButton] would bring a Material ink response and a second focus node.
class _PanelIconButton extends StatefulWidget {
  const _PanelIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<_PanelIconButton> createState() => _PanelIconButtonState();
}

class _PanelIconButtonState extends State<_PanelIconButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final metrics = PlayerPanelMetrics.of(context);
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: Focus(
        onFocusChange: (value) => setState(() => _focused = value),
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final key = event.logicalKey;
          // The same four keys a row and a tab take: a game controller's A is
          // Select on the remotes that are also gamepads.
          if (key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.space ||
              key == LogicalKeyboardKey.gameButtonA) {
            widget.onPressed();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Tooltip(
          message: widget.tooltip,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onPressed,
              child: Container(
                margin: const EdgeInsets.only(left: 4),
                padding: EdgeInsets.all(metrics.closeButtonPadding),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _focused
                      ? HotstarPlayerStyle.focus
                      : Colors.transparent,
                ),
                child: Icon(
                  widget.icon,
                  size: metrics.iconSize,
                  color: HotstarPlayerStyle.primaryText,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
