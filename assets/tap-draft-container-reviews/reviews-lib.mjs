// Prototype verifier for TAP-draft-container-reviews (MIT License). It is not a reference implementation.
//
// It builds review records with the TapeAPI SDK (EIP-712 in the TAP-11 domain, the TAP-13 response digest, canonical
// JSON and the Mandate and TaskVerdict types of draft #47) and checks them OFFLINE: what a verifier would read from the
// chain (current holders, current TAP-11 signers, whether a holder has code) is passed in as `facts`. It accepts only
// 65-byte ECDSA signatures; a verifier that declines EIP-1271, as this one does, reports `holder-signature-unsupported`.
//
// The SDK is TapeAPI at commit 4a1ac4fe2a0b2e3327652a794794765dd5da98ef (public, 1.8.1) or later, with its dependencies
// installed. Point TAPEAPI_ROOT at a checkout of it:
//   git clone https://github.com/BruceLanLan/tapeapi && cd tapeapi && git checkout 4a1ac4fe2a0b2e3327652a794794765dd5da98ef && npm ci
//   TAPEAPI_ROOT=/path/to/tapeapi node check-vectors.mjs
import { createRequire } from 'node:module'
import { existsSync } from 'node:fs'
import { resolve } from 'node:path'
import { pathToFileURL, fileURLToPath } from 'node:url'

const DEFAULT_ROOT = new URL('../../../../../', import.meta.url)
export const ROOT = process.env.TAPEAPI_ROOT ? pathToFileURL(resolve(process.env.TAPEAPI_ROOT) + '/') : DEFAULT_ROOT
if (!existsSync(fileURLToPath(new URL('sdk/src/sig.js', ROOT)))) {
  console.error('Set TAPEAPI_ROOT to a checkout of TapeAPI (commit 4a1ac4fe2a0b2e3327652a794794765dd5da98ef or later) with its dependencies installed.')
  process.exit(2)
}
const req = createRequire(new URL('package.json', ROOT))
/** Import a dependency (for example '@noble/hashes/sha3') as installed in the TapeAPI checkout. */
export const dep = (name) => import(pathToFileURL(req.resolve(name)).href)
const { keccak_256 } = await dep('@noble/hashes/sha3')
const { utf8ToBytes } = await dep('@noble/hashes/utils')
export const sig = await import(new URL('sdk/src/sig.js', ROOT))
export const abi = await import(new URL('sdk/src/abi.js', ROOT))
export const agent = await import(new URL('sdk/src/agent-sig.js', ROOT))
export const { canonicalJSON } = await import(new URL('sdk/src/canon.js', ROOT))

export const HUB = '0xe61A9C7213a6Aa616C246a2B569e555B417b25ee'
export const CHAINS = [56, 8453, 196]            // the TAP-10 §2.1 chain table
export const REVIEW_TYPE = 'Review(bytes32 reviewer,bytes32 reviewee,uint8 kind,uint8 score,bytes32 subject,bytes32 evidenceHash,bytes32 textHash,uint64 issued)'
export const REVIEW_TYPEHASH = abi.toHex(keccak_256(utf8ToBytes(REVIEW_TYPE)))
export const KIND_REVIEW = 1
export const KIND_WITHDRAWAL = 2
export const ID_PREFIX = 'tape-review:'
export const MAX_EVIDENCE_AGE_S = 7_776_000      // 90 days
export const ISSUED_SKEW_S = 300
export const MAX_BODY_CODE_POINTS = 2000
export const MAX_TAGS = 8
export const ZERO32 = '0x' + '00'.repeat(32)
const HASH_RE = /^0x[0-9a-f]{64}$/
const WORD_RE = /^[a-z0-9][a-z0-9._/-]{0,63}$/
const SIG65_RE = /^0x[0-9a-fA-F]{130}$/
const SIGANY_RE = /^0x([0-9a-fA-F]{2}){65,1024}$/
const MAX_SAFE = Number.MAX_SAFE_INTEGER

export class Problem extends Error { constructor(code, msg) { super(msg ?? code); this.code = code } }
const bad = (code, msg) => { throw new Problem(code, msg) }
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v)
const lc = (a) => String(a).toLowerCase()
const eq = (a, b) => typeof a === 'string' && typeof b === 'string' && lc(a) === lc(b)
export const jsonHash = (v) => abi.toHex(keccak_256(utf8ToBytes(canonicalJSON(v))))

