#!/usr/bin/env node
// Generator of the test vectors of TAP-draft-container-reviews (MIT License). Deterministic: fixed test keys
// (keccak256 of a label) and fixed times. Writes reviews.json next to this file.
//   TAPEAPI_ROOT=/path/to/tapeapi node make-vectors.mjs [--check]
//   --check: regenerate in memory and compare with reviews.json, write nothing.
// Needs TapeAPI at commit 4a1ac4fe2a0b2e3327652a794794765dd5da98ef (public, 1.8.1) with its dependencies (see reviews-lib.mjs).
import { readFileSync, writeFileSync } from 'node:fs'
import * as L from './reviews-lib.mjs'

const { keccak_256 } = await L.dep('@noble/hashes/sha3')
const { utf8ToBytes, bytesToHex } = await L.dep('@noble/hashes/utils')
const { sig, abi, agent } = L
const { hashReceipt } = await import(new URL('sdk/src/mcp.js', L.ROOT))
const OUT = new URL('./reviews.json', import.meta.url)

const h = (s) => '0x' + bytesToHex(keccak_256(utf8ToBytes(s)))
const key = (label) => { const pk = h('tap-reviews/test-key/' + label); return { label, privateKey: pk, address: sig.privateKeyToAddress(pk) } }
const addrOf = (label) => abi.checksumAddress('0x' + h('tap-reviews/test-container/' + label).slice(26))
const clone = (v) => JSON.parse(JSON.stringify(v))

// ---------------------------------------------------------------- parties ----
const K = {
  A_holder: key('A-holder'), A_delegate: key('A-delegate'), B_holder: key('B-holder'), B_signer: key('B-signer'),
  B_signer_rotated: key('B-signer-rotated'), C_holder: key('C-holder'), E_service_signer: key('E-signer'),
  stranger: key('stranger'), A_agent_key: key('A-agent-key'),
}
const P = {
  A: { chainId: 56, container: addrOf('A'), holder: K.A_holder.address, signer: K.A_delegate.address, note: 'reviewer on BNB Smart Chain; also a TAP-11 service whose signer is A_delegate' },
  B: { chainId: 56, container: addrOf('B'), holder: K.B_holder.address, signer: K.B_signer.address, note: 'reviewee on BNB Smart Chain, a TAP-11 service' },
  C: { chainId: 8453, container: addrOf('C'), holder: K.C_holder.address, signer: null, note: 'reviewer on Base, not a service' },
  D: { chainId: 56, container: addrOf('D'), holder: K.B_holder.address, signer: null, note: 'reviewer on BNB Smart Chain held by the same address as B' },
  E: { chainId: 56, container: addrOf('E'), holder: K.stranger.address, signer: K.E_service_signer.address, note: 'another service, not the reviewee' },
  F: { chainId: 56, container: addrOf('F'), holder: addrOf('F-contract-wallet'), signer: null, note: 'reviewer on BNB Smart Chain whose holder is a contract (has code)' },
}
for (const p of Object.values(P)) p.endpoint = L.endpointId(p.chainId, p.container)
const facts = { holders: {}, signers: {}, contracts: [P.F.holder] }
for (const p of Object.values(P)) { facts.holders[p.endpoint] = p.holder; if (p.signer) facts.signers[p.endpoint] = p.signer }
const NOW = 1791100000, T = 1791000000
const HUB = L.HUB

