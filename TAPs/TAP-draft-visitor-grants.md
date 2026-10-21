---
tap: TBD
title: Visitor Grants for Container Service Calls
description: A short-lived, method-level, revocable grant that a visitor's wallet signs so that one container website may call a few named methods of another container's service on the visitor's behalf, which that service verifies, counts and records in its signed answer.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/58
status: Draft
type: Application
created: 2026-10-21
updated: 2026-10-21
requires: TAP-10, TAP-11, TAP-13
license: CC0-1.0
---

# TAP-TBD: Visitor Grants for Container Service Calls

> **Experimental.** A grant carries no payment and moves no asset. No wallet's rendering of the typed data below has been tested yet, and the reference implementation is not in any release (Reference Implementation; Open questions in the Rationale). The names `12.7.tape` and `13.7.tape` and every key in the examples and vectors are test values, not services.

## Summary

A visitor's wallet signs a short statement that lets one container website call a few named methods of another container's service for them, a limited number of times and for a short period, and that service checks the statement, counts each call, accepts a revocation, and repeats the grant in every signed answer.

## Abstract

This TAP defines **visitor grants** between container websites (TAP-10) that call container services (TAP-11, TAP-13). A grant is an EIP-712 message, `VisitorGrant`, that the visitor's wallet (an EOA or an EIP-1271 contract wallet) signs in its own domain, `"TapeAPI Visitor Grant"`. It names the calling site (container, on-chain name and holder), a one-off key that the calling page holds, the called service (container, on-chain name and holder), one to eight method names, a maximum number of calls (1 to 10,000) and a validity of at most 7 days; its first field is a plain-language statement generated from the other fields. The calling page sends the grant with each TAP-13 request as a top-level member `grant`, with a call proof that its one-off key signs over that request. The called service checks the grant in a fixed order, cheap checks first and chain reads last, counts the call, writes a grant record into the `result` it signs, and accepts revocations signed by the visitor (`GrantRevocation`, through a free method `grant_revoke`). It specifies the domain and both types with their type hashes, the statement templates in English and Chinese, the 140-byte call proof, the request member, the manifest member that marks the methods that take a grant, the answer record, the 20 refusal reasons and their order, and revocation. A grant carries no payment and is never sent together with a voucher; directories, rankings, shell permission panels, logins and on-chain registries are out of scope.

