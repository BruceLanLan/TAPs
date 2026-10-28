---
tap: TBD
title: Agent Passports for Container Services
description: How a wallet that holds both a TapeOut circuit and an ERC-8004 agent identity binds the two, publishes the binding in the circuit container's site, and how tools verify, display and count reputation for that binding read-only.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/80
status: Draft
type: Application
created: 2026-10-24
updated: 2026-10-28
requires: TAP-10, TAP-11, TAP-13, ERC-721, ERC-8004 (Draft; as deployed on BNB Smart Chain, identity registry implementation 0x7274e874ca62410a93bd8bf61c69d8045e399c02, Specification §2)
license: CC0-1.0
---

# TAP-TBD: Agent Passports for Container Services

## Summary

A software agent that offers services can show, in a way anyone can check on the blockchain, that its public agent identity and its TapeOut circuit, with the circuit's website, signed answers and reviews, belong to the same owner.

## Abstract

A **passport** binds an ERC-8004 agent identity (`agentId` in the identity registry deployed on BNB Smart Chain) to a TapeOut circuit (TAP-10) whose container hosts the agent's service (TAP-11, TAP-13). It holds when one wallet, the **holder**, owns both tokens; the identity carries the metadata key `tap.passport = abi.encode(uint256 chainId, address processor, uint256 tokenId)`; the container's site holds the ERC-8004 registration file naming exactly one identity of that registry, with the holder's EIP-712 signature over that listing; and the registry's `agentWallet` equals the holder. This TAP fixes those rules (P-1 to P-11), the key's encoding, the `tap` member of the registration file and its listing signature, a resolution algorithm that reads the chain before any file at one pinned block under strict agreement and needs no log query, state words, holder epochs (which need an indexer or an archive node) and display rules. Two optional parts, for tools that implement unmerged drafts, write evidence-backed reviews as ERC-8004 feedback and count them, and show the independent layers of authorisation an agent may be under. The TAP defines one EIP-712 type, the listing, and no contract, token or fee.

**Builds on drafts not yet merged.** `requires` lists only TAPs merged as Drafts (TAP-10, TAP-11, TAP-13) and ERC-8004 as deployed. This text also refers to the following pull requests of the TAPs repository, each at the commit named here. Every rule that depends on one of them is conditional on a tool implementing that draft at that commit; none of the core rules P-1 to P-11 depends on them. When one is merged and numbered, the references change to its number.

