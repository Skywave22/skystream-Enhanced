/// One stateful engine fake for every app-side player test.
///
/// `VlcPlayerController` has a private constructor, so a test cannot hand the
/// widgets a stub controller; the real one is attached to a fake *engine*
/// instead - a mock 'vlc_player' method channel plus a mock event stream - and
/// the argument shapes stay honest as a side effect.
///
/// Unlike a handler that answers null to everything, this fake keeps the
/// engine's state: the track lists, which audio and subtitle track is on, and
/// a revision that ticks whenever the list changes. That is what makes the
/// assertions about the *active* track - "the panel opens focused on the row
/// that is playing" - writable at all: `emit` stamps the state into every
/// snapshot the way the natives do, so the controller's value follows it.
///
/// Hygiene, learned the hard way:
///  * A playing controller keeps a 1 s stall watchdog armed and flutter_test
///    checks for pending timers *before* `addTearDown` runs. A test that ends
///    in healthy playback must `dispose()` its controller in the body or emit a
///    `{'state': 'paused'}` snapshot first.
///  * Dispose the controller before the fake: `controller.dispose()` still
///    sends `dispose` to the engine, and a channel with no handler throws.
///  * Call [attach] *inside* the `testWidgets` body, never in `setUp`, when
///    an `eventThrottleInterval` is given: the controller's throttle timer is
///    created in whatever zone the first throttled snapshot arrives in, and
///    a controller built outside the test body owns a timer flutter_test's
///    fake async cannot see or drive.
///  * `onListen`/`onCancel` on the event stream are block-bodied on purpose.
///    flutter_test hands `onListen`'s return value back as the `listen` reply
///    (test_default_binary_messenger.dart), and an arrow that returns the
///    assigned sink is a reply the codec cannot encode - a failure only a
///    widget test reports, which is how it went unnoticed under `test()`.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

/// The engine as the app sees it over the 'vlc_player' channel, with enough
/// state to answer the track calls consistently.
class FakeVlcEngine {
  FakeVlcEngine({this.viewId = 1});

  static const MethodChannel channel = MethodChannel('vlc_player');

  /// The id `create` answers with, and the view every event is sent for.
  final int viewId;

  /// What `getAudioTracks` returns, in the engine's own shape
  /// (`{'id': int, 'name': String, 'language': String?}`). Include libVLC's
  /// `{'id': -1, 'name': 'Disable'}` pseudo-track when a test needs it.
  List<Map<String, Object?>> audio = const <Map<String, Object?>>[];

  /// What `getSubtitleTracks` returns; grown by [addSubtitle].
  List<Map<String, Object?>> subtitle = const <Map<String, Object?>>[];

  /// What `getMediaInfo` returns, as-is. Null makes the controller build an
  /// empty [VlcMediaInfo].
  Map<String, Object?>? mediaInfo;

  /// What `getMediaStats` returns, in the engine's own shape. Null is what an
  /// engine with nothing to say answers, and [VlcMediaStats.isAvailable] is
  /// then false - which is the default because a fake that claimed available
  /// counters of zero would look exactly like a decoder producing no picture.
  ///
  /// Use [decodedPictures] for the common shape rather than writing the map.
  Map<String, Object?>? mediaStats;

  /// Sets [mediaStats] to a session that has shown [displayed] pictures and
  /// thrown [lost] away. Counters are cumulative in libVLC, so a test that
  /// walks a window calls this repeatedly with growing totals.
  void decodedPictures({required int displayed, required int lost}) {
    mediaStats = <String, Object?>{
      'available': true,
      'displayedPictures': displayed,
      'lostPictures': lost,
    };
  }

  /// The audio track the engine has on; -1 means none.
  int activeAudioId = -1;

  /// The subtitle track the engine has on; -1 means off.
  int activeSubtitleId = -1;

  /// Ticks whenever the track list changes, as the natives' ESAdded does.
  /// [addSubtitle] moves it on its own; a test that edits [audio] or
  /// [subtitle] by hand announces the change with [bumpTracks].
  int trackRevision = 0;

