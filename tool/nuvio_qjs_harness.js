#!/usr/bin/env node
/*
 * Runs real Nuvio provider bundles inside a real QuickJS build using the exact
 * polyfill SkyStream ships (lib/core/nuvio/data/nuvio_polyfill.dart).
 *
 *   node tool/nuvio_qjs_harness.js <providers-dir> [--id 634649] [--type movie]
 *                                  [--only 4khdhub,hdhub4u] [--timeout 45]
 *
 * The bridge channels mirror the Dart ones (fetch through node fetch, cheerio
 * through the cheerio package, crypto through node:crypto) so a provider that
 * works here exercises the same API surface it will on device.
 */
const fs = require('fs');
const path = require('path');
const nodeCrypto = require('crypto');
const { getQuickJS } = require('quickjs-emscripten');

let cheerio = null;
try { cheerio = require('cheerio'); } catch (e) { /* dom channels degrade */ }

const args = process.argv.slice(2);
const providersDir = args[0] || '.';
function flag(name, fallback) {
  const i = args.indexOf('--' + name);
  return i >= 0 ? args[i + 1] : fallback;
}
const TMDB_ID = flag('id', '634649');
const MEDIA_TYPE = flag('type', 'movie');
const SEASON = flag('season', null);
const EPISODE = flag('episode', null);
const TIMEOUT_MS = Number(flag('timeout', 45)) * 1000;
const ONLY = (flag('only', '') || '').split(',').filter(Boolean);
const TMDB_KEY = flag('key', '439c478a771f35c05022f9feabcca01c');
const VERBOSE = args.includes('--verbose');
const CONCURRENCY = Number(flag('concurrency', 1));
// Mirror flutter_js's bridge, which jsonDecodes every message.
const STRICT_BRIDGE = !args.includes('--loose-bridge');
const SETTINGS_MODE = args.includes('--settings');
const SETTINGS_VALUES = {};
args.forEach((a, i) => {
  if (a === '--set' && args[i + 1]) {
    const [k, ...rest] = args[i + 1].split('=');
    SETTINGS_VALUES[k] = rest.join('=');
  }
});

function loadPolyfill() {
  const dart = fs.readFileSync(
    path.join(__dirname, '..', 'lib', 'core', 'nuvio', 'data', 'nuvio_polyfill.dart'),
    'utf8'
  );
  const start = dart.indexOf('>>>NUVIO_POLYFILL_START');
  const end = dart.indexOf('<<<NUVIO_POLYFILL_END');
  if (start < 0 || end < 0) throw new Error('polyfill markers missing');
  const chunk = dart.substring(start, end);
  const open = chunk.indexOf("r'''");
  const close = chunk.lastIndexOf("''';");
  if (open < 0 || close < 0) throw new Error('polyfill string not found');
  return chunk.substring(open + 4, close);
}

const POLYFILL_FILE = flag('polyfill', null);
const POLYFILL = (POLYFILL_FILE ? fs.readFileSync(POLYFILL_FILE, 'utf8') : loadPolyfill())
  .replace(/__NUVIO_SCRAPER_ID__/g, JSON.stringify('harness'))
  .replace(/__NUVIO_SETTINGS__/g, JSON.stringify(SETTINGS_VALUES))
  .replace(/__NUVIO_TMDB_KEY__/g, JSON.stringify(TMDB_KEY));

