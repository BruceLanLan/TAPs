#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Reference checker for TAP-11 §3: the manifest format, including the text
// rules of §3.4 and §3.5 and the parameter schema of §3.6. It reads no chain
// state and checks no signature: binding (§2.2 step 5), delegation (§4) and
// content signature (§5) are out of scope here.
//
// Usage:  node manifest-text.mjs                    run manifest-text.json
//         node manifest-text.mjs <file> [...]       check manifest files
// Needs:  Node 18 or later, no dependencies. Unicode properties and NFC come
//         from unicode-15.1.json in this directory (the tables of TAP-11 §3.5,
//         Unicode 15.1.0), never from the engine's own Unicode library.
// Exit:   1 if a vector fails or a file is not a valid manifest.

import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export class Invalid extends Error {
  constructor(reason, detail) { super(`${reason}: ${detail}`); this.reason = reason; this.detail = detail; }
}
const fail = (reason, detail) => { throw new Invalid(reason, detail); };

// ---------------------------------------------------------------- keccak256 (EIP-55 only)
const RC = [0x1n, 0x8082n, 0x800000000000808an, 0x8000000080008000n, 0x808bn, 0x80000001n, 0x8000000080008081n,
  0x8000000000008009n, 0x8an, 0x88n, 0x80008009n, 0x8000000an, 0x8000808bn, 0x800000000000008bn, 0x8000000000008089n,
  0x8000000000008003n, 0x8000000000008002n, 0x8000000000000080n, 0x800an, 0x800000008000000an, 0x8000000080008081n,
  0x8000000000008080n, 0x80000001n, 0x8000000080008008n];
const ROT = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14];
const M64 = (1n << 64n) - 1n;
const rotl = (x, n) => (n === 0 ? x : ((x << BigInt(n)) | (x >> BigInt(64 - n))) & M64);
function keccak256(bytes) {
  const rate = 136, s = new Array(25).fill(0n);
  const p = new Uint8Array(Math.ceil((bytes.length + 1) / rate) * rate); p.set(bytes); p[bytes.length] ^= 1; p[p.length - 1] ^= 0x80;
  for (let off = 0; off < p.length; off += rate) {
    for (let i = 0; i < rate / 8; i++) { let v = 0n; for (let b = 7; b >= 0; b--) v = (v << 8n) | BigInt(p[off + i * 8 + b]); s[i] ^= v; }
    for (let r = 0; r < 24; r++) {
      const C = [0, 1, 2, 3, 4].map((x) => s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20]);
      for (let x = 0; x < 5; x++) { const d = C[(x + 4) % 5] ^ rotl(C[(x + 1) % 5], 1); for (let y = 0; y < 25; y += 5) s[x + y] ^= d; }
      const B = new Array(25);
      for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) B[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(s[x + 5 * y], ROT[x + 5 * y]);
      for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) s[x + 5 * y] = B[x + 5 * y] ^ (~B[(x + 1) % 5 + 5 * y] & M64 & B[(x + 2) % 5 + 5 * y]);
      s[0] ^= RC[r];
    }
  }
  const out = []; for (let i = 0; i < 4; i++) for (let b = 0; b < 8; b++) out.push(Number((s[i] >> BigInt(8 * b)) & 0xffn));
  return Buffer.from(out).toString('hex');
}

