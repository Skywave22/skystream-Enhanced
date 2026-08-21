/// Cleanup for the free-text a plugin attaches to a link.
///
/// SkyStream plugins return whatever the source site printed
/// (`1080p WEB-DL x264 [SERVER 3]`), Nuvio scrapers return emoji-laden,
/// multi-line titles, and several pad them with zero-width characters to force
/// their own sort order. Sending all of that straight to the list is why the
/// sources sheet looked like two different apps stitched together.
library;

final RegExp _zeroWidth = RegExp(r'[\u200b-\u200f\ufeff]');
final RegExp _emoji = RegExp(
  r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{2190}-\u{21FF}]',
  unicode: true,
);
final RegExp _breaks = RegExp(r'[\r\n\t]+');
final RegExp _separators = RegExp(r'\s*[|•]\s*');
final RegExp _spaces = RegExp(r'\s+');
final RegExp _repeatedDots = RegExp(r'(\s*·\s*){2,}');
final RegExp _edgeDots = RegExp(r'^[·\s]+|[·\s]+$');

/// Normalises one label: no emoji, no zero-width padding, no line breaks,
/// single spaces, ` · ` as the only separator.
String cleanSourceText(String? value) {
  if (value == null) return '';
  var text = value
      .replaceAll(_zeroWidth, '')
      .replaceAll(_emoji, ' ')
      .replaceAll(_breaks, ' · ')
      .replaceAll(_separators, ' · ')
      .replaceAll(_spaces, ' ')
      .trim();
  text = text.replaceAll(_repeatedDots, ' · ').replaceAll(_edgeDots, '');
  return text;
}

/// Joins the parts of a source line, dropping empties and duplicates so the
/// same value can't appear twice ("1080p · 1080p WEB-DL").
String buildSourceDetail(Iterable<String?> parts, {String fallback = ''}) {
  final seen = <String>{};
  final out = <String>[];
  for (final part in parts) {
    final cleaned = cleanSourceText(part);
    if (cleaned.isEmpty) continue;
    final key = cleaned.toLowerCase();
    if (!seen.add(key)) continue;
    // Skip a part already covered by something we kept…
    if (out.any((existing) => existing.toLowerCase().contains(key))) continue;
    // …and let a longer part replace the shorter one it contains
    // ("1080p" + "1080p WEB-DL" is just "1080p WEB-DL").
    out.removeWhere((existing) => key.contains(existing.toLowerCase()));
    out.add(cleaned);
  }
  if (out.isEmpty) return cleanSourceText(fallback);
  return out.join(' · ');
}