// ---------- endpoint IDs (TAP-10 §12.1) ----------
export function endpointId(chainId, container) {
  if (!Number.isSafeInteger(chainId) || chainId <= 0) throw new Error('chainId')
  return '0x' + '00000000' + BigInt(chainId).toString(16).padStart(16, '0') + lc(container).slice(2)
}
export function parseEndpoint(e) {
  if (typeof e !== 'string' || !HASH_RE.test(e)) bad('record-malformed', 'endpoint must be 0x and 64 lower-case hex digits')
  if (e.slice(2, 10) !== '00000000') bad('record-malformed', 'endpoint top 4 bytes must be zero')
  const chainId = BigInt('0x' + e.slice(10, 26)), container = '0x' + e.slice(26)
  if (chainId === 0n || chainId > BigInt(MAX_SAFE)) bad('record-malformed', 'endpoint chainId out of range')
  if (/^0x0{40}$/.test(container)) bad('record-malformed', 'endpoint container is zero')
  return { chainId: Number(chainId), container }
}

// ---------- the Review type ----------
export function normalizeReview(r) {
  if (!isObj(r)) bad('record-malformed', 'review must be an object')
  for (const k of ['reviewer', 'reviewee', 'kind', 'score', 'subject', 'evidenceHash', 'textHash', 'issued']) if (!(k in r)) bad('record-malformed', `review.${k} missing`)
  parseEndpoint(r.reviewer); parseEndpoint(r.reviewee)
  for (const k of ['subject', 'evidenceHash', 'textHash']) if (typeof r[k] !== 'string' || !HASH_RE.test(r[k])) bad('record-malformed', `review.${k} must be 0x and 64 lower-case hex digits`)
  if (!Number.isSafeInteger(r.issued) || r.issued < 0) bad('record-malformed', 'review.issued must be an integer 0..2^53-1')
  if (r.kind === KIND_REVIEW) {
    if (!Number.isInteger(r.score) || r.score < 1 || r.score > 5) bad('record-malformed', 'a review has score 1..5')
    if ((r.subject === ZERO32) !== (r.evidenceHash === ZERO32)) bad('record-malformed', 'subject and evidenceHash are both zero or both non-zero')
  } else if (r.kind === KIND_WITHDRAWAL) {
    if (r.score !== 0) bad('record-malformed', 'a withdrawal has score 0')
    if (r.evidenceHash !== ZERO32) bad('record-malformed', 'a withdrawal has evidenceHash zero')
  } else bad('record-malformed', 'kind must be 1 or 2')
  return { reviewer: r.reviewer, reviewee: r.reviewee, kind: r.kind, score: r.score, subject: r.subject, evidenceHash: r.evidenceHash, textHash: r.textHash, issued: r.issued }
}
export function hashReview(r) {
  const n = normalizeReview(r)
  return keccak_256(abi.encodeParams(['bytes32', 'bytes32', 'bytes32', 'uint8', 'uint8', 'bytes32', 'bytes32', 'bytes32', 'uint64'],
    [abi.hexToBytes(REVIEW_TYPEHASH), abi.hexToBytes(n.reviewer), abi.hexToBytes(n.reviewee), n.kind, n.score, abi.hexToBytes(n.subject), abi.hexToBytes(n.evidenceHash), abi.hexToBytes(n.textHash), BigInt(n.issued)]))
}
/** The domain's chainId is the reviewer's chain, read from the reviewer endpoint ID (unless `chainId` overrides it). */
export function reviewDigest(r, { hub = HUB, chainId } = {}) {
  const c = chainId ?? parseEndpoint(r.reviewer).chainId
  return sig.typedDigest(sig.delegationDomain(c, hub), hashReview(r))
}
export const reviewHashOf = (r, o) => abi.toHex(reviewDigest(r, o))
export const signReview = (r, pk, o) => sig.signDigest(reviewDigest(r, o), pk)

// ---------- text ----------
export function textProblem(t) {
  if (!isObj(t)) return 'text must be an object'
  if (typeof t.body !== 'string') return 'text.body must be a string'
  if ([...t.body].length > MAX_BODY_CODE_POINTS) return 'text.body is too long'
  if (t.tags !== undefined) {
    if (!Array.isArray(t.tags) || t.tags.length > MAX_TAGS) return 'text.tags must be an array of at most 8 words'
    if (!t.tags.every((w) => typeof w === 'string' && WORD_RE.test(w))) return 'a tag is not a word'
    if (new Set(t.tags).size !== t.tags.length) return 'tags repeat'
  }
  try { canonicalJSON(t) } catch { return 'text has no canonical form' }
  return null
}

