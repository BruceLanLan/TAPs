---
tap: 11
title: TapeAPI Service Manifest and Holder Delegation
description: How the holder of a TapeOut circuit describes a callable service in the circuit container's DeWEB site and authorises an off-chain signing key for it, and how a client verifies both against the chain.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/7
status: Draft
type: Application
created: 2026-09-30
requires: TAP-10
license: CC0-1.0
---

# TAP-11: TapeAPI Service Manifest and Holder Delegation

## Summary

This TAP lets the owner of a TapeOut circuit publish, inside its on-chain website, a description of an online service it runs and of the key that speaks for it, so that anyone can check who stands behind a service before relying on it.

## Abstract

This TAP defines a **service manifest**: a JSON file at the fixed path `/.well-known/tapeapi.json` in a container's DeWEB site that lists the service's HTTPS endpoints and methods and names a **signer**, an ordinary secp256k1 address that the service uses to sign what it returns. The circuit's holder authorises the signer with an EIP-712 **delegation** that expires within 366 days. The TAP specifies the manifest format, the delegation's domain, type and checks (including holders that are contracts, via EIP-1271), an optional holder signature over the whole manifest with the canonical JSON it needs, and the procedure by which a client resolves a service, rereads it, and detects a rolled-back manifest. Names, chain selection, node agreement, pinned blocks, implementation pinning, activation and file verification are those of TAP-10 and are referenced, not restated. Response formats, payment and other bindings are left to later TAPs that build on this one.

## Motivation

TAP-10 gives every circuit container a website whose bytes anyone can verify, and a mailbox. It does not give a container a way to say "I answer requests at these URLs, and my answers are signed by this key". Off-chain APIs today have no on-chain identity: a client trusts DNS and a TLS certificate, and nothing ties an answer to the party a TapeOut name points to. Agents that call each other, and applications that want to cite a result, need that link.

The pieces already exist. The container is an identity that anyone can derive; its site is a store that anyone can verify; its holder is readable on chain. What is missing is an agreed file format, an agreed way for a cold holder key to authorise a hot signing key, and an agreed order of checks, so that two independent clients reach the same verdict about the same service. This TAP supplies exactly those, without a new contract, a new name syntax or any change to TAP-10.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms and notation

- **Circuit**, **processor contract**, **processor number**, **#ID**, **container**, **holder**, **opened**, **plain account**, **site store** (`SiteRegistry`), **payment contract** (`DomainBinding`), **pinned block**, **default agreement**, **strict agreement**, **home chain**, **endpoint ID**: as defined in TAP-10 §1 and §12.1.
- **Hub address**: `0xe61A9C7213a6Aa616C246a2B569e555B417b25ee`, the DeWEB hub proxy of TAP-10 §13.2, which has this address on every chain of the TAP-10 chain table. This TAP uses it only as a constant (§4.1) and calls none of its functions.
- **Service**: a circuit whose container's site holds a manifest (§3). A service lives on its circuit's home chain only; the same processor contract address and #ID on two chains are two services.
- **Manifest**: the file of §3. **Signer**: the address named in its `signer` member. **Delegation**: the holder's authorisation of the signer (§4).
- **Client**: software that resolves a service under §2. **Provider**: whoever runs the service's endpoints.
- `now` is the client's current Unix time in whole seconds. Other notation is that of TAP-10 §1.

### 2. Resolving a service

#### 2.1 Input

A client MUST accept an on-chain name (TAP-10 §3.1), a container address, and a processor contract with an #ID (given as the TAP-10 §3.4 text form or as two values). It MAY accept the other input forms of TAP-10 §3.4 except the endpoint ID. Anything else MUST be rejected as an input error, with the ranges and rules of TAP-10 §3.1 and §3.4.

#### 2.2 Procedure

All reads of one resolution MUST be made at one pinned block of the service's chain, chosen and checked for freshness as in TAP-10 §5.3 (`stale-block`), and MUST be adopted under at least default agreement (TAP-10 §5.2). A client SHOULD confirm with `eth_chainId` that its nodes are on the expected chain (TAP-10 §5.4). A client SHOULD adopt `ownerOf` and the EIP-1271 call of §4.4 under strict agreement, since a forged answer to either would authorise a signer. The client assigns the first outcome that applies:

1. **Identity.** Choose the chain and resolve the input as in TAP-10 §4.1–§4.3. The result is the chain, processor contract, processor number, #ID, container, holder and whether the container is opened.
2. **Site status.** In the same pinned block, check the site store and payment contract implementations (TAP-10 §6.1) and assign the first site status that applies in the order of TAP-10 §6.2: `store-changed`, an identity outcome other than a resolved circuit (TAP-10 §4.4), `not-opened`, `blocked`, `unpaid`. A client that keeps a blocklist (TAP-10 §10) MUST consult it here. Any status other than `ok` ends resolution with that status.
3. **Manifest file.** Read the manifest from the site store listed first for that chain that has any path for the container (TAP-10 §6.1), with the registry key `.well-known/tapeapi.json`: the URL path `/.well-known/tapeapi.json` with its leading `/` removed, as TAP-10 §7.2 step 3 does. Only this exact key is read; the landing rules of TAP-10 §7.2 step 4 (index files, fallback path) MUST NOT be applied. Then:
   - `fileInfo` with `chunkCount` 0 means `no-manifest`;
   - a declared `size` above 65,536 bytes means `manifest-invalid`, and the file MUST NOT be read;
   - otherwise the file is read and verified exactly as TAP-10 §7.1 steps 3–5. A file outcome other than `ok` (`incomplete`, `no-hash`) ends resolution with that outcome, and the bytes MUST NOT be used.