// ---------------------------------------------------------------- strict JSON (§3.1)
const PROTO = new Set(['__proto__', 'constructor', 'prototype']);
const MAX_DEPTH = 32;
// With `lexemes`, a JSON number is returned as a JsonNumber that keeps its text, so
// that §3.6 can judge the lexical form (`1.0` and `1e0` are not uint53 although
// they have the value 1). Manifests are parsed without it.
export class JsonNumber { constructor(lexeme) { this.lexeme = lexeme; } }
function parseStrict(text, lexemes = false) {
  let i = 0, depth = 0;
  const ws = () => { while (i < text.length && ' \t\n\r'.includes(text[i])) i++; };
  const err = (m) => fail('syntax', `${m} at offset ${i}`);
  function str() {
    if (text[i] !== '"') err('expected string'); i++; let out = '';
    for (;;) {
      if (i >= text.length) err('unterminated string');
      const c = text[i++];
      if (c === '"') return out;
      if (c < ' ') err('control character in string');
      if (c !== '\\') { out += c; continue; }
      const e = text[i++];
      const map = { '"': '"', '\\': '\\', '/': '/', b: '\b', f: '\f', n: '\n', r: '\r', t: '\t' };
      if (e in map) out += map[e];
      else if (e === 'u') { const h = text.slice(i, i + 4); if (!/^[0-9a-fA-F]{4}$/.test(h)) err('bad \\u escape'); out += String.fromCharCode(parseInt(h, 16)); i += 4; }
      else err('bad escape');
    }
  }
  function val() {
    ws(); const c = text[i];
    if ((c === '{' || c === '[') && ++depth > MAX_DEPTH) fail('limit-exceeded', `nesting depth > ${MAX_DEPTH}`);
    if (c === '{') {
      i++; const o = Object.create(null); ws();
      if (text[i] === '}') { i++; depth--; return o; }
      for (;;) {
        ws(); const k = str();
        if (PROTO.has(k)) fail('syntax', `member named ${k}`);
        if (Object.prototype.hasOwnProperty.call(o, k)) fail('syntax', `repeated member ${JSON.stringify(k)}`);
        ws(); if (text[i++] !== ':') err('expected :');
        o[k] = val(); ws();
        if (text[i] === ',') { i++; continue; } if (text[i] === '}') { i++; depth--; return o; } err('expected , or }');
      }
    }
    if (c === '[') {
      i++; const a = []; ws();
      if (text[i] === ']') { i++; depth--; return a; }
      for (;;) { a.push(val()); ws(); if (text[i] === ',') { i++; continue; } if (text[i] === ']') { i++; depth--; return a; } err('expected , or ]'); }
    }
    if (c === '"') return str();
    const m = /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/.exec(text.slice(i));
    if (m && m[0] !== '' && m[0] !== '-') { i += m[0].length; return lexemes ? new JsonNumber(m[0]) : Number(m[0]); }
    for (const [w, v] of [['true', true], ['false', false], ['null', null]]) if (text.startsWith(w, i)) { i += w.length; return v; }
    err('unexpected token');
  }
  const v = val(); ws(); if (i !== text.length) err('trailing text');
  return v;
}
export function parseJson(text) { return parseStrict(text, true); }
function decode(bytes) {
  if (bytes.length > 65536) fail('too-large', `${bytes.length} bytes`);
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) fail('syntax', 'byte order mark');
  let text;
  try { text = new TextDecoder('utf-8', { fatal: true }).decode(bytes); } catch { fail('syntax', 'not valid UTF-8'); }
  const v = parseStrict(text);
  if (v === null || typeof v !== 'object' || Array.isArray(v)) fail('syntax', 'top-level value is not an object');
  return v;
}

// ---------------------------------------------------------------- §3.5 text rules
// The tables of unicode-15.1.json are normative (§3.5); the digest below is the
// one the specification states. The engine's own Unicode library is not used.
const TABLES_SHA256 = 'a5fc0644d85d4638999ab5bb2d09f50514cfe10e7db6b4134638682a7c9fc4fd';
const tableBytes = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'unicode-15.1.json'));
if (createHash('sha256').update(tableBytes).digest('hex') !== TABLES_SHA256) throw new Error('unicode-15.1.json does not match the digest stated in TAP-11 §3.5');
const T = JSON.parse(tableBytes.toString('utf8'));
const ranges = (list) => list.map((r) => { const [lo, hi] = r.split('-'); return [parseInt(lo, 16), parseInt(hi ?? lo, 16)]; });
const inRanges = (rs, c) => { let lo = 0, hi = rs.length - 1; while (lo <= hi) { const m = (lo + hi) >> 1; if (c < rs[m][0]) hi = m - 1; else if (c > rs[m][1]) lo = m + 1; else return true; } return false; };
const prop = Object.fromEntries(['Cc', 'Cf', 'Default_Ignorable_Code_Point', 'Bidi_Control', 'Emoji', 'Full_Composition_Exclusion'].map((k) => [k, ranges(T[k])]));
const cccOf = new Map(); for (const [v, list] of Object.entries(T.ccc)) for (const [lo, hi] of ranges(list)) for (let c = lo; c <= hi; c++) cccOf.set(c, Number(v));
const ccc = (c) => cccOf.get(c) ?? 0;
const DECOMP = new Map(Object.entries(T.decomposition).map(([k, v]) => [parseInt(k, 16), v.split(' ').map((x) => parseInt(x, 16))]));
const COMPOSE = new Map();
for (const [c, d] of DECOMP) if (d.length === 2 && !inRanges(prop.Full_Composition_Exclusion, c)) COMPOSE.set(d[0] * 0x110000 + d[1], c);

