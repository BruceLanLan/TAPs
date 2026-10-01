---
tap: TBD
title: Attested Reads from Independent Container Services
description: How a client asks several independent container services the same read-only question about a chain, accepts the answer only when every signed answer is identical, and keeps two conflicting signed answers as evidence.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/17
status: Draft
type: Application
created: 2026-09-30
requires: TAP-10, TAP-11, TAP-draft-signed-responses
license: CC0-1.0
---

# TAP-TBD: Attested Reads from Independent Container Services

## Summary

A way to ask several online services, each run by a different TapeOut circuit owner, the same question about a blockchain, and to accept the reply only when all of them sign exactly the same answer.

## Abstract

An **attested read** is a method, offered by a service under TAP-11 and answered in signed envelopes under TAP-draft-signed-responses, that returns the raw result of a read-only `eth_call` on a named chain together with the block number and block hash it was evaluated at. This TAP defines the method descriptor member that marks such a method, its request and result, how a provider chooses the block and evaluates the call, when two services count as independent (different container, different holder, no shared origin, different signer), and the client rule: send the same request with an explicit block number to at least two independent services, and accept only if every signed answer is identical; any disagreement rejects the read, whatever the count. It also defines an optional **contradiction record**: two signed answers to the same request at the same block that differ, which anyone can check against the signers that the services' manifests resolve. Node agreement and pinned blocks for reading TapeOut chains remain those of TAP-10 §5; this TAP applies the same rule one level up, to services instead of nodes.

## Motivation

Applications on one chain often need a fact from another: a token balance on Ethereum, the holder of an NFT on Base, whether a contract on BNB Smart Chain is in a given state. A browser application usually has no node of its own for that chain. Public RPC endpoints answer anonymously and sign nothing, so a wrong answer cannot be attributed, kept or shown to anyone. Oracle committees and light-client bridges solve this with a new set of trusted parties and new contracts.

TAP-10 §5.2 already states the rule the TapeOut kernel uses for its own reads: several operators must agree, any disagreement rejects, and there is no majority vote. TAP-11 gives an off-chain service an identity that anyone can check on chain (a circuit, its container, its holder, a delegated signer), and TAP-draft-signed-responses makes every answer of such a service a signed statement bound to the question. What is missing is an agreed method shape, an agreed notion of when two services are different parties, and an agreed client rule, so that services and clients written by different people can combine answers safely. This TAP supplies those, and nothing else: no contract, no staking and no change to TAP-10 or to the two drafts it builds on.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms and notation

- **Container**, **holder**, **operator**, **answer**, **default agreement**, **pinned block**: as defined in TAP-10 §1 and §5.
- **Service**, **manifest**, **method descriptor**, **signer**, **resolved**: as defined in TAP-11 §1–§3. **Envelope**, **request object**, **live endpoint**, and the verification outcomes *accepted result*, *accepted error*, *own request malformed*, *binding failure*, *transport failure* and *rate limited*: as defined in TAP-draft-signed-responses §1–§8.
- **Target chain**: the EVM chain named by the request's `chainId`. It need not be a chain of the TAP-10 chain table (TAP-10 §2.1).
- **Provider**: whoever answers for a service at its live endpoints. **Upstream nodes**: the JSON-RPC nodes of the target chain that a provider reads.
- **Attested-read method**: a method whose descriptor carries the member `attestedRead` of §2.
- Hex strings are `0x`-prefixed and lowercase, as in TAP-10 §1. An **integer** is a JSON number with no fraction or exponent, in the range 0 to 2^53 − 1 (the range that canonical JSON admits, TAP-11 §6).

### 2. Method descriptor

A service offers an attested read by listing, in its manifest's `methods` (TAP-11 §3.3), a method descriptor with the member `attestedRead`. Example (the price is an example value):

```json
{ "name": "read", "priceBEM": "0.0001",
  "params": { "chainId": "number", "call": "object", "block": "string|number" },
  "returns": { "chainId": "number", "blockNumber": "number", "blockHash": "bytes32", "result": "bytes" },
  "attestedRead": { "kind": "eth_call", "chains": [1, 8453, 56] } }
```

