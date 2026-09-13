import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart'
    show ProviderListenable;
import 'package:vlc_player/vlc_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/network/http_defaults.dart';
import '../../../../core/providers/device_info_provider.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import '../../../../core/extensions/providers.dart';
import '../../../../core/models/torrent_status.dart';
import '../../../../core/services/download_service.dart';
import '../../../../core/services/local_proxy_service.dart';
import '../../../../core/storage/episode_watch_repository.dart';
import '../../../../core/storage/history_repository.dart';
import '../../../../core/utils/app_utils.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../domain/episode_navigator.dart';
import '../../../skip/data/skip_service.dart';
import '../../domain/clear_key.dart';
import '../../domain/playback_progress.dart';
import '../../domain/playback_recovery.dart';
import '../../domain/side_car_subtitles.dart';
import '../../domain/skip_segments.dart';
import '../../domain/playback_tracker.dart';
import '../../domain/stream_resolver.dart';
import '../../domain/subtitle_search_target.dart';
import '../../domain/subtitle_style.dart';
import '../player_debug_flags.dart';
import '../player_platform_service.dart';
import '../subtitle_search_provider.dart' show subtitleLanguageProvider;
import 'chrome_visibility_controller.dart';
import 'ended_card.dart';
import 'next_episode_countdown.dart';
import 'panel/player_panel.dart';
import 'player_value_selector.dart';
import 'resume_hint.dart';
import 'torrent_file_sheet.dart';
import 'vlc_player_controls.dart';

/// Playback on the VLC engine.
///
/// Built up over the migration notes phases 5 through 6.8: engine-owned
/// tracks, resolution of the route's plugin token into a real stream, headers
/// that libVLC can actually transmit, progress and resume, completion and
/// scrobbling, and source failover.
///
/// The screen is the only place the pieces meet, and it stays a hub rather than
/// an implementation: liveness, resume, failover, recovery, ClearKey, side-car
/// subtitles and the platform's PiP and orientation all live in files that can
/// be tested without an engine. What is left here is when to call them.
class VlcPlayerScreen extends ConsumerStatefulWidget {
  const VlcPlayerScreen({
    required this.item,
    required this.videoUrl,
    this.episode,
    this.preloadedStreams,
    super.key,
  });

  final MultimediaItem item;

  /// The plugin's resolution token, **not** a URL. See [resolvePlayback].
  final String videoUrl;

  final Episode? episode;

  /// Sources already aggregated by a source sheet. When present, no plugin
  /// call is made.
  final List<StreamResult>? preloadedStreams;

  @override
  ConsumerState<VlcPlayerScreen> createState() => _VlcPlayerScreenState();
}

enum _Stage { resolving, playing, failed }

/// What an end-of-media advance did, which is the whole question the ended
/// card answers.
///
/// A bool would have to conflate "an advance is already in flight, leave it
/// alone" with "nothing follows, put the card up", and the outgoing engine
/// really does deliver a late `ended` while the next episode is loading - so
/// that conflation would raise a card over an episode about to play.
enum _Advance {
  /// The next episode is loading, or an advance already in flight owns the
  /// transition. There is nothing to card.
  playing,

  /// Nothing follows: a film, or the last episode located in the list.
  finished,

  /// An episode follows, but the viewer declined it during the credits, so it
  /// was not started. Owner decision 2: the refusal is honoured, and the card
  /// offers the episode back rather than the advance taking it anyway.
  declined,
}

/// How many times one source is re-opened before moving to the next. Only
/// applies to a source that actually produced frames — one that never played is
/// simply dead and gets no retries.
const int _kSameSourceRetries = 2;

/// How many times a live feed is reopened before giving up on that source.
/// Reset as soon as playback actually resumes, so an all-evening channel that
/// drops once an hour never exhausts it.
const int _kMaxLiveReconnects = 5;

/// Breathing room before reopening a dropped live feed. Without it a dead URL
/// ends instantly and the reopen becomes a hot loop.
const Duration _kLiveReconnectDelay = Duration(seconds: 2);

/// How long an attempt must run before its recovery budgets are handed back.
///
/// Not the first frame: a source that plays three seconds after every reopen
/// would otherwise refill its own retry budget forever and never fail over.
const Duration _kHealthyPlayback = Duration(seconds: 30);

/// How often the stall watchdog looks. One second is far finer than any of its
/// thresholds and costs nothing — the check is arithmetic on two counters.
const Duration _kWatchdogTick = Duration(seconds: 1);

/// How long after Back has put the bars away a second Back is taken for the
/// same press. Some televisions deliver one press twice — as a key event and
/// as a `popRoute` in the same frame — and without this the echo would pop the
/// route the first delivery had just decided to keep. Short enough not to eat
/// a deliberate second press.
const Duration _kBackEcho = Duration(milliseconds: 300);

/// How long a locked screen gives the viewer to confirm that Back really did
/// mean "leave", after the first press was spent revealing the unlock chip.
///
/// Two seconds is long enough to be a deliberate second press and short enough
/// that a stray contact minutes later starts the two-press sequence over
/// rather than finishing one nobody remembers beginning — which is the whole
/// point of a lock. Comfortably longer than [_kBackEcho], so the same-press
/// echo is always swallowed inside it.
const Duration _kLockBackEscape = Duration(seconds: 2);

/// The opaque panel that covers the video between `setMedia` and the first
/// frame. Public because the invariant it stands for — that the viewer is
/// never shown a black rectangle with a seek bar over it — is worth a test.
const Key openingOverlayKey = Key('player-opening-overlay');

/// How far from the end the up-next card appears. Matches the old overlay
/// (38da335:player_controller.dart:2132) and the card's own countdown, so the
/// offer and the advance land at roughly the same moment.
const Duration _kNextEpisodeLeadIn = Duration(seconds: 15);