- TAP-15, *MCP Tools as Container Service Methods* (pull request [#16](https://github.com/TapeOutProtocol/TAPs/pull/16), merged as a Draft from commit `13d1179f89b8c7037ebfb4e3ec3e574c1740e989`): the manifest member `mcp` (display rule D-7).
- TAP-18, *Container Agent Mandates and Task Messages, Phase 0* (pull request [#47](https://github.com/TapeOutProtocol/TAPs/pull/47), merged as a Draft from commit `50a5a6f92abfefb3cdde4af2c86a9b18c087a3d6`), and [#60](https://github.com/TapeOutProtocol/TAPs/pull/60), *Container Agent Mandates Enforced by Escrow Channels, Phase 1*, at commit `42ce7aef2d16ef64c3d8ba94e255076c3db16a25`: the authorisation layers of §11.
- [#49](https://github.com/TapeOutProtocol/TAPs/pull/49), *Agent Member of the Service Manifest*, at commit `2af5cb34a02969491f88d0343edc6ccbfdca73ac`: informative only (Rationale).
- [#54](https://github.com/TapeOutProtocol/TAPs/pull/54), *Evidence-Backed Reviews between Containers*, at commit `703b2a91edf7545b3179a08b8041b49190fd4a0a`: the review record, its review hash and its counting rules, used by §10.
- TAP-14 (*Private Channels*, merged as a Draft from pull request [#12](https://github.com/TapeOutProtocol/TAPs/pull/12) at commit `496c3c90c9dc191e434659b451f718bd02cd5e79`), [#52](https://github.com/TapeOutProtocol/TAPs/pull/52) (*Payment Vouchers*, at commit `82b412495b7ee97dda6e86174e98cd051ea61bda`), [#59](https://github.com/TapeOutProtocol/TAPs/pull/59) (*Escrow Channels*, at commit `098de456152615d7c289c650a8a50533ccf53df1`) and [#77](https://github.com/TapeOutProtocol/TAPs/pull/77) (*Visitor Grants*, at commit `24eaf4c8514535f079bbe9f99172e2d540c28698`): mentioned in §8, §11 and the Rationale; nothing here depends on them.

## Motivation

This TAP is inspired by ERC-8004 (Trustless Agents) and interoperates with its registries as deployed on BNB Smart Chain; it is not an extension of ERC-8004 and is not endorsed by its authors or by anyone operating those registries.

ERC-8004 gives an agent a number (`agentId`), an owner, a URI that the owner can point anywhere, free-form metadata, and registries where anyone can leave feedback. It does not say whether the agent behind the number answers for what it says, and its own text notes that registration does not prove any capability. TapeOut already has the pieces an accountable agent needs: a container website on chain with a SHA-256 for every file (TAP-10), a manifest naming the key that signs the service's answers under a holder delegation (TAP-11), and a signature on every answer (TAP-13). What is missing is a rule that ties an ERC-8004 identity to such a container so that independent wallets, indexers and agents reach the same conclusion, and that a stranger cannot fake.

The obvious rule, "the identity's metadata names the circuit and both tokens have the same owner", is not enough: on the deployed registry anyone can register an identity with any URI and metadata and transfer it to any address without consent (measured on a fork of BNB Smart Chain at block 129352831). A passport therefore also needs statements that only the holder can make: a registration file in the container's site that lists the identity under the holder's own signature, and the registry's `agentWallet`, which a transfer clears and only the owner's own signature restores.

The target users are **agents that offer tools or tasks to others**: they gain a verifiable website, pinned tool definitions, signed answers and reviews backed by them. An agent that only wants an identity gains little over ERC-8004 alone.

A holder needs nothing from any wallet provider: every step is an ordinary contract call or an EIP-712 signature, so a custodial wallet that can make both works (Appendix A). Every state word is decided from reads of state at one block, which keyless public nodes serve; only holder history and reputation counts need an indexer or an archive node.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### Conformance summary

This table is a guide; where it and a section differ, the section prevails.

| Part | Who | Sections | Status |
|---|---|---|---|
| Binding rules P-1 to P-11, key encoding, registration file, listing signature | Holders and every tool that reports a passport | §3, §4, §5 | Core |
| Resolution and state words | Every tool that reports a passport | §6.1 to §6.3 | Core |
| History tier: holder epochs, site-operator check | Tools with an indexer or an archive node; every other tool reports them as unavailable | §6.4, §7 | Core (what a log-less tool reports); the operator check is optional |
| Signers and `agentWallet` | Every tool | §8 | Core |
| Tools that request signatures or build calls | Consoles, onboarding tools, agent runtimes | §9 | Core for those tools |
| Reviews as ERC-8004 feedback | Tools that implement #54 at the cited commit and have the history tier | §10 | Optional, conditional |
| Authorisation layers | Tools that show mandates or wallet limits | §11 | Optional, conditional |
| Display rules | Every tool that shows a passport | §12 | Core |

### 1. Terms and notation

- **Circuit**, **processor contract**, **processor number**, **#ID**, **container**, **holder**, **opened**, **plain account**, **site store** (`SiteRegistry`), **operator** (of a node), **pinned block**, **strict agreement**, **endpoint ID**, **on-chain name**: TAP-10 §1, §3.1, §12.1. **Manifest**, **signer**, **delegation**: TAP-11 §1.
- **Identity**: a token `agentId` of the identity registry of §2. **Identity owner**: its `ownerOf(agentId)`.
- **Passport**: an identity and a circuit for which a tool reports CONFIRMED under §6.
- **Holder**: the holder of the circuit, `processor.ownerOf(#ID)` (TAP-10 §1).
- **Site operator**: an address that `SiteRegistry.setOperator(container, operator, ttl)` allows to write the container's files (TAP-10 Appendix A). It is not a node operator.
- **Registration file**: the file of §5, read from the site store under the key `.well-known/agent-registration.json` (the URL path `/.well-known/agent-registration.json` without its leading `/`, TAP-10 §7.2 step 3).
- **Listing**: the member `tap.listing` of the registration file, the holder's EIP-712 `PassportListing` signature of §5.5 over the identity, the identity registry and the container.
- **History tier**: the parts of this TAP that need `eth_getLogs` over the whole history of a token or a container (§6.4), which in practice means an indexer or an archive node that serves logs. **Log-less tool**: a tool that reads only state at the pinned block (`eth_call`, `eth_getStorageAt`, `eth_getCode` and block headers).
- **Tool**: software that resolves, displays or counts passports, or that asks a holder to sign or send something for one.
- **Runtime driven by untrusted text**: software that decides which transaction or signature to request from what a language model produces after reading text it did not author (web pages, files, tool results, messages, registration files).
- `abi.encode`, `keccak256` and EIP-712 are as in Solidity and EIP-712. `canonicalJSON` is TAP-11 §6. SHA-256 is FIPS 180-4. Hex is lowercase with `0x` unless stated otherwise; addresses are compared case-insensitively.

### 2. Scope, chain and the registries read

1. This version defines passports on BNB Smart Chain (chain ID 56) only. The identity and the circuit MUST be on that chain.
2. The identity registry is the proxy `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`; the only accepted implementation is `0x7274e874ca62410a93bd8bf61c69d8045e399c02` (code hash `0xa5f9624ea85e45b3f4b8558581f03bfb3e6cefab278d7bf0500ec9bd065dc16f`). The reputation registry used by §10 is the proxy `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` with the implementation `0x16e0fa7f7c56b9a767e34b192b51f921be31da34` (code hash `0x38602de97f1bd86f0a4729f7f3c0a78b1d27892e6eb581272cce5504a68fd00b`). A tool MUST read the ERC-1967 implementation slot `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` of each proxy it uses at the pinned block, and MUST NOT report CONFIRMED when the implementation is not the one listed here (`registry-changed`, rule S-4).
3. The TapeOut contracts are those of TAP-10 Deployments for chain 56. A tool MUST NOT learn any of these addresses from a site, a file or a message.
4. The functions this TAP uses on the registries are exactly those of the interface below, written from the deployed implementations; every selector was found in the deployed bytecode (Deployments). ERC-8004 is a Draft; this TAP depends on the deployed behaviour, not on the EIP text. On a holder that is a contract, a tool also calls EIP-1271 `isValidSignature(bytes32,bytes)` (`0x1626ba7e`) as TAP-11 §4.4 item 2 does (§5.5).

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

interface IERC8004IdentityPassportSubset {
    struct MetadataEntry { string metadataKey; bytes metadataValue; }
    function ownerOf(uint256 agentId) external view returns (address);                                // 0x6352211e
    function tokenURI(uint256 agentId) external view returns (string memory);                         // 0xc87b56dd
    function getAgentWallet(uint256 agentId) external view returns (address);                         // 0x00339509
    function getMetadata(uint256 agentId, string calldata metadataKey) external view returns (bytes memory); // 0xcb4799f2
    function register(string calldata agentURI, MetadataEntry[] calldata metadata) external returns (uint256 agentId); // 0x8ea42286
    function setAgentURI(uint256 agentId, string calldata newURI) external;                            // 0x0af28bd3
    function setMetadata(uint256 agentId, string calldata metadataKey, bytes calldata metadataValue) external; // 0x466648da
    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature) external; // 0x2d1ef5ae
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
}

interface IERC8004ReputationPassportSubset {
    function giveFeedback(uint256 agentId, int128 value, uint8 valueDecimals, string calldata tag1, string calldata tag2,
        string calldata endpoint, string calldata feedbackURI, bytes32 feedbackHash) external;          // 0x3c036a7e
    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external;                           // 0x4ab3ca99
    function getSummary(uint256 agentId, address[] calldata clientAddresses, string calldata tag1, string calldata tag2)
        external view returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals);        // 0x81bbba58
}
```

5. Facts of the deployed identity registry that this TAP relies on: `register` mints to `msg.sender` and sets `agentWallet` to that address; a transfer of the identity clears `agentWallet` to zero and keeps the URI and every other metadata entry; `agentWallet` is a reserved key that `register` and `setMetadata` cannot write; `setAgentWallet` accepts an EIP-712 signature in the domain (`"ERC8004IdentityRegistry"`, `"1"`, 56, the registry proxy) over `AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)`, with `owner` the current identity owner and `deadline` at most about 300 seconds after the block time; the reputation registry rejects a feedback whose submitter is the agent's owner or an approved operator, and `getSummary` reverts when `clientAddresses` is empty. The sources of each fact are listed under Deployments.

A passport is not a credential, a licence or a certification. It confers no right to income, payment, tokens or any other asset, and a tool MUST NOT present it as doing so.

### 3. The passport binding

A tool reports CONFIRMED for an identity `agentId` of the registry of §2 only when all of the following hold at one pinned block, read under strict agreement (§6.1):

- **P-1 (one holder).** `ownerOf(agentId)` of the identity registry equals `processor.ownerOf(tokenId)`, where `processor` and `tokenId` come from the key of P-2. A revert of the identity's `ownerOf` is `no-such-agent`.
- **P-2 (the key).** `getMetadata(agentId, "tap.passport")` returns exactly the 96 bytes of §4.
- **P-3 (one chain).** The `chainId` in the key, the `eth_chainId` of the nodes, and the `tap.chainId` of the registration file are all 56; the file's listing counts only for the registry on chain 56 (P-10).
- **P-4 (a TapeOut circuit).** `factory.isCPU(processor)` is true and `processor.ownerOf(tokenId)` does not revert (TAP-10 §4.2, §4.3). The container is `opener.accountOf(processor, tokenId)`; a tool MUST NOT take the container from any file.
- **P-5 (opened).** `opener.isOpened(processor, tokenId)` is true.
- **P-6 (reads).** Every read was adopted under §6.1 at one pinned block that is not stale, and the implementations of §2 item 2 and TAP-10 §6.1 are accepted. When this fails the result is UNAVAILABLE, never BROKEN.
- **P-7 (the file).** The registration file of the container exists, passes §5, and its `tap` member states the same chain, processor, #ID and container as the chain.
- **P-8 (the holder's signature).** The registration file's `tap.listing` (§5.5) is a `PassportListing` signature over `agentId`, the identity registry of §2, the container of P-4 and the listing's `issued`, and it is accepted for `ownerOf(agentId)` read at the pinned block, by ECDSA or EIP-1271 as §5.5 item 5 says. Otherwise the result is `listing-not-by-holder`.
- **P-9 (agent wallet).** `getAgentWallet(agentId)`, read live at the pinned block, equals the holder and is not zero. A tool MUST NOT take this value from a cache or from events.
- **P-10 (the holder's statement).** The registration file lists, for the registry of §2, exactly one identity, and it is `agentId`. A file that lists more than one identity of this registry makes the result AMBIGUOUS. An identity that the file does not list is not a passport, whoever owns it.
- **P-11 (one circuit).** When the input is a circuit (§6.2 step 2), the processor and #ID of the key of P-2 are those of the input circuit; otherwise the result is `key-circuit-mismatch`.

P-1 and P-2 alone do not show the holder's intent: anyone can register an identity naming any circuit and transfer it to the circuit's holder (Security Considerations, T1). P-10 and P-8 together are the holder's statement: the file lists the identity, and the holder signed that listing for this container. Being able to write the file is not enough, because a site operator that an earlier holder set may still be able to write it (§6.4); signing needs the holder's key. No rule of P-1 to P-11 needs a log query. P-9 shows that the holder used the identity's own key path since it last changed hands. P-11 stops a copied registration file in another circuit, which anyone can give to the holder, from answering for the circuit the key names (T13).

### 4. The `tap.passport` key

The value of the metadata key `tap.passport` (the ASCII string, without terminator) MUST be

```
abi.encode(uint256 chainId, address processor, uint256 tokenId)     // 96 bytes
  bytes  0..31   chainId, big-endian
  bytes 32..43   zero
  bytes 44..63   processor contract address
  bytes 64..95   tokenId (#ID), big-endian
```

1. A tool MUST compare the value byte for byte and MUST treat any other length, non-zero bytes 32 to 43, a `chainId` of 0, a zero processor, or a `tokenId` outside 1 to 10^18 as `bad-passport-key`; an empty value is `no-passport-key`.
2. A holder SHOULD write the key in the transaction that registers the identity, `register(agentURI, [("tap.passport", value)])` (selector `0x8ea42286`), so that the identity never exists without it. A holder MAY write it later with `setMetadata`.
3. A holder that moves the passport to another circuit MUST rewrite the key and the registration files of both containers; a tool resolves each state as it finds it.

Example (informative): processor `0x50a994e71615474b55559ff4f500928fbc339dd9`, #ID 4246 on chain 56 gives `0x0000…0038` ‖ `0x000000000000000000000000 50a994e7…9dd9` ‖ `0x0000…1096`.

### 5. The registration file

#### 5.1 Location and agentURI

1. The registration file MUST be stored in the container's site under the key `.well-known/agent-registration.json`, the path ERC-8004 uses for endpoint domain verification.
2. **R-3.** The identity's `agentURI` SHOULD be `https://<label>.<gateway domain>/.well-known/agent-registration.json`, where `<label>` is the gateway host label of the circuit (TAP-10 §3.3, for example `4246-0`), so that each passport is its own endpoint domain. A tool MUST NOT read the registration file through the URI to decide a state; it reads the site store, and it reports a URI of another form as the warning `agent-uri-not-canonical`.

#### 5.2 Form

1. The file MUST be UTF-8 JSON (RFC 8259) without a byte order mark whose top-level value is an object, MUST NOT exceed 65,536 bytes, MUST NOT repeat a member name or contain a member named `__proto__`, `constructor` or `prototype`, and MUST have a canonical form under TAP-11 §6 (**R-5**). The file MUST have a SHA-256 declared in the site store; a file without one (`no-hash`) or that fails TAP-10 §7.1 step 4 (`incomplete`) is not read.
2. `type` MUST be `"https://eips.ethereum.org/EIPS/eip-8004#registration-v1"`. `registrations` and `services` MUST be arrays. Other ERC-8004 members keep their meaning and are not checked by this TAP.
3. `registrations` MUST contain the entry `{"agentId": <agentId>, "agentRegistry": "eip155:56:<identity registry address>"}`. `agentId` is a JSON integer or a decimal string without leading zeros; the address is compared case-insensitively. Entries for other registries or chains are ignored by P-10.
4. `services` MUST contain an object whose `name` is `"tape"` and whose `endpoint` is `tape://<on-chain name>` of the circuit (TAP-10 §3.2), for example `tape://4246.0.tape`; it MAY have `version` `"1"`. A file without it is `tape-service-missing`.
5. Members not named here are ignored, except under §5.4.

#### 5.3 The `tap` member

The file MUST contain a top-level member `tap` that is valid under this JSON Schema:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "tap-agent-passport/registration-tap/1",
  "type": "object",
  "required": ["v", "chainId", "processor", "tokenId", "container", "listing"],
  "properties": {
    "v":         { "const": 1 },
    "chainId":   { "type": "integer", "minimum": 1, "maximum": 9007199254740991 },
    "processor": { "type": "string", "pattern": "^0x[0-9a-fA-F]{40}$" },
    "tokenId":   { "type": "string", "pattern": "^[1-9][0-9]{0,18}$" },
    "container": { "type": "string", "pattern": "^0x[0-9a-fA-F]{40}$" },
    "manifest":  {
      "type": "object",
      "required": ["path", "sha256"],
      "properties": {
        "path":   { "const": "/.well-known/tapeapi.json" },
        "sha256": { "type": "string", "pattern": "^0x[0-9a-f]{64}$" }
      }
    },
    "listing":   {
      "type": "object",
      "required": ["issued", "sig"],
      "properties": {
        "issued": { "type": "integer", "minimum": 0, "maximum": 9007199254740991 },
        "sig":    { "type": "string", "pattern": "^0x([0-9a-f]{2})+$", "maxLength": 8194 }
      }
    }
  }
}
```

1. `tokenId` MUST NOT exceed 10^18 (TAP-10 §3.1; the pattern cannot express this bound).
2. **R-1.** `chainId`, `processor`, `tokenId` and `container` MUST equal the values read from the chain under §3. Where they differ, the chain prevails, and the result is `file-chain-mismatch`.
3. **R-4.** `manifest`, when present, gives the SHA-256 of the TAP-11 manifest when the file was written. A tool uses it only to notice that the two files were not written together (warning `manifest-hash-differs`), never in place of the site store's own hash. The `tap` member does not copy any digest of the manifest's members (such as TAP-15's `toolsSha256`); the manifest is the only source of them.
4. `listing` is the listing of §5.5. `sig` is lowercase hex of at most 4,096 bytes. A file without `listing`, or whose `listing` does not match the schema, is `registration-file-invalid`; a `listing` that matches the schema but is not accepted under §5.5 is `listing-not-by-holder`.

#### 5.4 Forbidden member names

A member name anywhere inside `tap` is forbidden when, after normalisation, it contains one of the words `price`, `worth`, `yield`, `interest`, `dividend`, `revenue`, `profit`, `income`, `share`, `allocation`, `allotment`, `airdrop`, `reward`, `payout`, `payment`, `weight`, `multiplier`, `bonus`, `boost`, `score`, `rating`, `eligibility`, `entitlement`, `claimable`, `vesting`, `staking`, `verified`, `certified`, `official`, `空投`, `奖励`, `分配`, `收益`, `资格`, `分红` or `认证`, or when it or one of its segments is exactly `point`, `points`, `rank`, `tier`, `stake`, `apy`, `apr`, `bounty` or `value`. Normalisation, in order: Unicode NFKC; removal of control characters, combining marks and every code point with the property `Default_Ignorable_Code_Point` in Unicode 15.1.0 (which includes `Bidi_Control`); mapping of each of the 31 Cyrillic and Greek letters of the confusable table, and of its capital, to the Latin letter given there; splitting into segments at every character that is not a letter or digit and at camel-case boundaries; case folding; joining the segments. A file with a forbidden name inside `tap` MUST be rejected (`forbidden-name`). This is the rule of the soulbound credentials draft (#76) applied to this member. Names outside `tap` belong to ERC-8004 and are not checked. Text values are a matter of tool judgement.

The **confusable table** is the member `constants.confusables` of the vectors (Test Cases, at the SHA-256 given there), also printed in the assets README; the reference verifier applies exactly it. It was chosen with reference to the UTS #39 confusable data of Unicode 15.1.0 (`confusables.txt`) and is a documented subset of it, not that data in full; where that data maps a letter to something other than a Latin letter, the table gives the Latin letter. This table, and no other, decides `forbidden-name`, so that every verifier reaches the same state. A tool MUST NOT report `forbidden-name` because of a mapping outside the table and MUST NOT claim that the check detects every look-alike; it MAY warn about others as a matter of judgement.

#### 5.5 The listing signature

The listing makes the holder's statement of P-10 a signature by the holder (P-8), so that no rule depends on who can write the container's site.

1. **Domain.** The EIP-712 domain of TAP-11 §4.1 with `chainId` 56: `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)` with `name` `"TapeAPI"`, `version` `"1"`, `chainId` 56 and `verifyingContract` the DeWEB hub `0xe61A9C7213a6Aa616C246a2B569e555B417b25ee`. Its separator on chain 56 is `0xa73ee348b5672f12dbc174f66a7d162c69e0d64befdba88475d9d7e3c0fd3ac7` (TAP-11 Test Cases). The hub is not called.
2. **Type.**

```
PassportListing(uint256 agentId,address registry,address container,uint64 issued)
LISTING_TYPEHASH = keccak256("PassportListing(uint256 agentId,address registry,address container,uint64 issued)")
                 = 0x957f9fc36c0b4ad63b2acb914eb16de50ad4623d8a0ff778528d3cc2a6a42ecb
structHash       = keccak256(abi.encode(LISTING_TYPEHASH, agentId, registry, container, uint64 issued))
digest           = keccak256(0x19 ‖ 0x01 ‖ DOMAIN_SEPARATOR ‖ structHash)
```

3. **Where the values come from.** `agentId` is the identity being resolved; `registry` is the identity registry proxy of §2 item 2; `container` is `opener.accountOf(processor, tokenId)` read under P-4. A tool MUST take these three from the chain and the input, never from the file, so that a listing signed for another identity, registry or container does not verify. Only `issued` and `sig` come from the file.
4. **`issued`** is the time in Unix seconds at which the holder signed, a JSON integer (the struct type is `uint64`; canonical JSON bounds the value by 2^53 − 1). It does not expire the listing and takes part in no check other than the digest; a tool MAY show it.
5. **Acceptance.** The listing is accepted when `sig` is valid for `digest` under TAP-11 §4.4, with the holder of that section replaced by `ownerOf(agentId)` read at the pinned block (equal to the holder under P-1): a 65-byte `sig` is tried as ECDSA first, with the range checks of TAP-11 §4.4 item 1, and one that fails them is rejected without trying EIP-1271; when `sig` is not 65 bytes, or ECDSA recovers to another address, the signature is accepted only when the owner has code at the pinned block (`eth_getCode`) and `isValidSignature(digest, sig)` called on it at the pinned block returns the magic value of TAP-11 §4.4 item 2. Unlike TAP-11 §4.4, a tool MUST NOT decline the EIP-1271 branch, since tools that did would report different states for one passport. The `eth_getCode` and `isValidSignature` reads take the signature from the file but are adopted under §6.1 like every other read: a disagreement is UNAVAILABLE, never BROKEN.
6. **Signing.** The holder signs `digest` with `eth_signTypedData_v4` or an equivalent, without the EIP-191 prefix (TAP-11 §4.2). Wallets show the DeWEB hub as the verifying contract; nothing is authorised on it (TAP-11 Security Considerations). A holder that changes the identity, the circuit or the container signs a new listing.
7. **What a writer of the site can and cannot do.** Anyone who can write the container's site, the holder or any site operator, including one that an earlier holder set and the current holder never cleared, can delete the registration file, corrupt it or list further identities: the result is then BROKEN or AMBIGUOUS. Without the holder's key such a writer cannot make a listing that is accepted for another identity, another container or another owner, so it cannot turn any identity into a CONFIRMED passport. It can put back a listing that the current holder signed earlier for the same container and identity registry (Security Considerations). The listing signs only the four values of item 2: the other members and texts of the registration file and the other files of the site are not signed by it (D-7).
8. **Example** (informative; `listingSignatures` of the vectors). `agentId` 1001, `registry` `0x8004a169fb4a3325136eb29fa0ceb6d2e539a432`, `container` `0x2737ba45df033da7be7d329e13e0898ebeb1c97c`, `issued` 1799999000 give `structHash` `0x46ea821c759f56ce656fd7535ff92fd312b236d2107a3340adfca8d196678cc6` and `digest` `0xae338f65c18b15912fffd3e4a79d86158bf69795c7e77ab96319c1fa7dd1af49`; the published test key `0x` followed by 64 digits `1` (address `0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A`, the test holder of TAP-11) signs it as `0xae868cc2a715fddd17cd0bef931c9e31b868db8845a4ebffda2dbf1d3ea1c5570ba0fdca9450f6c00e758736db6cb2abe1d4ccaa40a95163440e76fb08a7fbc91c`.

### 6. Resolution

#### 6.1 Reads

1. All reads of one resolution MUST be made at one pinned block chosen as in TAP-10 §5.3, and a pinned block whose lag exceeds 400 blocks MUST be rejected (`stale-block`).
2. Every read MUST be adopted under strict agreement (TAP-10 §5.2): sent to every configured node, adopted only when every answer agrees and the answers come from at least max(2, min(3, number of configured operators)) operators. Any disagreement is `node-disagreement`; too few answers is `unavailable`. A tool configured with one operator cannot report CONFIRMED.
3. `eth_chainId` MUST be 56 under the same rule; otherwise `wrong-chain`.
4. Log queries (§6.4, §7, §10) are reads like any other. A tool that cannot obtain them reports so (§6.4); it MUST NOT treat an unobtainable history as an empty one. No state word and no reason depends on a log query: every check of P-1 to P-11 reads state at the pinned block.
5. A failure of this section makes the result UNAVAILABLE. A tool MUST NOT report BROKEN because of a node, a timeout or a disagreement.

#### 6.2 Algorithm

The input is either an identity (`agentId`) or a circuit (processor contract and #ID). The tool applies these steps in order; the first that fails gives the result.

1. **Fixed reads.** `eth_chainId`; the pinned block and its hash; the implementation slots of §2 item 2 and of the site store (TAP-10 §6.1). Failures: `wrong-chain`, `stale-block`, `registry-changed`, `store-changed` (UNAVAILABLE).
2. **Circuit input only (R-2).** Resolve the circuit under P-4 and P-5, read the registration file under step 5 and P-10: no identity of this registry listed is `not-listed`; more than one is AMBIGUOUS (`several-listed`); otherwise continue from step 3 with the identity it lists. This file is used only to find the identity; P-7, P-10 and P-8 are checked, in steps 5 to 7, on the container that the key names.
3. **Identity, chain first.** `ownerOf(agentId)` (P-1); `getMetadata(agentId, "tap.passport")` (P-2, §4); the key's chain (P-3); for a circuit input, the key's processor and #ID against the input circuit (P-11); `isCPU`, `processor.ownerOf(tokenId)`, `accountOf`, `isOpened` (P-4, P-5); the processor number by `cpuAt` (TAP-10 §4.3 step 3), which gives the on-chain name; then P-1. Then `getAgentWallet(agentId)` and `tokenURI(agentId)`.
4. Only now does the tool read any file. No value from a file can change a value read in steps 1 to 3.
5. **Registration file.** `fileInfo` and `read` from the site store at the container (TAP-10 §7.1): missing is `registration-file-missing`, a declared size above 65,536 bytes is `registration-file-too-large` (not read), no declared hash is `registration-file-no-hash`, a size or SHA-256 mismatch is `registration-file-incomplete`; then §5.2 and §5.3 (`registration-file-invalid`, `forbidden-name`), R-1 (`file-chain-mismatch`), §5.2 item 4 (`tape-service-missing`).
6. **Listing (P-10).** The identity is not listed: `not-listed`. More than one identity of this registry is listed: AMBIGUOUS.
7. **Listing signature (P-8).** Verify `tap.listing` under §5.5 for `agentId`, the identity registry, the container and the identity owner of step 3, reading `eth_getCode` of the owner and `isValidSignature` when §5.5 item 5 needs them: not accepted is `listing-not-by-holder`.
8. **Warnings.** R-3, R-4; for a tool with the history tier, the holder epoch of §7 and, when it makes it, the site-operator check of §6.4; for a log-less tool, `transfer-history-unavailable`.
9. **Agent wallet (P-9).** `getAgentWallet` is zero: `wallet-unset`. It is another address: `stale-agent-wallet`. Otherwise CONFIRMED.

#### 6.3 State words and reasons

A tool MUST report exactly one state word, its reason and every warning:

| State | Meaning | Reasons |
|---|---|---|
| CONFIRMED | P-1 to P-11 hold | — |
| BROKEN | A binding fact is false; the identity is not a passport | `no-such-agent`, `holder-mismatch` (P-1); `no-passport-key`, `bad-passport-key` (P-2); `chain-mismatch` (P-3); `not-tapeout`, `no-such-token` (P-4); `not-opened` (P-5); `registration-file-missing`, `registration-file-too-large`, `registration-file-incomplete`, `registration-file-no-hash`, `registration-file-invalid`, `forbidden-name`, `file-chain-mismatch`, `tape-service-missing` (P-7); `listing-not-by-holder` (P-8); `not-listed` (P-10); `key-circuit-mismatch` (P-11) |
| AMBIGUOUS | The holder's file lists more than one identity of this registry | `several-listed` (P-10) |
| `wallet-unset` | Everything holds except that `agentWallet` is zero, as after a transfer of the identity | `wallet-unset` (P-9) |
| `stale-agent-wallet` | Everything holds except that `agentWallet` is a non-zero address other than the holder | `stale-agent-wallet` (P-9) |
| UNAVAILABLE | The reads could not be adopted; nothing is known | `wrong-chain`, `stale-block`, `node-disagreement`, `unavailable`, `registry-changed`, `store-changed` (P-6) |

Warnings, which do not change the state: `operators-not-checked`, `stale-operator` (both only from the optional check of §6.4), `agent-uri-not-canonical`, `manifest-hash-differs`, `holder-changed`, `transfer-history-unavailable`. Reason and warning names are only ever added. One exception was made before this TAP left Draft: `stale-operator` was a reason of P-8 in the text of 2026-10-24 and is a warning since 2026-10-28, when P-8 became the listing signature.

Between the registration transaction and the transaction that writes the registration file, a holder's own identity resolves as BROKEN (`registration-file-missing` or `not-listed`); onboarding tools SHOULD write the file immediately after registering (Appendix A). After both tokens change hands, the passport resolves as BROKEN (`listing-not-by-holder`) until the new holder signs a listing and rewrites the file, and then as `wallet-unset` until it sets the agent wallet (S-3).

#### 6.4 History tier (requires an indexer or an archive node)

1. Three parts of this TAP need log queries over the whole history of a token or a container: the holder epoch of §7 (the `Transfer` events of both tokens), the summaries of §10 (the reputation registry's feedback events) and the optional site-operator check of item 4. They form the **history tier**. At the time of writing, no keyless public node of BNB Smart Chain that was measured serves these queries from the first block: nodes limit the block range of one query (to 50 blocks on one of them) or its number of results, refuse old ranges without an access token, rate-limit, or do not serve `eth_getLogs` at all (assets README; TAP-10 §11 notes that most public nodes do not serve it). In practice the tier needs an indexer or an archive node that serves logs, and strict agreement (§6.1) needs at least two operators of them.
2. A log-less tool, or a tool whose history queries fail, reports the same state word and reasons as a tool with the history tier. It reports the holder epoch as unknown with the warning `transfer-history-unavailable` and shows "holder history not checked" (D-1); it computes no §10 summary and says so (F-7); it does not make the check of item 4 and adds no warning for it.
3. A tool MUST NOT present a history as complete unless it obtained it in full, from the token's mint (for item 4, from the site store's deployment) to the pinned block.
4. **Site operators (optional, informative).** A tool with the history tier MAY read the `OperatorSet(address indexed container, address operator, address setBy, uint40 until)` events of the site store for the container. For each operator it takes the latest record; if `operator` is not zero, `until` is not earlier than the pinned block's timestamp and `setBy` is not the holder, it adds the warning `stale-operator`. A tool that attempts the check and cannot obtain the events adds `operators-not-checked`. Neither warning changes the state: the listing (P-8) does not depend on who can write the site. They concern the parts of the site the listing does not sign (§5.5 item 7). A holder clears a stale operator with `setOperator(container, operator, 0)`.
5. **Bisection** (informative). Where a node serves state at past blocks (`eth_call` with an old block number) but not logs, a tool can find a block at which `ownerOf` of a token became the current holder by bisection, about 27 calls over the present height of BNB Smart Chain. The result is not a holder epoch under E-1: ownership need not change monotonically, and for a token that went from A to B and back to A, bisection can return A's first acquisition and so attribute B's period to A. A tool that uses it MAY show the block as an estimate, and MUST still treat the epoch as unknown for E-2 and F-7.

### 7. Holder epochs

The holder epoch is part of the history tier (§6.4): a log-less tool cannot compute it and reports it as unknown.

- **E-1.** The **holder epoch** of a passport starts at the later of the block of the last `Transfer` of the identity and the block of the last `Transfer` of the circuit (a mint counts as a transfer from the zero address). It has **changed** when either last transfer came from a non-zero address. The block of the identity's first `Transfer` (its registration) is also reported. A tool that cannot obtain both histories, or the identity's history from its registration, or whose last transfers do not end at the current holder, MUST add `transfer-history-unavailable` and MUST treat the epoch as unknown.
- **E-2.** A tool MUST NOT attribute to the current holder any review, feedback, task record or other reputation dated before the start of its holder epoch, and MUST NOT present a new holder as the successor of an earlier one. When the epoch has changed, a tool MUST show "holder changed at block <n>: earlier reputation does not belong to the current holder" (D-1). That sentence states when the current holder acquired the tokens; it does not state who held either container when a review was signed, which #54 §10, at the cited commit, tells a client not to state.

### 8. Signers, agent wallet and keys

- **S-1.** `agentWallet` is not a source of authority. A tool MUST NOT use `getAgentWallet(agentId)` as a signer, a holder or a payment address of the service; it uses it only for P-9.
- **S-2.** A signer speaks for the service only through TAP-11 §4.5. Addresses in the registration file, an agent card, an MCP handshake or any other document are display only, and a tool MUST NOT accept a signer from them.
- **S-3.** A holder whose identity is in `wallet-unset` restores P-9 only by signing `AgentWalletSet` itself and submitting `setAgentWallet(agentId, holder, deadline, signature)` (§2 item 5) within the registry's deadline. A tool that prepares this MUST read the block time immediately before asking for the signature, MUST set `deadline` no more than 240 seconds after it, and MUST prepare a new signature when the window passes. When a wallet returns a signature as `r ‖ s` and a recovery identifier, a tool MUST assemble the 65-byte form and MUST check that it recovers to the holder before submitting it.
- **S-4.** A tool MUST treat a change of the identity registry's implementation as `registry-changed` (§2 item 2) until it is updated with a new accepted implementation.
- A holder that can produce EIP-712 signatures but cannot produce EIP-191 `personal_sign` signatures, such as a custodial wallet that exposes typed-data signing only, cannot derive a TapeSend messaging key under TAP-10 §14.2. Its passport can receive public messages (TAP-10 §15.2) and can use private channels whose key record is an EIP-712 signature (TAP-14, key type `"tape-channel/v1"`). A tool MUST NOT report the absence of a sealed inbox for such a holder as a failure of the passport. Such a holder can make every signature a passport needs: the listing (§5.5), the TAP-11 delegation and `AgentWalletSet` (S-3) are all EIP-712 typed data.

### 9. Tools that request signatures or build calls

- **W-1 (delegation expiry).** A tool that asks a holder to sign a TAP-11 delegation MUST NOT propose by default an `expires` later than 30 days after the time of signing, SHOULD propose 7 days or less by default, and MUST let the holder choose any `expires` up to the limit of TAP-11 §4.3. The holder sets the upper limit; a tool MUST NOT propose the longest delegation TAP-11 allows (366 days) as its default.
- **W-2 (signer origin).** A tool MUST NOT ask a holder to sign a delegation whose `signer`, a mandate whose `agentKey` (TAP-18), or a channel key record (TAP-14) whose keys were not generated by that tool in the same session.
- **W-3 (runtimes driven by untrusted text).** A runtime driven by untrusted text that can request transactions from a holder's wallet:
  1. MUST NOT construct `approve(address,uint256)` (`0x095ea7b3`), `setApprovalForAll(address,bool)` (`0xa22cb465`), `transfer(address,uint256)` (`0xa9059cbb`), `transferFrom(address,address,uint256)` (`0x23b872dd`), `safeTransferFrom(address,address,uint256)` (`0x42842e0e`) or `safeTransferFrom(address,address,uint256,bytes)` (`0xb88d4fde`) on any contract, and MUST NOT construct any call that transfers the circuit or the identity;
  2. MUST NOT construct a container `execute(address,uint256,bytes,uint8)` (`0x51945447`);
  3. MUST address calls only to the identity and reputation registries of §2 and the contracts of TAP-10 Deployments for the chain, including processor contracts for which `factory.isCPU` is true;
  4. MUST NOT build calldata, addresses or amounts from text received from a counterparty; deterministic code builds them from the holder's own choices and from chain reads.
- **W-4 (writing feedback).** A tool that writes a review as feedback MUST use the arguments of §10.2.
- **W-5 (listing requests).** A tool that asks a holder to sign a listing MUST take `agentId` from the `register` transaction's receipt or from reads of the chain, `registry` from §2 and `container` from `opener.accountOf` under P-4, never from a file or from text received from a counterparty; MUST set `issued` from its own clock; MUST check, before it writes the registration file, that the returned signature is accepted under §5.5 for the holder, assembling a 65-byte form from `r ‖ s` and a recovery identifier as S-3 says; and, when it is a runtime driven by untrusted text, MUST NOT ask for a listing of an identity that the holder did not register or choose itself.

### 10. Reviews as ERC-8004 feedback (optional, conditional)

This section applies only to tools that implement #54 at commit `703b2a91edf7545b3179a08b8041b49190fd4a0a`, and is part of the history tier (§6.4): feedback is read from the reputation registry's events, and counting needs the holder epoch. A log-less tool computes no summary. Its record, review hash, levels, verification and summary rules are used as they stand at that commit, and "§n of #54" refers to it. This section defines a summary of ERC-8004 feedback, not the review summary of #54 §9, which is unchanged; a tool that shows both MUST label them as different summaries. E-2 explains why its holder-epoch sentence does not state what #54 §10 forbids; if #54 §10 changes before #54 is merged, E-2 and this section are revised.

#### 10.1 One immutable file per review

1. A reviewer that writes a #54 record as feedback MUST first store a file in its own container's site under the key `.well-known/tapeapi-reviews/<review hash>.json`, where `<review hash>` is the record's review hash (#54 §2.1) as `0x` and 64 lowercase hex digits, holding exactly `canonicalJSON(record)` and nothing else. The collection file `.well-known/tapeapi-reviews.json` of #54 §8.1 stays as #54 defines it.
2. The site store lets a holder replace a file. A replaced review file no longer matches its feedback hash, and the feedback stops counting (F-3); a reviewer that wants to change a review writes a new record (#54 §7) and a new file.

#### 10.2 Writing

The reviewer's holder (the holder of the reviewer's circuit at that block) calls

```
giveFeedback(agentId, value = score, valueDecimals = 0, tag1 = "tap-review", tag2 = "level-1" | "level-2",
             endpoint = "", feedbackURI, feedbackHash)
feedbackURI  = "https://" ‖ <gateway host label of the reviewer's circuit> ‖ "." ‖ <gateway domain> ‖ "/" ‖ <file key of 10.1>
feedbackHash = keccak256(exact bytes of that file)
```

1. `tag2` MUST be the level at which the record verifies under #54 §4; a record of level 0 MUST NOT be written under `tag1` `"tap-review"`.
2. A withdrawal (#54 §7, `kind` 2) is written as `revokeFeedback` of the earlier feedback by the same holder.
3. `feedbackURI` MAY instead be `tape://<reviewer's on-chain name>/<file key>`. The gateway domain is not checked; the host label alone names the reviewer's circuit (F-3).

#### 10.3 Counting

A tool that shows a summary of the feedback of a passport:

- **F-0 (named clients and spam).** Anyone can write feedback for any identity at the cost of a transaction, and each entry costs a tool several reads to check. A tool MUST compute a summary over an explicit set of client addresses, chosen by the viewer or the tool and shown with the summary, as ERC-8004 `getSummary` itself requires; MUST NOT fetch files or resolve circuits for feedback whose submitter is outside the set, only count it; and MUST NOT build the set from the feedback list alone. A tool MAY bound the number of entries it examines per summary or per client address; when it stops early it MUST report `summary-truncated` and MUST NOT show partial numbers as the summary. A tool that computes no summary MUST say why: `no-client-set`, `epoch-unknown` (F-7), `history-unavailable` (the feedback events could not be obtained), `registry-changed`, `summary-truncated`, or that the passport is not CONFIRMED (F-4).
- **F-1.** MUST consider only feedback with `tag1` `"tap-review"`.
- **F-2.** MUST exclude feedback whose `tag2` is not `"level-1"` or `"level-2"`.
- **F-3.** MUST resolve the reviewer's circuit from the host of `feedbackURI` (TAP-10 §3.3 or §3.2), read the file of §10.1 from that container's site store (TAP-10 §7.1, size and SHA-256), and exclude the feedback unless `keccak256` of the bytes equals `feedbackHash`, the bytes equal the canonical JSON of the parsed record, the file name equals the record's review hash, and the record's `reviewer` is the endpoint ID of that container.
- **F-4.** MUST compute a summary only for a passport that is CONFIRMED at the summary's pinned block, and MUST exclude a record whose `reviewee` is not the endpoint ID of the passport's container.
- **F-5.** MUST verify the record under #54 §6 and exclude it unless #54 counts it, and unless its level equals `tag2`.
- **F-6.** MUST exclude feedback whose submitter (`clientAddress`) is not the current holder of the reviewer's circuit.
- **F-7.** MUST exclude feedback given before the start of the passport's holder epoch (E-2) and MUST show the number of such entries under "earlier holders", never drop them silently. When the epoch is unknown (E-1, §6.4), nothing can be attributed to the current holder: the tool MUST NOT compute or show a summary, and MUST NOT show zero counts, an empty summary or "no reviews" in its place; it reports `epoch-unknown`. When the feedback events cannot be obtained it reports `history-unavailable` in the same way.
- **F-8.** MUST exclude revoked feedback and records of `kind` 2.
- **F-9.** MUST count at most one feedback per reviewer container: the one whose record has the highest `issued`, and of two with equal `issued` the greater review hash (#54 §9 item 2).
- **F-10.** MUST exclude feedback whose `value` is not the record's score or whose `valueDecimals` is not 0; MUST show level 1 and level 2 separately with the number of distinct reviewer containers, the number of distinct holders and the number of records with each score; MUST NOT show a weighted or averaged score in place of these numbers; and, when it calls `getSummary`, MUST pass as `clientAddresses` the submitters of the feedback it counted, which are a subset of the set of F-0, and MUST NOT call it with an empty list.

### 11. Authorisation layers (optional, conditional)

This section applies to tools that show the authority of an agent: mandates under TAP-18, escrow sessions under #60 at commit `42ce7aef2d16ef64c3d8ba94e255076c3db16a25`, or limits of a holder's wallet provider.

**A-1.** A tool MUST NOT present a limit enforced by a holder's wallet provider (a daily amount, a token scope, a confirmation rule) as a bound that a counterparty can rely on, and MUST NOT compare such a limit with an escrow cap. No on-chain, wallet-native limit exists on a holder's wallet: limits are enforced only by the parties that check them, such as an escrow channel that #60 reads on chain or a published rule that a counterparty re-runs. Until an escrow instance is audited and deployed, every mandate is `enforcement: none`.

| Layer | What it is | Who can see or check it | Enforced by |
|---|---|---|---|
| Wallet-provider policy (custodial wallets) | Daily limits in the provider's currency, token scope, confirmation rules, session sign-out | The user and the provider only | The provider, unilaterally; changeable at any time |
| TAP-18 mandate (phase 0) | The holder's EIP-712 `Mandate` naming an agent container, an agent key, a task and an expiry of at most 30 days | Any counterparty, off chain | Nothing (`enforcement: none`) |
| #60 escrow session (phase 1) | One channel per capped provider; the agent key is a session key until the mandate's expiry | Anyone, by reading the escrow at a pinned block | The escrow contract (not audited, not deployed) |

The three layers do not know about one another, and none of them can be verified from another. When a holder's wallet is frozen or lost, its limits stop the holder but not keys the holder authorised earlier: a TAP-11 signer stays valid until its delegation expires (TAP-11 §7.2), an agent key until its mandate or session expires, and no revocation can be signed. W-1 keeps that window short.

### 12. Display rules

A tool that shows a passport:

- **D-1.** For CONFIRMED MUST show the on-chain name, the container address, the `agentId` and the pinned block, and MUST add "holder history not checked" when the holder epoch is unknown, otherwise the block at which the identity was registered (E-1), and the sentence of E-2 when the epoch has changed. It SHOULD add "a site operator not set by the holder is active" when it reported `stale-operator`, and MAY add "site operators not checked" when it reported `operators-not-checked` (§6.4).
- **D-2.** For BROKEN MUST show that the identity is not a passport and the reason, and MUST NOT show the identity's ERC-8004 feedback as the reputation of the circuit's service.
- **D-3.** For AMBIGUOUS MUST show every listed identity and MUST NOT pick one.
- **D-4.** For `wallet-unset` MUST say that the identity changed hands and is not confirmed until the holder sets the agent wallet again, and MUST NOT show it as a failure of the service.
- **D-5.** For `stale-agent-wallet` MUST say that the agent wallet differs from the holder and MUST NOT show that address as a payment address.
- **D-6.** For UNAVAILABLE MUST say that nothing could be verified and MUST NOT show any earlier state as current.
- **D-7.** MUST NOT show, for any state, the words "verified agent", "certified", "official" or "trusted", a check mark or a badge; MUST NOT present a passport as proof that the agent runs any particular code, is honest or is safe; MUST mark the identity's `name`, `description` and `image` and every text of the registration file as statements published by the holder's site, which the listing does not sign (§5.5 item 7), and render them as plain text, removing the code points TAP-10 §16 lists; and, when the manifest carries `mcp` as defined in TAP-15, MUST apply TAP-15's digest check and MUST NOT let a tool list from the registration file or an agent card replace it.

## Rationale

- **Same holder, not the container as owner or as agent wallet.** A container-owned identity would follow the circuit, but every registry write would need a container `execute`, and a sale would leave the previous holder as `agentWallet`. A container as `agentWallet` depends on an unverified ERC-1271 path (the container at `0x86DDaEF00401E3F10418398D67D7189fc458eA95` answers `supportsInterface(0x1626ba7e)` with false at block 129353469). Under the same-holder rule a sale of either token makes the binding fail visibly at the next read.
- **Why P-8 to P-11.** The fork measurement shows that P-1 and P-2 can be satisfied by a stranger. P-10 asks for a statement in the holder's site, P-8 makes it a signature only the holder can give; P-9 asks for a signature path only the identity's owner can complete after a transfer. Neither costs a holder who registers its own identity anything. A circuit, like an identity, can be given without consent, so a file found by circuit only names an identity; P-11 then requires the key to point back at that circuit.
- **One registry entry in the file.** Scanning `MetadataSet` logs for uniqueness depends on log windows public nodes do not serve and can be triggered by gifts; the holder's own file cannot.
- **A signed listing, not an operator scan.** The text of 2026-10-24 excluded site operators left by earlier holders by scanning `OperatorSet` events (P-8). That needs the same full-history log queries that the previous item rejects for `MetadataSet`; measured on 2026-10-28, none of the keyless BNB Smart Chain endpoints tried served them (assets README), so in practice every tool could only warn `operators-not-checked` and P-8 was not checked at all. A signature by `ownerOf(agentId)` shows the holder's intent from reads at one block: a writer of the site can still break a passport but cannot forge one. The listing uses the TAP-11 domain, which wallets of TapeOut holders already show for the delegation, and names the identity registry and the container, so that it cannot be carried to another registry, identity or circuit; the domain carries the chain. Signing the whole file instead would also cover its texts, but every edit of the file would need a new signature; that is left as an open question.
- **History as a separate tier.** Holder epochs and reputation counts cannot be had from state at one block, and their sources are not served by keyless nodes. Keeping them out of every state word gives every tool the same state, and requiring a log-less tool to say what it did not check, rather than showing empty counts, keeps the gap visible (F-7).
- **Chain before files, one pinned block, strict agreement.** These are TAP-10's rules; reading files last means a file can only add problems, never remove one.
- **Why a key at all.** Without `tap.passport` an indexer that reads only ERC-8004 cannot find the circuit and would have to trust the URI; the key costs nothing at registration.
- **No new contract or token; one signed type.** Every fact is a read of contracts that exist, plus one holder signature kept in the holder's own site; a passport registry would be a second source of truth that needs an owner, an audit and a deployment. An onboarding helper contract was left out: it would be new, unverified code in the transaction where a holder is most exposed.
- **A fixed confusable table.** A larger table in one verifier and a smaller one in another would give the same file two states; a fixed table makes the result reproducible, at the cost of missing look-alikes outside it.
- **Feedback files and named clients.** ERC-8004 defines `feedbackHash` as the hash of the content `feedbackURI` points to. #54's collection file changes with every review, so one file per review keeps the ERC-8004 meaning and is keyed by the #54 review hash. Feedback is open to anyone, so a summary over every submitter could be flooded at the cost of gas; naming the client set (F-0) follows ERC-8004's own `getSummary`.
- **Tags.** `level-1` and `level-2` match #54's levels; automatic success rates were rejected because a provider could commission jobs from its own accounts.
- **Optional sections.** Reviews and authorisation layers depend on unmerged drafts and are conditional, so the core binding can be reviewed alone. A separate draft, *Policy Circuit Gate*, defines rules that a counterparty re-runs; A-1 does not deny such rules, only that the wallet itself enforces a limit on chain.
- **#49 and #77.** #49's `agent` member can be shown next to a passport; #77 lets a wallet without a circuit call a passport's service for a limited time.
- **Appendices after Copyright.** TAP-01 §7.2 lists the sections up to Copyright and says nothing about appendices; TAP-10 places its Appendices A to C after Copyright, and this TAP follows it.

## Backwards Compatibility

Nothing in TAP-10, TAP-11 or TAP-13 changes. ERC-8004 readers that ignore unknown members ignore `tap`; the `tape` entry of `services` is an ordinary service entry. ERC-8004 is a Draft and its deployment can be upgraded by its owner; this TAP pins the implementation it was checked against, and a new implementation needs a revision of §2 after the vectors are re-run against it. TapeSend sealed messaging is unchanged; holders who cannot sign `personal_sign` use public messages and channels (§8).

## Test Cases

`assets/tap-draft-agent-passport/vectors.json` (format `tap-agent-passport-vectors/1`) is generated by `make_vectors.py` in the same folder and is reproducible byte for byte; its SHA-256 is `a03e690d7ec7e0d96435d0bd71768829e114b324d792bbc2150c527f2c856066`. It holds 175 cases, each with its expected result and the rules it covers:

- `resolution` (97): snapshots of chain reads and site files at one pinned block with the expected state, reason, warnings and display text, covering every reason and warning of §6.3, gift identities and gift circuits, the listing signature (accepted from an EOA and through EIP-1271; signed by a former holder or for another identity, registry, container or chain; altered `issued`; short, high-`s` and bad-`v` signatures; a wrong or short EIP-1271 answer, a revert and a node disagreement; a site operator that rewrote the file), holder epochs, the optional operator check with the boundary `until` equal to the block time, node failures, and two **real reads** of BNB Smart Chain at block 129353737 (two operators agreeing): ERC-8004 agent #1 is not a passport (`no-passport-key`), and circuit #4246@0 has no registration file;
- `feedback` (22): §10 summaries with counted, excluded and unfetched feedback, the `clientAddresses` for `getSummary`, and the cases without a summary, including an unknown holder epoch and unobtainable feedback events;
- `listingSignatures` (3, §5.5): the worked example of §5.5 item 8 and two rejections;
- `passportKey` (10), `forbiddenNames` (20), `canonicalJson` (4), `runtimeCalls` (12, W-3), `delegationProposals` (6, W-1 and W-2), `feedbackParams` (1, §10.2), the confusable table of §5.4, and `interfaces` (every selector and hash this TAP names, with whether it was found in the deployed bytecode, or `null` where it belongs to no deployed contract).

All other chain state is synthetic, at addresses derived from a hash that belong to nobody, except the addresses of the published test keys that sign listings (`constants.testKeys`; the holder's key is TAP-11's test holder key). These keys must never be used for anything else. Rules a machine cannot check from data (for example A-1) have no vectors. The test suite also checks that removing every log answer from a resolution snapshot changes no state word or reason (§6.1 item 4).

## Reference Implementation

In this repository, under `assets/tap-draft-agent-passport/`: `passport.py` (MIT, Python 3.9+, standard library only), the read-only verifier, which takes a snapshot of chain reads per operator at one pinned block and the site files, and returns the state word, reasons, warnings, holder epoch, display text and, on request, the §10 summary; it also implements every machine-checkable rule. `make_vectors.py` writes `vectors.json` (`--check` compares without writing); `test_passport.py` replays every case and checks that every machine-checkable rule has a vector; `secp256k1.py` (MIT, standard library only) recovers ECDSA signatures for P-8 and signs the vectors deterministically (RFC 6979) with the test keys; it is not constant-time and is not for real keys; `IERC8004PassportSubset.sol` is the interface of §2 item 4; `keccak.py` is copied unchanged from the Design Credits draft (origin and SHA-256 in the README). The folder will be held at a fixed commit before Review.

## Deployments

This TAP deploys nothing. It reads the contracts below on BNB Smart Chain (56). The implementation slots and code hashes were read on 2026-10-23 at block 129353469 from the public endpoints of two node operators (named in the assets README) with identical answers; the selectors were found in the implementation bytecode at blocks 129353333 and 129355254, in code whose hash the two operators agreed on. Anyone can repeat the check with `eth_getStorageAt` on the slot of §2 item 2, `eth_getCode` and `cast sig`.

| Contract | Proxy (the address a tool calls) | Implementation the proxy must point to | Code hash of the implementation | Upgradeable by |
|---|---|---|---|---|
| ERC-8004 identity registry | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` | `0x7274e874ca62410a93bd8bf61c69d8045e399c02` | `0xa5f9624ea85e45b3f4b8558581f03bfb3e6cefab278d7bf0500ec9bd065dc16f` | Its owner (UUPS); not sealed |
| ERC-8004 reputation registry | `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` | `0x16e0fa7f7c56b9a767e34b192b51f921be31da34` | `0x38602de97f1bd86f0a4729f7f3c0a78b1d27892e6eb581272cce5504a68fd00b` | Its owner (UUPS); not sealed |
| Site store `SiteRegistry` | `0xd006ffdd5Ae313B17729621A00999cD3C71CE5e6` (TAP-10 Deployments) | `0x1d279D138A4D803378a7d4557c056f1beD53c261`, the accepted site store implementation of TAP-10 Deployments (slot re-read at block 129353737) | — | TAP-10 (UUPS) |
| Other TapeOut contracts (factory, opener, processors) | TAP-10 Deployments | TAP-10 Deployments | — | TAP-10 |
| DeWEB hub | `0xe61A9C7213a6Aa616C246a2B569e555B417b25ee` | Not read: only the `verifyingContract` of the listing's EIP-712 domain (TAP-11 §4.1); never called | — | — |

The facts of §2 item 5 were read on chain or measured on a local fork of block 129352831 with throwaway keys (a deadline of 240 seconds accepted, 400 rejected); the assets README gives the source and block of each. The exact deadline boundary and the ERC-1271 branch of `setAgentWallet` were not measured.

## Security Considerations

The threats considered, T1 to T13, are tabulated with their outcome and rules in the assets README; the main ones follow.

- **Gift identities and gift circuits are real.** On the deployed registry a stranger can give any wallet an identity whose URI and metadata the stranger chose, repeatedly, and any circuit can be transferred without consent. P-8 to P-11 keep such tokens from being reported as a passport; tools that show tokens by owner without applying §6 will still show the stranger's text next to the victim's address.
- **Bought reputation and fresh identities.** Both tokens can be sold together; the rules make the change of holder visible and stop earlier reputation from being attributed to the buyer, but cannot stop the history being presented elsewhere. Conversely, a holder can register a new identity, point it at the same circuit and list it, and so start a clean ERC-8004 ledger at any time; #54 reviews stay with the container. D-1 shows the identity's registration block so that a young identity is visible, but nothing in this TAP prevents the switch.
- **Site operators.** Whether the site store clears site operators when a circuit changes hands has not been checked; this TAP assumes it does not. Since P-8 is a signature, the answer does not decide any state: an operator left by an earlier holder can delete or corrupt the registration file or list further identities (BROKEN or AMBIGUOUS), but cannot forge CONFIRMED. It can still rewrite everything the listing does not sign, such as the file's texts and the other files of the site (for the manifest, TAP-11 §5 content signatures are the remedy), and only a tool with the history tier sees it (`stale-operator`). A holder clears a stale operator with `setOperator(container, operator, 0)`.
- **Old listings.** A listing does not expire. Anyone who can write the site can put back an earlier registration file whose listing the current holder signed for the same container, for example one naming an identity the holder no longer uses; that identity then resolves CONFIRMED if its key, owner and agent wallet still fit, and the current one `not-listed`. A holder that stops using an identity SHOULD remove its key by writing an empty `tap.passport` value, which makes it `no-passport-key`, and SHOULD clear site operators it does not know.
- **Custodial holders.** A provider can freeze a holder, lose its access or change its policies. Keys the holder authorised before (a TAP-11 signer, an agent key, a channel key) stay valid until they expire, nothing can revoke them without the holder's signature, and the tokens cannot be moved. Short default delegations (W-1) are the only mitigation. Soulbound credentials (#76) bound to such an address can be rebound only by a recovery authority named in their specification, or re-issued; issuers addressing agents with custodial wallets should name one.
- **Session hijack of an agent runtime.** An attacker who controls the text a runtime reads, or its session with the wallet, can try to have the holder transfer a token, approve tokens or sign a delegation to the attacker's key. W-1 to W-3 limit this; a wallet provider's confirmation rules are a further layer this TAP cannot rely on.
- **Forbidden names.** The check is a filter; it misses other scripts, misspellings and text in values, and rejects some innocent names.
- **What a passport does not show.** Not that the agent runs any particular code, answers correctly or is honest; only who holds both tokens and that the holder published the link.
- **Privacy.** A passport publicly and permanently links a wallet, an identity, a container, its site, reviews and feedback.
- **Upgradeable dependencies.** The ERC-8004 registries are upgradeable by their owner. The container implementation is upgradeable through a beacon (`0xe88f14464efe088267bbb8c5a7e6012f9cb75013`) owned by a Safe with threshold 3 of 5 (read at block 129353469); this TAP does not read container code. Pinning implementations makes changes fail closed (UNAVAILABLE).
- **Risks of what was left out.** Without a helper contract, onboarding leaves a short window in which the holder's own identity resolves as BROKEN; without container-owned identities a buyer must register or adopt one; unsigned agent cards are display only; without a registry scan other tools may still show unlisted identities; without log scans, a site operator left by an earlier holder is visible only to tools with the history tier, and a log-less tool cannot show holder history or reputation counts.

### Open questions

1. Should §10 move into #54 and §11 into #60, leaving this TAP with the binding only?
2. Should a later version let the container own the identity (the identity follows the circuit), with a `stale-agent-wallet` rule for the previous holder's wallet?
3. Should passports on Base and X Layer be defined once the ERC-8004 deployments there are checked?
4. Should TAP-10 gain a messaging-key derivation from an EIP-712 signature, so that holders without `personal_sign` can receive sealed messages?
5. Does the site store keep site operators across a change of holder? Since 2026-10-28 no state depends on the answer (P-8 is a signature, §5.5); it still decides whether a seller's operators can rewrite the unsigned parts of a sold circuit's site (§6.4 item 4).
6. Should an onboarding helper contract with a published code hash be specified after it is tested on a fork?
7. Should the listing also sign a hash of the registration file without the listing, so that its texts are the holder's signed statements, at the cost of a new signature for every edit of the file?
8. Should tools detect a registration file put back with an older listing, for example by remembering the highest `issued` seen per container as TAP-11 §7 does for manifests?

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).

## Appendix A. Onboarding with a custodial agent wallet (informative)

This appendix uses the Binance Agentic Wallet as an example of a custodial wallet that an agent drives through a command-line tool, as read from its public skill files on 2026-10-23 (repository `binance/binance-skills-hub` at commit `f42217160b1278f18e4df3fbe5b7816f00ad4009`; skill directory `skills/binance-web3/binance-agentic-wallet` at commit `b402990be1748d02b7b79ab958f278b1709e5de7`; skill version 1.13.0, CLI `baw` 1.11.0 or later). TapeOut is not affiliated with Binance and nothing here is endorsed by it; the interface can change.

The provider holds the key; with the app's Developer Mode on, `baw contract-call` sends any contract call after a risk check and `baw sign-message --signType EIP712` signs typed data; there is no `personal_sign`. Limits are set only in the app.

An agent that offers a service needs **6 contract calls and 2 signatures** (mint, tape out, open, delegation signature with a 7-day default, manifest, `register` with the key, listing signature, registration file), then re-reads every file and resolves under §6; each step may need a confirmation in the app. Both signatures are EIP-712 typed data (`baw sign-message --signType EIP712`), so the lack of `personal_sign` does not matter. The listing comes after `register` because it signs the `agentId`. The wallet provider needs to do nothing. The step table, fees read at the time, open unknowns and the claims that must not be made are in the assets README.

## Appendix B. An A2A agent card generated from the passport (informative)

A passport may also publish an A2A agent card at `/.well-known/agent-card.json` of its site, generated from the manifest and the registration file under A2A 1.0 (specification at a2a-protocol.org and `specification/a2a.proto`, read 2026-10-24). Nothing in the card raises a passport's state, and a card is never a source of signers (S-2). An example card is in the assets README.

| Card member (A2A 1.0) | Source |
|---|---|
| `name` | The manifest's `name`, shown as the holder's statement |
| `description` | The registration file's `description` |
| `version` | The manifest's `tapeapi` and the first 8 hex digits of its SHA-256, for example `"0.1+3fa2c1d0"` |
| `supportedInterfaces[]` | One entry per endpoint of the manifest's `endpoints.live` that serves A2A: `{"url": <endpoint>, "protocolBinding": "JSONRPC", "protocolVersion": "1.0"}`; all three are required in each entry, and there is no top-level `url` |
| `capabilities` | Only members A2A defines, for example `{"streaming": false, "pushNotifications": false}` |
| `defaultInputModes`, `defaultOutputModes` | `["application/json"]` |
| `skills[]` | One per task of the manifest's `agent` member (#49): `id` and `name` the task's `kind`, `description` the task's description, `tags` (required by A2A) the `agent.capabilities` words, or `["tape"]` when there are none |
| `signatures[]` | Optional. A JWS over the RFC 8785 canonical form of the card without `signatures`; A2A requires the protected header members `alg` and `kid`, and recommends `typ` `"JOSE"`. A signature by the TAP-11 signer would use `alg` `"ES256K"` and a `kid` naming the container. This version of the passport does not define or require it |
