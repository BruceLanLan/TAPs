---
tap: TBD
title: Evidence-Backed Reviews between Containers
description: A review record that one circuit container signs about another, with a score, optional text and optional evidence of an interaction (a signed answer or an accepted task), and the rules by which a client verifies it and counts it.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/41
status: Draft
type: Application
created: 2026-10-08
requires: TAP-10, TAP-11, TAP-13
license: CC0-1.0
---

# TAP-TBD: Evidence-Backed Reviews between Containers

## Summary

A way for the owner of one TapeOut circuit to publish a signed review of another circuit's service or agent, tied where possible to a call or a task that really happened, so that anyone can check who said it and what backs it.

## Abstract

This TAP defines a **review record**: an EIP-712 statement, in the domain of TAP-11 §4.1, by which a **reviewer** container gives a **reviewee** container a score from 1 to 5, optionally with text, and optionally with **evidence** of an interaction between the two. Two kinds of evidence are defined: a signed answer of the reviewee under TAP-13 whose request id names the reviewer (level 1), and a task between the two in the format of the container-agent draft of pull request #47 of the TAPs repository, with the agent's signed delivery and the principal holder's signed mandate and verdict (level 2). A record without evidence (level 0) is valid and can be shown, but is never counted. The TAP specifies the record, its signature by the reviewer's current holder or delegated signer, its verification, withdrawal and correction, two ways of carrying it (a file in the reviewer's site and a public TapeSend message) with what each makes public, and the rules a client follows when it summarises reviews. It builds on TAP-13 and on draft #47, not on the listing draft of pull request #49. It deploys no contract and changes no TAP. It is the review part of issue [#41](https://github.com/TapeOutProtocol/TAPs/issues/41), which the listing (#49) and task (#47) drafts left out.

## Motivation

Containers can now call each other's services with signed answers (TAP-13) and, under draft #47, hire each other as agents with signed mandates and verdicts. A container that wants to choose a service or an agent has no shared way to learn how others fared with it. Every directory or client that adds reviews invents a format, keeps the reviews on its own server, and becomes the party everyone has to trust.

Reviews whose authors are cheap to create are worth little: a review registry in which anyone can rate anyone is filled by coordinated accounts. On TapeOut an identity is a container, which costs an opened circuit, and every interaction that matters already leaves signed evidence. What is missing is an agreed record that binds a review to its author's container and to that evidence, an agreed order of checks so that two clients count the same reviews, and plain statements of what such a record proves and what it does not. Reputation built this way raises the cost of fraud; it proves nothing about quality, and this TAP says so.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms and notation

- **Circuit**, **container**, **holder**, **pinned block**, **strict agreement**, **endpoint ID**: as defined in TAP-10 §1 and §12.1. **Hub address**, **service**, **signer**: as defined in TAP-11 §1. **Envelope**, **request object**, **body**: as defined in TAP-13 §3 and §4.
- **Reviewer**, **reviewee**: the container that makes a review and the container it is about. Each is named by its endpoint ID, which carries its chain.
- **Delegate**: the signer of the reviewer's service, when the reviewer resolves under TAP-11 §2 with the outcome "resolved".
- **Task draft**: the draft "Container Agent Mandates and Task Messages, Phase 0" of pull request #47 of the TAPs repository, at commit `a95bc703cf32d7999aa51322adf1af8df88dd20f`. §4.3 restates every format and check of that draft that level 2 uses, so that level 2 can be verified from this text alone.
- **Holder signature** over a 32-byte digest: a signature checked against a container's holder exactly as TAP-11 §4.4 checks a delegation, with that digest (ECDSA, or EIP-1271 for a holder with code).
- **Verifier**: whoever checks a record under §6. `now` is the verifier's current Unix time in seconds.
- `keccak256`, `‖` and `utf8(s)` are as in TAP-13 §1; `canonicalJSON` is TAP-11 §6; `jsonHash(v)` is `keccak256(utf8(canonicalJSON(v)))`. A **word** is a string matching `^[a-z0-9][a-z0-9._/-]{0,63}$`. `ZERO` is 32 zero bytes.
- A **problem** is a named finding, written in `code font`. Problem names are descriptions, not wire values, and are only ever added.

### 2. The review record

#### 2.1 Type and digest

```
Review(bytes32 reviewer,bytes32 reviewee,uint8 kind,uint8 score,bytes32 subject,bytes32 evidenceHash,bytes32 textHash,uint64 issued)
REVIEW_TYPEHASH = 0xb9c66a727a6fba79714dcc4f0dfdbaf876840b1a35de576ed8fe3eef1f1b9a0b
```