// ---------------------------------------------------------------- builders ----
function review(o) {
  return { reviewer: o.reviewer.endpoint, reviewee: o.reviewee.endpoint, kind: o.kind ?? 1, score: o.score ?? 4,
    subject: o.subject ?? L.ZERO32, evidenceHash: o.evidenceHash ?? L.ZERO32, textHash: o.textHash ?? L.ZERO32, issued: o.issued ?? T }
}
function record(rv, signer, extra = {}) {
  const rec = { review: rv, sig: L.signReview(rv, signer.privateKey) }
  if (extra.text !== undefined) rec.text = extra.text
  if (extra.evidence !== undefined) rec.evidence = extra.evidence
  return rec
}
// A TAP-13 answer of `service` (signed by its signer key) to a request with id `id`, as a hash-only receipt (v 2)
function receipt({ service, signerKey, id, method = 'quote', params = { pair: 'BEM/USDT' }, ok = true, body = { price: '0.0123', block: 64000000 }, ts = T - 3600 }) {
  const env = { container: service.container, id, method, params, ok, body, ts }
  const s = sig.signResponse(env, signerKey.privateKey)
  const full = { v: 1, service: { container: service.container }, method, params, id, ts, ok, ...(ok ? { result: body } : { error: body }), sig: s }
  const hashOnly = hashReceipt(full)
  return { full, hashOnly, subject: abi.toHex(sig.responseDigest(env)) }
}
function responseEvidence(o) { const r = receipt(o); return { evidence: { kind: 'response', receipt: r.hashOnly }, subject: r.subject, full: r.full } }
function taskEvidence({ principal, agentP, principalKey, agentSignerKey, mandateKey = principalKey, verdictKey = principalKey, verdictValue = 1, deliverTs = T - 7200, verdictIssued = T - 3600, mandateOver = {}, deliverOver = {}, verdictOver = {} }) {
  const task = { kind: 'chain-report', text: 'Summarise BEM transfers of block 64000000.' }
  const m = { principal: principal.container, agent: agentP.container, agentKey: K.A_agent_key.address, mode: 0, taskHash: agent.taskHashOf(task),
    scope: [], feeToken: abi.ZERO_ADDRESS, feeCap: '0', notBefore: T - 86400, expires: T + 86400, nonce: '7', subdelegate: false, ...mandateOver }
  const mn = agent.normalizeMandate(m)
  const mandateHash = agent.mandateHashOf(principal.chainId, HUB, mn)
  const mandateSig = sig.signDigest(agent.mandateDigest(principal.chainId, HUB, mn), mandateKey.privateKey)
  const deliverable = { report: 'three transfers', count: 3 }
  const receiptsList = []
  const result = { kind: 'tape.agent/deliver', mandateHash, deliverableHash: agent.jsonHashOf(deliverable), receipts: receiptsList, receiptsHash: agent.jsonHashOf(receiptsList), exp: T + 86400, ...deliverOver }
  const did = 'deliver-0001'
  const dsig = sig.signResponse({ container: agentP.container, id: did, method: 'task_deliver', params: { mandateHash }, ok: true, body: result, ts: deliverTs }, agentSignerKey.privateKey)
  const deliver = { v: 1, service: { container: agentP.container }, method: 'task_deliver', params: { mandateHash }, id: did, ts: deliverTs, ok: true, result, sig: dsig }
  const verdict = { mandateHash, deliverableHash: result.deliverableHash, verdict: verdictValue, reasonHash: L.ZERO32, issued: verdictIssued, ...verdictOver }
  const verdictSig = sig.signDigest(agent.taskVerdictDigest(principal.chainId, HUB, verdict), verdictKey.privateKey)
  // the mandate in its JSON form (#47 §3.7): addresses as given, uint256 as decimal strings
  const mandate = { ...m, nonce: String(m.nonce), feeCap: String(m.feeCap) }
  return { evidence: { kind: 'task', mandate, mandateSig, deliver, verdict, verdictSig }, subject: mandateHash, task, deliverable }
}
const withEvidence = (o, ev) => ({ ...o, subject: ev.subject, evidenceHash: L.jsonHash(ev.evidence) })
const nonce = (n) => n.toString(16).padStart(32, '0')

// ---------------------------------------------------------------- cases ----
const cases = []
const add = (name, rec, expect, o = {}) => cases.push({ name, ...(o.description ? { description: o.description } : {}), record: rec, ...(o.facts ? { facts: o.facts } : {}), expect })

const text1 = { body: 'Answers were fast and matched the chain.', tags: ['fast', 'accurate'] }
// valid and counted
const ev1 = responseEvidence({ service: P.B, signerKey: K.B_signer, id: L.reviewRequestId(P.A.container, nonce(1)) })
const R_L1 = record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 5, textHash: L.jsonHash(text1), issued: T }, ev1)), K.A_holder, { text: text1, evidence: ev1.evidence })
add('level 1: signed answer, reviewer holder', R_L1, { valid: true, level: 1, signedBy: 'holder', counted: true, problems: [] })

const ev1b = responseEvidence({ service: P.B, signerKey: K.B_signer, id: L.reviewRequestId(P.A.container, nonce(2)), method: 'balance', params: { address: P.C.container }, body: { balance: '1000' }, ts: T - 600 })
const R_L1_DEL = record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 3, issued: T + 10 }, ev1b)), K.A_delegate, { evidence: ev1b.evidence })
add('level 1: signed by the reviewer\'s delegate (TAP-11 signer)', R_L1_DEL, { valid: true, level: 1, signedBy: 'delegate', counted: true, problems: [] })

