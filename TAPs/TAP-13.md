---
tap: 13
title: Signed Responses for Container Services
description: A request and response format in which a service run under a circuit container signs every answer, errors included, so that a client can attribute each answer to that container.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/9
status: Draft
type: Application
created: 2026-09-30
updated: 2026-10-10
requires: TAP-10, TAP-11
license: CC0-1.0
---

# TAP-13: Signed Responses for Container Services

## Summary

A way for an online service that belongs to a TapeOut circuit to sign every answer it gives, so that anyone can check which service gave the answer, to which question, and when.

## Abstract

This TAP defines the HTTPS request that a client sends to a service's live endpoint, the JSON envelope in which the service answers, and the signature that binds each answer to the service container, the request's id, the request itself, the success flag, the answer body and the time. The signing key is the signer resolved for the service under TAP-11; this TAP does not define how it is found. The signature covers JSON values in the canonical form defined by that TAP. This TAP also defines how requests and envelopes are parsed, the error codes a signed envelope may carry, the answers that are deliberately left unsigned, and the checks a client makes before it trusts an answer.

## Motivation

TAP-10 gives a circuit container a website and a mailbox. A service that a container's holder runs off chain (an API that reads the chain, a relay, a tool server) answers over HTTPS, and TLS authenticates a host name, not a container. Without a signature bound to the container, a client cannot show where a result came from, cannot dispute it, cannot cache it safely, and cannot tell a genuine refusal from one invented by a proxy or CDN on the path.

TAP-11 names the key that speaks for a container's service. This TAP says what that key signs, byte for byte, so that clients and providers written independently agree on every answer. A signature over "some payload" is not enough: it has to say "this is the answer to that question, from that container, at that time", or a valid signature can be moved to another question, another service or another moment.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms and notation

- **Container**, **holder**: as defined in TAP-10 §1. A container is the ERC-6551 account of a circuit.
- **Service**, **manifest**: as defined in TAP-11 §1. A **live endpoint** is a URL listed in the manifest's `endpoints.live` (TAP-11 §3.2); a **method** is the `name` of one of its method descriptors (TAP-11 §3.3).
- **Signer**: the address named by a manifest that TAP-11 §2 resolves with the outcome "resolved"; TAP-11 §4.5 lists the sources from which a signer is never taken. Wherever this TAP says "the signer", it means that address and nothing else.
- **Provider**: whoever answers at a live endpoint on behalf of a service and holds the signer's key.
- **Client**: whoever sends a request and verifies the answer.
- **Envelope**: a response body defined in §4.
- Notation is that of TAP-10 §1 (`‖`, `uint64(x)`, addresses as 20 raw bytes, ASCII labels as raw bytes). `keccak256` is the Keccak-256 hash used by Ethereum (original Keccak padding, not NIST SHA3-256). `utf8(s)` is the UTF-8 encoding of the string `s`.
- The **length of a string in UTF-16 code units** is the number of 16-bit units in its UTF-16 encoding; a character outside the Basic Multilingual Plane counts as two. It is what JavaScript's `String.length` returns.
- **Outcomes** of client verification (§8): *accepted result*, *accepted error*, *own request malformed*, *binding failure*, *transport failure* and *rate limited*. These are descriptions, not wire values.

### 2. Canonical JSON and parsing

`canonicalJSON(v)` is the canonical JSON of TAP-11 §6: RFC 8785 (JCS) together with that section's items 1 to 5 (repeated member names; numbers that are not finite or are negative zero; integers whose absolute value exceeds 2^53 − 1; the member names `__proto__`, `constructor` and `prototype`; unpaired UTF-16 surrogates). A value that has no canonical form under that section can be neither signed nor verified under this TAP. Every envelope already issued depends on these rules.

The **parser** used for requests (§3) and envelopes (§8) MUST accept only JSON text as defined by RFC 8259, and MUST reject, while parsing and without choosing a surviving value, any text in which one object repeats a member name or any member is named `__proto__`, `constructor` or `prototype` (TAP-11 §6 items 1 and 4). Items 2, 3 and 5 are applied when a canonical form is computed: a parsed value can, for example, contain a negative zero, and it then has no canonical form.

### 3. Request

A client calls a method with an HTTP request of this shape (the values are placeholders):

```
POST <live>/<method>
Content-Type: application/json

{ "id": "…", "method": "…", "params": { … }, "voucher": { … } }
```

