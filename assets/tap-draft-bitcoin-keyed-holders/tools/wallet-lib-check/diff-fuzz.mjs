// Differential fuzz corpus: BIP-322 "simple" signatures made by bip322-js (4.0.0) for public TEST keys, then mutated.
// Output corpus.json: for each case the message, the witness bytes, and bip322-js's own verdict on the mutant.
// The contract-side verdict is computed by contracts/test/DiffFuzz.t.sol with the same inputs. TEST KEYS ONLY.
// usage (in this directory, after npm ci): node diff-fuzz.mjs   -> writes ../../vectors/diff-fuzz-corpus.json (deterministic)
import { createRequire } from 'node:module';
import { writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import * as btc from '@scure/btc-signer';
import { secp256k1 } from '@noble/curves/secp256k1.js';

const require = createRequire(import.meta.url);
const lib = require('bip322-js');
const sha256 = (b) => createHash('sha256').update(b).digest();
const hex = (b) => Buffer.from(b).toString('hex');
const N = secp256k1.Point.Fn.ORDER;

// deterministic PRNG (xorshift128+) so the corpus is reproducible
let s0 = 0x9e3779b97f4a7c15n, s1 = 0xbf58476d1ce4e5b9n;
const M64 = (1n << 64n) - 1n;
function rnd() { let x = s0, y = s1; s0 = y; x ^= (x << 23n) & M64; s1 = (x ^ y ^ (x >> 17n) ^ (y >> 26n)) & M64; return Number(((s1 + y) & M64) >> 11n) / 2 ** 53; }
const ri = (n) => Math.floor(rnd() * n);
const pick = (a) => a[ri(a.length)];

function testKey(label) {
  const priv = sha256(Buffer.from(`TapeOut r10-wallets PUBLIC TEST KEY ${label} - never fund`));
  return { priv, pub: secp256k1.getPublicKey(priv, true), wif: btc.WIF().encode(priv) };
}
const kTR = testKey('p2tr-bip86'), kWP = testKey('p2wpkh'), kTR2 = testKey('p2tr-other'), kWP2 = testKey('p2wpkh-other');
const addrTR = btc.p2tr(kTR.pub.subarray(1)).address;
const addrWP = btc.p2wpkh(kWP.pub).address;
const addrTR2 = btc.p2tr(kTR2.pub.subarray(1)).address;
const addrWP2 = btc.p2wpkh(kWP2.pub).address;
const outKey = (a) => hex(btc.Address().decode(a).pubkey);
const wpHash = (a) => hex(btc.Address().decode(a).hash);

const verify = (addr, msg, wit) => {
  try { return lib.Verifier.verifySignature(addr, msg, Buffer.from(wit).toString('base64')) === true; } catch { return false; }
};

// messages: TAP-shaped texts and arbitrary ones, ASCII and multi-byte
const MSGS = [
  '', 'Hello World', 'Hello World!', 'a', '\n', 'x'.repeat(300),
  'TapeOut Bitcoin-keyed holder\nholder: 0x750d22d8b6dd3168c2a4a2efddd44a8bfe362647\nchain: 56\nmessage: 0x' + 'ab'.repeat(32),
  'ünïcödé — 比特币 ₿ 🚀', '\u0000\u0001 control', 'line1\r\nline2\r\n',
];
for (let i = 0; i < 24; i++) { let t = ''; const n = ri(120); for (let j = 0; j < n; j++) t += String.fromCharCode(32 + ri(95)); MSGS.push(t); }

function der(r, s) {
  const be = (x) => { let h = x.toString(16); if (h.length % 2) h = '0' + h; let b = Buffer.from(h, 'hex'); if (b[0] & 0x80) b = Buffer.concat([Buffer.from([0]), b]); return b; };
  const rb = be(r), sb = be(s);
  return Buffer.concat([Buffer.from([0x30, 4 + rb.length + sb.length, 2, rb.length]), rb, Buffer.from([2, sb.length]), sb]);
}
function parseDer(d) { // returns {r,s,rb,sb} or null
  if (d[0] !== 0x30) return null; const rl = d[3]; const rb = d.subarray(4, 4 + rl); const sl = d[5 + rl]; const sb = d.subarray(6 + rl, 6 + rl + sl);
  return { r: BigInt('0x' + hex(rb)), s: BigInt('0x' + hex(sb)), rb, sb };
}
const lenPrefix = (b) => Buffer.concat([Buffer.from([b.length]), b]);
const witness = (items) => Buffer.concat([Buffer.from([items.length]), ...items.map(lenPrefix)]);

function splitWitness(w) {
  const items = []; let i = 1; for (let k = 0; k < w[0]; k++) { const n = w[i]; items.push(Buffer.from(w.subarray(i + 1, i + 1 + n))); i += 1 + n; } return items;
}

const cases = [];
const add = (kind, tag, msg, wit, addr, expectOwn = null) => cases.push({ kind, tag, msg: hex(Buffer.from(msg, 'utf8')), wit: hex(wit), lib: verify(addr, msg, wit) });

const kinds = [
  { kind: 'p2wpkh', k: kWP, addr: addrWP, other: addrWP2, ko: kWP2 },
  { kind: 'p2tr', k: kTR, addr: addrTR, other: addrTR2, ko: kTR2 },
];

function mutateBytes(w) {
  const out = [];
  for (let i = 0; i < 40; i++) {
    const b = Buffer.from(w); const op = ri(7);
    if (op === 0) { b[ri(b.length)] ^= 1 << ri(8); out.push(['bitflip', b]); }
    else if (op === 1) { b[ri(b.length)] = ri(256); out.push(['setbyte', b]); }
    else if (op === 2) { const j = ri(b.length); out.push(['delete', Buffer.concat([b.subarray(0, j), b.subarray(j + 1)])]); }
    else if (op === 3) { const j = ri(b.length + 1); out.push(['insert', Buffer.concat([b.subarray(0, j), Buffer.from([ri(256)]), b.subarray(j)])]); }
    else if (op === 4) { out.push(['truncate', b.subarray(0, ri(b.length))]); }
    else if (op === 5) { out.push(['append', Buffer.concat([b, Buffer.from(Array.from({ length: 1 + ri(4) }, () => ri(256)))])]); }
    else { b[0] = pick([0, 1, 2, 3, 255]); out.push(['itemcount', b]); }
  }
  return out;
}

for (const K of kinds) {
  for (const msg of MSGS) {
    let b64;
    try { b64 = lib.Signer.sign(K.k.wif, K.addr, msg); } catch (e) { continue; }
    const w = Buffer.from(b64.startsWith('smp') ? b64.slice(3) : b64, 'base64');
    add(K.kind, 'valid', msg, w, K.addr);
    // wrong message / wrong key
    add(K.kind, 'msg+char', msg, w, K.addr); cases[cases.length - 1].msg = hex(Buffer.from(msg + 'x', 'utf8')); cases[cases.length - 1].lib = verify(K.addr, msg + 'x', w);
    // generic byte mutations
    for (const [tag, m] of mutateBytes(w)) add(K.kind, tag, msg, m, K.addr);
    const items = splitWitness(w);
    if (K.kind === 'p2wpkh') {
      const d = parseDer(items[0].subarray(0, items[0].length - 1)); const pub = items[1];
      // sighash types
      for (const ht of [0, 1, 2, 3, 0x81, 0x82, 0x83, 0x80, 0x40, 0xff]) add(K.kind, `sighash=${ht}`, msg, witness([Buffer.concat([items[0].subarray(0, -1), Buffer.from([ht])]), pub]), K.addr);
      // high s
      add(K.kind, 'high-s', msg, witness([Buffer.concat([der(d.r, N - d.s), Buffer.from([1])]), pub]), K.addr);
      // non-minimal DER integers
      add(K.kind, 'der-r-leading-zero', msg, witness([Buffer.concat([der(d.r, d.s).subarray(0, 0), (() => { const rb = Buffer.concat([Buffer.from([0]), d.rb]); const sb = d.sb; return Buffer.concat([Buffer.from([0x30, 4 + rb.length + sb.length, 2, rb.length]), rb, Buffer.from([2, sb.length]), sb]); })(), Buffer.from([1])]), pub]), K.addr);
      add(K.kind, 'der-s-leading-zero', msg, witness([Buffer.concat([(() => { const rb = d.rb, sb = Buffer.concat([Buffer.from([0]), d.sb]); return Buffer.concat([Buffer.from([0x30, 4 + rb.length + sb.length, 2, rb.length]), rb, Buffer.from([2, sb.length]), sb]); })(), Buffer.from([1])]), pub]), K.addr);
      // BER long-form length
      { const inner = items[0].subarray(2, items[0].length - 1); add(K.kind, 'der-long-form-length', msg, witness([Buffer.concat([Buffer.from([0x30, 0x81, inner.length]), inner, Buffer.from([1])]), pub]), K.addr); }
      // r or s zero, r = n
      add(K.kind, 'r-zero', msg, witness([Buffer.concat([der(0n, d.s), Buffer.from([1])]), pub]), K.addr);
      add(K.kind, 's-zero', msg, witness([Buffer.concat([der(d.r, 0n), Buffer.from([1])]), pub]), K.addr);
      add(K.kind, 'r-n', msg, witness([Buffer.concat([der(N, d.s), Buffer.from([1])]), pub]), K.addr);
      add(K.kind, 'r-plus-n', msg, witness([Buffer.concat([der(d.r + N, d.s), Buffer.from([1])]), pub]), K.addr);
      // pubkey variants
      const unc = Buffer.from(secp256k1.getPublicKey(K.k.priv, false));
      add(K.kind, 'pub-uncompressed', msg, witness([items[0], unc]), K.addr);
      const hyb = Buffer.from(unc); hyb[0] = 0x06 | (unc[64] & 1); add(K.kind, 'pub-hybrid', msg, witness([items[0], hyb]), K.addr);
      const flip = Buffer.from(pub); flip[0] ^= 1; add(K.kind, 'pub-parity-flip', msg, witness([items[0], flip]), K.addr);
      add(K.kind, 'pub-other-key', msg, witness([items[0], Buffer.from(K.ko.pub)]), K.addr);
      add(K.kind, 'swap-items', msg, witness([items[1], items[0]]), K.addr);
      add(K.kind, 'one-item', msg, witness([items[0]]), K.addr);
      add(K.kind, 'three-items', msg, witness([items[0], pub, Buffer.alloc(0)]), K.addr);
      // sig made by another key for this address
      try { const o = lib.Signer.sign(K.ko.wif, K.other, msg); const ow = Buffer.from(o.startsWith('smp') ? o.slice(3) : o, 'base64'); add(K.kind, 'other-key-sig', msg, ow, K.addr); } catch {}
    } else {
      const sig = items[0];
      for (const ht of [0, 1, 2, 3, 0x81, 0x82, 0x83, 0x80, 0xff]) add(K.kind, `sighash=${ht}`, msg, witness([Buffer.concat([sig.subarray(0, 64), Buffer.from([ht])])]), K.addr);
      add(K.kind, 'zero-pad-hashtype-explicit-default', msg, witness([Buffer.concat([sig.subarray(0, 64), Buffer.from([0])])]), K.addr);
      add(K.kind, 'sig-63', msg, witness([sig.subarray(0, 63)]), K.addr);
      add(K.kind, 'sig-66', msg, witness([Buffer.concat([sig.subarray(0, 64), Buffer.from([1, 1])])]), K.addr);
      add(K.kind, 'two-items', msg, witness([sig, Buffer.alloc(0)]), K.addr);
      add(K.kind, 'annex-like', msg, witness([sig, Buffer.from([0x50, 0x00])]), K.addr);
      // s = n - s analogue: r || (s+n mod 2^256), r with +p wrap
      const r = sig.subarray(0, 32), sv = BigInt('0x' + hex(sig.subarray(32, 64)));
      const s2 = ((N - sv) % (1n << 256n)).toString(16).padStart(64, '0');
      add(K.kind, 'schnorr-s-negated', msg, witness([Buffer.concat([r, Buffer.from(s2, 'hex')])]), K.addr);
      const rp = (BigInt('0x' + hex(r)) + 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2fn) % (1n << 256n);
      add(K.kind, 'schnorr-r-plus-p', msg, witness([Buffer.concat([Buffer.from(rp.toString(16).padStart(64, '0'), 'hex'), sig.subarray(32, 64)])]), K.addr);
      try { const o = lib.Signer.sign(K.ko.wif, K.other, msg); const ow = Buffer.from(o.startsWith('smp') ? o.slice(3) : o, 'base64'); add(K.kind, 'other-key-sig', msg, ow, K.addr); } catch {}
    }
  }
}
const out = {
  keys: { p2wpkh: wpHash(addrWP), p2tr: outKey(addrTR) },
  n: cases.length,
  kind: cases.map((c) => (c.kind === 'p2wpkh' ? 0 : 1)),
  msg: cases.map((c) => '0x' + c.msg),
  wit: cases.map((c) => '0x' + c.wit),
  lib: cases.map((c) => (c.lib ? 1 : 0)),
  tag: cases.map((c) => c.tag),
};
writeFileSync(new URL('../../vectors/diff-fuzz-corpus.json', import.meta.url), JSON.stringify(out));
const by = {}; for (const c of cases) { const k = c.kind + ':' + c.tag.replace(/=.*/, '='); by[k] = by[k] || [0, 0]; by[k][c.lib ? 1 : 0]++; }
console.log(out.n, 'cases; libAccept per tag [reject,accept]:'); console.log(JSON.stringify(by));
