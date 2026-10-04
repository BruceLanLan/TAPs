---
tap: TBD
title: Container Agent Mandates and Task Messages, Phase 0
description: Phase 0 of the container-agent Ideas #40 and #41, a holder-signed mandate saying which agent may act for a circuit container on which task, and the signed messages of one task, checked by counterparties and enforced by nothing.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/41
status: Draft
type: Application
created: 2026-10-05
requires: TAP-10, TAP-11, TAP-13
license: CC0-1.0
---

# TAP-TBD: Container Agent Mandates and Task Messages, Phase 0

## Summary

A way for the owner of a TapeOut circuit to sign a checkable record saying "this agent may work for my container on this task, until this time", and for the two sides to exchange signed offers, deliveries and verdicts, without any contract and without authorising any payment.

## Abstract

This TAP proposes phase 0 of the container-agent design outlined in issues [#40](https://github.com/TapeOutProtocol/TAPs/issues/40) (bounded payment delegation, the origin of the mandate) and [#41](https://github.com/TapeOutProtocol/TAPs/issues/41) (agent task protocol) of the TAPs repository. It defines four EIP-712 types that the **holder** of a principal circuit signs in the domain of TAP-11 §4.1 (`Mandate`, `TaskOffer`, `TaskVerdict`, `MandateRevocation`); six task messages, of which the agent's two are TAP-13 signed responses rather than new signed types; the thread state machine; a delivery's evidence of hash-only signed receipts; and revocation by direct message and by a holder-signed site file. **Nothing is enforced**: a mandate names no amount and no asset, every verification result says `enforcement: none`, and a payment, if any, is an ordinary transfer checked read-only with TAP-10 §19. Escrow, vaults, listings, markets and reputation are out of scope.

## Motivation

A container can hire an agent today only by handing over the holder's key or by agreeing on everything by hand. #40 and #41 propose enforcement through payment channels (#38) and later a vault; the channel escrow is not deployed and not audited, and the vault is not specified.

What can exist now, without a contract, is the record. Independent implementations need the same answers to: what exactly the holder signed and how a wallet shows it; how an offer is made, accepted and delivered; who signs which message; how a thread is ordered and when it expires; what a delivery proves; and how a mandate is revoked. Otherwise nothing an agent did for one principal can be checked by another, and later phases inherit incompatible formats. The EIP-712 types also have to be fixed once: a struct has no reserved fields, and changing a field invalidates every signature over the old type. This TAP therefore fixes the mandate with every field #40 lists, including those phase 0 requires to be zero.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms and notation

- **Circuit**, **processor contract**, **#ID**, **container**, **holder**, **site store**, **pinned block**, **strict agreement**: as defined in TAP-10 §1. **Hub address**, **service**, **manifest**, **signer**: as defined in TAP-11 §1. **Envelope**, **request object**, **body**: as defined in TAP-13 §3 and §4.
- **Principal**: the container on whose behalf an agent is hired. In this TAP the principal is always a container.
- **Holder of the principal**: `ownerOf(#ID)` of the principal's circuit, read as in §4. Only this address signs the four types of §3.
- **Agent**: a container whose service resolves under TAP-11 §2. Its **agent signer** is the signer of that resolution.
- **Agent key** (`agentKey`): an address the agent announces for one offer (§7.3). In phase 0 it is bound into the mandate and used for nothing else.
- **Provider**: a container service, other than the agent, that the agent calls while working.
- **Verifier**: whoever checks a mandate (§5), a thread (§7) or evidence (§8): the agent before it starts, the principal before it gives a verdict, or a third party later.
- **Thread**: the list of task messages (§7) about one offer, as presented to a verifier.
- `now` is the verifier's current Unix time in seconds; `at` is the time it evaluates a thread at (by default `now`). `keccak256`, `‖` and `utf8(s)` are as in TAP-13 §1; `canonicalJSON` is TAP-11 §6.
- A **problem** is a named finding of a verification, written in `code font`. Problem names are descriptions for interoperable reporting, not wire values, and are only ever added. A verification **passes** when it reports no problem. A verification that cannot read the chain is **unavailable** (§10), not a problem.

### 2. Overview (informative)

```
principal holder                          agent (TAP-13 service)
  offer       TaskOffer, holder-signed   ──►
                                         ◄── accept   signed response: offerHash, agentKey
  mandate     Mandate, holder-signed     ──►
                                         ◄── deliver  signed response: deliverableHash, hash-only receipts
  acceptance  TaskVerdict, holder-signed ──►
  revocation  MandateRevocation, holder-signed, at any time (also as a site file)
  [payment: an ordinary transfer and a TAP-10 message with an asset attachment, TAP-10 §19]
```

### 3. Signed types

#### 3.1 Domain, digest and signature

The four types use the EIP-712 domain of TAP-11 §4.1, unchanged: its domain type, `name`, `version` and `verifyingContract`, with `chainId` the chain ID of the **principal's** chain. This TAP defines no other domain; a chain without the hub at the hub address is handled as TAP-11 §4.1 says.

```
structHash(T, m) = keccak256(encodeData(T, m))                     // EIP-712 hashStruct
digest           = keccak256(0x19 ‖ 0x01 ‖ DOMAIN_SEPARATOR ‖ structHash(T, m))
```

- `DOMAIN_SEPARATOR` is that of TAP-11 §4.1 for the principal's chain (BNB Smart Chain: `0xa73ee348b5672f12dbc174f66a7d162c69e0d64befdba88475d9d7e3c0fd3ac7`, TAP-11 Test Cases).
- `encodeData` is EIP-712's: the type hash, then one 32-byte word per field in the order of the type string. A `Scope[]` member is `keccak256(structHash(Scope, s₀) ‖ structHash(Scope, s₁) ‖ …)`, a `bytes32[]` member `keccak256(e₀ ‖ e₁ ‖ …)`, and an empty array of either type `keccak256("")` = `0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470`.
- The holder signs `digest` itself (`eth_signTypedData_v4` or equivalent), without the EIP-191 prefix, as TAP-11 §4.2 does.
- **The digest is the message's identity**: `mandateHash`, `offerHash`, `verdictHash` and a revocation's hash are the `digest`, written as `0x` and 64 lowercase hex digits. The same mandate on another chain has another hash.
- A **holder signature** is checked against the holder of the principal exactly as TAP-11 §4.4 checks a delegation, with this `digest`. As TAP-11 §4.4 allows, a verifier MAY decline to support EIP-1271; it then reports `not-signed-by-holder` for a holder that only EIP-1271 would accept. A signature by the principal's TAP-11 signer is not a holder signature.

#### 3.2 Mandate

```
Mandate(address principal,address agent,address agentKey,uint8 mode,bytes32 taskHash,Scope[] scope,address feeToken,uint256 feeCap,uint64 notBefore,uint64 expires,uint256 nonce,bool subdelegate)Scope(address provider,address token,uint256 cap)
MANDATE_TYPEHASH = 0xf2121b841c65f4d74c6cd4a5f8de39d1aaec1060d147338e7a635ecc5bca8171
SCOPE_TYPEHASH   = keccak256("Scope(address provider,address token,uint256 cap)")
                 = 0xb16bb4dde6f01fa8f71521aeabb4ce63a0c9c7554fc6e9953718f9ee96191fbb
```

| Field | Meaning | Rule |
|---|---|---|
| `principal`, `agent` | The principal container; the agent's container | Non-zero |
| `agentKey` | The agent key announced in the thread's `accept` | Non-zero |
| `mode` | `0`: the agent is paid for the task. `1`: the agent spends the principal's budget on providers | `0` or `1`; a description, not an amount |
| `taskHash` | `keccak256(utf8(canonicalJSON(task)))` of the task object (§7.3) | Non-zero |
| `scope` | The providers the agent may call, each `{ provider, token, cap }` | At most 16 items (`MAX_SCOPE_ITEMS`); `provider` non-zero |
| `feeToken`, `feeCap` | The asset and cap of the agent's own fee | §3.6 |
| `notBefore`, `expires` | The validity window, inclusive at both ends | `expires` > `notBefore` |
| `nonce` | Chosen by the holder | §5.2 |
| `subdelegate` | Whether the agent may delegate further | §3.6 |

#### 3.3 TaskOffer

```
TaskOffer(address principal,address agent,bytes32 taskHash,uint8 mode,address feeToken,uint256 fee,uint64 deadline,uint64 exp,uint256 nonce)
TASK_OFFER_TYPEHASH = 0x9a96ccf2dd5736d1b56c02a80e91f86d6d8b5008b4abe68fee9cc78915e09546
```

`principal`, `agent`, `taskHash` and `mode` as in §3.2. `feeToken` (the zero address allowed) and `fee` are a **price statement**: they authorise no transfer and bind nobody to pay. `deadline` is when the principal wants the delivery; `exp` is when the offer stops being acceptable. `nonce` is the nonce the thread's mandate carries (§7.4).

#### 3.4 TaskVerdict

```
TaskVerdict(bytes32 mandateHash,bytes32 deliverableHash,uint8 verdict,bytes32 reasonHash,uint64 issued)
TASK_VERDICT_TYPEHASH = 0xdfd34037554f981271bc0b592c8389130df249ee45feb1a47f3706be5e8e33aa
```

A verdict on one delivery: `verdict` `1` (accepted) or `2` (rejected); `mandateHash` and `deliverableHash` are non-zero; `reasonHash` is `keccak256(utf8(canonicalJSON(reason)))` of a reason object, or 32 zero bytes. `issued` is the time the holder states. A verdict has no expiry.

#### 3.5 MandateRevocation

```
MandateRevocation(address principal,bytes32[] mandateHashes,uint64 revokedBefore,uint64 issued)
MANDATE_REVOCATION_TYPEHASH = 0xc2b443beeff2d29c4d489bbcc169a8ef6642edd24320e8dd612d50c5c2152ff3
```

`principal` is non-zero; `mandateHashes` lists at most 24 non-zero hashes (`MAX_REVOKED_HASHES`); `revokedBefore` is a time, `0` meaning none. A revocation **covers** a mandate `m` of that principal when `mandateHash(m)` is listed or `m.notBefore < revokedBefore`. `issued` is the time the holder states; it orders revocations (§6.3). A revocation has no expiry.

#### 3.6 Phase-0 rule

In phase 0 a mandate names no amount, no asset and no sub-delegation: every `scope[i].cap` and `feeCap` is `0`, every `scope[i].token` and `feeToken` is the zero address, and `subdelegate` is `false`. A verifier MUST report a mandate that breaks the first two conditions as `phase0-no-funds` and one with `subdelegate` `true` as `subdelegate-not-allowed`. A console that asks a holder to sign SHOULD NOT build a mandate that breaks this rule. (A non-zero `fee` in a `TaskOffer` is allowed: §3.3.)

#### 3.7 JSON forms

Wherever messages carry these values as JSON:

| EIP-712 type | JSON form |
|---|---|
| `address` | A string, `0x` and 40 hex digits; case is not significant |
| `bytes32` | A string, `0x` and 64 lowercase hex digits |
| `uint8` | A JSON number, one of the values the field allows |
| `uint64` | A JSON number, an integer from 0 to 2^53 − 1 (as `ts` in TAP-13 §4); Unix seconds for every time field |
| `uint256` | A string: a decimal integer without leading zeros, below 2^256 |
| `bool` | `true` or `false` |
| `Scope[]`, `bytes32[]` | A JSON array of the item form |

Every member of the types is present. A value in any other form makes the message malformed (`mandate-malformed`, §5.1; `message-malformed`, §7.1).

#### 3.8 Reserved values

These values are reserved for later TAPs, in the manner of TAP-13 §6 ("Reserved names"): this TAP gives them no meaning, an implementation of this TAP treats them as stated here, and no TAP other than one that defines them may give them a meaning.

| Value | Treated in phase 0 as |
|---|---|
| `mode` 2 to 255; `verdict` 0 and 3 to 255 | Malformed |
| A non-zero cap or fee cap, a non-zero token, `subdelegate` `true` in a mandate | `phase0-no-funds`, `subdelegate-not-allowed` (§3.6); reserved for a TAP that adds enforcement |
| Task message `v` other than `0`; receipt `v` other than `1` (§7.2) and `2` (§8) | Malformed |
| The task message names `quote`, `progress`, `reject`, `cancel`, `dispute` (from #41) | `kind-not-implemented` (§7.1) |
| `tapeapi-mandates` other than `"0"` in the revocation file | Invalid file (§6.2) |

### 4. The principal and its holder

A verifier resolves the principal under TAP-10 §4.3 (container address input), at one pinned block (TAP-10 §5.3), with every read under strict agreement, and only on the chain of the domain's `chainId`: the mandate's hash already names that chain, and TAP-10 §4.3 step 1 compares `token()`'s chain ID with it. The holder is the `ownerOf` of that resolution. The identity outcomes `not-tapeout` and `no-such-token` (TAP-10 §4.4) are problems, and the message being checked does not pass; the chain and node outcomes (`unavailable`, `stale-block`, `wrong-chain`, TAP-10 §4.1 and §5) make the verification unavailable (§10). The principal need not be opened or activated and need not have a site (Rationale).

A verifier MAY keep a holder for at most 60 seconds (TAP-11 §7.1). Every signature of §3 is checked against the holder read in this way at verification time, never against an address a message states, and never against the holder at signing time.

### 5. Verifying a mandate

#### 5.1 Checks

Given `{ "mandate": <Mandate>, "sig": <hex string> }` and, optionally, the agent and agent key the verifier expects, a verifier reports, in this order:

| Order | Check | Problem |
|---|---|---|
| 1 | The form of §3.2 and §3.7 | `mandate-malformed` (and stops) |
| 2 | §3.6 | `phase0-no-funds`, `subdelegate-not-allowed` |
| 3 | `notBefore ≤ t ≤ expires` for the time `t` checked (default `now`) | `mandate-not-yet`, `mandate-expired` |
| 4 | `expires − notBefore ≤ 2,592,000` (30 days, `MAX_MANDATE_S`) | `mandate-too-long` |
| 5 | `agentKey` and `agent` equal the expected values, when given | `agent-key-mismatch`, `agent-mismatch` |
| 6 | The principal resolves (§4) | §4 (and stops) |
| 7 | `sig` is a holder signature over `mandateHash` | `not-signed-by-holder` (and stops) |
| 8 | The nonce rule (§5.2) | `nonce-reused` |
| 9 | Revocation (§6) | `mandate-revoked`, `revocation-unavailable` |

Every result of a mandate verification MUST state `enforcement: none` (or an equivalent the verifier's interface defines) and MUST NOT be presented as an authorisation of any payment. An agent SHOULD verify the mandate, with the agent and agent key it expects, before it starts work and again before it signs a delivery.

#### 5.2 Nonce

One `(chainId, principal, nonce)` names at most one mandate. Reuse is detectable only by a verifier that keeps a record of nonces it has seen. Such a verifier:

- records `(chainId, principal, nonce) → mandateHash` only when step 7 passed and none of `phase0-no-funds`, `subdelegate-not-allowed`, `mandate-too-long`, `agent-key-mismatch` and `agent-mismatch` was reported, so that a corrected mandate can carry the nonce of one refused for these reasons;
- records a mandate that is `mandate-not-yet` or `mandate-expired`: the holder issued it, valid at another time;
- reports `nonce-reused` when its record maps that key to another `mandateHash`. Two checks of different mandates with the same key against one record MUST NOT both pass, even when they run concurrently.

A verifier that knows the agent and agent key it expects SHOULD supply them, since otherwise step 5 is skipped and a mandate with a wrong agent key uses up its nonce.

#### 5.3 What a passing mandate means

That the current holder of the principal signed, for this chain, a statement that this agent, with this agent key, may act for the principal on the task with this hash, calling the listed providers, within this window, and that the verifier knows of no revocation covering it. Not that anything stops the agent from doing anything else, that providers will check it, or that any amount may be spent.

### 6. Revocation

#### 6.1 Direct revocation

A holder may give a signed revocation `{ "revocation": <MandateRevocation>, "sig": <hex> }` to a party directly, in a thread (§7) or otherwise. It applies when its `principal` is the mandate's principal and `sig` is a holder signature; otherwise the verifier reports `revocation-mismatch` or `not-signed-by-holder` and ignores it. It binds only those who receive it.

#### 6.2 Revocation file

A holder may publish a revocation in the principal's site under the registry key `.well-known/tapeapi-mandates.json`: UTF-8 JSON text of at most 4,096 bytes whose top-level object has these members (others are ignored):

| Member | Content |
|---|---|
| `tapeapi-mandates` | The string `"0"` |
| `chainId` | The principal's chain ID, a JSON number |
| `revocation` | A `MandateRevocation` whose `principal` is the container whose site holds the file |
| `sig` | A holder signature over its hash, `0x` and 65 to 1,024 bytes in hex |

A holder SHOULD write the file without insignificant whitespace (Rationale). A verifier reads it at the pinned block of §4 from the site store chosen as in TAP-11 §2.2 step 3 (the first listed for that chain that has any path for the container), verifying it as TAP-10 §6.1 and §7.1 steps 3–5 do, with this exact key and without the landing rules of TAP-10 §7.2 step 4. Then:

1. `chunkCount` 0 means **none published**, unless the verifier keeps a floor for this principal (§6.3);
2. the file is **invalid** when: its declared size exceeds 4,096 bytes; it fails TAP-10 §7.1 or has no on-chain SHA-256; its bytes are not UTF-8, begin with a byte order mark, are not JSON, repeat a member name or contain a member named `__proto__`, `constructor` or `prototype`; a member breaks the table above; `issued` is more than 300 seconds after `now`; `sig` is not a holder signature; or it fails the floor (§6.3);
3. otherwise its revocation is **published**.

None published is not a problem. An invalid file is reported as `revocation-unavailable` for every mandate of that principal: a verifier MUST NOT treat an unreadable or invalid file as "not revoked".

#### 6.3 Floor

Whoever can write the principal's site can put back an older file or remove the current one. A verifier SHOULD keep, per chain and principal, the highest `issued` it has accepted from a revocation file (a **floor**), where the principals it checks cannot write. A verifier that keeps a floor treats as invalid a file whose `issued` is below the floor and a missing file (`chunkCount` 0) when a floor exists. A file whose `issued` equals the floor is accepted, whatever its content. To withdraw every revocation, a holder publishes a file with a higher `issued`, an empty list and `revokedBefore` 0.

#### 6.4 Effect on a mandate

A mandate covered by a published file or by an applicable direct revocation is reported as `mandate-revoked` (§5.1 step 9). Its **revocation time** is the smallest `issued` among the revocations that cover it. In a thread, revocation is applied as §7.5 says.

### 7. Task messages

#### 7.1 Message object

Every task message is a JSON object with `"v": 0` and `"kind"` equal to `"tape.agent/"` followed by one of the names of §7.3. A reserved name (§3.8) is `kind-not-implemented`; any other name is `kind-unknown`; a message with another `v` or without a string `kind` starting with `tape.agent/` is `message-malformed`. An empty thread is `thread-empty`.

A thread is keyed by `offerHash` until a mandate is applied and by `mandateHash` afterwards. TapeSend's `ref` (TAP-10 §17) is not used to group messages.

#### 7.2 Agent messages are signed responses

The agent's two messages carry a **receipt**: a TAP-13 envelope together with the request it answers.

| Member | Content |
|---|---|
| `v` | `1` |
| `service` | An object whose `container` is the agent's container; its `circuits`, `tokenId` and `name` are informative and not checked |
| `method`, `params` | The path segment and `params` of the TAP-13 request (TAP-13 §3) |
| `id`, `ts`, `ok`, `result`, `sig` | The envelope's members (TAP-13 §4); `ok` is `true` |
| `block` | Optional, as in TAP-13 §4; not signed |

A verifier checks an agent message as follows, reporting the first problem:

1. The receipt has this form, `ok` is `true` and `result` is an object; otherwise `message-malformed`.
2. `service.container` is the thread's agent; otherwise `agent-mismatch`.
3. `result.kind` equals the message's `kind`, and `ts` and `result.exp` have the `uint64` form of §3.7; otherwise `message-malformed`.
4. The agent resolves under TAP-11 §2; an outcome other than "resolved" is `agent-unresolvable`.
5. The envelope verifies under TAP-13 §5 against the agent signer of that resolution, with the digest computed from the thread's agent container, `id`, the request object `{ "method": method, "params": params }` (`params` `{}` when absent), `ok`, the canonical form of `result` and `ts`; otherwise `not-signed-by-agent`.

A thread verifier usually did not send the request and checks it later, so it applies TAP-13 §5 without the `maxSkew` of TAP-13 §8 step 5. An agent message is the genuine answer to a TAP-13 request, so TAP-13 §9 does not apply. Its `result` (`offerHash` or `mandateHash`), not its request, binds it to the thread.

#### 7.3 The six messages

| `kind` suffix | From | Members besides `v` and `kind` |
|---|---|---|
| `offer` | Principal | `task`: a JSON object; `offer`: a `TaskOffer`; `sig`: a holder signature over `offerHash`. `keccak256(utf8(canonicalJSON(task)))` equals `offer.taskHash`, otherwise `task-hash-mismatch` |
| `accept` | Agent | `receipt` whose `result` is `{ "kind": "tape.agent/accept", "offerHash", "agentKey", "exp" }`: the offer's hash, an agent key for this offer, and the time until which the agent waits for a mandate |
| `mandate` | Principal | `mandate`: a `Mandate`; `sig`: a holder signature over `mandateHash` |
| `deliver` | Agent | `receipt` whose `result` is `{ "kind": "tape.agent/deliver", "mandateHash", "deliverableHash", "receipts", "receiptsHash", "exp" }` (§8); `exp` is the time until which the agent waits for a verdict |
| `acceptance` | Principal | `verdict`: a `TaskVerdict`; `sig`: a holder signature over `verdictHash` |
| `revocation` | Principal | `revocation`: a `MandateRevocation`; `sig`: a holder signature over its hash |

The task object is data whose members the two parties choose; this TAP gives them no meaning. An agent SHOULD generate a new agent key for every offer it accepts and never reuse one.

#### 7.4 Thread state machine

The states are `Offered`, `Accepted`, `Active`, `Delivered`, `Settled`, `Rejected`, `Expired` and `Cancelled`; before an offer there is no state. A verifier processes the messages other than `revocation` in the order presented. A message not allowed in the current state is `out-of-order`. A message with a problem in the conditions column is reported and not applied: the state does not change and nothing in it is used later. A thread passes when no problem is reported.

| State | Message | Next | Conditions (problem if refused) |
|---|---|---|---|
| none | `offer` | `Offered` | §7.3; the principal resolves (§4); holder signature (`not-signed-by-holder`) |
| `Offered` | `accept` | `Accepted` | §7.2; `result.offerHash` equals `offerHash` (`offer-mismatch`); `result.agentKey` is a non-zero address (`message-malformed`); `ts ≤ offer.exp` (`offer-expired`); `ts` not after the revocation time (`message-after-revocation`, §7.5) |
| `Accepted` | `mandate` | `Active` | First, without reading the chain: `principal`, `taskHash`, `mode` and `nonce` equal the offer's (`mandate-mismatch`; no nonce is recorded). Then §5 with the expected agent `offer.agent` and the expected agent key of the `accept`. Every problem refuses it except `mandate-not-yet`, `mandate-expired` and `mandate-revoked`, which are not reported in a thread |
| `Active`, `Rejected` | `deliver` | `Delivered` | §7.2; `result.mandateHash` equals `mandateHash` (`mandate-mismatch`); `deliverableHash` has the `bytes32` form (`message-malformed`); `ts` not after the revocation time (`message-after-revocation`); `notBefore ≤ ts ≤ expires` of the mandate (`deliver-outside-mandate`); `result.exp ≥ ts` (`message-malformed`); `ts` not before the `accept`'s `ts` (`deliver-before-accept`). Reported but applied: `ts > offer.deadline` (`deliver-after-deadline`) and the problems of §8 |
| `Delivered` | `acceptance` | `Settled` (1), `Rejected` (2) | Holder signature (`not-signed-by-holder`); `mandateHash` and `deliverableHash` equal those of the last applied delivery (`verdict-mismatch`); `issued` not before that delivery's `ts` (`verdict-before-delivery`) |

After a rejection the agent may deliver again within the mandate's window. The mandate's window is checked against the delivery's `ts`, not against `at`: a thread read months later does not fail because its mandate has since expired.

#### 7.5 Revocation in a thread

A revocation **applies** to a thread when it is valid (§6.1) and covers the thread's applied mandate or, when no mandate is applied, has `revokedBefore` > 0. The revocations considered are the `revocation` messages of the thread, wherever they appear, and those found while checking the applied mandate (§5.1 step 9). A `revocation` message that does not apply is `revocation-mismatch`; one in a thread without an offer is `out-of-order`. The thread's **revocation time** `R` is the smallest `issued` of the revocations that apply.

A revocation affects only what is signed after it: it does not change the state when met, an agent message whose `ts` is after `R` is refused (§7.4), and a verdict is allowed whatever its `issued`, so a delivery made before the revocation can still be accepted or rejected. Since `R` depends on the applied mandate, which depends on the `accept`, a verifier finds `R` in a first pass without the `message-after-revocation` checks ("applied mandate" above means the one applied in that pass) and applies them in a second pass with that `R`; the problems reported are those of the second pass.

#### 7.6 Final checks

After the last message, at time `at`, in this order:

1. `Offered`, `Accepted` or `Active` with a revocation time `R ≤ at`: `Cancelled`;
2. `Offered` and `at > offer.exp`, `Accepted` and `at >` the `accept`'s `result.exp`, or `Active` and `at > mandate.expires`: `Expired`;
3. `Delivered` and `at >` the last delivery's `result.exp`: the state stays `Delivered` and the thread is reported **unaccepted**. There is no arbiter.

A verifier MUST report, with every thread result, whether it is a **self-hire**, with each reason that applies: `same-container` (`offer.principal` equals `offer.agent`); `same-holder` (the principal's and the agent's holders are equal); `agent-signer-is-principal-holder`; `agent-key-is-principal-holder`. A self-hire is reported, not refused. Any count of an agent's completed tasks SHOULD leave out self-hires.

### 8. Delivery evidence

`receipts` in a `deliver` result is an array of **hash-only receipts** of the calls the agent made to providers for the task, in which the request and the body are replaced by the two hashes TAP-13 §5 signs, so that the principal's requests are not published:

| Member | Content |
|---|---|
| `v` | `2` |
| `service` | As in §7.2, naming the provider's container |
| `method` | The path segment, informative; only `requestHash` is signed |
| `requestHash` | `keccak256(utf8(canonicalJSON({ "method": method, "params": params })))`, in the `bytes32` form |
| `id`, `ts`, `ok`, `sig` | The envelope's members; `ok` is a JSON boolean |
| `bodyHash` | `keccak256(utf8(canonicalJSON(body)))`, in the `bytes32` form |
| `block` | Optional; not signed |

`receiptsHash` is `keccak256(utf8(canonicalJSON(receipts)))`. `deliverableHash` is the hash of the deliverable, which travels separately: `keccak256(utf8(canonicalJSON(d)))` for a deliverable `d` handed over as a JSON value, and `keccak256(b)` for one handed over as a byte string `b`. Whoever holds the deliverable checks the hash of the form in which it received it. A principal SHOULD check the deliverable against `deliverableHash`, and SHOULD verify the evidence, before it signs a verdict.

A verifier checks the evidence of a delivery against the thread's mandate:

| Check | Problem |
|---|---|
| `receipts` is an array with a canonical form | `evidence-malformed` (and stops) |
| `receiptsHash` equals the hash above | `receipts-hash-mismatch` |
| Each receipt has the form above | `receipt-not-hash-only` |
| No two receipts have the same `sig` | `receipt-repeated` |
| `service.container` is a `provider` of the mandate's `scope` | `receipt-provider-out-of-scope` |
| `notBefore ≤ ts ≤ expires` of the mandate | `receipt-outside-mandate` |
| The provider resolves under TAP-11 §2 | `provider-unresolvable` |
| The TAP-13 §5 digest rebuilt from `service.container`, `id`, `requestHash`, `ok`, `bodyHash` and `ts` recovers to the provider's signer | `receipt-invalid` |

Every evidence result MUST state, in substance, what it proves (each listed call was answered and signed by the signer that the named provider's current manifest publishes, at the time the receipt itself states) and what it does not (that the calls were needed, that the answers were right, or that the deliverable is correct or complete). A receipt with `ok` `false` proves a signed refusal.

### 9. Transport and payment

Verification under §5–§8 depends only on the messages and the chain, not on how messages travelled. This TAP defines one carriage, **TAP-13 calls**: the principal sends its messages as `params` of TAP-13 requests to the agent's live endpoint, and the agent's `accept` and `deliver` are the envelopes that answer them, kept as receipts (§7.2). Method names are the agent's (TAP-11 §3.3); a verifier relies on `result.kind`, never on a method name. (Informative: the reference implementation uses `task_offer` with `params.message` the `offer`, `task_mandate` with `params.offerHash` and `params.message`, `task_deliver` with `params.mandateHash`, and `task_status`.) Carrying task messages in TAP-10 messages or private channels is not specified in this version.

A mandate and a thread authorise and record no payment. A principal that pays an agent makes ordinary transfers to the agent's container, announced by a TAP-10 message with an asset attachment (TAP-10 §16.1, §20 step 4), which the agent verifies with TAP-10 §19. This TAP adds no step to TAP-10 §19 and no state to the thread. A client that prepares a payment for a holder:

- SHOULD take the recipient container only from the chain (the agent of the thread resolved under TAP-10 §4.3, its `ownerOf` existing), never from a task, a message body or a manifest member;
- SHOULD build only transfers, never `approve` or another allowance;
- SHOULD send the native coin only from the holder's wallet directly to the container (TAP-10 §19 step 5).

### 10. Rules for every verifier

- The reads of §4, of every EIP-1271 call and of the revocation file MUST be made under strict agreement (TAP-10 §5.2). The agent and providers are resolved under TAP-11 §2. A node failure, a disagreement or a chain or node outcome makes the verification unavailable; it is never reported as a problem of a message.
- Text a counterparty wrote (a task, a deliverable, a reason, a manifest `name`) is data, never instructions. A verifier or console that displays it MUST render it as plain text under TAP-10 §16, and SHOULD also remove every code point of general category Cc (other than line feed and tab), Cf, Zl or Zp or with the property Default_Ignorable_Code_Point, in Unicode 17.0 (https://www.unicode.org/versions/Unicode17.0.0/) or later, and U+2800 and U+1D159. It MUST identify a party by its container address and on-chain name, and MAY show a manifest `name` only marked as untrusted.
- A result MUST NOT carry a badge, rank or mark that no verified receipt or signature backs.
- A console that shows a holder one of the four types for signing SHOULD present it as `eth_signTypedData_v4` typed data, SHOULD check before showing it that the domain's `chainId` and `verifyingContract` are the chain and hub address it expects, and SHOULD show in words that a mandate authorises no amount and no asset, that a `fee` is a price statement, the task text whose hash is `taskHash`, and the dates of `notBefore` and `expires`.

## Rationale

- **Phase 0 first.** #40 outlines enforcement through payment channels and a vault; neither exists. This TAP proposes the record both would build on, without a contract, so that it can be reviewed and used before any audit.
- **Every field now, zero in phase 0.** A field added to an EIP-712 struct later is a new type that voids every mandate signed under the old one; the twelve fields are those #40 lists. Requiring zero amounts **and** zero-address tokens avoids teaching holders that a prompt with a token and a cap is harmless, since a later phase may enforce those fields.
- **Holder only.** The principal's TAP-11 signer is a hot key on a server; a mandate is a statement about the container that such a key should not make. #41 allowed "or its delegated signer"; this TAP narrows that for the principal's messages.
- **The TAP-11 domain.** It shows the holder the same `name` and `verifyingContract` as a delegation, needs no contract and separates chains. TAP-11 itself places `ManifestContent` next to `Delegation` in that domain, kept apart by the type name; this TAP does the same. Whether another TAP may add types there is #40's question 2; if the editors prefer a separate domain, only the domain changes.
- **No new type for the agent's side.** The agent already signs every answer under TAP-13; a generic typed "task message" would show a wallet only a kind and a hash. The receipt objects of §7.2 and §8 are defined here because TAP-13 defines none; they could move into TAP-13.
- **`issued`, not `exp`, on verdicts and revocations.** They are statements that do not lapse; the mandate's `expires` is its expiry.
- **The principal need not be opened or activated.** TAP-10 §12.2 exempts messaging from the site rules of TAP-10 §6 and requires only the sender to be opened; TAP-11 §2.2 applies activation to resolving a service, and the principal is never resolved as a service here (the agent and providers are, under TAP-11 §2). Consequences: a principal without a site cannot publish a revocation file, and a principal that pays through TAP-10 §20 must be opened like any sender (TAP-10 §20 step 2).
- **Revocation.** A message costs nothing and binds its recipient; the file costs one write and reaches anyone who later checks. The floor works as in TAP-11 §7.3. A compact file with 24 hashes, a 1,024-byte signature and every number at 2^53 − 1 is 3,915 bytes; the same file on chain 56 pretty-printed with a two-space indent is 4,118 bytes, over the limit. `revokedBefore` revokes any number by date. In a thread a revocation affects only what is signed after it (§7.5), so it gives the same result as a message or as a file. The 30-day maximum bounds a mandate for those who never read a revocation.
- **The nonce rule.** A mandate refused for a mistake the holder can correct does not burn the offer's nonce; one merely outside its window does. `mandate.nonce` = `offer.nonce` keeps one mandate from serving two threads.
- **The principal is a container.** #40 also allowed the holder's own address; a container is the identity the rest of TapeOut uses, and an address principal can be added later without changing the type.
- **Payment outside the thread; TAP-13 calls as the carriage.** A payment's verification can be `pending` or `unavailable` for reasons unrelated to the task. TAP-13 calls need no chain write and no new key; TapeSend makes every message a paid, public write, and private channels (#12) are not yet a TAP. A later TAP can add either without changing a signed format (keeping TAP-10 §16 `kind` `"message"`, as TAP-12 does). An agent with no live endpoint cannot use this carriage (TAP-13 §3).
- **Reserved names and strict reads.** `quote`, `progress`, `reject`, `cancel` and `dispute` come from #41; a rejection is a verdict with value 2, and `dispute` has no arbiter. Reads are strict because an agent that starts on a lie about a holder works for nothing.
- **ERCs considered.** ERC-7710, ERC-7715 and smart-account session keys define permissions an account enforces; the container's `execute` is owner-only and phase 0 enforces nothing.
- **Left out.** Escrow, channels, the vault, directories, reviews and reputation; and the manifest member listing an agent's capabilities, proposed as a separate short draft so that an agent can be listed without implementing this protocol (#41's question 1).
- **Acknowledgement.** The idea of calling services under circuit identities, on which this work builds, came from @Theairresearch.

## Backwards Compatibility

This TAP adds no contract, hub function, payload format or name syntax, and changes nothing in TAP-10, TAP-11 or TAP-13: the four types are new types in the TAP-11 domain with type hashes distinct from `Delegation` and `ManifestContent`, agent messages are ordinary TAP-13 envelopes, and the revocation file is an ordinary site file.

**Relation to the Ideas.** This draft is phase 0 of #40 and #41. Differences: #40 describes no phase 0; the principal must be a container; the principal's messages are signed by the holder only; verdicts and revocations carry `issued` instead of an expiry; five of #41's message names are reserved; messages travel as TAP-13 calls, not private channels or TapeSend; #41's two mandatory checks become recommendations (the agent verifies the mandate before starting, §5.1, which in phase 0 concerns the mandate, revocation and holder since there are no channels; the principal verifies the delivery before its verdict, §8); listings and reviews are left out.

**TapeAPI 1.x.** The reference implementation is the experimental subpath `@tapeapi/sdk/agent` of TapeAPI 1.7.0, outside that SDK's 1.x compatibility promise. No existing TapeAPI interface changes.

**Reading of TAP-10 §19 step 14.** Step 14 makes the result `unavailable` for "an earlier entry whose wallet cannot be determined". TAP-10 §19 uses that wording for step 8 ("the sending wallet of m could not be determined") and lists `indirect` separately as step 9, so the reference implementation reads the parenthesis as the step 8 case (§18.5 step 1 failing) and, for an earlier entry whose message is `indirect`, compares only its sending container. The other reading would make a payment `unavailable` whenever a message sent through a contract by anyone lies among the at most 60 entries between the transfer's block and the payment message. This is the authors' reading, not a requirement of this TAP; if the TAP-10 editors read step 14 otherwise, the reference implementation will follow them.

**Differences between this text and the reference implementation.**

| Area | Reference implementation (1.7.0) | This TAP | Plan |
|---|---|---|---|
| Revocation in a thread | Applied when met: a covering revocation found while checking the mandate, even from a file with `issued` after a delivery, makes the thread `Cancelled` at once with `mandate-revoked`, and later messages are `out-of-order`; a `revocation` message cancels `Offered`, `Accepted` or `Active` at once; a revocation found while checking a refused mandate still counts; a `revocation` in `Cancelled` is accepted silently | §7.5, §7.6 | Change (1.7.1) |
| Principal identity | `token()`, `hub.accountOf`, `factory.isCPU`, `ownerOf`, strict at `latest`; `not-a-container` and `wrong-chain` where TAP-10 says `not-tapeout` | §4 | As TAP-11's plan for the same difference |
| Agent and provider resolution | The SDK's `resolve`, default agreement, with the differences TAP-11 lists | TAP-11 §2 | As TAP-11 |
| Revocation file | Missing file by `fileInfo.size` 0; site store implementation not checked; a byte order mark dropped | §6.2 | Change (1.7.1) |
| Input leniency | Holder messages accept upper-case `bytes32`, `uint256` as JSON numbers and a missing `reasonHash` (as zero); agent `ts`/`exp` may be negative; a receipt `ok` that is not a boolean reads as `false` | §3.7, §8 | Refuse (1.8; no hash changes) |

## Test Cases

The files are in `assets/tap-draft-container-agent/`. Keys and addresses are test values; the holder key is the published test key `0x` followed by 64 digits `1` (address `0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A`), as in TAP-11.

- **`vectors.json`**: copied unchanged from the reference implementation's `spec/vectors/container-agent.json`: domain, type strings and hashes, a task, three mandates (one naming a token and caps, signed only to show that it still hashes), the first mandate on chain 196, an offer, two verdicts and two revocations, each with `structHash`, digest and signature.
- **`worked-examples.json`**: the first mandate and the offer as `eth_signTypedData_v4` payloads with every intermediate value.
- **`check.py`** (output in `check.out`): recomputes all of these from the field lists of §3 with only a Keccak-256 library and secp256k1 arithmetic written in the file (and `eth_account`'s EIP-712 encoder when installed), plus the type hashes and file sizes stated below and in the Rationale.

The type hashes of §3 differ from those of `Delegation` (`0xc5081f9dc7e79dfbe7f3b3220ed9e7a29d0bc53239ee74dc184e4ac1f810948c`), `ManifestContent` (`0x809c1147faa2cda8716cdc72c000b05406f238cb127fea6f0abed585c02aea1c`) and, from the unmerged draft #12, `ChannelKeys` (`0x4dcd46fdde436adbdcfd3c3541cdb782612b23122af4c1640f9f673211d32542`).

**Worked example 1: a mandate**, chain 56. The task `{"kind":"report.attested-read","spec":"BEM holders at block 1","deliverables":["report.json"],"deadline":1789086400}` has the canonical form `{"deadline":1789086400,"deliverables":["report.json"],"kind":"report.attested-read","spec":"BEM holders at block 1"}` and `taskHash` `0x7cd6a489238bf6b1b71d7136181de5b847fee4b200fc3a8d6532f4915dcf7ff0`. The mandate: `principal` `0x86DDaEF00401E3F10418398D67D7189fc458eA95`, `agent` `0x19366c3c69FFEB3b286D9fA6cC5e616375BAafd3`, `agentKey` `0xAe72A48c1a36bd18Af168541c53037965d26e4A8`, `mode` 0, that `taskHash`, `scope` with providers `0x00000000000000000000000000000000000005e1` and `0x00000000000000000000000000000000000005e2` (token the zero address, cap `"0"`), `feeToken` the zero address, `feeCap` `"0"`, `notBefore` 1789000000, `expires` 1789086400, `nonce` `"1"`, `subdelegate` false.

| Step | Result |
|---|---|
| `structHash(Scope, scope[0])`, `[1]` | `0xf3386688fada3a897b773e2432a2d9eb096e9a8fedf75b2d32e4e60068c7995f`, `0x2e7077b88f8cf5e85f3e3faaa93c13bc1bc7f9d476aa122bcf6cd416531faec7` |
| `scope` word | `0x250d5b3f2525568ee800efa67d8491e37938baebbf85a6f5db2bac22c6a663d0` |
| `encodeData`, 13 words | `MANDATE_TYPEHASH`, the three addresses, `0`, `taskHash`, the `scope` word, `0`, `0`, `0x6aa1f940`, `0x6aa34ac0`, `1`, `0` |
| `structHash` | `0x95d93105029fb7124b3be259d91c6f1dd4c44ad4f7e94258cf042215efc50efb` |
| `digest` = `mandateHash` | `0x35eb4e7a6b9350682344107fac505300358ae1a1ab561c982f23f0c3844c223a` |
| `sig` | `0x69ff0d1e14fe3df990c5c8c80bc4e059f34104350a54c5d571ad8e099ee830503d130c932d4c65ccb9d05c13193e258747fbbaa085b03f1127d051b224bc940c1c` |
| recovers | `0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A` |

Rejections: on chain 196 the same mandate has digest `0x8949a6cb8c03096a1b4f993212e90ac3f3523852ad6e69540c4f23c79d20fa32`, against which the signature recovers `0x18b0de52E5078780Ba2F2363C71d62f10Ed1097e`; the signature with `s` replaced by `n − s` is refused (TAP-11 §4.4). With an empty `scope` the digest is `0xd281706a18bd563a691f86b6dc508ae0e63f56a9ca9e740493e81f9388cc2fcf`.

**Worked example 2: the offer behind it.** Same principal, agent, `taskHash` and `mode`; `feeToken` the zero address, `fee` `"0"`, `deadline` 1789086400, `exp` 1789003600, `nonce` `"1"`; `encodeData` is `TASK_OFFER_TYPEHASH`, the two addresses, `taskHash`, `0`, `0`, `0`, `0x6aa34ac0`, `0x6aa20750`, `1`.

| Step | Result |
|---|---|
| `structHash` | `0x4db3cd61f9e10376284fd8c893aef2712a17133e323d0f7606226ccf4e32e503` |
| `digest` = `offerHash` | `0x81a04adea0ea7cf95587504002a3de06720ef082681c468fef256e786f224c69` |
| `sig` | `0x2caee43461c34b03a3f6b1df503743c366bf3d9dd1cf104c92eceff95e35bbaf7da151e8ca04b950df785d69bf28952eb5e447929395a7c543a2a1092084d2c81c` |
| recovers | `0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A` |

The offer and the mandate agree in `principal`, `taskHash`, `mode` and `nonce` (§7.4). The first verdict in `vectors.json` names this `mandateHash`; the first revocation lists it and the empty-scope mandate.

**Not covered by vectors yet**: the thread state machine (§7.4–§7.6), agent receipts (§7.2), evidence (§8) and the revocation file (§6.2) are covered by the reference implementation's tests, not by vector files; TAP-13's `envelope.json` covers the receipt signature. Vectors are planned before Review.

## Reference Implementation

TapeAPI 1.7.0 at commit [`a9e09da2662b08ad2f16565fccac68f4f3ad2589`](https://github.com/BruceLanLan/tapeapi/tree/a9e09da2662b08ad2f16565fccac68f4f3ad2589) (MIT licensed, experimental, not audited); paths are relative to that commit:

- `sdk/src/agent-sig.js`: §3;
- `sdk/src/agent-verify.js`: §4–§8 and §10 (`createAgentKit`);
- `sdk/src/agent-pay.js`: §9 payment (TAP-10 §16 content, §19 verification, unsigned transfers);
- `sdk/types/agent.d.ts`: the interface;
- `spec/vectors/container-agent.json`, checked by `spec/vectors/verify.py` (independent Python) and `contracts/test/AgentMandateTypehash.t.sol` (Solidity);
- `examples/agent-service/`: an agent runtime and a principal's script that run a thread on a simulated chain.

The differences from this text are listed under Backwards Compatibility.

## Deployments

None. This TAP deploys no contract. Resolving the principal, the agent and providers and reading the revocation file use the contracts listed under Deployments in TAP-11; payment verification uses those of TAP-10.

## Security Considerations

The attackers considered are a dishonest agent or principal, a provider, whoever can write the principal's site, lying nodes, a console that shows the holder something other than what it asks the holder to sign, and the network path.

- **No enforcement.** A phase-0 mandate stops nothing: the agent can call providers outside its scope, keep working after expiry or revocation, or do nothing, and providers do not see mandates. A mandate limits what an agent can **claim** to be authorised to do. Every result says `enforcement: none`.
- **No money.** A mandate names no amount or asset (§3.6); nothing here moves or authorises funds; a `fee` is a statement. A payment is a separate transfer, checked under TAP-10 §19 and unrelated to the mandate.
- **Signing habit and the console.** Holders who sign phase-0 mandates get used to approving a `TapeAPI` prompt naming the hub with zero amounts; a later phase giving those fields meaning, or a phishing page filling them, exploits that habit. The wallet shows every field and the domain, not the task text behind `taskHash`. A malicious console can build any typed data, and a refusal in an honest library does not bind it; a console that does not check `chainId` could obtain a signature for another chain. Wallet rendering of these types has not been tested. The type hashes differ from every other type known in the domain (Test Cases).
- **Current holder.** Signatures are checked against the holder at verification time (§4); when the circuit changes hands, everything the former holder signed stops verifying, with the history of past threads. The revocation file passes to the buyer with the site: the buyer can overwrite or remove it, and the seller's mandates no longer verify anyway, so the file binds no one across a transfer.
- **Revocation is partial.** A direct revocation reaches its recipient only; the file cannot reach a verifier that checked earlier. Before a mandate exists only a revocation by date applies, cancelling every such thread of that principal. **Fail-open path**: a verifier without a floor (§6.3) reads a removed file as none published, so whoever can write the site (holder, operator, compromised server, buyer of the circuit) revives every revoked mandate for it by deleting the file; with a floor it sees `revocation-unavailable`. A file with the floor's `issued` is accepted whatever its content, so a site writer can switch between two lists signed with one `issued`. Floors and nonce records kept in memory are lost on restart.
- **Times are claims.** An agent message's `ts` is the agent's statement, and §7.2 applies no time window, so `offer-expired`, `deliver-outside-mandate`, `deliver-before-accept` and `message-after-revocation` constrain an honest agent's record, not a dishonest agent: one that keeps working after a revocation can date its delivery before it. A holder chooses `issued`: a verdict cannot predate the delivery, but a revocation can be backdated before a genuine delivery, which then appears signed after it and the thread `Cancelled`. A verifier cannot tell these apart; each party's own copy is its record.
- **Threads are what is presented.** A verifier checks the messages a party shows, in its order; holder messages carry no time to order them. Omitting a message (a revocation, a rejection) proves nothing.
- **Nonce reuse** is visible only to a verifier that keeps nonces (§5.2). If an agent announces one agent key for two offers whose other fields agree, a mandate and its evidence for one task could be shown for the other; `mandate.nonce` = `offer.nonce` prevents that if the principal uses a new nonce per offer. The agent key is bound, never used, in phase 0.
- **Evidence.** Receipts prove that the listed calls were answered and signed by the named providers' current signers at the stated times; not that the calls were needed, the answers right, or the deliverable correct. `taskHash` binds the task text, not the result. Receipts stop verifying when a provider rotates its signer. Hash-only receipts hide only what cannot be guessed: low-entropy params or a short body can be confirmed by hashing candidates.
- **Agent receipts checked later.** An agent message is bound to its thread by the `offerHash` or `mandateHash` in its signed result; a compromised agent signer can sign messages for any thread until its delegation ends (TAP-11 §7.2).
- **No arbiter.** A principal can reject or ignore a correct delivery (shown as unaccepted); an agent can deliver garbage. Neither can make the other pay.
- **Self-hire** is flagged, not prevented; one person can run many containers with different holders. Task counts raise the cost of a fake history and prove nothing.
- **Text is data.** Tasks, deliverables and reasons may carry instructions aimed at an agent's model, look-alike names or invisible characters; §10 reduces prompt injection, it cannot remove it.
- **EIP-1271.** A verifier that declines EIP-1271 cannot serve a principal held by a contract such as a Safe.
- **Payment checks.** TAP-10 §19 binds a transfer to a message, not to a task; a verdict hash in a body is a claim. A later check needs public nodes that still serve that block's logs or receipts.
- **Nodes and contracts.** Strict agreement does not defeat every configured operator lying together. Every guarantee rests on the contracts TAP-11 resolution reads and on the container's `isValidSignature`, which their owners can change until sealed.
- **Clock and privacy.** Windows are compared with the verifier's clock or the chosen `at`. TAP-13 calls show the agent the principal's address and messages; on chain phase 0 leaves only the revocation file and any payment.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