const ev1c = responseEvidence({ service: P.B, signerKey: K.B_signer, id: L.reviewRequestId(P.A.container, nonce(3)), ok: false, body: { code: 'METHOD_NOT_FOUND', message: 'no such method' }, method: 'swap', params: {} })
const R_L1_REFUSAL = record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 2, issued: T + 20 }, ev1c)), K.A_holder, { evidence: ev1c.evidence })
add('level 1: evidence is a signed refusal (ok false)', R_L1_REFUSAL, { valid: true, level: 1, signedBy: 'holder', counted: true, problems: [] })

const ev1x = responseEvidence({ service: P.B, signerKey: K.B_signer, id: L.reviewRequestId(P.C.container, nonce(4)) })
const R_X_CHAIN = record(review(withEvidence({ reviewer: P.C, reviewee: P.B, score: 4, issued: T + 30 }, ev1x)), K.C_holder, { evidence: ev1x.evidence })
add('level 1: reviewer on Base (domain chainId 8453) reviews a service on BNB Smart Chain', R_X_CHAIN, { valid: true, level: 1, signedBy: 'holder', counted: true, problems: [] })

const ev2 = taskEvidence({ principal: P.A, agentP: P.B, principalKey: K.A_holder, agentSignerKey: K.B_signer })
const R_L2 = record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 4, issued: T + 40 }, ev2)), K.A_holder, { evidence: ev2.evidence })
add('level 2: task evidence, principal reviews agent', R_L2, { valid: true, level: 2, signedBy: 'holder', counted: true, problems: [] })
const R_L2_REV = record(review(withEvidence({ reviewer: P.B, reviewee: P.A, score: 5, issued: T + 50 }, ev2)), K.B_holder, { evidence: ev2.evidence })
add('level 2: the same task, agent reviews principal', R_L2_REV, { valid: true, level: 2, signedBy: 'holder', counted: true, problems: [] })
const ev2r = taskEvidence({ principal: P.A, agentP: P.B, principalKey: K.A_holder, agentSignerKey: K.B_signer, verdictValue: 2, mandateOver: { nonce: '8' } })
const R_L2_REJ = record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 1, issued: T + 45 }, ev2r)), K.A_holder, { evidence: ev2r.evidence })
add('level 2: task evidence with a rejecting verdict (2)', R_L2_REJ, { valid: true, level: 2, signedBy: 'holder', counted: true, problems: [] })

