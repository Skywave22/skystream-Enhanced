import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/utils/stream_quality_sorter.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';

StreamResult sourceLabelled(String label, {String url = 'https://a/b.mkv'}) =>
    StreamResult(url: url, source: label, providerName: 'Plugin');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The label is composed, not authored: Nuvio and the add-on converter both
  // build `quality · size · language · N seeds`, so every number in it except
  // the resolution is a trap.
  group('quality detection', () {
    const cases = <String, String>{
      // Real resolutions, in the shapes plugins write them.
      '2160p · 18.4 GB · English · 42 seeds': '4K',
      '4K HDR · 18 GB': '4K',
      'Ultra HD': '4K',
      '3840x2160 · 18 GB': '4K',
      '1440p · 3.4 GB': '2K',
      '1080p · 2.1 GB · English · 1360 seeds': '1080p',
      '1920x1080 · 2 GB': '1080p',
      'Full HD': '1080p',
      'FHD · 2 GB': '1080p',
      '720p · 800 MB · 12 seeds': '720p',
      'HD': '720p',
      'Mid HD': '720p',
      'HD+': '720p',
      'Low HD': '480p',
      '480p': '480p',
      'SD · 400 MB': '480p',
      '576i': '480p',
      '360p': '360p',
      'Lowest': '360p',
      // A number beats a word: the label says both, and only one is measured.
      'HD 1080p': '1080p',
      // No resolution anywhere. Every one of these used to score a tier.
      '2.1 GB · English · 1360 seeds': 'Auto',
      '720 seeds · 1.2 GB': 'Auto',
      '4360 seeds': 'Auto',
      '👤 1080 · 4.2 GB': 'Auto',
      'Streamflow': 'Auto',
      'HDRezka': 'Auto',
      'SDR · 2.4 GB': 'Auto',
      'Server 2': 'Auto',
    };

    cases.forEach((label, badge) {
      test('"$label" reads as $badge', () {
        expect(qualityBadgeLabel(sourceLabelled(label)), badge);
      });
    });
  });

  group('sortStreamsByQuality', () {
    test('a seeder count does not promote a source above the preference', () {
      final streams = [
        sourceLabelled('2.1 GB · English · 1360 seeds', url: 'https://a/noise'),
        sourceLabelled('1080p · 2.4 GB · 8 seeds', url: 'https://a/fhd'),
      ];

      final sorted = sortStreamsByQuality(streams, QualityPreference.q360);

      expect(
        sorted.first.url,
        'https://a/fhd',
        reason: 'the 1080p source is the only one with a resolution at all',
      );
    });

    // Overshooting the preference is ranked last, but 1440p used to land
    // behind even that, as an unreadable label.
    test('1440p is a closer overshoot of a 1080p preference than 4K', () {
      final streams = [
        sourceLabelled('360p · 300 MB', url: 'https://a/360'),
        sourceLabelled('4K · 18 GB', url: 'https://a/4k'),
        sourceLabelled('1440p · 3.4 GB', url: 'https://a/1440'),
      ];

      final sorted = sortStreamsByQuality(streams, QualityPreference.q1080);

      expect(sorted.map((s) => s.url), [
        'https://a/360',
        'https://a/1440',
        'https://a/4k',
      ]);
    });
  });

  group('filterStreamsByQuality', () {
    test('a source whose only number is a seeder count is kept as auto', () {
      final streams = [
        sourceLabelled('1080p · 2.4 GB', url: 'https://a/fhd'),
        sourceLabelled('1.2 GB · 720 seeds', url: 'https://a/unknown'),
      ];

      final filtered = filterStreamsByQuality(
        streams,
        QualityPreference.q1080,
        QualityFilterMode.atOrAbove,
      );

      expect(filtered.map((s) => s.url), [
        'https://a/fhd',
        'https://a/unknown',
      ]);
    });
  });

  // Wired televisions and desktops are core targets, and connectivity_plus
  // never reports `wifi` for any of them.
  group('isOnMeteredNetwork', () {
    const channel = MethodChannel('dev.fluttercommunity.plus/connectivity');

    void answerWith(List<String> results) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => call.method == 'check' ? results : null,
          );
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('ethernet, wifi, a vpn tunnel and no link are unmetered', () async {
      for (final results in const [
        ['ethernet'],
        ['wifi'],
        ['vpn'],
        ['other'],
        ['none'],
      ]) {
        answerWith(results);
        expect(await isOnMeteredNetwork(), isFalse, reason: '$results');
      }
    });

    test('cellular is metered, including under a vpn', () async {
      for (final results in const [
        ['mobile'],
        ['mobile', 'vpn'],
      ]) {
        answerWith(results);
        expect(await isOnMeteredNetwork(), isTrue, reason: '$results');
      }
    });

    test('an unanswerable platform is assumed metered', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(await isOnMeteredNetwork(), isTrue);
    });
  });
}
