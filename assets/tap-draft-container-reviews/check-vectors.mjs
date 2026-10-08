#!/usr/bin/env node
// Checker of the test vectors of TAP-draft-container-reviews (MIT License).
//  1. Replays every case and every summary with the prototype verifier (reviews-lib.mjs) and compares every expected
//     member. This applies the draft's rules with the same prototype that produced the expectations; it is not an
//     independent check of the rules.
//  2. Recomputes, without TapeAPI's EIP-712 or TAP-13 code (noble keccak and secp256k1, hand-written 32-byte words),
//     the type hashes, the domain separators, every review hash, every level-1 subject (the TAP-13 §5 digest) and
//     every signature recovery that a case reports as accepted.
//  3. Controls: every counted case must stop counting when one byte of its signature, or one field of its evidence,
//     changes.
//   TAPEAPI_ROOT=/path/to/tapeapi node check-vectors.mjs [path/to/reviews.json]
// Needs TapeAPI at commit 4a1ac4fe2a0b2e3327652a794794765dd5da98ef (public, 1.8.1) with its dependencies (see reviews-lib.mjs).
import { readFileSync } from 'node:fs'
import * as L from './reviews-lib.mjs'

const { keccak_256 } = await L.dep('@noble/hashes/sha3')
const { secp256k1 } = await L.dep('@noble/curves/secp256k1')
const { utf8ToBytes, bytesToHex, hexToBytes, concatBytes } = await L.dep('@noble/hashes/utils')
const file = process.argv[2] ?? new URL('./reviews.json', import.meta.url)
const V = JSON.parse(readFileSync(file, 'utf8'))

let checks = 0
const failures = []
const ok = (what, cond) => { checks++; if (!cond) failures.push(what) }
const k = (b) => keccak_256(b)
const hx = (b) => '0x' + bytesToHex(b)
const b = (h) => hexToBytes(String(h).replace(/^0x/, ''))
const word = (n) => { const o = new Uint8Array(32); let x = BigInt(n); for (let i = 31; i >= 0; i--) { o[i] = Number(x & 0xffn); x >>= 8n } return o }
const addrWord = (a) => { const o = new Uint8Array(32); o.set(b(a), 12); return o }
const C = V.constants

// ---- type hashes and domains, independently ----
ok('REVIEW_TYPE string', C.REVIEW_TYPE === 'Review(bytes32 reviewer,bytes32 reviewee,uint8 kind,uint8 score,bytes32 subject,bytes32 evidenceHash,bytes32 textHash,uint64 issued)')
const typeHash = k(utf8ToBytes(C.REVIEW_TYPE))
ok('REVIEW_TYPEHASH', hx(typeHash) === C.REVIEW_TYPEHASH)
ok('MANDATE_TYPEHASH', hx(k(utf8ToBytes(C.MANDATE_TYPE))) === C.MANDATE_TYPEHASH && C.MANDATE_TYPEHASH === '0xf2121b841c65f4d74c6cd4a5f8de39d1aaec1060d147338e7a635ecc5bca8171')
ok('SCOPE_TYPEHASH', hx(k(utf8ToBytes('Scope(address provider,address token,uint256 cap)'))) === C.SCOPE_TYPEHASH)
ok('TASK_VERDICT_TYPEHASH', hx(k(utf8ToBytes(C.TASK_VERDICT_TYPE))) === C.TASK_VERDICT_TYPEHASH && C.TASK_VERDICT_TYPEHASH === '0xdfd34037554f981271bc0b592c8389130df249ee45feb1a47f3706be5e8e33aa')
const domSep = (chainId) => k(concatBytes(k(utf8ToBytes('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')),
  k(utf8ToBytes('TapeAPI')), k(utf8ToBytes('1')), word(chainId), addrWord(C.hub)))
ok('domain 56 = TAP-11 Test Cases', hx(domSep(56)) === '0xa73ee348b5672f12dbc174f66a7d162c69e0d64befdba88475d9d7e3c0fd3ac7')
for (const c of Object.keys(C.domainSeparator)) ok(`domain ${c}`, hx(domSep(Number(c))) === C.domainSeparator[c])
ok('domains for 56, 8453 and 196', ['56', '8453', '196'].every((c) => c in C.domainSeparator))
const reviewHash = (r) => {
  const chainId = Number(BigInt('0x' + r.reviewer.slice(10, 26)))
  const sh = k(concatBytes(typeHash, b(r.reviewer), b(r.reviewee), word(r.kind), word(r.score), b(r.subject), b(r.evidenceHash), b(r.textHash), word(r.issued)))
  return k(concatBytes(Uint8Array.of(0x19, 0x01), domSep(chainId), sh))
}
const recover = (digest, sigHex) => {
  const s = b(sigHex); const v = s[64] < 27 ? s[64] : s[64] - 27
  const pub = secp256k1.Signature.fromCompact(s.subarray(0, 64)).addRecoveryBit(v).recoverPublicKey(digest).toRawBytes(false)
  return '0x' + bytesToHex(k(pub.subarray(1)).subarray(12))
}
const tap13 = (container, r) => k(concatBytes(utf8ToBytes('TAPI-1/resp/v2'), b(container), k(utf8ToBytes(r.id)), b(r.requestHash), Uint8Array.of(r.ok ? 1 : 0), b(r.bodyHash), word(r.ts).subarray(24)))
const eip191 = (d) => k(concatBytes(utf8ToBytes('\x19Ethereum Signed Message:\n32'), d))

