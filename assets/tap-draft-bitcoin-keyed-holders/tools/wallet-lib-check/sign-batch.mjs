// Signs the executeBatch messages of vectors/batch-vectors.json, plus a longest-possible batch text, with
// bip322-js 4.0.0 and 3.0.0 (TEST keys of tools/cli.py; they hold nothing), and checks each signature
// with tools/cli.py verify; a flipped character in the message must be rejected. Writes results-batch.json
// next to this file; tools/make_batch_vectors.py puts the 4.0.0 signatures into the vectors, and the
// Foundry tests execute every batch with them (BatchTest.test_vectors_bip322js).
// usage: node sign-batch.mjs <path to this repository>   (run where `npm ci` installed package.json)
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import * as btc from '@scure/btc-signer';

const require = createRequire(import.meta.url);
const LIBS = { 'bip322-js@4.0.0': require('bip322-js'), 'bip322-js@3.0.0': require('bip322-js-v3') };
const REPO = process.argv[2];
const sha256 = (b) => createHash('sha256').update(b).digest();
const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
function testKey(label) { // tools/cli.py test_key
  const h = BigInt('0x' + sha256(Buffer.from('tap-bitcoin-keyed-holders vector key ' + label)).toString('hex')) % N;
  return Buffer.from(h.toString(16).padStart(64, '0'), 'hex');
}
const py = (...a) => execFileSync('python3', [`${REPO}/tools/cli.py`, ...a], { encoding: 'utf8' }).trim();
const verify = (addr, msg, sig) => { try { return py('verify', addr, msg, sig) === 'valid'; } catch { return false; } };

const vec = JSON.parse(readFileSync(`${REPO}/vectors/batch-vectors.json`, 'utf8'));
const keys = { p2tr: btc.WIF().encode(testKey('1')), p2wpkh: btc.WIF().encode(testKey('2')) };
const longest = execFileSync('python3', ['-c', `
import sys; sys.path.insert(0, "${REPO}/tools"); import holder as H
M = 2**256 - 1
calls = [(bytes.fromhex("ff" * 20), M, b"x" * 100, 2**64 - 1)] * 8
print(H.batch_message(bytes.fromhex("ff" * 20), 2**64 - 1, calls, M, M, 2**64 - 1).decode())`], { encoding: 'utf8' }).trim();

const msgs = vec.cases.map((c) => ({ name: c.name, kind: c.holder, text: c.message }));
for (const kind of ['p2tr', 'p2wpkh']) msgs.push({ name: `${kind}-longest-possible`, kind, text: longest });
let ok = 0, bad = 0;
const out = { node: process.version, libs: Object.keys(LIBS), creationCodeKeccak: vec.creationCodeKeccak, cases: [] };
for (const m of msgs) {
  const addr = vec.holders[m.kind].address;
  for (const [lib, L] of Object.entries(LIBS)) {
    const sig = L.Signer.sign(keys[m.kind], addr, m.text);
    const valid = verify(addr, m.text, sig);
    const flipped = m.text.slice(0, -1) + (m.text.endsWith('0') ? '1' : '0');
    const rejected = !verify(addr, flipped, sig);
    console.log(`${lib} ${m.name} chars=${m.text.length} valid=${valid} flippedRejected=${rejected}`);
    out.cases.push({ lib, name: m.name, kind: m.kind, address: addr, chars: m.text.length, message: m.text, signature: sig, cliVerify: valid, flippedRejected: rejected });
    valid && rejected ? ok++ : bad++;
  }
}
console.log(`summary: ${ok} ok, ${bad} failed`);
writeFileSync(new URL('./results-batch.json', import.meta.url), JSON.stringify(out, null, 1) + '\n');
process.exit(bad ? 1 : 0);