// UAX #15 normalization form C over the tables above (Hangul by algorithm).
const [SB, LB, VB, TB, LC, VC, TC] = [0xac00, 0x1100, 0x1161, 0x11a7, 19, 21, 28];
function decompose(c, out) {
  if (c >= SB && c < SB + LC * VC * TC) { const n = c - SB; out.push(LB + Math.floor(n / (VC * TC)), VB + Math.floor((n % (VC * TC)) / TC)); if (n % TC) out.push(TB + (n % TC)); return; }
  const d = DECOMP.get(c); if (!d) { out.push(c); return; }
  for (const x of d) decompose(x, out);
}
function composePair(a, b) {
  if (a >= LB && a < LB + LC && b >= VB && b < VB + VC) return SB + ((a - LB) * VC + (b - VB)) * TC;
  if (a >= SB && a < SB + LC * VC * TC && (a - SB) % TC === 0 && b > TB && b < TB + TC) return a + (b - TB);
  return COMPOSE.get(a * 0x110000 + b);
}
export function nfc(str) {
  const d = []; for (const ch of str) decompose(ch.codePointAt(0), d);
  for (let i = 1; i < d.length; i++) { // canonical ordering: stable insertion sort of runs with ccc > 0
    const c = ccc(d[i]); if (c === 0) continue;
    let j = i; while (j > 0 && ccc(d[j - 1]) > c) { [d[j - 1], d[j]] = [d[j], d[j - 1]]; j--; }
  }
  if (d.length === 0) return '';
  let sp = 0, sc = d[0], last = ccc(sc) === 0 ? 0 : 256, n = 1;
  for (let i = 1; i < d.length; i++) {
    const ch = d[i], cl = ccc(ch), comp = composePair(sc, ch);
    if (comp !== undefined && (last < cl || last === 0)) { d[sp] = comp; sc = comp; }
    else { if (cl === 0) { sp = n; sc = ch; } last = cl; d[n++] = ch; }
  }
  let out = ''; for (let i = 0; i < n; i++) out += String.fromCodePoint(d[i]);
  return out;
}

const isVS = (c) => (c >= 0xfe00 && c <= 0xfe0f) || (c >= 0xe0100 && c <= 0xe01ef);
const cpName = (c) => 'U+' + c.toString(16).toUpperCase().padStart(4, '0');