| Field | Rule |
|---|---|
| `reviewer`, `reviewee` | Endpoint IDs (TAP-10 §12.1): the top 4 bytes zero, a non-zero chain ID of at most 2^53 − 1, a non-zero container |
| `kind` | `1` a review, `2` a withdrawal (§7). Other values are reserved for later TAPs |
| `score` | For `kind` 1, an integer from 1 to 5, 5 the best. For `kind` 2, `0` |
| `subject` | What the review is about: `ZERO` for no particular interaction, otherwise the identity of the interaction named by the evidence (§4) |
| `evidenceHash` | `jsonHash(evidence)` of the evidence object (§4), or `ZERO` for none. For `kind` 1, `subject` and `evidenceHash` are both `ZERO` or both non-zero. For `kind` 2, `ZERO` |
| `textHash` | `jsonHash(text)` of the text object (§3), or `ZERO` for none |
| `issued` | The time the reviewer states, in Unix seconds, from 0 to 2^53 − 1 |

The record is signed in the EIP-712 domain of TAP-11 §4.1, unchanged, with `chainId` the chain ID carried by `reviewer`:

```
structHash = keccak256(abi.encode(REVIEW_TYPEHASH, reviewer, reviewee, kind, score, subject, evidenceHash, textHash, issued))
digest     = keccak256(0x19 ‖ 0x01 ‖ DOMAIN_SEPARATOR ‖ structHash)
```

The **review hash** is `digest`, written as `0x` and 64 lowercase hex digits; it is the record's identity.

#### 2.2 JSON form

A record is a JSON object, parsed with the parser of TAP-13 §2, with these members; a verifier ignores members it does not know:

| Member | Required | Content |
|---|---|---|
| `review` | yes | An object with the eight fields of §2.1. `bytes32` values are strings of `0x` and 64 lowercase hex digits; `uint8` and `uint64` values are JSON numbers |
| `sig` | yes | `0x` and 65 to 1,024 bytes in hex: the signature of §5 |
| `text` | no | The text object (§3) |
| `evidence` | no | The evidence object (§4) |

### 3. Text

The text object is a JSON object with a member `body`, a string of at most 2,000 Unicode code points, and an optional member `tags`, an array of at most 8 distinct words. It has a canonical form under TAP-11 §6. Members not named here are hashed with the object and otherwise ignored.

When `textHash` is not `ZERO`, a record MAY leave out `text`; the text is then **withheld**, and only its hash is published. A record whose `text` is present while `textHash` is `ZERO`, or whose `text` breaks this section or does not hash to `textHash`, is rejected (§6).

### 4. Evidence

#### 4.1 Levels

| Level | Evidence | `subject` |
|---|---|---|
| 0 | None, or evidence that fails §4.2 or §4.3 | `ZERO`, or as claimed |
| 1 | `{ "kind": "response", "receipt": <hash-only receipt> }`: a signed answer of the reviewee to a request of the reviewer (§4.2) | The TAP-13 §5 digest of that answer |
| 2 | `{ "kind": "task", "mandate", "mandateSig", "deliver", "verdict", "verdictSig" }`: a task between the two (§4.3) | The mandate hash of that task |

Other values of `kind` are reserved for later TAPs. A verifier MUST treat evidence of a reserved kind as level 0 (`evidence-unknown`). When `evidenceHash` is `ZERO`, a verifier MUST ignore an `evidence` member and MUST NOT show it.

#### 4.2 Level 1: a signed answer

A **hash-only receipt** is an object with these members: `v` (`2`); `service`, an object whose `container` is the answering container (its other members are informative); `method`, the TAP-13 path segment, informative; `requestHash`, `keccak256(utf8(canonicalJSON(request object)))`; `id`, `ts`, `ok` and `sig`, the envelope's members (TAP-13 §4), with `ts` an integer from 0 to 2^53 − 1 and `sig` 65 bytes; `bodyHash`, `keccak256(utf8(canonicalJSON(body)))`; and optionally `block`, not checked. Hashes are in the `bytes32` form of §2.2.

A reviewer that intends to review a service SHOULD send its TAP-13 requests with an `id` of the form `tape-review:` ‖ its own container address in lowercase hex with `0x` ‖ `:` ‖ a random string of at least 16 characters from U+0021–U+007E, keeping the `id` within the 128 UTF-16 code units TAP-13 §3 allows. A provider MUST NOT treat the container named in such an `id` as the identity of the caller. The verifier checks the conditions below in this order; when one does not hold, it reports the problem named after it and stops, and the record is level 0:

1. The receipt has the form above: `evidence-malformed`.
2. `service.container` is the reviewee's container: `evidence-wrong-party`.
3. `id` begins with `tape-review:` ‖ the reviewer's container in lowercase hex ‖ `:` and is longer than that prefix: `evidence-unbound`.
4. The TAP-13 §5 digest rebuilt from the reviewee's container, `id`, `requestHash`, `ok`, `bodyHash` and `ts` equals `subject`: `subject-mismatch`.
5. `ts ≤ issued` and `issued − ts ≤ 7,776,000` (90 days): `evidence-time`.
6. The reviewee resolves under TAP-11 §2, and `sig` recovers under TAP-13 §5 to the signer of that resolution: `evidence-signature`.

A verifier checks a receipt later than its time, so it does not apply the `maxSkew` of TAP-13 §8 step 5. A receipt with `ok` `false` (a signed refusal) is valid evidence.

#### 4.3 Level 2: a task

The formats below are those of the task draft (its §3 and §7), restated here. The mandate and the verdict are EIP-712 structs in the domain of TAP-11 §4.1 with `chainId` the **principal's chain** (below); a struct's hash is its full typed digest, as in §2.1:

```
Mandate(address principal,address agent,address agentKey,uint8 mode,bytes32 taskHash,Scope[] scope,address feeToken,uint256 feeCap,uint64 notBefore,uint64 expires,uint256 nonce,bool subdelegate)Scope(address provider,address token,uint256 cap)
MANDATE_TYPEHASH = 0xf2121b841c65f4d74c6cd4a5f8de39d1aaec1060d147338e7a635ecc5bca8171
SCOPE_TYPEHASH   = 0xb16bb4dde6f01fa8f71521aeabb4ce63a0c9c7554fc6e9953718f9ee96191fbb
TaskVerdict(bytes32 mandateHash,bytes32 deliverableHash,uint8 verdict,bytes32 reasonHash,uint64 issued)
TASK_VERDICT_TYPEHASH = 0xdfd34037554f981271bc0b592c8389130df249ee45feb1a47f3706be5e8e33aa
```

- `scope` is encoded as `keccak256` of the concatenated struct hashes of its items (`keccak256("")` when empty), as EIP-712 encodes an array of structs. The **mandate hash** is the typed digest of `mandate`.
- JSON forms: an `address` is a string of `0x` and 40 hex digits, case not significant; a `bytes32` is `0x` and 64 lowercase hex digits; a `uint8` is a JSON number; a `uint64` is a JSON number from 0 to 2^53 − 1; a `uint256` is a decimal string of at most 78 digits without leading zeros, below 2^256; a `bool` is `true` or `false`; `scope` is an array of at most 16 objects `{ "provider", "token", "cap" }`. Every field is present. `mode` is `0` or `1`; `verdict` is `1` (accepted) or `2` (rejected); `principal`, `agent`, `agentKey` and every `provider` are non-zero; `expires` is greater than `notBefore`; `taskHash`, `mandateHash` and `deliverableHash` are non-zero.
- **Phase-0 rule**: every `scope[i].cap` and `feeCap` is `"0"`, every `scope[i].token` and `feeToken` is the zero address, and `subdelegate` is `false`.
- `deliver` is the agent's full receipt (not a hash-only receipt): an object with `v` (`1`); `service`, whose `container` is the answering container; `method` and `params` (an object, `{}` when absent), the TAP-13 path segment and parameters; `id`, `ts` and `sig` as in §4.2; `ok`, `true`; and `result`, an object with `kind` `"tape.agent/deliver"`, `mandateHash`, `deliverableHash` and other members the task draft defines. It verifies when `sig` recovers under TAP-13 §5, with the digest computed from `service.container`, `id`, the request object `{ "method": method, "params": params }`, `ok`, the canonical form of `result` and `ts`, to the agent's signer resolved under TAP-11 §2.
- `mandateSig` and `verdictSig` are `0x` and 65 to 1,024 bytes in hex.

The **principal** and the **agent** are the containers `mandate.principal` and `mandate.agent`; the principal's chain is the chain of whichever of reviewer and reviewee is the principal. The verifier checks the conditions below in this order; when one does not hold, it reports the problem named after it and stops, and the record is level 0:

1. `mandate`, `verdict`, `deliver`, `mandateSig` and `verdictSig` have the forms above: `evidence-malformed`.
2. The principal and the agent are the reviewer and the reviewee, in either order: `evidence-wrong-party`.
3. The mandate hash equals `subject`: `subject-mismatch`.
4. The mandate meets the phase-0 rule, and `deliver` names the agent as `service.container`, `"tape.agent/deliver"` as `result.kind`, `subject` as `result.mandateHash`, and a `bytes32` `result.deliverableHash`: `evidence-malformed`.
5. `mandate.notBefore ≤ deliver.ts ≤ mandate.expires`, `verdict.issued ≥ deliver.ts`, and `issued ≥ verdict.issued`: `evidence-time`.
6. `verdict.mandateHash` equals `subject` and `verdict.deliverableHash` equals `result.deliverableHash`: `verdict-mismatch`.
7. `mandateSig` and `verdictSig` are holder signatures of the principal's current holder over the mandate hash and the verdict's hash, and `deliver` verifies against the agent's current signer: `evidence-signature`.