// valid, shown, not counted
const R_L0 = record(review({ reviewer: P.A, reviewee: P.B, score: 4, textHash: L.jsonHash(text1), issued: T - 100 }), K.A_holder, { text: text1 })
add('level 0: no evidence (shown, never counted)', R_L0, { valid: true, level: 0, signedBy: 'holder', counted: false, problems: [] })
const R_L0_WITHHELD = record(review({ reviewer: P.C, reviewee: P.B, score: 2, textHash: L.jsonHash({ body: 'kept private' }), issued: T - 50 }), K.C_holder)
add('level 0: text withheld (only its hash is published)', R_L0_WITHHELD, { valid: true, level: 0, signedBy: 'holder', counted: false, problems: [], textWithheld: true })
const R_WITHDRAW = record(review({ reviewer: P.A, reviewee: P.B, kind: 2, score: 0, subject: ev1.subject, issued: T + 100 }), K.A_holder)
add('withdrawal of the first level-1 review (same subject, later issued)', R_WITHDRAW, { valid: true, level: 0, signedBy: 'holder', counted: false, problems: [] })
add('signer is neither the current holder nor the current delegate', record(R_L1.review, K.stranger, { text: text1, evidence: ev1.evidence }), { valid: true, level: 1, signedBy: null, counted: false, problems: ['signer-not-current'] })
add('domain of the wrong chain: C (Base) signs with the BNB Smart Chain domain', { ...clone(R_X_CHAIN), sig: sig.signDigest(L.reviewDigest(R_X_CHAIN.review, { chainId: 56 }), K.C_holder.privateKey) }, { valid: true, level: 1, signedBy: null, counted: false, problems: ['signer-not-current'] })
const evD = responseEvidence({ service: P.B, signerKey: K.B_signer, id: L.reviewRequestId(P.D.container, nonce(5)) })
add('related parties: reviewer D is held by the reviewee\'s holder', record(review(withEvidence({ reviewer: P.D, reviewee: P.B, score: 5, issued: T + 60 }, evD)), K.B_holder, { evidence: evD.evidence }), { valid: true, level: 1, signedBy: 'holder', counted: false, problems: ['related-parties'] })
const evNoPrefix = responseEvidence({ service: P.B, signerKey: K.B_signer, id: 'req-' + nonce(6) })
add('evidence unbound: the request id does not name the reviewer', record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 5, issued: T + 70 }, evNoPrefix)), K.A_holder, { evidence: evNoPrefix.evidence }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-unbound'] })
add('evidence unbound: A cites a receipt whose id names C', record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 5, issued: T + 71 }, ev1x)), K.A_holder, { evidence: ev1x.evidence }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-unbound'] })
const evOther = responseEvidence({ service: P.E, signerKey: K.E_service_signer, id: L.reviewRequestId(P.A.container, nonce(7)) })
add('evidence from another service than the reviewee', record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 1, issued: T + 72 }, evOther)), K.A_holder, { evidence: evOther.evidence }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-wrong-party'] })
const evLate = responseEvidence({ service: P.B, signerKey: K.B_signer, id: L.reviewRequestId(P.A.container, nonce(8)), ts: T + 500 })
add('evidence after the review (receipt ts > issued)', record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 5, issued: T + 80 }, evLate)), K.A_holder, { evidence: evLate.evidence }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-time'] })
const evOld = responseEvidence({ service: P.B, signerKey: K.B_signer, id: L.reviewRequestId(P.A.container, nonce(9)), ts: T - L.MAX_EVIDENCE_AGE_S - 1 })
add('evidence older than 90 days', record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 5, issued: T }, evOld)), K.A_holder, { evidence: evOld.evidence }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-time'] })
const evEdge = responseEvidence({ service: P.B, signerKey: K.B_signer, id: L.reviewRequestId(P.A.container, nonce(10)), ts: T - L.MAX_EVIDENCE_AGE_S })
add('evidence exactly 90 days old (accepted)', record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 4, issued: T }, evEdge)), K.A_holder, { evidence: evEdge.evidence }), { valid: true, level: 1, signedBy: 'holder', counted: true, problems: [] })
add('reviewee rotated its signer: the old receipt no longer verifies', R_L1, { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-signature'] },
  { facts: { signers: { [P.B.endpoint]: K.B_signer_rotated.address } } })
const evAltered = clone(ev1.evidence); evAltered.receipt.ts += 1
add('evidence altered after signing (hash mismatch)', { ...clone(R_L1), evidence: evAltered }, { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-mismatch'] })
const evPay = { kind: 'payment', chainId: 56, tx: '0x' + 'ab'.repeat(32) }
add('unknown evidence kind (reserved): treated as level 0', record(review({ reviewer: P.A, reviewee: P.B, score: 5, subject: '0x' + 'ab'.repeat(32), evidenceHash: L.jsonHash(evPay), issued: T + 90 }), K.A_holder, { evidence: evPay }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-unknown'] })
add('evidence missing (only its hash is published)', record(R_L1.review, K.A_holder), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-missing'] })
add('subject does not match the evidence', record(review({ reviewer: P.A, reviewee: P.B, score: 5, subject: ev1b.subject, evidenceHash: L.jsonHash(ev1.evidence), issued: T + 91 }), K.A_holder, { evidence: ev1.evidence }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['subject-mismatch'] })
const ev2bad = taskEvidence({ principal: P.A, agentP: P.B, principalKey: K.A_holder, agentSignerKey: K.A_holder, mandateOver: { nonce: '9' } })
add('task evidence: the delivery is not signed by the agent (principal forged it)', record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 5, issued: T + 92 }, ev2bad)), K.A_holder, { evidence: ev2bad.evidence }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-signature'] })
const ev2fund = taskEvidence({ principal: P.A, agentP: P.B, principalKey: K.A_holder, agentSignerKey: K.B_signer, mandateOver: { nonce: '10', feeCap: '1000' } })
add('task evidence: mandate breaks the phase-0 rule', record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 5, issued: T + 93 }, ev2fund)), K.A_holder, { evidence: ev2fund.evidence }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-malformed'] })
const ev2late = taskEvidence({ principal: P.A, agentP: P.B, principalKey: K.A_holder, agentSignerKey: K.B_signer, mandateOver: { nonce: '11' }, verdictIssued: T + 1000 })
add('task evidence: the review is issued before the verdict', record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 5, issued: T + 94 }, ev2late)), K.A_holder, { evidence: ev2late.evidence }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-time'] })
add('task evidence cited by a third party (C is neither principal nor agent)', record(review(withEvidence({ reviewer: P.C, reviewee: P.B, score: 5, issued: T + 95 }, ev2)), K.C_holder, { evidence: ev2.evidence }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-wrong-party'] })


// added after the first review of the draft
const textW = { body: 'kept between us', tags: ['slow'] }
const ev1w = responseEvidence({ service: P.B, signerKey: K.B_signer, id: L.reviewRequestId(P.A.container, nonce(11)), ts: T - 900 })
add('level 1 with text withheld (counted; only the text hash is published)', record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 3, textHash: L.jsonHash(textW), issued: T + 5 }, ev1w)), K.A_holder, { evidence: ev1w.evidence }), { valid: true, level: 1, signedBy: 'holder', counted: true, problems: [], textWithheld: true })
add('withdrawal of a level-0 review (subject zero)', record(review({ reviewer: P.A, reviewee: P.B, kind: 2, score: 0, issued: T - 99 }), K.A_holder), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: [] })
add('evidence present while evidenceHash is zero: ignored, level 0', record(review({ reviewer: P.C, reviewee: P.B, score: 4, issued: T - 40 }), K.C_holder, { evidence: ev1x.evidence }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: [] })
const evV1 = { kind: 'response', receipt: ev1.full }
add('level 1: the full receipt (v 1) instead of the hash-only form', record(review({ reviewer: P.A, reviewee: P.B, score: 5, subject: ev1.subject, evidenceHash: L.jsonHash(evV1), issued: T + 73 }), K.A_holder, { evidence: evV1 }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-malformed'] })
add('level 2: subject is another mandate\'s hash', record(review({ reviewer: P.A, reviewee: P.B, score: 4, subject: ev2r.subject, evidenceHash: L.jsonHash(ev2.evidence), issued: T + 96 }), K.A_holder, { evidence: ev2.evidence }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['subject-mismatch'] })
const ev2ms = taskEvidence({ principal: P.A, agentP: P.B, principalKey: K.A_holder, agentSignerKey: K.B_signer, mandateKey: K.stranger, mandateOver: { nonce: '12' } })
add('level 2: the mandate is not signed by the principal\'s holder', record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 4, issued: T + 97 }, ev2ms)), K.A_holder, { evidence: ev2ms.evidence }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-signature'] })
const ev2vs = taskEvidence({ principal: P.A, agentP: P.B, principalKey: K.A_holder, agentSignerKey: K.B_signer, verdictKey: K.A_delegate, mandateOver: { nonce: '13' } })
add('level 2: the verdict is signed by the principal\'s delegate, not its holder', record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 4, issued: T + 98 }, ev2vs)), K.A_holder, { evidence: ev2vs.evidence }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-signature'] })
const ev2vm = taskEvidence({ principal: P.A, agentP: P.B, principalKey: K.A_holder, agentSignerKey: K.B_signer, mandateOver: { nonce: '14' }, verdictOver: { mandateHash: ev2.subject } })
add('level 2: the verdict names another mandate', record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 4, issued: T + 99 }, ev2vm)), K.A_holder, { evidence: ev2vm.evidence }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['verdict-mismatch'] })
const ev2w = taskEvidence({ principal: P.A, agentP: P.B, principalKey: K.A_holder, agentSignerKey: K.B_signer, mandateOver: { nonce: '15' }, deliverTs: T - 86400 - 1 })
add('level 2: the delivery is before the mandate\'s notBefore', record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 4, issued: T + 99 }, ev2w)), K.A_holder, { evidence: ev2w.evidence }), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: ['evidence-time'] })
const ev2k = taskEvidence({ principal: P.A, agentP: P.B, principalKey: K.A_holder, agentSignerKey: K.B_signer, mandateOver: { nonce: '16', agentKey: K.A_holder.address } })
add('level 2: the mandate\'s agentKey is the principal\'s holder (related parties)', record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 5, issued: T + 99 }, ev2k)), K.A_holder, { evidence: ev2k.evidence }), { valid: true, level: 2, signedBy: 'holder', counted: false, problems: ['related-parties'] })
const R_STRANGER_WITHDRAW = record(review({ reviewer: P.A, reviewee: P.B, kind: 2, score: 0, subject: ev1.subject, issued: T + 150 }), K.stranger)
add('a stranger signs a withdrawal of A\'s review (shown as not current, never withdraws)', R_STRANGER_WITHDRAW, { valid: true, level: 0, signedBy: null, counted: false, problems: ['signer-not-current'] })
const R_STRANGER_CONFLICT = record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 1, textHash: L.jsonHash(text1), issued: T }, ev1)), K.stranger, { text: text1, evidence: ev1.evidence })
add('a stranger signs another review with the same key and issued as A\'s (never a conflict)', R_STRANGER_CONFLICT, { valid: true, level: 1, signedBy: null, counted: false, problems: ['signer-not-current'] })
const R_DELEGATE_WITHDRAW = record(review({ reviewer: P.A, reviewee: P.B, kind: 2, score: 0, subject: ev1.subject, issued: T + 101 }), K.A_delegate)
add('the delegate withdraws a review the holder signed', R_DELEGATE_WITHDRAW, { valid: true, level: 0, signedBy: 'delegate', counted: false, problems: [] })
const R_CORRECTION = record(review(withEvidence({ reviewer: P.A, reviewee: P.B, score: 2, issued: T + 1 }, ev1)), K.A_holder, { evidence: ev1.evidence })
add('a correction of A\'s first review (same subject, later issued, score 2)', R_CORRECTION, { valid: true, level: 1, signedBy: 'holder', counted: true, problems: [] })
const longSig = (rv, pk) => L.signReview(rv, pk) + '00'
add('a 66-byte signature, holder without code (no EIP-1271 to try)', { review: R_L0.review, text: text1, sig: longSig(R_L0.review, K.A_holder.privateKey) }, { valid: true, level: 0, signedBy: null, counted: false, problems: ['signer-not-current'] })
const evF = responseEvidence({ service: P.B, signerKey: K.B_signer, id: L.reviewRequestId(P.F.container, nonce(12)) })
const R_F = review(withEvidence({ reviewer: P.F, reviewee: P.B, score: 5, issued: T + 30 }, evF))
add('a contract holder\'s signature, verifier declines EIP-1271', { review: R_F, sig: '0x' + 'ab'.repeat(97), evidence: evF.evidence }, { valid: true, level: 1, signedBy: null, counted: false, problems: ['holder-signature-unsupported'] })

