// Independent BIP-322 signer check for TAP "Bitcoin-keyed holders".
// Signs TAP §5.1/§5.2 messages with bip322-js (npm, pinned 4.0.0 and 3.0.0) using
// TEST keys derived from fixed public strings, then checks them with the TAP
// Python verifier (tools/cli.py verify). TEST KEYS ONLY - they are public.
//
// usage: node sign.mjs [path/to/tap-bitcoin-keyed-holders]  -> writes results.json
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import * as btc from '@scure/btc-signer';
import { secp256k1, schnorr } from '@noble/curves/secp256k1.js';

const require = createRequire(import.meta.url);
const LIBS = {
  'bip322-js@4.0.0': require('bip322-js'),
  'bip322-js@3.0.0': require('bip322-js-v3'),
};
for (const [name, lib] of Object.entries(LIBS)) {
  const pkg = name.endsWith('4.0.0') ? 'bip322-js/package.json' : 'bip322-js-v3/package.json';
  const v = require(pkg).version;
  if (!name.endsWith(v)) throw new Error(`${name} resolved to ${v}`);
}

const REPO = process.argv[2] || new URL('../..', import.meta.url).pathname;
const CLI = `${REPO}/tools/cli.py`;
const sha256 = (b) => createHash('sha256').update(b).digest();
const hex = (b) => Buffer.from(b).toString('hex');