- `attestedRead` MUST be an object with the members `kind` and `chains`.
- `kind` MUST be the string `"eth_call"`. A client MUST NOT treat a descriptor whose `kind` has another value as an attested-read method under this TAP. Other kinds (logs, receipts, non-EVM chains) are left to later TAPs, which MUST use a different `kind` string.
- `chains` MUST be a non-empty array of distinct positive integers: the chain IDs the provider serves. It is what the descriptor offers in the sense of TAP-draft-signed-responses §6: a chain it does not list is not offered (§3).
- The method name is not fixed; `read` is RECOMMENDED. Clients find attested-read methods by the member `attestedRead`, not by name.
- `params` and `returns` are informative, as in TAP-11 §3.3. The price and its payment are those of the manifest and are outside this TAP.

### 3. Request

A client calls an attested-read method as TAP-draft-signed-responses §3 defines. `params` MUST be an object with these members and no others:

| Member | Required | Content |
|---|---|---|
| `chainId` | yes | An integer: the chain ID of the target chain. A chain that the descriptor's `chains` does not list is not offered (below) |
| `call` | yes | An object with exactly the members `to` (an address: `0x` and 40 hex digits) and `data` (`0x` followed by an even number of hex digits, possibly none) |
| `block` | no | An integer block number, or one of the strings `"latest"`, `"safe"`, `"finalized"`. When absent, it is read as `"finalized"` |

A provider:

- MUST answer an integer `chainId` that its descriptor does not list with a signed `METHOD_NOT_FOUND`: the request asks the method for something outside what its descriptor offers (TAP-draft-signed-responses §6);
- MUST answer any other `params` that break this section with a signed `BAD_REQUEST`, with the addresses and hex digits of `call` accepted in either case;
- MUST evaluate the call on the target chain only.

### 4. Evaluation by the provider

1. **Upstream reads.** A provider reads the target chain through upstream nodes that carry operator labels as in TAP-10 §5.1. The block hash of step 3 and the outcome of step 4 MUST be adopted under default agreement (TAP-10 §5.2) among the provider's upstream nodes, in the place of a client's nodes, and without the single-node allowance of that section; a tag or head in step 2 MUST be taken from the reports of at least two different operators. A provider SHOULD confirm with `eth_chainId` that its upstream nodes are on the target chain, as TAP-10 §5.4 does for TapeOut chains.
2. **Block number.** A `block` integer is used as given. `"finalized"` and `"safe"` resolve to the lowest block number that the provider's counted upstream operators report for that tag. `"latest"` resolves to the lowest head those operators report, minus a lag the provider configures. When `block` is absent and the upstream nodes do not support the `finalized` tag, the provider MAY instead use the lowest head minus a lag no smaller than the target chain's usual reorganization depth; an explicit `"finalized"` or `"safe"` MUST NOT fall back this way. A provider MAY refuse, with a signed `INTERNAL` without revert data, a block it cannot serve.
3. **Block hash.** The provider adopts the hash of that block number (`eth_getBlockByNumber`).
4. **Call.** The provider evaluates `eth_call` with `{ "to", "data" }` from `call` at the EIP-1898 block parameter `{ "blockHash": <that hash>, "requireCanonical": true }`, so that the result belongs to the hash it reports even if a node reorganizes between steps 3 and 4. Only when an upstream node rejects the EIP-1898 block parameter itself (not when the call reverts) MAY the provider evaluate at the block number instead, and it MUST then set `blockRef` to `"number"` (§5).
5. **Revert.** When the adopted outcome of step 4 is an execution revert, the provider MUST answer with a signed `INTERNAL` error whose `message` is `"execution reverted"` and whose `data` is `{ "revert": <the revert bytes as hex> }`, as TAP-draft-signed-responses §6 permits, and not with a result.
6. **Other failures.** Any other failure, including upstream disagreement, is a signed `INTERNAL` without `data`.

### 5. Result

The `result` of an envelope that answers an attested read MUST be an object with exactly these members:

| Member | Type | Content |
|---|---|---|
| `chainId` | integer | The request's `chainId` |
| `blockNumber` | integer | The block number of §4 step 2; equal to the request's `block` when that is an integer |
| `blockHash` | hex string | The block hash of §4 step 3: `0x` and 64 hex digits |
| `result` | hex string | The raw return data of the call, `0x` followed by an even number of hex digits |
| `stateRoot` | hex string | OPTIONAL. The state root of that block, `0x` and 64 hex digits |
| `blockRef` | string | OPTIONAL. `"hash"` when the call was evaluated at `blockHash` (the meaning when absent); `"number"` when it was evaluated by number (§4 step 4), and then REQUIRED |

All members are covered by the envelope's signature. The envelope's own optional `block` member (TAP-draft-signed-responses §4) is unsigned and unrelated to `blockNumber`.

### 6. Independent services

Two resolved services are **independent** when all of the following hold:

1. their container addresses differ;
2. their holders, as resolved under TAP-11 §2.2 step 1 (never a value from a manifest), differ;
3. no origin appears in the `endpoints.live` of both. The origin of a URL is its scheme, host and port (RFC 6454), with the host compared case-insensitively and a missing port read as 443 for `https`. Every listed URL counts, not only the one a client happens to call;
4. their signers, as resolution returns them (TAP-11 §2.2 step 8), differ.

In items 1, 2 and 4, addresses are compared case-insensitively and regardless of the chain each service lives on.

A client MUST NOT count two services that are not independent as two answers. These conditions can be checked with data that resolution already provides; they do not show that two services are run by different parties or use different upstream operators, which a client cannot verify. A client SHOULD prefer services it believes to read the target chain through different operators.

### 7. Client rule

A client that acts on an attested read MUST follow this section.

#### 7.1 Selecting services

The client chooses a quorum `q`, an integer of at least 2, and selects `N ≥ q` services such that:

- each was resolved under TAP-11 §2 with the outcome "resolved";
- each lists an attested-read method whose `chains` contains the target `chainId`;
- every two of them are independent (§6).

If the selection breaks this, the client MUST NOT send the read.

#### 7.2 Choosing the block

Every request of one attested read MUST carry the same integer `block`. The client MUST NOT send a tag (`"latest"`, `"safe"`, `"finalized"`) or omit `block` in this round: two providers resolve a tag at different moments and honest answers would differ. The client obtains the number either from a separate request with a tag to any one service, whose result names the block it used (§5), or from nodes of the target chain that the client itself reads (for a chain of the TAP-10 chain table, the pinned block of TAP-10 §5.3 is one such number). An answer to that separate request carries different `params` and is not part of the round. The client SHOULD choose a block at or below the target chain's finalized block.

#### 7.3 Sending

The client sends each selected service a request under TAP-draft-signed-responses §3 to that service's attested-read method, with the same `params`; each request carries its own `id`, as that section requires. The container in each digest keeps the answers of different services apart.

#### 7.4 Classifying each service's answer

The client verifies each HTTP answer under TAP-draft-signed-responses §8 against that service's container and signer, and classifies the outcome:

- An *accepted result* is an **answer**. Its result MUST conform to §5, its `chainId` MUST equal the request's `chainId`, and its `blockNumber` MUST equal the request's `block`. A result that does not is a **nonconforming answer**: it agrees with no other answer and is never accepted.
- An *accepted error* with code `INTERNAL`, `message` `"execution reverted"` and `data.revert` a hex string is a **revert answer**: a signed statement that the call reverts at that block.
- Any other *accepted error* is a **refusal**.
- *Own request malformed*, *binding failure*, *transport failure* and *rate limited* give no answer.

Refusals and services without an answer lower the number of answers and SHOULD be reported, but are neither agreement nor disagreement, so that one provider that cannot serve a block cannot veto the others.

#### 7.5 Agreement