Either verdict value is valid evidence. Neither the mandate's revocation nor its nonce is checked: a level-2 record shows that a task was delegated, delivered and judged, not that the mandate is still valid.

### 5. Signing

The reviewer's **current holder** or its **delegate** signs the digest of §2.1 itself, without the EIP-191 prefix, as TAP-11 §4.2 requires. A signature by the holder is a holder signature (§1). A signature by the delegate MUST be 65 bytes and is checked as TAP-11 §4.4 item 1 with the delegate in place of the holder. A verifier MUST NOT accept a signer from any other source, and MUST NOT accept a signature by an address that was the holder or the delegate at some earlier time but is not now. A verifier MAY decline EIP-1271, as TAP-11 §4.4 allows; it then reports a record whose holder has code and that the delegate did not sign as `holder-signature-unsupported`, not as `signer-not-current`.

A console that asks a holder or a delegate to sign a record SHOULD show, besides the typed data, the reviewee's on-chain name, the score, the evidence level and the text, since the typed data shows only endpoint IDs and hashes.

### 6. Verifying a record

A verifier resolves the reviewer and the reviewee under TAP-10 §4.3, each on the chain its endpoint ID carries, at one pinned block per chain (TAP-10 §5.3), with `ownerOf` and every EIP-1271 call under strict agreement (TAP-10 §5.2). Neither container needs to be opened or activated, and the site statuses of TAP-10 §6 do not apply to that resolution. The reviewer's delegate and the services of §4 are resolved under TAP-11 §2, which applies them: a reviewee whose service does not resolve (for example `unpaid`) cannot back level-1 evidence. A chain or node outcome (`unavailable`, `stale-block`, `wrong-chain`) makes the verification unavailable; it is never reported as a problem of the record. The identity outcomes `not-tapeout` and `no-such-token` (TAP-10 §4.4) reject the record.

The verifier MUST apply these steps in order. A **rejected** record MUST NOT be shown or counted.

1. The record has the form of §2.2 and the fields meet §2.1: otherwise rejected, `record-malformed`.
2. The chain of `reviewer` or of `reviewee` is not in the chain table of TAP-10 §2.1: rejected, `unsupported-chain`.
3. `reviewer` and `reviewee` name the same container on the same chain: rejected, `self-review`.
4. `issued > now + 300`: rejected, `issued-in-future`.
5. The text meets §3: otherwise rejected, `text-mismatch`.
6. A 65-byte `sig` that breaks the range rules of TAP-11 §4.4 item 1: rejected, `record-signature`. Otherwise the record is **shown**, and it is **signed by the holder** or **signed by the delegate** when §5 accepts it as such; when neither, the verifier reports `holder-signature-unsupported` or `signer-not-current` as §5 says. A record signed by the holder or by the delegate is **accepted**.
7. For `kind` 1 with a non-zero `subject`: when `evidence` is absent, `evidence-missing`; when it is not an object with a canonical form, `evidence-malformed`; when `jsonHash(evidence)` differs from `evidenceHash`, `evidence-mismatch`; otherwise §4.2 or §4.3 by its `kind`, which gives the level or a problem.
8. When any address among the reviewer's holder and delegate equals any address among the reviewee's holder and signer: `related-parties`. At level 2, the mandate's `agentKey` counts as an address of the agent.

A shown record is **counted** when its `kind` is 1, it is accepted, its level is 1 or 2, and `related-parties` was not reported. A verifier MUST report, with every result, the level, by whom the record is signed, whether it is counted, every problem, and whether its text is withheld.

### 7. Withdrawal and correction

Only accepted records take part in this section. A record reported `signer-not-current` or `holder-signature-unsupported` is never current, never corrects or withdraws another record, and never causes a conflict.

Accepted records are grouped by **key** `(reviewer, reviewee, subject)`. Records with the same review hash are one record; a verifier that holds several copies of it (for example a TapeSend copy without evidence and the full record from a site file) uses the copy that verifies at the highest level, and among those one with its text present. Among the accepted records of one key, the one with the highest `issued` is the **current** record. When two different accepted records of one key share the highest `issued`, the verifier MUST discard every record of that key and report `conflict`.

