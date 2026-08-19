import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/nuvio/data/nuvio_crypto.dart';
import 'package:skystream/core/nuvio/data/nuvio_dom.dart';
import 'package:skystream/core/nuvio/data/nuvio_polyfill.dart';
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
    test('nothing is rejected up front any more', () {
      // The old gate refused any bundle whose text mentioned WebAssembly.
      // Real providers ship polyfill branches that name it without ever
      // running it, so that check threw away working scrapers. Failures are
      // now reported per scraper, after an actual attempt.
      expect(
        NuvioRuntime.unsupportedReason(
          "const c = require('cheerio-without-node-native');",
        ),
        isNull,
      );
      expect(
        NuvioRuntime.unsupportedReason('WebAssembly.instantiate(bytes)'),
        isNull,
      );
    });

    test('per-plugin budget matches Nuvio', () {
      expect(NuvioRuntime.defaultTimeout, const Duration(seconds: 60));
    });
  });

  group('javascript environment', () {
    final js = buildNuvioPolyfill(
      scraperIdJson: '"scraper"',
      settingsJson: '{}',
      tmdbKeyJson: '"KEY"',
    );

    test('placeholders are substituted', () {
      expect(js, isNot(contains('__NUVIO_TMDB_KEY__')));
      expect(js, contains('"KEY"'));
      expect(js, contains('"scraper"'));
    });

    test('exposes every global the real providers reach for', () {
      // Derived by scanning the 61 providers of All-in-One-Nuvio: 18 use URL,
      // 15 setTimeout, 8 URLSearchParams, 6 Buffer, 5 XMLHttpRequest,
      // 3 crypto-js, plus TextEncoder, localStorage and AbortSignal.timeout.
      for (final api in [
        'G.setTimeout',
        'G.setInterval',
        'G.clearTimeout',
        'G.URL',
        'G.URLSearchParams',
        'G.Buffer',
        'G.XMLHttpRequest',
        'G.TextEncoder',
        'G.TextDecoder',
        'G.localStorage',
        'G.CryptoJS',
        'G.crypto',
        'G.fetch',
        'G.Headers',
        'G.Response',
        'G.AbortSignal',
        'G.cheerio',
        'G.require',
        'NuvioAbortSignal.timeout',
      ]) {
        expect(js, contains(api), reason: '\$api missing from the runtime');
      }
    });

    test('require() answers the modules bundles ask for', () {
      for (final module in [
        "id.indexOf('cheerio') >= 0",
        "id === 'crypto-js'",
        "id === 'crypto'",
        "id === 'buffer'",
        "id === 'url'",
        "id === 'events'",
        "id === 'util'",
        "id === 'assert'",
      ]) {
        expect(js, contains(module));
      }
    });
  });

  group('crypto bridge', () {
    test('digests match known vectors', () {
      // "abc" = 616263
      expect(
        NuvioCrypto.handle({'op': 'digest', 'alg': 'SHA256', 'data': '616263'}),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        NuvioCrypto.handle({'op': 'digest', 'alg': 'MD5', 'data': '616263'}),
        '900150983cd24fb0d6963f7d28e17f72',
      );
    });

    test('hmac matches a known vector', () {
      expect(
        NuvioCrypto.handle({
          'op': 'hmac',
          'alg': 'SHA256',
          'key': '6b6579', // "key"
          'data': '616263',
        }),
        '9c196e32dc0175f86f4b1cb89289d6619de6bee699e4c378e68309ed97a1a6ab',
      );
    });

    test('AES-CBC round-trips', () {
      const key = '00112233445566778899aabbccddeeff';
      const iv = '000102030405060708090a0b0c0d0e0f';
      final encrypted = NuvioCrypto.handle({
        'op': 'aes_encrypt',
        'mode': 'AES-CBC',
        'key': key,
        'iv': iv,
        'data': '48656c6c6f204e7576696f', // "Hello Nuvio"
      });
      expect(encrypted.startsWith('__NUVIO_ERR__'), isFalse);
      final decrypted = NuvioCrypto.handle({
        'op': 'aes_decrypt',
        'mode': 'AES-CBC',
        'key': key,
        'iv': iv,
        'data': encrypted,
      });
      expect(decrypted, '48656c6c6f204e7576696f');
    });

    test('pbkdf2 matches RFC 6070 (SHA1, 2 iterations)', () {
      expect(
        NuvioCrypto.handle({
          'op': 'pbkdf2',
          'alg': 'SHA1',
          'pass': '70617373776f7264',
          'salt': '73616c74',
          'iterations': 2,
          'bits': 160,
        }),
        'ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957',
      );
    });

    test('random returns the requested number of bytes', () {
      final hex = NuvioCrypto.handle({'op': 'random', 'bytes': 16});
      expect(hex.length, 32);
    });

    test('an unknown op reports an error instead of throwing', () {
      expect(NuvioCrypto.handle({'op': 'nope'}), startsWith('__NUVIO_ERR__'));
    });
  });

  group('dom traversal', () {
    const html = '''
      <div class="list">
        <a class="item" href="/one">One</a>
        <a class="item skip" href="/two">Two</a>
        <span>tail</span>
      </div>
    ''';

    test('filter narrows a selection by selector', () {
      final dom = NuvioDom();
      final doc = dom.load(html);
      final links = dom.query(doc, null, 'a');
      expect(links, hasLength(2));
      expect(dom.filter(doc, links, '.skip'), hasLength(1));
    });

    test('relations walk the tree like cheerio', () {
      final dom = NuvioDom();
      final doc = dom.load(html);
      final first = dom.query(doc, null, 'a.item').first;
      expect(dom.relation(doc, [first], 'parent', null), hasLength(1));
      expect(dom.relation(doc, [first], 'next', null), hasLength(1));
      expect(dom.relation(doc, [first], 'siblings', null), hasLength(2));
      expect(dom.relation(doc, [first], 'closest', '.list'), hasLength(1));
      expect(dom.relation(doc, [first], 'index', null), ['0']);
    });

    test('text concatenates the whole selection', () {
      final dom = NuvioDom();
      final doc = dom.load(html);
      final links = dom.query(doc, null, 'a');
      expect(dom.textOf(doc, links), 'OneTwo');
    });

    test('html("") returns the document', () {
      final dom = NuvioDom();
      final doc = dom.load(html);
      expect(dom.html(doc, ''), contains('class="list"'));
    });
  });
}