- Two answers **agree** when their `chainId`, `blockNumber`, `blockHash` and `result` are identical and, if both carry `stateRoot`, their `stateRoot`s are identical. `blockRef` is not compared. Integers are compared as numbers and hex strings character for character.
- Two revert answers agree when their revert bytes are identical, compared case-insensitively.
- A revert answer and an answer never agree. A nonconforming answer agrees with nothing.

No tolerance, rounding or reinterpretation of the bytes is applied.

#### 7.6 Decision

The client assigns the first outcome that applies:

1. **Disagreement**: some two of the answers (answers, revert answers and nonconforming answers) do not agree. The client MUST reject the read, however many of the other answers agree with each other. It MUST NOT resolve a disagreement by majority, by reputation, or by asking only some of the services again. It MAY start a new attested read with a different selection, but MUST NOT combine answers from different reads.
2. **Too few answers**: fewer than `q` services gave an answer or a revert answer.
3. **Reverted**: the answers are revert answers. No result is accepted.
4. **Accepted**: at least `q` answers, all of which agree. The accepted result is their common `chainId`, `blockNumber`, `blockHash` and `result`.

A client MAY also reject an accepted read in which any answer has `blockRef` `"number"`.

#### 7.7 Use of an accepted read

An application that claims to follow this TAP SHOULD NOT release funds, or otherwise transfer value, on the strength of an attested read alone, and SHOULD NOT use attested reads as the primary price source of a lending protocol. Such an application combines the read with something that does not rest on the client's choice of services, such as its own nodes of the target chain or a proof against `blockHash`, or limits the value that a wrong read can move.

### 8. Contradiction records (optional)

A disagreement leaves signed statements that anyone can check again. This section is OPTIONAL; a client that implements it MUST follow it.

#### 8.1 Statement and block

For a result of §5:

- its **block** is the object `{ "chainId", "blockNumber", "blockHash" }` with the result's values, `blockHash` in lowercase;
- its **statement hash** is `keccak256(utf8(canonicalJSON({ "result": <the result's result member> })))`, with `canonicalJSON` as in TAP-11 §6. `stateRoot` and `blockRef` are not part of the statement.

#### 8.2 Format

A contradiction record is a JSON object:

| Member | Content |
|---|---|
| `tapeapiContradiction` | The integer `1` |
| `request` | The request object `{ "method", "params" }` of TAP-draft-signed-responses §3 |
| `requestHash` | `keccak256(utf8(canonicalJSON(request)))`, the request hash of TAP-draft-signed-responses §5, as hex |
| `block` | The block (§8.1) that both envelopes name. OPTIONAL |
| `envelopes` | An array of exactly two objects, each `{ "container", "signer", "id", "ts", "ok": true, "result", "sig", "resultHash" }`: the service container, the signer the builder resolved for it, and the `id`, `ts`, `result` and `sig` of an envelope with `ok` `true`. `resultHash` is the statement hash of `result` and is OPTIONAL |

A client MAY build a record from two accepted results that answer the same request object, name the same block and have different statement hashes, for example after a disagreement under §7.6. Revert answers are not recorded in this version.

#### 8.3 Verification

A verifier performs these steps in order. A failure in steps 1 to 7 makes the record **invalid**.

1. `tapeapiContradiction` is `1`; `request.method` is a string (an absent `request.params` is read as `{}`); `envelopes` has exactly two elements.
2. `requestHash` equals the request hash computed from `request` (compared case-insensitively).
3. In each envelope, `ok` is `true`, `container` and `signer` are addresses, `id` is a string, `ts` is an integer and `sig` is a string; and the address recovered under TAP-draft-signed-responses §5, from `container`, `id`, the request object, `ok` `true`, `result` as the body, `ts` and `sig`, equals `signer` (compared case-insensitively).
4. Each `result` has an integer `chainId`, an integer `blockNumber` and a `blockHash` of `0x` and 64 hex digits in either case.
5. Where `resultHash` is present, it equals the statement hash of that `result`.
6. The two blocks are identical, and equal to `block` when `block` is present.
7. The two statement hashes differ.
8. For each envelope, the verifier resolves the service at `container` under TAP-11 §2, with the container address as input (§2.1 of that TAP; the `chainId` of the block names the target chain, not the chain the service lives on). The signer compared is the one that resolution returns (TAP-11 §2.2 step 8), never the record's own `signer` member (TAP-11 §4.5). If either service resolves with a signer other than its envelope's `signer`, the record is **invalid**. Otherwise, if either does not resolve, or cannot be resolved, the record is **unconfirmed**.
9. Otherwise the record is **confirmed**.

