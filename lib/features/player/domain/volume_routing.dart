/// Where a volume request actually lands: the operating system's media
/// stream, libVLC's own gain, or both.
///
/// The three form factors want three different answers, and the reason is the
/// hardware each of them has rather than anything about the player.
///
///  * A **handset** has a rocker, and a viewer who presses it expects the same
///    number the player is showing them to move. So the player's own scale
///    *is* the system's up to 100 %, and only above that does libVLC's
///    amplifier come in.
///  * A **desktop** has a system mixer with a per-application slider in it.
///    Reaching past that from inside the app is how one window ends up
///    fighting the mixer for the same level, so the player keeps a gain of its
///    own and leaves the machine's alone.
///  * A **television** does not own its own volume at all: the remote's keys
///    belong to the set or the receiver, usually over HDMI-CEC, and every
///    ten-foot app on the platform lets them through rather than intercepting
///    them. What is left for the app is the one thing the television cannot
///    do, which is amplify a quiet source past unity — so the in-app control
///    starts at 100 % and only ever goes up.
///
/// A pure enum and a pure split, so the arithmetic is testable without a
/// platform channel anywhere near it.
library;

import '../presentation/player_platform_service.dart';

/// How one form factor routes a volume request.
enum VolumeRouting {
  /// 0..100 is the system's media stream and 100..max is libVLC's gain on top
  /// of a system stream held at full. A handset.
  systemThenBoost,

  /// Everything is libVLC's own gain; the system's mixer is never written to.
  /// A desktop.
  engineOnly,

  /// libVLC's gain again, but never below unity: the platform owns everything
  /// under 100 % and the app only amplifies. A television.
  boostOnly;

  /// The routing [form] calls for.
  ///
  /// An unresolved profile takes the desktop answer, which is the one that
  /// writes to nothing: the profile lands a frame or two into a session, and
  /// reaching for the system mixer before knowing what kind of machine this is
  /// is the one mistake here with a consequence outside the app.
  static VolumeRouting of(PlayerFormFactor form) => switch (form) {
    PlayerFormFactor.tv => VolumeRouting.boostOnly,
    PlayerFormFactor.desktop ||
    PlayerFormFactor.unknown => VolumeRouting.engineOnly,
    PlayerFormFactor.phone || PlayerFormFactor.tablet =>
      VolumeRouting.systemThenBoost,
  };

  /// The lowest level the in-app control offers.
  ///
  /// 100 on a television, where going below unity would be the app quietly
  /// attenuating what the set is sending it, and the set's own control is
  /// right there on the remote.
  int get minimum => this == VolumeRouting.boostOnly ? 100 : 0;

  /// Whether this routing writes to the operating system's media stream.
  bool get touchesSystem => this == VolumeRouting.systemThenBoost;
}

/// What one requested [level] means for the two places a volume can live.
///
/// [level] is the number the viewer sees, on a 0..max percentage scale.
class VolumeSplit {
  const VolumeSplit({required this.engine, this.system});

  /// The percentage handed to libVLC. 100 means unity - no amplification and
  /// no attenuation.
  final int engine;

  /// The system media stream's new level, 0..1, or null where this routing
  /// leaves the system alone.
  final double? system;

  @override
  bool operator ==(Object other) =>
      other is VolumeSplit && other.engine == engine && other.system == system;

  @override
  int get hashCode => Object.hash(engine, system);

  @override
  String toString() => 'VolumeSplit(engine: $engine, system: $system)';
}

/// Splits [level] according to [routing].
///
/// The handset case is the only interesting one, and the shape of it is why
/// this is a function rather than two lines at the call site: under unity the
/// *system* carries the level and libVLC is pinned at 100, because attenuating
/// twice would make the bottom of the scale useless. Over unity the system is
/// already as loud as it goes, so it is pinned at full and libVLC carries the
/// rest.
VolumeSplit splitVolume(int level, {required VolumeRouting routing}) {
  final clamped = level < routing.minimum ? routing.minimum : level;
  return switch (routing) {
    VolumeRouting.engineOnly || VolumeRouting.boostOnly => VolumeSplit(
      engine: clamped,
    ),
    VolumeRouting.systemThenBoost => clamped <= 100
        ? VolumeSplit(engine: 100, system: clamped / 100)
        : VolumeSplit(engine: clamped, system: 1),
  };
}

/// The level to show for a system stream at [system] (0..1) and an engine gain
/// of [engine], under [routing].
///
/// The inverse of [splitVolume], and it has to exist because on a handset the
/// rocker moves the system stream behind the player's back: the number on
/// screen comes from the platform, not from whatever this app last asked for.
int joinVolume({
  required VolumeRouting routing,
  required int engine,
  double? system,
}) {
  if (!routing.touchesSystem || system == null) {
    return engine < routing.minimum ? routing.minimum : engine;
  }
  // Above unity the engine is the level and the system is pinned at full, so
  // the engine is what to read. At or below it, the reverse.
  if (engine > 100) return engine;
  return (system * 100).round();
}
