import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// Cheerio-compatible DOM backing for Nuvio scrapers.
///
/// Real Nuvio plugins are bundled with `cheerio-without-node-native` and use a
/// small slice of its API — `load`, `$(sel)`, `.find`, `.first`, `.each`,
/// `.get`, `.attr`, `.text`. This class implements that slice on top of
/// package:html and hands JS stable node ids, so the JS shim stays tiny and
/// every query is a single bridge call.
class NuvioDom {
  final Map<String, _Doc> _docs = {};
  int _seq = 0;

  String load(String html) {
    final id = 'd${++_seq}';
    _docs[id] = _Doc(html_parser.parse(html));
    return id;
  }

  void free(String docId) => _docs.remove(docId);

  void clear() => _docs.clear();

  /// Query within the document, or within [contextId] when provided.
  List<String> query(String docId, String? contextId, String selector) {
    final doc = _docs[docId];
    if (doc == null) return const [];

    final root = contextId == null ? null : doc.nodes[contextId];
    if (contextId != null && root == null) return const [];

    final Iterable<dom.Element> found;
    try {
      found = root == null
          ? doc.document.querySelectorAll(selector)
          : root.querySelectorAll(selector);
    } catch (_) {
      // Cheerio tolerates selectors package:html rejects.
      return const [];
    }
    return [for (final element in found) doc.register(element)];
  }

  String? attr(String docId, String nodeId, String name) =>
      _docs[docId]?.nodes[nodeId]?.attributes[name];

  String text(String docId, String nodeId) =>
      _docs[docId]?.nodes[nodeId]?.text ?? '';

  String html(String docId, String nodeId) =>
      _docs[docId]?.nodes[nodeId]?.innerHtml ?? '';

  /// Everything the JS side needs about a batch of nodes in one call: cuts the
  /// bridge chatter that would otherwise dominate a big page.
  String describeBatch(String docId, List<String> nodeIds) {
    final doc = _docs[docId];
    if (doc == null) return '[]';
    return jsonEncode([
      for (final id in nodeIds)
        if (doc.nodes[id] case final element?)
          {
            'id': id,
            'text': element.text,
            'attrs': element.attributes.map(
              (key, value) => MapEntry(key.toString(), value),
            ),
          },
    ]);
  }

  int get documentCount => _docs.length;
}

class _Doc {
  _Doc(this.document);

  final dom.Document document;
  final Map<String, dom.Element> nodes = {};
  final Map<dom.Element, String> _ids = {};
  int _seq = 0;

  String register(dom.Element element) {
    final existing = _ids[element];
    if (existing != null) return existing;
    final id = 'n${++_seq}';
    nodes[id] = element;
    _ids[element] = id;
    return id;
  }
}