A confirmed record is of kind **self** when both envelopes have the same `container` and the same `signer`, and **cross** otherwise. It is **weak** when either result has `blockRef` `"number"`.

A verifier MUST NOT present an unconfirmed record as evidence against a service, and MUST NOT present a cross record as evidence that one particular service of the two is wrong.

## Rationale

- **Services, not nodes.** TAP-10 §5 combines nodes of one chain that the client reads itself. A client often has no node for the target chain, and a node's answer is unsigned. A service here has an identity that resolution checks on chain, and its answers are signed statements bound to the question, so a wrong answer is attributable and can be kept. The rule for combining them is TAP-10 §5.2's, unchanged: at least two, all identical, never a majority.
- **Reject on any disagreement.** A majority rule would turn three services into a committee whose threshold is the new target. Requiring every verified answer to agree keeps the failure mode a denial of service, never a wrong answer, as long as one honest independent service is in the selection.
- **Block-anchored answers, an explicit number in the round.** `blockNumber` and `blockHash` make an answer a statement about one state, so two answers are comparable, and evaluating at the hash (EIP-1898) ties the result to the hash reported. The service asked first for the number cannot bias the result: every other provider adopts the hash of that number from its own upstream nodes, so a wrong or orphaned block yields disagreement or a refusal, not a wrong agreed answer.
- **Independence by container, holder, origin and signer.** All four can be checked from resolution alone. A different signer is necessary, not sufficient: one party can give each of its services its own key at no cost, but two services that share a signer are certainly controlled by whoever holds that key, and the check costs nothing. Weaker notions, such as different labels, can be met by one party at no cost. Stronger notions, such as different upstream operators or different legal owners, cannot be verified by a client.
- **Refusals are neutral; reverts are statements.** A provider that lacks a block must not be able to veto the others, so a refusal only lowers the count. A revert is chain state, so it is compared like a result, and a group of reverts is never taken as a result.
- **`METHOD_NOT_FOUND` for an unlisted chain.** `chains` is what the descriptor offers (§2), and TAP-draft-signed-responses §6 gives this code to a well-formed request for something a descriptor does not offer, so this TAP needs no code of its own. What is missing is the service's offer, as with an unknown method: a client that receives it learns that its copy of the manifest is out of date or that it selected the service wrongly (§7.1), not that its request is malformed. Under §7.4 it is a refusal either way.
- **High-value use (§7.7).** The guarantee of an accepted read is only as strong as the client's selection, and nothing is staked, so an application that claims this TAP is held to not releasing value on it alone. It is a recommendation rather than a prohibition because the application knows the value at stake and what else it checks, and this TAP does not.
- **Contradiction records are optional and prove little on their own.** Anyone can sign envelopes that name someone else's container; a record binds a service only once its signer is confirmed by resolution (§8.3 step 8). Nothing is staked or slashed; a record is evidence for reputation, and for a later proof against `blockHash`.
- **Left out.** A tolerance for derived values such as prices, a mode that accepts a dominant group despite dissent, a single-provider mode, random second opinions and provider staking. Each weakens or extends the rule above and can be proposed separately.

## Backwards Compatibility

This TAP adds a method descriptor member, a request and result profile, a client rule and a record format. It changes nothing in TAP-10, TAP-11 or TAP-draft-signed-responses; it uses the error code `METHOD_NOT_FOUND` of TAP-draft-signed-responses §6, in the meaning that section gives it, for a chain that a method does not list (§2, §3). A client that does not implement it ignores `attestedRead` as an unknown member (TAP-11 §3.1).