4. **Parse and validate** the bytes under §3. Any failure is `manifest-invalid`.
5. **Binding.** `circuits` MUST equal the processor contract, `tokenId` the #ID, and `container` the container resolved in step 1 (addresses compared case-insensitively). Otherwise `manifest-invalid`. A client MUST NOT use any identity value the manifest states in place of the values resolved in step 1.
6. **Delegation.** Verify §4 against the holder read in step 1. Any failure is `delegation-invalid`.
7. **Content signature.** If the client applies §5, a failure there is handled as §5.3 says.
8. **Resolved.** The result is the chain, the on-chain name, the container, the holder, the pinned block, and the manifest with its `signer` and `delegation.expires`.

#### 2.3 Outcomes

| Outcome | Meaning |
|---|---|
| resolved | Every step passed; the signer speaks for the service until `delegation.expires` or until a reread (§7) says otherwise |
| Input error, `stale-block`, `unavailable`, `wrong-chain`, `ambiguous` | §2.1, or the chain and node rules of TAP-10 §4.1 and §5 |
| `store-changed`, TAP-10 identity outcomes, `not-opened`, `blocked`, `unpaid` | Step 2 (TAP-10 §4.4, §6.4) |
| `no-manifest` | The container's site has no file at `.well-known/tapeapi.json` |
| `incomplete`, `no-hash` | The file failed TAP-10 §7.1 |
| `manifest-invalid` | The file is too large, is not a valid manifest (§3), or states another circuit or container (step 5) |
| `delegation-invalid` | The delegation fails §4 |

Only "resolved" allows a client to treat the signer as speaking for the service. Outcome names are only ever added.

### 3. Manifest

#### 3.1 File

- The manifest is JSON text (RFC 8259) encoded in UTF-8, whose top-level value is an object. A file that is not valid UTF-8, or that begins with a byte order mark, is invalid. Providers SHOULD store it with content type `application/json`; clients do not rely on the content type.
- It MUST NOT exceed 65,536 bytes.
- A manifest in which any object repeats a member name (compared after escape sequences are decoded, as in §6 item 1), or in which any member anywhere is named `__proto__`, `constructor` or `prototype`, is invalid.
- Clients MUST ignore members they do not know, at every level, and MUST NOT reject a manifest because of them. Later TAPs MAY define further top-level members.

#### 3.2 Members

| Member | Type | Required | Rule |
|---|---|---|---|
| `tapeapi` | string | yes | Matches `^0\.[1-9][0-9]*$`. This TAP defines `"0.1"`. A client MUST accept any value of that form and MUST reject any other; a later minor version only adds optional members |
| `name` | string | no | At most 64 Unicode code points. Display only; it carries no identity |
| `circuits` | string | yes | The processor contract: `0x` and 40 hex digits, all lowercase or a valid EIP-55 checksum |
| `tokenId` | string | yes | The #ID in decimal without leading zeros |
| `container` | string | yes | The container address, same form as `circuits` |
| `signer` | string | yes | The signer address, same form as `circuits` |
| `delegation` | object | yes | `{ "expires": number, "sig": string }` (§4). Required even when `signer` equals the holder |
| `delegation.expires` | number | yes | A positive integer, in Unix seconds |
| `delegation.sig` | string | yes | `0x` followed by 65 to 1,024 bytes in hex; exactly 65 for an ECDSA signature |
| `endpoints` | object | yes | `{ "live": array, "async": boolean }` |
| `endpoints.live` | array of strings | yes | Absolute `https://` URLs without query, fragment, user name or password. May be empty. Providers SHOULD list at most 4 |
| `endpoints.async` | boolean | yes | `true` states that the service accepts requests as TAP-10 messages sent to its endpoint ID (TAP-10 §12.1). Either `live` is non-empty or `async` is `true` |
| `methods` | array of objects | yes | Non-empty; method names unique (§3.3) |
| `payment` | object | see rule | `{ "escrow": string, "unit": "BEM", "decimals": 8 }`. REQUIRED when any method's `priceBEM` is not exactly the string `"0"`, and then `escrow` MUST be a non-zero address in the form of `circuits`. Otherwise optional; an `escrow` that is present MUST be an address in that form. `unit` and `decimals` MAY be omitted and are then read as `"BEM"` and `8`; any other value is invalid |
| `contentSig` | string | no | The holder's signature over the rest of the manifest (§5) |

#### 3.3 Method descriptor

| Member | Type | Required | Rule |
|---|---|---|---|
| `name` | string | yes | Matches `^[A-Za-z_][A-Za-z0-9_]{0,63}$` and is not `__proto__`, `constructor` or `prototype` |
| `priceBEM` | string | yes | Matches `^[0-9]+(\.[0-9]{1,8})?$`: an amount of the BEM token (BNB Smart Chain `0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a`, 8 decimals). `"0"` means free. How a price is paid and settled is outside this TAP |
| `params` | object | yes | Parameter name to type name; may be `{}`. Type names are informative |
| `returns` | object | yes | Field name to type name; may be `{}`. Informative |
| `description` | string | no | At most 256 Unicode code points |

