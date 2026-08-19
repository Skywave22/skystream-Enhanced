import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/nuvio/data/nuvio_dom.dart';
import 'package:skystream/core/nuvio/data/nuvio_runtime.dart';
import 'package:skystream/core/nuvio/models/nuvio_models.dart';

/// Nuvio plugin support, checked against how real plugins behave: bundled
/// scrapers require('cheerio-without-node-native'), call
/// getStreams(tmdbId, mediaType, season, episode) and use
/// load / select / find / first / each / get / attr / text.
void main() {
  const manifestJson = {
    'name': 'All-in-One-Nuvio',
    'version': '1.0.0',
    'scrapers': [
      {
        'id': '4khdhub',
        'name': '4KHDHub',
        'version': '1.0.0',
        'filename': 'providers/4khdhub.js',
        'supportedTypes': ['movie', 'tv'],
        'enabled': true,
      },
      {
        'id': 'animepahe',
        'name': 'AnimePahe',
        'version': '1.0.0',
        'filename': 'providers/animepahe.js',
        'supportedTypes': ['movie', 'tv', 'anime'],
        'enabled': false,
      },
    ],
  };

  group('manifest', () {
    test('parses a real repository manifest', () {
      final manifest = NuvioManifest.fromJson(manifestJson);
      expect(manifest.isValid, isTrue);
      expect(manifest.scrapers, hasLength(2));
      expect(manifest.scrapers.first.filename, 'providers/4khdhub.js');
    });

    test('scraper code resolves relative to the manifest', () {
      final repo = NuvioRepo(
        manifestUrl:
            'https://raw.githubusercontent.com/Owner/Repo/main/manifest.json',
        manifest: NuvioManifest.fromJson(manifestJson),
        addedAt: DateTime.utc(2026),
      );
      expect(
        repo.codeUrlFor(repo.manifest!.scrapers.first).toString(),
        'https://raw.githubusercontent.com/Owner/Repo/main/providers/4khdhub.js',
      );
    });

    test('manifest-disabled scrapers stay off, user toggles persist', () {
      final repo = NuvioRepo(
        manifestUrl: 'https://x/manifest.json',
        manifest: NuvioManifest.fromJson(manifestJson),
        addedAt: DateTime.utc(2026),
        disabledScrapers: const {'4khdhub'},
      );
      expect(repo.enabledScrapers, isEmpty);

      final restored = NuvioRepo.fromJson(repo.toJson());
      expect(restored!.disabledScrapers, contains('4khdhub'));
      expect(restored.manifest!.scrapers, hasLength(2));
    });

    test('type aliases: series/anime map onto Nuvio tv', () {
      final scraper = NuvioManifest.fromJson(manifestJson).scrapers.first;
      expect(scraper.supportsType('tv'), isTrue);
      expect(scraper.supportsType('series'), isTrue);
      expect(scraper.supportsType('movie'), isTrue);
    });

    test('URLs normalise from bare hosts', () {
      expect(
        NuvioUrls.normalizeManifestUrl('example.com/repo'),
        'https://example.com/repo/manifest.json',
      );
      expect(
        NuvioUrls.normalizeManifestUrl(
          'https://raw.githubusercontent.com/a/b/main/manifest.json',
        ),
        'https://raw.githubusercontent.com/a/b/main/manifest.json',
      );
    });
  });

  group('results', () {
    test('maps a real 4KHDHub-style result onto a playable stream', () {
      final result = NuvioStreamResult.fromJson(
        const {
          'name': '4KHDHub | 2160p | Dual-Audio',
          'title': 'Fight Club (1999)',
          'url': 'https://nf-cdn.movies-server.workers.dev/52231a5f',
          'quality': '2160p',
          'size': '66.39GB',
          'headers': {'Referer': 'https://4khdhub.one/'},
          'subtitles': [
            {'url': 'https://x/sub.srt', 'language': 'eng', 'name': 'English'},
          ],
        },
        scraperId: '4khdhub',
        scraperName: '4KHDHub',
      );

      expect(result, isNotNull);
      expect(result!.isTorrent, isFalse);
      expect(result.label, contains('2160p'));
      final stream = result.toStreamResult();
      expect(stream.url, startsWith('https://'));
      expect(stream.headers, {'Referer': 'https://4khdhub.one/'});
      expect(stream.subtitles, hasLength(1));
      expect(stream.providerName, '4KHDHub');
    });

    test('accepts url objects, infoHash-only results and string numbers', () {
      final objectUrl = NuvioStreamResult.fromJson(
        const {
          'title': 'x',
          'url': {'url': 'https://a/b.mkv'},
          'seeders': '42',
        },
        scraperId: 's',
        scraperName: 'S',
      );
      expect(objectUrl!.url, 'https://a/b.mkv');
      expect(objectUrl.seeders, 42);

      final torrent = NuvioStreamResult.fromJson(
        const {'title': 'y', 'infoHash': 'abc123'},
        scraperId: 's',
        scraperName: 'S',
      );
      expect(torrent!.isTorrent, isTrue);
      expect(torrent.url, startsWith('magnet:?xt=urn:btih:abc123'));

      expect(
        NuvioStreamResult.fromJson(
          const {'title': 'no link'},
          scraperId: 's',
          scraperName: 'S',
        ),
        isNull,
      );
    });
  });

  group('cheerio bridge', () {
    const html = '<html><body>'
        '<div class="card" data-id="1"><a href="/one">First</a></div>'
        '<div class="card" data-id="2"><a href="/two">Second</a></div>'
        '</body></html>';

    test('load + query + attr + text mirror cheerio behaviour', () {
      final dom = NuvioDom();
      final doc = dom.load(html);

      final cards = dom.query(doc, null, '.card');
      expect(cards, hasLength(2));
      expect(dom.attr(doc, cards.first, 'data-id'), '1');

      final links = dom.query(doc, cards.last, 'a');
      expect(links, hasLength(1));
      expect(dom.attr(doc, links.first, 'href'), '/two');
      expect(dom.text(doc, links.first).trim(), 'Second');

      dom.free(doc);
      expect(dom.documentCount, 0);
    });

    test('a bad selector yields nothing instead of throwing', () {
      final dom = NuvioDom();
      final doc = dom.load(html);
      expect(dom.query(doc, null, '::::'), isEmpty);
    });

    test('batch describe returns text and attributes in one call', () {
      final dom = NuvioDom();
      final doc = dom.load(html);
      final cards = dom.query(doc, null, '.card');
      final described = dom.describeBatch(doc, cards);
      expect(described, contains('"data-id":"1"'));
      expect(described, contains('First'));
    });
  });

  group('runtime gating', () {
    test('cheerio scrapers are supported, WebAssembly ones are not', () {
      expect(
        NuvioRuntime.unsupportedReason(
          "const c = require('cheerio-without-node-native');",
        ),
        isNull,
      );
      expect(
        NuvioRuntime.unsupportedReason('WebAssembly.instantiate(bytes)'),
        isNotNull,
      );
    });
  });
}