// --------------------------------------------------------------- dom channels
class Dom {
  constructor() { this.docs = new Map(); this.seq = 0; }
  load(html) {
    if (!cheerio) return '';
    const id = 'd' + ++this.seq;
    this.docs.set(id, { $: cheerio.load(html), nodes: new Map(), seq: 0, ids: new Map() });
    return id;
  }
  register(doc, el) {
    if (doc.ids.has(el)) return doc.ids.get(el);
    const id = 'n' + ++doc.seq;
    doc.nodes.set(id, el);
    doc.ids.set(el, id);
    return id;
  }
  query(docId, ctx, selector) {
    const doc = this.docs.get(docId);
    if (!doc) return [];
    const root = ctx ? doc.nodes.get(ctx) : null;
    let found;
    try {
      found = root ? doc.$(root).find(selector).toArray() : doc.$(selector).toArray();
    } catch (e) { return []; }
    return found.map((el) => this.register(doc, el));
  }
  filter(docId, ids, selector) {
    const doc = this.docs.get(docId);
    if (!doc) return [];
    return ids.filter((id) => {
      const el = doc.nodes.get(id);
      try { return el && doc.$(el).is(selector); } catch (e) { return false; }
    });
  }
  relation(docId, ids, kind, selector) {
    const doc = this.docs.get(docId);
    if (!doc) return [];
    const out = [];
    for (const id of ids) {
      const el = doc.nodes.get(id);
      if (!el) continue;
      const $el = doc.$(el);
      let res;
      switch (kind) {
        case 'parent': res = $el.parent(selector || undefined); break;
        case 'parents': res = $el.parents(selector || undefined); break;
        case 'closest': res = $el.closest(selector || '*'); break;
        case 'children': res = $el.children(selector || undefined); break;
        case 'next': res = $el.next(selector || undefined); break;
        case 'nextAll': res = $el.nextAll(selector || undefined); break;
        case 'prev': res = $el.prev(selector || undefined); break;
        case 'prevAll': res = $el.prevAll(selector || undefined); break;
        case 'siblings': res = $el.siblings(selector || undefined); break;
        case 'index': out.push(String($el.index())); continue;
        default: res = null;
      }
      if (res) res.toArray().forEach((e) => out.push(this.register(doc, e)));
    }
    return out;
  }
  text(docId, ids) {
    const doc = this.docs.get(docId);
    if (!doc) return '';
    if (!ids.length) return doc.$.root().text();
    return ids.map((id) => (doc.nodes.get(id) ? doc.$(doc.nodes.get(id)).text() : '')).join('');
  }
  html(docId, id) {
    const doc = this.docs.get(docId);
    if (!doc) return '';
    if (!id) return doc.$.html();
    const el = doc.nodes.get(id);
    return el ? doc.$(el).html() || '' : '';
  }
  attr(docId, id, name) {
    const doc = this.docs.get(docId);
    if (!doc) return '';
    const el = doc.nodes.get(id);
    const v = el ? doc.$(el).attr(name) : undefined;
    return v === undefined ? '' : v;
  }
  describe(docId, ids) {
    const doc = this.docs.get(docId);
    if (!doc) return '[]';
    return JSON.stringify(ids.map((id) => {
      const el = doc.nodes.get(id);
      if (!el) return null;
      return { id, tag: el.tagName || '', text: doc.$(el).text(), attrs: el.attribs || {} };
    }).filter(Boolean));
  }
}

// ------------------------------------------------------------ crypto channel
function cryptoHandle(req) {
  const hex = (b) => Buffer.from(b).toString('hex');
  const buf = (h) => Buffer.from(String(h || ''), 'hex');
  const algName = (a) => String(a || 'SHA256').toLowerCase().replace(/[^a-z0-9]/g, '');
  try {
    switch (req.op) {
      case 'digest':
        return nodeCrypto.createHash(algName(req.alg)).update(buf(req.data)).digest('hex');
      case 'hmac':
        return nodeCrypto.createHmac(algName(req.alg), buf(req.key)).update(buf(req.data)).digest('hex');
      case 'pbkdf2':
        return hex(nodeCrypto.pbkdf2Sync(buf(req.pass), buf(req.salt), req.iterations, req.bits / 8, algName(req.alg)));
      case 'random':
        return hex(nodeCrypto.randomBytes(req.bytes || 0));
      case 'aes_encrypt':
      case 'aes_decrypt': {
        const encrypt = req.op === 'aes_encrypt';
        const key = buf(req.key);
        const iv = buf(req.iv);
        const bits = key.length * 8;
        const mode = String(req.mode || 'AES-CBC').toUpperCase();
        const noPad = mode.includes('NOPADDING');
        let algo = 'aes-' + bits + '-cbc';
        if (mode.includes('ECB')) algo = 'aes-' + bits + '-ecb';
        else if (mode.includes('GCM')) algo = 'aes-' + bits + '-gcm';
        else if (mode.includes('CTR')) algo = 'aes-' + bits + '-ctr';
        const usesIv = !mode.includes('ECB');
        const c = encrypt
          ? nodeCrypto.createCipheriv(algo, key, usesIv ? iv.subarray(0, algo.includes('gcm') ? 12 : 16) : null)
          : nodeCrypto.createDecipheriv(algo, key, usesIv ? iv.subarray(0, algo.includes('gcm') ? 12 : 16) : null);
        if (noPad && c.setAutoPadding) c.setAutoPadding(false);
        if (algo.includes('gcm') && !encrypt) c.setAuthTag(Buffer.alloc(16));
        return hex(Buffer.concat([c.update(buf(req.data)), encrypt ? c.final() : Buffer.alloc(0)]));
      }
      default:
        return '__NUVIO_ERR__unsupported op ' + req.op;
    }
  } catch (e) {
    return '__NUVIO_ERR__' + e.message;
  }
}

