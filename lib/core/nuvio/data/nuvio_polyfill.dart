/// The JavaScript environment real Nuvio scrapers are written against.
///
/// Nuvio (NuvioMobile) hands its plugins a fairly wide surface: fetch, cheerio,
/// crypto-js, WebCrypto-ish helpers, URL, timers, Node-isms. Every API missing
/// here is a scraper that returns nothing — which is exactly why only a couple
/// of providers used to answer. The set below was derived by scanning the 61
/// providers of `NuvioPlugin/All-in-One-Nuvio` for the globals they touch.
///
/// The string is kept in one place (and marked with the START/END comments) so
/// `tool/nuvio_qjs_harness.js` can run *this exact code* inside a real QuickJS
/// build and prove the providers load and execute.
library;

String buildNuvioPolyfill({
  required String scraperIdJson,
  required String settingsJson,
  required String tmdbKeyJson,
}) {
  return nuvioPolyfillSource
      .replaceAll('__NUVIO_SCRAPER_ID__', scraperIdJson)
      .replaceAll('__NUVIO_SETTINGS__', settingsJson)
      .replaceAll('__NUVIO_TMDB_KEY__', tmdbKeyJson);
}

// >>>NUVIO_POLYFILL_START
const String nuvioPolyfillSource = r'''
(function () {
  var G = globalThis;
  if (typeof G.global === 'undefined') G.global = G;
  if (typeof G.window === 'undefined') G.window = G;
  if (typeof G.self === 'undefined') G.self = G;

  G.SCRAPER_ID = __NUVIO_SCRAPER_ID__;
  G.NUVIO_SCRAPER_ID = G.SCRAPER_ID;
  G.SCRAPER_SETTINGS = __NUVIO_SETTINGS__;
  G.NUVIO_SETTINGS = G.SCRAPER_SETTINGS;
  G.getScraperSetting = function (key, fallback) {
    var s = G.SCRAPER_SETTINGS || {};
    return s[key] !== undefined ? s[key] : fallback;
  };

  var TMDB_KEY_VALUE = __NUVIO_TMDB_KEY__;
  G.TMDB_API_KEY = TMDB_KEY_VALUE;
  G.TMDB_KEY = TMDB_KEY_VALUE;
  G.process = G.process || { env: {}, platform: 'android', version: 'v18.0.0', argv: [] };
  G.process.env = G.process.env || {};
  G.process.env.TMDB_API_KEY = TMDB_KEY_VALUE;
  G.process.nextTick = function (fn) { Promise.resolve().then(fn); };

  function bridge(channel, payload) {
    return sendMessage(channel, JSON.stringify(payload === undefined ? {} : payload));
  }
  G.__nuvio_bridge = bridge;

  // ---------------------------------------------------------------- console
  function fmt(args) {
    var out = [];
    for (var i = 0; i < args.length; i++) {
      var a = args[i];
      if (a === null) { out.push('null'); continue; }
      if (typeof a === 'string') { out.push(a); continue; }
      if (typeof a === 'object') {
        try { out.push(JSON.stringify(a)); } catch (e) { out.push(String(a)); }
        continue;
      }
      out.push(String(a));
    }
    return out.join(' ');
  }
  G.console = {
    log: function () { sendMessage('nuvio_log', fmt(arguments)); },
    info: function () { sendMessage('nuvio_log', fmt(arguments)); },
    debug: function () { sendMessage('nuvio_log', fmt(arguments)); },
    warn: function () { sendMessage('nuvio_log', 'WARN ' + fmt(arguments)); },
    error: function () { sendMessage('nuvio_log', 'ERROR ' + fmt(arguments)); },
    trace: function () {},
    table: function () {},
    group: function () {},
    groupEnd: function () {},
    time: function () {},
    timeEnd: function () {}
  };

  // ----------------------------------------------------------------- result
  G.__nuvio_pending = {};
  G.__nuvio_seq = 0;
  G.__nuvio_result = function (payload) { sendMessage('nuvio_result', payload); };
  G.__nuvio_settle = function (id, payload, error) {
    var entry = G.__nuvio_pending[id];
    if (!entry) return;
    delete G.__nuvio_pending[id];
    if (error) { entry.reject(new Error(error)); return; }
    entry.resolve(payload);
  };

  // ----------------------------------------------------------------- timers
  // QuickJS has no event loop of its own here; the host pumps __nuvio_tick()
  // so setTimeout/setInterval behave like the real thing (15 of the 61 real
  // providers use them for retries and rate limiting).
  var timers = {};
  var timerSeq = 0;
  G.setTimeout = function (fn, delay) {
    var id = ++timerSeq;
    var args = Array.prototype.slice.call(arguments, 2);
    timers[id] = {
      fn: fn,
      due: Date.now() + (Number(delay) || 0),
      interval: null,
      args: args
    };
    return id;
  };
  G.setInterval = function (fn, delay) {
    var id = ++timerSeq;
    var every = Math.max(1, Number(delay) || 0);
    var args = Array.prototype.slice.call(arguments, 2);
    timers[id] = { fn: fn, due: Date.now() + every, interval: every, args: args };
    return id;
  };
  G.clearTimeout = function (id) { delete timers[id]; };
  G.clearInterval = G.clearTimeout;
  G.setImmediate = function (fn) { return G.setTimeout(fn, 0); };
  G.clearImmediate = G.clearTimeout;
  G.queueMicrotask = function (fn) { Promise.resolve().then(fn); };
  G.__nuvio_tick = function () {
    var now = Date.now();
    var ids = Object.keys(timers);
    for (var i = 0; i < ids.length; i++) {
      var t = timers[ids[i]];
      if (!t || t.due > now) continue;
      if (t.interval) { t.due = now + t.interval; } else { delete timers[ids[i]]; }
      try { t.fn.apply(null, t.args); } catch (e) { console.error('timer', e && e.message); }
    }
    return Object.keys(timers).length;
  };

  // ----------------------------------------------------------------- base64
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  G.btoa = function (input) {
    var str = String(input), out = '', i = 0;
    while (i < str.length) {
      var c1 = str.charCodeAt(i++), c2 = str.charCodeAt(i++), c3 = str.charCodeAt(i++);
      if (c1 > 255 || (c2 === c2 && c2 > 255) || (c3 === c3 && c3 > 255)) {
        throw new Error('InvalidCharacterError');
      }
      var e1 = c1 >> 2;
      var e2 = ((c1 & 3) << 4) | (isNaN(c2) ? 0 : c2 >> 4);
      var e3 = isNaN(c2) ? 64 : (((c2 & 15) << 2) | (isNaN(c3) ? 0 : c3 >> 6));
      var e4 = isNaN(c3) ? 64 : (c3 & 63);
      out += B64.charAt(e1) + B64.charAt(e2) +
        (e3 === 64 ? '=' : B64.charAt(e3)) + (e4 === 64 ? '=' : B64.charAt(e4));
    }
    return out;
  };
  G.atob = function (input) {
    var str = String(input).replace(/[\t\n\f\r ]+/g, '').replace(/=+$/, '');
    var out = '', bc = 0, bs = 0, buffer, i = 0;
    while ((buffer = str.charAt(i++))) {
      buffer = B64.indexOf(buffer);
      if (buffer === -1) continue;
      bs = bc % 4 ? bs * 64 + buffer : buffer;
      if (bc++ % 4) out += String.fromCharCode(255 & (bs >> ((-2 * bc) & 6)));
    }
    return out;
  };

  // -------------------------------------------------------- byte/hex helpers
  function toU8(data) {
    if (!data) return new Uint8Array(0);
    if (data instanceof Uint8Array) return data;
    if (data instanceof ArrayBuffer) return new Uint8Array(data);
    if (typeof ArrayBuffer !== 'undefined' && ArrayBuffer.isView && ArrayBuffer.isView(data)) {
      return new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength);
    }
    if (Array.isArray(data)) return new Uint8Array(data);
    if (typeof data === 'string') return utf8ToBytes(data);
    if (typeof data.length === 'number') return new Uint8Array(Array.prototype.slice.call(data));
    return new Uint8Array(0);
  }
  function bytesToHex(bytes) {
    bytes = toU8(bytes);
    var out = '';
    for (var i = 0; i < bytes.length; i++) {
      var h = bytes[i].toString(16);
      out += h.length < 2 ? '0' + h : h;
    }
    return out;
  }
  function hexToBytes(hex) {
    hex = String(hex || '').replace(/[^0-9a-fA-F]/g, '');
    if (hex.length % 2) hex = '0' + hex;
    var out = new Uint8Array(hex.length / 2);
    for (var i = 0; i < hex.length; i += 2) out[i / 2] = parseInt(hex.substr(i, 2), 16);
    return out;
  }
  function utf8ToBytes(str) {
    str = String(str);
    var out = [], i = 0;
    for (; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
        var c2 = str.charCodeAt(++i);
        var cp = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
        out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
      } else out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return new Uint8Array(out);
  }
  function bytesToUtf8(bytes) {
    bytes = toU8(bytes);
    var out = '', i = 0;
    while (i < bytes.length) {
      var c = bytes[i++];
      if (c < 0x80) out += String.fromCharCode(c);
      else if (c > 0xbf && c < 0xe0) out += String.fromCharCode(((c & 31) << 6) | (bytes[i++] & 63));
      else if (c > 0xdf && c < 0xf0) {
        out += String.fromCharCode(((c & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63));
      } else {
        var cp = (((c & 7) << 18) | ((bytes[i++] & 63) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63)) - 0x10000;
        out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 1023));
      }
    }
    return out;
  }
  G.__nuvio_bytes = { toU8: toU8, hex: bytesToHex, unhex: hexToBytes, utf8: utf8ToBytes, str: bytesToUtf8 };

  // --------------------------------------------------- TextEncoder / Decoder
  if (typeof G.TextEncoder === 'undefined') {
    G.TextEncoder = function () { this.encoding = 'utf-8'; };
    G.TextEncoder.prototype.encode = function (s) { return utf8ToBytes(s == null ? '' : s); };
  }
  if (typeof G.TextDecoder === 'undefined') {
    G.TextDecoder = function (enc) { this.encoding = enc || 'utf-8'; };
    G.TextDecoder.prototype.decode = function (b) { return bytesToUtf8(b); };
  }

  // ---------------------------------------------------------------- crypto
  function cryptoCall(op, payload) {
    payload = payload || {};
    payload.op = op;
    var raw = bridge('nuvio_crypto', payload);
    if (raw && raw.indexOf('__NUVIO_ERR__') === 0) {
      throw new Error(raw.substring('__NUVIO_ERR__'.length));
    }
    return raw;
  }
  function digestBytes(alg, bytes) { return hexToBytes(cryptoCall('digest', { alg: alg, data: bytesToHex(bytes) })); }
  function hmacBytes(alg, key, data) {
    return hexToBytes(cryptoCall('hmac', { alg: alg, key: bytesToHex(key), data: bytesToHex(data) }));
  }
  function pbkdf2Bytes(pass, salt, iterations, bits, alg) {
    return hexToBytes(cryptoCall('pbkdf2', {
      alg: alg, pass: bytesToHex(pass), salt: bytesToHex(salt),
      iterations: iterations, bits: bits
    }));
  }
  function aesBytes(encrypt, mode, key, iv, data) {
    return hexToBytes(cryptoCall(encrypt ? 'aes_encrypt' : 'aes_decrypt', {
      mode: mode, key: bytesToHex(key), iv: bytesToHex(iv), data: bytesToHex(data)
    }));
  }
  function randomBytes(n) { return hexToBytes(cryptoCall('random', { bytes: n })); }

  G.crypto = G.crypto || {};
  G.crypto.getRandomValues = function (arr) {
    var bytes = randomBytes(arr.length * (arr.BYTES_PER_ELEMENT || 1));
    if (arr instanceof Uint8Array) { arr.set(bytes.subarray(0, arr.length)); return arr; }
    for (var i = 0; i < arr.length; i++) arr[i] = bytes[i % bytes.length];
    return arr;
  };
  G.crypto.randomUUID = function () {
    var b = randomBytes(16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    var h = bytesToHex(b);
    return h.substr(0, 8) + '-' + h.substr(8, 4) + '-' + h.substr(12, 4) + '-' + h.substr(16, 4) + '-' + h.substr(20);
  };
  G.crypto.subtle = G.crypto.subtle || {
    digest: function (alg, data) {
      return Promise.resolve(digestBytes(normalizeHash(alg), toU8(data)).buffer);
    },
    importKey: function (format, keyData) {
      return Promise.resolve({ __rawKey: toU8(keyData) });
    },
    sign: function (algo, key, data) {
      var hash = normalizeHash((algo && algo.hash) || 'SHA-256');
      return Promise.resolve(hmacBytes(hash, key.__rawKey || toU8(key), toU8(data)).buffer);
    },
    encrypt: function (algo, key, data) {
      var mode = normalizeAes(algo && algo.name);
      var iv = toU8((algo && (algo.iv || algo.counter)) || new Uint8Array(16));
      return Promise.resolve(aesBytes(true, mode, key.__rawKey || toU8(key), iv, toU8(data)).buffer);
    },
    decrypt: function (algo, key, data) {
      var mode = normalizeAes(algo && algo.name);
      var iv = toU8((algo && (algo.iv || algo.counter)) || new Uint8Array(16));
      return Promise.resolve(aesBytes(false, mode, key.__rawKey || toU8(key), iv, toU8(data)).buffer);
    }
  };
  function normalizeHash(h) {
    var name = String((h && h.name) ? h.name : (h || 'SHA-256')).toUpperCase().replace(/[^A-Z0-9]/g, '');
    if (name === 'SHA1' || name === 'SHA256' || name === 'SHA384' || name === 'SHA512' || name === 'MD5') return name;
    return 'SHA256';
  }
  function normalizeAes(name) {
    name = String(name || 'AES-CBC').toUpperCase();
    if (name.indexOf('GCM') >= 0) return 'AES-GCM';
    if (name.indexOf('ECB') >= 0) return 'AES-ECB';
    if (name.indexOf('CTR') >= 0) return 'AES-CTR';
    return 'AES-CBC';
  }

  // ------------------------------------------------------------- CryptoJS
  function WordArray(words, sigBytes) {
    this.words = words || [];
    this.sigBytes = sigBytes === undefined ? this.words.length * 4 : sigBytes;
  }
  WordArray.prototype.toString = function (enc) { return (enc || CryptoJS.enc.Hex).stringify(this); };
  WordArray.prototype.clone = function () { return new WordArray(this.words.slice(0), this.sigBytes); };
  WordArray.prototype.concat = function (other) {
    var a = waToBytes(this), b = waToBytes(other);
    var out = new Uint8Array(a.length + b.length);
    out.set(a, 0); out.set(b, a.length);
    var merged = bytesToWa(out);
    this.words = merged.words; this.sigBytes = merged.sigBytes;
    return this;
  };
  function isWa(v) { return v && typeof v === 'object' && Array.isArray(v.words) && typeof v.sigBytes === 'number'; }
  function waToBytes(wa) {
    if (!isWa(wa)) return toU8(wa);
    var out = new Uint8Array(wa.sigBytes);
    for (var i = 0; i < wa.sigBytes; i++) out[i] = (wa.words[i >>> 2] >>> (24 - (i % 4) * 8)) & 0xff;
    return out;
  }
  function bytesToWa(bytes) {
    bytes = toU8(bytes);
    var words = [];
    for (var i = 0; i < bytes.length; i++) words[i >>> 2] |= (bytes[i] & 0xff) << (24 - (i % 4) * 8);
    return new WordArray(words, bytes.length);
  }
  function anyToBytes(v) {
    if (isWa(v)) return waToBytes(v);
    if (typeof v === 'string') return utf8ToBytes(v);
    return toU8(v);
  }
  function evpKdf(passBytes, saltBytes, keyLen, ivLen) {
    var target = keyLen + ivLen, derived = new Uint8Array(target);
    var block = new Uint8Array(0), offset = 0;
    while (offset < target) {
      var input = new Uint8Array(block.length + passBytes.length + saltBytes.length);
      input.set(block, 0); input.set(passBytes, block.length); input.set(saltBytes, block.length + passBytes.length);
      block = digestBytes('MD5', input);
      var take = Math.min(block.length, target - offset);
      derived.set(block.subarray(0, take), offset);
      offset += take;
    }
    return { key: derived.subarray(0, keyLen), iv: derived.subarray(keyLen, target) };
  }
  var CryptoJS = {
    lib: {
      WordArray: {
        create: function (words, sigBytes) {
          if (words == null) return new WordArray([], sigBytes || 0);
          if (isWa(words)) return words.clone();
          if (typeof words === 'string') return bytesToWa(utf8ToBytes(words));
          if (words instanceof ArrayBuffer || (ArrayBuffer.isView && ArrayBuffer.isView(words))) {
            var b = toU8(words);
            return bytesToWa(sigBytes === undefined ? b : b.subarray(0, sigBytes));
          }
          return new WordArray(words, sigBytes);
        },
        random: function (n) { return bytesToWa(randomBytes(n || 0)); }
      },
      CipherParams: {
        create: function (params) {
          params = params || {};
          params.toString = params.toString || function (f) { return (f || CryptoJS.format.OpenSSL).stringify(this); };
          return params;
        }
      }
    },
    enc: {
      Hex: {
        stringify: function (wa) { return bytesToHex(waToBytes(wa)); },
        parse: function (hex) { return bytesToWa(hexToBytes(hex)); }
      },
      Utf8: {
        stringify: function (wa) { return bytesToUtf8(waToBytes(wa)); },
        parse: function (s) { return bytesToWa(utf8ToBytes(s)); }
      },
      Latin1: {
        stringify: function (wa) {
          var b = waToBytes(wa), out = '';
          for (var i = 0; i < b.length; i++) out += String.fromCharCode(b[i]);
          return out;
        },
        parse: function (s) {
          s = String(s || '');
          var b = new Uint8Array(s.length);
          for (var i = 0; i < s.length; i++) b[i] = s.charCodeAt(i) & 0xff;
          return bytesToWa(b);
        }
      },
      Base64: {
        stringify: function (wa) {
          var b = waToBytes(wa), s = '';
          for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
          return G.btoa(s);
        },
        parse: function (s) {
          var bin = G.atob(String(s || ''));
          var b = new Uint8Array(bin.length);
          for (var i = 0; i < bin.length; i++) b[i] = bin.charCodeAt(i) & 0xff;
          return bytesToWa(b);
        }
      }
    },
    format: {
      OpenSSL: {
        stringify: function (p) {
          var body = waToBytes(p.ciphertext);
          if (p.salt) {
            var salted = utf8ToBytes('Salted__'), s = waToBytes(p.salt);
            var out = new Uint8Array(salted.length + s.length + body.length);
            out.set(salted, 0); out.set(s, salted.length); out.set(body, salted.length + s.length);
            body = out;
          }
          return CryptoJS.enc.Base64.stringify(bytesToWa(body));
        },
        parse: function (str) {
          var bytes = waToBytes(CryptoJS.enc.Base64.parse(str));
          if (bytes.length > 16 && bytesToUtf8(bytes.subarray(0, 8)) === 'Salted__') {
            return CryptoJS.lib.CipherParams.create({
              salt: bytesToWa(bytes.subarray(8, 16)),
              ciphertext: bytesToWa(bytes.subarray(16))
            });
          }
          return CryptoJS.lib.CipherParams.create({ ciphertext: bytesToWa(bytes) });
        }
      }
    },
    mode: { CBC: 'AES-CBC', ECB: 'AES-ECB', GCM: 'AES-GCM', CTR: 'AES-CTR' },
    pad: { Pkcs7: 'Pkcs7', NoPadding: 'NoPadding', ZeroPadding: 'ZeroPadding' },
    algo: { MD5: 'MD5', SHA1: 'SHA1', SHA256: 'SHA256', SHA384: 'SHA384', SHA512: 'SHA512' }
  };
  ['MD5', 'SHA1', 'SHA256', 'SHA384', 'SHA512'].forEach(function (alg) {
    CryptoJS[alg] = function (msg) { return bytesToWa(digestBytes(alg, anyToBytes(msg))); };
    CryptoJS['Hmac' + alg] = function (msg, key) {
      return bytesToWa(hmacBytes(alg, anyToBytes(key), anyToBytes(msg)));
    };
  });
  CryptoJS.PBKDF2 = function (pass, salt, opts) {
    opts = opts || {};
    return bytesToWa(pbkdf2Bytes(
      anyToBytes(pass), anyToBytes(salt),
      opts.iterations || 1000, (opts.keySize || 4) * 32,
      String(opts.hasher || 'SHA1').toUpperCase().replace(/[^A-Z0-9]/g, '')
    ));
  };
  function aesMode(opts) {
    var mode = (opts && opts.mode) ? opts.mode : 'AES-CBC';
    var name = normalizeAes(typeof mode === 'string' ? mode : (mode.name || 'AES-CBC'));
    if (opts && (opts.padding === 'NoPadding' || opts.padding === CryptoJS.pad.NoPadding)) name += '-NoPadding';
    return name;
  }
  CryptoJS.AES = {
    encrypt: function (message, key, opts) {
      opts = opts || {};
      var data = anyToBytes(message), keyBytes, ivBytes, saltBytes;
      if (typeof key === 'string') {
        saltBytes = opts.salt ? waToBytes(opts.salt) : randomBytes(8);
        var d = evpKdf(utf8ToBytes(key), saltBytes, 32, 16);
        keyBytes = d.key; ivBytes = opts.iv ? waToBytes(opts.iv) : d.iv;
      } else {
        keyBytes = anyToBytes(key);
        ivBytes = opts.iv ? anyToBytes(opts.iv) : new Uint8Array(16);
      }
      var out = aesBytes(true, aesMode(opts), keyBytes, ivBytes, data);
      return CryptoJS.lib.CipherParams.create({
        ciphertext: bytesToWa(out),
        key: bytesToWa(keyBytes),
        iv: bytesToWa(ivBytes),
        salt: saltBytes ? bytesToWa(saltBytes) : undefined
      });
    },
    decrypt: function (cipher, key, opts) {
      opts = opts || {};
      var params = typeof cipher === 'string' ? CryptoJS.format.OpenSSL.parse(cipher) : cipher;
      var data = waToBytes(params.ciphertext || params);
      var keyBytes, ivBytes;
      if (typeof key === 'string') {
        var salt = params.salt ? waToBytes(params.salt) : new Uint8Array(0);
        var d = evpKdf(utf8ToBytes(key), salt, 32, 16);
        keyBytes = d.key; ivBytes = opts.iv ? waToBytes(opts.iv) : d.iv;
      } else {
        keyBytes = anyToBytes(key);
        ivBytes = opts.iv ? anyToBytes(opts.iv) : new Uint8Array(16);
      }
      return bytesToWa(aesBytes(false, aesMode(opts), keyBytes, ivBytes, data));
    }
  };
  G.CryptoJS = CryptoJS;

  // ------------------------------------------------------------------- URL
  function NuvioSearchParams(init) {
    this._pairs = [];
    var self = this;
    if (typeof init === 'string') {
      init.replace(/^\?/, '').split('&').forEach(function (pair) {
        if (!pair) return;
        var idx = pair.indexOf('=');
        var k = idx < 0 ? pair : pair.slice(0, idx);
        var v = idx < 0 ? '' : pair.slice(idx + 1);
        try {
          self._pairs.push([decodeURIComponent(k.replace(/\+/g, ' ')), decodeURIComponent(v.replace(/\+/g, ' '))]);
        } catch (e) { self._pairs.push([k, v]); }
      });
    } else if (init && typeof init.forEach === 'function' && !Array.isArray(init)) {
      init.forEach(function (v, k) { self._pairs.push([String(k), String(v)]); });
    } else if (Array.isArray(init)) {
      init.forEach(function (p) { if (p && p.length >= 2) self._pairs.push([String(p[0]), String(p[1])]); });
    } else if (init && typeof init === 'object') {
      Object.keys(init).forEach(function (k) { self._pairs.push([k, String(init[k])]); });
    }
  }
  NuvioSearchParams.prototype.append = function (k, v) { this._pairs.push([String(k), String(v)]); };
  NuvioSearchParams.prototype.set = function (k, v) {
    var done = false;
    this._pairs = this._pairs.filter(function (p) {
      if (p[0] !== String(k)) return true;
      if (done) return false;
      done = true; p[1] = String(v); return true;
    });
    if (!done) this._pairs.push([String(k), String(v)]);
  };
  NuvioSearchParams.prototype.get = function (k) {
    for (var i = 0; i < this._pairs.length; i++) if (this._pairs[i][0] === String(k)) return this._pairs[i][1];
    return null;
  };
  NuvioSearchParams.prototype.getAll = function (k) {
    return this._pairs.filter(function (p) { return p[0] === String(k); }).map(function (p) { return p[1]; });
  };
  NuvioSearchParams.prototype.has = function (k) { return this.get(k) !== null; };
  NuvioSearchParams.prototype['delete'] = function (k) {
    this._pairs = this._pairs.filter(function (p) { return p[0] !== String(k); });
  };
  NuvioSearchParams.prototype.forEach = function (fn) {
    var self = this;
    this._pairs.slice().forEach(function (p) { fn(p[1], p[0], self); });
  };
  NuvioSearchParams.prototype.keys = function () { return this._pairs.map(function (p) { return p[0]; }); };
  NuvioSearchParams.prototype.values = function () { return this._pairs.map(function (p) { return p[1]; }); };
  NuvioSearchParams.prototype.entries = function () { return this._pairs.map(function (p) { return [p[0], p[1]]; }); };
  NuvioSearchParams.prototype.sort = function () { this._pairs.sort(function (a, b) { return a[0] < b[0] ? -1 : (a[0] > b[0] ? 1 : 0); }); };
  NuvioSearchParams.prototype.toString = function () {
    return this._pairs.map(function (p) {
      return encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1]);
    }).join('&');
  };
  G.URLSearchParams = NuvioSearchParams;

  function NuvioURL(input, base) {
    var url = String(input == null ? '' : input);
    if (base && !/^[a-zA-Z][a-zA-Z0-9+\-.]*:/.test(url)) {
      var b = String(typeof base === 'string' ? base : base.href);
      var origin = (b.match(/^([a-zA-Z][a-zA-Z0-9+\-.]*:\/\/[^\/?#]+)/) || [])[1] || '';
      if (url.indexOf('//') === 0) {
        url = (b.split(':')[0]) + ':' + url;
      } else if (url.charAt(0) === '/') {
        url = origin + url;
      } else if (url.charAt(0) === '?') {
        url = b.split('?')[0] + url;
      } else if (url.charAt(0) === '#') {
        url = b.split('#')[0] + url;
      } else {
        var path = b.split('#')[0].split('?')[0];
        url = path.replace(/\/[^\/]*$/, '/') + url;
      }
    }
    var m = /^([a-zA-Z][a-zA-Z0-9+\-.]*:)\/\/([^\/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/.exec(url);
    if (!m) throw new TypeError('Invalid URL: ' + url);
    var authority = m[2], userinfo = '', hostport = authority;
    var at = authority.lastIndexOf('@');
    if (at >= 0) { userinfo = authority.substring(0, at); hostport = authority.substring(at + 1); }
    var host = hostport, port = '';
    var portMatch = /^(\[[^\]]*\]|[^:]*)(?::(\d+))?$/.exec(hostport);
    if (portMatch) { host = portMatch[1]; port = portMatch[2] || ''; }
    this.protocol = m[1];
    this.username = userinfo.split(':')[0] || '';
    this.password = userinfo.indexOf(':') >= 0 ? userinfo.split(':')[1] : '';
    this.hostname = host;
    this.port = port;
    this.host = port ? host + ':' + port : host;
    this.pathname = m[3] || '/';
    this.search = m[4] || '';
    this.hash = m[5] || '';
    this.origin = this.protocol + '//' + this.host;
    this.searchParams = new NuvioSearchParams(this.search);
    var self = this;
    Object.defineProperty(this, 'href', {
      enumerable: true,
      get: function () {
        var q = self.searchParams.toString();
        return self.origin + self.pathname + (q ? '?' + q : '') + self.hash;
      },
      set: function (v) { NuvioURL.call(self, v); }
    });
  }
  NuvioURL.prototype.toString = function () { return this.href; };
  NuvioURL.prototype.toJSON = function () { return this.href; };
  G.URL = G.URL || NuvioURL;
  if (!G.URL.prototype.toString) G.URL.prototype.toString = NuvioURL.prototype.toString;

  // -------------------------------------------------------- Abort machinery
  function NuvioAbortSignal() { this.aborted = false; this.reason = undefined; this._listeners = []; }
  NuvioAbortSignal.prototype.addEventListener = function (type, fn) {
    if (type === 'abort' && typeof fn === 'function') this._listeners.push(fn);
  };
  NuvioAbortSignal.prototype.removeEventListener = function (type, fn) {
    this._listeners = this._listeners.filter(function (l) { return l !== fn; });
  };
  NuvioAbortSignal.prototype.throwIfAborted = function () { if (this.aborted) throw this.reason; };
  NuvioAbortSignal.prototype.dispatchEvent = function (ev) {
    var self = this;
    this._listeners.slice().forEach(function (l) { try { l.call(self, ev); } catch (e) {} });
    if (typeof this.onabort === 'function') { try { this.onabort(ev); } catch (e) {} }
    return true;
  };
  NuvioAbortSignal.timeout = function (ms) {
    var signal = new NuvioAbortSignal();
    G.setTimeout(function () {
      if (signal.aborted) return;
      signal.aborted = true;
      var err = new Error('The operation was aborted due to timeout');
      err.name = 'TimeoutError';
      signal.reason = err;
      signal.dispatchEvent({ type: 'abort' });
    }, ms);
    return signal;
  };
  NuvioAbortSignal.abort = function (reason) {
    var s = new NuvioAbortSignal();
    s.aborted = true; s.reason = reason;
    return s;
  };
  G.AbortSignal = NuvioAbortSignal;
  G.AbortController = function () {
    this.signal = new NuvioAbortSignal();
    var self = this;
    this.abort = function (reason) {
      if (self.signal.aborted) return;
      self.signal.aborted = true;
      var err = reason;
      if (!err) { err = new Error('The operation was aborted'); err.name = 'AbortError'; }
      self.signal.reason = err;
      self.signal.dispatchEvent({ type: 'abort' });
    };
  };

  // ----------------------------------------------------------------- fetch
  function NuvioHeaders(init) {
    this._map = {};
    var self = this;
    if (init instanceof NuvioHeaders) init = init._map;
    if (Array.isArray(init)) {
      init.forEach(function (p) { if (p && p.length >= 2) self._map[String(p[0]).toLowerCase()] = String(p[1]); });
    } else if (init && typeof init.forEach === 'function') {
      init.forEach(function (v, k) { self._map[String(k).toLowerCase()] = String(v); });
    } else if (init && typeof init === 'object') {
      Object.keys(init).forEach(function (k) {
        if (init[k] !== undefined && init[k] !== null) self._map[k.toLowerCase()] = String(init[k]);
      });
    }
  }
  NuvioHeaders.prototype.get = function (n) {
    var v = this._map[String(n).toLowerCase()];
    return v === undefined ? null : v;
  };
  NuvioHeaders.prototype.has = function (n) { return this._map[String(n).toLowerCase()] !== undefined; };
  NuvioHeaders.prototype.set = function (n, v) { this._map[String(n).toLowerCase()] = String(v); };
  NuvioHeaders.prototype.append = NuvioHeaders.prototype.set;
  NuvioHeaders.prototype['delete'] = function (n) { delete this._map[String(n).toLowerCase()]; };
  NuvioHeaders.prototype.forEach = function (fn) {
    var self = this;
    Object.keys(this._map).forEach(function (k) { fn(self._map[k], k, self); });
  };
  NuvioHeaders.prototype.keys = function () { return Object.keys(this._map); };
  NuvioHeaders.prototype.entries = function () {
    var self = this;
    return Object.keys(this._map).map(function (k) { return [k, self._map[k]]; });
  };
  NuvioHeaders.prototype.raw = function () {
    var out = {}, self = this;
    Object.keys(this._map).forEach(function (k) { out[k] = [self._map[k]]; });
    return out;
  };
  G.Headers = NuvioHeaders;

  function NuvioResponse(raw) {
    this.ok = !!raw.ok;
    this.status = raw.status || 0;
    this.statusText = raw.statusText || String(raw.status || '');
    this.url = raw.url || '';
    this.headers = new NuvioHeaders(raw.headers || {});
    this.redirected = !!raw.redirected;
    this.type = 'basic';
    this._body = raw.body == null ? '' : String(raw.body);
    this.bodyUsed = false;
  }
  NuvioResponse.prototype.text = function () { this.bodyUsed = true; return Promise.resolve(this._body); };
  NuvioResponse.prototype.json = function () {
    var body = this._body;
    this.bodyUsed = true;
    return new Promise(function (resolve, reject) {
      try { resolve(body === '' ? null : JSON.parse(body)); } catch (e) { reject(new Error('Invalid JSON response')); }
    });
  };
  NuvioResponse.prototype.arrayBuffer = function () {
    var body = this._body;
    this.bodyUsed = true;
    return Promise.resolve(utf8ToBytes(body).buffer);
  };
  NuvioResponse.prototype.blob = NuvioResponse.prototype.arrayBuffer;
  NuvioResponse.prototype.clone = function () {
    return new NuvioResponse({
      ok: this.ok, status: this.status, statusText: this.statusText,
      url: this.url, headers: this.headers._map, body: this._body
    });
  };
  G.Response = NuvioResponse;

  G.Request = function (input, init) {
    init = init || {};
    this.url = typeof input === 'string' ? input : (input && input.url);
    this.method = (init.method || 'GET').toUpperCase();
    this.headers = new NuvioHeaders(init.headers || {});
    this.body = init.body;
  };

  function doFetch(input, init) {
    init = init || {};
    var url = typeof input === 'string' ? input : (input && (input.url || input.href));
    if (input && typeof input === 'object' && input.headers && !init.headers) init = { headers: input.headers, method: input.method, body: input.body };
    var id = 'f' + (++G.__nuvio_seq);

    var headers = {};
    var rawHeaders = init.headers || {};
    if (rawHeaders && typeof rawHeaders.forEach === 'function' && !Array.isArray(rawHeaders)) {
      rawHeaders.forEach(function (value, key) { headers[key] = String(value); });
    } else if (Array.isArray(rawHeaders)) {
      rawHeaders.forEach(function (p) { if (p && p.length >= 2) headers[p[0]] = String(p[1]); });
    } else {
      Object.keys(rawHeaders).forEach(function (k) {
        if (rawHeaders[k] !== undefined && rawHeaders[k] !== null) headers[k] = String(rawHeaders[k]);
      });
    }

    var body = init.body;
    if (body && typeof body !== 'string') {
      if (body instanceof NuvioSearchParams) {
        body = body.toString();
        if (!headers['Content-Type'] && !headers['content-type']) {
          headers['Content-Type'] = 'application/x-www-form-urlencoded';
        }
      } else if (body instanceof Uint8Array || body instanceof ArrayBuffer) {
        body = bytesToUtf8(toU8(body));
      } else {
        try { body = JSON.stringify(body); } catch (e) { body = String(body); }
      }
    }

    var signal = init.signal;
    return new Promise(function (resolve, reject) {
      var settled = false;
      if (signal) {
        if (signal.aborted) {
          var e0 = signal.reason || new Error('The operation was aborted');
          if (!e0.name) e0.name = 'AbortError';
          reject(e0);
          return;
        }
        signal.addEventListener('abort', function () {
          if (settled) return;
          settled = true;
          delete G.__nuvio_pending[id];
          var err = signal.reason || new Error('The operation was aborted');
          if (!err.name) err.name = 'AbortError';
          reject(err);
        });
      }
      G.__nuvio_pending[id] = {
        resolve: function (payload) {
          if (settled) return;
          settled = true;
          resolve(new NuvioResponse(payload));
        },
        reject: function (err) {
          if (settled) return;
          settled = true;
          reject(err);
        }
      };
      sendMessage('nuvio_fetch', JSON.stringify({
        id: id,
        url: url,
        method: (init.method || 'GET').toUpperCase(),
        headers: headers,
        body: body === undefined ? null : body,
        follow: init.redirect !== 'manual'
      }));
    });
  }
  G.fetch = doFetch;

  // -------------------------------------------------------- XMLHttpRequest
  function NuvioXHR() {
    this.readyState = 0;
    this.status = 0;
    this.statusText = '';
    this.responseText = '';
    this.response = '';
    this.responseURL = '';
    this._headers = {};
    this._responseHeaders = '';
    this.timeout = 0;
    this.withCredentials = false;
  }
  NuvioXHR.prototype.open = function (method, url) {
    this._method = String(method || 'GET').toUpperCase();
    this._url = url;
    this.readyState = 1;
    if (typeof this.onreadystatechange === 'function') this.onreadystatechange();
  };
  NuvioXHR.prototype.setRequestHeader = function (k, v) { this._headers[k] = String(v); };
  NuvioXHR.prototype.getAllResponseHeaders = function () { return this._responseHeaders; };
  NuvioXHR.prototype.getResponseHeader = function (name) {
    return this._respHeaderMap ? (this._respHeaderMap[String(name).toLowerCase()] || null) : null;
  };
  NuvioXHR.prototype.abort = function () { this._aborted = true; };
  NuvioXHR.prototype.send = function (body) {
    var self = this;
    doFetch(this._url, { method: this._method, headers: this._headers, body: body }).then(function (res) {
      if (self._aborted) return;
      return res.text().then(function (text) {
        self.status = res.status;
        self.statusText = res.statusText;
        self.responseURL = res.url;
        self.responseText = text;
        self.response = self.responseType === 'json' ? (function () {
          try { return JSON.parse(text); } catch (e) { return null; }
        })() : text;
        self._respHeaderMap = res.headers._map;
        self._responseHeaders = res.headers.entries().map(function (p) { return p[0] + ': ' + p[1]; }).join('\r\n');
        self.readyState = 4;
        if (typeof self.onreadystatechange === 'function') self.onreadystatechange();
        if (typeof self.onload === 'function') self.onload();
        if (typeof self.onloadend === 'function') self.onloadend();
      });
    })['catch'](function (err) {
      if (self._aborted) return;
      self.readyState = 4;
      self.status = 0;
      if (typeof self.onreadystatechange === 'function') self.onreadystatechange();
      if (typeof self.onerror === 'function') self.onerror(err);
      if (typeof self.onloadend === 'function') self.onloadend();
    });
  };
  G.XMLHttpRequest = NuvioXHR;

  // ------------------------------------------------------------------ Buffer
  function NuvioBuffer() {}
  NuvioBuffer.from = function (value, encoding) {
    var bytes;
    if (typeof value === 'string') {
      encoding = String(encoding || 'utf8').toLowerCase();
      if (encoding === 'base64') {
        var bin = G.atob(value.replace(/-/g, '+').replace(/_/g, '/'));
        bytes = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i) & 0xff;
      } else if (encoding === 'hex') {
        bytes = hexToBytes(value);
      } else if (encoding === 'latin1' || encoding === 'binary' || encoding === 'ascii') {
        bytes = new Uint8Array(value.length);
        for (var j = 0; j < value.length; j++) bytes[j] = value.charCodeAt(j) & 0xff;
      } else {
        bytes = utf8ToBytes(value);
      }
    } else {
      bytes = toU8(value);
    }
    return decorateBuffer(bytes);
  };
  NuvioBuffer.alloc = function (n) { return decorateBuffer(new Uint8Array(n || 0)); };
  NuvioBuffer.concat = function (list) {
    var total = 0, parts = [];
    (list || []).forEach(function (p) { var b = toU8(p); parts.push(b); total += b.length; });
    var out = new Uint8Array(total), off = 0;
    parts.forEach(function (p) { out.set(p, off); off += p.length; });
    return decorateBuffer(out);
  };
  NuvioBuffer.isBuffer = function (b) { return b instanceof Uint8Array; };
  NuvioBuffer.byteLength = function (s, enc) { return NuvioBuffer.from(s, enc).length; };
  function decorateBuffer(bytes) {
    bytes.toString = function (encoding) {
      encoding = String(encoding || 'utf8').toLowerCase();
      if (encoding === 'hex') return bytesToHex(this);
      if (encoding === 'base64') {
        var s = '';
        for (var i = 0; i < this.length; i++) s += String.fromCharCode(this[i]);
        return G.btoa(s);
      }
      if (encoding === 'latin1' || encoding === 'binary' || encoding === 'ascii') {
        var o = '';
        for (var j = 0; j < this.length; j++) o += String.fromCharCode(this[j]);
        return o;
      }
      return bytesToUtf8(this);
    };
    return bytes;
  }
  G.Buffer = NuvioBuffer;

  // ------------------------------------------------------------ localStorage
  var storage = {};
  G.localStorage = {
    getItem: function (k) { return storage[k] === undefined ? null : storage[k]; },
    setItem: function (k, v) { storage[k] = String(v); },
    removeItem: function (k) { delete storage[k]; },
    clear: function () { storage = {}; },
    key: function (i) { return Object.keys(storage)[i] || null; }
  };
  Object.defineProperty(G.localStorage, 'length', { get: function () { return Object.keys(storage).length; } });
  G.sessionStorage = G.localStorage;

  // ---------------------------------------------------------------- cheerio
  function domCall(channel, payload) { return bridge(channel, payload); }
  function Selection(docId, nodeIds) {
    this._doc = docId;
    this._nodes = nodeIds || [];
    this.length = this._nodes.length;
    this.cheerio = '[cheerio object]';
    for (var i = 0; i < this._nodes.length; i++) {
      this[i] = { __nuvioNode: this._nodes[i], __nuvioDoc: docId };
    }
  }
  function idsOf(input, docId) {
    if (input == null) return [];
    if (input instanceof Selection) return input._nodes.slice();
    if (typeof input === 'object' && input.__nuvioNode) return [input.__nuvioNode];
    if (Array.isArray(input)) {
      var out = [];
      input.forEach(function (n) {
        if (n && n.__nuvioNode) out.push(n.__nuvioNode);
        else if (typeof n === 'string') out.push(n);
      });
      return out;
    }
    if (typeof input === 'string') {
      return JSON.parse(domCall('nuvio_dom_query', { doc: docId, context: null, selector: input }));
    }
    return [];
  }
  Selection.prototype.get = function (index) {
    var self = this;
    if (index === undefined) {
      return this._nodes.map(function (id) { return { __nuvioNode: id, __nuvioDoc: self._doc }; });
    }
    if (index < 0) index += this._nodes.length;
    var id = this._nodes[index];
    return id === undefined ? undefined : { __nuvioNode: id, __nuvioDoc: this._doc };
  };
  Selection.prototype.toArray = function () { return this.get(); };
  Selection.prototype.eq = function (i) {
    if (i < 0) i += this._nodes.length;
    var id = this._nodes[i];
    return new Selection(this._doc, id === undefined ? [] : [id]);
  };
  Selection.prototype.first = function () { return this.eq(0); };
  Selection.prototype.last = function () { return this.eq(this._nodes.length - 1); };
  Selection.prototype.each = function (fn) {
    for (var i = 0; i < this._nodes.length; i++) {
      var el = { __nuvioNode: this._nodes[i], __nuvioDoc: this._doc };
      if (fn.call(el, i, el) === false) break;
    }
    return this;
  };
  Selection.prototype.map = function (fn) {
    var out = [];
    for (var i = 0; i < this._nodes.length; i++) {
      var el = { __nuvioNode: this._nodes[i], __nuvioDoc: this._doc };
      var r = fn.call(el, i, el);
      if (r !== undefined && r !== null) out.push(r);
    }
    var wrapped = new Selection(this._doc, []);
    wrapped.length = out.length;
    wrapped.get = function (i) { return i === undefined ? out : out[i]; };
    wrapped.toArray = function () { return out; };
    return wrapped;
  };
  Selection.prototype.filter = function (test) {
    if (typeof test === 'function') {
      var keep = [];
      for (var i = 0; i < this._nodes.length; i++) {
        var el = { __nuvioNode: this._nodes[i], __nuvioDoc: this._doc };
        if (test.call(el, i, el)) keep.push(this._nodes[i]);
      }
      return new Selection(this._doc, keep);
    }
    var matched = JSON.parse(domCall('nuvio_dom_filter', {
      doc: this._doc, nodes: this._nodes, selector: String(test)
    }));
    return new Selection(this._doc, matched);
  };
  Selection.prototype.not = function (selector) {
    var matched = JSON.parse(domCall('nuvio_dom_filter', {
      doc: this._doc, nodes: this._nodes, selector: String(selector)
    }));
    return new Selection(this._doc, this._nodes.filter(function (id) { return matched.indexOf(id) < 0; }));
  };
  Selection.prototype.is = function (selector) {
    if (typeof selector === 'function') return this.filter(selector).length > 0;
    return this.filter(selector).length > 0;
  };
  Selection.prototype.find = function (selector) {
    var all = [];
    for (var i = 0; i < this._nodes.length; i++) {
      all = all.concat(JSON.parse(domCall('nuvio_dom_query', {
        doc: this._doc, context: this._nodes[i], selector: selector
      })));
    }
    return new Selection(this._doc, all);
  };
  function relation(kind) {
    return function (selector) {
      var ids = JSON.parse(domCall('nuvio_dom_relation', {
        doc: this._doc, nodes: this._nodes, kind: kind, selector: selector || null
      }));
      return new Selection(this._doc, ids);
    };
  }
  Selection.prototype.parent = relation('parent');
  Selection.prototype.parents = relation('parents');
  Selection.prototype.closest = relation('closest');
  Selection.prototype.children = relation('children');
  Selection.prototype.next = relation('next');
  Selection.prototype.nextAll = relation('nextAll');
  Selection.prototype.prev = relation('prev');
  Selection.prototype.prevAll = relation('prevAll');
  Selection.prototype.siblings = relation('siblings');
  Selection.prototype.contents = relation('children');
  Selection.prototype.attr = function (name, value) {
    if (value !== undefined) return this;
    if (!this._nodes.length) return undefined;
    if (name === undefined) {
      var described = JSON.parse(domCall('nuvio_dom_describe', { doc: this._doc, nodes: [this._nodes[0]] }));
      return described.length ? described[0].attrs : {};
    }
    var v = domCall('nuvio_dom_attr', { doc: this._doc, node: this._nodes[0], name: name });
    return (v === '' || v === null || v === '__NUVIO_NONE__') ? undefined : v;
  };
  Selection.prototype.prop = function (name) {
    if (String(name).toLowerCase() === 'tagname') {
      var d = JSON.parse(domCall('nuvio_dom_describe', { doc: this._doc, nodes: this._nodes.slice(0, 1) }));
      return d.length ? String(d[0].tag || '').toUpperCase() : undefined;
    }
    return this.attr(name);
  };
  Selection.prototype.data = function (name) {
    if (name === undefined) {
      var all = this.attr();
      var out = {};
      Object.keys(all || {}).forEach(function (k) {
        if (k.indexOf('data-') === 0) out[k.substring(5)] = all[k];
      });
      return out;
    }
    return this.attr('data-' + name);
  };
  Selection.prototype.val = function () { return this.attr('value'); };
  Selection.prototype.hasClass = function (name) {
    var cls = this.attr('class');
    if (!cls) return false;
    return (' ' + cls + ' ').indexOf(' ' + name + ' ') >= 0;
  };
  Selection.prototype.text = function () {
    if (!this._nodes.length) return '';
    return domCall('nuvio_dom_text', { doc: this._doc, nodes: this._nodes });
  };
  Selection.prototype.html = function () {
    if (!this._nodes.length) return null;
    return domCall('nuvio_dom_html', { doc: this._doc, node: this._nodes[0] });
  };
  Selection.prototype.add = function (other) {
    return new Selection(this._doc, this._nodes.concat(idsOf(other, this._doc)));
  };
  Selection.prototype.slice = function (a, b) { return new Selection(this._doc, this._nodes.slice(a, b)); };
  Selection.prototype.remove = function () { return this; };
  Selection.prototype.index = function () {
    var ids = JSON.parse(domCall('nuvio_dom_relation', {
      doc: this._doc, nodes: this._nodes.slice(0, 1), kind: 'index', selector: null
    }));
    return ids.length ? Number(ids[0]) : -1;
  };

  var cheerio = {
    load: function (html) {
      var docId = domCall('nuvio_dom_load', { html: String(html == null ? '' : html) });
      var api = function (input, context) {
        if (input instanceof Selection) return input;
        if (context) {
          var ctxIds = idsOf(context, docId);
          var found = [];
          for (var i = 0; i < ctxIds.length; i++) {
            found = found.concat(JSON.parse(domCall('nuvio_dom_query', {
              doc: docId, context: ctxIds[i], selector: String(input)
            })));
          }
          return new Selection(docId, found);
        }
        return new Selection(docId, idsOf(input, docId));
      };
      api.html = function (el) {
        if (el && (el.__nuvioNode || el instanceof Selection)) {
          var id = el instanceof Selection ? el._nodes[0] : el.__nuvioNode;
          return id ? domCall('nuvio_dom_html', { doc: docId, node: id }) : '';
        }
        return domCall('nuvio_dom_html', { doc: docId, node: '' });
      };
      api.text = function (el) {
        var ids = el ? idsOf(el, docId) : [];
        return domCall('nuvio_dom_text', { doc: docId, nodes: ids });
      };
      api.root = function () { return new Selection(docId, idsOf('html', docId)); };
      api.__docId = docId;
      return api;
    }
  };
  G.cheerio = cheerio;

  // ---------------------------------------------------------------- require
  var moduleStubs = {};
  G.require = function (name) {
    var id = String(name || '').replace(/^node:/, '');
    if (id.indexOf('cheerio') >= 0) {
      return { load: cheerio.load, 'default': cheerio, __esModule: true };
    }
    if (id === 'crypto-js') return CryptoJS;
    if (id === 'crypto') {
      return {
        randomUUID: G.crypto.randomUUID,
        getRandomValues: G.crypto.getRandomValues,
        randomBytes: function (n) { return NuvioBuffer.from(randomBytes(n)); },
        webcrypto: G.crypto,
        createHash: function (alg) {
          var chunks = [];
          return {
            update: function (d) { chunks.push(toU8(typeof d === 'string' ? utf8ToBytes(d) : d)); return this; },
            digest: function (enc) {
              var total = 0;
              chunks.forEach(function (c) { total += c.length; });
              var all = new Uint8Array(total), off = 0;
              chunks.forEach(function (c) { all.set(c, off); off += c.length; });
              var out = digestBytes(normalizeHash(alg), all);
              return enc === 'hex' ? bytesToHex(out) : NuvioBuffer.from(out);
            }
          };
        }
      };
    }
    if (id === 'url') return { URL: G.URL, URLSearchParams: G.URLSearchParams, parse: function (u) { return new G.URL(u); } };
    if (id === 'querystring') {
      return {
        stringify: function (o) { return new NuvioSearchParams(o).toString(); },
        parse: function (s) {
          var p = new NuvioSearchParams(s), out = {};
          p.forEach(function (v, k) { out[k] = v; });
          return out;
        }
      };
    }
    if (id === 'buffer') return { Buffer: NuvioBuffer };
    if (id === 'events') {
      var EventEmitter = function () { this._e = {}; };
      EventEmitter.prototype.on = function (n, f) { (this._e[n] = this._e[n] || []).push(f); return this; };
      EventEmitter.prototype.once = EventEmitter.prototype.on;
      EventEmitter.prototype.off = function (n, f) {
        this._e[n] = (this._e[n] || []).filter(function (x) { return x !== f; });
        return this;
      };
      EventEmitter.prototype.emit = function (n) {
        var args = Array.prototype.slice.call(arguments, 1);
        (this._e[n] || []).forEach(function (f) { f.apply(null, args); });
        return true;
      };
      return { EventEmitter: EventEmitter, 'default': EventEmitter };
    }
    if (id === 'util') {
      return {
        inspect: function (o) { try { return JSON.stringify(o); } catch (e) { return String(o); } },
        promisify: function (fn) {
          return function () {
            var args = Array.prototype.slice.call(arguments);
            return new Promise(function (resolve, reject) {
              args.push(function (err, val) { err ? reject(err) : resolve(val); });
              fn.apply(null, args);
            });
          };
        },
        types: { isUint8Array: function (v) { return v instanceof Uint8Array; } },
        TextEncoder: G.TextEncoder,
        TextDecoder: G.TextDecoder
      };
    }
    if (id === 'timers') return { setTimeout: G.setTimeout, setInterval: G.setInterval, clearTimeout: G.clearTimeout };
    if (id === 'assert') {
      var assert = function (v, m) { if (!v) throw new Error(m || 'assertion failed'); };
      assert.ok = assert;
      assert.equal = function (a, b, m) { if (a != b) throw new Error(m || 'not equal'); };
      assert.strictEqual = function (a, b, m) { if (a !== b) throw new Error(m || 'not strict equal'); };
      assert.deepStrictEqual = function () {};
      assert.fail = function (m) { throw new Error(m || 'failed'); };
      return assert;
    }
    if (moduleStubs[id]) return moduleStubs[id];
    throw new Error("Module '" + id + "' is not available in SkyStream");
  };
  G.require.resolve = function (n) { return n; };

  // ------------------------------------------------------ language polyfills
  if (!Array.prototype.flat) {
    Array.prototype.flat = function (depth) {
      depth = depth === undefined ? 1 : Math.floor(depth);
      if (depth < 1) return Array.prototype.slice.call(this);
      return (function flatten(arr, d) {
        return d > 0
          ? arr.reduce(function (acc, v) { return acc.concat(Array.isArray(v) ? flatten(v, d - 1) : v); }, [])
          : arr.slice();
      })(this, depth);
    };
  }
  if (!Array.prototype.flatMap) {
    Array.prototype.flatMap = function (cb, t) { return this.map(cb, t).flat(); };
  }
  if (!Array.prototype.at) {
    Array.prototype.at = function (i) { i = Math.trunc(i) || 0; if (i < 0) i += this.length; return this[i]; };
  }
  if (!String.prototype.at) {
    String.prototype.at = function (i) { i = Math.trunc(i) || 0; if (i < 0) i += this.length; return this[i]; };
  }
  if (!Object.entries) {
    Object.entries = function (o) {
      return Object.keys(o).map(function (k) { return [k, o[k]]; });
    };
  }
  if (!Object.fromEntries) {
    Object.fromEntries = function (entries) {
      var out = {};
      (entries || []).forEach(function (e) { out[e[0]] = e[1]; });
      return out;
    };
  }
  if (!Object.values) {
    Object.values = function (o) { return Object.keys(o).map(function (k) { return o[k]; }); };
  }
  if (!String.prototype.replaceAll) {
    String.prototype.replaceAll = function (search, replace) {
      if (search instanceof RegExp) {
        if (!search.global) throw new TypeError('replaceAll needs a global RegExp');
        return this.replace(search, replace);
      }
      return this.split(search).join(replace);
    };
  }
  if (!Promise.allSettled) {
    Promise.allSettled = function (promises) {
      return Promise.all(Array.prototype.map.call(promises, function (p) {
        return Promise.resolve(p).then(
          function (value) { return { status: 'fulfilled', value: value }; },
          function (reason) { return { status: 'rejected', reason: reason }; }
        );
      }));
    };
  }
  if (!Promise.any) {
    Promise.any = function (promises) {
      return new Promise(function (resolve, reject) {
        var errors = [], pending = 0, done = false;
        Array.prototype.forEach.call(promises, function (p) {
          pending++;
          Promise.resolve(p).then(function (v) { done = true; resolve(v); }, function (e) {
            errors.push(e);
            if (--pending === 0 && !done) reject(new Error('All promises were rejected'));
          });
        });
        if (pending === 0) reject(new Error('All promises were rejected'));
      });
    };
  }
})();
''';
// <<<NUVIO_POLYFILL_END