- `<live>` is one of the service's live endpoints and `<method>` one of its methods (§1). The path segment `<method>` MUST match `^[A-Za-z_][A-Za-z0-9_]{0,63}$`. It is the method name that the signature covers.
- The body is a JSON object in UTF-8. Its members:

| Member | Required | Content |
|---|---|---|
| `id` | yes | A string of 1 to 128 UTF-16 code units, chosen by the client, unique among that client's requests. It MUST be well-formed Unicode: no unpaired surrogate (TAP-11 §6 item 5) |
| `method` | no | When present, MUST equal the path segment. A provider MUST refuse a mismatch with `BAD_REQUEST` rather than prefer either value |
| `params` | no | A JSON object. When absent it is `{}` for every purpose of this TAP |
| `voucher` | no | Reserved for a payment voucher (§6, reserved names): its format, and when it is required, are left to a later payment TAP. It is not part of the request object below and is not covered by any signature. A provider ignores it for a method whose `priceBEM` (TAP-11 §3.3) is zero |

- A provider MUST parse the body with the parser of §2 and MUST refuse a body that the parser rejects with `BAD_REQUEST`.
- The **request object** of a call is `{ "method": <path segment>, "params": <params, or {} when absent> }`, an object with exactly these two members.

This TAP defines calls over HTTPS only. Requests delivered through a container's TAP-10 inbox are out of scope.

### 4. Response envelope

A provider answers every request that reaches a method route (a path that matches the pattern of §3) with an envelope, except the answers of §7. Two examples:

```json
{ "id": "…", "ok": true, "result": { … }, "container": "0x…", "ts": 1789000000, "block": 123456789, "sig": "0x…" }
{ "id": "…", "ok": false, "error": { "code": "BAD_REQUEST", "message": "…", "data": { … } }, "container": "0x…", "ts": 1789000000, "sig": "0x…" }
```

| Member | Type | Content |
|---|---|---|
| `id` | string | The request's `id`, or `""` under binding rule 1 below |
| `ok` | boolean | `true` for a result, `false` for an error. MUST be a JSON boolean |
| `result` | any JSON value | Present exactly when `ok` is `true` |
| `error` | object | Present exactly when `ok` is `false`: `code` (string, §6), `message` (string), and optionally `data` (object) |
| `container` | string | The service container, `0x` and 40 hex digits |
| `ts` | integer | The provider's Unix time in seconds, 0 ≤ `ts` ≤ 2^53 − 1 |
| `block` | integer | OPTIONAL. The chain height the provider used. Informative and not signed |
| `sig` | string | `0x` and 130 hex digits: the 65-byte signature of §5 |

The **body** of an envelope is `result` when `ok` is `true` and `error` when `ok` is `false`.

**Binding rules.** Every envelope is signed over an `id` and a request object:

1. A request the provider cannot parse (not JSON, not an object, over the provider's size limit, rejected by the parser of §2) or whose `id` is missing or invalid (anything other than a string of 1 to 128 UTF-16 code units) has no `id` or `params` the provider can trust. A provider MAY also treat an `id` that is not well-formed Unicode as invalid. It is refused with `BAD_REQUEST` signed over `id` `""` and the request object `{ "method": <path segment>, "params": {} }`. The HTTP status is 400, or 413 when the body is over the size limit.
2. A request with a valid `id` whose `params` is present but not a JSON object, or has no canonical form under §2, is refused with `BAD_REQUEST` signed over its own `id` and `{ "method": <path segment>, "params": {} }`.
3. Every other answer, including an `INTERNAL` for a failure inside the provider, is signed over the request's own `id` and request object.

**Transport.**

- A provider MAY send an envelope with HTTP status 200 or with the status of its error code (§6).
- A provider MUST cap the response body at 1 MiB (1 048 576 bytes of UTF-8). A provider whose result would exceed the cap answers a signed `INTERNAL` instead, and so does a provider whose handler exceeds its own time bound; neither is charged for. Providers SHOULD answer within 30 seconds.
- A live endpoint is an `https://` URL (TAP-11 §3.2). The signature does not replace TLS; it makes an answer verifiable after TLS has ended.

### 5. Digest and signature

The **digest** of an envelope is `keccak256` of the following 139-byte preimage:

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 14 | Prefix | ASCII `TAPI-1/resp/v2`, bytes `0x544150492d312f726573702f7632` |
| 14 | 20 | Container | The service container |
| 34 | 32 | Id hash | `keccak256(utf8(id))` |
| 66 | 32 | Request hash | `keccak256(utf8(canonicalJSON(request object)))` (§3) |
| 98 | 1 | Ok | `0x01` if `ok` is `true`, `0x00` if `false` |
| 99 | 32 | Body hash | `keccak256(utf8(canonicalJSON(body)))` (§4) |
| 131 | 8 | Time | `uint64(ts)` |

```
digest       = keccak256(preimage)
eip191Digest = keccak256(0x19 ‖ "Ethereum Signed Message:\n32" ‖ digest)      // EIP-191 personal_sign over 32 bytes
sig          = r ‖ s ‖ v                                                        // 65 bytes, secp256k1 over eip191Digest
```

- The prefix is a fixed historical constant and MUST be used exactly as written. Its "1" and "v2" do not refer to any TAP number.
- `sig` is 65 bytes. A signer MUST set `v` to 27 or 28. A verifier MUST read a `v` of 0 or 1 as 27 or 28, and MUST then reject any `v` that is not 27 or 28. `r` MUST be in [1, n − 1] and `s` in [1, n/2], where n = `0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141` is the order of secp256k1. A verifier MUST reject a high-`s` signature even though it recovers the same address; signers MUST produce low-`s` signatures.
- An envelope is valid for a service when the address recovered from `eip191Digest` and `sig` equals the service's signer.
- `block` is not covered.

### 6. Provider error codes

`error.code` in a signed envelope MUST be one of the codes below, or a code that a later TAP adds to this list. Codes are only ever added, never removed or renamed. A client MUST treat a code it does not know as an error, never as a result.

| Code | HTTP status | Meaning | `error.data` |
|---|---|---|---|
| `PAYMENT_REQUIRED` | 402 | Reserved for a later payment TAP (below); intended for a request that carries no voucher to a method whose `priceBEM` in the manifest is not zero | Defined by that TAP |
| `BAD_VOUCHER` | 402 | Reserved for a later payment TAP (below); intended for a request that carries a voucher the provider does not accept | Defined by that TAP |
| `METHOD_NOT_FOUND` | 404 | The path segment is well-formed but names no method the provider serves, or the request asks a method for something outside what the method's descriptor offers (below) | None |
| `BAD_REQUEST` | 400, or 413 for size | The request is malformed (§3, §4 binding rules) | None |
| `INTERNAL` | 500 | A failure inside the provider, including a result over 1 MiB or over the time bound | Only `revert` (below) |
| `TOOLS_CHANGED` | 409 | Reserved for a later TAP that binds a service to a tool server (below); intended for a request to a service whose tool server no longer offers the tools that its manifest describes | Defined by that TAP |

- `error.data`, when present, MUST be a JSON object; it is covered by the signature through the body hash.
- **What a descriptor offers.** A method's descriptor offers what one of its members lists, as the TAP that defines that member states; for example, a TAP may define a member that lists the chains a method serves. The members defined in TAP-11 §3.3 offer nothing in this sense: `params` and `returns` there are informative. A request that is well-formed under §3, and under any TAP that defines the method's `params`, but asks for something that the method's descriptor does not offer is refused with `METHOD_NOT_FOUND`, not `BAD_REQUEST`. The code tells a client that the service, under its current manifest, does not offer what was asked (the client's copy of the manifest may be out of date, or it chose the wrong service), not that its request is malformed.
- **Reserved names.** The codes `PAYMENT_REQUIRED`, `BAD_VOUCHER` and `TOOLS_CHANGED` and the request member `voucher` (§3) are reserved. Each is left to a later TAP that defines when it is used, its format and its `error.data`: a payment TAP for `voucher` and the two payment codes, and a TAP that binds a service to a tool server for `TOOLS_CHANGED`. Neither is a TAP yet: a tool-server binding is proposed in pull request #16, and payment vouchers are under discussion in issue #38. Until the TAP that defines a reserved name exists, an implementation of this TAP need not send, read or act on it: a client treats a reserved code it receives as it treats any other error (§8), and a provider that implements no such TAP ignores `voucher`. An implementation MUST NOT use a reserved name with any meaning other than the intended one given in §3 and in the table above, and no TAP other than the one that defines it may give it another.
- An `INTERNAL` message MUST NOT reveal upstream details such as node URLs, keys or internal host names. The single exception: an `INTERNAL` MAY carry `error.data.revert`, the `0x`-prefixed hex revert data of a chain call the provider made, with `message` equal to `"execution reverted"`. An `INTERNAL` MUST NOT carry anything else.
- A provider signs its errors: a signed refusal is a statement the provider cannot later deny.