async function runProvider(QuickJS, file) {
  const code = fs.readFileSync(file, 'utf8');
  const name = path.basename(file, '.js');
  const runtime = QuickJS.newRuntime();
  runtime.setMemoryLimit(256 * 1024 * 1024);
  runtime.setMaxStackSize(4 * 1024 * 1024);
  const vm = runtime.newContext();
  const dom = new Dom();
  const settleQueue = [];
  const bridgeFailures = [];
  let resultJson = null;
  let logs = [];

  const sendMessage = vm.newFunction('sendMessage', (chanHandle, msgHandle) => {
    const channel = vm.getString(chanHandle);
    const message = msgHandle === undefined ? '' : vm.getString(msgHandle);
    // flutter_js (QuickJsRuntime2) hands the Dart side jsonDecode(message):
    // a payload that is not valid JSON throws, and the exception surfaces in
    // JS. STRICT mode reproduces that exactly so the harness can catch it.
    let payload = {};
    let decodeFailed = false;
    try { payload = JSON.parse(message); } catch (e) { decodeFailed = true; }
    if (decodeFailed && STRICT_BRIDGE) {
      bridgeFailures.push(channel);
      return vm.newError('FormatException: bridge payload is not JSON (' + channel + ')');
    }
    let out = '';
    switch (channel) {
      case 'nuvio_log':
        logs.push(typeof payload === 'string' ? payload : message);
        if (VERBOSE) console.log('   [' + name + ']', message);
        break;
      case 'nuvio_result':
        resultJson = typeof payload === 'string' ? payload : message;
        break;
      case 'nuvio_crypto': out = cryptoHandle(payload); break;
      case 'nuvio_dom_load': out = dom.load(payload.html || ''); break;
      case 'nuvio_dom_query': out = JSON.stringify(dom.query(payload.doc, payload.context, payload.selector)); break;
      case 'nuvio_dom_filter': out = JSON.stringify(dom.filter(payload.doc, payload.nodes || [], payload.selector)); break;
      case 'nuvio_dom_relation': out = JSON.stringify(dom.relation(payload.doc, payload.nodes || [], payload.kind, payload.selector)); break;
      case 'nuvio_dom_describe': out = dom.describe(payload.doc, payload.nodes || []); break;
      case 'nuvio_dom_text': out = dom.text(payload.doc, payload.nodes || []); break;
      case 'nuvio_dom_html': out = dom.html(payload.doc, payload.node || ''); break;
      case 'nuvio_dom_attr': out = dom.attr(payload.doc, payload.node, payload.name); break;
      case 'nuvio_fetch': {
        const id = payload.id;
        doFetch(payload).then((res) => settleQueue.push([id, res, null]))
          .catch((err) => settleQueue.push([id, null, String(err && err.message || err)]));
        break;
      }
      default: out = '';
    }
    return vm.newString(out === undefined || out === null ? '' : String(out));
  });
  vm.setProp(vm.global, 'sendMessage', sendMessage);
  sendMessage.dispose();

  function evalOrThrow(source, label) {
    const res = vm.evalCode(source);
    if (res.error) {
      const err = vm.dump(res.error);
      res.error.dispose();
      throw new Error(label + ': ' + (err && err.message ? err.message : JSON.stringify(err)));
    }
    res.value.dispose();
  }

  const started = Date.now();
  let status = 'ok';
  let streams = [];
  let error = null;
  try {
    evalOrThrow(POLYFILL, 'polyfill');
    evalOrThrow('var module = { exports: {} }; var exports = module.exports; (function(){\n' + code + '\n})();', 'load');
    const seasonArg = SEASON == null ? 'undefined' : SEASON;
    const episodeArg = EPISODE == null ? 'undefined' : EPISODE;
    if (SETTINGS_MODE) {
      evalOrThrow(
        '(async function(){ try {' +
        ' var os = (module.exports && module.exports.onSettings) || globalThis.onSettings;' +
        ' if (typeof os !== "function") { __nuvio_result(JSON.stringify({layout: []})); return; }' +
        ' var layout = await os();' +
        ' __nuvio_result(JSON.stringify({layout: layout || []}));' +
        ' } catch (e) { __nuvio_result(JSON.stringify({error: (e && e.message) ? e.message : String(e)})); } })();',
        'settings'
      );
    } else evalOrThrow(
      '(async function(){ try {' +
      ' var gs = (module.exports && module.exports.getStreams) || globalThis.getStreams;' +
      ' if (!gs) { __nuvio_result(JSON.stringify({error: "getStreams not found"})); return; }' +
      ' var out = await gs(' + JSON.stringify(TMDB_ID) + ',' + JSON.stringify(MEDIA_TYPE) + ',' + seasonArg + ',' + episodeArg + ');' +
      ' __nuvio_result(JSON.stringify({streams: out || []}));' +
      ' } catch (e) { __nuvio_result(JSON.stringify({error: (e && e.message) ? e.message : String(e), stack: e && e.stack})); } })();',
      'call'
    );

    while (resultJson === null && Date.now() - started < TIMEOUT_MS) {
      while (settleQueue.length) {
        const [id, payload, err] = settleQueue.shift();
        const script = 'globalThis.__nuvio_settle(' + JSON.stringify(id) + ',' +
          (payload ? JSON.stringify(payload) : 'null') + ',' +
          (err ? JSON.stringify(err) : 'null') + ')';
        const r = vm.evalCode(script);
        if (r.error) r.error.dispose(); else r.value.dispose();
      }
      if (runtime.hasPendingJob()) runtime.executePendingJobs();
      const tick = vm.evalCode('__nuvio_tick && __nuvio_tick();');
      if (tick.error) tick.error.dispose(); else tick.value.dispose();
      await new Promise((r) => setTimeout(r, 5));
    }

    if (resultJson === null) {
      status = 'timeout';
    } else {
      const parsed = JSON.parse(resultJson);
      if (parsed.error) { status = 'error'; error = parsed.error; }
      else if (SETTINGS_MODE) {
        const layout = parsed.layout || [];
        streams = layout;
        const types = [...new Set(layout.map((f) => f && f.type))].join(',');
        status = layout.length ? 'fields' : 'none';
        error = layout.length ? types : '';
      }
      else { streams = parsed.streams || []; status = streams.length ? 'links' : 'empty'; }
    }
  } catch (e) {
    status = 'crash';
    error = e.message;
  } finally {
    try { vm.dispose(); } catch (e) {}
    try { runtime.dispose(); } catch (e) {}
  }
  if (bridgeFailures.length) {
    error = (error ? error + ' | ' : '') + 'bridge rejected ' + bridgeFailures.length +
      ' message(s) on ' + [...new Set(bridgeFailures)].join(',');
    if (status === 'empty') status = 'bridge';
  }
  return { name, status, count: streams.length, error, seconds: ((Date.now() - started) / 1000).toFixed(1), sample: streams[0], logs };
}

