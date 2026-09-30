---
tap: TBD
title: Sealed Commitments and Verdicts over TapeSend
description: A record format for claims that are fixed in time, hidden until an open time, revealed, and judged, built entirely on TAP-10 messages.
author: spongemochi (@spongemochi)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/5
status: Draft
type: Application
created: 2026-09-30
requires: TAP-10
license: CC0-1.0
---

# TAP-TBD: Sealed Commitments and Verdicts over TapeSend

## Summary

A way for a person or an agent to seal a claim on chain, reveal it on a chosen date, and have it judged in public, so that anyone can rebuild the same track record without trusting a server.

## Abstract

This TAP defines three record types carried as ordinary TAP-10 messages: a **commitment** (a sealed message from an author to a judge whose `ref` publicly states its kind and open time), a **reveal** (a public message that discloses the commitment's content key so anyone can decrypt and verify the original payload), and a **verdict** (a public message from a judge that references the commitment and states an outcome with its sources). It defines the 32-byte `ref` layout that marks these records, the content members they carry, how a client locates and verifies them, and the status a commitment has at any time (sealed, revealed, unrevealed, malformed, judged). Nothing in the hub, payload or content formats of TAP-10 is changed; a TAP-10 client that does not know this TAP still shows these messages as ordinary messages.

## Motivation

DeWEB gives containers an identity, a site and a mailbox (TAP-10), but no standard way to say "I claim X, sealed now, to be checked on date T". Applications that want a track record — forecasts, promises, service commitments — each invent a format and keep the record on their own server, where it can be edited, deleted or lost, and where no other application can read it.

As agents begin to hold assets and serve each other, "who has been right, and who keeps their word" becomes information other applications need. This TAP puts that record on chain in a form any client can rebuild, using only what TAP-10 already provides:

- the hub entry fixes **when** a commitment was made and binds its digest;
- the sealed payload hides **what** was claimed until the author or the judge discloses the content key;
- the public outbox makes every commitment an author has made **visible**, so an author cannot seal opposite claims and reveal only the winner;
- public verdicts let anyone see **how** a claim was judged and by whom.

Scoring, leaderboards, agreement between judges and reputation-backed uses of a record are out of scope and left to later TAPs.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms

- **Hub**, **endpoint ID**, **container**, **inbox index**, **sealed payload**, **public payload**, **content**: as defined in TAP-10 §12, §13, §15 and §16.
- **Author**: the container that sends a commitment. Its endpoint ID is `endpointID(sending chain, from)`.
- **Judge**: the container whose endpoint ID is the `to` of a commitment.
- **Record**: a TAP-10 message whose `ref` carries the tag of §2.
- **Commitment ID**: the 32-byte value defined in §3.3.
- All multi-byte integers in this TAP are big-endian. Timestamps are seconds since the Unix epoch.

### 2. The `ref` layout

TAP-10 lets the sender choose the 32-byte `ref` of a message. The hub binds it into the digest (`keccak256(ref ‖ keccak256(payload))`) and into the sealing context `X`, so it cannot be changed after sending.

A message is a record of this TAP if and only if bytes 0–3 of its `ref` equal the tag below. All other messages are outside this TAP.

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 4 | Tag | `0x53 0x43 0x56 0x31` (ASCII `SCV1`) |
| 4 | 1 | Record type | `0x01` commitment, `0x02` reveal, `0x03` verdict |
| 5 | 27 | Type-specific | see §3, §4, §5 |

A record whose type byte is not `0x01`, `0x02` or `0x03` is `unknown-type`; clients MUST ignore it for the purposes of this TAP and MAY still show it as an ordinary message.

### 3. Commitment (record type `0x01`)

#### 3.1 `ref`

| Offset | Size | Field | Value |
|---|---|---|---|
| 5 | 1 | Kind | `0x01` promise, `0x02` forecast |
| 6 | 8 | Open time | `uint64`, seconds since the Unix epoch |
| 14 | 18 | Reserved | MUST be zero |

- **promise**: a claim about the author's own future conduct ("I will ship v2 by 2027-01-01").
- **forecast**: a claim about the world that the author does not control ("BTC/USD closes above 100,000 on 2026-10-06").

A commitment whose kind byte is not `0x01` or `0x02`, or whose reserved bytes are not zero, is `malformed` (§7).

#### 3.2 Sending

The author MUST send the commitment with a **sealed** payload (TAP-10 §15.3) to the judge's endpoint ID, so the judge's usable key is in the key list. The author SHOULD also include its own usable key, as TAP-10 recommends, so it can later read and reveal its own commitment.

The open time in `ref` MUST be greater than the timestamp of the block in which the message is included; otherwise the commitment is `malformed`.

The judge's container need not be opened, but it MUST have a usable key (TAP-10 §14.4) at the time of sending, because a sealed payload cannot be built without it.

#### 3.3 Commitment ID

```
commitmentId = keccak256("SCV1/commitment" ‖ uint64(chainId) ‖ bytes32(to) ‖ uint32(inboxIndex))
```

where `chainId` is the chain of the hub that holds the entry, `to` the judge's endpoint ID and `inboxIndex` the index returned by `send` and carried in the `Sent` event. A commitment is identified by this triple, never by digest alone (TAP-10 §13.6).

#### 3.4 Content

The sealed content is a TAP-10 content object (§16) with `v` = `1` and `kind` = `"message"`. `body` MUST hold the human-readable text of the claim. The object MUST carry an additional member `scv`:

| Member | Type | Required | Meaning |
|---|---|---|---|
| `scv.v` | number | yes | `1` |
| `scv.type` | string | yes | `"commitment"` |
| `scv.kind` | string | yes | `"promise"` or `"forecast"`; MUST equal the kind byte in `ref` |
| `scv.open` | number | yes | MUST equal the open time in `ref` |
| `scv.claim` | object | no | Machine-readable form of the claim (§3.5) |
| `scv.slot` | object | no | `{ "chainId": number, "processor": "0x…", "id": string }` — a circuit taped out for this commitment, for products that tie one commitment to one transistor |
| `scv.nonce` | string | no | Random hex string, RECOMMENDED so that identical claims produce different payloads |

A revealed content that fails these rules makes the commitment `malformed` (§7). Unknown members are ignored, as in TAP-10.

#### 3.5 Machine-readable claim (optional)

When present, `scv.claim` is an object with:

| Member | Type | Meaning |
|---|---|---|
| `metric` | string | What is measured, e.g. `"price"` |
| `subject` | string | e.g. `"BTC/USD"` |
| `op` | string | One of `">"`, `">="`, `"<"`, `"<="`, `"=="` |
| `value` | string | Decimal string without leading zeros |
| `at` | number | The time at which the metric is read; defaults to `scv.open` |

This TAP does not define how a judge obtains the metric. A judge that cannot evaluate a claim MUST rule `undecidable` (§5).

### 4. Reveal (record type `0x02`)

#### 4.1 `ref`

| Offset | Size | Field | Value |
|---|---|---|---|
| 5 | 27 | Commitment reference | bytes 0–26 of the commitment ID (§3.3) |

#### 4.2 Sending

A reveal is a **public** payload (TAP-10 §15.2) sent by the author or by the judge. The author SHOULD send it to the judge's endpoint; the judge SHOULD send it to the author's endpoint. A reveal from any other container is ignored.

A reveal MAY be sent at any time, including before the open time; an early reveal simply ends the sealed period early.

#### 4.3 Content

A TAP-10 content object with `v` = `1`, `kind` = `"message"`, any `body`, and:

| Member | Type | Required | Meaning |
|---|---|---|---|
| `scv.v` | number | yes | `1` |
| `scv.type` | string | yes | `"reveal"` |
| `scv.commitment` | object | yes | `{ "chainId": number, "to": "0x…" (32 bytes), "inboxIndex": number }` |
| `scv.key` | string | yes | `K` of the commitment's sealed payload, 32 bytes as `0x`-prefixed lowercase hex |

#### 4.4 Verification

A client verifies a reveal as follows and MUST reject it on any failure:

1. Recompute the commitment ID from `scv.commitment`; its first 27 bytes MUST equal `ref` bytes 5–31;
2. Fetch the commitment's entry and `Sent` event (§6) and confirm the reveal's sender is the commitment's author or judge;
3. Parse the commitment payload as a sealed payload; `SHA-256("TAP-10/commit/v2" ‖ K)` MUST equal its field `D`;
4. Decrypt `C` with `K`, nonce `N` and `aad = P ‖ S ‖ X` exactly as TAP-10 §15.3 "Opening" step 4, where `X` is built from the commitment's `to`, `from`, `ref` and hub;
5. Decode the content under §3.4.

Because `K` is fresh for every message and bound to `D`, disclosing it reveals this message only and nothing about the parties' long-term keys.

### 5. Verdict (record type `0x03`)

#### 5.1 `ref`

As §4.1.

#### 5.2 Sending

A verdict is a **public** payload sent by a container acting as judge to the **author's** endpoint. Any container MAY send a verdict on any commitment; a verdict from the container named as `to` in the commitment is the **designated judge's** verdict, others are **third-party** verdicts. Clients MUST show which is which and MUST NOT merge them.

A verdict SHOULD NOT be sent before the open time. A verdict sent before the open time is recorded but MUST be marked `early`.

#### 5.3 Content

A TAP-10 content object with `v` = `1`, `kind` = `"message"`, a `body` that states the verdict in words, and:

| Member | Type | Required | Meaning |
|---|---|---|---|
| `scv.v` | number | yes | `1` |
| `scv.type` | string | yes | `"verdict"` |
| `scv.commitment` | object | yes | As §4.3 |
| `scv.key` | string | no | `K`, when the judge is revealing and judging in one message |
| `scv.outcome` | string | yes | `"hit"`, `"miss"` or `"undecidable"` |
| `scv.sources` | array | yes for `hit`/`miss` | Each `{ "name": string, "value": string, "at": number, "url": string (optional) }` |
| `scv.reason` | string | no | Free text |

A verdict on a commitment that has not been revealed (by this verdict's `scv.key` or an earlier reveal) MUST be `undecidable`.

### 6. Locating and verifying records

A client rebuilds records per chain in the TAP-10 chain table, from the hub at the TAP-10 hub address on that chain, under the node-agreement and pinned-block rules of TAP-10 §5:

1. Read `Sent` events whose `ref` begins with the tag (topic3 bytes 0–3). Records need log-capable nodes; a client without them MAY instead walk the outbox of known containers with `outboxPage` and then fetch the events for those entries;
2. For every event, read `inboxAt(to, inboxIndex)`. The entry's `from` MUST equal the event's `from` and its `digest` MUST equal `keccak256(ref ‖ keccak256(payload))`; otherwise discard the event;
3. Group records by commitment ID; attach reveals and verdicts to their commitment; discard reveals and verdicts whose 27-byte reference matches no known commitment;
4. Apply §4.4 and §5 to each reveal and verdict.

The time of every record is its block timestamp, never a sender-claimed `ts`.

### 7. Commitment status

Given a commitment with open time `T`, the grace period `G = 604800` seconds (7 days), and the current pinned block time `now`, a client MUST derive exactly one status:

| Status | Condition |
|---|---|
| `malformed` | The `ref` fails §3.1, the payload is not a sealed payload, the open time is not after the sending block, or a verified reveal yields content that fails §3.4 |
| `sealed` | Not malformed, no verified reveal, `now < T` |
| `pending` | Not malformed, no verified reveal, `T ≤ now < T + G` |
| `unrevealed` | Not malformed, no verified reveal, `now ≥ T + G` |
| `revealed` | A verified reveal exists and no verdict from the designated judge |
| `judged` | A verified reveal exists and at least one verdict from the designated judge |

Clients MUST display `unrevealed` and `malformed` commitments with the same prominence as `judged` ones. An application MUST NOT hide a commitment because of its status or outcome.

### 8. Privacy

A message that is not meant to be a public record MUST NOT carry the tag. A sealed message without the tag is an ordinary TAP-10 message and is never `unrevealed`.

Every record's metadata — author, judge, time, kind, open time — is public from the moment it is sent. Only the claim text is hidden, and only until reveal.

## Rationale

- **Why `ref` for public metadata.** The hub stores neither payload nor any parsed field, but it binds `ref` into the digest and into the sealing context. `ref` is therefore the only 32 bytes a sender can make public and tamper-proof at no extra cost. Putting kind and open time there lets anyone see what is due and when without decrypting anything.
- **Why reveal the content key instead of the text.** The digest covers the ciphertext, so publishing plaintext proves nothing. TAP-10's sealed format already commits to `K` through `D`; disclosing `K` lets every reader decrypt the exact on-chain bytes and check them, with no new cryptography.
- **Why the outbox defeats cherry-picking.** A commitment is a public entry in the author's outbox with the tag in plain view. An author who seals two opposite claims has two visible commitments; the losing one becomes `unrevealed` and is shown.
- **Why `kind` stays `"message"`.** TAP-10 treats any other `kind` as `unsupported`. Keeping `"message"` and adding an `scv` member means every existing client shows these records as readable mail, and this TAP does not weaken TAP-10 (TAP-01 §3).
- **Why verdicts are public.** A record that only the author can read cannot be rebuilt by third parties. Judges that need confidentiality can send an ordinary sealed message in addition to the public verdict.
- **Why anyone may judge.** Restricting verdicts to the designated judge would make every record depend on one container staying online and honest. Third-party verdicts are recorded separately so later TAPs can score judges against each other.
- **Why a 7-day grace period.** Judges and authors need time after the open time to read prices, decide and send. Seven days is long enough for a weekly process and short enough that a stale commitment is flagged within the same reporting period. Applications MAY show `pending` differently from `unrevealed`.

Alternatives considered: storing commitments as site files in the author's container (rejected: no per-record timestamp from the hub, and no way to seal to a judge); a dedicated contract (rejected: TAP-10 already provides timestamped, digest-bound, sealed delivery on every supported chain).

## Backwards Compatibility

This TAP adds no contract, no hub function and no payload version. A TAP-10 client that does not implement this TAP shows commitments as sealed mail it cannot open (unless it holds a key), and shows reveals and verdicts as public mail with a readable `body`. No existing message is affected.

## Test Cases

The following are examples; a reference vector set will be added under `assets/` once the reference implementation is at a fixed commit.

**Example 1 — commitment `ref`.** Kind forecast, open time 2026-10-06 04:00:00 UTC (`1791259200`):

```
ref = 0x53435631 01 02 000000006ac47240 000000000000000000000000000000000000
      ^tag      ^type ^kind ^open time (8 bytes) ^reserved (18 zero bytes)
```

**Example 2 — commitment ID.** Chain 196, judge endpoint `0x0000000000000000000000c40b4a0ba288b4d2a87fc07db5f4c929f87dfda282` (illustrative), inbox index 7:

```
commitmentId = keccak256("SCV1/commitment" ‖ 0x00000000000000c4 ‖ to ‖ 0x00000007)
             = 0x7351b20d22fe22d97c4b3ad4dae6aea379a08e4529f146af1080227a1ffaac5c
```

**Example 3 — verdict `ref` for that commitment:**

```
ref = 0x53435631 03 7351b20d22fe22d97c4b3ad4dae6aea379a08e4529f146af108022
      ^tag      ^type ^first 27 bytes of commitmentId
```

**Example 4 — commitment content (before sealing):**

```json
{
  "v": 1,
  "kind": "message",
  "subject": "Commitment",
  "body": "BTC/USD is above 100000 at 2026-10-06 04:00 UTC.",
  "scv": {
    "v": 1,
    "type": "commitment",
    "kind": "forecast",
    "open": 1791259200,
    "claim": { "metric": "price", "subject": "BTC/USD", "op": ">", "value": "100000", "at": 1791259200 },
    "nonce": "0x9f3c2b1a"
  }
}
```

**Example 5 — verdict content:**

```json
{
  "v": 1,
  "kind": "message",
  "subject": "Verdict",
  "body": "Miss. BTC/USD was 96410.20 at the open time.",
  "scv": {
    "v": 1,
    "type": "verdict",
    "commitment": { "chainId": 196, "to": "0x0000000000000000000000c40b4a0ba288b4d2a87fc07db5f4c929f87dfda282", "inboxIndex": 7 },
    "key": "0x…",
    "outcome": "miss",
    "sources": [
      { "name": "chainlink-bsc", "value": "96410.20", "at": 1791259200 },
      { "name": "chainlink-base", "value": "96402.75", "at": 1791259200 },
      { "name": "okx-spot", "value": "96415.00", "at": 1791259200 }
    ]
  }
}
```

## Reference Implementation

168 on X Layer (chain 196), TapeOut processor `#168`. Link at a fixed commit to be added before this TAP moves to Review.

## Deployments

None. This TAP uses the DeWEB hub listed in TAP-10 Deployments on every supported chain and deploys no contract of its own.

## Security Considerations

- **Cherry-picking.** Handled by §7: every tagged commitment is visible in the author's public outbox and becomes `unrevealed` if not disclosed. Applications that hide such records do not conform.
- **Malformed commitments.** An author can seal bytes that do not decrypt or do not parse, then blame the judge. §7 makes such a commitment `malformed`, which is the author's record, not the judge's. Verifiers MUST run §4.4 in full before accepting a reveal.
- **Judge absence or dishonesty.** The author holds `K` and can reveal alone (§4.2); any container can issue a third-party verdict (§5.2). Which judges to trust is left to clients and to later TAPs; this TAP only records who said what.
- **Verdict spam.** Anyone can send a verdict on anyone's commitment. Clients MUST separate the designated judge's verdict from third-party verdicts and SHOULD let the reader filter the latter.
- **Container transfer.** Records belong to the container. Transferring the circuit transfers the track record. Clients SHOULD show holder changes (TAP-10 §18.5) alongside a record so readers can see when the current holder was not the author.
- **Trust before seals.** Until the factory and hub seals are in effect (TAP-10 §13.8), whoever controls them can impersonate endpoints and replace keys; records inherit that assumption and clients MUST indicate it as TAP-10 requires.
- **Timing.** The open time is chosen by the author; a far-future open time keeps a claim sealed for years but is visible as such. Block timestamps, not sender claims, are the time of record.
- **Replay.** A commitment payload cannot be replayed to another judge, from another author or on another chain, because TAP-10 binds `to`, `from`, `ref` and hub into `X`.
- **Key exposure.** Revealing `K` exposes one message only. Long-term keys are never disclosed.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