// Checks one decoded string (a value or a member name). `allowLfTab`: the value
// of the `description` member of a method descriptor, where U+000A and U+0009
// are allowed (§3.5 item 1, clause (a)).
function checkString(s, where, allowLfTab) {
  for (let k = 0; k < s.length; k++) {
    const u = s.charCodeAt(k);
    if (u >= 0xd800 && u <= 0xdbff && k + 1 < s.length && s.charCodeAt(k + 1) >= 0xdc00 && s.charCodeAt(k + 1) <= 0xdfff) { k++; continue; }
    if (u >= 0xd800 && u <= 0xdfff) fail('unpaired-surrogate', `${where}: U+${u.toString(16).toUpperCase()}`);
  }
  const cps = [...s].map((ch) => ch.codePointAt(0));
  cps.forEach((c, k) => {
    if (inRanges(prop.Bidi_Control, c)) fail('bidi-control', `${where}: ${cpName(c)} at code point ${k}`);
    if (allowLfTab && (c === 0x0a || c === 0x09)) return;
    if (isVS(c)) {
      const prev = cps[k - 1];
      if ((c === 0xfe0e || c === 0xfe0f) && prev !== undefined && inRanges(prop.Emoji, prev) && !isVS(prev)) return;
      fail('hidden-text', `${where}: ${cpName(c)} at code point ${k}`);
    }
    if (inRanges(prop.Cf, c) || inRanges(prop.Cc, c) || inRanges(prop.Default_Ignorable_Code_Point, c) || c === 0x2028 || c === 0x2029 || c === 0x2800 || c === 0x1d159) fail('hidden-text', `${where}: ${cpName(c)} at code point ${k}`);
  });
  if (nfc(s) !== s) fail('not-nfc', where);
}
// §3.5 item 1 applies to every string and member name at every depth, known or not.
// U+000A and U+0009 are allowed only in methods[n].description.
function walkText(v, where, path) {
  if (typeof v === 'string') return checkString(v, where, path.length === 3 && path[0] === 'methods' && typeof path[1] === 'number' && path[2] === 'description');
  if (Array.isArray(v)) return v.forEach((x, k) => walkText(x, `${where}[${k}]`, [...path, k]));
  if (v && typeof v === 'object') for (const k of Object.keys(v)) { checkString(k, `${where} member name ${JSON.stringify(k)}`, false); walkText(v[k], `${where}.${k}`, [...path, k]); }
}
const bytesOf = (s) => Buffer.byteLength(s, 'utf8');
const cps = (s) => [...s].length;
const ASCII = /^[\x20-\x7e]*$/;
function limit(s, where, maxCp, maxBytes) {
  if (maxCp !== undefined && cps(s) > maxCp) fail('limit-exceeded', `${where}: ${cps(s)} code points > ${maxCp}`);
  if (bytesOf(s) > maxBytes) fail('limit-exceeded', `${where}: ${bytesOf(s)} bytes > ${maxBytes}`);
}

// ---------------------------------------------------------------- §3.2, §3.3, §3.6
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
function isAddress(s) {
  if (typeof s !== 'string' || !ADDRESS.test(s)) return false;
  const h = s.slice(2); if (h === h.toLowerCase()) return true;
  const d = keccak256(Buffer.from(h.toLowerCase(), 'ascii'));
  for (let k = 0; k < 40; k++) { const c = h[k]; if (/[a-f]/.test(c) && parseInt(d[k], 16) >= 8) return false; if (/[A-F]/.test(c) && parseInt(d[k], 16) < 8) return false; }
  return true;
}
const MEMBER = /^[A-Za-z_][A-Za-z0-9_]{0,63}$/;
const TOKEN = /^[a-z0-9][a-z0-9-]{0,31}$/;
export const TYPES = {
  string: (v) => typeof v === 'string',
  boolean: (v) => typeof v === 'boolean',
  // §3.6: the JSON text is `0` or a nonzero digit followed by digits, with a value of at most 2^53 - 1.
  // A JsonNumber carries its text; a plain JS number has lost it, and is accepted only
  // when it is an integer in range that is not -0 (its JSON text is then of that form).
  uint53: (v) => v instanceof JsonNumber
    ? /^(0|[1-9][0-9]*)$/.test(v.lexeme) && BigInt(v.lexeme) <= 9007199254740991n
    : typeof v === 'number' && Number.isSafeInteger(v) && v >= 0 && !Object.is(v, -0),
  'uint256-dec': (v) => typeof v === 'string' && /^(0|[1-9][0-9]{0,77})$/.test(v) && BigInt(v) < 1n << 256n,
  address: (v) => isAddress(v),
  'bytes32-hex': (v) => typeof v === 'string' && /^0x[0-9a-f]{64}$/.test(v),
  'bytes32-bare': (v) => typeof v === 'string' && /^[0-9a-f]{64}$/.test(v),
  'bytes-hex': (v) => typeof v === 'string' && /^0x([0-9a-f]{2})*$/.test(v),
  base64: (v) => typeof v === 'string' && /^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(v),
};
const bad = (where, d) => fail('format', `${where}: ${d}`);