for (const [label, key] of Object.entries(V.keys)) {
  ok(`key ${label} = keccak256(label)`, hx(k(utf8ToBytes('tap-reviews/test-key/' + key.label))) === key.privateKey)
  const pub = secp256k1.getPublicKey(b(key.privateKey), false)
  ok(`key ${label} address`, ('0x' + bytesToHex(k(pub.subarray(1)).subarray(12))) === key.address.toLowerCase())
}

const factsFor = (c) => ({ holders: { ...V.facts.holders, ...(c.facts?.holders ?? {}) }, signers: { ...V.facts.signers, ...(c.facts?.signers ?? {}) }, contracts: V.facts.contracts })
let counted = 0
for (const c of V.cases) {
  const got = L.verifyRecord(c.record, factsFor(c), { now: V.now })
  for (const m of Object.keys(c.expect)) ok(`${c.name}: ${m}`, JSON.stringify(got[m]) === JSON.stringify(c.expect[m]))
  if (!c.expect.valid) continue
  const r = c.record.review
  const d = reviewHash(r)
  ok(`${c.name}: review hash (independent)`, hx(d) === c.expect.hash)
  if (c.expect.signedBy === 'holder') ok(`${c.name}: recovers to holder`, recover(d, c.record.sig) === factsFor(c).holders[r.reviewer].toLowerCase())
  if (c.expect.signedBy === 'delegate') ok(`${c.name}: recovers to delegate`, recover(d, c.record.sig) === factsFor(c).signers[r.reviewer].toLowerCase())
  if (c.record.evidence !== undefined && r.evidenceHash !== L.ZERO32 && !c.expect.problems.includes('evidence-mismatch')) {
    ok(`${c.name}: evidenceHash`, hx(k(utf8ToBytes(L.canonicalJSON(c.record.evidence)))) === r.evidenceHash)
  }
  if (c.expect.level === 1) {
    const rc = c.record.evidence.receipt, container = '0x' + r.reviewee.slice(26)
    const sd = tap13(container, rc)
    ok(`${c.name}: subject = TAP-13 digest (independent)`, hx(sd) === r.subject)
    ok(`${c.name}: receipt recovers to reviewee signer`, recover(eip191(sd), rc.sig) === factsFor(c).signers[r.reviewee].toLowerCase())
    ok(`${c.name}: id names reviewer`, rc.id.startsWith('tape-review:0x' + r.reviewer.slice(26) + ':'))
  }
  if (c.expect.counted) {
    counted++
    const s = c.record.sig, flipped = s.slice(0, 20) + (s[20] === '0' ? '1' : '0') + s.slice(21)
    ok(`${c.name}: control, signature byte changed`, L.verifyRecord({ ...c.record, sig: flipped }, factsFor(c), { now: V.now }).counted === false)
    if (c.record.evidence) {
      const ev = JSON.parse(JSON.stringify(c.record.evidence))
      if (ev.receipt) ev.receipt.ts -= 1; else ev.deliver.ts -= 1
      ok(`${c.name}: control, evidence changed`, L.verifyRecord({ ...c.record, evidence: ev }, factsFor(c), { now: V.now }).counted === false)
    }
  }
}
for (const sc of V.summaries.scenarios) {
  const records = sc.cases ? [...V.cases.filter((c) => sc.cases.includes(c.name)).map((c) => c.record), ...sc.extra] : sc.records
  if (sc.cases) ok(`summary "${sc.name}": names every case`, records.length === sc.cases.length + sc.extra.length)
  const results = records.map((record) => ({ record, result: L.verifyRecord(record, V.facts, { now: V.now }) }))
  ok(`summary "${sc.name}"`, JSON.stringify(L.summarize(results, (e) => V.facts.holders[e])) === JSON.stringify(sc.expect))
}
ok('cases at every level, and at least ten rejected', [0, 1, 2].every((l) => V.cases.some((c) => c.expect.valid && c.expect.level === l)) && V.cases.filter((c) => !c.expect.valid).length >= 10)

if (failures.length) { for (const f of failures) console.error('FAIL', f); console.error(`${failures.length} of ${checks} checks failed`); process.exit(1) }
console.log(`ok: ${checks} checks over ${V.cases.length} cases (${counted} counted, ${V.cases.filter((c) => !c.expect.valid).length} rejected) and ${V.summaries.scenarios.length} summaries`)