A reviewer **corrects** a review by signing a new record with the same key and a higher `issued`, and **withdraws** it by signing a record of `kind` 2 with the same key and a higher `issued`. Either the holder or the delegate can correct or withdraw a record that either of them signed. A current record of `kind` 2 leaves the key without a review. A withdrawal needs no evidence. A verifier that keeps records SHOULD keep every accepted withdrawal it has verified, even when a later reading of the same carriage no longer contains it.

### 8. Carriage

Verification depends only on the record and the chain, not on how the record travelled. This section defines two carriages and states what each makes public. Records MAY also be handed over in any other way, for example in an answer of a service, over a private channel, or by a directory; a verifier applies §6 to them unchanged.

#### 8.1 Site file

A reviewer MAY publish records in its own site under the registry key `.well-known/tapeapi-reviews.json`: UTF-8 JSON text of at most 262,144 bytes whose top-level object has the member `tapeapi-reviews`, the string `"1"`, and the member `reviews`, an array of records. A reader reads the file from the site store chosen as in TAP-11 §2.2 step 3, with this exact key and without the landing rules of TAP-10 §7.2 step 4. A declared size above 262,144 bytes makes the file **invalid**, and the reader MUST NOT read it. Otherwise the reader verifies it as TAP-10 §6.1 and §7.1 steps 3–5; a file that fails those steps, is not UTF-8, begins with a byte order mark, is not JSON, repeats a member name or contains a member named `__proto__`, `constructor` or `prototype`, or lacks either member is invalid, and no record is read from it. A reader MUST ignore a record of the file whose `reviewer` is not the endpoint ID of the container whose site holds it.

The file and every earlier version of it are public on its chain. Removing a record from the file does not remove it from that history; withdrawal is done by a record of `kind` 2 (§7).

#### 8.2 TapeSend

A reviewer MAY send a record as a TAP-10 message with a **public** payload (TAP-10 §15.2) from the reviewer to the reviewee, whose content (TAP-10 §16) has `v` `1`, `kind` `"message"`, a `body` that states the review in words, and an additional member, `review`, holding the record. Such a message carries a review of this TAP only when its sending container and chain are those of `reviewer`; a reader MUST ignore it otherwise. The `ref` SHOULD be the review hash; a reader MUST NOT rely on it (TAP-10 §17). A record in a sealed payload is a private message to the reviewee; a reader other than the reviewee cannot verify it, and a summary (§9) MUST NOT count it.

A payload longer than 16,000 bytes is `unsupported` (TAP-10 §15.1). A record that does not fit MUST NOT be sent this way whole; the reviewer MAY send it without its `evidence` member, or without its `text` member, and publish the whole record by another carriage. A copy without `evidence` verifies at level 0 (`evidence-missing`), and one without `text` has its text withheld.

A reader MUST NOT use a message that is `pending` under TAP-10 §17. It MUST apply §6 step 4 with the message's block time in place of `now`. It MUST show, next to the record, the sending wallet of the message (TAP-10 §18.5), and MUST mark it when it differs from the reviewer's current holder, which means that the circuit changed hands after the message was sent. No other carriage lets a reader say who held the reviewer when a record was sent.

Everything in the record is public and permanent, together with what TAP-10 §17 and its Security Considerations list for every message: who wrote to whom, when and on which chains, the size of the payload and its `ref`.

### 9. Summaries and directories

A client that shows a **summary** of the reviews of a reviewee:

1. MUST compute it from records it verified under §6, after applying §7;
2. MUST count, for each pair `(reviewer, reviewee)`, at most one record: among the counted current records of that pair, the one with the highest `issued`, and of two with the same `issued` the one with the greater review hash;
3. MUST show level 1 and level 2 separately, each with the number of distinct reviewer containers, the number of distinct current holders of those reviewers, the number of records with each score, and the earliest and latest `issued`;
4. MUST NOT add level-0 records, or records not counted, to these numbers, and MAY show how many pairs have only such records;
5. MUST NOT weight a record by any amount paid, staked or held;
6. MUST NOT present a summary as proof of quality, honesty or availability.

A **directory** (any service that collects records or summaries for others) is for discovery only. A client MUST NOT treat a directory's inclusion, order, summary or label as a verification, and MUST NOT show a badge, rank or mark that no record it verified backs.

### 10. Display