// ---------- evidence ----------
export const reviewRequestId = (reviewerContainer, nonceHex) => `${ID_PREFIX}${lc(reviewerContainer)}:${nonceHex}`
const tsOk = (t) => Number.isSafeInteger(t) && t >= 0
function hashOnlyReceiptForm(r) {
  return isObj(r) && r.v === 2 && isObj(r.service) && abi.isAddress(r.service.container) && typeof r.method === 'string' &&
    typeof r.requestHash === 'string' && HASH_RE.test(r.requestHash) && typeof r.bodyHash === 'string' && HASH_RE.test(r.bodyHash) &&
    typeof r.id === 'string' && r.id.length >= 1 && r.id.length <= 128 && tsOk(r.ts) &&
    typeof r.ok === 'boolean' && typeof r.sig === 'string' && SIG65_RE.test(r.sig)
}
function deliverReceiptForm(r) {
  return isObj(r) && r.v === 1 && isObj(r.service) && abi.isAddress(r.service.container) && typeof r.method === 'string' &&
    (r.params === undefined || isObj(r.params)) && typeof r.id === 'string' && r.id.length >= 1 && r.id.length <= 128 &&
    tsOk(r.ts) && r.ok === true && isObj(r.result) && typeof r.sig === 'string' && SIG65_RE.test(r.sig)
}
function recovers(digest, s, want) { try { return want != null && eq(sig.recoverAddress(digest, s), want) } catch { return false } }

function responseEvidence(ev, rv, re, issued, F) {
  const r = ev.receipt
  if (!hashOnlyReceiptForm(r)) bad('evidence-malformed', 'receipt is not a hash-only receipt (v 2)')
  if (!eq(r.service.container, re.container)) bad('evidence-wrong-party', 'receipt is not from the reviewee')
  const prefix = ID_PREFIX + lc(rv.container) + ':'
  if (!r.id.startsWith(prefix) || r.id.length === prefix.length) bad('evidence-unbound', 'receipt id does not name the reviewer')
  const d = sig.responseDigestFromHashes({ container: re.container, id: r.id, requestHash: r.requestHash, ok: r.ok, bodyHash: r.bodyHash, ts: r.ts })
  return { level: 1, subject: abi.toHex(d), extra: {}, check() {
    if (!(r.ts <= issued && issued - r.ts <= MAX_EVIDENCE_AGE_S)) bad('evidence-time', 'receipt ts is after the review or more than 90 days before it')
    if (!recovers(sig.personalDigest(d), r.sig, F.signer(re))) bad('evidence-signature', 'receipt is not signed by the reviewee\'s current signer')
  } }
}