async function doFetch(payload) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 25000);
  try {
    const res = await fetch(payload.url, {
      method: payload.method || 'GET',
      headers: payload.headers || {},
      body: payload.body === null ? undefined : payload.body,
      redirect: payload.follow === false ? 'manual' : 'follow',
      signal: controller.signal
    });
    const body = await res.text();
    const headers = {};
    res.headers.forEach((v, k) => { headers[k.toLowerCase()] = v; });
    return {
      ok: res.ok, status: res.status, statusText: res.statusText,
      url: res.url, redirected: res.redirected, headers, body
    };
  } finally {
    clearTimeout(timer);
  }
}

(async () => {
  const QuickJS = await getQuickJS();
  let files = fs.readdirSync(providersDir).filter((f) => f.endsWith('.js'));
  if (ONLY.length) files = files.filter((f) => ONLY.includes(path.basename(f, '.js')));
  const results = [];
  const queue = files.slice();
  const workers = Array.from({ length: Math.max(1, Math.min(CONCURRENCY, files.length)) }, async () => {
    while (queue.length) {
      const f = queue.shift();
      const r = await runProvider(QuickJS, path.join(providersDir, f));
      results.push(r);
      report(r);
    }
  });
  await Promise.all(workers);
  function report(r) {
    const detail = r.status === 'links'
      ? r.count + ' links'
      : (r.status === 'fields' ? r.count + ' fields: ' + (r.error || '') : (r.error || ''));
    console.log(
      String(r.name).padEnd(20),
      String(r.status).padEnd(8),
      String(r.seconds + 's').padEnd(7),
      String(detail).slice(0, 110)
    );
  }
  const by = (s) => results.filter((r) => r.status === s).length;
  if (SETTINGS_MODE) {
    console.log('\n--- ' + results.length + ' providers: with-settings-form=' + by('fields') +
      ' none=' + by('none') + ' error=' + by('error') +
      ' crash=' + by('crash') + ' timeout=' + by('timeout'));
    fs.writeFileSync('/tmp/nuvio_settings_results.json', JSON.stringify(results, null, 2));
    return;
  }
  console.log('\n--- ' + results.length + ' providers: links=' + by('links') +
    ' empty=' + by('empty') + ' error=' + by('error') +
    ' crash=' + by('crash') + ' timeout=' + by('timeout'));
  fs.writeFileSync('/tmp/nuvio_harness_results.json', JSON.stringify(results, null, 2));
})();