The request and answer formats of `endpoints.live` and `endpoints.async` are outside this TAP.

### 4. Delegation

#### 4.1 Domain and type

These values are fixed and never change:

| Item | Value |
|---|---|
| Domain type | `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)` |
| `name` | `"TapeAPI"` |
| `version` | `"1"` |
| `chainId` | The chain ID of the service's chain (TAP-10 §2.1) |
| `verifyingContract` | The hub address (§1) |
| Primary type | `Delegation(address container,address signer,uint64 expires)` |
| `DELEGATION_TYPEHASH` | `keccak256("Delegation(address container,address signer,uint64 expires)")` = `0xc5081f9dc7e79dfbe7f3b3220ed9e7a29d0bc53239ee74dc184e4ac1f810948c` |

```
DOMAIN_SEPARATOR = keccak256(abi.encode(
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
    keccak256("TapeAPI"), keccak256("1"), chainId, 0xe61A9C7213a6Aa616C246a2B569e555B417b25ee))
structHash       = keccak256(abi.encode(DELEGATION_TYPEHASH, container, signer, uint64 expires))
digest           = keccak256(0x19 ‖ 0x01 ‖ DOMAIN_SEPARATOR ‖ structHash)
```

`container`, `signer` and `expires` are the manifest's `container`, `signer` and `delegation.expires`. Because the hub address is the same on every chain, `chainId` alone separates the chains: a delegation for one chain MUST NOT be accepted on another. A chain added to the TAP-10 chain table without the hub at this address needs its own `verifyingContract`, named by a revision of this TAP.

#### 4.2 Signing

The holder signs `digest` with `eth_signTypedData_v4` or an equivalent. The signature is over `digest` itself, without the EIP-191 `personal_sign` prefix.

#### 4.3 Expiry

A delegation is acceptable only while `now < expires ≤ now + 31,622,400` (366 days). A client MUST reject a delegation outside this range.

#### 4.4 Holder check

The holder is the value of `ownerOf(#ID)` read in §2.2 step 1, never a value from the manifest. The delegation is valid when either holds:

1. **ECDSA.** `sig` is 65 bytes `r ‖ s ‖ v`; a `v` of 0 or 1 is read as 27 or 28, and any other `v` outside {27, 28} is rejected; `r` and `s` MUST be in [1, n − 1] and `s` MUST NOT exceed n/2, where n is the secp256k1 group order; and the address recovered from `digest` equals the holder.
2. **EIP-1271.** The holder has code at the pinned block, and `isValidSignature(bytes32 digest, bytes sig)` (selector `0x1626ba7e`), called on the holder at the pinned block, returns at least 32 bytes whose first 32 bytes are exactly `0x1626ba7e` followed by 28 zero bytes. A revert or any other return means the holder does not accept the signature.

A client MUST try ECDSA first when `sig` is 65 bytes and MUST reject a 65-byte `sig` that fails the range checks of item 1 without trying EIP-1271. A client MAY decline to support EIP-1271; it then rejects delegations that only item 2 would accept.

#### 4.5 Where authority comes from

A signer speaks for a service only through a delegation that passed this section in a manifest resolved under §2. A client MUST NOT accept a signer from any other source: an HTTP header, a response body, a directory or label contract, a manifest fetched over HTTP, or a manifest resolved on another chain.

### 5. Manifest content signature (optional)

#### 5.1 Purpose

A delegation covers `container`, `signer` and `expires` only. A holder MAY also sign the rest of the manifest in the member `contentSig`. Clients MAY ignore this section.

#### 5.2 Digest

- Domain: that of §4.1, with the service's `chainId`.
- Primary type: `ManifestContent(address container,bytes32 contentHash)`; `MANIFEST_CONTENT_TYPEHASH` = `keccak256("ManifestContent(address container,bytes32 contentHash)")` = `0x809c1147faa2cda8716cdc72c000b05406f238cb127fea6f0abed585c02aea1c`.
- `contentHash = keccak256(UTF-8(canonicalJSON(M)))`, where `M` is the manifest object exactly as parsed from the file, with its top-level member `contentSig` removed, and `canonicalJSON` is §6. A manifest without a canonical form cannot carry a content signature.
- `structHash = keccak256(abi.encode(MANIFEST_CONTENT_TYPEHASH, container, contentHash))`; `digest` as in §4.1.
- The signature is checked against the holder exactly as §4.4, with this digest.

#### 5.3 Use

A client that implements this section MAY verify `contentSig` when present, and MAY offer a setting that requires a valid one. Under that setting, a manifest without `contentSig`, or whose `contentSig` fails, is `manifest-invalid`. Without it, a failed `contentSig` MUST NOT be reported as verified content, and the client MAY report it as a warning and continue.

### 6. Canonical JSON

`canonicalJSON(v)` is the JSON Canonicalization Scheme (RFC 8785): object members sorted recursively by their names as sequences of UTF-16 code units, no insignificant whitespace, numbers in the shortest round-trip form of ECMAScript `Number::toString`, and strings escaped as ECMAScript `JSON.stringify` escapes them. In addition, a value has no canonical form, and a signer MUST refuse and a verifier MUST reject it, when:

1. any object in the JSON text it was parsed from repeats a member name, member names being compared after their escape sequences are decoded (so `"a"` and `"\u0061"` are the same name);
2. it contains a number that is not finite (including one written in JSON text that overflows to infinity) or that is negative zero;
3. it contains an integer whose absolute value exceeds 2^53 − 1;
4. any member anywhere is named `__proto__`, `constructor` or `prototype`;
5. any string or member name contains an unpaired UTF-16 surrogate.

A verifier recomputes the canonical form from the parsed value; it never hashes the bytes as received. Other TAPs that sign JSON values can refer to this section.

These rules are fixed and never change: every signature already made over a canonical form depends on them, and a change would invalidate it or give one value two canonical forms.

### 7. Rereading, rollback and revocation

#### 7.1 Caching and rereading

A client MAY keep a resolved service for reuse. The holder and site status it keeps are resolution results in the sense of TAP-10 §11: a client SHOULD NOT rely on them for more than 60 seconds without a reread. A client SHOULD reread a manifest older than one hour before an action that spends funds, and MUST NOT rely on a delegation after its `expires`. A **reread** repeats §2.2 at a new pinned block: it reads the holder, the site status and the manifest file again and repeats every later step. Only the processor table MAY come from a cache (TAP-10 §4.3). Checking again only the delegation of a kept manifest is not a reread.

A client MUST reread before it next relies on the service:

- when a signature that it checks against the kept `signer` fails;
- when the provider, or a later TAP's protocol, reports that the manifest has changed (for example a price or an endpoint). A value reported that way is only a trigger: after the reread the client uses what it read from the chain.

#### 7.2 Revocation

A delegation cannot be revoked on chain before it expires. It stops being accepted when:

- the circuit changes hands: the recovered address or EIP-1271 answer no longer matches the new holder (§4.4);
- the holder publishes a manifest with another `signer` or delegation, or removes the file;
- it expires.

Each takes effect for a client at its next reread.

#### 7.3 Rolled-back manifests

Whoever can write the container's site can put back an older manifest whose delegation has not expired. A client MAY keep, per chain, container, holder and signer, the highest `delegation.expires` it has accepted (a **floor**), and reject a manifest whose `delegation.expires` is below the floor for the same chain, container, holder and signer as `delegation-invalid`. A client that keeps floors MUST keep them where the services it resolves cannot write, and SHOULD let its user clear one.

## Rationale

- **The circuit is the identity.** A circuit already has a derivable container, a verifiable site and a holder, and users already recognise its name. A separate registry or name grammar for services would be a second identity system. Binding the manifest to the circuit resolved under TAP-10 (§2.2 step 5) means a manifest can never choose its own identity: its `circuits`, `tokenId` and `container` only have to agree with what the client derived.
- **The manifest is a site file.** It changes often and is small; as a site file it costs nothing new, and it inherits TAP-10's verification (derived container, length and SHA-256, node agreement, pinned implementations). A contract-stored manifest would need its own verification rules.
- **A delegation instead of the holder signing everything.** Holders are cold keys, multisig wallets or smart accounts; answering requests needs a hot key. A delegation keeps the holder key off the server, and binding `container` rather than `tokenId` makes it valid for exactly one derived container.
- **The hub address as `verifyingContract`.** It is a TapeOut-controlled address that exists on every chain of the chain table, so a service needs no contract of its own and none of this TAP's author's. The hub is never called; upgrading or sealing it does not change any digest. `chainId` separates the chains.
- **366 days, mandatory.** A delegation cannot be revoked before it expires (§7.2), so its lifetime bounds the damage of a lost signer key. A year allows annual renewal; anything longer is refused rather than trusted.
- **Site status applies in full, including activation.** The manifest is read from the site store, so TAP-10 §6.1 already stops the read when an implementation is not accepted. Activation is different: TAP-10 enforces it only through compliant shells (TAP-10 §6.3) and not in the messaging layer (TAP-10 §12.2). This TAP applies it to service resolution as well, so that a client reaches the same verdict about a name as an official shell, a service identity follows the same rules as a site identity, and a service convention does not become a way around activation. The alternative is to have clients other than shells resolve an unactivated service and only report its status as `unpaid`; services would then be usable before activation, but the same name could be relied on by one client and refused by another.
- **Only the exact key.** Landing rules exist for browsing. A service that has no manifest must not resolve to its `index.html` or fallback page.
- **Content signature is optional.** It helps only clients that require it, and it proves approval, not recency (§7.3). Making it mandatory would stop every holder that cannot sign typed data over a large object today. Its type name differs from `Delegation`, so neither signature can be presented as the other; TAP-10's key-derivation text is signed with `personal_sign` and cannot collide with either.
- **Canonical JSON with restrictions.** A value with two defensible canonical forms is a value two verifiers can disagree about, and a disagreement between verifiers is a signature bypass. Each restriction in §6 removes one such case found in practice (duplicate members, `-0`, unsafe integers, prototype keys, lone surrogates).
- **Amounts as decimal strings.** No floating point, readable JSON, and prices defined independently of how a later TAP settles them.
- **Left out.** A label directory contract, a shell API exposing services to sites, and bindings for MCP servers and AI APIs existed in the earlier text (Backwards Compatibility). None is needed to identify a service; the directory was never deployed and the shell API was never implemented. They can be proposed as separate TAPs.
- **Acknowledgement.** The idea of calling services under circuit identities came from @Theairresearch.