**Related drafts not yet merged.** `requires` lists only TAPs merged as Drafts (TAP-10, TAP-11, TAP-13; merging a Draft does not mean that it is accepted, TAP-01 §5). Nothing normative here depends on a draft that is not merged. The Rationale and the Open questions compare this text with the following pull requests of the TAPs repository, cited at the commits named here: [#47](https://github.com/TapeOutProtocol/TAPs/pull/47) (*Container Agent Mandates and Task Messages, Phase 0*) at [`50a5a6f92abfefb3cdde4af2c86a9b18c087a3d6`](https://github.com/TapeOutProtocol/TAPs/blob/50a5a6f92abfefb3cdde4af2c86a9b18c087a3d6/TAPs/TAP-draft-container-agent.md); [#59](https://github.com/TapeOutProtocol/TAPs/pull/59) (*Escrow Channels for Paying Container Services*) at [`098de456152615d7c289c650a8a50533ccf53df1`](https://github.com/TapeOutProtocol/TAPs/blob/098de456152615d7c289c650a8a50533ccf53df1/TAPs/TAP-draft-escrow-channels.md); [#60](https://github.com/TapeOutProtocol/TAPs/pull/60) (*Container Agent Mandates Enforced by Escrow Channels, Phase 1*) at [`42ce7aef2d16ef64c3d8ba94e255076c3db16a25`](https://github.com/TapeOutProtocol/TAPs/blob/42ce7aef2d16ef64c3d8ba94e255076c3db16a25/TAPs/TAP-draft-container-agent-phase1.md); and [#52](https://github.com/TapeOutProtocol/TAPs/pull/52) (*Payment Vouchers for Container Services*) at [`82b412495b7ee97dda6e86174e98cd051ea61bda`](https://github.com/TapeOutProtocol/TAPs/blob/82b412495b7ee97dda6e86174e98cd051ea61bda/TAPs/TAP-draft-payment-vouchers.md). The idea issues it relates to are [#58](https://github.com/TapeOutProtocol/TAPs/issues/58) (its discussion thread), [#29](https://github.com/TapeOutProtocol/TAPs/issues/29) (the shell's permission lifecycle) and [#57](https://github.com/TapeOutProtocol/TAPs/issues/57) (site metadata).

## Motivation

Container websites are isolated on purpose (TAP-10 §8): one origin per site, separate storage, and wallet permissions recorded per site. That keeps one site from reading another's data, and it also leaves each site on its own: nothing says how a page of site A asks the service of container B for something on a visitor's behalf, within limits the visitor set, and how B can tell.

TAP-11 and TAP-13 already let any page find B's service by name, call a method and verify B's signed answer. What they do not give B:

- **Who is calling, and for whom.** A TAP-13 request has no caller. A free call is anonymous; B cannot tell that a request comes from site A acting for visitor U.
- **Limits per method.** A service can only serve a method to everyone or to no one. There is no way to say "A may call `history` and `notes` for me, 100 times, for one hour", and nothing to count against.
- **Revocation the service enforces.** There is no message a visitor can send to B that makes B stop serving A for them.
- **Consent from a plain wallet.** The mandates of #47 are signed by the holder of a principal circuit for a container; a visitor who holds no circuit cannot give one, and B never sees the mandate. The shell-side permission lifecycle of #29 is local to the client and, as #29 says, a service's signature is not the visitor's consent.

A visitor grant fills only that gap. It does not change TAP-10's isolation: whether a shell lets a page send a cross-site request at all stays with the shell (TAP-10 §8.5). It defines the second door, the one at the service: whether B honours a request made on a visitor's behalf.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms and notation

- **Visitor** (`user`): the wallet that signs a grant. An EOA, or a contract wallet that answers EIP-1271.
- **Calling site** (`caller`): the container whose website asks for the grant and makes the calls, with its on-chain name `callerName` (TAP-10 §3.1) and its holder `callerHolder` (TAP-10 §4.2 step 4).
- **Caller key** (`callerKey`): a secp256k1 key that the calling site's page creates for one grant and keeps; it signs the call proof of every request made under that grant (§5).
- **Service** (`audience`): the container whose service (TAP-11) is called, with its on-chain name `audienceName` and its holder `audienceHolder`.
- **Grant**: a `VisitorGrant` message (§4) and the visitor's signature over it. **Grant hash**: the EIP-712 digest of a grant (§4.4), written `0x` and 64 lowercase hex digits.
- **Call proof**: the caller key's signature over one request (§5). **Grant record**: the member `grant` of a signed result (§6.3).
- **Hub**: the DeWEB hub address of TAP-10 §13, `0xe61A9C7213a6Aa616C246a2B569e555B417b25ee`, as TAP-11 §1 uses it.
- **Pinned block**: TAP-10 §5.3. `now` is the verifier's Unix time in seconds. **Skew**: 300 seconds.
- `keccak256`, `‖` (concatenation), `uint64(x)` (8 bytes, big-endian) and `canonicalJSON` (TAP-11 §6) are used as in TAP-13 §5. `utf8(s)` is the UTF-8 encoding of `s`.

### 2. Overview (informative)

1. The calling site's page resolves its own name and the service's name (TAP-11 §2), creates a caller key, builds a `VisitorGrant` from the values it read on chain, generates the statement (§4.3), and asks the visitor's wallet to sign it with `eth_signTypedData_v4`.
2. For every call under the grant, the page sends a TAP-13 request directly to one of the service's `endpoints.live` URLs, with the top-level member `grant`: the grant, the visitor's signature, and a call proof signed by the caller key over that request.
3. The service checks the grant (§7), runs the method, and signs a TAP-13 answer whose `result` carries the grant record: the grant hash, the caller, the visitor, the calls used and the maximum.
4. The visitor can revoke grants at that service with a signed `GrantRevocation` (§8). A grant also ends at `expires`, and when either holder changes.

No party other than the calling page and the service handles the request or the grant: there is no relay, proxy or third-party host in the call path, and no directory or ranking of services.

### 3. Domain

Both types of this TAP use this EIP-712 domain:

| Item | Value |
|---|---|
| Domain type | `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)` |
| `name` | `"TapeAPI Visitor Grant"` |
| `version` | `"1"` |
| `chainId` | The chain ID of the service's chain (TAP-10 §2.1) |
| `verifyingContract` | The hub address (§1) |

```
DOMAIN_SEPARATOR = keccak256(abi.encode(
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
    keccak256("TapeAPI Visitor Grant"), keccak256("1"), chainId, 0xe61A9C7213a6Aa616C246a2B569e555B417b25ee))
```

On BNB Smart Chain (chain ID 56), `DOMAIN_SEPARATOR` = `0xdbd05ddb38a6097675b1f87bde7ad79201d08085045992096a6f8a2f72b07d80`.

- This domain differs from the TAP-11 §4.1 domain (`name` `"TapeAPI"`). A calling site MUST NOT ask a visitor to sign any type in the TAP-11 domain as part of a grant, and a verifier MUST NOT accept a signature made in one domain or under one type as a signature in another domain or under another type.
- A grant or revocation for one chain MUST NOT be accepted on another; the chain ID makes their digests differ.

### 4. The grant

#### 4.1 Type and encoding

```
VisitorGrant(string statement,address user,address caller,string callerName,address callerHolder,address callerKey,address audience,string audienceName,address audienceHolder,string[] methods,uint32 maxCalls,uint64 notBefore,uint64 expires,bytes32 nonce)
```

`VISITOR_GRANT_TYPEHASH` = `keccak256` of the type string above (no spaces other than the single space between each type and its name, no line break) = `0xbc95bd5b4977cb089511e2e459636a0c22d7d0d29280f72043963456ac3e8f0e`.

```
structHash = keccak256(abi.encode(VISITOR_GRANT_TYPEHASH,
    keccak256(utf8(statement)), user, caller, keccak256(utf8(callerName)), callerHolder, callerKey,
    audience, keccak256(utf8(audienceName)), audienceHolder,
    keccak256(keccak256(utf8(methods[0])) ‖ … ‖ keccak256(utf8(methods[n-1]))),
    uint32 maxCalls, uint64 notBefore, uint64 expires, nonce))
digest     = keccak256(0x19 ‖ 0x01 ‖ DOMAIN_SEPARATOR ‖ structHash)
```

`methods` is hashed in the order given. The fields are in the order a wallet that shows fields in order shows them: `statement` first.

#### 4.2 Field rules

A grant is well-formed when all of the following hold. A verifier MUST refuse a grant that is not.

| Field | Rule |
|---|---|
| `statement` | A string of at most 2,048 UTF-16 code units, equal character for character to one rendering of §4.3 of the other fields |
| `user` | `0x` and 40 hex digits (either case), not the zero address |
| `caller`, `callerHolder`, `callerKey`, `audience`, `audienceHolder` | Same form as `user`. `callerKey` MUST NOT equal `user` |
| `callerName`, `audienceName` | An on-chain name in canonical form (TAP-10 §3.1), exactly as written there, on the chain `chainId` |
| `methods` | 1 to 8 strings, each matching `^[A-Za-z_][A-Za-z0-9_]{0,63}$` (the method-name pattern of TAP-11 §3.3), no string repeated. There is no wildcard |
| `maxCalls` | An integer from 1 to 10,000 |
| `notBefore`, `expires` | Integers in Unix seconds from 0 to 253,402,300,799 (9999-12-31 23:59:59 UTC), with `notBefore < expires ≤ notBefore + 604,800` (7 days) |
| `nonce` | `0x` and 64 lowercase hex digits, not zero |

A grant is valid at `now` when `notBefore ≤ now + 300` and `now < expires`. A calling site MUST NOT build a grant whose `notBefore` lies more than 300 seconds after its own `now`, and SHOULD give a grant a validity of one hour unless the visitor chooses otherwise. A calling site MUST create `nonce` from 32 random bytes.

#### 4.3 The statement

The statement is generated from the other fields with one of the two templates below and is never written by hand. In the templates, `{callerName}`, `{audienceName}` and `{maxCalls}` (decimal, no separators) are the fields; `{methods}` is the elements of `methods` in order, joined by a comma and a space (`, `); `{from}` and `{to}` are `notBefore` and `expires` written as `YYYY-MM-DD HH:MM:SS` in UTC, with four-digit year and two-digit fields.

English (`{s}` is empty when `maxCalls` is 1 and `s` otherwise):

```
Allow {callerName} to call these methods of {audienceName} on my behalf: {methods}. At most {maxCalls} call{s}, valid from {from} to {to} UTC. This grant includes no payment. Revocable at any time with {audienceName}.
```

Chinese:

```
允许 {callerName} 代表我调用 {audienceName} 的方法：{methods}。最多 {maxCalls} 次，{from} 至 {to} UTC 有效。本授权不含任何付款。可随时向 {audienceName} 撤销。
```

- Each template is a single line without a line break; the spaces and punctuation are as written, including the full-width `：`, `。` and `，` of the Chinese template and the single space around each name and number in it.
- A verifier MUST rebuild both renderings from the other fields and MUST refuse a grant whose `statement` equals neither (`statement-mismatch`).
- These templates belong to format version 1 (§6.1, `v`). A change to their wording is a new format version; the templates of version 1 never change.
- The statement contains no address and no key; the visitor reads names, methods, a count and times.

#### 4.4 Grant hash and the visitor's signature

- The grant hash is `digest` of §4.1. It names the chain, the hub and every field, so another chain, another hub or any other field gives another grant hash.
- The visitor signs `digest` itself with `eth_signTypedData_v4` or an equivalent, without the EIP-191 `personal_sign` prefix. `userSig` is `0x` followed by 65 to 1,024 bytes in hex, in either case.
- A verifier MUST accept the signature exactly when TAP-11 §4.4 would accept it for `digest` and the address `user`, read at one pinned block: ECDSA first when `userSig` is 65 bytes, with the range checks of TAP-11 §4.4 item 1, and otherwise, or when the 65-byte signature recovers to another address, EIP-1271 as TAP-11 §4.4 item 2. A verifier MAY decline to support EIP-1271; it then refuses grants that only EIP-1271 would accept.

### 5. Call proof

For each request under a grant, the caller key signs the **call proof digest**, `keccak256` of this 140-byte preimage:

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 16 | Prefix | ASCII `TAPI-grant/call1`, bytes `0x544150492d6772616e742f63616c6c31` |
| 16 | 20 | Service | The `audience` of the grant |
| 36 | 32 | Grant hash | The grant hash (§4.4) |
| 68 | 32 | Id hash | `keccak256(utf8(id))`, where `id` is the request's TAP-13 `id` |
| 100 | 32 | Request hash | `keccak256(utf8(canonicalJSON({ "method": <path segment>, "params": <params, or {} when absent> })))`: the TAP-13 §3 request object |
| 132 | 8 | Time | `uint64(ts)` |

```
eip191Digest = keccak256(0x19 ‖ "Ethereum Signed Message:\n32" ‖ keccak256(preimage))
sig          = r ‖ s ‖ v                      // 65 bytes, secp256k1 over eip191Digest, by the caller key
```

- `ts` is the calling page's Unix time in seconds when it signs. `sig` follows the rules of TAP-13 §5 for `v`, `r` and `s` (low `s`, `v` 27 or 28; a verifier reads a `v` of 0 or 1 as 27 or 28). `sig` is `0x` and 130 hex digits, in either case.
- The caller key is an EOA key; a call proof is never checked under EIP-1271.
- The prefix and the length differ from those of TAP-13 §5 (`TAPI-1/resp/v2`, 139 bytes), so a call proof is never a TAP-13 answer signature, nor the reverse.

### 6. Wire form

#### 6.1 Request

A request under a grant is a TAP-13 §3 request with one more top-level member, `grant`. An example, with values shortened:

```json
{ "id": "g-0001", "method": "history", "params": { "limit": 1 },
  "grant": { "v": 1, "chainId": 56, "message": { … }, "userSig": "0x…", "proof": { "ts": 1791000007, "sig": "0x…" } } }
```

| Member | Rule |
|---|---|
| `grant` | A JSON object with exactly the members `v`, `chainId`, `message`, `userSig` and `proof` |
| `grant.v` | The integer `1`, the format version of this TAP |
| `grant.chainId` | The integer chain ID of the domain (§3); it MUST equal the service's chain |
| `grant.message` | The `VisitorGrant` message as a JSON object with exactly its 14 fields as members: strings for the addresses, names, `statement`, `nonce`; an array of strings for `methods`; integers for `maxCalls`, `notBefore` and `expires` |
| `grant.userSig` | The visitor's signature (§4.4) |
| `grant.proof` | `{ "ts": <integer>, "sig": <string> }`, exactly these members: the call proof of §5 for this request |

- A calling site MUST send a request that carries `grant` only to one of the `endpoints.live` URLs of the resolved service named by `audienceName` (TAP-11 §2), and MUST sign a new call proof for each request it sends, including a retry of the same `id`.
- A request that carries `grant` MUST NOT carry `voucher` (TAP-13 §3).
- `grant` is not part of the TAP-13 request object and is not covered by the answer's signature; the grant record (§6.3) is.

#### 6.2 Manifest

A method descriptor (TAP-11 §3.3) MAY carry the member `grant`, with the value `"required"` or `"optional"`:

- `"required"`: the method serves only requests that carry a grant valid for it.
- `"optional"`: the method serves requests with or without a grant; without one, it runs as it would without this TAP.
- A descriptor without `grant` takes no grant: a request to it that carries `grant` is refused (`method-out-of-scope`).
- A method whose descriptor carries `grant` MUST have `priceBEM` `"0"`.
- A method that returns only public data SHOULD NOT be marked `"required"`.
- A service that accepts revocations (§8.2) lists the method `grant_revoke` with `priceBEM` `"0"` and without the member `grant`.

Clients that do not implement this TAP ignore the member, as TAP-11 §3.1 requires for unknown members.

#### 6.3 Answer

When a service serves a request under a grant, the `result` of its signed answer (TAP-13 §4) MUST be a JSON object and MUST contain the member `grant`. An example, with values shortened:

```json
{ "…": "…", "grant": { "hash": "0x…", "caller": "0x…", "user": "0x…", "used": 1, "maxCalls": 100 } }
```

| Member | Value |
|---|---|
| `hash` | The grant hash, lowercase |
| `caller`, `user` | The grant's `caller` and `user` |
| `used` | The number of calls counted under this grant including this one, from 1 to `maxCalls` |
| `maxCalls` | The grant's `maxCalls` |

- The record is inside the body, so the answer's signature covers it (TAP-13 §5).
- A method served under a grant MUST produce an object result without a member `grant` of its own. When it produces anything else, the service answers `INTERNAL` and does not count the call.
- A calling site MUST NOT treat an accepted result (TAP-13 §8) that lacks a grant record with its grant's `hash`, `caller`, `user` and `maxCalls`, and a `used` from 1 to `maxCalls`, as a call served under the grant.

#### 6.4 Refusals

A service refuses a grant with a signed TAP-13 envelope whose `error.code` is `BAD_REQUEST`, whose `error.message` begins with `grant: ` followed by one reason of the table below (optionally followed by a space and a detail in parentheses), and which carries no `error.data`. The reasons, in the order of §7:

| Reason | Step | Meaning |
|---|---|---|
| `required` | 0 | The method's descriptor says `"required"` and the request carries no `grant` |
| `malformed` | 1 | `grant` or one of its members does not follow §4.2 or §6.1 |
| `wrong-audience` | 2 | The grant names another service |
| `method-out-of-scope` | 3 | The method is not in `methods`, or a method in `methods` takes no grant here |
| `expired` | 4 | The grant is not valid at `now` (§4.2) |
| `statement-mismatch` | 5 | The statement is not a rendering of the other fields (§4.3) |
| `revoked` | 6 | The service holds a revocation that covers the grant (§8) |
| `bad-proof` | 7 | The call proof is out of the time window or not signed by `callerKey` |
| `replayed` | 8 | The grant has already been used for this `id` |
| `bad-user-signature` | 9 | The visitor's signature does not verify (§4.4) |
| `audience-holder-changed` | 10 | The service's holder is not `audienceHolder` |
| `audience-not-opened`, `audience-unpaid` | 10 | The service's own site status is `not-opened` or `unpaid` |
| `caller-name-mismatch` | 11 | `callerName` does not resolve to `caller` on this chain |
| `caller-holder-changed` | 11 | The holder of `caller` is not `callerHolder` |
| `caller-not-opened`, `caller-unpaid` | 11 | The calling site's status is `not-opened` or `unpaid` |
| `voucher-not-allowed` | 12 | The request also carries `voucher` |
| `rate-limited` | 12a | The optional window of §7.4 is full |
| `exhausted` | 13 | `maxCalls` calls have been counted |

- A failure of a chain read (an unavailable or stale node, a pinned block that cannot be chosen, a site status `store-changed`) is not a refusal: the service answers `INTERNAL`, counts nothing, records nothing, and a retry with the same `id` is checked again from step 1.
- A client that receives a refusal it does not know treats it as an error (TAP-13 §6).

### 7. Service verification

#### 7.1 Order

A service that implements this TAP MUST check a request in this order and MUST stop at the first refusal. The service knows its own container `C`, its on-chain name `N` and its manifest. Steps 1 to 8 read nothing from the chain.

0. If the request carries no `grant`: refuse `required` when the method's descriptor says `"required"`, and otherwise serve the request without a grant.
1. **Shape.** `grant` follows §6.1; `v` is 1; `chainId` is the service's chain; `message` follows §4.2 with exactly its 14 members; `userSig` and `proof` have the forms of §4.4 and §5. Otherwise `malformed`.
2. **Audience.** `audience` equals `C` (case-insensitively) and `audienceName` equals `N` (character for character). Otherwise `wrong-audience`.
3. **Methods.** The request's method is in `methods` and its descriptor carries `grant`, and every element of `methods` names a method of this manifest whose descriptor carries `grant`. Otherwise `method-out-of-scope`.
4. **Time.** The grant is valid at `now` (§4.2). Otherwise `expired`.
5. **Statement.** §4.3. Otherwise `statement-mismatch`.
6. **Revocation.** Compute the grant hash. If the service holds a revocation by this `user` that lists the grant hash, or whose `revokedBefore` is greater than the grant's `notBefore` (§8.1), refuse `revoked`.
7. **Call proof.** `|proof.ts − now| ≤ 300`, and the address recovered from `proof.sig` over the call proof digest of §5, computed from `C`, the grant hash, the request's `id`, its path segment and its `params` (`{}` when absent), equals `callerKey`. Otherwise `bad-proof`.
8. **Replay.** If a call with this grant hash and this `id` has already been counted (§7.2), refuse `replayed`, or answer as §7.3 allows.
9. **Visitor's signature.** §4.4. Otherwise `bad-user-signature`.
10. **Service identity.** At one pinned block, read the service's own holder and site status as TAP-10 §4.2 and §6.2 do. The holder MUST equal `audienceHolder`, otherwise `audience-holder-changed`; a site status `not-opened` or `unpaid` is refused `audience-not-opened` or `audience-unpaid`.
11. **Calling site.** At one pinned block, resolve `callerName` on this chain as TAP-10 §4.2 and §6.2 do. If it does not resolve to a circuit with a holder, or its container is not `caller`, refuse `caller-name-mismatch`. If its holder is not `callerHolder`, the service MUST record the grant hash as revoked for `user` until `expires` (§8.3) and refuse `caller-holder-changed`. A site status `not-opened` or `unpaid` is refused `caller-not-opened` or `caller-unpaid`.
12. **No payment.** If the request carries `voucher`, refuse `voucher-not-allowed`.
13. **Count.** Reserve one call under the grant hash for this `id` (§7.2). If `maxCalls` calls are already counted or reserved, refuse `exhausted`.
14. **Serve.** Run the method and sign the answer with the grant record (§6.3).

- Results of the reads of steps 10 and 11 SHOULD NOT be cached for more than 60 seconds (TAP-10 §11).
- A service MUST NOT take any identity in steps 10 and 11 from the request; it reads them from the chain.

#### 7.2 Counting

- A reservation (step 13) becomes a counted call only when the service accepts the method's result and signs the answer. A service MUST release the reservation, without counting, when the method fails, when its result breaks §6.3, when the call is answered `INTERNAL`, or when the service's own time bound for the call (TAP-13 §4, "Transport") passes before the method finishes. A method that finishes after that time bound MUST NOT be counted.
- A reservation for a grant hash and `id` that is still open makes a second request with the same grant hash and `id` a replay (step 8 or 13).
- The pair (grant hash, `id`) is recorded as used only when the call is counted, so a request that failed on a chain read or a time bound can be retried with the same `id`.
- A service MUST keep the counts and used pairs of a grant at least until `expires` + 300 seconds.

#### 7.3 A retry of a delivered `id`

An answer can be lost after the service has counted the call. When a request reaches step 8 with a grant hash and `id` already counted, and its method and `params` are those of the counted call, the service MAY send again, unchanged, the envelope it signed for that call, without running the method, counting the call again or signing anew; otherwise it refuses `replayed`. A kept envelope is of no use more than 300 seconds after its `ts`, since a client refuses an older `ts` (TAP-13 §8 step 5).

#### 7.4 An optional window per calling site and visitor

A service MAY in addition limit the calls with a verified grant per pair (`caller`, `user`), across all their grants, over a sliding window of its choice. It applies the window after step 12 and before step 13, keyed only on the `caller` and `user` that steps 9 to 11 proved, and refuses a call over it with `rate-limited` (step 12a), without counting it. `maxCalls` already bounds each grant, so a service need not set a window.

### 8. Revocation

#### 8.1 Type

```
GrantRevocation(address user,bytes32[] grantHashes,uint64 revokedBefore,uint64 issued)
```

`GRANT_REVOCATION_TYPEHASH` = `0x065cffa2962afb3c14827c4d10da27f7f6992c32837f9748a7046963335f03f5`.

```
structHash = keccak256(abi.encode(GRANT_REVOCATION_TYPEHASH, user,
    keccak256(grantHashes[0] ‖ … ‖ grantHashes[n-1]), uint64 revokedBefore, uint64 issued))
digest     = keccak256(0x19 ‖ 0x01 ‖ DOMAIN_SEPARATOR ‖ structHash)    // the domain of §3
```

An empty `grantHashes` hashes as `keccak256` of the empty string.

| Field | Rule |
|---|---|
| `user` | The visitor whose grants are revoked; same form as in §4.2 |
| `grantHashes` | 0 to 24 grant hashes, each `0x` and 64 lowercase hex digits, not zero |
| `revokedBefore` | Unix seconds, from 0 to 253,402,300,799. When it is not 0, every grant of `user` whose `notBefore` is less than `revokedBefore` is revoked |
| `issued` | Unix seconds, from 0 to 253,402,300,799: when the visitor signed. A service MUST refuse a revocation whose `issued` is more than 300 seconds after its `now` |

A revocation MUST list at least one grant hash or set `revokedBefore` to a value other than 0. The visitor signs `digest` as in §4.4, and a verifier checks the signature against `user` as in §4.4.

#### 8.2 The method `grant_revoke`

A service that accepts revocations serves the free method `grant_revoke` (§6.2) with `params` `{ "revocation": <GrantRevocation as a JSON object with exactly its four fields>, "sig": <the visitor's signature> }`. Anyone may deliver it.

- The service checks the revocation under §8.1 (otherwise `grant: malformed`) and the signature (otherwise `grant: bad-user-signature`), and then records every listed grant hash and the `revokedBefore` for `user`.
- The signed answer is the visitor's receipt: `result` is `{ "revoked": { "user", "grantHashes", "revokedBefore", "issued", "hash" } }`, the four fields as recorded and `hash` the `structHash` of §8.1, lowercase.
- A revocation binds only the service that received it. It takes effect for every request checked after it is recorded.

#### 8.3 Revocations the service makes itself

When step 11 finds that the calling site's holder changed, the service records the grant as revoked (§7.1 step 11). A later return of the circuit to the earlier holder does not restore the grant.

#### 8.4 Keeping revocations

A service MUST keep a revocation at least until every grant it can refuse has expired: for a listed grant hash, until that grant's `expires` when known, and for `revokedBefore`, until `revokedBefore` + 604,800 + 300 seconds. A service that keeps state across restarts SHOULD keep revocations in it. A service that cannot store a new revocation MUST answer `INTERNAL` rather than drop an earlier one.

### 9. The calling site

- A calling site MUST take `caller`, `callerHolder`, `audience` and `audienceHolder` from its own reads at one pinned block (TAP-10 §4.2), never from the service, a page parameter or another request, and SHOULD refuse to build a grant for a name whose site status is not `ok`.
- It MUST create a new caller key for each grant, keep its private key in the page (never in a request, a URL or storage that other origins can read), and MUST NOT send the grant or the key to any party other than the service named in the grant.
- It MUST present the grant to the wallet as `eth_signTypedData_v4` typed data with the domain of §3, `primaryType` `VisitorGrant` and the fields in the order of §4.1, and MUST NOT present a grant whose statement is not a rendering of its fields. It SHOULD check, before asking, that the domain's `chainId` and `verifyingContract` and the two names are those it resolved itself.
- It SHOULD show, next to the wallet's prompt and never instead of it, one sentence asking the visitor to check that the calling site named in the first line is the site that the wallet says the request comes from (TAP-10 §8.4).

### 10. Not defined here

This TAP defines no payment, no asset transfer and no price: a grant names no amount, a method that takes a grant is free (§6.2), and a grant is never sent with a voucher (§6.1). It defines no login, session or account; no directory, listing or ranking of services; no shell user interface for granting or revoking; no on-chain registry of grants or revocations; and no carriage of requests through TAP-10 messages (TAP-11 `endpoints.async`).

## Rationale

- **The service is the place that can say no.** A shell can refuse to send a request, but only the called service can refuse to serve it, count it and stop serving it. A grant that the service verifies is the smallest addition that gives a visitor a limit the service enforces. The shell-side lifecycle of #29 stays useful and separate: two doors, the shell's (send or not) and the service's (serve or not).
- **Why not a mandate of #47.** A mandate is signed by the holder of a principal circuit, for a container agent, in the TAP-11 domain, and the service never sees it. A visitor need not hold a circuit, and here the service must see and check the statement on every call. Changing the principal from a container to a wallet would be another type, not a reuse; a separate domain keeps a visitor from ever seeing a `"TapeAPI"` prompt that resembles a holder's delegation.
- **Why not the session keys of #59.** A session key there is authorised on chain for one escrow channel, lasts up to 30 days, can only be extended and cannot be revoked, and it governs money only. A grant governs which methods may be called, for at most 7 days, revocable at the service, and carries no money. The four mechanisms do not replace one another: a TAP-11 delegation says who signs a service's answers, a #47 mandate says what an agent may do for a container, a #59 session key says what a key may spend on a channel, and a visitor grant says which methods a site may call for a visitor.
- **Grant and voucher never together.** The statement tells the visitor "This grant includes no payment". Accepting a voucher with a grant would make that sentence false. A later format version that combines them would change the statement, and so the version.
- **A generated statement, rebuilt by the service.** The first line a wallet shows is the only part most visitors read. Generating it from the fields, and refusing a grant whose statement differs, keeps the readable line and the signed fields from saying different things. The statement names no address, because a visitor cannot check an address by reading it; the names are the identities a shell displays (TAP-10 §8.7).
- **A one-off caller key and a call proof.** Without a key bound into the grant, anyone who copied a grant could use it until it expires. The call proof binds the service, the grant, the `id`, the method and the `params`, so a copied request cannot be replayed elsewhere or with other parameters, and the proof's prefix and length keep it from being read as a TAP-13 answer.
- **Both holders in the grant.** A circuit that changes hands keeps its name and container. Binding `callerHolder` and `audienceHolder` makes a grant end when either site changes hands, following item 4 of #29's lifecycle; a grant ended by a change of the calling site's holder stays ended.
- **Cheap checks first.** Steps 1 to 8 read nothing from the chain, and the holders are read only after the visitor's signature (step 10), so a malformed, expired, revoked, replayed or forged grant costs the service no chain read.
- **`BAD_REQUEST` with a reason prefix.** TAP-13 §6 lets a later TAP add codes. Until editors decide whether this TAP adds codes (Open questions), refusals use the existing `BAD_REQUEST` without `error.data`, and the reason is in a fixed message prefix that a client can read and that the answer's signature covers.
- **A top-level request member.** The call proof covers `params` unchanged, and the record comes back in `result`. Carrying the grant inside `params` would make the proof cover something other than the request object that TAP-13 signs. TAP-13 does not say how a provider treats a top-level member it does not define (Backwards Compatibility).
- **Numbers.** One hour by default and seven days at most keep a leaked caller key's reach short; 8 methods and 10,000 calls keep a statement readable on one screen; 24 hashes per revocation matches `MandateRevocation` of #47; 300 seconds is the skew TAP-13 §8 already uses.
- **Acknowledgement.** The question of whether DeWEB apps can work together, rather than stay islands, was raised by @BruceBlue (#58).

### Open questions

1. **Wallet rendering of the first line.** No wallet's display of `VisitorGrant` has been tested yet. Whether wallets show the `statement` first, in full or truncated, and how they show the domain's `verifyingContract` (possibly as an unknown contract) decides whether the statement design works. If wallets truncate it, a shorter first line or a different layout would be a new format version. Test results will be added to this pull request.
2. **An on-chain revocation registry.** Revocation here binds only the service that received it, and is useless against a service that ignores it. A registry that every service reads would need a contract, an audit and gas; it is out of scope of this TAP, and the authors do not propose one here.
3. **Interplay with #47 and #59.** Whether a mandate of #47 could in a later phase name the methods a visitor granted, and whether a grant could ever coexist with a payment backed by the escrow of #59, are left open; this text keeps the four apart (Rationale) and keeps grants free.
4. **Domain.** Whether the domain name keeps the prefix `"TapeAPI"`, and whether `verifyingContract` is the hub (as here) or the service's container. Either change is a new domain version.
5. **The member name `grant`**, in the request and in `result`, and the method name `grant_revoke`, given that a later TAP could want `grant` for something else.
6. **Error codes.** Whether this TAP adds codes to TAP-13 §6 (for example `GRANT_REQUIRED` and `BAD_GRANT` with the reason in `error.data`), and whether a missing grant on a `"required"` method is better answered with `METHOD_NOT_FOUND`, which TAP-13 §6 uses for a request outside what a descriptor offers.
7. **Unknown top-level request members.** Whether TAP-13 states that a provider ignores a top-level request member it does not define unless it implements the TAP that defines it. That would be a small follow-up to TAP-13, not part of this text.
8. **The numbers of §4.2 and §8.1** (1 hour, 7 days, 8 methods, 10,000 calls, 24 hashes), and the time format of the statement.
9. **Step 8.** Whether resending the first envelope (§7.3) stays optional, becomes the rule, or is removed.

## Backwards Compatibility

- TAP-10, TAP-11 and TAP-13 do not change. No signed type, digest or vector of those TAPs changes, and the domain and both type hashes of this TAP are new (Test Cases).
- **Manifests.** The descriptor member `grant` is ignored by clients that do not implement this TAP (TAP-11 §3.1). A method marked `"optional"` behaves for them exactly as before; a method marked `"required"` refuses their requests with a signed `BAD_REQUEST`.
- **Requests.** TAP-13 §3 lists the members `id`, `method`, `params` and `voucher` and says nothing about other top-level members. The reference provider ignores members it does not know, so a provider that does not implement this TAP serves a request with `grant` as an ordinary call and returns no grant record; §6.3 makes the calling site treat that answer as not served under the grant. A provider that refuses unknown members would refuse such requests. Open question 7 proposes stating the rule in TAP-13.
- **Answers.** A method served under a grant must return an object, because the record is a member of `result`; a method that returns an array or a scalar cannot take a grant without changing its result.
- **Refusals.** They are ordinary TAP-13 `BAD_REQUEST` envelopes, which every TAP-13 client already handles. When a request's `params` is `{}`, TAP-13 §8 step 3 may report such a refusal as *own request malformed*; the reason prefix still tells the cause.

## Test Cases

The vector file is `assets/tap-draft-visitor-grants/visitor-grant.json` (8,945 bytes, SHA-256 `c4ec082b2e2c048aec41002f009d626746679db30719f956a3ab343b6964be3c`), copied unchanged from `spec/vectors/interop-visitor-grant.json` of the reference implementation. Its member `note` was written before this draft and still calls the format a prototype that is not a TAP; this text supersedes that note. Every key and address in it is a test value (repeated bytes), and `12.7.tape` and `13.7.tape` are example names. It contains:

- the domain of §3 on chain 56 with its separator, the domain on chain 8453 with the separator and the grant hash of the first grant there;
- the two type strings and type hashes;
- two grants (`"en, one method"`: one method, 100 calls, one hour, English statement; `"zh, three methods, 7 days"`: three methods, 10,000 calls, 7 days, Chinese statement), each with both statement renderings, the methods hash, `structHash`, the grant hash and the visitor's signature;
- two call proofs (empty `params`; `params` with two members), each with the 140-byte preimage, its digest, the EIP-191 digest and the caller key's signature;
- two revocations (by hash, listing both grants; by date), each with `structHash`, digest and signature.

`assets/tap-draft-visitor-grants/check.py` recomputes every value from the text of this TAP with the Python standard library only (no dependency; Keccak-256, canonical JSON and secp256k1 recovery are written out in the file). Run `python3 check.py` in that folder: it makes 46 comparisons (types and hashes, domain, statements, struct hashes, grant hashes, signers, bounds, the other chain, preimages and proof signers, revocations, and the distinctness of the two type hashes from those of TAP-11 and of #47 and #59) and prints `ok: 46 checks, 0 disagreed`.

In the reference implementation, the same file is reproduced by its JavaScript SDK tests, by its own independent Python check (46 of its comparisons concern this file; all agree), and by Foundry tests that compute both type hashes, the domain separator, the first grant and the date revocation in Solidity (3 tests, all passing). The step order, the refusal reasons, counting, the retry of §7.3, the window of §7.4 and revocation are covered by its unit and end-to-end tests (61 tests in five files, all passing), not by vectors; no vector covers a refusal.

## Reference Implementation

Implemented in TapeAPI (MIT licensed), under its experimental subpath `@tapeapi/sdk/interop`, **not yet released**: the visitor-grant code is not in any published TapeAPI release or public commit, so this section cannot yet name a fixed commit. It will name one once the code is published; until then the assets of this TAP are the reproducible part. **Wallet rendering of the typed data has not been tested yet** (Open question 1). It consists of:

- the types, hashes, statement templates, wallet payload and call proof (§3–§5, §9);
- the service's check in the order of §7.1, the counting of §7.2, the retry of §7.3, the optional window of §7.4, the wrapper that writes the grant record (§6.3), and the method `grant_revoke` (§8);
- the calling site's side: attaching `grant` with a fresh call proof to requests sent to the service's own endpoints, and refusing an answer without the grant record (§6.1, §6.3);
- an end-to-end example with two sites and a wallet on a simulated chain, and a local test page for wallet rendering that sends no transaction.

**Differences between this text and the reference implementation.** Its EIP-1271 call (§4.4) is made at the latest block rather than at a pinned block. Its default store keeps counts and revocations in memory, so a restart loses them (§8.4 asks for more where state persists). It sets its own time bound for a call under a grant (20 seconds) below its provider's default time bound (25 seconds), and documents that an operator who lowers the provider's bound must lower it too (§7.2).

## Deployments

None. This TAP deploys no contract. The domain names the hub address only as a domain separator; nothing calls it. Names are resolved and holders read with the contracts listed under Deployments in TAP-11.

## Security Considerations

- **A new signing prompt is a new phishing surface.** Any page can ask a visitor to sign a `VisitorGrant` naming any calling site. The statement, the shell's display of the requesting site (TAP-10 §8.4, §8.7) and the visitor's comparison of the two are the defence; until shells check that `callerName` is the requesting site, the visitor has to. Visitors who sign many grants get used to the prompt, and that habit is what a phishing page exploits. Wallet rendering has not been tested (Open question 1).
- **What a service learns about the caller.** A service can confirm that the visitor signed a grant naming the calling site and its one-off key, and that the key signed this request. It cannot confirm that the request came from the calling site's own page: a page that obtained a visitor's signature for a grant naming another site, and holds the key named in it, can use it. The shell's check of the requesting site closes that gap; this TAP does not.
- **A leaked caller key** can make calls under its grant until the grant expires, is revoked at the service, or reaches `maxCalls`, for the listed methods only, and never with payment. The default of one hour and the maximum of seven days bound it.
- **Revocation binds only the service that received it** and is useless against a service that ignores it: revocation protects the visitor from the calling site, not from the service. A service that loses its revocation state on restart serves revoked grants again until they expire (§8.4).
- **Replay.** The call proof binds the service, the grant hash, the `id`, the method and the `params`, and its `ts` is checked within 300 seconds; (grant hash, `id`) is counted at most once. An attacker who intercepts a request cannot change its parameters or send it to another service.
- **Domain separation.** The domain and both type hashes differ from those of TAP-11 (`Delegation`, `ManifestContent`), #47 and #59 (Test Cases), so no grant or revocation signature is valid as one of those, and the call proof differs from a TAP-13 answer digest in prefix and length.
- **Holders and sites.** A grant ends when either circuit changes hands. The service reads holders at a pinned block and caches them for at most 60 seconds, so a change of holder can take that long to take effect.
- **The off-chain request.** A call from one site to another's service is an off-chain request (TAP-10 §8.5); a shell records it and the site loses the on-chain indication of TAP-10 §9.
- **Privacy.** The service sees the visitor's address, the calling site, the methods, the `params`, the times and the client's network address, and the calling site learns the visitor's address. A grant record in a signed answer links the visitor to the calling site for whoever receives that answer.
- **Denial of service.** Steps 1 to 8 read nothing from the chain, so forged grants are refused cheaply; the TAP-13 §7 rate limit applies before any of them. The optional window of §7.4 lets a service bound one calling site's use of one visitor's grants.
- **What a signed answer proves.** It proves what the service signed and that it served the call under the grant; it does not prove that the data is right.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