  /// Whether `addSubtitle` behaves the way libVLC 3 does on a running player:
  /// the slave is *queued* to the input thread, so the call returns before the
  /// ES exists. While this is on, the lists and [trackRevision] do not move
  /// until [landQueuedSlaves] plays the natives' ESAdded forward.
  ///
  /// Off by default, which is the shape most tests want - the file is simply
  /// a track by the time `addSubtitle` completes.
  bool queueAddedSlaves = false;

  /// Methods the engine refuses: every call to one throws a
  /// [PlatformException] instead of answering, which the controller surfaces
  /// as a `VlcPlayerException`. Empty by default. Track *selection* refuses
  /// an unknown id on its own (see [_knownId]); this is for the calls that
  /// have no other way to say no - a delay, an add-slave the demuxer will not
  /// take. The call is still recorded in [calls].
  Set<String> refusedMethods = const <String>{};

  /// The delays the engine holds, in microseconds - what `setAudioDelay` and
  /// `setSubtitleDelay` last asked for. Stamped into every snapshot so a
  /// stepper that reads `value.audioDelay` sees its own press echoed the way
  /// the natives echo it on the next tick.
  int audioDelayUs = 0;
  int subtitleDelayUs = 0;

  /// Every call the controller sent, arguments included.
  final List<MethodCall> calls = <MethodCall>[];

  /// The event sink handed over when the controller subscribed, or null while
  /// nobody listens. [emit] does not need it - it goes through the messenger
  /// like a real platform message - but a test can push raw envelopes here.
  MockStreamHandlerEventSink? sink;

  int _nextSubtitleId = 100;

  /// Slaves handed over while [queueAddedSlaves] is on and not yet landed.
  final List<String> _queuedSlaves = <String>[];

  EventChannel get events => EventChannel('vlc_player/events/$viewId');

  /// Method names in call order, for the assertions that only care *what* was
  /// asked.
  List<String> get methods =>
      calls.map((call) => call.method).toList(growable: false);

  /// The calls made to [method], for the ones that care with what.
  List<MethodCall> callsTo(String method) =>
      calls.where((call) => call.method == method).toList(growable: false);