class _VlcPlayerScreenState extends ConsumerState<VlcPlayerScreen>
    with WidgetsBindingObserver, WindowListener {
  /// The screen owns the controller, and its lifetime is exactly this State's.
  ///
  /// This is the ownership the migration plan calls for and the old player got
  /// wrong: PlayerController is ref.keepAlive()'d while PlayerScreen owns and
  /// disposes the actual Player, which is why per-session state leaked across
  /// episodes there. Starting correct is free; retrofitting it is not.
  late final VlcPlayerController _controller;

  /// Whether the bars are up. Owned here rather than by the controls because
  /// two decisions about them are the screen's: Back puts them away before it
  /// ever pops (see [_hideChromeForBack]), and they must outlive the controls,
  /// which come and go with [_sawFrames] across every failover and episode
  /// advance. The controls are lent it and neither construct nor dispose one.
  late final ChromeVisibilityController _chrome;

  /// Armed when Back has just put the bars away; while it runs a second Back
  /// is the same press arriving again. Held as a Timer rather than a timestamp
  /// for the same reason [_skipCooldown] is: teardown can cancel it, and the
  /// test clock can run it out.
  Timer? _backEcho;

  /// Whether the screen is locked against accidental touches.
  ///
  /// Owned here, not by [VlcPlayerControls], and that is the fix for
  /// 38da335's one fatal flaw: its `_isLocked` lived in a widget State that
  /// the screen's Back handling could not see, so an edge swipe left the
  /// player while locked - on an Android phone, the one device the lock
  /// existed for. Back is decided in [_handleBack]; the flag it is decided
  /// against has to be readable from there. It also outlives the controls,
  /// which are rebuilt from scratch on every failover and episode advance.
  ///
  /// Lent to the controls only on `PlayerFormFactor.isTouch`, so on a
  /// television and on a desktop there is no padlock and no chip to build
  /// from - absent by construction rather than hidden. Never written from
  /// here except to *clear* it; only the padlock sets it.
  final ValueNotifier<bool> _locked = ValueNotifier<bool>(false);

  /// The window in which a second Back means "I really do want out".
  ///
  /// Armed by the first Back arriving on a locked screen, which is spent on
  /// revealing the unlock chip instead of leaving. Same shape as [_backEcho]
  /// and cancelled in the same place, but deliberately a second field rather
  /// than a second meaning for that one: [_backEcho] is 300 ms and answers
  /// "is this the same press arriving twice", this is two seconds and answers
  /// "is this a deliberate second press". Conflating them would make one
  /// press delivered twice by the platform read as an escape.
  Timer? _lockEscape;

  _Stage _stage = _Stage.resolving;

  /// Guards Skip against remote key-repeat; see [_skip]. Held as a Timer so
  /// teardown can cancel it - a bare delayed future outlives the State.
  Timer? _skipCooldown;
  bool get _skipping => _skipCooldown?.isActive ?? false;
  String _error = '';

  /// Shown under the spinner while opening, when there is something worth
  /// saying - a cold magnet link can take a long time to become playable.
  String _status = '';

  /// Why the last source was given up on, shown under the source line while
  /// the next one opens. Its own field rather than a write to [_status]:
  /// [_failAttempt] and the [_openAttempt] it calls run in one synchronous
  /// stretch, so a reason written to the status line was replaced by the
  /// source name before a frame was ever drawn - which is why "the source
  /// stopped responding" never appeared despite the comment that said it
  /// would. Cleared by the first frame, which is the moment it stops being
  /// news.
  String? _failReason;
  bool _disposed = false;

  PlaybackProgressRecorder? _recorder;
  PlaybackTracker? _tracker;

  /// The last position/duration pair observed while playback was actually
  /// running. Teardown writes this rather than asking the engine, because by
  /// then the engine reports zero — see playback_progress.dart.
  ///
  /// Scoped to **one attempt**: it is also the answer to "did this source ever
  /// play", and a sample left over from the previous source answers for the
  /// wrong media. Where to resume is a separate question, kept in
  /// [_resumePosition], because that one does have to outlive the attempt.
  ProgressSample? _sample;

  /// Whether the current attempt has produced any playback at all.
  ///
  /// Distinct from `_sample != null`, which is the stricter question of
  /// whether there is anything worth writing to history: a livestream reports
  /// no duration and a short clip is below the resumable threshold, so neither
  /// ever produces a sample, and neither should be mistaken for a source that
  /// failed to start.
  bool _sawFrames = false;

  /// Whether the engine has been handed this attempt's media yet.
  ///
  /// Until it has, every tick describes the outgoing media: `setMedia` is the
  /// last await in an open, and the engine keeps playing what it had through
  /// the download lookup, the resolve and the proxy handshake before it. A
  /// tick from there says playback is alive, and nothing else - it is not this
  /// attempt's first frame, and its position is not a resume point for media
  /// that may be a different episode.
  bool _handedToEngine = false;

  /// Where playback should pick up: the last position actually observed, or
  /// the stored resume point until the first sample lands.
  ///
  /// Survives failover by design. Losing the viewer's place is the one thing
  /// recovery must never do, and it is exactly what happens if the position is
  /// read back from a controller that `setMedia` has already zeroed.
  Duration _resumePosition = Duration.zero;

  /// Identifies this media session. Stamped onto every sample so a value that
  /// still describes the previous media cannot be written against this one.
  int _token = 0;

  /// The pre-resolution source URL, which is what the resolver's saved-source
  /// lookup matches on. Deliberately not the proxied URL.
  String? _lastStreamUrl;

  ResolvedPlayback? _resolved;
  ResumePoint? _initialResume;

  /// The candidate list as soon as resolution knows it, which is well before
  /// it knows which one to open. Held apart from [_resolved] because the whole
  /// point is to have something to show the viewer *during* that decision.
  List<StreamResult> _candidates = const <StreamResult>[];

  /// How each probed candidate is doing, in the order the probes were
  /// dispatched — which is also the failover order, so the first entry still
  /// reading `trying` is the source the player is waiting on.
  final Map<int, ProbeOutcome> _probes = <int, ProbeOutcome>{};

  /// Identifies the resolve in flight. Bumped by every [_start], and carried
  /// by the callbacks that resolve hands out, so an answer from a resolve that
  /// has been superseded can be dropped rather than written.
  ///
  /// The probe race deliberately reports a candidate that answers after the
  /// race is over (see `stream_resolver.dart`'s `record`), and a HEAD or
  /// ranged GET can take seconds. By then an episode advance may have started
  /// another resolve, and both [_candidates] and [_probes] are keyed by index
  /// into a list that is no longer the one on screen.
  int _resolveGeneration = 0;

  /// The media the published source list describes.
  ///
  /// The keep-previous rule in [_publishPanelData] needs to tell a re-resolve
  /// of *this* episode from an advance to the next one; nothing else on the
  /// screen distinguishes them at the moment the list is published.
  Object? _publishedSourcesMedia;

  /// Completed when the viewer refuses to wait for the health probe. Null once
  /// resolution is past it, which is how Skip knows it now means "abandon the
  /// source the engine is opening" instead.
  Completer<void>? _skipProbe;

  /// The episode currently playing. Mutable because advancing swaps media on
  /// this same State rather than pushing a new route.
  Episode? _episode;

  /// The plugin token for [_episode]. Starts as the route's, then follows.
  late String _videoUrl;

  /// Sources the route pre-aggregated. They belong to the FIRST episode only,
  /// so advancing must drop them or the next episode plays this one's streams.
  List<StreamResult>? _preloaded;

  /// One advance at a time. The engine's ended event, a retry and any future
  /// button can all land within the same second.
  bool _advancing = false;

  /// Cancellation token for the open chain. Bumped on every attempt, so a
  /// failover that completes late cannot overwrite a newer one.
  int _generation = 0;
  int _attemptIndex = 0;
  int _attemptRetries = 0;

  /// Candidates opened during the current failover walk, so the walk can wrap
  /// past the end of the list without becoming a loop. Cleared once a source
  /// has played for [_kHealthyPlayback] — see [_onProgress].
  final Set<int> _tried = <int>{};

  /// Set while a hand-picked source is on trial, holding the session it
  /// interrupted. A pick that will not open must cost the viewer nothing, so
  /// its failure restores this instead of walking the failover ladder.
  ({int index, Duration position})? _revertTo;

  /// Whether the current attempt is a torrent, which is allowed far longer to
  /// produce its first frame — it is waiting on pieces, not on a socket.
  bool _attemptIsTorrent = false;

  /// How long the current attempt has been running, and how long since the
  /// position last moved. Together they are the watchdog's whole input.
  ///
  /// Counted by the watchdog's own tick rather than read off the wall clock. A
  /// clock correction mid-play - NTP, a television coming out of standby -
  /// would otherwise read as a stall and fail a healthy source over; and a
  /// count the test clock drives is the only kind a test can hurry.
  Duration _attemptAge = Duration.zero;
  Duration _stalledFor = Duration.zero;

  /// The highest watchdog rung already fired for the current stall, so each
  /// fires once. Cleared the moment the position moves.
  StallAction _lastStallAction = StallAction.none;
  Timer? _watchdog;

  /// The tallest adaptive rendition this session may be handed.
  ///
  /// Seeded in [initState] from what the device and the panel can be shown to
  /// manage — see [adaptiveMaxHeightFor] — and lowered a rung at a time by
  /// [_checkVideoHealth] when the decoder proves it cannot keep up with what
  /// it was given. Seeded value goes on the instance config; a lowered one is
  /// carried per-media, because the instance's options are fixed at
  /// construction and this has to change without a new engine.
  late int _adaptiveMaxHeight;

  /// The seeded cap, kept so a step-down can be recognised as one. Media
  /// options stay untouched while the two agree, which keeps every open the
  /// engine sees identical to the one it saw before this existed.
  late final int _deviceAdaptiveMaxHeight;

  /// The decoder counters when the current measurement window opened, and how
  /// much of the window has been covered so far.
  ///
  /// Deltas from here are what [videoHealthFor] reads, so the ragged first
  /// seconds after an open are the baseline rather than the evidence. Null
  /// until the first sample of an attempt lands.
  ({int displayed, int lost})? _videoBaseline;
  Duration _videoWindow = Duration.zero;

  /// Whether a stats request is in flight, so a slow platform round trip
  /// cannot queue a second behind itself on the next tick.
  bool _statsInFlight = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;

  /// Whether the app is on screen. A backgrounded player freezes its position
  /// legitimately, and recovering from that would reopen sources nobody is
  /// watching.
  bool _foreground = true;

  /// Android picture-in-picture, as the activity reports it.
  ///
  /// Drives the chrome as well as the watchdog: at PiP size the bars are an
  /// unreadable smear over most of the frame, so the window renders the video
  /// and nothing else (the old overlay did the same,
  /// 38da335:...skystream_player_controls.dart:1025).
  bool _inPip = false;

  /// Mirrors the engine's playing flag so the PiP window's middle button can be
  /// re-sent only when it actually flips.
  bool _wasPlaying = false;

  /// Edge detectors. `VlcPlayerValue` is level-triggered and the native error
  /// is sticky until the next setSource, so without these one dead source
  /// produces an unbounded failover storm.
  bool _sawError = false;
  bool _sawEnded = false;

  /// Decided from the item and URL at open time rather than from the engine,
  /// because it governs buffering and what end-of-media means.
  bool _isLive = false;

  /// Consecutive live reopen attempts that have not yet produced playback.
  int _liveReconnects = 0;

  /// A livestream has no position worth sampling, so it is written to history
  /// once per session rather than on every tick.
  bool _recordedLivestream = false;

  /// The last position observed, used to tell real playback from a stuck state
  /// enum.
  Duration _lastSeenPosition = Duration.zero;

  /// The last non-zero length the engine reported for *this* attempt.
  ///
  /// [_handleEnded] tells a finished film from a truncated one by numbers, and
  /// [_sample] is not always there to supply them: it is refused for anything
  /// shorter than [kMinResumableDuration] and never written at all for a
  /// source whose length libVLC never learned. Held per attempt, exactly as
  /// [_sample] is - a length left behind by the previous candidate answers for
  /// the wrong media - and sticky within one, because the engine reports zero
  /// again the moment it reaches the end.
  Duration _lastSeenDuration = Duration.zero;

  /// Desktop window state, mirrored so the button icon can follow it.
  ///
  /// Written only from the window's own events and the seed read in
  /// [initState] - never from our own toggle. The window is moved by things
  /// this screen never hears about otherwise: main.dart's app-wide F11
  /// handler, the macOS green button, the Window menu. Mirroring the toggle
  /// instead left the flag stale after every one of them, which showed the
  /// wrong icon and made Escape inert, since the controls gate it on this.
  bool _isFullscreen = false;

  /// Whether the window has spoken for itself yet.
  ///
  /// The seed read and the window's own events race: a read issued during
  /// [initState] can complete after an event that has already moved the flag,
  /// and would then write a value the window left behind. Anything the window
  /// says outranks the seed, so the seed stands down once one has arrived.
  bool _windowSpoke = false;

  /// How the video is scaled, seeded once from the viewer's default resize
  /// mode and then left alone.
  ///
  /// Deliberately not reactive to the setting: `VlcPlayer` pushes `setFit` to
  /// the running player whenever this changes, and the controls' own resize
  /// button pushes there too. A value that moved under them would overwrite
  /// whatever the viewer had just picked.
  /// Mutable: the resize button reports through onFitChanged, and on the
  /// texture platforms this is the value that actually does the work.
  late VlcVideoFit _fit;

  /// The source sheet's own context while it is open, so Back has something to
  /// close. Null whenever the video is the only thing on screen.
  BuildContext? _sheetContext;

  /// Whether this session ever started the torrent engine, so teardown only
  /// stops something it actually started.
  bool _startedTorrent = false;

  /// Intro/outro bands for the current episode. Usually empty: both sources
  /// are opt-in and off by default.
  List<SkipSegment> _skipSegments = const <SkipSegment>[];

  final PlayerPlatformService _platform = PlayerPlatformService();

  /// The orientation policy this device wants. Derived in [build] from the
  /// device profile, which can still be resolving when playback starts;
  /// [PlayerFormFactor.unknown] makes every orientation call a no-op, so an
  /// early frame pins nothing and therefore needs nothing restored.
  PlayerFormFactor _form = PlayerFormFactor.unknown;

  /// The next episode, once playback is close enough to the end to offer it.
  /// Null whenever the card is not up.
  Episode? _nextEpisodeOffer;

  /// The viewer said no. One refusal per episode - re-offering the card three
  /// seconds later is the behaviour "cancel" exists to prevent. Honoured at
  /// end of media too (owner decision 2): a declined episode does not start
  /// itself when the credits run out.
  bool _nextEpisodeDeclined = false;

  /// Why playback stopped with nothing playing after it, or null while it is
  /// still going. Non-null is what puts [EndedCard] up.
  ///
  /// Deliberately not a [_Stage]. `body: switch (_stage)` swaps the Scaffold's
  /// child, and the playing branch's first child is always [VlcPlayer] so that
  /// nothing unmounts the native view out from under the engine - the comment
  /// above that branch records the episode restarting every time PiP shrank
  /// the window. A stage for this would tear the view down and force Start
  /// Over to rebuild it.
  EndedKind? _ended;

  /// Whether the start-over affordance is up, and whether this session has
  /// already had its turn. Shown once, on the first frame after a resume point
  /// was applied - not again after every failover.
  bool _showResumeHint = false;
  bool _resumeHintOffered = false;

  /// Live torrent statistics, polled only while a torrent is actually playing.
  TorrentStatus? _torrentStatus;
  Timer? _torrentPoll;

  /// Guards against a slow poll overlapping the next tick, which would queue
  /// requests against the torrent server rather than skipping a beat.
  bool _pollingTorrent = false;

  /// The torrent file the viewer picked, and its server-side id. The label
  /// replaces the title, because inside a season pack "Show S02" says nothing
  /// about which episode is on screen.
  String? _torrentFileLabel;
  int? _torrentFileIndex;

  /// What the side panel shows, published by [_publishPanelData] from every
  /// place one of its inputs changes. The panel listens for as long as it is
  /// up, so a failover, a late probe or a torrent poll reaches it in place;
  /// the panel itself decides its anchor row once from the value at open.
  /// Screen-owned rather than a provider because none of its inputs lives in
  /// one, and a plain notifier is what a panel with no ProviderScope can read.
  final ValueNotifier<PanelData> _panelData = ValueNotifier<PanelData>(
    PanelData.empty,
  );

  ProviderContainer? _container;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context, listen: false);
    // The first thing the spinner has to say. Here rather than in _start(),
    // which runs before the first build: reading localizations takes an
    // inherited-widget dependency, and doing that from initState is an
    // assertion. No setState for the same reason - nothing has built yet.
    if (_stage == _Stage.resolving && _status.isEmpty) {
      _status = AppLocalizations.of(context)?.loading ?? '';
    }
  }

  T _read<T>(ProviderListenable<T> provider) {
    final container = _container;
    if (container != null) {
      return container.read(provider);
    }
    return ref.read(provider);
  }

  /// Strings, when there is still a tree to read them from.
  ///
  /// Nullable because most of this file runs from async continuations and
  /// engine callbacks that can outlive the route; the text they produce is
  /// never worth throwing over.
  AppLocalizations? get _l10n =>
      (!mounted || _disposed) ? null : AppLocalizations.of(context);

  /// The shortest side of the surface the video will be shown on, in physical
  /// pixels, or 0 when that is not a ceiling worth applying.
  ///
  /// Shortest side because the player is landscape and a rendition's *height*
  /// is what `--adaptive-maxheight` names: a 2400x1080 handset and a 1920x1080
  /// television both want 1080. Physical pixels because that is the only unit
  /// a rendition can be compared against — logical dp on Android TV is half
  /// the panel, and main.dart clamps the reported density on top of that.
  ///
  /// Zero on a desktop, and this is a capability difference rather than a
  /// platform preference: a window is resized, maximised and full-screened
  /// mid-playback, so its height at the moment the engine is built is not a
  /// ceiling on anything. A television panel and a handset panel cannot
  /// change for the life of the session.
  ///
  /// Read off the implicit view rather than a `MediaQuery`, because the engine
  /// is constructed in [initState], where an inherited widget may not be
  /// depended on.
  int _panelHeightPx() {
    if (ref.read(deviceProfileProvider).asData?.value.isDesktopOS ?? false) {
      return 0;
    }
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    return view?.physicalSize.shortestSide.round() ?? 0;
  }

  @override
  void initState() {
    super.initState();
    _episode = widget.episode;
    _videoUrl = widget.videoUrl;
    _preloaded = widget.preloadedStreams;
    _publishPanelData();
    // The lock is lent to the controls, so the screen is not the only thing
    // that writes it. Subscribed here so the off transition is owned in one
    // place no matter who made it - see [_onUnlocked].
    _locked.addListener(_onUnlocked);
    WidgetsBinding.instance.addObserver(this);
    // The desktop shell stacks its title bar over every route; over this one
    // that is a 48px bar on the back button and an invisible pointer-eating
    // strip the rest of the time. Raised for the whole life of the screen,
    // including the resolving and failed stages, which are just as much the
    // player's window as playback is.
    setImmersiveRoute(active: true);
    // The window is the source of truth for full screen. Subscribed before
    // the seed read is issued so nothing that happens during its await is
    // missed - see [_windowSpoke] for which of the two wins.
    _platform.addWindowListener(this);
    unawaited(_seedFullscreen());
    // Held for startup, then handed to playback - see [_syncPlayingState].
    // Resolving a cold magnet link can take minutes with nothing playing, and
    // a screen that sleeps through it never gets to the video.
    WakelockPlus.enable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // Subtitles are drawn by the engine, so the user's appearance settings have
    // to be supplied at construction. Without them VLC uses its own default
    // relative size of 16, which is enormous on a full-screen video.
    final settings =
        ref.read(playerSettingsProvider).asData?.value ??
        const PlayerSettings();
    _fit = _fitFromSettings(settings.defaultResizeMode);
    _deviceAdaptiveMaxHeight = _adaptiveMaxHeight = adaptiveMaxHeightFor(
      // Unresolved is not "capable". The provider is warmed at startup and is
      // normally already data by the time a player opens, but a cold deep link
      // can beat it here, and the whole point of the cap is that the answer
      // when nothing is known is the conservative one.
      tier:
          ref.read(deviceProfileProvider).asData?.value.tier ??
          DeviceTier.standard,
      panelHeightPx: _panelHeightPx(),
      hardwareDecoding: settings.hardwareDecoding,
    );

    _controller = VlcPlayerController(
      autoPlay: true,
      // Native events are not throttled by default and position ticks are not
      // deduped, so every tick would rebuild the overlay and run the progress
      // listener. Four updates a second is plenty for a seek bar.
      eventThrottleInterval: const Duration(milliseconds: 250),
      config: VlcPlayerConfig(
        network: VlcNetworkConfig(
          // VOD default from user settings (buffer depth); a live source overrides it per-media in _openAttempt.
          networkCaching: settings.readaheadSeconds > 0
              ? (settings.readaheadSeconds * 1000).clamp(1000, 60000)
              : 3000,
          userAgent: kDefaultBrowserUserAgent,
          // The mpv path pins hls-bitrate=max because FFmpeg treats HLS variant
          // bitrate as metadata and never switches on it. libVLC does adapt, but
          // its estimator starts pessimistic and can sit on a low rendition for
          // a long stretch, so pin the highest for the same reason.
          //
          // "Highest" with no ceiling is what handed a 2016 television box the
          // 4K rung of every HLS stream it opened. The ceiling is the other
          // half of the same decision and belongs beside it.
          adaptiveLogic: VlcAdaptiveLogic.highest,
          adaptiveMaxHeight: _adaptiveMaxHeight,
        ),
        subtitleStyle: subtitleStyleFrom(settings),
        // Off by default; see [PlayerDiagnostics]. The only way to get libVLC's
        // own account of a playback out of a machine nobody here owns.
        verbose: PlayerDiagnostics.verboseVlcLog,
        // The user's hardware-decoding preference. libVLC has no equivalent for
        // the tone-mapping settings that sat beside this one, but it does have
        // --avcodec-hw.
        //
        // Reaches the decoder on Android only. Darwin, Windows and Linux all
        // render through libVLC's vmem callbacks, and libvlc_video_set_callbacks
        // sets `avcodec-hw = "none"` on the media player itself
        // (VLC 3.0.21 lib/media_player.c:1113) - which sits below the instance
        // in the variable-inheritance chain, so it beats whatever this emits.
        //
        // What that costs differs by platform, which is why it is worth stating
        // rather than leaving as one rule. Windows and Linux have no hardware
        // decoder outside avcodec - DXVA2/D3D11VA and VA-API/VDPAU are all
        // avcodec accelerators - so they are software-decode-only however this
        // switch is set. Darwin decodes on VideoToolbox, a standalone `video
        // decoder` module that `avcodec-hw` has no authority over, so it keeps
        // its hardware path however this switch is set. The switch is therefore
        // inert in *both* directions on Darwin, not just the off one.
        // See VlcDecodingConfig.hardwareAcceleration.
        decoding: VlcDecodingConfig(
          hardwareAcceleration: settings.hardwareDecoding
              ? VlcHardwareAcceleration.automatic
              : VlcHardwareAcceleration.disabled,
        ),
      ),
      // Verified present in both shipped libVLC builds (VLCKit 3.7.3 and
      // libvlc-all 3.7.0) - see FORK.md section 8 for why option names are
      // checked against the binary rather than assumed.
      options: const <String>['--http-reconnect'],
    );

    _controller.addListener(_onPlaybackValue);
    _chrome = ChromeVisibilityController(
      isPlaying: () => _controller.value.isPlaying,
    );
    _watchdog = Timer.periodic(_kWatchdogTick, (_) => _checkStall());
    _listenForNetworkRestore();
    _attachPip();
    unawaited(_start());
  }

  /// Wires the PiP window's transport buttons to the controller.
  ///
  /// Without this the buttons Android draws under the shrunken video do
  /// nothing at all: they are broadcasts into `MainActivity`, which forwards
  /// them over the channel and has had no listener on this side.
  ///
  /// Both callbacks arrive from the platform thread while the Flutter UI is
  /// not being touched, hence the mounted/disposed guard before any setState.
  void _attachPip() {
    _platform.attachPipListener(
      onAction: (action) => switch (action) {
        PipAction.play => unawaited(_controller.play()),
        PipAction.pause => unawaited(_controller.pause()),
        PipAction.seekForward => _seekRelative(
          PlayerPlatformService.pipSeekStep,
        ),
        PipAction.seekBackward => _seekRelative(
          -PlayerPlatformService.pipSeekStep,
        ),
      },
      onModeChanged: (inPip) {
        if (!mounted || _disposed || inPip == _inPip) return;
        // The other way into PiP: the user swiped home, or pressed the
        // system's own PiP control, and `_enterPip` never ran. Same reason -
        // a locked PiP window has no chip in it.
        if (inPip) _clearLock();
        setState(() => _inPip = inPip);
      },
    );
  }

  /// Seeks by [delta] from wherever playback is, for the PiP buttons.
  ///
  /// Clamped at both ends: a negative target is refused outright by libVLC,
  /// and overshooting the duration would trip the end-of-media handler and
  /// advance an episode the viewer only meant to skip forward in.
  ///
  /// Counted from the published position and nothing else, unlike the
  /// controls' own arrows, which chain off their last target for ~1.5 s
  /// because the engine has not read the seek back yet. No chain can straddle
  /// this: [VlcPlayerControls] is built only while `!_inPip`, so the State
  /// holding that chain is unmounted before Android can draw a PiP window to
  /// press these buttons in - `_enterPip` sets `_inPip` in the same frame it
  /// asks, ahead of the platform's own `pipModeChanged` - and leaving PiP
  /// builds a fresh one whose chain is empty. That is what
  /// pip_engine_continuity_test.dart asserts when it expects no
  /// `VlcPlayerControls` in PiP and one again after. So there is nothing here
  /// to re-base, and reaching into the controls to say so would widen their
  /// surface for a chain that cannot exist.
  void _seekRelative(Duration delta) {
    final value = _controller.value;
    if (!value.isSeekable) return;
    var target = value.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (value.duration > Duration.zero && target > value.duration) {
      target = value.duration;
    }
    unawaited(_controller.seekTo(target));
  }

  /// Resolve the candidate list, then open the best one.
  ///
  /// Everything that can fail is inside one try, and every failure lands on the
  /// same error state rather than an exception in initState — which is exactly
  /// how the JSON-token crash surfaced.
  Future<void> _start() async {
    // Everything this run learns is stamped with this, so the previous run's
    // stragglers - a probe still in flight when the viewer advanced - can be
    // told apart from this one's answers and dropped.
    final generation = ++_resolveGeneration;
    // Whatever the last run learned describes the last run. A retry re-probes
    // and an episode advance resolves different media, and either one showing
    // the previous attempt list is worse than showing nothing.
    _candidates = const <StreamResult>[];
    _probes.clear();
    _publishPanelData();
    _setFailReason(null);
    final skipProbe = _skipProbe = Completer<void>();
    try {
      // Plugin resolution is a network round trip and can be the longest part
      // of startup; the spinner says so from didChangeDependencies, the probe
      // narrates itself through [_onCandidates] and [_onProbe], and the
      // per-source line takes over from _openAttempt.
      final resolved = await resolvePlayback(
        read: _read,
        item: widget.item,
        videoUrl: _videoUrl,
        preloadedStreams: _preloaded,
        isCancelled: () => _disposed,
        onCandidates: (streams) => _onCandidates(generation, streams),
        onProbe: (index, outcome) => _onProbe(generation, index, outcome),
        stopProbing: skipProbe.future,
      );
      if (_disposed) return;
      _resolved = resolved;
      _publishPanelData();
      // Resolution is done deciding, so Skip stops meaning "stop waiting for
      // the probe" and starts meaning "abandon the source being opened".
      _skipProbe = null;

      _token++;
      _recordedLivestream = false;
      final currentEpisode = _currentEpisode;
      _recorder = PlaybackProgressRecorder(
        read: _read,
        item: widget.item,
        episode: currentEpisode,
        videoUrl: _videoUrl,
        token: _token,
      );
      // One tracker for the whole screen, deliberately: failing over to another
      // source is still the same episode, so the watched latch must survive it.
      _tracker = PlaybackTracker(
        read: _read,
        item: widget.item,
        episode: currentEpisode,
        videoUrl: _videoUrl,
        token: _token,
      );

      // Resolved from storage before the engine ever sees the media, and
      // applied as a start position rather than a seek. That removes the whole
      // question of when the engine is ready enough to seek — the old path
      // carried a pending-seek percentage and a readiness race to answer it.
      //
      // Awaited rather than read straight off Hive: whichever device wrote
      // last wins, so pausing on the television and picking up the phone
      // resumes rather than restarts. The lookup falls back to the local
      // answer on any tracker failure, so it cannot delay startup past the
      // trackers' own timeouts.
      _initialResume = await resolveResumePoint(
        read: _read,
        item: widget.item,
        episode: currentEpisode,
        videoUrl: _videoUrl,
      );
      if (_disposed) return;
      // From here the resume point belongs to the session rather than to the
      // stored history entry: every later attempt, failover or hand-picked,
      // starts from wherever playback actually got to.
      _resumePosition = _initialResume?.position ?? Duration.zero;
      // Per session, and this is the only place that is. The hint belongs to
      // the resume point resolved just above, and the reconnect budget to the
      // media about to be opened - carrying either into a new episode or a
      // retry means offering a stale position or refusing to reconnect a feed
      // that has not dropped yet.
      _resumeHintOffered = false;
      _showResumeHint = false;
      _liveReconnects = 0;
      _revertTo = null;
      _tried.clear();

      // Not awaited: both skip sources are network lookups against
      // crowdsourced databases, and playback must not wait on a convenience.
      unawaited(_loadSkipSegments(currentEpisode));

      await _openAttempt(resolved.index, startAt: _resumePosition);
    } catch (e) {
      final l10n = _l10n;
      _fail(switch ((e, l10n)) {
        (final StreamResolutionException f, final AppLocalizations t) =>
          describeStreamFailure(t, f),
        (final StreamResolutionException f, _) => f.message,
        (_, final AppLocalizations t) => t.playerPlaybackFailed('$e'),
        _ => 'Playback failed: $e',
      });
    }
  }

  /// The candidate list, the moment resolution has one.
  ///
  /// Indices in [_probes] and in [ResolvedPlayback] are indices into this, so
  /// it is stored rather than counted: "Source 2 of 5" needs the 5, and the
  /// attempt list needs the names.
  void _onCandidates(int generation, List<StreamResult> streams) {
    if (_disposed || !mounted || generation != _resolveGeneration) return;
    setState(() {
      _candidates = streams;
      _publishPanelData();
    });
  }

  /// One probe answered.
  ///
  /// [generation] is the resolve that dispatched it, and an answer from any
  /// older one is dropped: the losing probes of a resolve keep running for
  /// seconds after it returns, and [index] means nothing once another resolve
  /// has replaced the list it indexes. Left ungated, an advance made under an
  /// open panel painted the previous episode's 'Reachable' and 'Failed' chips
  /// onto the new episode's rows.
  void _onProbe(int generation, int index, ProbeOutcome outcome) {
    if (_disposed || !mounted || generation != _resolveGeneration) return;
    setState(() {
      _probes[index] = outcome;
      _publishPanelData();
      // Resolution returns as soon as the best healthy candidate is known, but
      // the losing probes keep running for seconds afterwards. Past the
      // resolving stage the line belongs to the open - and _status is only
      // cleared on the first frame, which by then has already gone by, so a
      // late probe would leave a wrong source name up for the whole episode.
      if (_stage == _Stage.resolving) _status = _probingStatus() ?? _status;
    });
  }

  /// Which candidate the probe is still waiting on, named.
  ///
  /// Null once they have all settled, and the caller keeps whatever the line
  /// said rather than blanking it — the next thing to happen is the open, and
  /// that writes its own line a moment later.
  String? _probingStatus() {
    final l10n = _l10n;
    if (l10n == null || _candidates.isEmpty) return null;
    for (final entry in _probes.entries) {
      if (entry.value != ProbeOutcome.trying) continue;
      if (entry.key >= _candidates.length) continue;
      return '${l10n.sourceAttempt(entry.key + 1, _candidates.length)}'
          ' · ${_candidates[entry.key].displaySource}';
    }
    return null;
  }

  /// The viewer refuses to keep waiting.
  ///
  /// What that means depends on what is being waited for, and there are only
  /// two things it can be. During the probe it means stop racing and take the
  /// best candidate proved so far — the resolver's own [stopProbing] seam, so
  /// the answer is still the resolver's to give. During an open it means this
  /// source has had its chance: hand it to the failover ring, which already
  /// knows the order and when the ring is exhausted.
  void _skip() {
    if (_disposed || _skipping) return;
    // A remote repeats OK while held, and the button survives the press with
    // focus intact, so without this one hold burns every remaining source.
    _skipCooldown?.cancel();
    _skipCooldown = Timer(const Duration(milliseconds: 700), () {});
    final skipProbe = _skipProbe;
    if (skipProbe != null && !skipProbe.isCompleted) {
      skipProbe.complete();
      // Not nulled here: _start owns the field and clears it when resolution
      // returns, which is the moment Skip changes meaning.
      setState(() {});
      return;
    }
    // No same-source retry: re-opening the URL the viewer just walked away
    // from is precisely what they refused.
    _failAttempt(
      _l10n?.playerReasonSkipped ?? 'you skipped this source',
      allowSameSourceRetry: false,
    );
  }

  /// Opens one candidate.
  ///
  /// The generation counter is bumped first and re-checked after every await.
  /// Without it a failover triggered by a dying source can land after the user
  /// has already moved on, and hand the engine media nobody asked for.
  Future<void> _openAttempt(
    int index, {
    required Duration startAt,
    int retries = 0,
  }) async {
    final resolved = _resolved;
    if (resolved == null || _disposed) return;
    if (index < 0 || index >= resolved.streams.length) {
      final total = resolved.streams.length;
      return _fail(
        _l10n?.playerNoSourcesPlayable(total) ??
            'None of the $total sources would play.',
      );
    }

    final generation = ++_generation;
    _sawError = false;
    _sawEnded = false;
    // Every way back into playback goes through here - Start Over, a failover,
    // a hand-picked source - and none of them may leave the ended card up over
    // media that is opening.
    _ended = null;
    _attemptIndex = index;
    // Published here, not only at open: this is the write the panel's
    // 'Now playing' tick follows through a failover or a trial revert.
    _publishPanelData();
    _attemptRetries = retries;
    _tried.add(index);

    // The outgoing attempt's last position goes to history before it is
    // forgotten. Teardown used to be the backstop for this, and can no longer
    // be: the sample it would have flushed is cleared on the next line.
    _flushProgress();

    // Per attempt, not per session. "Did this source play" and the
    // end-of-media check both ask about *this* media, and a sample left behind
    // by the last one answers on behalf of the wrong one — which is why a dead
    // candidate used to be opened twice at full connect timeout before
    // failover would move past it.
    _sample = null;
    _handedToEngine = false;
    _setSawFrames(false);
    // Seeded with the start position rather than zero: the first value after
    // setMedia still carries the previous media's numbers, and treating that
    // as movement would both hide a stall and sample the wrong position.
    _lastSeenPosition = startAt;
    _lastSeenDuration = Duration.zero;
    _startAttemptClock();

    final stream = resolved.streams[index];

    // Which candidate is being tried, named. Nine sources failing over used to
    // be indistinguishable from one source hanging.
    _setStatus(
      _l10n == null
          ? ''
          : '${_l10n!.sourceAttempt(index + 1, resolved.streams.length)}'
                ' · ${stream.displaySource}',
    );

    // libVLC cannot decrypt CENC on any build we ship, so ClearKey content is
    // decrypted in the local proxy and handed to the engine as plaintext.
    //
    // The key does not have to be in the playlist: the W3C ClearKey exchange
    // is a plain JSON request, so it is worth asking the licence server before
    // giving up. fetchClearKey answers inline keys without a round trip and
    // never throws, so this costs nothing on the ordinary path.
    final clearKey = await fetchClearKey(stream);
    if (_disposed || generation != _generation) return;
    if (clearKey == null) {
      // Only now is the refusal honest. Widevine and PlayReady need a CDM this
      // app does not have, and a licence server that answered with nothing
      // usable will answer the same way again - so retrying this candidate is
      // pointless, while the others may not be encrypted at all.
      final obstacle = drmObstacleFor(stream);
      if (obstacle != null) {
        final l10n = _l10n;
        return _failAttempt(
          l10n == null ? 'DRM' : describeDrmObstacle(l10n, obstacle),
          allowSameSourceRetry: false,
        );
      }
    }

    // A torrent has to be prepared and seeded before anything can open it, and
    // that can take a while on a cold magnet - so say so rather than sitting on
    // a blank screen.
    final isTorrent = isTorrentSource(stream);
    // A file picked out of a pack is served over plain http by the torrent
    // server, so isTorrentSource no longer sees it - but it still needs the
    // patient stall deadline while the piece cache fills.
    _attemptIsTorrent = isTorrent || _torrentFileIndex != null;
    if (isTorrent) _setStatus(_l10n?.playerPreparingTorrent ?? '');
    if (isTorrent && _torrentPoll == null) {
      _startedTorrent = true;
      _startTorrentPolling();
    }
    final playable = await playableUrlFor(read: _read, stream: stream);
    if (_disposed || generation != _generation) return;
    if (playable == null) {
      return _failAttempt(
        _l10n?.playerReasonTorrentNotPrepared ??
            'torrent could not be prepared',
      );
    }

    final uri = _playableUri(playable);
    if (uri == null) {
      return _failAttempt(
        _l10n?.playerReasonNoPlayableAddress ??
            'source has no playable address',
      );
    }

    final headers = playbackHeaders(stream);
    final mediaUri = clearKey != null
        ? await _decryptingUri(uri, headers, clearKey)
        : await _deliverableUri(uri, headers);
    if (_disposed || generation != _generation) return;

    _lastStreamUrl = stream.url;
    _isLive = isLiveSource(widget.item, stream.url);
    await _controller.setMedia(
      VlcMediaSource(
        uri: mediaUri,
        httpHeaders: headers,
        startPosition: startAt,
        // Live trades latency for jitter tolerance and never seeks, so it wants
        // a small live buffer rather than the large VOD readahead.
        //
        // The rendition ceiling rides here only once it has been *lowered*
        // from what the device was seeded with: the seeded value is already on
        // the instance config, and repeating it per-media would change the
        // option list every open sees for no effect at all.
        mediaOptions: <String>[
          if (_isLive) ':live-caching=3000',
          if (_isLive) ':network-caching=3000',
          if (_adaptiveMaxHeight != _deviceAdaptiveMaxHeight)
            ':adaptive-maxheight=$_adaptiveMaxHeight',
        ],
      ),
      autoPlay: true,
    );
    if (_disposed || generation != _generation) return;
    // From here every tick is this attempt's. Restarted here as well as above:
    // everything between the two is setup — torrent preparation, a proxy
    // handshake — and the deadline the watchdog enforces is on the engine
    // producing a frame, not on getting to setMedia.
    _handedToEngine = true;
    _startAttemptClock();

    // Register the source's subtitles with the engine rather than tracking
    // them ourselves. VLC turns each into an ordinary subtitle track, so
    // getSubtitleTracks() returns one list containing both embedded and
    // external entries, with one kind of id.
    //
    // addSubtitle has no header channel at any layer, so a subtitle behind
    // the same protection as the video can only be reached by proxying it.
    //
    // Collected first and added as a batch: every native backend hardcodes
    // libVLC's select flag to true, so firing the adds off unawaited left the
    // viewer watching whichever platform round trip happened to finish last.
    final subtitlesNeedIdentity = stream.headers?.isNotEmpty ?? false;
    final sideCars = <Uri>[];
    final sideCarLanguages = <String?>[];
    for (final sub in stream.subtitles ?? const <SubtitleFile>[]) {
      final subUri = _playableUri(sub.url);
      if (subUri == null) continue;
      final deliverable = subtitlesNeedIdentity
          ? await _proxied(subUri, headers)
          : subUri;
      if (_disposed || generation != _generation) return;
      sideCars.add(deliverable);
      sideCarLanguages.add(sub.lang);
    }
    await addSideCarSubtitles(
      _controller,
      sideCars,
      enable: preferredSubtitleIndex(
        sideCarLanguages,
        _read(subtitleLanguageProvider),
      ),
    );
    if (_disposed || generation != _generation) return;

    if (_stage != _Stage.playing) {
      setState(() => _stage = _Stage.playing);
      // The stage is an input to the published tick - see
      // [_publishPanelData] - and this is the only write that turns it
      // back on, so the tick would stay off after a recovery without it.
      _publishPanelData();
    }
  }

  /// The current candidate failed. Retry it, or move to the next one.
  ///
  /// Resumes from [_resumePosition] rather than from `controller.value`, which
  /// `setMedia` has already zeroed by the time any retry runs — losing the
  /// user's position is the one thing failover must never do.
  void _failAttempt(String reason, {bool allowSameSourceRetry = true}) {
    if (_disposed) return;
    final resolved = _resolved;
    if (resolved == null) return;

    final startAt = _controller.value.isLive ? Duration.zero : _resumePosition;

    // A source the viewer picked by hand is on trial, and a trial that fails
    // costs nothing: the session it interrupted was fine and is still there.
    // Going back to it beats burning the failover budget on a URL nobody was
    // watching and ending at "none of these would play".
    final revert = _revertTo;
    if (revert != null) {
      _revertTo = null;
      _notify(
        _l10n?.playerSourceRestoredPrevious ??
            'That source would not play. Restored the previous one.',
      );
      unawaited(_openAttempt(revert.index, startAt: revert.position));
      return;
    }

    // Failover is otherwise silent: the engine is quietly handed a different
    // URL behind a frame that has stopped moving, which reads as a freeze.
    // This says why, under the name of the source being tried next, until
    // that source produces a frame.
    _setFailReason(reason);

    // A source that produced frames and then died is worth another try at the
    // same URL; one that never played at all is simply dead.
    // A failure the source cannot recover from - DRM we have no key for -
    // opts out: re-opening the same URL would hit the same wall.
    final hadFrames = _sawFrames;
    if (allowSameSourceRetry &&
        hadFrames &&
        _attemptRetries < _kSameSourceRetries) {
      unawaited(
        _openAttempt(
          _attemptIndex,
          startAt: startAt,
          retries: _attemptRetries + 1,
        ),
      );
      return;
    }

    final next = nextFailoverIndex(
      from: _attemptIndex,
      total: resolved.streams.length,
      tried: _tried,
    );
    if (next == null) {
      // Say what actually went wrong. A single-source channel refused for DRM
      // should name the scheme, not just count to one - which the plural
      // handles, so the reason is always carried through.
      final total = resolved.streams.length;
      return _fail(
        _l10n?.playerNoSourcesPlayableWithReason(total, reason) ??
            (total == 1
                ? reason
                : 'None of the $total sources would play - $reason'),
      );
    }
    unawaited(_openAttempt(next, startAt: startAt));
  }

  /// Starts both attempt clocks. Called when an attempt begins and again when
  /// the engine is finally handed media.
  void _startAttemptClock() {
    _attemptAge = Duration.zero;
    _resetStallClock();
    // The decoder counters belong to one media. A reopen resets them natively,
    // so a baseline taken from the outgoing media would read as a colossal
    // negative delta on the incoming one.
    _videoBaseline = null;
    _videoWindow = Duration.zero;
  }

  void _resetStallClock() {
    _stalledFor = Duration.zero;
    _lastStallAction = StallAction.none;
  }

  /// The one thing that notices a source has gone quiet.
  ///
  /// libVLC parked on a half-open socket reports neither `error` nor `ended`;
  /// it sits in `buffering` indefinitely, and without this the viewer gets a
  /// spinner with no recovery and no failover behind it. So the trigger is the
  /// signal the progress path already trusts — an advancing position — rather
  /// than the state enum, which reports `buffering` throughout healthy
  /// playback on some builds and would have this firing constantly.
  ///
  /// Escalation is deliberately shallow: a nudge, then the existing failover
  /// ladder, which already knows how to reopen a source that was playing and
  /// when to give up on one that was not. Three overlapping watchdogs is what
  /// the old player had.
  void _checkStall() {
    if (_disposed || _stage != _Stage.playing) return;
    final value = _controller.value;

    // A frozen position is only a stall if playback was supposed to be
    // happening. A deliberate pause, a backgrounded app and PiP all freeze it
    // legitimately - and the clock restarts with them, so ten minutes paused
    // is not ten minutes stalled the instant play resumes.
    final playbackExpected =
        _foreground &&
        !_inPip &&
        value.state != VlcPlaybackState.paused &&
        value.state != VlcPlaybackState.stopped &&
        value.state != VlcPlaybackState.ended &&
        value.state != VlcPlaybackState.error;
    if (!playbackExpected) {
      // A pause or background mid-stall ends the episode of recovery. Clear
      // the "Reconnecting" line here too, or _resetStallClock zeroes the
      // action flag and _onProgress never sees the recovery it would have
      // cleared it on - the pill outlived the stall.
      if (_lastStallAction != StallAction.none) _setStatus('');
      _resetStallClock();
      return;
    }
    _attemptAge += _kWatchdogTick;
    _stalledFor += _kWatchdogTick;

    // The position moved since the last tick, so there is no stall to report
    // and this second belongs to the other watchdog - the one that asks
    // whether a picture came with the sound. Exactly one of the two speaks per
    // tick, which is what keeps them from double-reporting the same second.
    if (_stalledFor <= _kWatchdogTick) {
      _watchVideoHealth();
      return;
    }
    // A frozen clock ends the measurement window: the counters would keep
    // ticking over a stall that is not this device's fault and convict it of
    // a decode failure it did not commit.
    _videoBaseline = null;
    _videoWindow = Duration.zero;

    final action = stallActionFor(
      stalledFor: _stalledFor,
      hadFrames: _sawFrames,
      lastAction: _lastStallAction,
      recoverAfter: _attemptIsTorrent
          ? kTorrentStallRecoverAfter
          : kStallRecoverAfter,
    );
    switch (action) {
      case StallAction.none:
        return;
      case StallAction.nudge:
        _lastStallAction = action;
        // The frame has been frozen for ten seconds and is about to be for
        // longer; the spinner over it is the controls' to draw, but what is
        // being done about it is only known here. Cleared by the next
        // movement - see [_onProgress].
        _setStatus(_l10n?.playerReconnecting ?? '');
        unawaited(_nudge(value));
      case StallAction.recover:
        final l10n = _l10n;
        _recover(
          _sawFrames
              ? l10n?.playerReasonSourceStoppedResponding ??
                    'the source stopped responding'
              : l10n?.playerReasonSourceNeverStarted ??
                    'the source never started',
        );
    }
  }

  /// The other watchdog: whether a picture is arriving behind the sound.
  ///
  /// Runs only on ticks where the position moved, so it can never contradict
  /// or duplicate the stall ladder above — that one exists for a clock that
  /// froze, this one for the failure where the clock is perfect and the
  /// picture is not. Audio drives libVLC's clock, so a 2016 television box
  /// software-decoding a 4K rendition, and a vout that never opened at all,
  /// both look like flawless playback to every other signal the screen has.
  ///
  /// Sampled through `getMediaStats`, which every backend already implements
  /// and nothing has ever called.
  void _watchVideoHealth() {
    if (!_handedToEngine || _statsInFlight) return;
    // No picture is expected before the engine has produced one, and the
    // opening overlay is already saying so.
    if (!_sawFrames) return;
    _videoWindow += _kWatchdogTick;
    _statsInFlight = true;
    unawaited(_sampleVideoHealth());
  }

  /// One `getMediaStats` round trip, and what it means.
  Future<void> _sampleVideoHealth() async {
    final generation = _generation;
    VlcMediaStats stats;
    try {
      stats = await _controller.getMediaStats();
    } on Object {
      // A backend that will not answer is not evidence of anything. It also
      // must not keep the flag raised: a detached controller throws on every
      // call, and one swallowed failure would otherwise stop the probe for
      // the life of the session.
      _statsInFlight = false;
      return;
    }
    _statsInFlight = false;
    if (_disposed || generation != _generation) return;

    final baseline = _videoBaseline;
    if (baseline == null) {
      // First reading of the window is the datum, never the verdict.
      _videoBaseline = (
        displayed: stats.displayedPictures,
        lost: stats.lostPictures,
      );
      _videoWindow = Duration.zero;
      return;
    }

    final health = videoHealthFor(
      statsAvailable: stats.isAvailable,
      // Track info, not the vout, so this stays true for the very failure
      // being looked for: a video track that exists and is not reaching the
      // screen. False only for genuinely audio-only media.
      hasVideoTrack: _controller.value.videoSize != null,
      measuredFor: _videoWindow,
      displayed: stats.displayedPictures - baseline.displayed,
      lost: stats.lostPictures - baseline.lost,
    );
    if (health == VideoHealth.ok) return;

    // Whatever happens next reopens or replaces the media, so the window that
    // produced this verdict is spent either way.
    _videoBaseline = null;
    _videoWindow = Duration.zero;
    switch (health) {
      case VideoHealth.ok:
        return;
      case VideoHealth.absent:
        // Nothing has reached the screen for a whole window while the clock
        // ran. Handed to the ladder rather than reported, because the ladder
        // already knows how to reopen a source once and how to move on when
        // reopening does not help - and because from the viewer's side this
        // is precisely a source that never started.
        _recover(
          _l10n?.playerReasonSourceNeverStarted ?? 'the source never started',
        );
      case VideoHealth.overwhelmed:
        _stepDownRendition();
    }
  }

  /// Asks for one rung less of the same stream and reopens where we are.
  ///
  /// Not a failover: the source is fine, the request was too big for this
  /// device. Walking the ladder here would abandon a stream whose audio is
  /// perfect in favour of mirrors that will be decoded by the same silicon,
  /// and would end on "none of the sources would play" for a title the device
  /// can show at 1080p all day.
  ///
  /// Bounded twice over. Each step is a whole rung, so at most three can
  /// happen before [stepDownFrom] returns null at the floor; and the reopen
  /// is handed the current retry count rather than a fresh one, so it cannot
  /// refill the failover budget a genuinely broken source is spending.
  void _stepDownRendition() {
    final next = stepDownFrom(_adaptiveMaxHeight);
    // Already asking for the least this app will ask for. Another rung down
    // would not be decodable either, and reopening on a loop is worse than
    // the slideshow.
    if (next == null) return;
    _adaptiveMaxHeight = next;
    unawaited(
      _openAttempt(
        _attemptIndex,
        startAt: _resumePosition,
        retries: _attemptRetries,
      ),
    );
  }

  /// Re-issues the current position and resumes.
  ///
  /// A demuxer that dropped its request after a Range response it disliked
  /// starts a new one, and a stream the engine quietly parked simply resumes.
  /// Only the seek is conditional: a live feed has nowhere to seek to, so it
  /// gets the play() on its own.
  Future<void> _nudge(VlcPlayerValue value) async {
    final generation = _generation;
    if (value.isSeekable && value.position > Duration.zero) {
      await _controller.seekTo(value.position);
      if (_disposed || generation != _generation) return;
    }
    await _controller.play();
  }

  /// Hands a stalled source to the failover ladder.
  ///
  /// Not a reopen of its own: [_failAttempt] already reopens a source that was
  /// playing, up to [_kSameSourceRetries], and moves on from one that was not.
  /// Routing through it is what keeps the retry budget honest — a source that
  /// stalls, recovers for three seconds and stalls again would otherwise
  /// reopen forever without ever trying a different candidate.
  void _recover(String reason) {
    _resetStallClock();
    _lastStallAction = StallAction.recover;
    _failAttempt(reason);
  }

  /// Network restore short-circuits the wait.
  ///
  /// The watchdog would get there on its own, but a viewer who has just walked
  /// back into signal should not sit out the rest of the window. Scoped to a
  /// session that is *already* stalled on purpose: `onConnectivityChanged`
  /// fires for interface changes that say nothing about reachability, and
  /// reopening a healthy stream on one would be a self-inflicted rebuffer.
  void _listenForNetworkRestore() {
    _connectivity = Connectivity().onConnectivityChanged.listen((results) {
      if (_disposed || _stage != _Stage.playing) return;
      if (!results.any((r) => r != ConnectivityResult.none)) return;
      if (_lastStallAction == StallAction.recover) return;
      if (_stalledFor < kStallNudgeAfter) return;
      _recover(_l10n?.playerReasonNetworkDropped ?? 'the network dropped');
    });
  }

  /// End-of-media is ambiguous: a finished film and a truncated download look
  /// identical to the engine. Only a position short of the duration
  /// distinguishes them.
  void _handleEnded() {
    if (_disposed) return;
    _flushProgress();

    // A live feed has no end. Reaching one means the stream dropped, so
    // reopening the same source is the right answer - advancing or failing over
    // to another source would abandon a channel that is merely interrupted.
    if (_isLive) {
      if (_liveReconnects >= _kMaxLiveReconnects) {
        // This source keeps dropping without ever coming back; try another.
        // Explicitly not a same-source retry: reopening is precisely what has
        // just been tried five times.
        _liveReconnects = 0;
        _failAttempt(
          _l10n?.playerReasonLiveFeedDropped ?? 'live feed dropped repeatedly',
          allowSameSourceRetry: false,
        );
        return;
      }
      _liveReconnects++;
      // The wait is spent on the overlay rather than on the last frame the
      // feed produced. A frozen picture under a play glyph reads as a hang;
      // the same two seconds over black, saying what is happening, read as
      // what they are. _openAttempt would drop the flag anyway, but only
      // after the delay.
      _setSawFrames(false);
      _setStatus(_l10n?.playerReconnecting ?? '');
      final generation = _generation;
      unawaited(
        Future<void>.delayed(_kLiveReconnectDelay).then((_) async {
          if (_disposed || generation != _generation) return;
          await _openAttempt(
            _attemptIndex,
            startAt: Duration.zero,
            retries: _attemptRetries,
          );
        }),
      );
      return;
    }

    if (!_sawFrames) {
      // This source ended without ever producing a frame, so there is nothing
      // that could have finished. It is a dead candidate, not a watched
      // episode - advancing on it would skip an episode nobody saw.
      _failAttempt(
        _l10n?.playerReasonStreamEndedBeforePlaying ??
            'stream ended before it played',
      );
      return;
    }
    // The engine's own numbers when there is no sample. A missing sample is
    // not evidence of an ending: it is refused below
    // [kMinResumableDuration] and never written for a source whose length
    // libVLC never reported, and "no sample" used to fall straight through to
    // the card.
    final sample = _sample;
    final duration = sample?.duration ?? _lastSeenDuration;
    final position = sample?.position ?? _lastSeenPosition;
    // Two ways to be a failure wearing an ending's clothes, and one reason
    // covers both. Short of the duration is the truncated download. No
    // duration at all is the one that cannot be measured - an HLS manifest
    // with no EXT-X-ENDLIST on a non-live item, an unindexed MKV over HTTP, a
    // torrent whose header never completed - and "cannot tell" is a failure,
    // not a completion: carding it tells the viewer a stream that dropped its
    // socket ten minutes in has finished, and spends none of the failover
    // ladder on the sources that would have played.
    if (duration <= Duration.zero ||
        position < duration - const Duration(seconds: 2)) {
      _failAttempt(
        _l10n?.playerReasonStreamEndedEarly ??
            'stream ended before its duration',
      );
      return;
    }
    // The only place the card can be raised from. Everything above this line
    // is a failure dressed as an ending - a dropped live feed, a truncated
    // download, a source that never played - and each one lands on the black
    // opening overlay with a named reason, which is correct: telling a viewer
    // "you've finished" over a stream that broke is worse than saying nothing.
    unawaited(
      _advance(automatic: true).then((outcome) {
        if (outcome == _Advance.playing) return;
        _showEnded(
          outcome == _Advance.declined
              ? EndedKind.declinedNext
              : EndedKind.finished,
        );
      }),
    );
  }

  /// Looks up intro/outro segments in the background.
  ///
  /// Never awaited by the open path: both sources are network lookups against
  /// crowdsourced databases, and playback must not wait on a convenience.
  Future<void> _loadSkipSegments(Episode? episode) async {
    if (episode == null) return;
    final token = _token;
    final segments = await fetchSkipSegments(
      read: _read,
      item: widget.item,
      episode: episode,
    );
    if (_disposed || token != _token || segments.isEmpty) return;
    setState(() => _skipSegments = segments);
  }

  /// Whether an episode follows this one. Recomputed rather than cached so it
  /// cannot go stale after an advance.
  bool get _hasNextEpisode =>
      nextEpisodeFor(
        item: widget.item,
        current: _currentEpisode,
        videoUrl: _videoUrl,
      ).next !=
      null;

  /// Polls the torrent server while a torrent is playing.
  ///
  /// Three seconds matches the old controller. The status is only meaningful
  /// while the engine is seeding, so polling starts with playback rather than
  /// with the screen, and stops with it.
  void _startTorrentPolling() {
    _torrentPoll?.cancel();
    _torrentPoll = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_disposed || _pollingTorrent) return;
      _pollingTorrent = true;
      try {
        final status = await _read(torrentServiceProvider).getCurrentStatus();
        if (!_disposed && mounted) {
          setState(() {
            _torrentStatus = status;
            // Equal file lists compare equal, so a poll that found nothing
            // new never reaches the panel.
            _publishPanelData();
          });
        }
      } catch (e) {
        if (kDebugMode) debugPrint('Torrent status poll failed: $e');
      } finally {
        _pollingTorrent = false;
      }
    });
  }

  /// Picture-in-picture is an Android activity mode; there is no equivalent on
  /// the other platforms this ships to, and it is meaningless on a television.
  bool get _pipAvailable => Platform.isAndroid && _form != PlayerFormFactor.tv;

  /// Only a desktop window can change size; mobile and TV are already full
  /// screen, so the affordance is absent rather than inert.
  bool get _fullscreenAvailable =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// Asks the window to flip. The answer arrives as [onWindowEnterFullScreen]
  /// or [onWindowLeaveFullScreen], the same way it does when the viewer uses
  /// F11 or the green button instead of this button.
  void _toggleFullscreen() => unawaited(_platform.toggleFullscreen());

  /// Picks up a window that was already full screen before the player opened.
  Future<void> _seedFullscreen() async {
    final full = await _platform.isFullscreen();
    if (_windowSpoke) return;
    _setFullscreen(full);
  }

  @override
  void onWindowEnterFullScreen() {
    _windowSpoke = true;
    _setFullscreen(true);
  }

  @override
  void onWindowLeaveFullScreen() {
    _windowSpoke = true;
    _setFullscreen(false);
  }

  void _setFullscreen(bool value) {
    if (!mounted || _disposed || value == _isFullscreen) return;
    setState(() => _isFullscreen = value);
  }

  /// The stored resize mode, which is a display string rather than an enum.
  ///
  /// Duplicated from the controls, which map the same setting for the same
  /// reason. Not shared because the two are on opposite sides of the widget's
  /// public API and there is nowhere for it to live that neither owns.
  static VlcVideoFit _fitFromSettings(String mode) =>
      switch (mode.toLowerCase()) {
        'zoom' => VlcVideoFit.cover,
        'stretch' => VlcVideoFit.fill,
        _ => VlcVideoFit.contain,
      };

  Future<void> _enterPip() async {
    // Set here as well as from onModeChanged, so the watchdog stands down and
    // the chrome comes off in the same frame the request is made rather than a
    // platform round trip later. A PiP surface the user has walked away from
    // should not be reopening sources on its own.
    setState(() => _inPip = true);
    // A locked PiP window is unrecoverable: the controls are not built in PiP
    // at all, so there is no chip in it to press and no gesture that would
    // reach one. Cleared on the way in rather than on the way out, because the
    // window is drawn from this frame.
    _clearLock();
    final entered = await _platform.enterPip(
      _controller.value.isPlaying,
      // Shapes the window to the film. Read at the moment of the request
      // rather than remembered, because a failover or a next-episode start
      // can have changed it since the last size event.
      videoSize: _controller.value.videoSize,
    );
    // Android answers false - not an error - when the user has PiP disabled
    // for the app, and then never sends onPictureInPictureModeChanged. Without
    // this the optimism above is permanent and the chrome never comes back.
    if (entered || _disposed || !mounted || !_inPip) return;
    setState(() => _inPip = false);
  }

  /// Opens the side panel, on whichever of its tabs the caller asked for.
  ///
  /// One entry point for every list the player can put on screen, because the
  /// three things that have to be arranged around such a list — holding the
  /// chrome open, giving Back exactly one thing to close, and handing focus
  /// back to the control that opened it — are the same every time and were
  /// getting arranged separately, or not at all, by four different sheets.
  ///
  /// The future is the reason this is not a `void`: the chrome has to be held
  /// open for as long as the panel is up, or the bars go down underneath it and
  /// the button focus comes back to is no longer there. The hold belongs to the
  /// controls, which own the timer: they call this through
  /// `ChromeVisibilityController.whileHeld`, one callback for every tab.
  Future<void> _openPanel(PlayerPanelTab tab, {bool onTrial = true}) async {
    final isTv = _form == PlayerFormFactor.tv;
    await showPlayerPanel(
      context,
      controller: _controller,
      initialTab: tab,
      isTv: isTv,
      // A remote and a keyboard both need focus inside the panel to use it at
      // all. A thumb does not, and a focus ring nobody asked for is just a
      // mark on the screen.
      focusOnOpen: isTv || _form == PlayerFormFactor.desktop,
      // Live, not a snapshot: every fact the panel shows is republished from
      // the place it changes - see [_publishPanelData].
      data: _panelData,
      onPickSource: (index) => _pickSource(index, onTrial: onTrial),
      onPickEpisode: (episode) => unawaited(_pickEpisode(episode)),
      // The panel has no ProviderScope of its own, so the one question its
      // Episodes tab cannot answer - which of these have been seen - is
      // answered from here, one row at a time as the list builds them.
      episodeProgress: _episodeProgressFor,
      onPickFile: (file) => unawaited(_applyTorrentFile(file)),
      // Held so Back has something to close - see [_dismissOverlay].
      onOpened: (panelContext) => _sheetContext = panelContext,
    );
    _sheetContext = null;
  }

  /// How much of [episode] the viewer has already seen, for the panel's
  /// Episodes tab.
  ///
  /// Asked per row as the list builds it, never precomputed into a map: every
  /// call costs a SHA-256 over the episode key plus up to four store reads,
  /// and a sixty-episode season republished on every torrent poll would spend
  /// all of it on rows nobody scrolled to. See `EpisodeProgressLookup`.
  ///
  /// `isWatched` is asked FIRST and short-circuits, because it is the only
  /// authority that honours an explicit mark from the details screen: an
  /// episode marked seen by hand at 40 % is watched, and one abandoned at 97 %
  /// is watched rather than a row with a near-full bar. `item.url` is the
  /// series key both stores are written under (playback_progress.dart).
  EpisodeProgress _episodeProgressFor(Episode episode) {
    final mainUrl = widget.item.url;
    if (_read(episodeWatchRepositoryProvider).isWatched(mainUrl, episode)) {
      return const EpisodeProgress(watched: true);
    }
    final history = _read(historyRepositoryProvider);
    final duration = history.getEpisodeDuration(
      episode.url,
      mainUrl: mainUrl,
      season: episode.season,
      episode: episode.episode,
    );
    if (duration <= 0) return EpisodeProgress.none;
    final position = history.getEpisodePosition(
      episode.url,
      mainUrl: mainUrl,
      season: episode.season,
      episode: episode.episode,
    );
    return EpisodeProgress(fraction: (position / duration).clamp(0.0, 1.0));
  }

  /// What "the same media" means to the panel: the episode being played and
  /// the URL this session was launched from.
  ///
  /// Both move together on an advance and neither moves on a re-resolve, a
  /// failover or a hand-picked source, which is exactly the distinction the
  /// keep-previous rule in [_publishPanelData] has to make.
  Object get _panelMedia => (_currentEpisode, _videoUrl);

  /// Publishes what the panel shows, from the fields as they stand now.
  ///
  /// Called from every mutation point of its inputs rather than from build:
  /// several of them are bare field writes with no frame behind them
  /// (`_attemptIndex` during a failover), and the panel is a route of its own
  /// that this screen's build does not reach. [PanelData]'s equality drops a
  /// publish that changed nothing, so calling it liberally costs no rebuilds.
  void _publishPanelData() {
    if (_disposed) return;
    final resolved = _resolved;
    final previous = _panelData.value;
    // Never hand an open panel an empty list mid re-resolve: on a television
    // the focused row would unmount and nothing in the panel would hold focus.
    // The candidates arrive first, then the resolution; until either exists
    // the last list stands, with no tick on it.
    //
    // Only for the same media, though. An advance is not a re-resolve: left
    // unscoped, a panel open when an episode ended went on listing the
    // finished episode's sources - untickable rows, for as long as the next
    // one took to resolve, and picking one acted on media that was no longer
    // playing. The new episode's own state, empty under its spinner, is the
    // honest answer.
    final media = _panelMedia;
    final carryOver = media == _publishedSourcesMedia;
    final sources =
        resolved?.streams ??
        (carryOver
            ? (_candidates.isNotEmpty ? _candidates : previous.sources)
            : const <StreamResult>[]);
    _publishedSourcesMedia = media;
    _panelData.value = PanelData(
      sources: sources,
      // -1 whenever nothing is playing, which is a re-resolve *or* the
      // failed stage: the candidate that just died is still in
      // [_attemptIndex], and publishing it would badge the dead source
      // 'Now playing' and anchor the remote on it.
      currentSourceIndex: (resolved == null || _stage == _Stage.failed)
          ? -1
          : _attemptIndex,
      // A copy, so a later _probes.clear() cannot empty the chips under an
      // open panel - which is what passing the map by reference used to do.
      probes: Map<int, ProbeOutcome>.unmodifiable(_probes),
      qualityFilteredFallback: resolved?.qualityFilteredFallback ?? false,
      // The list the next arrow walks, filtered the same way, so what the
      // panel offers and what Next does can never disagree.
      episodes: effectiveEpisodes(widget.item, _currentEpisode),
      currentEpisode: _currentEpisode,
      files: torrentFilesOf(_torrentStatus),
      currentFileIndex: _torrentFileIndex,
      // The show title always; season and episode only when the file playing
      // is known to be that episode. A hand-picked pack file may not be the
      // one the URL match named (see [_currentEpisode]), so they are dropped
      // then rather than scoping the search to the wrong episode.
      subtitleTarget: SubtitleSearchTarget.of(
        widget.item,
        _torrentFileIndex != null ? null : _currentEpisode,
      ),
    );
  }

  /// Moves off a source that plays but plays badly - failover only reacts to
  /// outright failure.
  ///
  /// [onTrial] is false when the picker was opened from the failed stage: there
  /// is no working session behind it to put back, so a pick that will not play
  /// should walk the failover ladder like any other candidate.
  void _pickSource(int index, {required bool onTrial}) {
    if (_disposed) return;
    // Picking the row already playing is a no-op - but in the failed stage
    // nothing is playing, and picking the candidate the ladder died on is a
    // deliberate 'try that one again'. Swallowing it left the panel closing on
    // a press that did nothing at all, on the screen's only recovery path.
    if (index == _attemptIndex && _stage != _Stage.failed) return;
    // The panel keeps the last list up through a re-resolve, so a pick can
    // land while nothing is resolved to switch from. Say so; the resolve in
    // flight will open its own choice in a moment.
    if (_resolved == null) {
      _setStatus(_l10n?.loading ?? '');
      return;
    }
    // Carry the position across, exactly as failover does - including before
    // the first sample lands, which is when switching source used to restart a
    // long resume from zero.
    final at = _controller.value.isLive ? Duration.zero : _resumePosition;
    // The pick is on trial. Remember what it interrupted so its failure can put
    // that back rather than take the session down with it.
    if (onTrial) {
      _revertTo = (index: _attemptIndex, position: at);
    } else {
      // A hand-picked source deserves the full ladder rather than the leftovers
      // of the walk that already failed.
      _tried.clear();
      _attemptRetries = 0;
    }
    unawaited(_openAttempt(index, startAt: at));
  }

  /// Switches playback to another file inside the season-pack torrent.
  ///
  /// The pick replaces the current candidate rather than being appended, so the
  /// failover list stays the list of *sources* and does not grow a new entry
  /// every time somebody browses the pack. It restarts at zero on purpose: a
  /// different file is different media, and carrying the old position into it
  /// would drop the viewer into the middle of an episode they have not seen.
  Future<void> _applyTorrentFile(TorrentFile picked) async {
    final resolved = _resolved;
    if (resolved == null || _disposed) return;
    if (picked.index == _torrentFileIndex) return;

    final url = await _read(
      torrentServiceProvider,
    ).getStreamUrlForFileIndex(picked.index);
    if (_disposed) return;
    if (url == null) {
      _notify(
        _l10n?.playerTorrentFileNotReady ??
            'That file is not ready to stream yet.',
      );
      return;
    }

    final current = resolved.streams[_attemptIndex];
    final streams = [...resolved.streams];
    streams[_attemptIndex] = StreamResult(
      url: url,
      source: 'Torrent (${picked.name})',
      providerName: current.providerName,
    );
    setState(() {
      _resolved = ResolvedPlayback(
        streams: streams,
        index: _attemptIndex,
        qualityFilteredFallback: resolved.qualityFilteredFallback,
      );
      _torrentFileLabel = picked.name;
      _torrentFileIndex = picked.index;
      _publishPanelData();
    });
    // A deliberate switch, not a failure: the walk that led here is over.
    _tried.clear();
    _revertTo = null;
    await _openAttempt(_attemptIndex, startAt: Duration.zero);
  }

  /// Moves to the next episode in place, on this controller and this State.
  ///
  /// In place rather than a fresh route because the screen already owns its
  /// controller for the State's lifetime; pushing would tear down and rebuild
  /// the native view for no gain. The cost is that every per-episode field has
  /// to be reset by hand here — which is exactly the bookkeeping the old path
  /// got wrong, so the reset is a single block rather than scattered.
  /// [automatic] marks the end-of-media caller, and is the only one a refusal
  /// applies to: pressing Next in the chrome or on the ended card is the
  /// viewer changing their mind, which a stale "not this time" must not veto.
  Future<_Advance> _advance({bool automatic = false}) async {
    // [_Advance.playing] rather than a refusal: a disposed screen has no card
    // to show, and an advance already in flight owns the transition - the
    // outgoing engine keeps ticking through it and delivers its `ended` late,
    // which is exactly the call that must not raise a card over the episode
    // already loading.
    if (_disposed || _advancing) return _Advance.playing;
    _advancing = true;
    try {
      final lookup = nextEpisodeFor(
        item: widget.item,
        current: _currentEpisode,
        videoUrl: _videoUrl,
      );

      // The outgoing episode's session ends first: finish() emits its single
      // terminal tracking event while the tracker still describes it.
      _tracker?.finish();

      final next = lookup.next;
      if (next == null) {
        // Only a located last episode means "finished". A current episode we
        // could not find in the list means "don't know", and deleting the
        // series on that would cascade across every per-episode row.
        if (lookup.isFinalEpisode) {
          clearFinishedFromHistory(read: _read, item: widget.item);
        }
        return _Advance.finished;
      }

      // Owner decision 2. Cancel on the up-next card used to buy fifteen
      // seconds of credits and nothing more: the episode ended and the advance
      // took it anyway, which is the one outcome the button exists to prevent.
      // Nothing is rolled forward here - the viewer has not moved on - and the
      // card offers the episode back, so a binge is still one press away.
      if (automatic && _nextEpisodeDeclined) return _Advance.declined;

      rollForwardHistory(read: _read, item: widget.item, next: next);
      await _startEpisode(next);
      return _Advance.playing;
    } finally {
      _advancing = false;
    }
  }

  /// Raises the ended card, once.
  void _showEnded(EndedKind kind) {
    if (_disposed || !mounted || _ended == kind) return;
    // The card unmounts the whole controls subtree - see the build gate - and
    // the unlock chip goes with it, so a lock left standing here would be a
    // lock with nothing on screen to undo it. The media it was protecting is
    // over, which is the same reason every other per-episode flag is dropped
    // around here.
    _clearLock();
    setState(() => _ended = kind);
  }

  /// Plays the finished media again, from the top.
  ///
  /// Through [_start] rather than `controller.play()`: whether libVLC 3
  /// restarts from Ended at all is an open platform question, and this
  /// sidesteps it. It is also the only path that mints a fresh token,
  /// recorder and tracker - which this session needs, because `finish()` has
  /// already fired for it - and that re-resolves a URL which may well have
  /// expired during the credits. Starting at zero comes for free:
  /// `resolveResumePoint` returns null at or past `kCompletedFraction`.
  void _startOver() {
    if (_disposed) return;
    _tried.clear();
    _revertTo = null;
    _attemptRetries = 0;
    _liveReconnects = 0;
    _sample = null;
    _handedToEngine = false;
    // The refusal was made about the *previous* viewing of this episode. Left
    // set, the whole re-watch runs with the auto-advance silently off - no
    // up-next card in the last fifteen seconds - and ends on this same card
    // again. The offer goes with it: it belongs to the run that just ended.
    _nextEpisodeDeclined = false;
    _nextEpisodeOffer = null;
    setState(() => _ended = null);
    // The finished picture comes down here, before the first await, for the
    // reason [_startEpisode] drops it in the same place: the resolve and the
    // resume lookup can take seconds, and every one of them would otherwise be
    // spent on a frozen last frame under a spinner-less black card that has
    // just been dismissed.
    _setSawFrames(false);
    _setStatus(_l10n?.loading ?? '');
    unawaited(_start());
  }

  /// Plays [next] because the viewer asked for it from the panel, rather than
  /// because the last one ended.
  ///
  /// Everything the advance does apart from choosing the episode, so the two
  /// cannot drift: the same history roll-forward, the same per-episode reset,
  /// the same look on disk for a downloaded copy.
  Future<void> _pickEpisode(Episode next) async {
    if (_disposed || _advancing || next == _currentEpisode) return;
    _advancing = true;
    try {
      // The outgoing episode's session ends first, exactly as it does when one
      // runs out: finish() emits its single terminal event while the tracker
      // still describes it.
      _tracker?.finish();
      rollForwardHistory(read: _read, item: widget.item, next: next);
      await _startEpisode(next);
    } finally {
      _advancing = false;
    }
  }

  /// Swaps this session onto [next] on the controller it already owns.
  Future<void> _startEpisode(Episode next) async {
    // Per-episode reset. _token, _recorder, _tracker and _initialResume are
    // rebuilt by _start(); _generation and the attempt/edge flags by
    // _openAttempt(). These four are the ones nothing else clears.
    _sample = null;
    _lastStreamUrl = null;
    _resolved = null;
    _preloaded = null; // route sources belong to the first episode only
    _skipSegments = const <SkipSegment>[]; // previous episode's intro/outro
    // Both offers belong to the episode that just ended. The refusal
    // especially: "not this time" must not silence the next episode's card.
    _nextEpisodeOffer = null;
    _nextEpisodeDeclined = false;
    // A card left standing over an episode that is loading would offer Start
    // Over on media nobody is watching any more.
    _ended = null;
    _showResumeHint = false;
    // The picked torrent file, and the pack it came from, belonged to the
    // finished episode. Left standing, a direct-HTTP next episode still
    // offers a file picker built from the old pack - and picking from it
    // overwrites a perfectly good candidate with the old torrent's URL.
    // _startedTorrent deliberately survives: dispose still has to stop the
    // engine this session started.
    _torrentFileLabel = null;
    _torrentFileIndex = null;
    _torrentStatus = null;
    _torrentPoll?.cancel();
    _torrentPoll = null;
    _publishPanelData();

    // The outgoing episode's last picture comes down here, before the first
    // await, and not in _openAttempt where every other attempt drops it.
    // Everything between here and setMedia - the download lookup, the plugin
    // resolve, the resume lookup - can take seconds, and for all of them the
    // viewer was left looking at a frozen frame under a play glyph with no
    // sign anything was happening.
    _handedToEngine = false;
    _setSawFrames(false);
    _setStatus(_l10n?.loading ?? '');

    _episode = next;
    _publishPanelData();
    // A downloaded episode plays from disk, exactly as the details screen
    // does when it launches the first one. Streaming one the user already
    // has on device is the difference between offline binge-watching
    // working and not.
    var nextUrl = next.url;
    try {
      final local = await _read(
        downloadServiceProvider,
      ).getDownloadedFile(widget.item, episode: next);
      if (local != null) nextUrl = local.path;
    } catch (_) {
      // The lookup is a convenience; fall back to streaming.
    }
    if (_disposed) return;
    _videoUrl = AppUtils.normalizeUrl(nextUrl);
    _publishPanelData();
    if (mounted) setState(() {}); // title/subtitle follow the new episode

    await _start();
  }

  /// The episode this session is playing, resolved the way the old controller
  /// does: an explicitly passed episode wins, otherwise match the route's token
  /// against the series' own episode list.
  Episode? get _currentEpisode {
    if (_episode != null) return _episode;
    final type = widget.item.contentType;
    final isSeries =
        type == MultimediaContentType.series ||
        type == MultimediaContentType.anime;
    if (!isSeries) return null;
    return widget.item.episodes?.firstWhereOrNull((e) => e.url == _videoUrl);
  }

  /// Samples progress, and only while playback is genuinely running.
  ///
  /// Every other state lies: `stopped` and `ended` report position zero, and a
  /// value taken right after `setMedia` still carries the previous media's
  /// numbers because VlcPlayerValue merges into its predecessor.
  void _onPlaybackValue() {
    if (_disposed) return;
    final value = _controller.value;
    _syncPlayingState(value);
    _syncOrientation(value);
    final recorder = _recorder;
    if (recorder == null) return;

    // Both of these are edges, not levels, and neither may run synchronously
    // inside the listener - failing over calls setMedia, which notifies again.
    if (value.state == VlcPlaybackState.error) {
      if (!_sawError) {
        _sawError = true;
        final reason =
            value.errorDescription ??
            _l10n?.playerReasonPlaybackError ??
            'playback error';
        scheduleMicrotask(() => _failAttempt(reason));
      }
      return;
    }
    if (value.state == VlcPlaybackState.ended) {
      if (!_sawEnded) {
        _sawEnded = true;
        scheduleMicrotask(_handleEnded);
      }
      return;
    }

    // Advancing position is the only trustworthy sign of playback, so it - not
    // the state enum - decides whether this counts as progress. libVLC reports
    // `buffering` throughout healthy playback on some builds, and gating on the
    // enum meant progress, scrobbling and completion never fired at all.
    final advanced = value.position != _lastSeenPosition;
    _lastSeenPosition = value.position;
    final running =
        value.state != VlcPlaybackState.paused &&
        value.state != VlcPlaybackState.stopped &&
        (value.isPlaying || advanced);

    if (running) {
      // The outgoing media is still playing through the setup of the next
      // attempt. Its ticks keep the watchdog quiet - playback is alive - but
      // are not the incoming attempt's first frame, and are not sampled: the
      // recorder and the resume point may already describe the next episode,
      // and a position from the last one written into either would resume a
      // fresh episode forty minutes in.
      if (!_handedToEngine) {
        if (advanced) _resetStallClock();
        return;
      }
      // Kept even when the sample below is refused: this is the only length
      // end-of-media has to judge by on a source too short to be resumable,
      // and the only proof that a source which reports none never had one.
      if (value.duration > Duration.zero) _lastSeenDuration = value.duration;
      final sample = ProgressSample(
        position: value.position,
        duration: value.duration,
        token: _token,
      );
      if (advanced) _onProgress();

      // record() refuses a livestream because there is no position to store,
      // but Continue Watching still needs the row: the card deletes its entry
      // on tap and relies on playback putting it back.
      //
      // Gated on the content type rather than _isLive, which is also true for
      // a film served over rtsp:// - that still wants ordinary progress.
      if (!_recordedLivestream &&
          widget.item.contentType == MultimediaContentType.livestream) {
        _recordedLivestream = true;
        recorder.recordLivestream();
      }

      if (!sample.isWritable) return;
      _sample = sample;
      _resumePosition = sample.position;
      recorder.record(sample, lastStreamUrl: _lastStreamUrl);
      _tracker?.onPlaying(sample);
      _maybeOfferNextEpisode(sample);
      return;
    }

    // Pausing is the user's own save point, so flush past the rate limit.
    // `buffering` is a separate state, so this really is a user pause.
    if (value.state == VlcPlaybackState.paused) {
      _flushProgress();
      _tracker?.onPaused();
    }
  }

  /// The position moved, which is the only proof that any of this is working.
  ///
  /// Two different clocks hang off it. The stall window restarts immediately —
  /// that is what stops the watchdog firing during healthy playback. The
  /// recovery budgets wait for a real stretch of playback first, because a
  /// source that plays three seconds after every reopen would otherwise refill
  /// them forever and never let failover reach a source that works.
  void _onProgress() {
    final firstFrame = !_sawFrames;
    // Read before the clock resets it: this is the only record that the
    // watchdog said anything.
    final recovering = _lastStallAction != StallAction.none;
    _setSawFrames(true);
    _resetStallClock();
    // Whatever the status line was announcing has happened - the first
    // picture, or the position moving again after "Reconnecting…". Cleared on
    // the first frame alone, the pill outlived every recovery it described.
    if (firstFrame || recovering) _setStatus('');
    if (firstFrame) {
      _setFailReason(null);
      // A new picture, so the bars come up over it for a moment - the same
      // moment a freshly mounted chrome used to give itself - and on a
      // television that is also where focus lands.
      _chrome.poke();
      // The seek has already been applied as a start position, so this is a
      // notice rather than a prompt - and it belongs on the first real frame,
      // not on the stage change, which fires while the engine is still opening.
      if (_initialResume != null && !_resumeHintOffered) {
        _resumeHintOffered = true;
        if (mounted) setState(() => _showResumeHint = true);
      }
    }
    if (_attemptAge < _kHealthyPlayback) return;
    _attemptRetries = 0;
    _liveReconnects = 0;
    // The pick has proved itself; there is nothing left to revert to.
    _revertTo = null;
    // The tried-set describes one failover walk, not the whole session: a
    // source that has just played happily has earned a fresh walk if the
    // network drops an hour from now.
    _tried
      ..clear()
      ..add(_attemptIndex);
  }

  /// Replaces the one line the viewer is given about what the player is doing.
  ///
  /// Cheap enough to call unconditionally: it is a no-op when the text has not
  /// changed, which is what stops per-tick callers rebuilding the screen.
  void _setStatus(String status) {
    if (_disposed || !mounted || status == _status) return;
    setState(() => _status = status);
  }

  /// The second line under the status, or none. Same no-op-on-equal rule as
  /// [_setStatus], for the same reason.
  void _setFailReason(String? reason) {
    if (_disposed || !mounted || reason == _failReason) return;
    setState(() => _failReason = reason);
  }

  /// Whether this attempt has a picture yet, set through the build.
  ///
  /// Written here rather than assigned in place because the opening overlay
  /// hangs off it: `setMedia` returns long before the engine has opened
  /// anything, so this is the flag that decides whether the viewer is looking
  /// at the video or at an opaque panel saying what is being tried.
  void _setSawFrames(bool value) {
    // The lock belongs to the picture that was on screen when it was set. Every
    // path that takes that picture away comes through here - a failover, a live
    // reconnect, Start Over and, through `_startEpisode`, both the automatic
    // advance and a hand-picked episode - so this is the one place that has to
    // say so. Left standing, a lock set on the last episode would greet the
    // next one with a chip over media nobody locked, and the padlock that set
    // it is inside controls this flag has just unmounted.
    //
    // Ahead of the early return on purpose: `_setSawFrames(false)` is called
    // twice on some paths and the second call is the one that would otherwise
    // do nothing.
    if (!value) _clearLock();
    if (_sawFrames == value) return;
    _sawFrames = value;
    if (mounted && !_disposed) setState(() {});
  }

  /// Fans the playing/not-playing edge out to the two things that follow it.
  ///
  /// Only on the flip, and both callees want it that way.
  /// `MainActivity.isPlaying` is otherwise set once, at enterPip time, so
  /// pausing from inside the PiP window left its own button offering to pause
  /// again. The wakelock is a platform call with no business running on every
  /// position tick.
  ///
  /// The wakelock follows playback rather than the screen's lifetime: a player
  /// parked on pause for twenty minutes should let the display sleep like
  /// anything else, and the engine pausing itself on the way to the background
  /// releases it without the screen having to know.
  void _syncPlayingState(VlcPlayerValue value) {
    if (value.isPlaying == _wasPlaying) return;
    _wasPlaying = value.isPlaying;
    _platform.syncPipState(value.isPlaying, videoSize: value.videoSize);
    // Only a real stop releases the screen. The engine also reports
    // not-playing across every setMedia - failover, a torrent file switch, the
    // next episode - and a reopen can take minutes on a cold magnet; dropping
    // the wakelock there is exactly the case initState took it out for.
    unawaited(
      value.isPlaying
          ? WakelockPlus.enable()
          : (_sawFrames ? WakelockPlus.disable() : Future<void>.value()),
    );
  }

  /// Points the device the way the video is shaped.
  ///
  /// Driven by the decoded size rather than by anything the app knows in
  /// advance, because a portrait clip inside a landscape-locked player is
  /// letterboxed down to a stripe, and because nothing in the route arguments
  /// knows the aspect: it arrives from the engine after the first frames.
  ///
  /// ## Why `codedVideoSize` and not `videoSize`
  ///
  /// Because `videoSize` does not know which way up the picture is, and this
  /// decision is *only* about which way up the picture is.
  ///
  /// `videoSize` is the elementary stream's declared width and height on every
  /// backend that reports one, and the rotation a phone camera writes lives in
  /// a field beside it that no backend forwards — the evidence, per platform,
  /// is on [PlayerPlatformService.applyVideoOrientation]. `codedVideoSize` is
  /// the buffer libVLC decodes into after it has applied that rotation, so it
  /// is the upright picture by construction.
  ///
  /// The three cases this leaves, all deliberate:
  ///
  ///  * **iOS** takes the shared NV12 texture path by default, so it reports a
  ///    coded size and a portrait clip turns the handset portrait — including
  ///    one shot on a phone, which is the case that used to come out backwards.
  ///  * **Android** renders through an `AndroidView` and reports no coded
  ///    size, so nothing is pinned and the device keeps whatever orientation
  ///    the user's own rotation setting gives it. That is the conservative
  ///    answer and the only honest one available from Dart: the sole size
  ///    Android sends is the rotation-blind one, and pinning from it would be
  ///    a coin flip on exactly the video the viewer most wants turned. Landing
  ///    `orientation` alongside `width`/`height` in the plugin's snapshot is
  ///    what restores the feature there; it is a change under `packages/`.
  ///  * **macOS, Windows and Linux** are [PlayerFormFactor.desktop] and were
  ///    never pinned, so nothing is lost by not reading the rotation-aware
  ///    size those two desktops do happen to report.
  ///
  /// Fed on every tick rather than only on a size change. That is no longer
  /// load-bearing — the service settles on a clock now, not on a count of
  /// events — but it costs one comparison and it is what keeps a shape that
  /// arrives late, on a tick that changed nothing else, from being missed.
  ///
  /// No `unknown` guard: the service's own form-factor gate handles a profile
  /// that is still resolving, and does it better than a guard here could, by
  /// also disarming a settle that a change of form factor has invalidated.
  void _syncOrientation(VlcPlayerValue value) {
    _platform.applyVideoOrientation(_form, renderedSize: value.codedVideoSize);
  }

  /// Raises the up-next card in the closing seconds of an episode.
  ///
  /// Position-driven rather than end-of-media driven, which is the whole point:
  /// the viewer decides during the credits, and the old overlay used the same
  /// 15-second window (player_controller.dart:2122-2157).
  void _maybeOfferNextEpisode(ProgressSample sample) {
    // _advancing matters: the transition awaits a download lookup and a full
    // resolve, and a late tick from the outgoing episode would re-arm the card
    // over the episode already loading.
    if (_nextEpisodeDeclined ||
        _nextEpisodeOffer != null ||
        _advancing ||
        _isLive) {
      return;
    }
    if (sample.duration - sample.position > _kNextEpisodeLeadIn) return;
    final next = nextEpisodeFor(
      item: widget.item,
      current: _currentEpisode,
      videoUrl: _videoUrl,
    ).next;
    if (next == null || !mounted) return;
    setState(() => _nextEpisodeOffer = next);
  }

  /// Raises the same card because the viewer pressed Skip Outro, rather than
  /// because the position reached the last fifteen seconds.
  ///
  /// Beside [_maybeOfferNextEpisode] so the two cannot drift, and through the
  /// same card for the same reason: one countdown, one advance path, and no
  /// second overlay to keep in step with the first.
  ///
  /// The one deliberate asymmetry is the refusal. The automatic path
  /// early-returns on [_nextEpisodeDeclined]; this one CLEARS it. "Not this
  /// time, automatically" must not veto "yes, now, on purpose" - and left
  /// standing it would veto it twice, first by refusing to raise the card at
  /// all and then, through owner decision 2, by holding the advance back when
  /// the credits ran out anyway.
  void _offerNextEpisodeNow() {
    if (_disposed || !mounted) return;
    // The same two guards the automatic path opens with, for the same
    // reasons: an advance in flight already owns the transition and a card
    // raised into it would stand over the episode already loading, and a live
    // channel has no next episode to offer.
    if (_advancing || _isLive) return;
    final next = nextEpisodeFor(
      item: widget.item,
      current: _currentEpisode,
      videoUrl: _videoUrl,
    ).next;
    if (next == null) return;
    setState(() {
      _nextEpisodeDeclined = false;
      _nextEpisodeOffer = next;
    });
  }

  /// Writes the last known-good sample, bypassing the rate limit.
  void _flushProgress() {
    final sample = _sample;
    final recorder = _recorder;
    if (sample == null || recorder == null) return;
    recorder.record(sample, lastStreamUrl: _lastStreamUrl, force: true);
  }

  /// What the *screen* has to do about the app coming and going.
  ///
  /// Pausing and resuming playback is deliberately not here. That policy lives
  /// on [VlcPlayerController] (see `VlcPlayerConfig.backgroundPolicy`), so
  /// every embedder of the engine gets it and so the "resume only what the
  /// policy paused" bookkeeping sits next to the state that answers it. What
  /// is left is the screen's own: the last chance to write progress, and the
  /// watchdog's clock.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed || !mounted) return;
    // Only a foreground player is worth watching for stalls; off screen the
    // position freezes for reasons that are nobody's fault. `inactive` is
    // deliberately still foreground - on desktop it only means the window lost
    // focus, and on Android it is what entering PiP looks like. Playback
    // carries on through both.
    _foreground =
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.detached;
    if (state == AppLifecycleState.resumed) {
      // However long the app was away is not time this source spent stalled,
      // and the engine needs a moment to get its position moving again.
      _resetStallClock();
      // A backstop behind `pipModeChanged`: returning to the foreground is
      // what ending PiP looks like, and the chrome must come back with it
      // whether or not the activity got round to telling us.
      if (_inPip) setState(() => _inPip = false);
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // The process may not come back. This is the last guaranteed chance.
      _flushProgress();
    }
  }

  /// A brief notice over the video. The app's messenger rather than a bespoke
  /// overlay, so it looks and dismisses like every other toast.
  void _notify(String message) {
    if (_disposed || !mounted) return;
    // maybeOf: a player that cannot find a messenger should still play, not
    // throw on the way past a failed source.
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// Back, from the remote, the gesture or the on-screen button alike.
  ///
  /// [fromChrome] marks the arrow in the top bar. The viewer can only press
  /// that while the bars are up and is looking straight at it, so answering it
  /// by taking the bars away would be the one wrong reading of the press.
  ///
  /// The lock comes first, ahead of everything including [_dismissOverlay]:
  /// nothing the screen could have open can be reached from behind a lock,
  /// and a press that got past it to pop the route would make the lock
  /// decorative - which is precisely how the old one failed.
  void _handleBack({bool fromChrome = false}) {
    if (_locked.value && _lockedBack()) return;
    if (_dismissOverlay()) return;
    if (!fromChrome && _hideChromeForBack()) return;
    final navigator = Navigator.of(context);
    // The player is normally pushed over something. If it is not - a deep link
    // straight into playback - Back leaves the app, which is what it would
    // have done without the PopScope in the way.
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      unawaited(SystemNavigator.pop());
    }
  }

  /// What Back does on a locked screen: two presses to get out.
  ///
  /// Reports whether the press was spent here. The first press is - it reveals
  /// the unlock chip and nothing else, which is the answer a pocket, a lap or
  /// a chest deserves. A second press inside [_kLockBackEscape] is taken as a
  /// deliberate escape: the lock comes off and the press falls through to the
  /// ordinary pop, so a viewer who cannot find the chip, or does not want it,
  /// is never trapped.
  ///
  /// Swallowing Back outright would have been simpler and is what the lock's
  /// own spec asked for. It is also a brick: on Android the gesture is *the*
  /// way out of a screen, a locked player that ignores it forever looks hung,
  /// and the one escape left would be a chip the viewer has already failed to
  /// find. Two presses is the same bargain the platform's own "press back
  /// again to exit" makes.
  ///
  /// [_backEcho] is consulted first and for its usual reason: some devices
  /// deliver one press twice, and the second delivery must not be read as the
  /// deliberate second press. Its 300 ms sits well inside the two-second
  /// window, so the sequence is echo-safe without either timer knowing about
  /// the other's meaning.
  bool _lockedBack() {
    if (_backEcho?.isActive ?? false) return true;
    if (_lockEscape?.isActive ?? false) {
      // Second press, and it means it. The lock comes off here rather than in
      // dispose so that the fall-through is an ordinary Back on an ordinary
      // player, with no locked state left behind for a route that may yet
      // refuse to pop.
      _clearLock();
      return false;
    }
    _backEcho = Timer(_kBackEcho, () {});
    _lockEscape = Timer(_kLockBackEscape, () {});
    // poke(), never keepAlive() and never toggle(). keepAlive is a no-op while
    // the chrome is down, which is exactly when Back is pressed on a screen
    // that has been locked and left alone; toggle() would take the chip away
    // again on the press after. This is the one line that decides whether the
    // lock is a lock or a brick.
    _chrome.poke();
    return true;
  }

  /// Takes the lock off from the screen's own paths - a failover, an episode
  /// advance, an ending, a terminal failure, picture-in-picture, and the
  /// two-press escape itself.
  ///
  /// Guarded like every other method here that teardown can still reach:
  /// [_setSawFrames] is called from unawaited open attempts that outlive the
  /// State, and the notifier is disposed in [dispose].
  ///
  /// It writes the flag and nothing else. Everything that has to happen
  /// *because* the lock came off lives in [_onUnlocked] - see there for why
  /// this method is deliberately not where it lives.
  void _clearLock() {
    if (_disposed) return;
    _locked.value = false;
  }

  /// The one owner of the lock's off transition, whichever of the two writers
  /// made it: this screen through [_clearLock], or the controls' unlock chip,
  /// which holds the same notifier and sets it false itself.
  ///
  /// The Back timers go off with the lock. [_lockEscape] left armed would make
  /// the *next* Back on a freshly re-locked screen count as the second press
  /// of a sequence the viewer never started, so a viewer who unlocks with the
  /// chip and locks again inside two seconds would lose the player on one
  /// press - the one thing a lock promises cannot happen. [_backEcho] left
  /// armed is the same shape and smaller: for 300 ms after an unlock, Back
  /// would be swallowed as the echo of a press already spent on revealing a
  /// chip that has since been used.
  ///
  /// Hung off the notifier rather than written into [_clearLock], and that is
  /// the whole point. The flag is shared state with two writers - the padlock
  /// sets it true, the chip sets it false - so a reset that lives on one call
  /// path is a reset the other path can bypass, which is exactly how this
  /// broke. Attached to the flag itself, it cannot be bypassed by any writer,
  /// present or future. Only a real edge fires it: a [ValueNotifier] notifies
  /// on change, so the many [_clearLock] calls over an already-unlocked
  /// screen cost nothing.
  void _onUnlocked() {
    if (_locked.value) return;
    _lockEscape?.cancel();
    _lockEscape = null;
    _backEcho?.cancel();
    _backEcho = null;
  }

  /// On a television Back with the bars up means "put the bars away", and only
  /// Back over bare video means "leave" - the convention every TV player
  /// follows, and the one the old player kept
  /// (38da335:player_screen.dart:587-597). Reports whether the press was spent
  /// on that.
  ///
  /// Paused or playing alike. There is no pause exception, and the one this
  /// method used to carry was wrong: pausing to read the seek bar is exactly
  /// what a viewer does in the moment before pressing Back, so the exception
  /// turned the most ordinary press on a television into "lose the session".
  /// The bars really do go down while paused - [ChromeVisibilityController]
  /// hides on demand through `toggle()` even though its own clock refuses to
  /// auto-hide over a still picture.
  ///
  /// A phone is still left out: it has a tap to dismiss the bars with, and a
  /// swipe that only cleared the chrome would read as the gesture failing.
  ///
  /// A press arriving while [_backEcho] runs is swallowed whether or not the
  /// bars are up: it is the same press again, and the first delivery has
  /// already answered it.
  bool _hideChromeForBack() {
    if (_backEcho?.isActive ?? false) return true;
    // The ended card unmounts the whole controls subtree, so there are no bars
    // left to put away and the press belongs to the pop. Stated here rather
    // than left to luck: this method claims a paused press since the pause
    // exception was removed, and `ended` is a paused-looking state with the
    // chrome flag still wherever the last nudge left it.
    if (_ended != null) return false;
    if (_form != PlayerFormFactor.tv ||
        _stage != _Stage.playing ||
        !_sawFrames ||
        _inPip) {
      return false;
    }
    // A hold - a D-pad seek in flight - would keep the bars up through
    // toggle(), and a Back that visibly did nothing is worse than one that
    // leaves.
    if (!_chrome.value || _chrome.isHeld) return false;
    _backEcho = Timer(_kBackEcho, () {});
    // toggle() is the controller's only way down; guarded above so it cannot
    // be its way up.
    _chrome.toggle();
    return true;
  }

  /// Closes whatever the screen has over the video, and reports whether there
  /// was anything to close.
  ///
  /// The source sheet is a route of its own and usually pops itself, but on a
  /// television Back also arrives as a key event; without one guarded path a
  /// single press can dismiss the panel and leave the player in the same
  /// frame.
  bool _dismissOverlay() {
    final sheet = _sheetContext;
    if (sheet == null || !sheet.mounted) return false;
    // `mounted` is not enough. Through the panel's exit transition its element
    // is still mounted while its route is no longer the current one, so a
    // second Back arriving mid-animation - which is exactly what a television
    // delivers - popped the player out from under the closing panel.
    if (!(ModalRoute.of(sheet)?.isCurrent ?? false)) return false;
    _sheetContext = null;
    Navigator.of(sheet).pop();
    return true;
  }

  void _fail(String message) {
    if (_disposed) return;
    // Same rule as [_showEnded] and [_setSawFrames], and for the same reason
    // written out at the former: the media the lock was protecting is gone,
    // and the failed frame unmounts the whole controls subtree, so the chip
    // that undoes the lock has just gone with it. Left standing, Back does
    // nothing on the first press with no feedback at all - poke() paints
    // nothing when there are no bars to paint - on the one screen a viewer
    // most wants to leave.
    _clearLock();
    setState(() {
      _stage = _Stage.failed;
      _error = message;
      // The failed frame says it in [_error]; carried past here it would
      // resurface under the next hand-picked source's line.
      _failReason = null;
    });
    // Nothing is playing any more, so the panel's tick has to go out - the
    // last publish was [_openAttempt]'s, naming the candidate that just died.
    _publishPanelData();
  }

  /// Plugins hand back both real URLs and bare filesystem paths; only the
  /// former survive [Uri.parse].
  Uri? _playableUri(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('/') ||
        (Platform.isWindows && value.contains(':\\'))) {
      return Uri.file(value);
    }
    final uri = Uri.tryParse(value);
    return (uri != null && uri.hasScheme) ? uri : null;
  }

  /// Returns a URL libVLC can open while still presenting [headers].
  ///
  /// libVLC 3.x can transmit only User-Agent and Referer — there is no option
  /// for Cookie, Authorization, Origin or anything custom, so those headers
  /// cannot reach the server no matter how they are passed. When a stream needs
  /// one, the URL is handed to the local proxy instead, which re-injects the
  /// full set on the real request and across redirects. This is the same answer
  /// the mpv path reached, for the same reason.
  Future<Uri> _deliverableUri(Uri uri, Map<String, String> headers) async {
    if (!uri.scheme.startsWith('http')) return uri;
    if (unsupportedVlcHeaders(headers).isEmpty) return uri;
    return _proxied(uri, headers);
  }

  /// Routes an encrypted DASH manifest through the decrypting proxy.
  Future<Uri> _decryptingUri(
    Uri uri,
    Map<String, String> headers,
    ClearKey clearKey,
  ) async {
    await LocalProxyService.instance.startServer();
    return Uri.parse(
      LocalProxyService.instance.getDecryptingDashUrl(
        uri.toString(),
        key: clearKey.key,
        keyId: clearKey.keyId,
        headers: headers,
      ),
    );
  }

  Future<Uri> _proxied(Uri uri, Map<String, String> headers) async {
    if (!uri.scheme.startsWith('http')) return uri;
    // getProxyUrl starts the server without awaiting it, and the port is 0
    // until the bind completes - so a cold first call would build a URL
    // pointing at port 0. Start it explicitly first.
    await LocalProxyService.instance.startServer();
    return Uri.parse(
      LocalProxyService.instance.getProxyUrl(
        uri.toString(),
        headers: headers,
        // Without this the proxy strips Cookie outright
        // (local_proxy_service.dart:563), which would defeat the whole point
        // of routing through it. Keep exactly the cookies the source supplied.
        options: ProxyOptions(keepCookies: _cookieNames(headers)),
      ),
    );
  }

  List<String> _cookieNames(Map<String, String> headers) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() != 'cookie') continue;
      return entry.value
          .split(';')
          .map((pair) => pair.split('=').first.trim())
          .where((name) => name.isNotEmpty)
          .toList();
    }
    return const <String>[];
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _platform.removeWindowListener(this);
    // Hands the top of the window back to the desktop title bar.
    setImmersiveRoute(active: false);
    // Order matters: dispose() stops the player, and a stopped libVLC reports
    // position zero. Write first, tear down second. finish() runs after the
    // local write and emits exactly one terminal tracking event.
    _flushProgress();
    _tracker?.finish();
    _disposed = true;
    _torrentPoll?.cancel();
    _skipCooldown?.cancel();
    _backEcho?.cancel();
    _lockEscape?.cancel();
    _watchdog?.cancel();
    // After the controls, which unmount first and stop listening; its hide
    // clock is still armed and nothing else would stop it.
    _chrome.dispose();
    // Same order and the same reason: the controls listen to it through a
    // ValueListenableBuilder and have already gone by here.
    _locked.removeListener(_onUnlocked);
    _locked.dispose();
    // After _disposed is set, so no late publisher writes to a dead notifier;
    // an open panel's builder may still unsubscribe, which a disposed
    // notifier allows.
    _panelData.dispose();
    unawaited(_connectivity?.cancel());
    // Unconditional and required: Android keeps delivering over this channel
    // while it tears the PiP window down, and a handler left registered closes
    // over a screen that no longer exists.
    _platform.detachPipListener();
    // A window left full screen after the video closes traps the user in a
    // chrome-less shell. Not gated on _isFullscreen: that only tracks the
    // toggles we issued, and is wrong whenever the OS window control was used
    // instead - which is exactly when this matters.
    unawaited(_platform.exitFullscreen());
    _controller.removeListener(_onPlaybackValue);
    _controller.dispose();
    // The torrent server seeds in the background; nothing else stops it.
    if (_startedTorrent) unawaited(_read(torrentServiceProvider).stop());
    WakelockPlus.disable();
    // Hands orientation back the way this device wants it, rather than
    // unlocking rotation app-wide: `DeviceOrientation.values` here left every
    // other screen free to land sideways for the rest of the process.
    _platform.restoreOrientation(_form);
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // A pure derivation of a watched value, cached because the orientation and
    // teardown calls run from places that have no context. The profile
    // resolves asynchronously, so this is also how a session that started
    // before it landed picks it up.
    _form = playerFormFactorOf(ref.watch(deviceProfileProvider).asData?.value);
    final isTv = _form == PlayerFormFactor.tv;

    return PopScope(
      // One guarded path for Back: dismiss what the screen has open, and only
      // then leave playback. canPop is false because a pop cannot be taken
      // back once it has started, and on a remote Back is the only way out of
      // a panel.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        backgroundColor: playerScaffoldColor,
        body: switch (_stage) {
          _Stage.resolving => _statusFrame(
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                if (_status.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  // Two lines, then an ellipsis. The status carries a source
                  // name a plugin may have written as a paragraph, and on a
                  // 320px phone that alone wrapped this Column off the screen.
                  Text(
                    _status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
                if (_failReason case final reason?) ...[
                  const SizedBox(height: 6),
                  _reasonLine(reason),
                ],
                // What the health probe is finding, while it finds it. A
                // five-source title otherwise spends the whole check behind
                // one spinner that says nothing. Flexible + scroll so a long
                // race yields to the spinner and Skip instead of overflowing.
                if (_probes.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Flexible(
                    child: SingleChildScrollView(child: _probeList(l10n)),
                  ),
                ],
                if (_canSkip) ...[
                  const SizedBox(height: 24),
                  _skipButton(l10n, autofocus: isTv),
                ],
              ],
            ),
            // Skip is the better landing place when it is there, and two
            // autofocus nodes in one scope is an assertion.
            backAutofocus: !(isTv && _canSkip),
          ),
          _Stage.failed => _statusFrame(
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 24),
                // A dead end with a Back button is not a recovery. Retry
                // covers the common case - a source that was merely down -
                // and Sources reaches the candidates the ladder skipped past.
                Wrap(
                  spacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      // The one autofocus in this frame - see [_statusFrame],
                      // whose Back button stands down while this is on screen.
                      autofocus: true,
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(l10n.retry),
                    ),
                    if ((_resolved?.streams.length ?? 0) > 1)
                      OutlinedButton.icon(
                        onPressed: () => unawaited(
                          _openPanel(PlayerPanelTab.sources, onTrial: false),
                        ),
                        icon: const Icon(Icons.source_outlined),
                        label: Text(l10n.sources),
                      ),
                  ],
                ),
              ],
            ),
          ),
          // One branch, and the VlcPlayer is the first child of it in every
          // state this screen can be in.
          //
          // PiP used to have a branch of its own, returning a bare VlcPlayer.
          // That changes the widget occupying this slot, so entering PiP
          // rebuilt the element, VlcPlayer.dispose detached, the native player
          // died, and re-attaching replayed the media from the position it was
          // opened at - the episode restarted every time the window shrank.
          // Hiding the chrome inside the same Stack keeps the element, and
          // with it the engine.
          _Stage.playing => Stack(
            fit: StackFit.expand,
            children: [
              // The fit is the widget's, not just the engine's: on the texture
              // path VlcPlayer draws its own FittedBox from this, and the
              // native setFit behind it is a no-op on Windows and Linux. Left
              // off, the viewer's default resize mode was ignored there.
              //
              // Offstage rather than absent under the diagnostic switch, and
              // the distinction is the whole value of it: on the texture
              // platforms it is VlcPlayer's own initState that attaches the
              // native player, so a widget left out of the tree is not a
              // player without a picture, it is no player at all. Offstage
              // keeps the element, the State and the attach, and drops only
              // the paint - which is exactly the half being bisected.
              Offstage(
                offstage: PlayerDiagnostics.suppressVideoSurface,
                child: VlcPlayer(
                  controller: _controller,
                  fit: _fit,
                  darwinRenderer: playerDarwinRenderer,
                  androidRenderer: playerAndroidRenderer,
                  backgroundColor: playerBackdropColor,
                ),
              ),
              // `setMedia` hands libVLC a URL and returns; it opens nothing.
              // So this stage begins with the engine owing us a picture, and
              // until it pays the video widget is an empty surface. Covering
              // it is the only honest thing to draw - the alternative, and
              // what this replaces, is black with a seek bar over it.
              if (!_inPip && !_sawFrames) _openingOverlay(l10n, isTv: isTv),
              // At PiP size the frame is about a sixth of the screen: bars,
              // scrims and gesture layers are an unreadable smear over most of
              // it, and there is nothing there to tap them with anyway.
              // `_ended == null` unmounts this whole subtree rather than
              // fading it, which is the same rule the opening overlay follows
              // and which deletes the dead-Play-button problem outright
              // instead of special-casing it: [_playPause] carries
              // `autofocus: isTv`, so leaving it mounted under the card would
              // be two autofocus nodes in one route - a framework assertion -
              // and its key sink would keep taking the remote back. It also
              // makes the ended card and the up-next card structurally
              // incapable of being on screen at once.
              if (!_inPip && _sawFrames && _ended == null) ...[
                // The overlay gets its own layer so a chrome repaint never
                // forces the embedder to recomposite the video surface beneath
                // it.
                RepaintBoundary(
                  child: VlcPlayerControls(
                    controller: _controller,
                    chrome: _chrome,
                    // The texture platforms honour fit through VlcPlayer's
                    // FittedBox, not through the native setFit, so the button
                    // has to reach this state to do anything there.
                    fit: _fit,
                    onFitChanged: (fit) {
                      if (mounted) setState(() => _fit = fit);
                    },
                    title: _torrentFileLabel ?? widget.item.title,
                    subtitle: _currentEpisode?.name,
                    onBack: () => _handleBack(fromChrome: true),
                    // Each is null unless the thing it does is actually
                    // available, so the overlay never renders a button that
                    // would do nothing.
                    onNextEpisode: _hasNextEpisode
                        ? () => unawaited(_advance())
                        : null,
                    // One panel, one callback: the controls render a button
                    // per tab in [panelTabs] and open the panel on it. The
                    // tabs come from the same helper the panel strip reads,
                    // so a button can never open a tab that does not exist -
                    // and Sources stays reachable on a one-source title,
                    // where the panel still carries audio and subtitles.
                    onOpenPanel: (tab) => _openPanel(tab),
                    panelTabs: _panelData.value.tabs,
                    onEnterPip: _pipAvailable ? _enterPip : null,
                    onToggleFullscreen: _fullscreenAvailable
                        ? _toggleFullscreen
                        : null,
                    isFullscreen: _isFullscreen,
                    isLive: _isLive,
                    skipSegments: _skipSegments,
                    // Null on a film and on the last episode, where the chip
                    // keeps its plain seek to the end of the credits because
                    // there is nothing to move on to.
                    onSkipOutro: _hasNextEpisode ? _offerNextEpisodeNow : null,
                    // The skip chip and the up-next card are both bottom-right
                    // and the card is a later child of this Stack, so without
                    // this the chip would still be there underneath it: a tap
                    // that lands on the card on touch, and an invisible focus
                    // stop inside the card's rectangle on a remote. `_ended`
                    // is in here for completeness rather than for effect - the
                    // gate above unmounts these controls entirely for it - so
                    // that the rule survives that gate changing.
                    promptVisible: _nextEpisodeOffer != null || _ended != null,
                    // Phone and tablet only, and null - not false - anywhere
                    // else: with nothing here the controls have no padlock to
                    // render and no locked branch to reach, so the lock is
                    // absent on a television and on a desktop by construction.
                    // A remote has no accidental surface and a mouse has no
                    // pocket; none of Netflix, Prime or YouTube TV ships a
                    // lock, and the only key one could eat on a television is
                    // Back, which is already the load-bearing "hide the bars".
                    locked: _form.isTouch ? _locked : null,
                    torrentStatus: _torrentStatus,
                  ),
                ),
                // Both overlays position themselves against the chrome and sit
                // above it, so they stay readable while the bars are down.
                if (_showResumeHint && _initialResume != null)
                  _unlessLocked(
                    ResumeHint(
                      position: _initialResume!.position,
                      isTv: isTv,
                      onStartOver: () {
                        _resumePosition = Duration.zero;
                        unawaited(_controller.seekTo(Duration.zero));
                      },
                      onDismissed: () {
                        if (mounted) setState(() => _showResumeHint = false);
                      },
                    ),
                  ),
                if (_nextEpisodeOffer != null)
                  _unlessLocked(_nextEpisodeCard(isTv: isTv)),
                // Anything the player has to say while a picture is actually
                // up. A failover no longer lands here - it clears the frame
                // flag and the opening overlay takes the screen instead.
                if (_status.isNotEmpty)
                  Align(
                    alignment: Alignment.topCenter,
                    child: IgnorePointer(child: _statusPill(_status)),
                  ),
              ],
              // A sibling of the controls, never a child: see the gate above.
              if (_ended case final kind? when !_inPip && _sawFrames)
                _endedCard(kind, isTv: isTv),
            ],
          ),
        },
      ),
    );
  }

  /// Withholds a screen-level overlay while the screen lock is on.
  ///
  /// The two the screen owns - the resume hint and the up-next card - are live
  /// tap targets sitting over a picture the viewer believes is inert, and the
  /// up-next one is there for the last fifteen seconds of every episode of
  /// every binge: a pocket press on Play now loses the position, and one on
  /// Cancel ends the episode *and* takes the lock off with it.
  ///
  /// Withheld rather than wrapped in an [IgnorePointer], which is the rule the
  /// controls already follow for the three targets they own
  /// (vlc_player_controls.dart:1613-1618): a dead button that is still drawn
  /// reads as a broken player, and withholding also stops the countdown
  /// deciding an advance from behind a surface nobody can see. The notifier is
  /// the controls' own, so the card comes back the moment the chip unlocks.
  ///
  /// Off touch [_locked] is never set - the padlock is not built there - so
  /// this is a rebuild that never fires.
  Widget _unlessLocked(Widget child) => ValueListenableBuilder<bool>(
    valueListenable: _locked,
    builder: (context, locked, child) =>
        locked ? const SizedBox.shrink() : child!,
    child: child,
  );

  /// What a film - or the last episode of a series, or an episode whose
  /// advance was declined - ends on.
  ///
  /// Everything the card renders is resolved here, so [EndedCard] itself never
  /// touches the item, the episode list or the engine.
  Widget _endedCard(EndedKind kind, {required bool isTv}) {
    final l10n = AppLocalizations.of(context)!;
    final episode = _currentEpisode;
    // Re-asked rather than remembered: the list is the only authority on what
    // follows, and between the refusal and the credits a season can have been
    // switched underneath this.
    final next = kind == EndedKind.declinedNext
        ? nextEpisodeFor(
            item: widget.item,
            current: episode,
            videoUrl: _videoUrl,
          ).next
        : null;
    // A declined kind with nothing to offer is not reachable through
    // [_advance], which only reports `declined` after finding an episode - but
    // the card asserts the pair, and degrading to Start Over beats asserting
    // in a viewer's face if that ever stops being true.
    final effective = next == null ? EndedKind.finished : kind;

    return EndedCard(
      key: endedCardKey,
      kind: effective,
      isTv: isTv,
      // The series title is right for a finale and wrong for a declined
      // episode: "you've finished Breaking Bad" after episode two is a lie.
      title: effective == EndedKind.declinedNext
          ? _declinedTitle(l10n, episode)
          : widget.item.title,
      nextLabel: next == null ? null : _nextEpisodeLabel(l10n, next),
      onNextEpisode: next == null
          ? null
          : () {
              setState(() => _ended = null);
              // Not `automatic`: this is the viewer changing their mind, and
              // the refusal that stopped the auto-advance must not stop them.
              unawaited(_advance());
            },
      onStartOver: _startOver,
      onClose: _handleBack,
    );
  }

  /// What to call the episode a viewer declined to move on from.
  ///
  /// Never the series title while there is anything else to say. A plugin that
  /// scraped its season list without episode names - common - used to fall
  /// straight back to it, which is the "you have finished `<whole series>`"
  /// claim two lines above exist to prevent, on episode one of sixty. The
  /// numbers are the episode panel's own composition
  /// (player_episodes_tab.dart:126-133), so the two read the same and this
  /// spends no new key.
  String _declinedTitle(AppLocalizations l10n, Episode? episode) {
    final name = episode?.name.trim() ?? '';
    if (name.isNotEmpty) return name;
    final season = episode?.season ?? 0;
    final number = episode?.episode ?? 0;
    if (season > 0 && number > 0) {
      return l10n.playerSeasonEpisode(season, number);
    }
    if (number > 0) return l10n.playerEpisodeNumber(number);
    // Nothing on the entry identifies it at all - no name and no numbers - so
    // the series title is the only name there is to print.
    return widget.item.title;
  }

  /// `Next S2 E5`, or a plain `Next` when the numbers are unknown - the
  /// details screen's own composition
  /// (details_layout_widgets.dart:134-143), so the two read the same and the
  /// phase spends no new ARB key on it.
  String _nextEpisodeLabel(AppLocalizations l10n, Episode next) {
    if (next.season > 0 && next.episode > 0) {
      return l10n.playEpisode(l10n.next, next.season, next.episode);
    }
    if (next.episode > 0) return l10n.playEpisodeOnly(l10n.next, next.episode);
    return l10n.next;
  }

  /// The up-next card, with its countdown following actual playback.
  ///
  /// The `paused` input comes through a selector rather than from this build,
  /// because the screen deliberately does not rebuild on every playback value -
  /// and a countdown that keeps running while the viewer has paused to read it
  /// is exactly the behaviour the input exists to prevent.
  Widget _nextEpisodeCard({required bool isTv}) {
    final next = _nextEpisodeOffer!;
    final runtime = next.runtime;
    return PlayerValueSelector<bool>(
      controller: _controller,
      selector: (v) => v.isPlaying,
      builder: (context, playing) => NextEpisodeCountdown(
        title: next.name,
        posterUrl: next.posterUrl,
        season: next.season > 0 ? next.season : null,
        episode: next.episode > 0 ? next.episode : null,
        rating: next.rating,
        runtime: runtime == null ? null : Duration(minutes: runtime),
        description: next.description,
        paused: !playing,
        isTv: isTv,
        onPlayNext: () {
          setState(() => _nextEpisodeOffer = null);
          unawaited(_advance());
        },
        onCancel: () => setState(() {
          _nextEpisodeOffer = null;
          _nextEpisodeDeclined = true;
        }),
      ),
    );
  }

  /// Starts the whole resolve-and-open chain again from the failed stage.
  ///
  /// Deliberately from [_start] rather than from the last candidate: the
  /// failure may have been in resolution itself, and every recovery budget is
  /// spent by the time this screen is reachable.
  void _retry() {
    if (_disposed) return;
    _tried.clear();
    _revertTo = null;
    _attemptRetries = 0;
    _liveReconnects = 0;
    setState(() {
      _stage = _Stage.resolving;
      _error = '';
      _status = AppLocalizations.of(context)?.loading ?? '';
    });
    _publishPanelData();
    unawaited(_start());
  }

  /// The line under the status that says why the previous source was dropped.
  /// Quieter than the status: it is context for the line above it, not news.
  Widget _reasonLine(String reason) => Text(
    reason,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    textAlign: TextAlign.center,
    style: const TextStyle(color: Colors.white38, fontSize: 13),
  );

  Widget _statusPill(String text) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            text,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      ),
    ),
  );

  /// Resolving and failed share one frame so that back is always reachable —
  /// on TV there is no gesture to fall back on.
  Widget _statusFrame(Widget child, {bool? backAutofocus}) {
    return SafeArea(
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: IconButton(
              // Only while there is nothing better to land on. The failed
              // stage's Retry takes it instead, and two autofocus nodes in one
              // scope is an assertion, not a preference.
              autofocus: backAutofocus ?? _stage != _Stage.failed,
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: _handleBack,
            ),
          ),
          Center(
            child: Padding(padding: const EdgeInsets.all(32), child: child),
          ),
        ],
      ),
    );
  }

  /// Whether Skip currently means "stop waiting for the probe".
  ///
  /// Gated on the candidate list because before it exists the player is inside
  /// the plugin's own `loadStreams()`, and there is nothing to fall back to —
  /// a Skip there could only cancel playback, which is what Back is for.
  bool get _canSkipProbe {
    final skipProbe = _skipProbe;
    return skipProbe != null &&
        !skipProbe.isCompleted &&
        _candidates.isNotEmpty;
  }

  /// Whether Skip has anything to do at all.
  ///
  /// The second half covers the first attempt, which runs while the screen is
  /// still on the resolving frame: seeding a cold magnet lives there, and it
  /// is the longest wait the player has.
  bool get _canSkip => _canSkipProbe || _resolved != null;

  Widget _skipButton(AppLocalizations l10n, {required bool autofocus}) =>
      OutlinedButton.icon(
        autofocus: autofocus,
        onPressed: _skip,
        icon: const Icon(Icons.fast_forward_rounded),
        label: Text(l10n.playerSkipSource),
      );

  /// What the parallel health probe is finding, as it finds it.
  ///
  /// Not the old overlay's artwork (38da335:player_loading_overlay.dart), but
  /// the same information: which candidates are in the race, which are still
  /// out, and which have already lost.
  Widget _probeList(AppLocalizations l10n) {
    final rows = <Widget>[];
    for (final entry in _probes.entries) {
      if (entry.key >= _candidates.length) continue;
      final (icon, badge) = switch (entry.value) {
        ProbeOutcome.trying => (Icons.more_horiz_rounded, l10n.trying),
        ProbeOutcome.healthy => (
          Icons.check_rounded,
          l10n.playerSourceReachable,
        ),
        ProbeOutcome.unhealthy => (Icons.close_rounded, l10n.failed),
      };
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: Colors.white38),
              const SizedBox(width: 8),
              // Flexible, not a fixed cap: the name yields to whatever the
              // badge and icon need, so a plugin with a paragraph for a name
              // ellipsises instead of pushing the badge off the side. A hard
              // maxWidth here overflowed by exactly the badge's width on a
              // narrow panel, because it never knew how wide the row was.
              Flexible(
                child: Text(
                  _candidates[entry.key].displaySource,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                badge,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }

  /// The panel that stands in for the video until there is a video.
  ///
  /// A plain opaque [ColoredBox] on purpose. This sits over a platform view on
  /// macOS and iOS, where Flutter gives every layer above one its own
  /// IOSurface — an opacity or filter layer here would be window-sized and
  /// torn down the instant the first frame landed, which is the churn the
  /// compositing rules in vlc_player_controls.dart exist to prevent.
  ///
  /// The chrome is not merely covered but absent while this is up, so the
  /// controls' key sink is not there to compete with Skip for the remote.
  Widget _openingOverlay(AppLocalizations l10n, {required bool isTv}) {
    return RepaintBoundary(
      child: ColoredBox(
        key: openingOverlayKey,
        color: Colors.black,
        child: SafeArea(
          child: Stack(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  // Skip is the D-pad's landing place here; Back is reached by
                  // the remote's own key, which PopScope already routes.
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: _handleBack,
                ),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Both lines capped: a torrent file name or a plugin's
                      // source label can run to a paragraph, and this Column
                      // has no room to give on a phone in portrait.
                      Text(
                        _torrentFileLabel ?? widget.item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const CircularProgressIndicator(),
                      if (_status.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          _status,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                      // Why the source before this one was given up on. A
                      // failover used to look like one source hanging twice.
                      if (_failReason case final reason?) ...[
                        const SizedBox(height: 6),
                        _reasonLine(reason),
                      ],
                      const SizedBox(height: 24),
                      _skipButton(l10n, autofocus: isTv),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