**History and frozen names.** This specification was first published in the TapeAPI repository as "TAP-23" (renamed "TAPI-23" on 2026-09-30; neither is a TAP number). The editors assign this TAP's number. The names `attestedRead`, `"eth_call"` and `tapeapiContradiction` are historical and never change; none of them encodes a TAP number. The earlier text described the client rule as that of the tape:// specification; the rule referred to is TAP-10 §5.2.

**Differences between this text and the reference implementation** (commit `fda84db`), and the planned changes:

| Area | Reference implementation today | This TAP | Plan |
|---|---|---|---|
| Descriptor checks | Treats any truthy `attestedRead` as an attested-read method; checks that `chains` is an array containing the `chainId`, but not `kind` or the form of `chains` | §2 | Check `kind` and `chains` |
| Provider `params` | The example provider ignores members of `params` and `call` other than those of §3 | Refused with `BAD_REQUEST` (§3) | Refuse them |
| Answer checks | Compares `chainId`, `blockNumber`, `blockHash`, `result` and `stateRoot` as described, but does not check that `chainId` and `blockNumber` echo the request, that no other member is present, or that hex is lowercase; takes any signed error carrying hex `data.revert` as a revert answer, without checking `code` and `message` | §7.4: a nonconforming answer is never accepted and causes rejection; a revert answer is an `INTERNAL` with `message` `"execution reverted"` | Add the checks |
| `block` form | The client accepts, and the example provider serves, a block number given as a decimal or `0x` hex string | An integer (§3, §7.2) | Keep accepting strings; send integers |
| Request `id` | `callQuorum` sends the caller's `id`, when one is given, to every service; otherwise each request gets a fresh one | Each request has its own `id` (§7.3) | Derive a distinct `id` per service |
| Signer check | `callQuorum` does not compare the signers of the selected services: two services whose manifests name the same signer, and that pass the other three checks, are counted as two | §6 item 4: not independent, so the read is refused before any request (§7.1) | Add the check in a 1.x release as an option, off by default so that existing callers are unaffected; a client that follows this TAP turns it on |
| Upstream chain check | The example provider does not call `eth_chainId` | Recommended (§4 step 1) | Add the check |
| Options outside this TAP | `callQuorum` offers `onDissent: 'quorum'` (accept a dominant group), `allowSingleProvider` and a numeric tolerance (`compare`), each off by default (the tolerance is refused for attested reads) | Not part of this TAP; a read that uses them does not follow it | Document them as outside this TAP |
| Outcome names | `ATTEST_DISAGREE` for a disagreement; `QUORUM_FAILED` for too few answers, reverted, and a selection or `block` that breaks §7.1–§7.2 | §7.6 names | Add the §7.6 name to each error, keeping the codes |
| Contradiction records | Also builds and checks records for other methods whose results carry a `blockPinned` object; the signer check is a caller-supplied function, and the first envelope whose check fails or throws decides between invalid and unconfirmed; `chainId` and `blockNumber` may be negative | Attested-read results only (§8.1); signer confirmed by resolution, invalid taking precedence (§8.3 step 8); integers as in §1 | Document `blockPinned` records as outside this TAP; pass a resolver as the signer check; let invalid take precedence; check the integer range |

The differences in how the reference implementation resolves a service are listed in TAP-11 and apply here unchanged. No live service offers an attested-read method at the time of writing: the author's service `11.1013.tape` pins its answers to blocks but lists no `attestedRead` descriptor.

## Test Cases