// invalid records (rejected, not shown)
function signLoose(rv, pk) { // signs whatever fields are there, so that only the form check fails
  const types = ['bytes32', 'bytes32', 'bytes32', 'uint8', 'uint8', 'bytes32', 'bytes32', 'bytes32', 'uint64']
  const hx = (x) => abi.hexToBytes(String(x).toLowerCase())
  const sh = keccak_256(abi.encodeParams(types, [hx(L.REVIEW_TYPEHASH), hx(rv.reviewer), hx(rv.reviewee), Number(rv.kind) & 255, Number(rv.score) & 255, hx(rv.subject), hx(rv.evidenceHash), hx(rv.textHash), BigInt(rv.issued)]))
  return sig.signDigest(sig.typedDigest(sig.delegationDomain(56, HUB), sh), pk)
}
const mut = (f) => { const r = clone(R_L0); f(r.review); r.sig = signLoose(r.review, K.A_holder.privateKey); return r }
add('score 6', mut((r) => { r.score = 6 }), { valid: false, problems: ['record-malformed'] })
add('score 0 in a review', mut((r) => { r.score = 0 }), { valid: false, problems: ['record-malformed'] })
add('kind 3 (reserved)', mut((r) => { r.kind = 3 }), { valid: false, problems: ['record-malformed'] })
add('withdrawal with a score', mut((r) => { r.kind = 2; r.score = 3 }), { valid: false, problems: ['record-malformed'] })
add('subject without evidenceHash', mut((r) => { r.subject = ev1.subject }), { valid: false, problems: ['record-malformed'] })
add('upper-case hex in textHash', mut((r) => { r.textHash = r.textHash.toUpperCase().replace('0X', '0x') }), { valid: false, problems: ['record-malformed'] })
add('reviewee endpoint with non-zero top bytes', mut((r) => { r.reviewee = '0x00000001' + r.reviewee.slice(10) }), { valid: false, problems: ['record-malformed'] })
add('reviewee on a chain outside the TAP-10 chain table (chainId 1)', record(review({ reviewer: P.A, reviewee: { endpoint: L.endpointId(1, P.B.container) } }), K.A_holder), { valid: false, problems: ['unsupported-chain'] })
add('self-review (reviewer equals reviewee)', record(review({ reviewer: P.B, reviewee: P.B, score: 5 }), K.B_holder), { valid: false, problems: ['self-review'] })
add('issued more than 300 s in the future', record(review({ reviewer: P.A, reviewee: P.B, issued: NOW + 301 }), K.A_holder), { valid: false, problems: ['issued-in-future'] })
add('issued exactly 300 s in the future (accepted)', record(review({ reviewer: P.A, reviewee: P.B, issued: NOW + 300 }), K.A_holder), { valid: true, level: 0, signedBy: 'holder', counted: false, problems: [] })
add('text does not match textHash', { ...clone(R_L0), text: { ...text1, body: text1.body + '!' } }, { valid: false, problems: ['text-mismatch'] })
add('text present while textHash is zero', record(review({ reviewer: P.A, reviewee: P.B }), K.A_holder, { text: text1 }), { valid: false, problems: ['text-mismatch'] })
add('text with an invalid tag', (() => { const t = { body: 'x', tags: ['Fast'] }; return record(review({ reviewer: P.A, reviewee: P.B, textHash: L.jsonHash(t) }), K.A_holder, { text: t }) })(), { valid: false, problems: ['text-mismatch'] })
// high-s: s' = n - s, v flipped; recovers to the same address but MUST be rejected
const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n
const highS = (s) => { const b = s.slice(2); const S = N - BigInt('0x' + b.slice(64, 128)); const v = parseInt(b.slice(128), 16) === 27 ? 28 : 27; return '0x' + b.slice(0, 64) + S.toString(16).padStart(64, '0') + v.toString(16) }
add('high-s reviewer signature', { ...clone(R_L0), sig: highS(R_L0.sig) }, { valid: false, problems: ['record-signature'] })