function taskEvidence(ev, rv, re, issued, F, hub) {
  let m, v
  try { m = agent.normalizeMandate(ev.mandate, { wire: true }); v = agent.normalizeTaskVerdict(ev.verdict, { wire: true }) } catch { bad('evidence-malformed', 'mandate or verdict malformed') }
  const d = ev.deliver
  if (!deliverReceiptForm(d) || typeof ev.mandateSig !== 'string' || !SIGANY_RE.test(ev.mandateSig) || typeof ev.verdictSig !== 'string' || !SIGANY_RE.test(ev.verdictSig)) bad('evidence-malformed', 'deliver receipt or signatures malformed')
  let principal, agentEp, agentIsReviewer
  if (eq(m.principal, rv.container) && eq(m.agent, re.container)) { principal = rv; agentEp = re; agentIsReviewer = false }
  else if (eq(m.principal, re.container) && eq(m.agent, rv.container)) { principal = re; agentEp = rv; agentIsReviewer = true }
  else bad('evidence-wrong-party', 'the mandate is not between reviewer and reviewee')
  const mandateHash = agent.mandateHashOf(principal.chainId, hub, m)
  return { level: 2, subject: mandateHash, extra: { agentKey: m.agentKey, agentIsReviewer }, check() {
    if (agent.phase0Problems(m).length || m.subdelegate) bad('evidence-malformed', 'mandate breaks the phase-0 rule')
    const res = d.result
    if (!eq(d.service.container, agentEp.container) || res.kind !== 'tape.agent/deliver' || res.mandateHash !== mandateHash ||
      typeof res.deliverableHash !== 'string' || !HASH_RE.test(res.deliverableHash)) bad('evidence-malformed', 'deliver does not name this agent and mandate')
    if (!(m.notBefore <= d.ts && d.ts <= m.expires && v.issued >= d.ts && issued >= v.issued)) bad('evidence-time', 'deliver outside the mandate, verdict before deliver, or review before verdict')
    if (v.mandateHash !== mandateHash || v.deliverableHash !== res.deliverableHash) bad('verdict-mismatch', 'verdict is about another mandate or delivery')
    const holder = F.holder(principal)
    // 65-byte ECDSA only in this prototype (a longer signature would need EIP-1271)
    if (!recovers(agent.mandateDigest(principal.chainId, hub, m), ev.mandateSig, holder)) bad('evidence-signature', 'mandate not signed by the principal\'s current holder')
    if (!recovers(agent.taskVerdictDigest(principal.chainId, hub, v), ev.verdictSig, holder)) bad('evidence-signature', 'verdict not signed by the principal\'s current holder')
    const dd = sig.responseDigest({ container: agentEp.container, id: d.id, method: d.method, params: d.params ?? {}, ok: true, body: res, ts: d.ts })
    if (!recovers(sig.personalDigest(dd), d.sig, F.signer(agentEp))) bad('evidence-signature', 'deliver not signed by the agent\'s current signer')
  } }
}

/**
 * Offline verification of one record (draft §6).
 * facts: { holders: { [endpointId]: address }, signers: { [endpointId]: address }, contracts: [address] }
 *   signers: an absent entry means the container does not resolve as a TAP-11 service;
 *   contracts: holders that have code (whose signatures would need EIP-1271).
 * Returns { valid, hash, level, signedBy, counted, problems[], textWithheld }. `valid` false: rejected (not shown).
 */
export function verifyRecord(rec, facts, { now, hub = HUB } = {}) {
  const out = { valid: false, hash: null, level: 0, signedBy: null, counted: false, problems: [], textWithheld: false }
  const F = {
    holder: (ep) => facts.holders?.[endpointId(ep.chainId, ep.container)] ?? null,
    signer: (ep) => facts.signers?.[endpointId(ep.chainId, ep.container)] ?? null,
    hasCode: (a) => a != null && (facts.contracts ?? []).some((c) => eq(c, a)),
  }
  try {
    // 1. form
    if (!isObj(rec)) bad('record-malformed', 'record must be an object')
    const r = normalizeReview(rec.review)
    if (typeof rec.sig !== 'string' || !SIGANY_RE.test(rec.sig)) bad('record-malformed', 'sig malformed')
    const rv = parseEndpoint(r.reviewer), re = parseEndpoint(r.reviewee)
    // 2. chains
    if (!CHAINS.includes(rv.chainId) || !CHAINS.includes(re.chainId)) bad('unsupported-chain')
    out.hash = reviewHashOf(r, { hub })
    // 3. self-review
    if (rv.chainId === re.chainId && eq(rv.container, re.container)) bad('self-review')
    // 4. time
    if (r.issued > now + ISSUED_SKEW_S) bad('issued-in-future')
    // 5. text
    if (r.textHash === ZERO32) { if (rec.text !== undefined) bad('text-mismatch', 'text present but textHash is zero') }
    else if (rec.text === undefined) out.textWithheld = true
    else if (textProblem(rec.text) || jsonHash(rec.text) !== r.textHash) bad('text-mismatch')
    // 6. signature
    let who = null
    if (SIG65_RE.test(rec.sig)) {
      try { who = sig.recoverAddress(reviewDigest(r, { hub }), rec.sig) } catch { bad('record-signature', 'malformed or high-s signature') }
    }
    out.valid = true
    if (who && eq(who, F.holder(rv))) out.signedBy = 'holder'
    else if (who && eq(who, F.signer(rv))) out.signedBy = 'delegate'
    else if (F.hasCode(F.holder(rv))) out.problems.push('holder-signature-unsupported')   // this verifier declines EIP-1271
    else out.problems.push('signer-not-current')
    // 7. evidence (ignored when evidenceHash is zero)
    let extra = {}
    if (r.kind === KIND_REVIEW && r.subject !== ZERO32) {
      try {
        if (rec.evidence === undefined) bad('evidence-missing')
        if (!isObj(rec.evidence)) bad('evidence-malformed')
        let e
        try { e = jsonHash(rec.evidence) } catch { bad('evidence-malformed', 'evidence has no canonical form') }
        if (e !== r.evidenceHash) bad('evidence-mismatch')
        const ev = rec.evidence
        const h = ev.kind === 'response' ? responseEvidence(ev, rv, re, r.issued, F)
          : ev.kind === 'task' ? taskEvidence(ev, rv, re, r.issued, F, hub)
            : bad('evidence-unknown')
        if (h.subject !== r.subject) bad('subject-mismatch')
        h.check()
        out.level = h.level; extra = h.extra
      } catch (e) { if (!(e instanceof Problem)) throw e; out.problems.push(e.code) }
    }
    // 8. related parties (the agent key of a level-2 mandate counts as an address of the agent)
    const a = [F.holder(rv), F.signer(rv)], b = [F.holder(re), F.signer(re)]
    if (out.level === 2) (extra.agentIsReviewer ? a : b).push(extra.agentKey)
    const A = a.filter(Boolean).map(lc), B = b.filter(Boolean).map(lc)
    if (A.some((x) => B.includes(x))) out.problems.push('related-parties')
    out.counted = r.kind === KIND_REVIEW && out.signedBy !== null && out.level > 0 && !out.problems.includes('related-parties')
  } catch (e) {
    if (!(e instanceof Problem)) throw e
    out.valid = false; out.level = 0; out.signedBy = null; out.counted = false; out.problems.push(e.code)
  }
  return out
}