function checkInputs(inputs, params, where) {
  const ii = (d) => fail('inputs-invalid', `${where}: ${d}`);
  if (!isObj(inputs)) ii('not an object');
  const a = Object.keys(inputs).sort(), b = Object.keys(params).sort();
  if (a.length !== b.length || a.some((k, n) => k !== b[n])) ii('member names differ from params');
  for (const [k, spec] of Object.entries(inputs)) {
    if (!isObj(spec)) ii(`${k} is not an object`);
    const t = Array.isArray(spec.type) ? spec.type : [spec.type];
    if (t.length < 1 || t.length > 4 || t.some((x) => typeof x !== 'string' || !TOKEN.test(x)) || new Set(t).size !== t.length) ii(`${k}.type`);
    if ('optional' in spec && typeof spec.optional !== 'boolean') ii(`${k}.optional`);
    if ('enum' in spec) {
      const e = spec.enum;
      if (!t.includes('string') || !Array.isArray(e) || e.length < 1 || e.length > 32 || e.some((x) => typeof x !== 'string' || bytesOf(x) > 64) || new Set(e).size !== e.length) ii(`${k}.enum`);
    }
  }
}

// §3.2 `endpoints.live`: the grammar of a URL, then the WHATWG round trip. `u` is already
// printable ASCII without spaces. Reason `bad-url`.
const LABEL = '[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?';
const URL_RE = new RegExp(`^https://((?:${LABEL}\\.)*[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?)(?::([1-9][0-9]{0,4}))?(/(?:[A-Za-z0-9._~!$&'()*+,;=:@/-]|%[0-9A-F]{2})*)?$`);
export function checkUrl(u, w) {
  const bu = (d) => fail('bad-url', `${w}: ${d}`);
  const m = URL_RE.exec(u);
  if (!m) bu('not of the form https://host[:port][/path] with a lowercase domain-name host, no user name, no query or fragment, and a host whose last label starts with a letter');
  if (m[1].length > 253) bu('host longer than 253 bytes');
  if (m[2] !== undefined && (Number(m[2]) > 65535 || m[2] === '443')) bu('port above 65535 or the default port 443');
  if ((m[3] ?? '/').split('/').some((seg) => /^(\.|%2e)(\.|%2e)?$/i.test(seg))) bu('a "." or ".." path segment');
  let p; try { p = new URL(u); } catch { bu('not a URL'); }
  if (p.href !== (m[3] === undefined ? u + '/' : u)) bu(`WHATWG serialization differs: ${p.href}`);
}