function cli(...args) {
  try {
    const out = execFileSync('python3', [CLI, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    return { exit: 0, out: out.trim() };
  } catch (e) {
    const err = (e.stderr || '').trim().split('\n').pop();
    return { exit: e.status, out: (e.stdout || '').trim(), err };
  }
}
const cliVerify = (addr, msg, sig) => {
  const r = cli('verify', addr, msg, sig);
  return r.exit === 0 && r.out === 'valid' ? 'valid' : `INVALID(exit=${r.exit}${r.out ? ' ' + r.out : ''}${r.err ? ' ' + r.err : ''})`;
};
function libVerify(lib, addr, msg, sig) {
  try { return lib.Verifier.verifySignature(addr, msg, sig) ? 'valid' : 'invalid'; }
  catch (e) { return `throws: ${e.message}`; }
}
// Describe a BIP-322 simple witness (base64, optionally smp-prefixed)
function describeWitness(b64) {
  const s = b64.startsWith('smp') ? b64.slice(3) : b64;
  const w = Buffer.from(s, 'base64');
  const items = [];
  let i = 1;
  for (let k = 0; k < w[0]; k++) { const n = w[i]; items.push(w.subarray(i + 1, i + 1 + n)); i += 1 + n; }
  const d = { smpPrefix: b64.startsWith('smp'), witnessBytes: w.length, stackItems: w[0], itemLengths: items.map((x) => x.length) };
  if (w[0] === 1) d.p2trSighash = items[0].length === 64 ? 'SIGHASH_DEFAULT (64-byte sig)' : `0x${items[0][64].toString(16).padStart(2, '0')} (65-byte sig)`;
  if (w[0] === 2) d.p2wpkhSighash = `0x${items[0][items[0].length - 1].toString(16).padStart(2, '0')}`;
  return d;
}
const flipChar = (b64) => { const i = 10; const c = b64[i] === 'A' ? 'B' : 'A'; return b64.slice(0, i) + c + b64.slice(i + 1); };

const results = { generatedAt: new Date().toISOString(), node: process.version, libs: Object.keys(LIBS), upstream: {}, tap: {} };

// ---------- Step 1: official BIP-322 vectors (bitcoin/bips @ pinned commit) ----------
const up = JSON.parse(readFileSync(`${REPO}/vectors/upstream/basic-test-vectors.json`, 'utf8'));
for (const [name, lib] of Object.entries(LIBS)) {
  const r = { tx_hashes: [], simple: [], error: [] };
  for (const v of up.tx_hashes) {
    const spk = Buffer.from(lib.Address.convertAdressToScriptPubkey(v.address));
    const mh = hex(lib.BIP322.hashMessage(v.message));
    const toSpend = lib.BIP322.buildToSpendTx(v.message, spk);
    const psbt = lib.BIP322.buildToSignTx(toSpend.getId(), spk);
    const unsigned = Buffer.from(psbt.data.getTransaction());
    const toSignId = hex(sha256(sha256(unsigned)).reverse());
    r.tx_hashes.push({ message: v.message, message_hash: mh === v.message_hash, to_spend: toSpend.getId() === v.to_spend_tx_hash, to_sign: toSignId === v.to_sign_tx_hash });
  }
  for (const v of up.simple) {
    const e = { type: v.type, message: v.message, verify: [] };
    for (const sig of v.bip322_signatures) {
      e.verify.push({
        asGiven: libVerify(lib, v.address, v.message, sig),
        smpStripped: libVerify(lib, v.address, v.message, sig.startsWith('smp') ? sig.slice(3) : sig),
      });
    }
    if (v.type === 'p2wpkh' || v.type === 'p2tr') {
      try {
        const own = lib.Signer.sign(v.private_keys[0], v.address, v.message);
        e.ownSignature = own;
        e.ownSignatureFormat = describeWitness(own);
        e.ownMatchesAVector = v.bip322_signatures.map((s) => (s.startsWith('smp') ? s.slice(3) : s)).includes(own);
        e.ownSelfVerify = libVerify(lib, v.address, v.message, own);
        e.ownCliVerify = cliVerify(v.address, v.message, own);
      } catch (err) { e.ownSignature = `throws: ${err.message}`; }
    }
    r.simple.push(e);
  }
  for (const v of up.error) {
    const sig = v.signature.startsWith('smp') ? v.signature.slice(3) : v.signature;
    r.error.push({ description: v.description, smpStripped: libVerify(lib, v.address, v.message, sig) });
  }
  results.upstream[name] = r;
}

// ---------- Step 2: TEST keys, derived from fixed strings (public, hold nothing) ----------
function testKey(label) {
  const priv = sha256(Buffer.from(`TapeOut r10-wallets PUBLIC TEST KEY ${label} - never fund`));
  const pub = secp256k1.getPublicKey(priv, true);
  return { label, wif: btc.WIF().encode(priv), priv, pub };
}
const kTR = testKey('p2tr-bip86');
const kWPKH = testKey('p2wpkh');
const kTR2 = testKey('p2tr-other');
const addrTR = btc.p2tr(kTR.pub.subarray(1)).address;       // BIP-86: key path only, tweak with empty merkle root
const addrWPKH = btc.p2wpkh(kWPKH.pub).address;
const addrTR2 = btc.p2tr(kTR2.pub.subarray(1)).address;
const addrSH = btc.p2sh(btc.p2wpkh(kWPKH.pub)).address;      // P2SH-P2WPKH (Xverse "payment" style)
results.tap.keys = [
  { kind: 'p2tr (BIP-86)', wif: kTR.wif, internalKey: hex(kTR.pub.subarray(1)), address: addrTR, cliAddress: cli('address', addrTR).out.split('\n').slice(0, 3) },
  { kind: 'p2wpkh', wif: kWPKH.wif, pubkey: hex(kWPKH.pub), address: addrWPKH, cliAddress: cli('address', addrWPKH).out.split('\n').slice(0, 3) },
  { kind: 'p2tr other (wrong-address control)', wif: kTR2.wif, address: addrTR2 },
  { kind: 'p2sh-p2wpkh (same key as p2wpkh)', wif: kWPKH.wif, address: addrSH },
];
// The bc1p address must carry the BIP-86 *tweaked* output key, not the internal key:
const outKey = Buffer.from(btc.Address().decode(addrTR).pubkey);
results.tap.p2trOutputKeyIsTweaked = hex(outKey) !== hex(kTR.pub.subarray(1));

const DIGESTS = [
  '0x0000000000000000000000000000000000000000000000000000000000000000',
  '0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
  '0x' + hex(sha256(Buffer.from('r10 digest'))),
];
function messagesFor(addr) {
  const m = DIGESTS.map((d) => ({ kind: '§5.1 sign-message', text: cli('sign-message', addr, '56', d).out }));
  // TAP-11 delegation digest as the realistic §5.1 case
  const tap11 = cli('tap11-digest', '56', '0x1111111111111111111111111111111111111111', '0x2222222222222222222222222222222222222222', '1893456000').out.split('\n').pop();
  m.push({ kind: '§5.1 sign-message (TAP-11 delegation digest)', text: cli('sign-message', addr, '56', tap11).out });
  // §5.2 realistic call: ERC-20 transfer, 1.5 BNB value, generous gas/tip/nonce, far deadline
  const data = '0xa9059cbb000000000000000000000000' + 'ab'.repeat(20) + (10n ** 24n).toString(16).padStart(64, '0');
  m.push({ kind: '§5.2 call-message (realistic long)', text: cli('call-message', addr, '56', '0x55d398326f99059ff775485246999027b3197955', '1500000000000000000', data, '30000000', '2500000000000000', '4294967295', '4102444800').out });
  // §5.2 extreme: every number at its maximum: uint256 except the uint64 deadline (upper bound on message length)
  const M = (2n ** 256n - 1n).toString();
  const D64 = (2n ** 64n - 1n).toString(); // deadline is a uint64
  m.push({ kind: '§5.2 call-message (every number at its maximum)', text: cli('call-message', addr, '56', '0x' + 'ff'.repeat(20), M, data, M, M, M, D64).out });
  return m.map((x) => ({ ...x, chars: x.text.length }));
}

const SIGNERS = [
  { kind: 'p2tr', addr: addrTR, key: kTR, wrongAddr: addrTR2 },
  { kind: 'p2wpkh', addr: addrWPKH, key: kWPKH, wrongAddr: btc.p2wpkh(kTR2.pub).address },
];
results.tap.cases = [];
for (const s of SIGNERS) {
  for (const m of messagesFor(s.addr)) {
    if (!m.text.startsWith('TapeOut Bitcoin-keyed holder 0x')) throw new Error(`cli did not build a message: ${m.text}`);
    for (const [name, lib] of Object.entries(LIBS)) {
      const sig = lib.Signer.sign(s.key.wif, s.addr, m.text); // exactly what the wallet shows (base64)
      results.tap.cases.push({
        lib: name, addressKind: s.kind, address: s.addr, messageKind: m.kind, chars: m.chars, message: m.text,
        signature: sig, format: describeWitness(sig),
        cliVerify: cliVerify(s.addr, m.text, sig),
        cliVerifySmpPrefixed: cliVerify(s.addr, m.text, 'smp' + sig),
        cliVerifyHexWitness: cliVerify(s.addr, m.text, '0x' + hex(Buffer.from(sig, 'base64'))),
        libSelfVerify: libVerify(lib, s.addr, m.text, sig),
        negative: {
          flippedChar: cliVerify(s.addr, m.text, flipChar(sig)),
          wrongMessage: cliVerify(s.addr, m.text.replace(' on chain 56 ', ' on chain 97 '), sig),
          wrongAddress: cliVerify(s.wrongAddr, m.text, sig),
        },
      });
    }
  }
}

// ---------- P2SH-P2WPKH: what a bip322-js-based wallet emits, and what our verifier does ----------
const shMsg = cli('sign-message', addrWPKH, '56', DIGESTS[2]).out;
results.tap.p2sh = {};
for (const [name, lib] of Object.entries(LIBS)) {
  let sig;
  try { sig = lib.Signer.sign(kWPKH.wif, addrSH, shMsg); } catch (e) { results.tap.p2sh[name] = { signs: `throws: ${e.message}` }; continue; }
  results.tap.p2sh[name] = {
    address: addrSH, signature: sig, format: describeWitness(sig),
    libSelfVerify: libVerify(lib, addrSH, shMsg, sig),
    cliVerifyAgainstP2SH: cliVerify(addrSH, shMsg, sig),
    cliAddress: cli('address', addrSH),
    note: 'witness-only output; BIP-322 simple requires an empty scriptSig so P2SH-P2WPKH needs the full format',
  };
}

// ---------- Second, independent code path: port of Xverse's signMessageBip322 ----------
// Source: secretkeylabs/xverse-core@7f755226 connect/messageSigning.ts (2025-02-21), which builds
// to_spend/to_sign with @scure/btc-signer and calls txToSign.sign(privateKey) with scure's default
// sighash (SIGHASH_DEFAULT for taproot). Ported line by line; only the key plumbing differs.
const encVarint = (n) => (n < 0xfd ? Buffer.from([n]) : (() => { throw new Error('varint'); })());
function xverseSignBip322(addressType, message, priv) {
  const tag = sha256(Buffer.from('BIP0322-signed-message'));
  const msgHash = sha256(Buffer.concat([tag, tag, Buffer.from(message)]));
  const pub = addressType === 'p2tr' ? schnorr.getPublicKey(priv) : secp256k1.getPublicKey(priv, true);
  const txScript = addressType === 'p2tr' ? btc.p2tr(pub) : addressType === 'p2wpkh' ? btc.p2wpkh(pub) : btc.p2sh(btc.p2wpkh(pub));
  const txToSpend = new btc.Transaction({ allowUnknownOutputs: true, version: 0 });
  txToSpend.addOutput({ amount: 0n, script: txScript.script });
  txToSpend.addInput({ txid: new Uint8Array(32), index: 4294967295, sequence: 0, finalScriptSig: btc.Script.encode(['OP_0', msgHash]) });
  const txToSign = new btc.Transaction({ allowUnknownOutputs: true, version: 0 });
  txToSign.addInput({
    txid: txToSpend.id, index: 0, sequence: 0,
    tapInternalKey: addressType === 'p2tr' ? pub : undefined,
    witnessUtxo: { script: txScript.script, amount: 0n },
    // Xverse passes an empty redeemScript for non-P2SH; scure 2.x rejects that, so it is omitted (no effect on the signature)
    ...(addressType === 'p2sh' ? { redeemScript: txScript.redeemScript } : {}),
  });
  txToSign.addOutput({ script: btc.Script.encode(['RETURN']), amount: 0n });
  txToSign.sign(priv);
  txToSign.finalize();
  const w = txToSign.getInput(0).finalScriptWitness;
  return Buffer.concat([encVarint(w.length), ...w.map((x) => Buffer.concat([encVarint(x.length), Buffer.from(x)]))]).toString('base64');
}
results.tap.xversePort = [];
for (const s of SIGNERS) {
  for (const m of messagesFor(s.addr)) {
    const sig = xverseSignBip322(s.kind, m.text, s.key.priv);
    results.tap.xversePort.push({
      lib: 'xverse-core signMessageBip322 port (@scure/btc-signer 2.4.1)', addressKind: s.kind, messageKind: m.kind, chars: m.chars,
      signature: sig, format: describeWitness(sig),
      cliVerify: cliVerify(s.addr, m.text, sig),
      bip322jsVerify: libVerify(LIBS['bip322-js@4.0.0'], s.addr, m.text, sig),
      negativeWrongMessage: cliVerify(s.addr, m.text + ' ', sig),
    });
  }
}
{
  const sig = xverseSignBip322('p2sh', shMsg, kWPKH.priv);
  results.tap.xversePortP2sh = { address: addrSH, signature: sig, format: describeWitness(sig), sameAsBip322js: sig === results.tap.p2sh['bip322-js@4.0.0'].signature, bip322jsVerify: libVerify(LIBS['bip322-js@4.0.0'], addrSH, shMsg, sig) };
}

// ---------- Outputs published by wallet code bases (their own unit tests), fed to cli.py ----------
// Key L3VFee... is the public BIP-322 test-vector key; its BIP-86 taproot address is bc1ppv609...
const vk = btc.WIF().decode('L3VFeEujGtevx9w18HD1fhRbCH67Az2dpCymeRE1SoPK6XQtaN2k');
const vkTR = btc.p2tr(schnorr.getPublicKey(vk)).address;
const PUBLISHED = [
  { source: 'unisat-wallet/wallet-sdk test/message/message.test.ts (LocalWallet P2TR bip322-simple, "signature_old")', address: vkTR, message: 'hello', signature: 'AUCNuph9ZfpmxxVZozX4jVUYDXU3rR481/id9sQRUYTwdYWiLUE1cftTK2chYJENB0eYCLPykIC4Zi+U4DQ9zqew' },
  { source: 'leather-io/mono packages/bitcoin/src/bip322/sign-message-bip322.spec.ts (taproot, empty message)', address: vkTR, message: '', signature: 'AUD4DxC7li8RxVkoC/H27LIZnaBD/ZCyZOjjVTzyQf7wa1kYMuyv1uX7XshysTXVR05HbexLSChXuGSoZcqJl6zF' },
  { source: 'leather-io/mono sign-message-bip322.spec.ts (taproot, "WearLeather")', address: vkTR, message: 'WearLeather', signature: 'AUDjK8SJX34boek3m3EKXI94AMBZynJUmdqgO7i4z6JKG6gkUgp+brkWl0ylzWb+8enM4s4B4TWel0iCmcQrKNWS' },
  { source: 'sparrowwallet/drongo@3779317 Bip322Test.java signMessageBip322Taproot (smp + SIGHASH_ALL)', address: vkTR, message: 'Hello World', signature: 'smpAUHd69PrJQEv+oKTfZ8l+WROBHuy9HKrbFCJu7U1iK2iiEy1vMU5EfMtjc+VSHM7aU0SDbak5IUZRVno2P5mjSafAQ==' },
  { source: 'leather-io/mono sign-message-bip322.spec.ts (native segwit, empty message)', address: 'bc1q9vza2e8x573nczrlzms0wvx3gsqjx7vavgkx0l', message: '', signature: 'AkgwRQIhAPkJ1Q4oYS0htvyuSFHLxRQpFAY56b70UvE7Dxazen0ZAiAtZfFz1S6T6I23MWI2lK/pcNTWncuyL8UL+oMdydVgzAEhAsfxIAMZZEKUPYWI4BruhAQjzFT8FSFSajuFwrDL1Yhy' },
  { source: 'unisat-wallet/wallet-sdk message.test.ts (P2WPKH, "Hello World")', address: 'bc1q9vza2e8x573nczrlzms0wvx3gsqjx7vavgkx0l', message: 'Hello World', signature: 'AkcwRAIgZRfIY3p7/DoVTty6YZbWS71bc5Vct9p9Fia83eRmw2QCICK/ENGfwLtptFluMGs2KsqoNSk89pO7F29zJLUx9a/sASECx/EgAxlkQpQ9hYjgGu6EBCPMVPwVIVJqO4XCsMvViHI=' },
];
results.published = PUBLISHED.map((p) => ({ ...p, format: describeWitness(p.signature), cliVerify: cliVerify(p.address, p.message, p.signature), bip322jsVerify: libVerify(LIBS['bip322-js@4.0.0'], p.address, p.message, p.signature) }));

writeFileSync(new URL('./results.json', import.meta.url), JSON.stringify(results, null, 2));

// ---------- summary ----------
const cases = results.tap.cases;
const ok = cases.filter((c) => c.cliVerify === 'valid' && c.cliVerifySmpPrefixed === 'valid' && c.cliVerifyHexWitness === 'valid');
const negOk = cases.filter((c) => Object.values(c.negative).every((x) => x.startsWith('INVALID')));
console.log(`TAP cases: ${cases.length}, accepted by cli.py (plain/smp/hex): ${ok.length}, negative controls rejected: ${negOk.length}`);
for (const [n, r] of Object.entries(results.upstream)) {
  console.log(`${n} upstream tx_hashes all ok: ${r.tx_hashes.every((t) => t.message_hash && t.to_spend && t.to_sign)}`);
}
const xp = results.tap.xversePort;
console.log(`Xverse-port cases: ${xp.length}, cli.py valid: ${xp.filter((c) => c.cliVerify === 'valid').length}, negative rejected: ${xp.filter((c) => c.negativeWrongMessage.startsWith('INVALID')).length}`);
for (const p of results.published) console.log(`published ${p.format.witnessBytes}B ${p.cliVerify} <- ${p.source}`);
console.log('wrote results.json');