// ---------------------------------------------------------------- summary ----
// every record above about B, plus two conflicting records (same key, same issued)
const conflictA = record(review({ reviewer: P.C, reviewee: P.B, score: 5, issued: T + 200 }), K.C_holder)
const conflictB = record(review({ reviewer: P.C, reviewee: P.B, score: 1, issued: T + 200 }), K.C_holder)
const summaryNames = cases.filter((c) => !c.facts && c.record.review?.reviewee === P.B.endpoint).map((c) => c.name)
const summaryRecords = [...cases.filter((c) => summaryNames.includes(c.name)).map((c) => c.record), conflictA, conflictB]

// ---------------------------------------------------------------- verify + assemble ----
let fail = 0
const factsFor = (c) => ({ holders: { ...facts.holders, ...(c.facts?.holders ?? {}) }, signers: { ...facts.signers, ...(c.facts?.signers ?? {}) }, contracts: facts.contracts })
for (const c of cases) {
  const got = L.verifyRecord(c.record, factsFor(c), { now: NOW })
  for (const k of Object.keys(c.expect)) {
    if (JSON.stringify(got[k]) !== JSON.stringify(c.expect[k])) { fail++; console.error(`FAIL ${c.name}: ${k} got ${JSON.stringify(got[k])} want ${JSON.stringify(c.expect[k])}`) }
  }
  c.expect = { ...c.expect, hash: got.hash }
  if (!c.expect.valid) delete c.expect.hash
}
const summarize = (records) => L.summarize(records.map((record) => ({ record, result: L.verifyRecord(record, facts, { now: NOW }) })), (e) => facts.holders[e])
const none = { reviewers: 0, holders: 0, scores: [0, 0, 0, 0, 0], issued: null }
// main: A's latest counted current record is L2 (level 2, score 4, T+40): L2_REJ (T+45) is no longer current, because
// the holder later signed another record with the same subject (the subject-mismatch case at T+96), which replaces it
// although its own evidence fails. C's is X_CHAIN (level 1, score 4, T+30);
// C's level-0 key has a conflict at T+200 (dropped); D is related (one uncounted pair); F's record is not accepted
// (holder-signature-unsupported), so F has no pair; strangers' records take no part.
const want = { level1: { reviewers: 1, holders: 1, scores: [0, 0, 0, 1, 0], issued: [T + 30, T + 30] }, level2: { reviewers: 1, holders: 1, scores: [0, 0, 0, 1, 0], issued: [T + 40, T + 40] }, uncountedPairs: 1, conflicts: 1 }
const one = (score, t) => ({ reviewers: 1, holders: 1, scores: [1, 2, 3, 4, 5].map((x) => (x === score ? 1 : 0)), issued: [t, t] })
const scenarios = [
  { name: 'every case about B, with two conflicting records of C', records: summaryRecords, expect: want, cases: summaryNames, extra: [conflictA, conflictB] },
  { name: 'a stranger\'s withdrawal does not withdraw', records: [R_L1, R_STRANGER_WITHDRAW], expect: { level1: one(5, T), level2: none, uncountedPairs: 0, conflicts: 0 } },
  { name: 'a stranger\'s record with the same key and issued is not a conflict', records: [R_L1, R_STRANGER_CONFLICT], expect: { level1: one(5, T), level2: none, uncountedPairs: 0, conflicts: 0 } },
  { name: 'the delegate withdraws a review the holder signed', records: [R_L1, R_DELEGATE_WITHDRAW], expect: { level1: none, level2: none, uncountedPairs: 0, conflicts: 0 } },
  { name: 'a correction replaces the earlier score', records: [R_L1, R_CORRECTION], expect: { level1: one(2, T + 1), level2: none, uncountedPairs: 0, conflicts: 0 } },
  { name: 'two records the holder signed with the same key and issued conflict', records: [conflictA, conflictB, R_X_CHAIN], expect: { level1: one(4, T + 30), level2: none, uncountedPairs: 0, conflicts: 1 } },
]
for (const sc of scenarios) {
  const got = summarize(sc.records)
  if (JSON.stringify(got) !== JSON.stringify(sc.expect)) { fail++; console.error(`FAIL summary "${sc.name}"`, JSON.stringify(got), 'want', JSON.stringify(sc.expect)) }
}
if (fail) { console.error(`${fail} failure(s); nothing written`); process.exit(1) }