export function validateManifest(bytes) {
  const m = decode(bytes);
  walkText(m, '$', []);
  const str = (v, w) => { if (typeof v !== 'string') bad(w, 'not a string'); return v; };
  if (!/^0\.[1-9][0-9]*$/.test(str(m.tapeapi, 'tapeapi'))) bad('tapeapi', 'bad version');
  if ('name' in m) limit(str(m.name, 'name'), 'name', 64, 256);
  for (const k of ['circuits', 'container', 'signer']) if (!isAddress(m[k])) bad(k, 'not an address');
  if (typeof m.tokenId !== 'string' || !/^(0|[1-9][0-9]*)$/.test(m.tokenId)) bad('tokenId', 'not decimal');
  const d = m.delegation;
  if (!isObj(d) || !Number.isSafeInteger(d.expires) || d.expires <= 0) bad('delegation.expires', 'not a positive integer');
  if (typeof d.sig !== 'string' || !/^0x([0-9a-fA-F]{2}){65,1024}$/.test(d.sig)) bad('delegation.sig', 'bad signature form');
  const e = m.endpoints;
  if (!isObj(e) || !Array.isArray(e.live) || typeof e.async !== 'boolean') bad('endpoints', 'bad shape');
  if (e.live.length > 16) fail('limit-exceeded', `endpoints.live: ${e.live.length} > 16`);
  e.live.forEach((u, n) => {
    const w = `endpoints.live[${n}]`; str(u, w);
    if (!ASCII.test(u) || u.includes(' ')) fail('not-ascii', `${w}: not printable ASCII without spaces`);
    limit(u, w, undefined, 512);
    checkUrl(u, w);
  });
  if (e.live.length === 0 && e.async !== true) bad('endpoints', 'no live endpoint and not async');
  if (!Array.isArray(m.methods) || m.methods.length === 0) bad('methods', 'empty or not an array');
  if (m.methods.length > 64) fail('limit-exceeded', `methods: ${m.methods.length} > 64`);
  const names = new Set(); let paid = false;
  m.methods.forEach((x, n) => {
    const w = `methods[${n}]`;
    if (!isObj(x)) bad(w, 'not an object');
    if (typeof x.name !== 'string' || !MEMBER.test(x.name) || PROTO.has(x.name)) bad(`${w}.name`, 'bad method name');
    if (names.has(x.name)) bad(`${w}.name`, 'repeated method name'); names.add(x.name);
    if (typeof x.priceBEM !== 'string' || !/^[0-9]+(\.[0-9]{1,8})?$/.test(x.priceBEM)) bad(`${w}.priceBEM`, 'bad amount');
    if (x.priceBEM !== '0') paid = true;
    for (const part of ['params', 'returns']) {
      const o = x[part];
      if (!isObj(o)) bad(`${w}.${part}`, 'not an object');
      if (Object.keys(o).length > 32) fail('limit-exceeded', `${w}.${part}: ${Object.keys(o).length} members > 32`);
      for (const [k, v] of Object.entries(o)) {
        if (!MEMBER.test(k)) fail('bad-member-name', `${w}.${part}: ${JSON.stringify(k)}`);
        str(v, `${w}.${part}.${k}`);
        if (!ASCII.test(v)) fail('not-ascii', `${w}.${part}.${k}: not printable ASCII`);
        limit(v, `${w}.${part}.${k}`, undefined, 128);
      }
    }
    if ('description' in x) limit(str(x.description, `${w}.description`), `${w}.description`, 256, 1024);
    if ('inputs' in x) checkInputs(x.inputs, x.params, `${w}.inputs`);
  });
  if ('payment' in m || paid) {
    const p = m.payment;
    if (!isObj(p)) bad('payment', 'required when a method has a price');
    if ('escrow' in p || paid) { if (!isAddress(p.escrow)) bad('payment.escrow', 'not an address'); if (paid && /^0x0{40}$/.test(p.escrow)) bad('payment.escrow', 'zero address'); }
    if ('unit' in p && p.unit !== 'BEM') bad('payment.unit', 'not BEM');
    if ('decimals' in p && p.decimals !== 8) bad('payment.decimals', 'not 8');
  }
  if ('contentSig' in m) str(m.contentSig, 'contentSig');
  return m;
}

// §3.4: the text a client may present from a valid manifest, as quoted data.
// Members this TAP does not define (at any level) are left out entirely.
export function knownText(m) {
  return {
    name: m.name ?? null,
    endpoints: [...m.endpoints.live],
    methods: m.methods.map((x) => ({
      name: x.name, description: x.description ?? null,
      params: { ...x.params }, returns: { ...x.returns },
      ...(x.inputs ? { inputs: Object.fromEntries(Object.entries(x.inputs).map(([k, s]) => [k, { type: s.type, ...('optional' in s ? { optional: s.optional } : {}), ...('enum' in s ? { enum: s.enum } : {}) }])) } : {}),
    })),
  };
}