The vector files are in `assets/tap-draft-attested-reads/` (the directory name follows the question in #7). Keys, containers, holders and endpoints in them are test values; the private keys are published test keys. The services are given as already resolved: container, holder, signer and live endpoint are inputs, not read from a chain. The Ethereum values are real: `totalSupply()` of `0xdAC17F958D2ee523a2206206994597C13D831ec7` at block 20000000 (hash `0xd24fd73f794058a3807db926d8898c6481e902b7edb91ce0d479d6760f276183`) returns `0x00000000000000000000000000000000000000000000000000b8bc8118ccdd50`, read on 2026-09-28 with identical answers from four node operators. The `id` `tap23-vector-1` is an opaque test value kept from the earlier vectors; to keep their signatures unchanged, the vectors use it in the request to every service, whereas a client following §7.3 gives each request its own `id`. No outcome depends on it.

**`attested-read.json`** (§2–§7). Three services A, B and C (containers `0x…0a77e1`, `0x…0a77e2`, `0x…0a77e3`; test keys `0x44…44`, `0x55…55`, `0x66…66`; different holders and origins), the descriptor, the request `{ "chainId": 1, "call": { "to": "0xdAC17F958D2ee523a2206206994597C13D831ec7", "data": "0x18160ddd" }, "block": 20000000 }`, and 15 cases. Each case lists the signed envelopes with their digest, EIP-191 digest and recovered address, the expected §7.6 outcome, and what the reference implementation reports:

- **accepted**: A and B return the same block and bytes; only A carries `stateRoot`; A and C agree while B refuses;
- **disagreement**: B's `result` is one unit higher; B names another hash for block 20000000; both carry `stateRoot` and they differ; B answers a signed revert and A a result; A and C agree while B signs a different result;
- **reverted**: A and B answer the same signed revert;
- **too few answers**: B refuses (a signed `INTERNAL` without revert data); A's envelope is presented as B's (a binding failure);
- **refused before any request**: A and B have the same holder, B lists an endpoint on A's origin, or B's manifest names A's signer (§6, §7.1); the round names the block by `"finalized"` (§7.2).

The first five cases, with their signatures, are the earlier TapeAPI vectors unchanged.

**`contradiction-record.json`** (§8). The record built from the third case (`requestHash` `0x0d39710a73ea5142cd10f23a4a8a36fc74daeedb07716cc59728d881463e4938`, statement hash of A's result `0xc8de91d1d34d36aee2ff49579c03994b3162f10e9bee460982c940a5419e4922`) and 8 verifications: confirmed cross; unconfirmed when the signers are not checked; invalid when A's container resolves to another signer; invalid after B's result, the request or B's `signer` is altered; confirmed self when A signs two different results; weak when one result has `blockRef` `"number"`. Two pairs that make no record: different block hashes (the fourth case) and identical statements (the first case).

The reference implementation at the commit below reproduces every case but one when the envelopes are given to its `callQuorum` as HTTP answers, as its `sdk/test/attested-vectors.test.mjs` does for the first five; the records are built and checked with its `security.contradictionRecord`, `security.contradictionsOf` and `security.verifyContradiction`.

The exception is the case in which B's manifest names A's signer. Its expected outcome follows from §6 item 4, which the reference implementation does not implement yet (Backwards Compatibility): it sends both requests and accepts. The case says so (`referenceImplementation.implementsRule` is `false`) and, unlike the other cases refused before any request, carries the two signed answers that an implementation without the check receives; B's envelope names B's container and is signed with A's key. That envelope was generated with the reference implementation at the commit below, and its digest, EIP-191 digest and recovered address were checked by an independent Python implementation of the envelope signature, which also derives every expected outcome, this one included, from §6 and §7.

## Reference Implementation

TapeAPI 1.3.0, at commit [`fda84db889d2a732915f264a799af24073177a85`](https://github.com/BruceLanLan/tapeapi/tree/fda84db889d2a732915f264a799af24073177a85) (MIT licensed):

- [`sdk/src/index.js`](https://github.com/BruceLanLan/tapeapi/blob/fda84db889d2a732915f264a799af24073177a85/sdk/src/index.js) (`callQuorum`): the client rule (§6, §7);
- [`sdk/src/security.js`](https://github.com/BruceLanLan/tapeapi/blob/fda84db889d2a732915f264a799af24073177a85/sdk/src/security.js): contradiction records (§8);
- [`examples/chain-attested-read/index.mjs`](https://github.com/BruceLanLan/tapeapi/blob/fda84db889d2a732915f264a799af24073177a85/examples/chain-attested-read/index.mjs) and [`examples/_lib/chain.mjs`](https://github.com/BruceLanLan/tapeapi/blob/fda84db889d2a732915f264a799af24073177a85/examples/_lib/chain.mjs): a provider for Ethereum and Base (§2–§5);
- [`sdk/test/attested-vectors.test.mjs`](https://github.com/BruceLanLan/tapeapi/blob/fda84db889d2a732915f264a799af24073177a85/sdk/test/attested-vectors.test.mjs) and [`spec/vectors/verify.py`](https://github.com/BruceLanLan/tapeapi/blob/fda84db889d2a732915f264a799af24073177a85/spec/vectors/verify.py): the earlier five cases, replayed through `callQuorum` and checked by an independent Python implementation of the envelope signature.

In that commit the files still carry the earlier name "TAP-23". The differences from this text are listed under Backwards Compatibility. The implementation has not been audited.

## Deployments

None. This TAP deploys no contract and depends on none directly. Resolving a service uses the contracts listed under Deployments in TAP-11, which refers to TAP-10. The target chain's contracts are whatever the request names.

## Security Considerations

The attacker considered can run services of its own under any number of circuits, can control some of the selected providers or their upstream nodes, and can read, delay, drop and modify traffic between client and providers.

**What the design protects.**

- **A single provider that lies.** A wrong result, a wrong block hash, a hidden revert or a false state root from one provider disagrees with every honest independent provider in the selection, and the read is rejected. The lie is signed, so it is attributable and can be kept as a contradiction record.
- **Some providers colluding.** As long as at least one selected provider answers honestly, colluding providers can cause a rejection but cannot make the client accept a wrong result, because acceptance needs every answer to agree (§7.6).
- **Tampering and confusion.** Every answer is verified under TAP-draft-signed-responses, so an altered or relabelled answer is a binding failure; `chainId`, `blockNumber` and `blockHash` are signed and must echo the request, so an answer for one chain or block cannot pass as another.
- **Reorganizations.** Evaluating at the reported hash (§4 step 4) means a result cannot silently come from another fork than the one it names; an answer by number says so in `blockRef`.

**What it does not protect.**

- **All selected providers colluding**, or all of them reading through the same lying upstream operator, produce an accepted wrong result. The guarantee is exactly "every service the client chose said the same thing", and it is as strong as that choice.
- **One party behind several services.** §6 excludes shared containers, holders, origins and signers, but one party can hold many circuits under different addresses, give each its own signer key and serve them from different domains. Holding a circuit costs little, and nothing in this TAP is staked or slashed. Two services whose manifests name the same signer are controlled by whoever holds that key, which is why §6 item 4 excludes them; different signers show no more than that the keys differ. Clients choose services by their own knowledge of who runs them.
- **The target chain itself.** A reorganization deeper than the chosen block's finality, a consensus failure, a chain whose `finalized` tag is wrong, or a contract that returns misleading data (for example an upgradeable contract changed by its owner) is reported faithfully by honest providers. An attested read says what the chain said, not that it is true.
- **Denial of service.** One provider in the selection can block every read by disagreeing. The remedy is a new read with a different selection (§7.6), not a vote.
- **High-value decisions.** Because the guarantee depends on the client's selection and nothing is staked, an attested read alone is not a sufficient basis for releasing funds or for a lending protocol's primary price; §7.7 holds applications that claim this TAP to that.
- **Trust inherited from resolution.** Which signer speaks for a service, and who its holder is, come from TAP-11 and the TapeOut contracts it reads. Until those contracts are sealed, whoever controls them can change what resolution returns (TAP-10, Deployments and Security Considerations), and this TAP inherits that assumption.
- **Contradiction records.** A record's signer check uses resolution at the time of verification. After a holder replaces the signer, or after the circuit changes hands, an older record can no longer be confirmed: §8.3 step 8 then finds it invalid (another signer) or unconfirmed (no resolution), although it held when it was made. Records are best checked soon after they are made. A cross record shows only that at least one of two services is wrong; a self record shows that one signer signed two different results for one request at one block hash (weakened when `blockRef` is `"number"`). Nothing is enforced by either.
- **Privacy.** Every selected provider learns the target chain, contract and calldata of the read, and the client's network address.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
