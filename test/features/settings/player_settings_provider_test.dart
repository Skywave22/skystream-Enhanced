import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';

/// Source of [PlayerSettings], read as text.
///
/// The guard below is about a parameter that *exists in the signature*, which
/// no amount of calling the API can observe: a `copyWith` argument with no
/// backing field compiles, runs, and silently does nothing. Only the source
/// text can tell us it is there.
const String _source =
    'lib/features/settings/presentation/player_settings_provider.dart';

/// `copyWith` parameters that intentionally have no field of the same name.
///
/// A nullable field cannot be *cleared* through `T? x` — passing null is
/// indistinguishable from passing nothing — so [PlayerSettings.preferredPlayer]
/// takes a companion flag instead. That is a deliberate pattern, not debris.
const Set<String> _fieldlessByDesign = <String>{'clearPreferredPlayer'};

String _classBody(String src) {
  final int start = src.indexOf('class PlayerSettings {');
  final int end = src.indexOf('  const PlayerSettings({', start);
  expect(start, isNonNegative, reason: 'class PlayerSettings not found');
  expect(end, greaterThan(start), reason: 'PlayerSettings constructor moved');
  return src.substring(start, end);
}

String _copyWithParams(String src) {
  final int start = src.indexOf('PlayerSettings copyWith({');
  expect(start, isNonNegative, reason: 'PlayerSettings.copyWith not found');
  final int end = src.indexOf('\n  }) {', start);
  expect(end, greaterThan(start), reason: 'copyWith signature not closed');
  return src.substring(start, end);
}

void main() {
  test('every copyWith parameter is backed by a field', () {
    final String src = File(_source).readAsStringSync();

    final Set<String> fields = RegExp(r'\bfinal\s+[^;]*?(\w+)\s*;')
        .allMatches(_classBody(src))
        .map((RegExpMatch m) => m.group(1)!)
        .toSet();
    expect(
      fields,
      contains('subtitleSize'),
      reason: 'field scrape is broken, not the class',
    );

    final List<String> params = <String>[];
    for (final String line in _copyWithParams(src).split('\n').skip(1)) {
      final RegExpMatch? m = RegExp(
        r'(\w+)\s*(?:=\s*[^,]+)?,\s*$',
      ).firstMatch(line);
      if (m != null) params.add(m.group(1)!);
    }
    expect(
      params.length,
      greaterThan(20),
      reason: 'parameter scrape is broken, not the signature',
    );

    final List<String> dead = params
        .where((String p) => !fields.contains(p))
        .where((String p) => !_fieldlessByDesign.contains(p))
        .toList();

    expect(
      dead,
      isEmpty,
      reason:
          'copyWith takes ${dead.join(', ')} but PlayerSettings has no such '
          'field, so passing one is silently ignored. Six of these were left '
          'behind when the media_kit subtitle model was deleted.',
    );
  });

  test('the Wi-Fi quality ceiling defaults to 1080p, not 4K', () {
    // Deliberate: a 3840x2160 render target is ~33 MB per frame and there is
    // no in-app escape once a 4K stream is picked. Reverting this to q4k was
    // proposed and rejected; the constant and both of its use sites stay.
    expect(kDefaultWifiQuality, QualityPreference.q1080);
    expect(const PlayerSettings().wifiQuality, kDefaultWifiQuality);
    expect(const PlayerSettings().mobileQuality, QualityPreference.q1080);

    final String src = File(_source).readAsStringSync();
    expect(
      RegExp(r'\bkDefaultWifiQuality\b').allMatches(src).length,
      greaterThanOrEqualTo(3),
      reason: 'the constant, the field default and the storage fallback',
    );
    expect(
      src.contains('QualityPreference.q4k,\n'),
      isFalse,
      reason: 'no default may be hardcoded to 4K',
    );
  });

  test('the live subtitle appearance fields survive copyWith', () {
    const PlayerSettings defaults = PlayerSettings();
    expect(defaults.subtitleSize, 22.0);
    expect(defaults.subtitleColor, 0xFFFFFFFF);
    expect(defaults.subtitleBackgroundColor, 0x00000000);
    expect(defaults.subtitleBackgroundOpacity, 0.5);

    final PlayerSettings styled = defaults.copyWith(
      subtitleSize: 30.0,
      subtitleColor: 0xFFFFEB3B,
      subtitleBackgroundColor: 0xFF303030,
      subtitleBackgroundOpacity: 0.0,
    );
    expect(styled.subtitleSize, 30.0);
    expect(styled.subtitleColor, 0xFFFFEB3B);
    expect(styled.subtitleBackgroundColor, 0xFF303030);
    expect(styled.subtitleBackgroundOpacity, 0.0);
    expect(styled.wifiQuality, kDefaultWifiQuality);
  });
}