// §3.4 item 2: provider text is put into a model's input only as a JSON string literal:
// `"` and `\` as `\"` and `\\`, U+0008, U+000C, U+000A, U+000D and U+0009 as `\b`, `\f`,
// `\n`, `\r` and `\t`, every other code point below U+0020 as `\u00xx`, and `<`, `>` and `&`
// as `\u003c`, `\u003e` and `\u0026` (lowercase hex); every other code point as itself.
export function quoteText(text) {
  return JSON.stringify(text).replace(/[<>&]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
}

// §3.6: check the arguments of a call against a method's `inputs` before sending.
// Returns null when the client may send the call, or the reason it refuses.
// A method without `inputs`, or with a type name the client does not know, has no
// schema for this client (§3.6): nothing is checked and the call may be sent.
// `args` is an object of JS values, or of values from parseJson (JsonNumber).
export function checkArguments(method, args) {
  if (!method.inputs) return null;
  const specs = Object.entries(method.inputs);
  if (specs.some(([, s]) => (Array.isArray(s.type) ? s.type : [s.type]).some((t) => !Object.hasOwn(TYPES, t)))) return null;
  for (const k of Object.keys(args)) if (!(k in method.inputs)) return `argument-unknown(${k})`;
  for (const [k, s] of specs) {
    if (!(k in args)) { if (s.optional === true) continue; return `argument-missing(${k})`; }
    const t = Array.isArray(s.type) ? s.type : [s.type];
    const v = args[k];
    const ok = t.some((x) => TYPES[x](v) && !(x === 'string' && s.enum && !s.enum.includes(v)));
    if (!ok) return `argument-type(${k})`;
  }
  return null;
}

// ---------------------------------------------------------------- CLI
function result(bytes) {
  try { return { valid: true, manifest: validateManifest(bytes) }; } catch (e) { if (e instanceof Invalid) return { valid: false, reason: e.reason, detail: e.detail }; throw e; }
}
const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  let failures = 0;
  const files = process.argv.slice(2);
  if (files.length) {
    for (const f of files) {
      const r = result(readFileSync(f));
      console.log(r.valid ? `valid      ${f}` : `INVALID    ${f}  manifest-invalid (${r.reason}) ${r.detail}`);
      if (!r.valid) failures++;
    }
  } else {
    const here = dirname(fileURLToPath(import.meta.url));
    const vec = JSON.parse(readFileSync(join(here, 'manifest-text.json'), 'utf8'));
    for (const c of vec.cases) {
      const g = c.generate, r = result(Buffer.from(g ? g.prefix + g.unit.repeat(g.count) + g.suffix : c.manifest, 'utf8'));
      let ok = r.valid === c.expect.valid && (r.valid || r.reason === c.expect.reason);
      const notes = [];
      if (ok && r.valid && c.expect.knownText) {
        const got = JSON.stringify(knownText(r.manifest));
        if (got !== JSON.stringify(c.expect.knownText)) { ok = false; notes.push(`knownText ${got}`); }
      }
      if (ok && r.valid && c.calls) for (const call of c.calls) {
        const meth = r.manifest.methods.find((x) => x.name === call.method);
        // `paramsText` is the JSON text of the arguments, judged with its number lexemes; else `params`.
        const args = call.paramsText !== undefined ? parseJson(call.paramsText) : call.params;
        const got = checkArguments(meth, args);
        if (got !== call.expect) { ok = false; notes.push(`call ${call.paramsText ?? JSON.stringify(call.params)}: ${got} != ${call.expect}`); }
      }
      if (!ok) failures++;
      console.log(`${ok ? 'pass' : 'FAIL'}  ${c.id}  -> ${r.valid ? 'valid' : `manifest-invalid (${r.reason})`}${c.calls ? `, ${c.calls.length} argument checks` : ''}${notes.length ? '  ' + notes.join('; ') : ''}`);
    }
    for (const q of vec.quotes) {
      const got = quoteText(q.text);
      const ok = got === q.quoted;
      if (!ok) failures++;
      console.log(`${ok ? 'pass' : 'FAIL'}  quote ${q.id}${ok ? '' : `  ${got} != ${q.quoted}`}`);
    }
    for (const u of vec.urls) {
      let reason = null;
      try { checkUrl(u.url, 'url'); } catch (e) { if (e instanceof Invalid) reason = e.reason; else throw e; }
      const ok = (reason === null) === u.valid && (u.valid || reason === 'bad-url');
      if (!ok) failures++;
      console.log(`${ok ? 'pass' : 'FAIL'}  url ${u.id}  -> ${reason === null ? 'valid' : reason}`);
    }
    for (const s of vec.mainnet.services) {
      const bytes = Buffer.from(s.manifestBase64, 'base64');
      const sha = '0x' + createHash('sha256').update(bytes).digest('hex');
      const r = result(bytes);
      const ok = sha === s.sha256 && r.valid === s.expect.valid;
      if (!ok) failures++;
      console.log(`${ok ? 'pass' : 'FAIL'}  mainnet ${s.name} at block ${vec.mainnet.block} (sha256 ${sha === s.sha256 ? 'matches' : 'DIFFERS'}) -> ${r.valid ? 'valid' : `manifest-invalid (${r.reason}) ${r.detail}`}`);
    }
    console.log(`${vec.cases.length} cases, ${vec.quotes.length} quotes, ${vec.urls.length} urls, ${vec.mainnet.services.length} mainnet manifests, ${failures} failed`);
  }
  process.exit(failures ? 1 : 0);
}