## Backwards Compatibility

This TAP adds no contract, hub function, payload format or name syntax, and changes nothing in TAP-10. A TAP-10 client that does not implement it sees the manifest as an ordinary site file.

**History and frozen constants.** This specification was published earlier in the TapeAPI repository under the self-assigned name "TAP-20" (with companion documents "TAP-21" to "TAP-27"). Those were local names, not TAP numbers; the editors assign this TAP's number (TAP-01 §6.1). The constants that were deployed under the earlier name are historical and never change: the EIP-712 domain name `"TapeAPI"` and version `"1"`, the type strings `Delegation(address container,address signer,uint64 expires)` and `ManifestContent(address container,bytes32 contentHash)`, the path `/.well-known/tapeapi.json`, the version string `"0.1"`, and, in companion drafts, strings such as `TAPI-1/resp/v2` and labels beginning with `TAP-26/`. None of them encodes this TAP's number.

**Existing manifests.** The manifest format is unchanged. Two rules that the earlier text stated as recommendations are now requirements, and the reference implementation already enforced both: rejecting duplicate member names, and the 366-day bound. The live manifest of `11.1013.tape` satisfies both (Test Cases).

**Differences between this text and the reference implementation.** The reference implementation (Reference Implementation, commit `fda84db`) was written to the earlier text and does not yet conform to this TAP. The known differences, and the planned changes:

| Area | Reference implementation today | This TAP | Plan |
|---|---|---|---|
| Container derivation | `hub.accountOf(circuits, tokenId)` | `opener.accountOf` under TAP-10 §4.2 | Read the opener. For the accepted hub implementations both return the same ERC-6551 address (checked for `11.1013.tape` at BNB Smart Chain block 124890135) |
| Container address input | Reads the manifest from that container, then takes the processor contract and #ID from the manifest and checks that they derive the container and that the factory knows the processor contract; does not call `token()` or find the processor number | TAP-10 §4.3 before any file is read; the manifest's identity values are only compared (§2.2 step 5) | Resolve under TAP-10 §4.3 first. Both paths accept the same circuit, because the container is derived from the processor contract and #ID |
| Label input | With a directory contract configured by the caller (there is no default), any other string is looked up there as a label | Not an input form (§2.1) | Keep label lookup outside resolution under this TAP |
| Missing file | Detected by `fileInfo.size` 0 | `chunkCount` 0 (§2.2 step 3, TAP-10 §7.1) | Use `chunkCount` |
| Decoding | Replaces bytes that are not valid UTF-8 and drops a leading byte order mark before parsing | Both make the manifest invalid (§3.1) | Decode strictly |
| Opened | Not read | TAP-10 §4.2 step 5, §6.2 `not-opened` | Read `isOpened` |
| Activation | Not checked | TAP-10 §6.2 `unpaid` ends resolution | Check `isLive` and `isContainerLive`. The author's two services, `11.1013.tape` and `12.1013.tape`, were not activated when read on 2026-09-30 and resolve as `unpaid` under this TAP until their holder activates them |
| Implementation pinning | Checks the hub and site store slots and by default only warns | Site store and payment contract, fail-closed (`store-changed`) | Check the payment contract too; make fail-closed the default (announced as a security fix, with an opt-out, or in a major version) |
| Pinned block | Reads at `latest` by default; optional pinning uses the finality tag and a timestamp age | One pinned block per resolution, freshness by block lag (TAP-10 §5.3) | Adopt TAP-10 §5.3 |
| Input without chain information | Resolved on the caller's or configured chain only | Every active chain, `ambiguous` (TAP-10 §4.1) | Resolve on every active chain |
| Name ranges | #ID and processor number up to 78 digits | TAP-10 §3.1 ranges | Apply TAP-10 §3.1 |
| What counts as an answer | Some JSON-RPC errors are compared across nodes as answers | Only results and reverts are answers (TAP-10 §1) | Treat other errors as node failures |
| Keeping results | Keeps `accountOf` answers and the implementation slots for up to 300 seconds across resolutions | Holder and site status are relied on for at most 60 seconds; only the processor table is kept (§7.1, TAP-10 §11) | Reread per resolution, keeping the processor table |
| Chain check | Does not check `eth_chainId` when resolving | Recommended (TAP-10 §5.4) | Add the check |
| Outcome names | `MANIFEST_INVALID` (also for a missing file, a non-existent token, `no-hash` and `incomplete`), `DELEGATION_INVALID`, `NOT_FOUND`, `RPC_DISAGREE`, `RPC_UNAVAILABLE`, `RPC_STALE` | §2.3 and TAP-10 names | Add the §2.3 name to each error, keeping the existing codes |

Apart from the rows above, a client built to the earlier text and a client of this TAP reach the same verdict on the same manifest. The earlier text also defined a label directory, a shell capability and MCP and AI bindings (Rationale, "Left out"); a client of this TAP ignores the `mcp` and `ai` members as unknown members.

## Test Cases