const TAP11_BNB_DOMAIN = '0xa73ee348b5672f12dbc174f66a7d162c69e0d64befdba88475d9d7e3c0fd3ac7'
const dom56 = abi.toHex(sig.domainSeparator(sig.delegationDomain(56, HUB)))
if (dom56 !== TAP11_BNB_DOMAIN) { console.error('domain separator differs from TAP-11 Test Cases'); process.exit(1) }

const out = {
  description: 'Test vectors for TAP-draft-container-reviews. Chain facts (current holders and current TAP-11 signers) are given as inputs, as a verifier would read them under TAP-10 §5. The private keys are published test keys: keccak256("tap-reviews/test-key/<label>"). Never use them for anything else.',
  note: 'Generated by make-vectors.mjs with the EIP-712, TAP-13 and canonical-JSON code of TapeAPI at commit 4a1ac4fe2a0b2e3327652a794794765dd5da98ef (public, 1.8.1: sdk/src/sig.js, sdk/src/agent-sig.js, sdk/src/mcp.js, sdk/src/canon.js) and the prototype verifier reviews-lib.mjs. check-vectors.mjs recomputes every hash, type hash, domain separator and signature recovery without that code; it applies the rules with the same prototype. Container addresses are arbitrary test values; nothing here was read from a chain. No case uses EIP-1271: the one contract holder only shows the result of a verifier that declines it.',
  constants: {
    REVIEW_TYPE: L.REVIEW_TYPE, REVIEW_TYPEHASH: L.REVIEW_TYPEHASH, hub: HUB,
    domainSeparator: Object.fromEntries(L.CHAINS.map((c) => [c, abi.toHex(sig.domainSeparator(sig.delegationDomain(c, HUB)))])),
    ID_PREFIX: L.ID_PREFIX, MAX_EVIDENCE_AGE_S: L.MAX_EVIDENCE_AGE_S, ISSUED_SKEW_S: L.ISSUED_SKEW_S,
    MANDATE_TYPE: agent.MANDATE_TYPE, MANDATE_TYPEHASH: abi.toHex(agent.MANDATE_TYPEHASH), SCOPE_TYPEHASH: abi.toHex(agent.SCOPE_TYPEHASH),
    TASK_VERDICT_TYPE: agent.TASK_VERDICT_TYPE, TASK_VERDICT_TYPEHASH: abi.toHex(agent.TASK_VERDICT_TYPEHASH), chains: L.CHAINS,
  },
  keys: K, parties: P, now: NOW, facts,
  examples: {
    'level-1 evidence, the full receipt the reviewer kept (not published; its hash-only form is the evidence)': ev1.full,
    'level-2 evidence, the task object whose hash is the mandate taskHash': ev2.task,
    'level-2 evidence, the deliverable whose hash is deliverableHash': ev2.deliverable,
  },
  cases,
  summaries: {
    reviewee: P.B.endpoint,
    description: 'Summaries of §7 and §9 with the top-level facts. The first lists the case names it uses (`cases`) and two further records (`extra`); the others give their records.',
    scenarios: scenarios.map((sc) => (sc.cases ? { name: sc.name, cases: sc.cases, extra: sc.extra, expect: sc.expect } : { name: sc.name, records: sc.records, expect: sc.expect })),
  },
}
const text = JSON.stringify(out, null, 2) + '\n'
if (process.argv.includes('--check')) {
  const old = readFileSync(OUT, 'utf8')
  if (old !== text) { console.error('reviews.json differs from a fresh generation'); process.exit(1) }
  console.log(`reviews.json is up to date (${cases.length} cases)`)
} else {
  writeFileSync(OUT, text)
  console.log(`wrote reviews.json: ${cases.length} cases, summary over ${summaryRecords.length} records`)
}
