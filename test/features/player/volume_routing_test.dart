import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/volume_routing.dart';
import 'package:skystream/features/player/presentation/player_platform_service.dart';

/// Where a volume request lands, per form factor.
///
/// Pure arithmetic on purpose: the decision is the interesting part and it has
/// nothing to do with a platform channel, so it is decided here and the widget
/// only has to obey.
void main() {
  group('which routing a device gets', () {
    test('a handset and a tablet share the system stream', () {
      expect(
        VolumeRouting.of(PlayerFormFactor.phone),
        VolumeRouting.systemThenBoost,
      );
      expect(
        VolumeRouting.of(PlayerFormFactor.tablet),
        VolumeRouting.systemThenBoost,
      );
    });

    test('a desktop keeps its own gain, separate from the mixer', () {
      // A desktop already has a per-application slider in its mixer. An app
      // reaching past that is how one window ends up fighting the machine for
      // the same level.
      expect(
        VolumeRouting.of(PlayerFormFactor.desktop),
        VolumeRouting.engineOnly,
      );
      expect(VolumeRouting.of(PlayerFormFactor.desktop).touchesSystem, isFalse);
    });

    test('a television only ever boosts', () {
      expect(VolumeRouting.of(PlayerFormFactor.tv), VolumeRouting.boostOnly);
      expect(VolumeRouting.of(PlayerFormFactor.tv).minimum, 100);
      expect(VolumeRouting.of(PlayerFormFactor.tv).touchesSystem, isFalse);
    });

    test('an unresolved profile touches nothing', () {
      // The profile lands a frame or two into a session. Writing to the
      // system mixer before knowing what kind of machine this is is the one
      // mistake here with a consequence outside the app.
      expect(
        VolumeRouting.of(PlayerFormFactor.unknown),
        VolumeRouting.engineOnly,
      );
    });
  });

  group('splitting a level', () {
    test('a handset carries the bottom of the scale in the system stream', () {
      // libVLC stays at unity under 100: attenuating in both places would make
      // the bottom of the scale useless, since 40 % of 40 % is 16 %.
      expect(
        splitVolume(40, routing: VolumeRouting.systemThenBoost),
        const VolumeSplit(engine: 100, system: 0.4),
      );
      expect(
        splitVolume(0, routing: VolumeRouting.systemThenBoost),
        const VolumeSplit(engine: 100, system: 0),
      );
      expect(
        splitVolume(100, routing: VolumeRouting.systemThenBoost),
        const VolumeSplit(engine: 100, system: 1),
      );
    });

    test('and the top of it in libVLC, over a system already at full', () {
      expect(
        splitVolume(160, routing: VolumeRouting.systemThenBoost),
        const VolumeSplit(engine: 160, system: 1),
      );
    });

    test('a desktop never names a system level at all', () {
      expect(
        splitVolume(40, routing: VolumeRouting.engineOnly),
        const VolumeSplit(engine: 40),
      );
      expect(
        splitVolume(180, routing: VolumeRouting.engineOnly).system,
        isNull,
      );
    });

    test('a television is floored at unity, whatever it is asked for', () {
      expect(
        splitVolume(30, routing: VolumeRouting.boostOnly),
        const VolumeSplit(engine: 100),
      );
      expect(
        splitVolume(150, routing: VolumeRouting.boostOnly),
        const VolumeSplit(engine: 150),
      );
    });
  });

  group('reading a level back', () {
    test('a handset reads the system stream under unity', () {
      // The rocker moves it with no call from the app, so the number on screen
      // has to be the platform's rather than whatever the app last asked for.
      expect(
        joinVolume(
          routing: VolumeRouting.systemThenBoost,
          engine: 100,
          system: 0.35,
        ),
        35,
      );
    });

    test('and the engine above it, where the system is pinned at full', () {
      expect(
        joinVolume(
          routing: VolumeRouting.systemThenBoost,
          engine: 175,
          system: 1,
        ),
        175,
      );
    });

    test('before the platform has answered it falls back to the engine', () {
      expect(
        joinVolume(routing: VolumeRouting.systemThenBoost, engine: 100),
        100,
      );
    });

    test('a television never reports below its floor', () {
      // libVLC's own starting volume is whatever the engine says, and on this
      // routing the app has never written anything under 100.
      expect(joinVolume(routing: VolumeRouting.boostOnly, engine: 80), 100);
    });

    test('split and join are inverses across the handset range', () {
      for (final level in <int>[0, 5, 40, 95, 100, 105, 150, 200]) {
        final split = splitVolume(level, routing: VolumeRouting.systemThenBoost);
        expect(
          joinVolume(
            routing: VolumeRouting.systemThenBoost,
            engine: split.engine,
            system: split.system,
          ),
          level,
          reason: '$level did not survive the round trip',
        );
      }
    });
  });
}