### 7. Unsigned answers

These answers are deliberately not signed, and a client MUST NOT treat any of them as an envelope:

- **Rate limiting.** A provider MAY refuse a request before doing any work. Such a refusal MUST use HTTP 429 with a `Retry-After` header and the body `{ "ok": false, "error": { "code": "RATE_LIMITED", "message": "…", "data": { "retryAfterS": <seconds> } } }`, and MUST NOT be signed. A client MUST treat HTTP 429 as *rate limited*, whatever the body, and MUST NOT attempt verification on it. When a provider sits behind a proxy, the caller identity it uses for rate limiting MUST come from the host (for example the edge's connecting IP) or from the last hop of a configured forwarding header, never from a value the client can supply.
- **Route errors.** A path that does not match the pattern of §3, or an HTTP method other than `POST`, MAY be answered with an unsigned 404 or 405.
- **Anything without a signature.** A body that is not JSON, that is JSON but not an object with a string member `sig`, or that is larger than 1 MiB (a proxy or CDN error page, the route errors above, a notice from a provider whose delegation has lapsed) is a *transport failure*. A client MUST NOT report it as a signature failure and MUST NOT trust any claim in it.

### 8. Client verification

Input: the service's container `C` and signer `S`, from a resolution under TAP-11 §2 with the outcome "resolved"; the `id`, path segment and `params` the client itself sent; and the HTTP answer. A client MUST perform these steps in order and MUST stop at the first outcome:

1. If the HTTP status is 429: *rate limited*.
2. Read at most 1 MiB of the body. If it is larger, is rejected by the parser of §2, or is not an object with a string member `sig`: *transport failure*. The HTTP status is otherwise ignored.
3. If `ok` is `false`, `error.code` is `BAD_REQUEST`, and the envelope verifies under §5 with container `C`, request object `{ "method": <path segment it sent>, "params": {} }` and either `id` `""` or its own `id`: *own request malformed*. The client reports its own request as malformed, not the provider's signature.
4. The envelope's `id` MUST equal the `id` the client sent; `ok` MUST be a boolean; `result` or `error` MUST be present as `ok` requires; `container` MUST equal `C` (compared case-insensitively); `ts` MUST be an integer in the range of §4. Otherwise: *binding failure*.
5. `|now − ts|` MUST NOT exceed `maxSkew`, which is 300 seconds unless the client is configured otherwise. Otherwise: *binding failure*.
6. Compute the digest of §5 from `C` (never the envelope's `container`), the client's own `id`, the request object built from what the client sent (never from values the provider echoes), the envelope's `ok`, the canonical form of the parsed body (never the raw bytes), and the envelope's `ts`. If the body has no canonical form under §2, or the signature is malformed or recovers to an address other than `S`: *binding failure*.
7. Otherwise: *accepted result* when `ok` is `true`, *accepted error* when `ok` is `false`.

On a *binding failure* the client MUST reread the service, as defined in TAP-11 §7.1, before it sends the request again. That section requires a reread when a signature fails against the kept signer; this TAP requires one after every binding failure. If the reread manifest names exactly the address that the envelope's signature recovers to, the client MAY accept that same envelope, after verifying it in full against the new signer, rather than sending the request again, so that a result the provider has already charged for is not paid twice. Rereads triggered by binding failures SHOULD be rate limited per service.

### 9. Reuse of the digest by other TAPs

Another TAP MAY define a signed statement that uses the preimage, digest and signature of §5 with inputs other than a §3 request, for example a statement about a request that was not sent in the §3 format. Such a TAP MUST state which values take the places of `id`, the request object, `ok` and the body, and how a verifier obtains each of them; and it MUST state why none of its statements can be accepted under §8 as the answer to a request, and no answer as one of its statements.

## Rationale

- **A fixed ASCII prefix** separates this digest from EIP-712 typed data, from TAP-10 payloads and from any other message the same key might sign.
- **Separate hashes of `id`, request and body** keep the preimage at a fixed 139 bytes and let a verifier check the binding, or rebuild the digest from the three hashes alone, without re-serialising the whole envelope.
- **Covering the request object and `ok`** turns an envelope into "this is the answer to that question" instead of "this is a payload I signed". A proxy or CDN cannot relabel a signed error as a result, a result shaped like `{code, message}` cannot become an error, and an answer cannot be moved to another question even under a reused `id`.
- **The client recomputes from what it sent and from the container it resolved.** Echoed values are exactly what an attacker on the path controls.
- **EIP-191 over a 32-byte digest** is supported by every wallet and hardware signer. EIP-712 was rejected because `result` has no fixed type.
- **Canonical JSON instead of the raw bytes.** Proxies, CDNs and frameworks re-encode JSON; the meaning survives, the bytes do not. RFC 8785 already exists in several languages, and the restrictions of TAP-11 §6 remove the values on which implementations have been observed to disagree (the vectors include numeric-looking keys, on which a JavaScript and a Python implementation once did). Using the same canonical form as that TAP means one implementation serves both.
- **Low-`s` only**, as EIP-2 requires for transaction signatures and as widely used on-chain recovery routines also require, so that a signature accepted off chain is never refused by a contract that checks the same key.
- **Errors are signed** so that a provider cannot deny having refused a request, and so that a client can tell a real refusal from one inserted on the path. **Rate-limit refusals are not signed** because they assert nothing about any result, and signing them would make a flood cost the provider one signature per request.
- **One code for what a service does not offer.** An unknown method and a well-formed request for something a method's descriptor does not list (a chain, say) tell the client the same thing: its view of the service's offer is wrong, not its request. One code for both lets later TAPs use it without adding a code per case, and keeps `BAD_REQUEST` for requests that are malformed.
- **Reserved names instead of a payment format.** The payment and tool-server rules that the reference implementation uses are not TAPs yet. Reserving their names tells an implementer what it need not handle yet and keeps the names free for those TAPs, without fixing a format here that they would then have to follow.
- **`block` is not signed.** It is a debugging aid; a height that matters belongs in the result.
- **Unparseable requests are bound to `id` `""`.** The provider cannot trust any `id` in a body it cannot parse; binding to a fixed value still lets the sender verify the refusal. Such a refusal says only that some unparseable request for that method was refused (Security Considerations).
- **Alternatives considered.** HTTP Message Signatures (RFC 9421) sign bytes and headers that intermediaries rewrite, and do not bind the request's JSON meaning. JWS has the same canonicalisation problem and adds algorithm negotiation this format does not need.
- **AI usage receipts are proposed separately.** In the TapeAPI documents the same envelope also signs usage receipts for AI API answers. They depend on a price table and usage schema that TAP-11 does not define, and their rules (stream parsing, response hashes, delivery, a lookup method) would double this TAP. §9 is all they need from here.

## Backwards Compatibility

This specification was published in the TapeAPI repository under the self-assigned name "TAP-21" (renamed "TAPI-21" on 2026-09-30). Neither name is a TAP number; editors assign the number of this TAP. The constant `TAPI-1/resp/v2` is a historical wire constant, not a TAP number, and never changes. Every envelope already issued depends on the canonical JSON of TAP-11 §6, which is the one the TapeAPI documents used.

An earlier envelope version used the prefix `TAPI-1/resp/v1` and covered neither the request nor `ok`. It is superseded; such envelopes do not verify under §5 and are rejected.

Two public services have signed every answer, errors included, with this envelope since 2026-09-27, and the TapeAPI SDK 1.x verifies it (Reference Implementation). Nothing in this TAP changes a byte they send or accept. Compared with the TapeAPI document, this text:

- states that a `params` that is present but not an object is refused bound to `params` `{}` (binding rule 2), which the reference provider already does, and that an unparseable request is bound to the path segment as its method;
- requires a client's `id` to be well-formed Unicode. Since version 1.5.0 the reference client refuses such an `id` before it sends anything, and the reference provider treats it as invalid and answers under binding rule 1 (§4);
- leaves out the client-side error codes of the TapeAPI SDK and describes client outcomes in words instead (§1, §8);
- takes canonical JSON from TAP-11 §6 instead of defining it here;
- keeps `TOOLS_CHANGED` only as a reserved code (§6, reserved names), because the tool-server binding that used it is not part of TAP-11; the reference implementation's tool-server proxy still sends it;
- moves AI usage receipts and their lookup method to a separate proposal (Rationale);
- keeps the request member `voucher` and the codes `PAYMENT_REQUIRED` and `BAD_VOUCHER` only as reserved names (§6), because the payment TAP that would define them has not been proposed; the reference provider and SDK still send and act on them, with the voucher format and `error.data` of the TapeAPI document "TAPI-22" (called "TAP-22" until 2026-09-30; not a TAP number);
- widens `METHOD_NOT_FOUND` to a request that asks a method for something its descriptor does not offer (§6), so that another TAP can use the code for, say, a chain that a method does not list, rather than adding a code for that one case. The reference provider sends `METHOD_NOT_FOUND` for an unknown method, and its attested-read example already sends it for an unlisted chain.

Where the reference implementation's resolution of a service differs from TAP-10, the difference is listed in TAP-11; this TAP adds none.

## Test Cases

The vector files are in `assets/tap-13/`. They were generated with the reference implementation at commit `fda84db` (version 1.3.0) and checked with the canonicalisation and recovery routines of the independent Python implementation at the same commit. The reference implementation at the fixed commit below (version 1.8.1) reproduces every value in them (`sdk/src/canon.js`, `sdk/src/sig.js`), and so does the independent Python implementation at that commit (`spec/vectors/verify.py`). Keys and addresses in them are test values.

The canonical JSON vectors of TAP-11 (its Test Cases, `canonical-json.json`) apply to this TAP unchanged. This TAP adds:

- `canonical-json-extra.json` (§2, TAP-11 §6), in the same format as those vectors and covering cases they do not: 6 JSON texts with their exact canonical form and its `keccak256` (numeric-looking member names, which sort as strings; objects inside arrays; escapes of `\\`, `\/`, U+0008, U+000C, U+000D and U+001F; fractions and exponent form; the negative safe-integer boundary; empty containers), and 6 texts that have no canonical form (a repeated member name whose escaped spelling comes first, the reverse of the order in the TAP-11 vectors, a nested `prototype`, `1e21`, −2^53, `-0.0`, an unpaired low surrogate in a member name).
- `envelope.json` (§4, §5): container `0x86DDaEF00401E3F10418398D67D7189fc458eA95`, published test signer key `0x2222…2222` (address `0x1563915e194D8CfBA1943570603F7606A3115508`), and:
  - 5 envelopes, each with canonical request and body, the 139-byte preimage, digest, EIP-191 digest, signature and recovered address: empty `params`, `params`, a signed error, `params` in another key order, and the refusal of an unparseable request (binding rule 1);
  - 4 encodings of the first signature: `v` as 0/1 (accepted), its high-`s` twin (rejected although it recovers the signer), `v` = 29 and 64 bytes (rejected);
  - 7 cases in which the verifier's own `ok`, `id`, `params`, method, body, `ts` or container differs from what was signed, each with the digest it computes and the wrong address it recovers.

Example, the first envelope in full:

```
container       0x86DDaEF00401E3F10418398D67D7189fc458eA95
id              "req-1"          request object {"method":"blockNumber","params":{}}
ok              true             body           {"blockNumber":123456789}
ts              1789000000
digest          0x71c2489e6d3e3682739380996d0981f2a283b5957011d3d7b279329567111b05
eip191Digest    0xd8a321457c5bf13db75f989253b344be59a502ee29edef0888d398c250143c2d
sig             0xd7d544bcab20533ab3d82f790195e0e5bd775a705fc67e32c6dcb41134f22bed59669c08c32ab3e16386a85e90603cedb020a267928488f9d1a349da3149b1451b
recovers        0x1563915e194D8CfBA1943570603F7606A3115508
```

## Reference Implementation

TapeAPI 1.8.1, at commit [`4a1ac4fe2a0b2e3327652a794794765dd5da98ef`](https://github.com/BruceLanLan/tapeapi/tree/4a1ac4fe2a0b2e3327652a794794765dd5da98ef):

- [`sdk/src/canon.js`](https://github.com/BruceLanLan/tapeapi/blob/4a1ac4fe2a0b2e3327652a794794765dd5da98ef/sdk/src/canon.js): canonical JSON (TAP-11 §6) and the strict parser (§2);
- [`sdk/src/sig.js`](https://github.com/BruceLanLan/tapeapi/blob/4a1ac4fe2a0b2e3327652a794794765dd5da98ef/sdk/src/sig.js): the digest, signing and low-`s` recovery (§5);
- [`server/src/index.js`](https://github.com/BruceLanLan/tapeapi/blob/4a1ac4fe2a0b2e3327652a794794765dd5da98ef/server/src/index.js): a provider (§3, §4, §6, §7);
- [`sdk/src/index.js`](https://github.com/BruceLanLan/tapeapi/blob/4a1ac4fe2a0b2e3327652a794794765dd5da98ef/sdk/src/index.js): client verification (§8);
- [`spec/vectors/verify.py`](https://github.com/BruceLanLan/tapeapi/blob/4a1ac4fe2a0b2e3327652a794794765dd5da98ef/spec/vectors/verify.py): an independent Python implementation of the canonical JSON and of §5, with Keccak-256 and secp256k1 recovery written from their specifications.

Two services answer with this envelope: `https://api.tapeapi.fun` (container `0x1b2A657BcBa9D3229f57aC2f4FcbEE2AA756aAe8`, #11 of processor `0xe02c26c7432A7121168AA9B610DE24eCf9a1a414` on BNB Smart Chain) and `https://relay.tapeapi.fun` (container `0x9cD838625251576c199B2DeF7A17e50266843185`, #12 of the same processor). They are not audited. Their holder activated both names on 2026-10-01. On 2026-10-09 `isContainerLive` was true for both containers when read from two operators at BNB Smart Chain block 126658102 (hash `0x152776aae99baff145411961ab761000d7825f21046648848d053a8a02b8b8ea`), so under TAP-11 they no longer end resolution as `unpaid` (TAP-10 §6.2). The envelopes they send were never affected.

## Deployments

None. This TAP deploys no contract and depends on none directly. Finding and verifying a service's signer uses the contracts listed under Deployments in TAP-11, which in turn refers to TAP-10.

## Security Considerations

The attacker considered can read, delay, drop, replay and modify all traffic between client and provider, including through a proxy or CDN, and can run services of its own.

- **What the signature proves.** That the service's signer, at time `ts`, gave this body with this `ok` in answer to this request object under this `id`, for this container. It does not prove that the answer is correct: a provider can sign a wrong result. It makes a wrong result attributable, not impossible.
- **Replay.** `id`, `ts` and the request hash are covered. An envelope for one question does not verify for another, even under a reused `id`, and an old envelope fails the `ts` window. Within the window a genuine envelope can be delivered again only as the answer to the same `id` and request object, which the client already holds. Refusals bound to `id` `""` (binding rule 1) are the exception described under forged refusals.
- **Relabelling.** `ok` is covered, so a signed error cannot be shown as a result or the reverse.
- **Substitution.** The container is covered and the client uses the container it resolved, so a signature from service A cannot be presented as service B, even if both use the same signer key.
- **Malleability.** High-`s` signatures and unusual `v` values are rejected, so each digest has one valid encoding per key and no verifier accepts what another refuses.
- **Canonicalisation.** A disagreement between two canonical-JSON implementations is the main interoperability risk and, where one side accepts, a bypass. TAP-11 §6 and the parser rule of §2 remove the known sources; implementations are expected to pass the vectors of both TAPs.
- **Prototype pollution.** The forbidden keys are refused while parsing on both sides, so these keys cannot reach JavaScript application state through a verified `result`.
- **Forged refusals.** A proxy can drop an answer or put an unsigned page in its place, but unsigned answers are transport failures (§7). An attacker cannot make a provider appear to have refused or failed a request bound to that request's own `id`. A refusal under binding rule 1 is bound to `id` `""` and to no particular request: anyone can obtain one for a method by sending an unparseable body, and §8 step 3 does not check its `ts`. An attacker on the path can therefore put such a refusal in place of any answer for that method, and the client reports its own request as malformed. This is a denial of service, like dropping the answer; it proves nothing about the client's request.
- **Clock.** The `ts` window assumes that the client's clock is roughly right. A client with a wrong clock rejects genuine envelopes or accepts older ones within the error of its clock.
- **Signer key.** The signer key is kept online to sign answers. Whoever steals it can sign answers for the service until the holder replaces it or the delegation expires (TAP-11 §7.2). A client that cached the old signer keeps trusting it until its next reread (TAP-11 §7.1); the reread after a binding failure (§8) covers the other direction, a provider that already signs with a key the client does not yet know.
- **Reuse of the digest.** Statements defined under §9 share this signature domain; the condition of §9 keeps them from being accepted as answers, and the reverse.
- **Trust inherited from resolution.** Every guarantee above rests on the signer being the one the holder authorised. Until the contracts that resolution reads are sealed, whoever controls them can change what resolution returns (TAP-11, Deployments and Security Considerations); this TAP inherits that assumption.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
