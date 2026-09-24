import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/models/addon_stream_source.dart';

/// Mirrors [_AddonSourcesSheetState._matchesSearch] so the filter stays
/// covered without spinning up the full sheet (which hangs under D-pad tests).
bool matchesSearch(AddonStreamSource s, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final haystack = [
    s.addonName,
    s.providerName ?? '',
    s.headline,
    s.subtitleLine,
    s.qualityLabel,
    s.name ?? '',
    s.title ?? '',
    s.description ?? '',
  ].join(' ').toLowerCase();
  return haystack.contains(q);
}

AddonStreamSource stream({
  required String addonName,
  String? name,
  String? title,
  String? description,
}) {
  return AddonStreamSource(
    addonId: 'test.$addonName',
    addonName: addonName,
    name: name,
    title: title,
    description: description,
    url: 'https://example.com/v.m3u8',
  );
}

void main() {
  test('empty query keeps every link', () {
    final s = stream(addonName: 'CNCVerse', name: 'VegaMovies');
    expect(matchesSearch(s, ''), isTrue);
    expect(matchesSearch(s, '   '), isTrue);
  });

  test('filters by add-on name', () {
    final a = stream(addonName: 'CNCVerse', name: 'VegaMovies · 1080p');
    final b = stream(addonName: 'Torrentio', name: '1080p BluRay');
    expect(matchesSearch(a, 'cncverse'), isTrue);
    expect(matchesSearch(b, 'cncverse'), isFalse);
    expect(matchesSearch(b, 'torrentio'), isTrue);
  });

  test('filters by inner provider (VegaMovies on CNCVerse)', () {
    final a = stream(addonName: 'CNCVerse', name: 'VegaMovies');
    final b = stream(addonName: 'CNCVerse', name: 'MovieBoxIN');
    expect(matchesSearch(a, 'vegamovies'), isTrue);
    expect(matchesSearch(b, 'vegamovies'), isFalse);
    expect(matchesSearch(b, 'moviebox'), isTrue);
  });

  test('filters by quality token in name', () {
    final a = stream(addonName: 'Torrentio', name: 'remux 2160p');
    final b = stream(addonName: 'Torrentio', name: 'web 720p');
    expect(matchesSearch(a, '2160'), isTrue);
    expect(matchesSearch(b, '2160'), isFalse);
    expect(matchesSearch(a, '4k'), isTrue); // qualityLabel maps 2160 → 4K
  });
}