  /// Installs the method-channel handler and the event stream for [viewId].
  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, _handle);
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (arguments, eventSink) {
          sink = eventSink;
        },
        onCancel: (arguments) {
          sink = null;
        },
      ),
    );
  }

  /// A controller attached to this engine, the platform-view way: the view
  /// already exists under [viewId], so nothing is created.
  ///
  /// No throttle by default, so a snapshot lands on the very next microtask;
  /// pass the screen's 250 ms when the test is about that timing, and pump
  /// 400 ms after each [emit].
  Future<VlcPlayerController> attach({Duration? eventThrottleInterval}) async {
    final controller = VlcPlayerController(
      eventThrottleInterval: eventThrottleInterval,
    );
    // `attach` is on an interface the package deliberately does not export;
    // the app-side tests reach it dynamically by convention.
    await (controller as dynamic).attach(viewId);
    return controller;
  }

  /// The snapshot [emit] would deliver: the harness-shaped healthy-playback
  /// default, this engine's track state, then [partial] on top.
  Map<String, Object?> event([
    Map<String, Object?> partial = const <String, Object?>{},
  ]) => <String, Object?>{
    'state': 'playing',
    'position': 1500,
    'duration': 0,
    'volume': 100,
    'playbackSpeed': 1.0,
    'isReady': true,
    'isSeekable': true,
    'isLive': false,
    'audioTrack': activeAudioId,
    'subtitleTrack': activeSubtitleId,
    'trackRevision': trackRevision,
    'audioDelay': audioDelayUs,
    'subtitleDelay': subtitleDelayUs,
    ...partial,
  };

  /// Delivers one snapshot as the native side would, and returns what went
  /// over the wire. A throttled controller needs a 400 ms pump afterwards.
  Future<Map<String, Object?>> emit([
    Map<String, Object?> partial = const <String, Object?>{},
  ]) async {
    final snapshot = event(partial);
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          events.name,
          events.codec.encodeSuccessEnvelope(snapshot),
          null,
        );
    return snapshot;
  }

  /// A track arrived or left outside [addSubtitle] - a demuxer finishing its
  /// parse, a stream announcing its audio late. Edit [audio] or [subtitle]
  /// first, then call this: it moves [trackRevision] and delivers the
  /// snapshot the natives send on ESAdded/ESDeleted, so a consumer keyed on
  /// the revision re-reads the lists. [partial] rides on the snapshot as in
  /// [emit] (`{'state': 'paused'}` keeps the stall watchdog unarmed).
  Future<Map<String, Object?>> bumpTracks([
    Map<String, Object?> partial = const <String, Object?>{},
  ]) {
    trackRevision++;
    return emit(partial);
  }

  /// Removes both handlers. Dispose the controller first.
  void dispose() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockStreamHandler(events, null);
    sink = null;
  }

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    if (refusedMethods.contains(call.method)) {
      throw PlatformException(
        code: 'refused',
        message: 'The engine refused ${call.method}.',
      );
    }
    switch (call.method) {
      case 'create':
        return <String, Object?>{'viewId': viewId, 'textureId': viewId};
      case 'getAudioTracks':
        return audio;
      case 'getSubtitleTracks':
        return subtitle;
      case 'getMediaInfo':
        return mediaInfo;
      case 'getMediaStats':
        return mediaStats;
      case 'setAudioTrack':
        activeAudioId = _knownId(call, audio);
        return null;
      case 'setSubtitleTrack':
        activeSubtitleId = _knownId(call, subtitle);
        return null;
      case 'disableSubtitle':
        activeSubtitleId = -1;
        return null;
      case 'addSubtitle':
        _addSubtitle(_argument<String>(call, 'uri') ?? '');
        return null;
      case 'setAudioDelay':
        audioDelayUs = _argument<int>(call, 'delay') ?? audioDelayUs;
        return null;
      case 'setSubtitleDelay':
        subtitleDelayUs = _argument<int>(call, 'delay') ?? subtitleDelayUs;
        return null;
      default:
        // play, pause, stop, seekTo, setVolume, setPlaybackSpeed, setFit,
        // setSource, takeSnapshot, dispose: recorded above,
        // answered the way a void method is. The controller's `_invokeFor<T>`
        // is `Future<T?>`.
        return null;
    }
  }

  /// libVLC's add-slave has the select flag hardcoded on in all five natives
  /// (side_car_subtitles.dart), so the new track is on the moment it exists.
  /// When it exists is [queueAddedSlaves]' business.
  void _addSubtitle(String uri) {
    if (queueAddedSlaves) {
      _queuedSlaves.add(uri);
      return;
    }
    _landSlave(uri);
  }

  /// The input thread got to the queued add-slaves: each becomes a track, the
  /// last one is on, [trackRevision] moves once per slave and the snapshot the
  /// natives send on ESAdded is delivered - the notification a consumer keyed
  /// on the revision re-reads the lists from. [partial] rides on it as in
  /// [emit] (`{'state': 'paused'}` keeps the stall watchdog unarmed).
  ///
  /// Safe to call with nothing queued: it is then a plain [emit], which is
  /// what an engine that announced nothing new looks like.
  Future<Map<String, Object?>> landQueuedSlaves([
    Map<String, Object?> partial = const <String, Object?>{},
  ]) {
    final queued = List<String>.of(_queuedSlaves);
    _queuedSlaves.clear();
    queued.forEach(_landSlave);
    return emit(partial);
  }

  void _landSlave(String uri) {
    final id = _nextSubtitleId++;
    final segments = Uri.tryParse(uri)?.pathSegments ?? const <String>[];
    final leaf = segments.lastWhere((s) => s.isNotEmpty, orElse: () => uri);
    subtitle = <Map<String, Object?>>[
      ...subtitle,
      <String, Object?>{'id': id, 'name': leaf},
    ];
    activeSubtitleId = id;
    trackRevision++;
  }

  int _knownId(MethodCall call, List<Map<String, Object?>> tracks) {
    final id = _argument<int>(call, 'id');
    if (id == null || !tracks.any((track) => track['id'] == id)) {
      throw PlatformException(
        code: 'track_not_found',
        message: 'No track with id $id.',
      );
    }
    return id;
  }

  T? _argument<T>(MethodCall call, String key) {
    final arguments = call.arguments;
    if (arguments is! Map) {
      return null;
    }
    final value = arguments[key];
    return value is T ? value : null;
  }
}