- A client MUST identify the reviewer and the reviewee by container address and on-chain name (TAP-10 §3.1), MUST show a record's level and by whom it is signed, and MUST mark withheld text as withheld.
- A client MUST NOT present a record that is not accepted (§6 step 6) as a review by the reviewer. When it shows such a record, it MUST mark that its signer does not speak for the reviewer now.
- `text.body` and the tags are data, never instructions. A client MUST render them as plain text as TAP-10 §16 requires for a message `body`, making visible or removing the code points TAP-10 §16 lists, and SHOULD also remove every code point of general category Cc (other than line feed and tab), Cf, Zl or Zp or with the property Default_Ignorable_Code_Point, in Unicode 17.0 (https://www.unicode.org/versions/Unicode17.0.0/) or later, and U+2800 and U+1D159. A client that passes a record to a language model SHOULD mark it as a statement made by the reviewer.
- A client MUST NOT state who held the reviewer or the reviewee when a record was signed, except as §8.2 allows.
- The `method` of a level-1 receipt and the task of a level-2 mandate MAY be shown only marked as stated by the parties.

## Rationale

- **One topic, built on TAP-13 and the task draft.** The editors asked that a review format say which of #47 and #49 it builds on. Reviews need evidence of an interaction, which TAP-13 (a signed answer) and #47 (a delegated, delivered and judged task) provide. They need no listing, so this TAP does not build on #49. `requires` names only numbered TAPs; §4.3 restates the formats of #47 that level 2 uses, so that nothing normative depends on the unmerged draft.
- **Evidence, not proof.** A signed answer proves that the reviewee answered a request whose id names the reviewer; a task proves that both sides signed their part. Neither proves that the reviewer is independent of the reviewee, that the answer was right or that the score is fair. The levels make the strength of the evidence visible instead of hiding it in one number.
- **The id names the reviewer.** TAP-13 lets the client choose the request id, and the provider signs it. Writing the reviewer's container into the id stops anyone else from citing the same answer in a review of their own. It is a label for that purpose, not an identity of the caller.
- **Level 0 is shown, never counted.** Forbidding unbacked reviews would only move them elsewhere; showing them separately keeps the counted numbers clean.
- **Endpoint IDs and the reviewer's chain.** An endpoint ID carries its chain, so a review can cross chains with no further field, and the domain's `chainId` separates the chains as TAP-11 §4.1 does.
- **One type with `kind`.** Correction is a newer record and withdrawal is a record of `kind` 2, so one type covers all three. An EIP-712 struct has no reserved fields; `kind` leaves room for later record kinds without voiding signatures.
- **Only accepted records correct, withdraw or conflict.** Anyone can sign a record naming any reviewer. If such a record could be current, a stranger could withdraw any review by signing a later withdrawal, or void it by signing a different record with the same `issued`.
- **The digest is the identity.** As in #47, the review hash names the record across carriages and is what a reader deduplicates on.
- **The holder or the delegate.** The holder is the authority over a container (TAP-10 §13.4). Agents that review automatically need a hot key, which TAP-11 already gives them in the delegate. #47 allows only the holder for a principal's messages, which authorise work; a review authorises nothing, so the delegate is allowed here, with the risk stated under Security Considerations.
- **The current holder, not the holder at signing time.** A record in a site file carries only the `issued` its author states, and TAP-10 reads the chain at a recent pinned block. Proving who held a circuit at an earlier time needs historical state that TAP-10 does not specify. So a record counts only while its signer still speaks for the reviewer; after a transfer the new holder can sign the same review again, with the same review hash. TapeSend is the exception, since TAP-10 §18.5 gives the sending wallet of a message.
- **A separate name for EIP-1271 not supported.** A verifier that declines EIP-1271 cannot tell whether a contract holder signed; reporting `signer-not-current` would accuse the reviewer of something the verifier did not check. #47 reports `not-signed-by-holder` in the same situation for its own messages.
- **Records stay with containers.** A review of a container stays with it when the circuit changes hands, as the TapeOut team noted in #41: the buyer inherits the record, good or bad.
- **The TAP-11 domain.** It needs no contract and shows the holder the same `name` and `verifyingContract` as a delegation. TAP-11 places `ManifestContent` next to `Delegation` in that domain and #47 adds four types; whether further TAPs may add types there is the same question #47 raises, and only the domain would change.
- **No registry contract.** In the reputation registry of ERC-8004 (ethereum/ERCs at commit `503591a`), any address other than the agent's owner or operators can give feedback, and a summary is filtered by a list of reviewer addresses that the reader supplies; its text names Sybil attacks as possible. An empirical study of its deployments (arXiv:2606.26028v2, Xiong et al., "Can Trustless Agents Be Trusted? An Empirical Study of the ERC-8004 Decentralized AI Agent Ecosystem", 2026-07-08) estimated that 73.5%, 59.2% and 90.6% of reviewers on three chains were coordinated Sybil accounts. A registry records who gave feedback, not that an interaction took place. An off-chain signed record, as in EAS's off-chain attestations, costs nothing to make and carries its evidence. TapeOut already has the identity (the container) and a timestamped carriage (TapeSend), so this TAP adds neither a contract nor a schema registry.
- **Counting counterparties, not money.** An amount can be paid and returned for the cost of gas, so weighting by it rewards washing. Distinct reviewer containers, distinct holders and age are what a reader can check.
- **90 days.** Evidence more than 90 days older than `issued` cannot back a review. Since `issued` is the reviewer's own claim, a reviewer can backdate a record to meet the limit; the record then carries the backdated time, which orders it behind the reviewer's later records (§7), and a TapeSend carriage shows the block time beside it. The limit keeps casual reuse of old answers out; it does not prevent deliberate stockpiling.
- **Withdrawal, not deletion.** Published records cannot be erased from chain history; a later record that withdraws an earlier one is what every reader can see.
- **TapeSend copies without evidence.** A level-2 record with its delivery can exceed the 16,000-byte payload of TAP-10 §15.1. Sending a copy without evidence keeps the time and sender that TapeSend records, and the whole record can be read from the site file.
- **Payments are not evidence here.** A TapeSend asset attachment verified under TAP-10 §19 proves that a payment was made, not that anything was delivered, and can be returned. A later TAP can define it as a further kind.
- **Usage receipts.** The AI usage receipts proposed in pull request #26 are TAP-13 envelopes, but their `id` is chosen by the upstream or the sidecar, not by the client, so §4.2 step 3 cannot bind them to a reviewer.
- **Relation to TAP-12.** TAP-12 records sealed claims and their verdicts and leaves scoring to later TAPs. Its records are about claims, not about interactions between two containers, so this TAP does not count them; a later TAP may add them as a kind of evidence. Its display rule for the sending wallet is the one §8.2 follows.
- **Acknowledgement.** The idea of calling services under circuit identities, on which this work builds, came from @Theairresearch.

## Backwards Compatibility

This TAP adds no contract, hub function, payload format, manifest member or name syntax, and changes nothing in TAP-10, TAP-11 or TAP-13. `Review` is a new type in the TAP-11 domain whose type hash differs from those of `Delegation`, `ManifestContent`, the four types of #47 and `ChannelKeys` of the private-channels draft #12. The site file is an ordinary site file, and a TapeSend review is an ordinary public message that a TAP-10 client shows as mail, as TAP-12 records are.

**Relation to #41.** Part 3 of #41 made a review valid only with the principal's signed acceptance and a matching settlement. This TAP separates a valid record from a counted one, counts two kinds of evidence, and requires no payment (Rationale). It keeps "latest review per pair only" and counting counterparties rather than amounts.

**Relation to #47.** §4.3 restates the formats of #47 at the commit named in §1. If #47 changes them, the next revision of this draft follows it and regenerates the vectors of level 2.

## Test Cases

`assets/tap-draft-container-reviews/reviews.json` gives the type hashes, the domain separators for chains 56, 8453 and 196 (the first equal to TAP-11's), published test keys, six test containers with their holders and signers, 59 cases and 6 summaries. Chain facts (current holders, current signers, which holders have code) are inputs, as a verifier would read them. Each case gives a record and the expected result of §6: whether it is rejected, its review hash, level, by whom it is signed, whether it is counted, its problems, and whether its text is withheld. The cases cover levels 0, 1 and 2 (including a signed refusal, a delegate's signature, a reviewer on another chain, a rejecting verdict and an agent reviewing its principal), withheld text at levels 0 and 1, withdrawals and a correction, the 90-day and 300-second limits on both sides, each problem of §4 and §6, a high-`s` signature, a signature longer than 65 bytes, and a reviewee that rotated its signer. No case exercises EIP-1271: the one contract holder shows only the result of a verifier that declines it. The summaries cover §7 and §9: strangers who try to withdraw or to cause a conflict, a delegate withdrawing a review its holder signed, a correction, and a conflict between two accepted records.

The values were computed with the EIP-712, TAP-13 and canonical-JSON code of TapeAPI at commit `4a1ac4fe2a0b2e3327652a794794765dd5da98ef` (public, 1.8.1) and a prototype verifier included in the assets (`reviews-lib.mjs`, with the generator `make-vectors.mjs`). `check-vectors.mjs` recomputes every type hash, domain separator, review hash and level-1 subject, and every signature recovery a case reports as accepted, without that code; it applies the rules of §6, §7 and §9 with the same prototype. Both scripts need a checkout of that commit with its dependencies installed: `TAPEAPI_ROOT=<checkout> node check-vectors.mjs`, and `TAPEAPI_ROOT=<checkout> node make-vectors.mjs --check` to regenerate the file and compare.

## Reference Implementation

To be implemented.

## Deployments

None. This TAP deploys no contract and depends on none directly. Verification reads the contracts listed under Deployments in TAP-10 and TAP-11.

## Security Considerations

- **Sybil reviewers.** Each counted review costs one opened container and either one answered call or one completed task. A service can open containers and call itself, and two colluding containers can stage a task for the cost of a few signatures. `related-parties` catches only reviewers that share an address with the reviewee; a different wallet per container defeats it. Reputation under this TAP raises the cost of fraud; it does not detect collusion, and summaries are not proof.
- **Review farming by the reviewee.** A reviewee can answer calls labelled for many reviewers it controls. Readers see the count of distinct holders, the age of each record and the level, and can discount reviewers they do not know. Nothing in this TAP makes that judgement for them.
- **Negative reviews cost nothing extra.** A provider signs its refusals (TAP-13 §6), so a malformed request labelled for the reviewer yields a signed answer that backs a level-1 review. Level 1 shows that the two containers exchanged a request and an answer, not that the reviewer tried to use the service.
- **The label is not the caller.** Anyone can send a request whose `id` names another container. Such an answer can back only that container's reviews, so the label cannot be used to review in its name, but a provider that read the label as the caller's identity could be led to blame or bill the wrong container; §4.2 forbids that reading.
- **Evidence is not quality.** A signed answer proves an answer, not its correctness; a task proves a signed verdict, not that the verdict is fair. A reviewer can give any score after a real interaction.
- **Retaliation.** An agent can review its principal after a rejected task, and a reviewee can review its reviewers. Both are records like any other; readers see the evidence and the dates.
- **Forged attribution.** Anyone can sign a record that names any container as reviewer. Such a record is not accepted (§6 step 6): it cannot count, cannot withdraw or correct, and cannot cause a conflict (§7), and §10 forbids showing it as the reviewer's. A client that ignores §10 can still be used to put words in a container's mouth.
- **Transfers.** A buyer of a well-reviewed container inherits its reviews and can trade on them. Clients identify containers by name and container, not by a reputation, and §10 forbids claims about past holders. When a reviewer changes hands, its records stop counting until the new holder signs them again; a delegate's signature stops counting when the delegation lapses at the transfer (TAP-11 §7.2).
- **Delegate keys.** A delegate is a hot key on a server. Whoever steals it can publish reviews in the reviewer's name, and can withdraw or override the reviews the holder signed (§7), until the holder replaces the delegate or the delegation expires. The holder can then sign its reviews again with a later `issued`. A reader can count only holder-signed records if it prefers.
- **Signer rotation and lapsed services.** When a reviewee replaces its signer, removes its manifest or lets its service stop resolving, level-1 evidence no longer verifies, and every such review stops counting at once, favourable and unfavourable alike. A reviewee cannot shed only the unfavourable ones this way, but it can shed all of them.
- **Rolled-back files and withheld withdrawals.** Whoever can write the reviewer's site can put back an older file or leave a withdrawal out of it; readers that see only that file then see the earlier review. §7 asks readers to keep the withdrawals they have seen, which helps only readers that saw them.
- **Self-stated times.** `issued` is the reviewer's claim, bounded only by `now` plus 300 seconds and, in a TapeSend message, by its block time. A backdated record can win or lose the ordering of §7 only against the reviewer's own records. Backdating also lets old evidence meet the 90-day limit of §4.2; only a TapeSend carriage shows when the record was actually sent.
- **What a wallet shows.** The typed data of a review shows endpoint IDs and hashes, not the reviewee's name, the text or the evidence. A holder that signs from a wallet alone signs what the console tells it; §5 asks consoles to show the content.
- **Privacy.** Everything in a published record is public and permanent: reviewer, reviewee, score, text unless withheld, and the evidence. A hash-only receipt still publishes the method name, the request id, the time and success or refusal; parameters and results from a small set (an address, a token ID, a price pair) can be recovered by hashing candidates. Level-2 evidence publishes the mandate (task hash, mode, the providers in scope, the window and nonce), the verdict and the agent's delivery result, which lists the providers the agent called. TapeSend adds its metadata (§8.2). A reviewer that wants to keep an interaction private uses level 0 or withholds the text, at the cost of not being counted.
- **Text is data.** Review text can address a language model that reads it and can hide text in invisible code points; §10 makes those visible or removes them and has the text presented as the reviewer's statement. It does not make the text true.
- **Directories.** A directory can omit, reorder or delay records. §9 keeps it from changing what a client trusts, not from changing what a client sees; a client can read the reviewers' files and messages itself.
- **Words as keys.** The word pattern admits `constructor` and `prototype`. A client that builds a map keyed by tag uses a `Map` or an object without a prototype.
- **Inherited trust.** Every check rests on the identity, holder and signer reads of TAP-10 and TAP-11, under their node and contract assumptions, which this TAP inherits.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