Vector files are in `assets/tap-11/`. Each gives inputs and exact expected outputs. The reference implementation at the fixed commit below reproduces `delegation.json`, `content-signature.json` and `canonical-json.json` (the last from `sdk/src/canon.js`), and the file verification and delegation recovery of `mainnet-11-1013.json`. The reads that this TAP adds from TAP-10 (opener, `isOpened`, activation, the payment contract's implementation slot) were recorded with plain `eth_call` and `eth_getStorageAt`; the reference implementation makes them under `conform: 'tap10'` and not on its default path (Backwards Compatibility).

**`delegation.json`** (§4). The domain separators, a worked example on all three chains, two signatures by a published test key, and rejections. For `container = 0x0000000000000000000000000000000000000002`, `signer = 0x0000000000000000000000000000000000000003`, `expires = 1790000000`:

| Value | Result |
|---|---|
| `keccak256("TapeAPI")` | `0x6f09e044b872e2827cf4fdc5d623450caee9449f1fc4151b8f9e3582593a8802` |
| `keccak256("1")` | `0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6` |
| `structHash` | `0x525ae7f6670fd36175882a96c6f8491af6c83c3ebb4ab51437a9733ecc7dd6da` |
| `DOMAIN_SEPARATOR`, chainId 56 | `0xa73ee348b5672f12dbc174f66a7d162c69e0d64befdba88475d9d7e3c0fd3ac7` |
| `digest`, chainId 56 | `0xf0ef7315ef455303fb4a7d8a301ca84f25e9fbd0641e931cdb01e7f7e8bcaa9a` |
| `DOMAIN_SEPARATOR`, chainId 8453 | `0xab3b0c6f3cecceb9d441893c56616889d71cf893f74296dc2229a6f241238516` |
| `digest`, chainId 8453 | `0x741c7e6412012f5134d127404641a4eb294c77e30a7b19104aece30efe1be9b9` |
| `DOMAIN_SEPARATOR`, chainId 196 | `0xf9c5be6dcd7d4cfdf9c57717c7d6a7e04bccd499d2a7f3fcfdc603cc7f1f3ad6` |
| `digest`, chainId 196 | `0xf4f57ad38c3efd363cbd271e3fc9fa7a54a1302db7f6adcc202a53f8a7cd529a` |

The test holder key `0x` followed by 64 digits `1` (address `0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A`) signs, on chainId 56, `container = 0x86DDaEF00401E3F10418398D67D7189fc458eA95`, `signer = 0x1563915e194D8CfBA1943570603F7606A3115508`, `expires = 1791592000`: digest `0xb6c9879471c2f82db4bb634a7ede3637872c77f75cf2746e30032e00a6b1be41`. Rejected: the same signature on chainId 196 (recovers to `0xf041d1b484C5103D32Ee6eb3Fe5FE8CF3448f5b6`); with `expires` one second later (recovers to `0x2B93279a4576d81874Ad8BFfD7F66099f21F7aDd`); with `s` replaced by `n − s` (high `s`). The expiry cases fix `now = 1790000000`: `expires` 1790000000 and 1821622401 are rejected, 1790000001 and 1821622400 accepted.

**`content-signature.json`** (§5). Two manifests signed by the same test key on chainId 56, with their canonical forms, `contentHash` (`0x37b2d1b772e3f90d4975aecbe22d00e00c185e2db6e7ccf726a2cd4d7386e2b9` for the first), `structHash`, digest and signature; the second differs only in its endpoint. The first signature attached to the second content recovers to `0x39987963c6069A93915024607D5537DD733a208a` and is rejected.

**`canonical-json.json`** (§6). JSON texts with their exact canonical form and its keccak256, including member order by UTF-16 code units (`é` before an emoji), number forms and string escapes; and texts that have no canonical form (a repeated member, also nested and also written once with an escape; `-0`; `9007199254740992`; `1e400`; `__proto__` and a nested `constructor`; a lone surrogate).

**`mainnet-11-1013.json`** (§2). The service `11.1013.tape` on BNB Smart Chain, read-only at block 124886559 (hash `0x2c4a5d41009682a9a450cb9b9df5e4b03fef6e74b85e03c19f899f1eaff9ef69`) from two operators with identical answers. Most public nodes no longer serve state at that block; the same reads gave the same results at block 124890135 (hash `0xae8aa2fc2ab1b59eaca4912929f13d09ea9426701e706336f65b27f34af10d66`), again from two operators:

| Read | Result |
|---|---|
| `cpuAt(1013)`, `isCPU` | `0xe02c26c7432A7121168AA9B610DE24eCf9a1a414`, true |
| `opener.accountOf(…, 11)`, `isOpened` | `0x1b2A657BcBa9D3229f57aC2f4FcbEE2AA756aAe8`, true |
| `ownerOf(11)` | `0x086bFB1908B1DF8C0c4412f28E4DD22Bdd52d715` |
| Site store and payment contract implementations | `0x1d279D138A4D803378a7d4557c056f1beD53c261`, `0xaa226181a6588d3f9AC0035e5f3dBaF311039bCE` (both accepted) |
| `isLive("11.1013.tape", container)`, `isContainerLive(container)` | false, false |
| `fileInfo(container, ".well-known/tapeapi.json")` | 3,414 bytes, `application/json`, SHA-256 `0xee57f304f8316802978695e8e9f14e89ce1f9e5c79123b5a583fdcfd3b52c37a` |

Expected outcome at that block: **`unpaid`**. The file also gives the exact 3,414 manifest bytes (their SHA-256 equals the declared hash) and what steps 3–6 produce with them: `signer` `0xaB70dEe8e1CEabb1D10eDFeBcbe0c313c53cf154`, `expires` 1798190813, delegation digest `0x2477541749b1b28de5dba42ee4d9f252e904dfb9042eb15068527e3213fb4a7b`, which recovers to the holder. Two rejections: another service's valid manifest served from this container, and this manifest with its `container` replaced, are both `manifest-invalid`.

## Reference Implementation

The TapeAPI SDK at [BruceLanLan/tapeapi, commit `4a1ac4fe2a0b2e3327652a794794765dd5da98ef`](https://github.com/BruceLanLan/tapeapi/tree/4a1ac4fe2a0b2e3327652a794794765dd5da98ef) (version 1.8.1, MIT licensed). A client created with `createTapeAPI({ conform: 'tap10' })` resolves as §2 says; the SDK's default path differs from this text as listed under Backwards Compatibility.

| Location | Covers |
|---|---|
| `sdk/src/index.js` (`resolveConform`, `identifyAt`, `conformManifest`, `finishConform`, `siteStatus`) | §2 under `conform: 'tap10'`; §7.1 (a kept service is resolved again before a call once it is 60 seconds old, `CONFORM_TTL_MS`) |
| `sdk/src/index.js` (`resolve`, `verifyDelegation`, `holderApproves`, `contentSigProblem`) | The default path; §4.3–§4.4, §5.2–§5.3 (`requireContentSig`), §7.3 (`delegationFloor`) |
| `sdk/src/manifest.js` | §3 |
| `sdk/src/sig.js` | §4.1, §5 |
| `sdk/src/canon.js` | §6 |
| `sdk/src/rpc.js` (`tap10Block`; the read options `answers: 'tap10'` and `strict`), `sdk/src/chains.js`, `sdk/src/processors-snapshot.js` | The pinned block of TAP-10 §5.3, what counts as an answer, default and strict agreement, the chain table, names and their ranges, the processor table |
| `sdk/test/conform-tap10.test.mjs`, `sdk/test/conform-strict-holder.test.mjs`, `sdk/test/conform-allchains.test.mjs` | Tests of the conformance mode against a simulated chain: input forms, the order of §2.2 and TAP-10 §6.2, the pinned block, strict agreement for `ownerOf` and EIP-1271, input without chain information |
| `docs/guides/upgrade-1.0.md`, section "The TAP-10 conformance mode" | How the mode is enabled, what it does differently from the default path, and its limits |
| `spec/vectors/verify.py` | An independent Python implementation of §4–§6, checked against the repository's own vectors and an earlier recording of the `11.1013.tape` manifest (`sdk/test/fixtures/mainnet-11-1013-manifest.json`); it does not read the files in Test Cases |

The differences from this text are listed under Backwards Compatibility. The services `https://api.tapeapi.fun` (`11.1013.tape`) and `https://relay.tapeapi.fun` (`12.1013.tape`) on BNB Smart Chain publish manifests in this format.

## Deployments

This TAP deploys no contract. It reads the contracts below, at the addresses of TAP-10 Deployments, and accepts only the implementations TAP-10 lists. On 2026-09-30 every implementation below, and the seal status, was read again from two operators on each chain (BNB Smart Chain at block 124890135 and later, Base and X Layer at the latest block); every value matched TAP-10 Deployments. Anyone can repeat this with `eth_call` and `eth_getStorageAt` on the ERC-1967 slot `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`.

| Contract | BNB Smart Chain (56) | Base (8453) and X Layer (196) | Implementation (TAP-10 Deployments) | What this TAP uses | Sealed? |
|---|---|---|---|---|---|
| Processor factory (UUPS proxy) | `0x68224F668083c29e9800Be2a646d42d18cedF7e2` | `0x1f09DAeFA827f02CBb40967cc91b259763760761` | BNB `0xa68cCF4931d98ad0A4BE15eE40542eDc0DEc6422`; Base, X Layer `0x74956236Ab64eD143933040B4137E8A352e4d17b`. A seal constant of TAP-10 §13.8; this TAP does not check it | `cpuCount`, `cpuAt`, `isCPU` (TAP-10 §4) | No |
| Container opener | `0x021745DE2f42A7839d96f2d3634d0294487D81F1` | `0x536adD8F30f03b69f6fbF29d425A816A0dC50106` | — | `accountOf` `0x0c1905e5`, `isOpened` `0x8b508494` | — |
| ERC-6551 registry | `0x000000006551c19487814612e58FE06813775758` | the same | Not a proxy | Not called; the container is `registry.account(containerImplementation, 0, chainId, processor contract, #ID)`, which a client can recompute to check `accountOf` | — |
| Container implementation | `0xAf4E78a2257C9c5480c2F8310E3b00437260751d` | `0xAC4F791353eE9F06e2C50Ae4C34680D28Ea52a57` | — | The code behind every container; `token()` `0xfc0c546a` is called on the container itself (TAP-10 §4.3) | — |
| Site store `SiteRegistry` (UUPS proxy) | `0xd006ffdd5Ae313B17729621A00999cD3C71CE5e6` | `0xd6EFb7adCc9c83dC4924Ad56f6a8E4e969b9ADB6` | Must be BNB `0x1d279D138A4D803378a7d4557c056f1beD53c261`; Base, X Layer `0xa85c4143d1D4A77f54b8e4ecC9E6D1418Afea45f` (TAP-10 §6.1) | Implementation slot, `fileInfo` `0x6c609107`, `read` `0xccaa7afb`, `readRange` `0x15a4cae2` | No (upgradeable) |
| Payment contract `DomainBinding` (UUPS proxy) | `0x861EE183de2BBE4a6ecf9D15812C123b566a3DB7` | `0x68809Fd2fb343aA57D0aeB7f33Defe477c9666f9` | Must be BNB `0xaa226181a6588d3f9AC0035e5f3dBaF311039bCE` (or the previous `0x4E8684EaEA48b524245B2191DeE451eAa1c1cA94`); Base, X Layer `0x5eBF29b80789e548907C707530C3C7607C4347Df` (TAP-10 §6.1) | Implementation slot, `isLive` `0xd6b062cd`, `isContainerLive` `0xdcca979e` | No (upgradeable) |
| DeWEB hub (proxy) | `0xe61A9C7213a6Aa616C246a2B569e555B417b25ee` | the same | v3: BNB `0x80aFE7B77F2dFD08e9feab7675780baC34a7EE85`; Base `0x38A2d320b8984Bbac9b0a2691B6c0FD829A23867`; X Layer `0xdCC57797089eBD9f26e686379A4323f353a3F9C6`. Checked by TAP-10 messaging clients (TAP-10 §13.8), not by this TAP | Not called; its address is the EIP-712 `verifyingContract` (§4.1) | No |

Processor contracts are read for `ownerOf` `0x6352211e`; a contract holder for `isValidSignature` `0x1626ba7e` (§4.4). As of these reads no hub and no processor factory is sealed on any chain (`isSealed()` 0, hub owner `0x571d447f4f24688eC35Ccf07f1D6993655F6aF15`), and the site store and payment contract are upgradeable. This TAP therefore cannot become Final before they are sealed or no longer upgradeable (TAP-01 §5.1).

## Security Considerations

- **What is protected.** A client that follows §2 accepts a signer only if the current holder of the circuit behind the name signed a delegation for that exact container and signer, on that chain, within the last 366 days, in a file whose bytes match the chain. A self-reported container, a counterfeit ERC-721, a delegation from another chain, a previous holder's delegation and a manifest served from another container are all rejected.
- **Site writers.** Whoever can write the container's site (the holder, an operator the holder set with `setOperator`, or an upgrade of the site store) can change endpoints, methods and prices under a delegation that stays valid, and can put back an older manifest until its delegation expires. They cannot create a delegation for a new signer. A client that requires `contentSig` (§5) detects changed content, but not rollback to older signed content; floors (§7.3) detect rollback only for clients that saw the newer manifest.
- **Signer key compromise.** A stolen signer key speaks for the service until the holder publishes a new manifest and clients reread, or until the delegation expires; the 366-day bound caps this. Providers should keep the signer key in an isolated process and use short delegations.
- **Holder transfer.** A buyer of the circuit inherits the container and its site, including the old manifest; the old delegation fails from the next reread because the recovered address is no longer the holder. Clients that cache resolved services keep trusting the old signer until they reread (§7.1).
- **Nodes.** Default agreement defeats a single lying node, not every configured operator lying together (TAP-10 Security Considerations). Forging `ownerOf` or the EIP-1271 answer would authorise an attacker's signer, which is why strict agreement is recommended for those reads.
- **Upgradeable contracts.** The owners of the site store, the payment contract and the processor factory can change what they return until they are sealed. Implementation pinning makes a lasting change fail closed but cannot detect an upgrade that restores an accepted implementation within one transaction (TAP-10 §13.8). The hub is not called, so its upgrades do not affect this TAP.
- **Contract holders.** An EIP-1271 holder decides by its own code which signatures it accepts, and its answer can change from one block to the next. Pinning every read to one block keeps a resolution consistent, not stable over time.
- **Clock.** Expiry is compared with the client's clock, unlike TAP-10's block-lag freshness. A client with a slow clock accepts an expired delegation; one with a fast clock rejects a valid one. Clients that care can compare with the pinned block's timestamp as well.
- **Activation.** Resolving under this TAP requires the name to be activated (§2.2 step 2, TAP-10 §6.3). As TAP-10 §6.3 says, the site store can still be read without it; a client that reads a manifest that way has not resolved the service under this TAP.
- **Transport and meaning.** `https://` protects the connection to an endpoint, not the truth of what it returns. A manifest proves who stands behind a service, not that its methods behave as described; signed answers, defined by later TAPs, make behaviour attributable rather than correct.
- **What the holder sees when signing.** Wallets show the `verifyingContract` field of EIP-712 typed data, so a holder who signs a delegation or a content signature sees the DeWEB hub named as the verifying contract (§1). That is expected and harmless: the hub is never called and nothing is authorised on it (§4.1). A holder should check the other fields shown, namely the container, the signer and the expiry, and that the domain name is `TapeAPI`.
- **Parsing.** Manifests are attacker-controlled. The 64 KiB bound, the rejection of repeated and prototype member names and the canonical JSON restrictions limit parser differences and prototype pollution.
- **Privacy.** Resolution reads only public chain state. Calling an endpoint reveals the caller's network address and request to the provider.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