/**
 * Summary for one reviewee (draft §7 and §9). items: [{ record, result }] with result from verifyRecord.
 * Only records signed by the holder or the delegate take part in §7: a record reported `signer-not-current` or
 * `holder-signature-unsupported` is never current, never corrects or withdraws, and never causes a conflict.
 * holderOf(endpointId) gives a reviewer's current holder (for counting distinct holders).
 */
export function summarize(items, holderOf) {
  const accepted = items.filter((x) => x.result.valid && x.result.signedBy !== null)
  const conflicts = []
  const byKey = new Map()
  for (const x of accepted) {
    const r = x.record.review, k = `${r.reviewer}|${r.reviewee}|${r.subject}`
    if (!byKey.has(k)) byKey.set(k, [])
    // several copies of one review hash are one record: keep the copy counted, else at the highest level, else with text
    const rank = (y) => (y.result.counted ? 8 : 0) + y.result.level * 2 + (y.record.text !== undefined ? 1 : 0)
    const list = byKey.get(k), i = list.findIndex((y) => y.result.hash === x.result.hash)
    if (i < 0) list.push(x); else if (rank(x) > rank(list[i])) list[i] = x
  }
  const current = []
  for (const [k, list] of byKey) {
    const top = Math.max(...list.map((x) => x.record.review.issued))
    const best = list.filter((x) => x.record.review.issued === top)
    if (best.length > 1) { conflicts.push(k); continue }
    if (best[0].record.review.kind === KIND_REVIEW) current.push(best[0])
  }
  const pairs = new Map()
  for (const x of current) {
    const r = x.record.review, k = `${r.reviewer}|${r.reviewee}`
    if (!pairs.has(k)) pairs.set(k, [])
    pairs.get(k).push(x)
  }
  const levels = { 1: [], 2: [] }
  let uncountedPairs = 0
  for (const [, list] of pairs) {
    const c = list.filter((x) => x.result.counted)
    if (!c.length) { uncountedPairs++; continue }
    c.sort((p, q) => (q.record.review.issued - p.record.review.issued) || (q.result.hash > p.result.hash ? 1 : -1))
    levels[c[0].result.level].push(c[0])
  }
  const stats = (list) => ({
    reviewers: new Set(list.map((x) => x.record.review.reviewer)).size,
    holders: new Set(list.map((x) => lc(holderOf(x.record.review.reviewer)))).size,
    scores: [1, 2, 3, 4, 5].map((s) => list.filter((x) => x.record.review.score === s).length),
    issued: list.length ? [Math.min(...list.map((x) => x.record.review.issued)), Math.max(...list.map((x) => x.record.review.issued))] : null,
  })
  return { level1: stats(levels[1]), level2: stats(levels[2]), uncountedPairs, conflicts: conflicts.length }
}
