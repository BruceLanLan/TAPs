---
tap: 10
title: DeWEB Access and Messaging Layers
description: How clients open TapeOut on-chain websites through tape:// names and exchange encrypted messages between circuit containers, verifying everything they read against the chain.
author: TapeOut (@TapeOutProtocol)
discussions-to: https://github.com/TapeOutProtocol/TAPs/pull/2
status: Draft
type: Standards
version: 1.1
created: 2026-09-17
updated: 2026-09-28
license: CC0-1.0
---

# TAP-10: DeWEB Access and Messaging Layers

## Summary

TAP-10 defines how anyone can open a website stored on BNB Smart Chain, Base or X Layer by its on-chain name, and send encrypted messages to the container behind it, without trusting a domain, a gateway or a server.

## Abstract

A TapeOut circuit container is an ERC-6551 account bound to a circuit NFT. DeWEB gives every container two roles, and this TAP specifies both:

- **Access layer (tape://).** The container is the address of a website whose files are stored on chain. The TAP defines the on-chain names and URLs, the resolution from a name to a container and its files, the verification of every byte, and the isolation rules that shells (viewers, gateways, extensions, desktop apps) must follow so that on-chain sites cannot harm users or each other (§6–§11).
- **Messaging layer (TapeSend).** The container is an endpoint that sends and receives messages across chains through the DeWEB hub contract: keys derived from a wallet signature, the payload and content formats, message identity, reading and sending (§12–§20).

Both layers share one set of names, one chain table, one resolution procedure and one rule for reading the chain: several independent nodes must agree, all reads are pinned to one block, and a client never accepts an address that someone merely reports (§1–§5). There is no DNS, bridge, indexer or server in either path.

Status: **Draft**, version 1.1. The access layer replaces the tape:// specification v0.2 (TapeKit `SPEC.md`, 2026-09-13); the messaging layer replaces TAP-10 v1.0 (2026-09-18). Following TAP-01, this TAP becomes Candidate once reviewed, and Final once the contracts it depends on are sealed or no longer upgradeable on every active chain (Deployments). As of 2026-09-27 none of them is sealed. The contracts and clients were reviewed internally only; **no independent audit has been published**.

## Motivation

TapeOut already stores website files in full on chain, but reaching them used to require a domain name, a DNS record and a gateway, each of which can lie or disappear. Containers on different chains also had no way to reach each other privately. TAP-10 lets independent implementations agree, byte for byte, on what a name means, which files belong to it and which messages were sent to it, and lets every user check this against the chain without trusting the implementer. It also records the deployed addresses and the trust that remains until the contracts are sealed.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

Part I (§1–§5) applies to both layers. Part II (§6–§11) is the access layer and Part III (§12–§20) the messaging layer. §21 states what may change. Every address referred to by role ("the factory", "the site store", "the hub") is listed per chain under Deployments.

## Part I. Common

## 1. Terms and notation

| Term | Meaning |
|---|---|
| Processor | A CPU in TapeOut. On chain it is an independent circuit NFT contract (ERC-721), the **processor contract**, created by the chain's processor factory |
| Processor number | The index of a processor contract in its factory: `factory.cpuAt(number)`. Starts at 0, in creation order, append-only and never reused. Numbers are per chain |
| #ID | A circuit's token ID within its processor contract; every processor numbers from 1 |
| Circuit | A pair (processor contract, #ID) |
| Container | The ERC-6551 account bound to a circuit. Its address is derived from (chain, processor contract, #ID) with `opener.accountOf(processor contract, #ID)`. One container is one website and one messaging endpoint |
| Holder | The current `ownerOf(#ID)` of the circuit NFT |
| Opened | The circuit's container has been opened (its one-time opening fee is paid). The access layer reads `opener.isOpened(processor contract, #ID)`; the hub reads `payments.paid(container)` |
| Plain account | An address with no code, or whose code is exactly an EIP-7702 delegation designator (`0xef0100` followed by 20 bytes, 23 bytes in total) |
| Site store | The `SiteRegistry` contract, storing files by (container, path) with a SHA-256 for every file |
| Payment contract | The `DomainBinding` contract, recording until when a name or domain is paid for a container |
| Kernel | A library that reads the chain, resolves and verifies. It does not render and does not connect wallets |
| Shell | An application built on a kernel that displays sites: a web viewer, a browser extension, a desktop or mobile app, a wallet's browser, a Service Worker gateway |
| Area code | The number that marks a chain other than BNB Smart Chain in names (§2.1, §3.1). BNB Smart Chain has none |
| Operator | The organization that runs a node. Nodes of one operator count as one wherever this TAP counts answers |
| Answer | A well-formed JSON-RPC result, including `null` and an execution revert. Transport errors, other JSON-RPC errors, timeouts and malformed results are not answers |
| Default agreement, strict agreement | The two ways of adopting a read (§5.2) |
| Pinned block | The block at which a set of reads is made (§5.3) |
| Finality tag | The block tag a chain uses to decide that a message can no longer be reorganized away: `finalized` or `safe` (§2.1, §17) |
| Endpoint, endpoint ID | A container as a messaging address, and its 32-byte identifier (§12.1) |
| Hub | The DeWEB hub contract on one chain (§13). It has the same address on every chain |
| Home chain | The chain a container lives on. Its site, its messaging key and its sent messages are on that chain |
| Entry | One record in an inbox (§13.6) |
| Payload | The bytes carried by a message (§15) |
| Content | The JSON object inside a payload (§16) |

Notation: `‖` is byte concatenation. `uint256(x)` is the 32-byte big-endian encoding of `x`; `uint64(x)` and `uint32(x)` are 8- and 4-byte big-endian. An address in a byte string is its 20 raw bytes. ASCII labels such as `"TAP-10/key/v2"` are used as their raw bytes, without a terminator. Hex is lowercase and `0x`-prefixed unless stated otherwise; addresses in tables are EIP-55 checksummed and compared case-insensitively.

## 2. Chains

### 2.1 Chain table

The chain table is part of this specification. The **area code** is used in names (§3.1). The **bitmap bit** is used only in messaging keys (§14.3). They are different numbers: always take each from this table.

| Bitmap bit | Chain | chainId | Area code | Short name | Finality tag | Max pin lag (blocks) | Status |
|---|---|---|---|---|---|---|---|
| 0 | BNB Smart Chain | 56 | none | `bnb` | `finalized` | 400 | Active |
| 1 | Base | 8453 | `3` | `base` | `safe` | 150 | Active since 2026-09-19 |
| 2 | X Layer | 196 | `2` | `xlayer` | `safe` | 300 | Active since 2026-09-19 |

- A chain becomes active when the TapeOut circuit protocol, the site contracts and a reviewed hub implementation are deployed on it and listed under Deployments. Bitmap bits are never reused or renumbered; new chains are appended.
- Area codes are assigned once and never changed or reused. `0` and `1` are reserved and never assigned. BNB Smart Chain has no area code, so each of its containers has exactly one name.
- The finality tag is used in §17. The max pin lag bounds how far a pinned block may fall behind the highest head reported by any operator (§5.3); each value is about five minutes of blocks on that chain.
- The short name identifies a chain in configuration only. It is not part of any name or display form.

### 2.2 Contracts on each chain

Each active chain has its own processor factory, container opener, ERC-6551 registry and container implementation, site store, payment contract, container payments table and DeWEB hub. Their addresses, and the implementations a client accepts behind each upgradeable proxy, are listed under Deployments. A client **MUST** use, for each chain, only the addresses listed for that chain, and **MUST NOT** learn addresses from any server, site or message.

## 3. Names and input

### 3.1 Names

Every processor numbers its #IDs from 1, so a #ID alone does not identify a circuit; "processor + #ID" does. Processor names are not unique and processor contract addresses are long, so names use the processor number, and, for chains other than BNB Smart Chain, the area code.

| Form | BNB Smart Chain | Other chains in §2.1 | Example (BNB) | Example (Base) |
|---|---|---|---|---|
| **On-chain name** (canonical) | `<#ID>.<processor number>.tape` | `<#ID>.<area code>.<processor number>.tape` | `4246.0.tape` | `1.3.1.tape` |
| Short name | `<#ID>.<processor number>` | `<#ID>.<area code>.<processor number>` | `4246.0` | `1.3.1` |
| Display label | `#<#ID>@<processor number>` | `#<#ID>@<area code>.<processor number>` | `#4246@0` | `#1@3.1` |

- All numbers are decimal ASCII without leading zeros (except `0` itself); 1 ≤ #ID ≤ 10^18 and 0 ≤ processor number ≤ 10^9. The canonical forms are lowercase;
- A name with an area code denotes a circuit on that chain only; a name without an area code denotes a circuit on BNB Smart Chain. An area code that is not in §2.1 (including `0` and `1`) is an input error;
- The on-chain name is also, character for character, the name registered in the payment contract (§6.3);
- `#` is the URL fragment delimiter, so the display label is only for display and typing; URLs use the on-chain name;
- A client **MUST** produce identical resolution results for every form of one name. A chain that is not in §2.1 is displayed as `#<#ID>@<processor number>.chain<chainId>`; that form **MUST NOT** be accepted as input.

### 3.2 URLs

```
tape://<on-chain name>/<path>
```

Example: `tape://4246.0.tape/index.html`. The host is the complete on-chain name, including `.tape`, so the origin of a site is exactly `tape://4246.0.tape` (or `tape://1.3.1.tape`). The suffix cannot be dropped from URLs: Chromium parses the host of every standard scheme as IPv4 where it can, rejecting `4246.0` and rewriting `1.0` to `1.0.0.0` (measured on Electron 43, 2026-09-13). Path rules are in §7.2.

`web+tape://` is an alias for web environments with identical host and path: browsers let web pages claim only schemes that start with `web+` (`navigator.registerProtocolHandler`), while an unprefixed `tape://` can only be registered by an installed program. Every shell **MUST** accept both; for display `tape://` **SHOULD** be used.

### 3.3 Gateway host labels

A Service Worker gateway (§8.8) carries the name in one DNS label, because a wildcard certificate covers only one label:

```
<#ID>-<processor number>.<gateway domain>                 BNB Smart Chain, e.g. 4246-0.<gateway domain>
<#ID>-<area code>-<processor number>.<gateway domain>     other chains,    e.g. 1-3-1.<gateway domain>
```

A label is valid only if it matches `^[1-9][0-9]*-(?:[1-9][0-9]*-)?(0|[1-9][0-9]*)$` and the resulting name is valid under §3.1.

### 3.4 Input

A shell's address bar and a messaging client's recipient field **SHOULD** accept the following forms, case-insensitively for the `tape://`, `web+tape://` and `.tape` parts, and after resolution display the canonical name (shells) or the display label (messaging):

| Form | Example | Meaning |
|---|---|---|
| On-chain name | `4246.0.tape`, `1.3.1.tape` | §3.1 |
| Short name | `4246.0`, `1.3.1` | The same |
| URL | `tape://4246.0.tape/docs/`, `tape://4246.0/docs/`, `web+tape://1.3.1.tape/` | With path; the suffix-less host is accepted as input only |
| Display label | `#4246@0`, `4246@0`, `#1@3.1` | The same name |
| Container address | `0x86DDaEF00401E3F10418398D67D7189fc458eA95` | Reverse-resolved (§4.3) |
| Processor contract#ID | `0x50A994E71615474b55559fF4F500928fbc339DD9#4246` | Reverse-resolved (§4.3) |
| Endpoint ID (messaging only) | 32 bytes, §12.1 | Carries its chain |

Anything else **MUST** be rejected as an input error; a client **MUST NOT** guess.

## 4. Resolving identity

### 4.1 Choosing the chain

- **A name** belongs to the chain its area code denotes (no area code: BNB Smart Chain). A client asked to resolve a name on another chain **MUST** stop with `wrong-chain` before reading the chain;
- **An endpoint ID** carries its chain ID (§12.1);
- **Input without chain information** (a container address, or a processor contract with a #ID) is resolved on every active chain, each at its own pinned block:
  - a container address can be a container on one chain only, because its derivation includes the chain ID; the client uses the chain on which it resolves;
  - a processor contract with a #ID is resolved only when exactly one chain resolves it. If it resolves on more than one chain, the client **MUST** stop with `ambiguous` and ask for a name with an area code. The processor factories on Base and X Layer share an address, so the same processor contract address can exist on both (for example `0x0565EA48CA41Ae559d8d491dbb0a9ec945DB551b` is processor 1 on both; see Test Cases). If the input resolves on one of them while the other could not be read or its site store implementation is not accepted, the client **MUST** report the other chain's status rather than guess;
  - if the input resolves on no chain, but some chain could not be read or its implementation is not accepted, the client **MUST** report that chain's status and **MUST NOT** report `not-tapeout`.

### 4.2 Name → container

All of the following reads are made at one pinned block (§5.3) of the chosen chain:

1. `factory.cpuCount()`; processor number ≥ count → `no-such-cpu`;
2. `factory.cpuAt(processor number)` gives the processor contract (a revert → `no-such-cpu`);
3. `opener.accountOf(processor contract, #ID)` gives the container address;
4. `processor contract.ownerOf(#ID)`: a revert → `no-such-token`; otherwise it gives the holder;
5. `opener.isOpened(processor contract, #ID)` gives whether the container is opened.

The processor's `name()` **MAY** be read for display; it is not unique and **MUST NOT** be used for identity.

### 4.3 Container address or processor contract#ID → name

Container address:

1. `container.token()` returns (chainId, processor contract, #ID). If the call fails, returns no code, or its chainId is not the chain being read → `not-tapeout`;
2. `factory.isCPU(processor contract)` is false → `not-tapeout`;
3. Find the processor number: the factory has no reverse table, so the client scans `cpuAt(i)` by index in batches. Not found → `not-tapeout`;
4. `opener.accountOf(processor contract, #ID)` **MUST** equal the input container address, otherwise `not-tapeout`. This defends against a contract that merely claims to be a container;
5. Continue with §4.2 steps 4–5.

Processor contract#ID: steps 2 and 3, then §4.2 steps 3–5.

Numbers are append-only, so the table from processor number to processor contract **MAY** be cached indefinitely per chain and factory; only new numbers need scanning.

### 4.4 Identity outcomes

| Outcome | Meaning |
|---|---|
| Input error | The input matches no form of §3.4, has a leading zero, is out of range, or has an unknown area code |
| `wrong-chain` | A name was to be resolved on a chain other than the one its area code denotes |
| `ambiguous` | Input without chain information resolves on more than one chain |
| `no-such-cpu` | No processor with this number on that chain |
| `no-such-token` | The processor has no circuit with this #ID |
| `not-tapeout` | Not a TapeOut circuit container, or not a TapeOut processor |
| `unavailable` | The reads could not be adopted (§5.2) |

## 5. Nodes, agreement and the pinned block

### 5.1 Nodes and operators

A client reads each chain through a list of JSON-RPC nodes. Each node carries an operator label; nodes of one operator count as one. A client **SHOULD** let users add or replace nodes, including self-hosted ones, **MUST** keep such settings where site code cannot change them (§8.3), and **MUST NOT** fetch node lists, implementation lists or any other part of its configuration dynamically from a server: the lists travel with the client version (§21).

A node URL that carries an API key or identifies the caller **MUST NOT** be written into public files such as a gateway's bootstrap (§8.8), and **MUST NOT** be offered to site code as a node the site may use: a site could otherwise make visitors' browsers send requests billed to the site owner's own key.

### 5.2 Agreement

- **Default agreement.** A read is adopted when answers from at least two different operators agree exactly after normalization. If any two answers received disagree, the client **MUST** reject the read and **MUST NOT** take a majority vote. If a node errors or times out, the client **MAY** ask the next one. A client whose user has configured a single node **MAY** adopt that node's answers.
- **Strict agreement.** A read is sent to every configured node and adopted only when every answer agrees after normalization and the agreeing answers come from at least max(2, min(3, number of configured operators)) different operators, within a deadline. Any disagreement means rejection; too few answers means `unavailable`. Strict agreement is used wherever a few colluding nodes could otherwise misdirect encryption or forge messages: every messaging read of §12–§20 that this TAP marks strict, and the seal checks of §13.8.

The access layer uses default agreement. Normalization compares results as returned for hex strings, and compares objects (blocks, transactions, receipts, logs) on the fields the client uses, as canonical JSON with keys sorted and strings lowercased.

### 5.3 Pinned block and freshness

All reads for one resolution, one site open, one key lookup or one send are made at one pinned block, so that a change on chain in the middle cannot produce a mix of old and new state.

A client asks every configured node for its head (`eth_blockNumber`). Once heads from Q different operators have arrived, where Q = min(2, number of configured operators), it waits up to 1.5 seconds for the others. For each operator it keeps the lowest head that operator's nodes reported. The pinned block is the Q-th highest of these operator heads, minus 2. The **pin lag** is the highest operator head minus the pinned block.

A client **MUST** reject a pinned block as `stale-block` when its pin lag exceeds the chain's max pin lag (§2.1). The check uses only block numbers, so a wrong clock on the client's device does not make it fail. (TAP-10 v1.0 compared the block time with the client clock and defined `clock-skew`; §18.6 keeps the code, but it is no longer produced.) Security Considerations describes what this check cannot detect.

### 5.4 Chain check

A messaging client **MUST** confirm with `eth_chainId`, under strict agreement, that the nodes of each chain are on the expected chain, and stop with `wrong-chain` otherwise. A shell **SHOULD** make the same check. The chain ID of a container is taken only from the client's configuration and from `token()` compared with it (§4.3), never from other data.

## Part II. Access layer (tape://)

## 6. Sites

### 6.1 Pinned implementations

The site store and the payment contract are upgradeable proxies (UUPS behind ERC-1967). At the pinned block, a client **MUST** read the ERC-1967 implementation slot `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` of both proxies of the chosen chain, and compare each with the implementations listed as accepted for that proxy under Deployments. A client **MUST NOT** call the contract's own `implementation()` for this purpose: after an upgrade the new code answers. If either implementation is not accepted, the status is `store-changed` and the client **MUST NOT** read the site until the client is updated with a new list (fail-closed, §21).

A site store list may hold several store addresses for one chain (a future store version next to the old one). A client looks them up in order and uses the first that has any path for the container; old store addresses stay on the list.

### 6.2 Site resolution

To open a site, a client resolves the input (§4) at one pinned block, checks the implementations (§6.1) in the same block, and assigns the first status that applies:

1. `store-changed` (§6.1);
2. an identity outcome other than a resolved circuit (§4.4);
3. `not-opened` if the container is not opened;
4. `blocked` if the container address or the on-chain name is on the client's blocklist (§10);
5. `unpaid` if the name is not activated (§6.3);
6. otherwise `ok`.

### 6.3 Activation

A name is activated when either of the following holds at the pinned block. In both, "the container" is the one **derived** from the name (§4.2), never one reported by anyone:

1. `DomainBinding.isLive(on-chain name, container)` is true: this on-chain name has been paid for this container and has not expired;
2. `DomainBinding.isContainerLive(container)` is true: this container has paid for **any** name or domain and has not expired. One payment per container activates both its bound domain and its on-chain name. On payment-contract implementations that lack this function the call reverts, and a client **MUST** treat a revert as false.

Consequences and rules:

- Nobody can squat a name: if someone pays for `4246.0.tape` with their own container, clients ignore it, because the container derived from the name is not theirs;
- Paying: the container's holder calls `DomainBinding.bind(name or domain, container, months)` with `msg.value = months × monthlyFee()`, in the chain's native coin (BNB, ETH or OKB). The payment contract, not the client, enforces who may pay and for how long (Appendix A). The fee is set by the contract owner, differs per chain and can change at any time (`FeeChanged`). A client that helps a holder pay **MUST** read `monthlyFee()` from the chain at the time of payment and **MUST NOT** hard-code a fee. Deciding whether a site is activated needs only `isLive` and `isContainerLive`, never the fee;
- `DomainBinding.syncContainer(domain, container)` copies an existing name-level expiry into the container-level record; anyone may call it, and it can only raise the expiry;
- When the circuit NFT changes hands, the payment record stays with the container;
- On-chain data is public and anyone can read it. The fee is enforced only by compliant shells displaying only activated sites, not by any technical block on reading. Official shells **MUST** display only sites in state `ok`, and documentation **SHOULD** say plainly that the fee can be bypassed.

### 6.4 Site status codes

| Status | Meaning | Shell behaviour |
|---|---|---|
| `ok` | Activated | Display |
| `unpaid` | Name not paid for, or expired | Do not display content; explain how the holder can activate it |
| `not-opened` | The circuit has not opened its container | Do not display |
| `no-such-cpu` | No processor with this number | Error |
| `no-such-token` | The processor has no such circuit | Error |
| `not-tapeout` | Not a TapeOut circuit container | Error |
| `blocked` | Blocked by this client (§10) | Show the block notice |
| `store-changed` | A site contract's implementation is not accepted (§6.1) | Refuse to read |

Status codes are only ever added; existing ones are never changed or removed (§21).

## 7. Files

### 7.1 Reading and verification

All reads of one site open are made at the pinned block of its resolution.

1. `SiteRegistry.fileInfo(container, path)` returns `(size, contentType, sha256Hash, updatedAt, chunkCount)`; `chunkCount` 0 means the file does not exist;
2. Files larger than 8,400,000 bytes (350 chunks of 24,000 bytes) **MUST NOT** be read (`too-large`);
3. Files up to 96 KiB (98,304 bytes) are read with one `read(container, path)`; larger ones with `readRange(container, path, offset, 98304)` segments;
4. After reading, the length **MUST** equal the declared size and the SHA-256 of the bytes **MUST** equal `sha256Hash`. Otherwise the file is `incomplete` (uploading or corrupted) and **MUST NOT** be displayed as a normal file;
5. A `sha256Hash` of all zeros means the owner declared no hash (`no-hash`). Shells **MAY** display such files but **MUST** mark them unverified; official shells **SHOULD** mark the whole site unverified;
6. From `contentType`, every character other than letters, digits, `_ . + / ; = -` and space is removed and the result is cut to 100 characters; if it does not then start with `type/subtype`, the file is served as `application/octet-stream`;
7. The file list comes from `pathCount(container)` and `pathsRange(container, from, n)`; a client **MAY** stop listing after 5,000 paths and **SHOULD** say that the list was cut.

File outcomes: `ok`, `no-hash`, `incomplete`, `too-large`, or not found.

### 7.2 Paths

1. Strip everything from the first `?` or `#`, percent-decode (a malformed `%xx` makes the path invalid), apply Unicode NFC normalization, and collapse consecutive `/`;
2. A control character (U+0000–U+001F, U+007F), a `.` segment or a `..` segment makes the path invalid;
3. An empty path, `/`, or a path ending in `/` gets `index.html` appended; then the leading `/` is removed;
4. Landing order: (a) exact match; (b) if the last segment has no extension, `<path>/index.html`; (c) still nothing and no extension: the site's `fallbackPath(container)`, if it names an existing path (single-page applications); (d) otherwise not found.

## 8. Shells

This section is the security floor. An on-chain site may be malicious; a shell **MUST** ensure that it cannot harm the user, other sites or the shell itself.

### 8.1 Origins

Site code **MUST** run in one of these environments:

- **A real, independent origin.** A native app or desktop shell registers `tape://` and uses the on-chain name as the host: one origin per site, e.g. `tape://4246.0.tape`. Only a real origin may persist data and connect wallets (§8.4);
- **An opaque origin (preview mode).** A sandboxed iframe **without** `allow-same-origin`. The site cannot read or write any persistent storage and cannot touch the shell page;
- **A Service Worker gateway.** An ordinary HTTPS domain with one subdomain per site (§3.3). The server returns the same bootstrap for every subdomain and path; once the bootstrap has installed the Service Worker, every same-origin request is resolved, read and verified against the chain inside the user's browser, and the server never handles site content (§8.8).

Two sites **MUST NOT** share an origin, and a site **MUST NOT** share an origin with the shell's own pages. A shell **MUST NOT** let other origins frame a site (for example `frame-ancestors 'self'`).

### 8.2 Privileged contexts

Site code **MUST NOT** run in extension pages with access to extension APIs, an app's bridge page, the shell's own page or any similarly privileged context. Browser extensions **MUST** render through a sandbox page declared in the manifest.

### 8.3 Storage

Under a real origin, storage (localStorage, IndexedDB, cookies, caches) is isolated per origin, that is per site. Site code can read and write everything stored under its origin, so a shell running under the site's origin (a Service Worker gateway):

- **MUST NOT** keep resolution results, activation status, blocklists or node settings where site code can change them;
- **MUST** verify cached file bytes again before serving them (§11).

After a circuit changes hands, the old data under the same origin remains; shells **SHOULD** offer to clear a site's data.

### 8.4 Wallets

- A wallet (for example `window.ethereum`) **MAY** be available only under a real, independent origin; preview mode **MUST NOT** inject one;
- For every connection or signing request, the wallet interface **MUST** show the on-chain name, the processor name and the container address, not only the page's title;
- Wallet permissions **MUST** be recorded per origin, that is per site;
- A shell that injects a wallet **MUST** refuse raw-hash signing and any `personal_sign` text containing `tapesend:hub:`: whoever holds that signature holds a TapeSend key (§14.2).

### 8.5 Network access

- **Code only from the chain.** A site's scripts, workers and nested frames' scripts **MUST** come only from the site itself (same origin, inline, `blob:`), never from an off-chain address. A shell enforces this with a Content Security Policy whose `script-src` lists no off-chain source and whose `worker-src` allows only the site and `blob:`, applied to every response of the site; nested frames inherit it;
- **Off-chain data.** A shell **MAY** let a site reach off-chain data (APIs, images, fonts, styles, media, WebSocket, embedded players, wallet relays) and **MAY** block it. In either case it **MUST** record the off-chain requests it can observe and **SHOULD** list them to the user, and it **MUST** reflect them in the indication of §9;
- Requests to the shell's own chain nodes are not off-chain requests.

### 8.6 Navigation and pop-ups

- A site **MUST NOT** navigate the shell's top-level page;
- Links within the site open inside the shell; links to off-chain destinations **MUST** open in a new window with a notice that the user is leaving the on-chain site;
- Pop-ups, notifications and downloads **MUST** require user confirmation.

### 8.7 Displaying identity

The shell's address bar or title bar **MUST** always show the on-chain name, the activation status and the verification status (§7.1). The page's own `<title>` may only be a subtitle. Names are all digits and have no look-alike letters, but `4246.0` and `4264.0` can still be confused, so shells **SHOULD** also show the processor name and the holder.

### 8.8 Service Worker gateways

- **Trust boundary:** the bootstrap files (the bootstrap page, `sw.js` and its imports) are the only download that must be trusted. They **MUST** be open source and contain no external resources, and anyone must be able to run a gateway from the same files. Files served from the gateway's own paths **MUST** be locked (`default-src 'none'; sandbox`) when opened as documents;
- **Nodes do not belong to the gateway:** reads happen in the user's browser with the client's node list. A node the operator adds counts as one operator's vote; the agreement rules do not change;
- **Reserved paths:** `/sw.js` and the `/.tape/` prefix belong to the gateway; site files at those paths are never read. Every site **MUST** have a status page at `/.tape/status` showing identity, activation, verification, off-chain references and requests, and node statistics;
- **Gateway pages:** the status page, settings and every notice or error page **MUST NOT** contain scripts, **MUST** carry a Content Security Policy that forbids framing them and loading anything else, and **MUST NOT** echo the requested path or other attacker-chosen text;
- **Headers:** verified responses **SHOULD** carry `x-tape-name`, `x-tape-status`, `x-tape-container`, `x-tape-block`, `x-tape-sha256` and `x-tape-verified`;
- **Requests the gateway cannot see:** WebSocket, WebRTC, some cross-origin frames and requests started while the Service Worker is not controlling the page do not pass through it. Documentation **SHOULD** say so, and the indication of §9 **MUST** take it into account;
- **Sibling subdomains:** cookies can be set on the parent domain and leak between sites. Production gateways **SHOULD** put their domain on the Public Suffix List, so that every subdomain is a separate site with its own process and storage partition;
- **Hard reload** (Shift+Reload) bypasses the Service Worker once; the bootstrap page **SHOULD** explain this.

## 9. The on-chain indication

A shell **MAY** mark a site "100% on-chain" only when both hold:

1. **Static scan:** the HTML and CSS it served contain no references to off-chain resources (`http:`, `https:`, `ws:`, `wss:`, `ftp:` or `//host` in `src`, `href`, `action`, `poster`, `data`, `formaction`, `background`, `srcset`, `url()`, `@import` or a meta refresh);
2. **Runtime:** it observed no off-chain request, and it can observe every kind of request the site can make.

A shell that cannot observe every kind of request (a Service Worker gateway, §8.8) **MUST NOT** claim "100% on-chain"; it **MAY** say that no off-chain access was seen. Otherwise the shell shows that the site references off-chain resources and lists them.

## 10. Blocking and reporting

- Nothing on chain can be deleted, but the shell is the party that displays it. A shell **MUST** support a blocklist by container address or on-chain name, returning `blocked` on a hit, and **MUST** consult it on every resolution, including one served from a cache;
- List format: plain text, one container address or on-chain name per line; lines starting with `#` are comments;
- Official shells **SHOULD** offer a way to report a site and publish their blocking rules;
- Blocking affects only shells that follow it; it changes nothing on chain or in other shells.

## 11. Caching and updates

- A file cache **MUST** be keyed by the on-chain SHA-256, so an update on chain makes old entries unreachable. Before serving a cached file, a shell **MUST** recompute its SHA-256 and discard the entry on a mismatch; files without a declared hash **MUST NOT** be served from a cache;
- Resolution results (container, holder, activation) **SHOULD NOT** be cached for more than 60 seconds, **MUST NOT** be persisted where site code can write them (§8.3), and an entry whose time lies in the future is invalid;
- A shell **MAY** detect updates with `SiteRegistry` events (`FileSet`, `FileRemoved`, `FallbackSet`). Most public nodes do not serve `eth_getLogs`, so the reference kernel instead re-reads `pathCount`, `fallbackPath` and the `fileInfo` of known paths periodically and treats any change as an update;
- The processor number table **MAY** be cached indefinitely (§4.3);
- Shells **SHOULD** offer both Chinese and English interface text.

## Part III. Messaging layer (TapeSend)

## 12. Endpoints

### 12.1 Endpoint ID

```
endpoint ID = uint32(0) ‖ uint64(chainId) ‖ container      (32 bytes)
```

- The top 4 bytes **MUST** be zero, `chainId` **MUST** be non-zero and the container address **MUST** be non-zero. The hub rejects anything else with `BadEndpoint` (§13.5);
- The endpoint ID is globally unique: the same container address on two chains gives two different endpoints;
- Clients **MUST** reject endpoint IDs whose `chainId` exceeds 2^53 − 1 (such chains are not supported).

Messaging clients display an endpoint by its display label (§3.1).

### 12.2 Resolving an endpoint

A messaging client resolves input as in §4, with these differences:

- All reads are made at one pinned block under **strict** agreement, after the chain check of §5.4;
- After §4.2 or §4.3, it reads `hub.keyFor(processor contract, #ID)` (§13.5). The `container` it returns **MUST** equal the resolved container, and its `endpoint` **MUST** equal `endpointID(chainId, container)` for the chain being read; otherwise the client **MUST** stop (`hub-mismatch`);
- §6 does **not** apply: an unpaid on-chain name, a changed site-store implementation or a site blocklist entry **MUST NOT** prevent messaging.

The result is (chain, processor contract, processor number, #ID, container, endpoint ID, holder, opened, key view). Only the **sender** must be opened; the hub enforces it.

## 13. The DeWEB hub

### 13.1 Properties

- An ERC-1967 proxy over a UUPS implementation. Until it is **sealed** its owner can replace the implementation (§13.7); after `seal()` there is no owner and no upgrade path;
- The implementation has no payable function, no `receive` and no `fallback`, so every call carrying the chain's native coin (BNB, ETH or OKB) reverts; the hub holds no assets and has no function that moves assets;
- It makes no state-changing call elsewhere. It reads other contracts only through bounded `staticcall`s: 100,000 gas each, return data never copied beyond 32 bytes, exactly 32 bytes required. A failed or malformed read counts as "not authorized" (a revert, no code, return data that is not 32 bytes, a boolean other than 0 or 1, or an address word with non-zero upper 96 bits). A failed registry read, or a zero registry answer, reverts `RegistryFailed`;
- An under-gassed transaction reverts with an authorization error rather than running out of gas (63/64 rule). Wallets **MUST** use gas estimation;
- It does not parse payloads.

### 13.2 Deployment

All three contracts are deployed through the deterministic CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C`, so every address can be recomputed from source.

| Item | Value |
|---|---|
| Build | solc 0.8.28, optimizer on, 10,000 runs, EVM `shanghai`, legacy pipeline (no via-IR), `bytecode_hash = none`, `cbor_metadata = false` |
| Boot implementation | salt `keccak256("DeWEB Boot v1")`; creation code of `DeWebBoot`, no arguments. Address **`0xC0D28CA8689248B0bed26cC0aa328CF16Aa4401e`**, the same on every chain |
| Hub (proxy) | salt `keccak256("DeWEB Hub v1")`; `DeWebProxy` creation code ‖ `abi.encode(boot, abi.encodeCall(initialize, (owner)))`. With owner `0x571d447f4f24688eC35Ccf07f1D6993655F6aF15` the address is **`0xe61A9C7213a6Aa616C246a2B569e555B417b25ee`**, the same on every chain |
| Implementation | salt `keccak256("DeWEB Hub impl v2")`; `DeWebHub` creation code ‖ `abi.encode(uint256 expectedChainId, registry, accountImplementation, factory, payments, circuitBeacon, circuitImplementation, circuitCodehash)`. Its address differs per chain because the arguments do |

The boot implementation only allows its owner to upgrade (it cannot be sealed); it exists so that the hub address does not depend on any chain's TapeOut addresses.

**Accepted implementations** are listed per chain under Deployments; §13.8 says when a client accepts the hub. The Base and X Layer implementations are built from the same source and salt as v3 on BNB Smart Chain; only the constructor arguments differ.

- The constructor reverts `WrongChain` on any chain other than `expectedChainId`, and `BadEndpoint` if the chain ID is 0 or above 2^64 − 1;
- Anyone can recompute the boot, proxy and implementation addresses from source (`forge test --match-contract Pinned` in TapeKit `send/contracts`), and read the implementation slot and the constructor arguments back through the proxy with `eth_getStorageAt` and `eth_call`.

### 13.3 Storage

Two ERC-7201 namespaces, so records survive upgrades:

- `deweb.admin.v1` at `0x736671d3d7aa7b8c7f898557852b1cc8f6b8b590d42594c0a8eca138259d9100`: `owner`, `sealed`, `initialized`, `pendingOwner`;
- `deweb.hub.v1` at `0x52508d06499dccc2446f87bf89abfddc2d85f3e5a1bdd29ea2bc99cdfd6b2000`: key records, inbox counts and entries, outbox counts and entries.

A future implementation **MUST** keep both namespaces and their layouts.

### 13.4 Authorization

Every write names a circuit as `(processor contract, #ID)`. The hub checks, in this order:

1. `circuitBeacon.implementation()` equals `circuitImplementation`, otherwise `CircuitsChanged`;
2. the code hash of the processor contract equals `circuitCodehash`, otherwise `NotCPU`;
3. `factory.isCPU(processor contract)` is true, otherwise `NotCPU`;
4. `processor contract.ownerOf(#ID)` returns `msg.sender`, otherwise `NotHolder`;
5. the container is `registry.account(accountImplementation, 0, block.chainid, processor contract, #ID)`; a failed read reverts `RegistryFailed`;
6. `payments.paid(container)` is true, otherwise `NotOpened`.

The container is then the author. Consequences:

- only the current holder of an opened circuit on a registered processor can write for its container; after a transfer the new holder speaks for the same container;
- `send` and `revokeKey` accept **any** holder, including contracts. A contract the holder approved for the circuit NFT (for example a marketplace) can therefore take the NFT, write as the container and return it within one transaction. The hub cannot see this; clients detect it (§18.5);
- a lasting replacement of the processor implementation stops every write and makes every key unusable; a new hub would be needed;
- the pin cannot detect a **temporary** replacement by whoever controls an unsealed factory (§13.8).

### 13.5 Interface

**Writes** (each reverts `NotProxy` when called on the implementation directly):

| Function | Selector | Behaviour, in order |
|---|---|---|
| `send(address circuits, uint256 tokenId, bytes32 to, bytes32 ref, bytes payload) returns (uint256 inboxIndex)` | `0xa181b579` | `BadEndpoint` unless `to` is a valid endpoint ID (§12.1); `EmptyPayload` if empty; `PayloadTooLarge(size, 16000)` if longer than 16,000 bytes; §13.4; `BoxFull` if the recipient's inbox or the sender's outbox already holds 2^32 − 1 entries; appends an inbox entry and an outbox entry (§13.6); emits `Sent`. `to` may be on any chain and need not be opened |
| `publishKey(address circuits, uint256 tokenId, uint8 suite, uint16 keyIndex, bytes32 key, uint64 chains)` | `0x23e0bbc6` | `BadSuite` unless `suite == 1`; `EmptyKey` if `key == 0`; `NoChains` if `chains == 0`; §13.4; `ContractHolder` unless `msg.sender` is a plain account, and also when `msg.sender` has no code but is not `tx.origin`; stores the record with `holder = msg.sender` and `publishedAt = block.timestamp`, increments `version`; emits `KeyPublished` |
| `revokeKey(address circuits, uint256 tokenId)` | `0x08394925` | §13.4; `NoKey` if there is no key; zeroes `key`, `holder`, `suite`, `keyIndex`, `chains`, sets `publishedAt`, increments `version`; emits `KeyRevoked` |

**Reads:**

| Function | Selector | Returns |
|---|---|---|
| `keyFor(address circuits, uint256 tokenId)` | `0x3145c6cb` | `KeyView(address container, bytes32 endpoint, bool opened, address current, uint8 suite, uint16 keyIndex, bytes32 key, bool usable, uint32 version, uint64 chains)`. `current` is `ownerOf` or 0 if that read fails. `usable` is true only when a key exists, `current != 0`, the stored holder equals `current`, `current` is a plain account, and the processor is genuine (§13.4 steps 1–3). **When `usable` is false, `suite`, `keyIndex`, `key` and `chains` are returned as 0**; `version` is always returned. Reverts only `RegistryFailed` |
| `keyOf(address container)` | `0xfa073d76` | The raw record `(bytes32 key, address holder, uint40 publishedAt, uint8 suite, uint16 keyIndex, uint32 version, uint64 chains)`, unchecked. Clients **MUST NOT** use it to decide whether to encrypt |
| `inboxCount(bytes32 to)` | `0x9343ecd9` | Number of entries in `inbox[to]` on this chain |
| `inboxAt(bytes32 to, uint256 i)` | `0x3e605450` | `Entry`; reverts `OutOfRange` if `i ≥ inboxCount(to)` |
| `inboxPage(bytes32 to, uint256 start, uint256 n)` | `0x2eec4913` | `Entry[]` from `start`, oldest first, at most `min(n, 200)` entries; empty when `start ≥ count` |
| `outboxCount(address from)` | `0xf0549006` | Number of messages sent by container `from` on this chain |
| `outboxPage(address from, uint256 start, uint256 n)` | `0xcf082720` | `OutEntry[]` as for `inboxPage` |
| `digestOf(bytes32 ref, bytes payload)` | `0x120950e3` | `keccak256(ref ‖ keccak256(payload))` |
| `endpointOf(address container)` | `0x4b893642` | The endpoint ID of `container` on this chain |
| `accountOf(address circuits, uint256 tokenId)` | `0x0c1905e5` | The container address (does not check that `circuits` is a processor) |
| `MAX_PAYLOAD()`, `MAX_PAGE()`, `SUITE_X25519()` | `0xcfdd2b73`, `0x69fc09b9`, `0xda582a0e` | `16000`, `200`, `1` |
| `registry()`, `accountImplementation()`, `factory()`, `payments()`, `circuitBeacon()`, `circuitImplementation()`, `circuitCodehash()` | | The constructor arguments |

`version` is per container, starts at 0, increases by exactly 1 on every publish and revoke, and never resets. `keyIndex` is not forced to increase; clients use `version` to detect change. If the NFT returns to the holder who published the current record, `usable` becomes true again without re-publishing.

**Events:**

| Event | topic0 |
|---|---|
| `Sent(bytes32 indexed to, address indexed from, bytes32 indexed ref, uint256 inboxIndex, uint256 outboxIndex, bytes payload)` | `0xd75bb8082dd3ae8bb88682115ee1412a8e8051cc81d0e4c01dc3b06c0cf61020` |
| `KeyPublished(address indexed container, address indexed holder, uint8 suite, uint16 keyIndex, bytes32 key, uint32 version, uint64 chains)` | `0x3508619c70f595e587bda151c8e0d612b9b2bb7b2e9f7d35696ff38cbdf0f85d` |
| `KeyRevoked(address indexed container, address indexed holder, uint32 version)` | `0xd360cbf79f51b9effe9910886c31cb5727df68b64e1cadc0be214931a7fb84c9` |
| `Upgraded(address indexed implementation)` | `0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b` |
| `OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)` | `0x38d16b8cac22d99fc7c124b9cd0de2d3fa1faef420bfe791d8c362d765e22700` |
| `OwnerChanged(address indexed previousOwner, address indexed newOwner)` | `0xb532073b38c83145e3e5135377a08bf9aab55bc0fd7c1179cd4fb995d2a5159c` |
| `HubSealed()` | `0xa38d24a530434d3ab8b3f3f3f3a54ea1f987dddceba505bd3bd1f05dfa2106ad` |

For `Sent`: topic1 = `to`, topic2 = `from` (low 20 bytes), topic3 = `ref`; `data` is the ABI encoding of `(uint256 inboxIndex, uint256 outboxIndex, bytes payload)`.

**Errors:** `BadEndpoint` `0xd98d0ab4`, `EmptyPayload` `0x2e3f1f34`, `PayloadTooLarge(uint256,uint256)` `0x04247564`, `BoxFull` `0x12b9de4e`, `BadSuite` `0xe9b6829d`, `EmptyKey` `0x3cd69fac`, `NoChains` `0xa41d7dc9`, `NoKey` `0x80246e7f`, `ContractHolder` `0xc21b8423`, `NotCPU` `0x853f2907`, `NotHolder` `0x7623fb52`, `NotOpened` `0x6d36408a`, `CircuitsChanged` `0x2ffa540a`, `RegistryFailed` `0x06215c9b`, `OutOfRange` `0x7db3aba7`, `WrongChain` `0x10dfc033` (constructor), `NotAContract` `0x09ee12d5`, `ZeroAddress` `0xd92e233d`, `NotProxy` `0xbf10dd3a`, `NotOwner` `0x30cd7471`, `NotPendingOwner` `0x1853971c`, `Sealed` `0x1b2d71eb`, `NotUUPS` `0xf2fc2b29`, `NotDelegated` `0x9ccd6d76`, `AlreadyInitialized` `0x0dc149f0`.

### 13.6 Inbox and outbox

For each message, `send` stores:

```
Entry    { address from; uint56 blockNumber; uint40 timestamp; bytes32 digest }      in inbox[to][inboxIndex]
outbox[from][outboxIndex] = uint256(to) << 32 | inboxIndex
digest   = keccak256(ref ‖ keccak256(payload))
```

`outboxPage` returns `OutEntry { bytes32 to; uint32 inboxIndex; uint56 blockNumber; uint40 timestamp; bytes32 digest }`, joined with the inbox entry it points to. Both lists only grow; entries are never changed or removed.

`inboxPage` returns a static-struct array: `offset (= 0x20) ‖ length ‖ length × 4 words`; `outboxPage` uses 5 words per element. A client **MUST** reject a result whose length word exceeds 200, whose byte length does not match, or whose fields exceed their widths (addresses 160 bits, `blockNumber` 56, `timestamp` 40, `inboxIndex` 32).

The payload itself is **not** stored; it is only in the `Sent` event. The digest binds the payload and `ref` to the entry; it does not bind sender, recipient or index, so a client **MUST NOT** match a log to an entry by digest alone (§18.3).

### 13.7 Administration

| Function | Selector | Behaviour |
|---|---|---|
| `owner()`, `pendingOwner()`, `isSealed()` | `0x8da5cb5b`, `0xe30c3978`, `0x631f9852` | Current values |
| `transferOwnership(address)` | `0xf2fde38b` | Owner only; `ZeroAddress` for 0; sets `pendingOwner` |
| `acceptOwnership()` | `0x79ba5097` | The pending owner only; `Sealed` after sealing |
| `upgradeToAndCall(address impl, bytes data)` | `0x4f1ef286` | Owner only and not sealed; `ZeroAddress`, `NotAContract`; `NotUUPS` if `impl` is the proxy itself, if `impl.proxiableUUID()` does not return exactly 32 bytes equal to the ERC-1967 slot, or if `impl.selfAddress()` does not return exactly 32 bytes equal to `impl`; sets the slot, emits `Upgraded`, then delegatecalls `data` if non-empty |
| `seal()` | `0x3fb27b85` | Owner only; clears `pendingOwner` and `owner`, sets `sealed`; emits `OwnerChanged(owner, 0)` and `HubSealed()`. Irreversible. The boot implementation cannot be sealed |
| `proxiableUUID()` | `0x52d1902d` | The ERC-1967 slot when called on an implementation; reverts `NotDelegated` through a proxy |
| `selfAddress()` | `0x12e905b0` | The implementation's own address, also through the proxy |

Every future implementation **MUST** satisfy the two checks above and keep the storage of §13.3. Because v2 and the boot implementation lack `selfAddress`, the hub cannot be downgraded from v3.

`seal()` does not itself check that the TapeOut factory is sealed. The factory **MUST** be sealed first (§13.8); otherwise a later lasting change of the processor implementation stops the sealed hub for good.

### 13.8 Seal status and trust

At the pinned block and under strict agreement, a client **MUST** read:

1. **Factory:** `factory.isSealed()`, the factory's ERC-1967 implementation slot, `circuitBeacon.owner()` and `circuitBeacon.implementation()`. The factory seal is in effect only when `isSealed()` returns exactly 1, the factory implementation is the one listed for that chain under Deployments, the beacon's owner is the factory, and the beacon's implementation is `circuitImplementation`;
2. **Hub:** `hub.isSealed()`, `hub.owner()` and the hub's ERC-1967 implementation slot. The hub is **accepted** only when the slot holds the implementation listed as current for that chain under Deployments (`hub-changed` otherwise). The hub seal is in effect only when, in addition, `isSealed()` is 1 and `owner()` is 0.

Any revert, any non-canonical word (upper 96 bits of an address word non-zero) or any other value counts as not in effect.

- If `circuitBeacon.implementation()` is not `circuitImplementation`, messaging on that hub has stopped (`circuits-changed`); the client **MUST NOT** send and **MUST** keep this status even if later reads show the pinned value again;
- If the hub is not accepted, the client **MUST NOT** send;
- While either seal is not in effect, whoever controls the factory or the hub owner can impersonate endpoints and replace keys. A client **SHOULD** indicate this wherever it shows sender identities or encrypts. A client that has once seen the factory seal in effect and later sees it not in effect at a block not earlier than the first **MUST** keep treating the seal as lost;
- An upgrade can rewrite storage within one transaction and restore an accepted implementation, leaving only an `Upgraded` log. When log-capable nodes are available, a client **SHOULD** read every `Upgraded` log of the hub and accept the hub only if every implementation it names is the boot implementation or listed under Deployments (current or replaced).

The seals are recorded per chain and per hub address; sticky statuses of one chain **MUST NOT** affect another.

## 14. Keys

### 14.1 Suite

Suite `1`: X25519 (RFC 7748), HKDF-SHA256 (RFC 5869), XChaCha20-Poly1305 (32-byte key, 24-byte nonce, 16-byte tag), SHA-256. Public keys are the 32-byte RFC 7748 encoding, stored byte for byte in `bytes32 key`.

### 14.2 Deriving the key from the wallet

The private key is never stored on chain or on a server. It is derived from a wallet signature over a fixed text.

1. Build the text `T` (EIP-4361 form): ASCII, exactly these 14 lines, single `0x0A` separators, no trailing newline. `<holder>`, `<container>` and `<hub>` are EIP-55 checksummed; numbers are decimal without leading zeros; `<chainId>` is the **home chain** of the container; `#<#ID>` is one `#` followed by the decimal #ID.

```
www.tapesend.com wants you to sign in with your Ethereum account:
<holder>

Create the TapeSend encryption key for #<#ID>@<processor number>. Anyone who obtains this signature can read your messages. Only sign this on www.tapesend.com or in the official TapeSend app.

URI: https://www.tapesend.com
Version: 1
Chain ID: <chainId>
Nonce: tapesendkey<k>
Issued At: 2026-09-17T00:00:00Z
Resources:
- tapesend:container:<container>
- tapesend:hub:<hub>
- tapesend:key-index:<k>
```

2. Ask the holder's wallet for `personal_sign` of `T` (EIP-191). The signature is 65 bytes `r ‖ s ‖ v`; `v` **MUST** be 0, 1, 27 or 28.
3. Reject if `r` or `s` is 0 or ≥ n (secp256k1 order). Recover the signer from the signature as given and require it to equal the holder.
4. If `s > n/2`, replace `s` with `n − s`. `v` is discarded.
5. ```
   seed = HKDF-SHA256(salt = "TAP-10/key/v2", IKM = r ‖ s,
                      info = endpointID(chainId, container) ‖ uint256(k) ‖ hub, L = 32)
   ```
6. The X25519 private key is `seed`; the public key is `X25519(seed, 9)`.

**The name in the fourth line never carries an area code**, on any chain: it is always `#<#ID>@<processor number>`. For a container on Base or X Layer it therefore looks like a BNB Smart Chain name; for example, the container displayed as `#1@2.344` signs `Create the TapeSend encryption key for #1@344.` The `Chain ID` line and the `tapesend:container:` resource identify the container exactly, and the derivation (step 5) binds the endpoint ID, so no two containers derive the same key. A client **MUST NOT** add an area code to this line: the text is fixed (§21), and a different text derives a different key.

The fixed domain makes EIP-4361-aware wallets warn when any other site asks for this signature. This protection is partial (not every wallet checks; WalletConnect origins are self-declared). Therefore the official web client **MUST** be served only from `https://www.tapesend.com`, that origin **MUST NOT** run any other EIP-4361 sign-in, and the signature and derived key **MUST NOT** leave the device.

**Determinism.** Derivation requires deterministic signatures (RFC 6979). Before publishing a new key a client **MUST** obtain two signatures of `T` with equal normalized `r ‖ s`. Whenever it derives a key while `keyFor` reports a usable key with the connected wallet as holder and the same `keyIndex`, it **MUST** compare the derived public key with the on-chain key and **MUST NOT** use or publish on a mismatch. A client **MAY** skip the second signature when that comparison succeeds. Smart-contract wallets cannot derive a key (§13.5 refuses them).

### 14.3 Publishing and receiving chains

The holder calls `publishKey(processor contract, #ID, 1, k, publicKey, chains)` on the hub of the container's home chain. `chains` is the **receiving-chains bitmap**: bit `i` set means the holder reads its inbox on the chain whose bitmap bit is `i` in §2.1. It **MUST NOT** be 0. A client **SHOULD** publish all active chains and **SHOULD NOT** set bits of chains it does not read.

A client **SHOULD** skip the transaction when `keyFor` already reports the same key, `keyIndex` and bitmap as usable, and **SHOULD NOT** publish twice for one request (for example after a wallet timeout it **MUST** re-read `keyFor` before trying again).

When a chain becomes active, a client **SHOULD** offer holders whose bitmap lacks that chain's bit to publish the same key and `keyIndex` again with the bit added. This changes only `chains` and increments `version`.

### 14.4 Using a recipient's key

Before sealing to an endpoint, a client **MUST**:

1. resolve it (§12.2) on its home chain and read `keyFor` at a fresh pinned block under strict agreement;
2. require `suite == 1` and `usable == true`;
3. reject the key if byte 31 has its top bit set, if its little-endian value is ≥ 2^255 − 19, or if it is a low-order point (u = 0, 1, 325606250916557431795983626356110631294008115727848805560023387167927233504, 39382357235489614581723060781553021112529911719440698176882885853963445705823, or p − 1). Any X25519 error or an all-zero shared secret also means rejection;
4. require that the recipient's bitmap has the bit of the **sending chain** set, judged on the raw bitmap (an unknown bit does not count). Otherwise the recipient does not read that chain and the client **MUST NOT** send (`wrong-chain`).

When an endpoint has no usable key, a client **MAY** send it a public message (§15.2) from any active chain, only after telling the sender in plain words that everyone can read it, and **MUST NOT** fall back silently. Step 4 does not apply: without a usable key there is no bitmap, and the recipient's client reads every active chain (§18.2).

### 14.5 Key lifetime and rotation

- A key record is tied to the holder that published it; after a transfer `usable` is false until the new holder publishes;
- The same holder derives the same key for the same container, chain, hub and `k`;
- To rotate, publish with a higher `k`. Messages sealed to the old key remain readable by whoever holds it;
- `k` is 0..65535. A client **SHOULD** use `k = 0` first and, when rotating, `max(version, keyIndex + 1)` (using `keyIndex + 1` only when the current record is the holder's own usable key);
- A client opening older messages **MAY** try earlier `k` values of the same holder; a derived key is used only if its fingerprint matches a slot.

## 15. Payload

### 15.1 Header

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | Magic `0x54 0x53` (`TS`) |
| 2 | 1 | Format version `0x02` |
| 3 | 1 | Kind: `0x00` public, `0x01` sealed |

A payload with another magic, version (including `0x01` of draft v0.5) or kind, shorter than 4 bytes or longer than 16,000 bytes is `unsupported` and **MUST NOT** be interpreted further.

### 15.2 Public payload (kind `0x00`)

Bytes 4.. are the content (§16), in the clear.

### 15.3 Sealed payload (kind `0x01`)

| Offset | Size | Field |
|---|---|---|
| 4 | 32 | `E`: ephemeral X25519 public key |
| 36 | 24 | `N`: nonce |
| 60 | 32 | `D`: key commitment `SHA-256("TAP-10/commit/v2" ‖ K)` |
| 92 | 1 | `n`: number of key slots, 1 ≤ n ≤ 16 |
| 93 | 56·n | Slots, each `fingerprint (8) ‖ wrapped key (48)` |
| 93 + 56·n | rest | `C`: encrypted content including its 16-byte tag |

Let `P` be the first 93 bytes and

```
X = "TAP-10/X/v2" ‖ endpointID(to) ‖ endpointID(from) ‖ ref ‖ hub
```

where `to` is the recipient endpoint ID given to `send`, `from` the sender's endpoint ID (its chain is the sending chain), `ref` the 32-byte `ref` and `hub` the hub address.

**Sealing:**

1. Generate `e` (32 bytes), `E = X25519(e, 9)`, `N` (24 bytes) and `K` (32 bytes) from a cryptographically secure generator, fresh for every message;
2. Key list: the recipient's usable key (§14.4), then **SHOULD** also the sender container's own usable key if it belongs to the connected wallet, so the sender can read its sent messages. Keys **MUST** be distinct and pass §14.4 step 3;
3. `D = SHA-256("TAP-10/commit/v2" ‖ K)`; `P = 0x54 ‖ 0x53 ‖ 0x02 ‖ 0x01 ‖ E ‖ N ‖ D ‖ n`;
4. For each key `R` in order: `ss = X25519(e, R)` (reject all zero); `kek = HKDF-SHA256(salt = "TAP-10/wrap/v2", IKM = ss, info = E ‖ R ‖ X, L = 32)`; `wrapped = XChaCha20-Poly1305-Encrypt(kek, N, K, aad = P ‖ X)`; slot = `SHA-256(R)[0..8) ‖ wrapped`;
5. `S` = the slots; `C = XChaCha20-Poly1305-Encrypt(K, N, content, aad = P ‖ S ‖ X)`;
6. Payload = `P ‖ S ‖ C`, at most 16,000 bytes (content up to 15,835 bytes with one slot, 15,779 with two).

**Opening** (private key `r`, public key `R`; `to`, `from`, `ref` from the verified entry and event):

1. `damaged` if shorter than 93 bytes, `n` outside 1..16, shorter than `93 + 56·n + 16`, or `E` fails §14.4 step 3;
2. For each slot whose fingerprint equals `SHA-256(R)[0..8)`: derive `kek` and decrypt `wrapped`; the slot yields `K` only if decryption succeeds and `SHA-256("TAP-10/commit/v2" ‖ K) = D`;
3. No slot yields `K`: `damaged` if some fingerprint matched, otherwise `not-for-key`;
4. Decrypt `C` with `aad = P ‖ S ‖ X`; failure is `damaged` and nothing may be shown.

A client holding several keys tries each: `ok` if any opens, else `damaged` if any gave `damaged`, else `not-for-key`.

Because `to`, `from` (and so both chains), `ref` and the hub are bound into `X`, a payload does not open when replayed from another sender, to another recipient, with another `ref`, on another chain or through another hub. The commitment makes every reader obtain the same content. The sender can re-emit the same payload as a new message; clients show identical `(from, to, digest)` messages once (§18.4).

## 16. Content

Content is a UTF-8 JSON object (RFC 8259); surrounding whitespace is allowed.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `v` | number | yes | `1` |
| `kind` | string | yes | `"message"` |
| `subject` | string | no | At most 200 code points |
| `body` | string | yes | May be empty |
| `ts` | number | no | Sender-claimed milliseconds since the Unix epoch; informational |
| `attachments` | array | no | At most 4 attachments (§16.1) |

**Decoding**, in this order:

- `damaged` if not valid UTF-8, starts with `EF BB BF`, is not a JSON object, nests deeper than 32 levels, has a duplicate member name at any depth (after unescaping), or has an unpaired surrogate escape in any string or member name;
- `unsupported` if `v` is a number other than 1 or `kind` is a string other than `"message"`;
- `damaged` if `v` or `kind` is missing or of another type, `body` is missing or not a string, or `subject` is not a string;
- otherwise a message: `subject` is cut to 200 code points; a `ts` that is not an integer in 0..2^53−1 is ignored; unknown members are ignored.

**Attachments** never make a message `damaged`. Only the first 4 elements of an `attachments` array are considered; each that fails §16.1 is dropped, and the client **MUST** tell the reader how many were dropped (elements beyond the fourth count as dropped; a non-array `attachments` counts as one).

**Rendering:** `subject` and `body` **MUST** be rendered as plain text, never as HTML or markup. Bidirectional controls (U+061C, U+202A–U+202E, U+2066–U+2069), U+200B, U+200E, U+200F, U+2028, U+2029, U+2060–U+2064, U+FEFF, U+115F, U+180E, U+3164, U+FFA0 and C0/C1 controls other than line feed and tab **MUST** be made visible or removed. A client **MUST** show a full URL before opening it. The time of a message is its block time, not `ts`.

### 16.1 Attachment formats

| `type` | Fields | Rules |
|---|---|---|
| `image` | `mime`, `data`, `w`, `h` | `mime` is `image/webp`, `image/jpeg` or `image/png`; `data` is standard base64 with padding (length a multiple of 4) of 1..11,000 bytes whose leading bytes match the declared format; the **real** width and height read from the file header **MUST** be 1..2048 and **MUST** equal `w` and `h`. Rejected: animated PNG (an `acTL` chunk before `IDAT`), WebP `VP8X` with the animation flag (0x02), and JPEG other than baseline (the first SOF marker must be SOF0 or SOF1) |
| `native` | `chainId`, `amount`, `tx` | The chain's native coin sent to the recipient's container |
| `erc20` | `chainId`, `token`, `amount`, `tx` | A token transfer to the recipient's container |
| `erc721` | `chainId`, `token`, `tokenId`, `tx` | An NFT transfer to the recipient's container |

`chainId` is a safe integer > 0; `tx` a 32-byte transaction hash; `token` a 20-byte address; `amount` a non-zero decimal string without leading zeros (at most 78 digits); `tokenId` a decimal string (0 allowed). Hex is compared in lowercase.

An asset attachment is only a **claim**: the assets move in a separate transaction from the sender's wallet directly to the recipient's container; the hub never touches assets. The recipient's client verifies the claim (§19). A client **MUST NOT** offer a circuit NFT (a contract for which `factory.isCPU` is true, read under strict agreement; a failed read counts as true) as an attachment.

## 17. Message identity, order, replies and finality

- **Message ID** = `keccak256("TAP-10/msg/v2" ‖ uint256(chainId) ‖ hub ‖ endpointID(to) ‖ uint256(inboxIndex))`, where `chainId` is the chain whose hub holds the entry. It depends only on values read from storage under strict agreement;
- **Order:** by block time, then chain, then block number, then index;
- **Replies:** `ref` is chosen by the sender, public and unverified; a client **MUST NOT** assume the referenced message exists or involves the same parties, and groups conversations by the pair of endpoints, not by `ref`;
- **Finality:** a message is `pending` while its block is above the confirmed height `F` of its chain. `F` is obtained by asking every node for `eth_getBlockByNumber(<finality tag>)` with the chain's finality tag (§2.1), requiring answers from at least min(3, number of configured operators) different operators, and taking the **smallest**. When `F` cannot be obtained: on a chain whose tag is `finalized`, messages within 30 blocks of the pinned block are `pending`; on a chain whose tag is `safe`, every message is `pending`. A reorganization can change which message holds an inbox index, and therefore its ID. For a `pending` message a client **MUST NOT** verify attachments, record anything persistent about it, or offer it as a reply target. On a chain whose tag is `safe`, a client **MAY** leave out the `pending` indication when it shows a message, but **MUST** still apply these rules;
- `from` identifies a container, not a person; it proves only that the holder at that block, or a contract acting as holder (§13.4), controlled it.

## 18. Reading

### 18.1 Sources

The only source of messages is the inbox and outbox storage of a hub at the configured address, read with `eth_call`, plus `Sent` logs of that same address for payloads. Logs of any other address are not messages. No indexer is used or needed.

### 18.2 Listing

For its endpoint, on every active chain, a client reads under strict agreement at one pinned block per chain:

- `inboxCount(endpoint)` and `inboxPage(endpoint, start, n)`, newest page first;
- `outboxCount(container)` and `outboxPage(container, start, n)` for sent messages (on its home chain).

A client **MUST** read its inbox at least on the chains whose bit is set in its own bitmap, and **SHOULD** read it on every active chain: public messages to an endpoint without a usable key may arrive from any active chain (§14.4). The reference client reads every active chain.

Every entry **MUST** belong to the mailbox being read (the inbox entry's `to` is the reader's endpoint; the outbox entry's `from` is the reader's container); anything else is dropped and reported. A client **MAY** poll `inboxCount` and `outboxCount` with ordinary (non-strict) reads to detect new messages, but **MUST** reload through strict reads before showing anything, and **SHOULD** back off when counts keep changing.

### 18.3 Fetching payloads

For an entry at block `b`, a client asks **any one** node for the `Sent` logs of the hub in block `b` (`eth_getLogs` with `fromBlock = toBlock = b`, address = hub, topics `[Sent, to]`), or, if that node does not serve logs, for `eth_getBlockReceipts(b)`. It accepts a log only if it decodes as `Sent` from the hub with the entry's `to`, `from` and `inboxIndex`, and `keccak256(ref ‖ keccak256(payload))` equals the entry's digest. Otherwise it tries the next node. Only `ref` and `payload` are taken from the node.

The log's transaction hash is only a **hint** (`txHint`). Whoever uses it (§18.5, §19) **MUST** confirm it under strict agreement. A client **MUST NOT** cache a payload without a hint, and **MUST** drop a cached hint that failed confirmation, so that the next load asks another node.

### 18.4 Showing messages

- Messages from muted senders are not fetched;
- Messages with the same `(from, to, digest)` are the same payload sent again; a client shows one and **MAY** show the count;
- If the inbox and outbox reads give the same message ID with different digests, a reorganization happened between them: the client keeps one, marks it `pending` and reloads;
- To limit flooding, a client **SHOULD** fetch at most a few messages per page (the reference: 3) from each sender it has never written to, count the rest as folded, and let the user show them.

### 18.5 The sending wallet

The wallet that sent a message is determined from the message's own transaction, never from the circuit's current holder:

1. Read the receipt of `txHint` under strict agreement; require status 1, its block equal to the entry's block, and a `Sent` log from the hub with the entry's `to`, `from`, `inboxIndex`, `ref` and payload;
2. If the same receipt contains any ERC-721 `Transfer` log (topic0 `0xddf252ad…`, 4 topics), the sender is **indirect**;
3. Read the transaction under strict agreement. If `tx.to` is the hub, or `tx.to == tx.from` (an EIP-7702 account calling itself), the sending wallet is `tx.from`; otherwise the sender is **indirect**.

An indirect message may have been written by a contract the holder approved (§13.4). A client **SHOULD** say so next to the message. When the sending wallet of a correspondent changes, or differs from the one recorded for that correspondent on first contact, a client **SHOULD** show that the circuit changed hands.

### 18.6 Status codes

| Status | Meaning |
|---|---|
| `ok` | Public, or sealed and opened, and content decoded |
| `unsupported` | §15.1 or §16 unsupported |
| `damaged` | §15.3 or §16 damaged |
| `not-for-key` | No slot opens with any key the client holds |
| `pending` | Above the finalized height (§17) |
| `unavailable` | Answers disagreed, too few nodes answered, or no node returned a payload matching the digest; retry later |
| `stale-block`, `clock-skew` | §5.3 (`clock-skew` is no longer produced since v1.1) |
| `wrong-chain` | Nodes are not on the expected chain, the recipient does not read the sending chain (§14.4), or a name's area code denotes another chain (§4.1) |
| `ambiguous` | Input without chain information resolves on more than one chain (§4.1); the user must give a name with an area code |
| `hub-mismatch` | The hub's container or endpoint differs from the resolved one (§12.2) |
| `hub-missing` | No hub at the configured address |
| `hub-changed` | The hub implementation is not accepted (§13.8) |
| `circuits-changed` | The processor implementation changed (§13.8) |
| `no-key`, `key-stale`, `bad-key` | No key; key not usable; key fails §14.4 step 3 |
| `key-changed` | The recipient's key or holder differs from the last exchange (§20 step 3) |

Status codes are only ever added.

## 19. Asset attachment verification

A client verifies every asset attachment of message `m` on the chain named by its `chainId`; an attachment for a chain the client does not read is shown as unverified (`other-chain`). All reads are under strict agreement. The checks run in this order and the first that applies is the result:

1. `pending` — `m` is pending (§17);
2. `mismatch` — every node agrees that there is neither a receipt nor a transaction for `tx`;
3. `unavailable` — the receipt or the transaction could not be read under strict agreement;
4. `mismatch` — the receipt status is not 1;
5. `unverifiable` — `native` only: `tx.to` is not the recipient's container (an internal transfer from a contract wallet cannot be seen);
6. `mismatch` — no matching transfer: for `native`, `tx.value ≠ amount`; for `erc20`, no `Transfer` log emitted by `token` to the container with exactly 3 topics and data equal to `amount`; for `erc721`, no `Transfer` log emitted by `token` to the container with 4 topics and topic3 equal to `tokenId`;
7. `late` — the transfer's block is later than `m`'s block;
8. `unavailable` — the sending wallet of `m` (§18.5) could not be determined;
9. `indirect` — the sender of `m` is indirect (§18.5);
10. `third-party` — the payer is not the sending wallet. The payer is `tx.from` for `native` and the `Transfer` log's `from` for tokens; a transfer out of the sender's own container counts as paid by the sender only if `tx.from` is the sending wallet;
11. `unavailable` — the transfer's block time could not be read;
12. `stale` — the transfer's block time is more than 3,600 seconds before `m`'s block time;
13. `crowded` — walking the same inbox backwards from `m`, more than 60 entries lie at or after the transfer's block;
14. `not-first` — one of those earlier entries is from the same sending container, or its message (§18.5) has the same sending wallet (an earlier entry whose wallet cannot be determined makes the result `unavailable`);
15. `ok` — otherwise.

Only `ok` proves that the sender paid this recipient for this message. A client **SHOULD** show `ok` as positive only for tokens on its list of known contracts; any other token is shown neutrally, and a token whose symbol contains non-ASCII characters or imitates a known symbol **SHOULD** be flagged as a possible fake. Within one message, a second attachment with the same `tx` is a repeat and **MUST NOT** be counted again. `mismatch`, `not-first` and repeats **SHOULD** be shown as warnings.

## 20. Sending

1. Resolve the recipient (§12.2) on its home chain at a fresh pinned block and apply §14.4. The hub of the recipient's home chain **MUST** be accepted (§13.8), otherwise the client **MUST NOT** send;
2. Resolve the sender's own endpoint; require `opened` and `holder` equal to the connected wallet; require the hub to be accepted and the processor implementation unchanged (§13.8);
3. If the client has exchanged messages with this recipient before, compare the recipient's key, `keyIndex` and holder with what it recorded; on any difference show `key-changed` and require confirmation. After a successful exchange, record them;
4. If attaching assets: send each transfer from the holder's wallet directly to the recipient's container and record its hash locally **immediately**, before waiting for inclusion. A recorded transfer **MUST NOT** be sent again; it is removed only when every node agrees the transaction reverted, or that it was cancelled (a different transaction with the same nonce was included). If the wallet speeds it up, the replacement's hash replaces the recorded one. Recorded transfers go with the next message to the same recipient, and **SHOULD** be sent within an hour (§19 `stale`);
5. Build the content (§16) and payload (§15) with `to` = the recipient's endpoint ID, `from` = the sender's endpoint ID and the `ref` passed to `send`;
6. Immediately before signing, read the recipient's `keyFor` again; if `version` changed, go back to step 1;
7. Call `send(sender processor contract, sender #ID, recipient endpoint ID, ref, payload)` from the holder's wallet on the sender's home chain; the message is written to that chain's hub whatever the recipient's chain. A client **SHOULD** ask the wallet to switch to that chain first and **MUST NOT** submit the transaction on any other chain;
8. If the outcome is unknown (timeout, wallet error), record the transaction hash and **MUST NOT** allow another send from the same container and wallet until the transaction is confirmed or every node agrees it will not be included.

## 21. Change rules

This section answers: if I build on TAP-10, what will change, what will not, and how will I find out.

**Never changes.** Changing any of these would make a different standard:

1. The on-chain names of §3.1, including the `.tape` suffix, and the rule that the URL host is the complete on-chain name (§3.2);
2. The processor number (the index in `factory.cpuAt`, from 0, append-only) and the #ID (the circuit's token ID);
3. The bitmap bits and area codes of §2.1; new chains are only appended;
4. The derivation of a container from a processor contract and #ID; a client never accepts a container someone reports (§4);
5. The verification rule of §7.1: a length or SHA-256 mismatch means the file is not displayed;
6. Agreement (§5.2): disagreement means rejection, never a majority vote;
7. The names and meanings of status codes (§4.4, §6.4, §18.6, §19); codes are only ever added;
8. For payload format `0x02`: the endpoint ID of §12.1; the text, labels and steps of §14.2; the payload layout, labels and steps of §15; the message ID of §17; the hub's write interface, events, storage layout and authorization rule (§13). Anything else that must differ gets a new format version, suite or hub, and clients keep reading the old ones.

**What changes, and how:**

| What | Who changes it | How it is announced | What clients do |
|---|---|---|---|
| Accepted implementations (Deployments) | The contract owner upgrades; the TAP editors merge the new list into this TAP | A pull request to this TAP and a release of each reference implementation, stating old and new addresses and where the review is | Update. A client that has not updated returns `store-changed` or `hub-changed` for a new implementation (fail-closed); this is by design |
| A new chain | The same, plus a new row in §2.1 | The same | Update to use it |
| Default node lists | Each implementation | Its release notes | Optional; users can use their own nodes |
| The payment fee (`monthlyFee`) | The contract owner | The on-chain `FeeChanged` event | Nothing; clients read it from the chain |
| Input forms (§3.4), shell requirements (§8), caching (§11) | This TAP | A new version | A new version may only loosen input forms and tighten security requirements |
| A new site store version | The contract owner and this TAP | A new version; old store addresses stay listed | Look up in order, first hit wins (§6.1) |

Versions follow TAP-01 §6.3. Contract addresses are not tied to versions of this TAP.

## Rationale

- **One TAP for both layers.** A name must mean the same container whether a user opens its site or writes to it. The reference implementations already share one identity core (`kernel/src/identity.js`) for this reason; one text keeps the rules from drifting apart. The messaging layer keeps the number TAP-10 because the labels `TAP-10/key/v2`, `TAP-10/wrap/v2`, `TAP-10/commit/v2`, `TAP-10/X/v2` and `TAP-10/msg/v2` are inside deployed key derivation, encryption and message IDs.
- **Processor numbers and area codes in names.** #IDs repeat across processors and processor numbers repeat across chains. Names use numbers rather than processor names (not unique) or addresses (long, error-prone). BNB Smart Chain keeps names without an area code so that every existing name stays valid and each of its containers keeps exactly one name.
- **The key text keeps names without area codes** (§14.2). The text is part of key derivation; adding an area code would change every key already derived on Base and X Layer. The `Chain ID` line, the container resource and the endpoint ID in the derivation already identify the container exactly.
- **No majority vote.** A vote lets a majority of colluding or misconfigured nodes win silently. Rejecting on any disagreement turns such an attack into unavailability, which users notice, and counting operators instead of URLs stops one operator from counting several times.
- **Freshness by block lag, not by clock.** A clock check fails on devices with a wrong clock and cannot be fixed by the user in the moment; a block-lag check compares only numbers reported by the nodes. What it cannot detect is discussed under Security Considerations.
- **Pinned implementations, fail-closed.** The site and hub contracts are upgradeable until sealed. Pinning the accepted implementations in the client means an upgrade takes effect only after the new code is reviewed and the list is updated in public.
- **Off-chain data allowed, off-chain code not** (§8.5). SPEC.md v0.2 blocked all off-chain requests in preview mode. Sites that connect wallets through relays, stream video or call public APIs cannot work that way, so the reference shells changed on 2026-09-19 (TapeKit `489956e`) to allow off-chain data while recording it, and to keep code on chain. The "100% on-chain" indication (§9) keeps the difference visible.
- **Public messages to any chain** (§14.4). An endpoint without a key has no bitmap saying which chains it reads; the reference client reads every active chain, so allowing public messages from any chain matches what recipients actually see.
- **Deployments in the TAP.** Clients must pin addresses and implementations; putting them in the TAP gives every implementation the same list and a public history of changes.

## Backwards Compatibility

This TAP replaces two documents. Both were drafts.

**From tape:// specification v0.2** (TapeKit `SPEC.md`, 2026-09-13; BNB Smart Chain only):

- Names on Base and X Layer carry an area code (§3.1); names on BNB Smart Chain are unchanged;
- Input without chain information is resolved on every active chain, with the new outcome `ambiguous` (§4.1);
- Pinning counts operators, and a stale pinned block is rejected (§5.3);
- Off-chain data may be allowed and recorded instead of blocked; scripts must still come from the chain (§8.5). A gateway no longer claims "100% on-chain" (§9);
- Cached files are re-hashed before use, and resolution results are no longer stored where site code can write (§8.3, §11). v0.2 said cached files need not be verified again;
- Gateways no longer let users set nodes on the status page, because site code could change those settings (§5.1, §8.3);
- The test vector for `4246.0.tape` changed because the site owner updated the file (Test Cases).

Clients built for v0.2 resolve BNB Smart Chain names exactly as before. They reject names with an area code as unknown input.

**From TAP-10 v1.0** (TapeKit `9a7d25a`, 2026-09-18, withdrawn the same day):

- Base and X Layer are active; names use area codes instead of the v1.0 suffix form (`#15324@30.base`);
- Finality uses each chain's finality tag and counts operators; freshness uses block lag and `clock-skew` is no longer produced;
- A public message to an endpoint without a usable key may come from any active chain; clients should read their inbox on every active chain;
- The hub contracts, interface, storage, key derivation, payload format `0x02`, content, message IDs and attachment verification are unchanged, so every message and key written under v1.0 remains valid.

Appendix C lists the changes in detail.

## Test Cases

### Access layer

Resolved with the reference kernel at TapeKit `f1831a4` against mainnet, read-only, on 2026-09-27 between 19:30 and 19:35 UTC (BNB Smart Chain blocks 124389066–124389111, Base 51874039–51874048, X Layer 71768388–71768407). Every implementation **MUST** give the same results at those blocks. Results that depend on later chain state (payment expiry, file updates) are marked.

| Input | Expected |
|---|---|
| `4246.0.tape`, `4246.0`, `#4246@0`, `tape://4246.0/`, `0x50A994E71615474b55559fF4F500928fbc339DD9#4246` | BNB Smart Chain, processor 0 (`Genesis CPU`, `0x50A994E71615474b55559fF4F500928fbc339DD9`), #4246, container `0x86DDaEF00401E3F10418398D67D7189fc458eA95`, opened. `ok`, paid through the container, until 2026-10-08T14:34:51Z |
| `0x86DDaEF00401E3F10418398D67D7189fc458eA95` | Reverse-resolves to `4246.0.tape` |
| File list of `4246.0.tape` | Only `index.html`; fallback `index.html` |
| `index.html` of `4246.0.tape` | 19,770 bytes, SHA-256 `0x275c896aa347670b19e8ed11256165dbabadb0f9e3c947370b591130acb507b8`, updated 2026-09-21T09:00:31Z; `ok` |
| `tape://4246.0.tape/some/route` | Lands on `index.html` (§7.2 step 4c) |
| `tape://4246.0.tape/missing.png` | Not found (has an extension) |
| `1.3.1`, `#1@3.1`, `0x4591b393399452eA24ECB10424CdBA194F1c4E64` | Base, processor 1 (`0x0565EA48CA41Ae559d8d491dbb0a9ec945DB551b`), #1, container `0x4591b393399452eA24ECB10424CdBA194F1c4E64`, opened, `unpaid` |
| `1.3.5` | Base, processor 5, #1, container `0xa1a56711bE1B3DdfbB5384C025a17C435B8DFff7`, `not-opened` |
| `#1@2.1` | X Layer, processor 1 (`0x0565EA48CA41Ae559d8d491dbb0a9ec945DB551b`), #1, container `0x374fa57399f356030847Eb0c56851bE9a1194E5D`, `not-opened` |
| `0x0565EA48CA41Ae559d8d491dbb0a9ec945DB551b#1` | `ambiguous` (the processor exists on Base and X Layer) |
| `1.2.344` | `no-such-cpu` on X Layer |
| `1.999999` | `no-such-cpu` |
| `999999999.0` | `no-such-token` |
| `0x000000000000000000000000000000000000dEaD` | `not-tapeout` |
| `04246.0`, `0.0.tape`, `4246`, `1.0.5`, `1.1.5`, `1.4.5` | Input error |
| Accepted implementations | Every site store and payment contract of §2.2 is accepted on all three chains |

`kernel/test/unit.test.mjs` in TapeKit covers the name, URL, host-label and path rules offline, including every input form of §3.4 with area codes; `kernel/test/mainnet.test.mjs` covers the BNB Smart Chain cases above (its file vector is the older 756-byte `index.html` of 2026-09-13 and has to be updated with this table).

### Messaging layer

`send/module/test/vectors.json` in TapeKit (unchanged from v1.0 to commit `f1831a4`) contains, and every implementation **MUST** reproduce:

1. §14.2 for `#4246@0`, container `0x86DDaEF00401E3F10418398D67D7189fc458eA95`, a fixed test wallet and a test hub, with `k = 0` and `k = 1`: the text, its bytes, length and SHA-256, the signed hash, the signature, normalized `r ‖ s`, the HKDF info, the seed and the public key;
2. §15.3 with fixed `e`, `N`, `K`, two recipient keys, `to`, `from`, `ref` and hub: `E`, `D`, `X`, `P`, per slot the shared secret, `kek`, fingerprint and wrapped key, `C` and the payload;
3. §15.2 for the same content;
4. §17 message IDs, including one for a chain other than 56;
5. §16 decoding cases (valid; duplicate member, plain and escaped; invalid UTF-8; byte order mark; unpaired surrogate in a value and in a member name; missing `v`; `v` as a string; future `v`; other `kind`; missing `body`; depth 32 and 33; surrounding whitespace; long `subject`);
6. §15.3 opening results, including an old version-1 payload (`unsupported`);
7. §14.4 rejected keys and §14.2 signature variants.

`send/module/test/crypto.test.mjs` additionally covers attachment rules (§16.1) including image headers for PNG, WebP (VP8, VP8L, VP8X) and JPEG, animated and progressive rejection, and endpoint validation; since 2026-09-19 it also covers display labels with area codes, the chain an input belongs to, and per-chain client instances.

## Reference Implementation

All in [TapeOutProtocol/TapeKit](https://github.com/TapeOutProtocol/TapeKit) at commit `f1831a44160e7a5a31385c05f1cdf64f25619516` (2026-09-20), MIT licensed. The later commit `da14c93` (2026-09-27) changes only a gateway end-to-end test.

| Component | Location | Covers |
|---|---|---|
| Chain parameters | `kernel/src/config.js` | Per chain: nodes and their operators, area code, finality tag, max pin lag, addresses and accepted implementations (§2, Deployments) |
| Identity core | `kernel/src/identity.js`, `kernel/src/name.js` | §3, §4; shared by both layers |
| Node client | `kernel/src/rpc.js` | §5: default and strict agreement, operator counting, pinned block and pin lag |
| Kernel | `kernel/` | §6, §7, §11: multi-chain routing, implementation pinning, activation, file verification, paths, caching |
| Web viewer | `viewer/` | Preview-mode shell (§8.1 opaque origin) |
| Browser extension | `extension/` | Address-bar keyword `tape`, sandboxed rendering |
| Service Worker gateway | `sw-gateway/` | §8.8, §9, §10 |
| Hub contracts | `send/contracts/` | §13: `DeWebHub`, `DeWebAdmin`, `DeWebProxy`, `DeWebBoot`; unit, fuzz, invariant, fork and pinned-address tests for all three chains |
| Messaging module | `send/module/` | §12, §14–§19: keys, payload, content and attachments, strict chain reads, finality; test vectors |
| Messaging client | `apps/tapesend/` | §18–§20: web, desktop (Electron) and mobile (Capacitor); reads the inbox on every active chain, switches the wallet to the sender's chain, blocks sending when a hub is not accepted |

Known gaps between this text and the reference implementation at that commit:

- `chainIdOfInput` in `send/module/src/chain.js` resolves input without chain information on BNB Smart Chain only; §4.1 requires every active chain;
- The tape:// kernel does not make the `eth_chainId` check that §5.4 recommends for shells;
- `send/README.md` still describes Base and X Layer as planned;
- The test vectors do not yet include a Base or X Layer container for §14.2, and `kernel/test/mainnet.test.mjs` still expects the 756-byte `index.html`.

## Deployments

Read back on mainnet on 2026-09-27 at 19:34 UTC, read-only, from two operators per chain at one pinned block: BNB Smart Chain block 124389612, Base block 51874173, X Layer block 71768710. Every value below matched on both operators, and no hub or factory was sealed. Anyone can repeat the check with `eth_getCode`, `eth_getStorageAt` and `eth_call` (the ERC-1967 implementation slot is `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`), or recompute the hub addresses from source (§13.2).

### TapeOut and site contracts

| Contract | BNB Smart Chain (56) | Base (8453) and X Layer (196) |
|---|---|---|
| Processor factory (UUPS proxy) | `0x68224F668083c29e9800Be2a646d42d18cedF7e2` | `0x1f09DAeFA827f02CBb40967cc91b259763760761` |
| Factory implementation (seal constant, §13.8) | `0xa68cCF4931d98ad0A4BE15eE40542eDc0DEc6422` | `0x74956236Ab64eD143933040B4137E8A352e4d17b` |
| Circuit beacon | `0xf8D6d8EB894d6971c8976Ad8b4971cbEFE028156` | `0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C` |
| Circuit implementation | `0x8E1D125Def6d3826C278299273a0760D47626068` | `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2` |
| Processor proxy code hash | `0xd8c4b0216e0aadd615fbd134465b6af060a11769edc7c844d8f14d1b8a783992` | `0x57aa306fd0be97087da3534e03398f5ff4efd533b5be4e45a405ce86fa6717d5` |
| Container opener | `0x021745DE2f42A7839d96f2d3634d0294487D81F1` | `0x536adD8F30f03b69f6fbF29d425A816A0dC50106` |
| ERC-6551 registry | `0x000000006551c19487814612e58FE06813775758` | the same |
| Container implementation | `0xAf4E78a2257C9c5480c2F8310E3b00437260751d` | `0xAC4F791353eE9F06e2C50Ae4C34680D28Ea52a57` |
| Container payments table | `0xc0C643eb9820eF208Ea38bb2c8E8377047D9fa4c` | `0x13b8AFa4Fd1b29B09D23A57A75ba8D3078d44858` |
| Site store `SiteRegistry` (UUPS proxy) | `0xd006ffdd5Ae313B17729621A00999cD3C71CE5e6` | `0xd6EFb7adCc9c83dC4924Ad56f6a8E4e969b9ADB6` |
| Accepted site store implementations | `0x1d279D138A4D803378a7d4557c056f1beD53c261` | `0xa85c4143d1D4A77f54b8e4ecC9E6D1418Afea45f` |
| Payment contract `DomainBinding` (UUPS proxy) | `0x861EE183de2BBE4a6ecf9D15812C123b566a3DB7` | `0x68809Fd2fb343aA57D0aeB7f33Defe477c9666f9` |
| Accepted payment contract implementations | `0xaa226181a6588d3f9AC0035e5f3dBaF311039bCE` (current since 2026-09-13), `0x4E8684EaEA48b524245B2191DeE451eAa1c1cA94` (previous, kept for rollback) | `0x5eBF29b80789e548907C707530C3C7607C4347Df` |

The TapeOut and site contracts on Base and X Layer were deployed by the same deployer in the same order, so their addresses are equal on both chains; the constructor arguments and the fee constants differ. Their processor code hash differs from BNB Smart Chain's because the Layer 2 factory was compiled separately.

### DeWEB hub

| Item | Value |
|---|---|
| Hub (proxy), every chain | `0xe61A9C7213a6Aa616C246a2B569e555B417b25ee` |
| Boot implementation, every chain | `0xC0D28CA8689248B0bed26cC0aa328CF16Aa4401e` |
| Owner, every chain (until sealed) | `0x571d447f4f24688eC35Ccf07f1D6993655F6aF15` |

Hub implementations (a client accepts only the current one on each chain, §13.8):

| Chain | Version | Address | State |
|---|---|---|---|
| BNB Smart Chain | v3 | `0x80aFE7B77F2dFD08e9feab7675780baC34a7EE85` | **Current**, since block 122623031 (2026-09-18) |
| BNB Smart Chain | v2 | `0x7dF03218910E0F37FC3A8DA8792831ab7580340F` | Replaced; not accepted (it allowed an upgrade to a proxy still in its boot phase) |
| BNB Smart Chain | v1 | `0xf5f18e3fe811b9b382C90539d14440654E789d92` | Replaced the same day; not accepted |
| Base | v3 | `0x38A2d320b8984Bbac9b0a2691B6c0FD829A23867` | **Current**, since 2026-09-19 |
| X Layer | v3 | `0xdCC57797089eBD9f26e686379A4323f353a3F9C6` | **Current**, since 2026-09-19 |

Their immutable constructor arguments are the chain's own values from the table above: `expectedChainId` (56, 8453 or 196), `registry` (the ERC-6551 registry), `accountImplementation` (the container implementation), `factory`, `payments` (the container payments table), `circuitBeacon`, `circuitImplementation` and `circuitCodehash` (the processor proxy code hash).

### Seal status

As of the reads above: the hub is **not sealed** on any chain (`isSealed()` 0, owner as listed), and the processor factory is **not sealed** on any chain (`isSealed()` 0). The factory implementation, the beacon's owner (the factory) and the beacon's implementation match the seal constants on every chain. The site store and the payment contract are upgradeable proxies. Until every contract this TAP depends on is sealed or no longer upgradeable, TAP-10 cannot become Final (TAP-01 §5.1), and the trust described under Security Considerations applies.

## Security Considerations

### Both layers

- **Colluding nodes.** Agreement defeats a single lying node, not all configured operators lying together. Clients seeking stronger guarantees **SHOULD** support self-hosted nodes, or verify state proofs against block headers with `eth_getProof`;
- **Few operators.** Agreement is only as independent as the configured operators. The reference client's default nodes for X Layer belong to two operators, one of which (OKX) also runs the X Layer sequencer; there, strict agreement requires both, and either one can make reads `unavailable`. Users can add their own nodes;
- **Freshness without a clock.** The pin-lag check (§5.3) works on devices with a wrong clock, but it cannot notice when every configured operator is behind at the same time; like agreement, it assumes the configured operators are not all wrong together;
- **Upgradeable contracts.** Until sealed, the owners of the site store, the payment contract, the processor factory and the hub can change what those contracts do. Pinned implementations (§6.1, §13.8) make a lasting change visible and fail-closed, but an upgrade can rewrite storage within one transaction and restore an accepted implementation (§13.8);
- **Look-alike names and endpoints.** Names are digits only, but `4246.0` and `4264.0`, or two area codes, are easy to confuse. Clients **MUST** always show the complete name, including the area code, and **SHOULD** show the processor name and the holder.

### Access layer

- **A malicious site owner.** "Verified" means only that the bytes match the chain, not that the site is trustworthy. That is why the name must always be visible (§8.7) and wallet requests must show it (§8.4);
- **Off-chain data.** A shell that allows off-chain data (§8.5) lets a site send whatever it learns to any server, and load content that is not on chain and not verified. Scripts stay on chain, and recording makes the traffic visible, but a shell that allows off-chain data cannot promise privacy from the site;
- **Site code on the gateway's origin.** Under a Service Worker gateway, site code shares an origin with the gateway's storage. §8.3 and §11 exist because site scripts were shown (audit, 2026-09-20) to plant cached bytes and resolution results that the gateway would otherwise have vouched for;
- **Listing freeze.** While a circuit is listed on the market its owner cannot change the site, so buyers get what they saw. Reading is unaffected;
- **The fee can be bypassed** (§6.3); state it plainly.

### Messaging layer

- **Metadata is public and permanent.** Who wrote to whom, when, how much, and which chains are used are visible to everyone. Only sealed content is protected; lengths are not padded; slot fingerprints reveal which key a message was sealed to;
- **No forward secrecy.** Whoever later obtains a private key, or the signature it came from, can open every message sealed to it;
- **The signature is the key.** Anyone holding the §14.2 signature holds the key. Shells that inject a wallet refuse to produce it (§8.4). The official client **MUST NOT** be served from a domain that serves user sites;
- **Hub owner until sealed.** The owner can replace the implementation and, within one upgrade transaction, rewrite key records or inbox entries and restore an accepted implementation (§13.8). Checking the implementation address alone cannot prove storage was untouched. Seal as early as the protocol allows, after the factory;
- **Factory until sealed.** Whoever controls the factory can temporarily replace the processor implementation, write as any container and revoke keys without a trace the hub can see. State planted before the factory seal can still move circuits later, as ordinary transfers;
- **Approved contracts.** A contract approved for a circuit NFT can write as its container within one transaction and revoke its key (§13.4). Clients flag such messages (§18.5). Holders **SHOULD** approve only single tokens and revoke approvals after use;
- **Flooding.** Anyone with an opened container can append to any inbox, and entries are never removed; a message costs its sender only gas. Clients rely on stranger limits and muting (§18.4); a full scan of a flooded inbox costs one `eth_call` per 200 entries;
- **Layer 2 finality.** On Base and X Layer a single sequencer produces the latest blocks, and they can still be rewritten until they are posted to Ethereum; this is why §17 uses `safe` there. Reads are pinned near the latest block for responsiveness (§5.3), so a message a client shows can still disappear, or move to another inbox index, before it is confirmed;
- **Strict reads.** Identity, keys, inbox entries, receipts and seal status use strict agreement, so forging them requires every answering node. A single node can only make reads `unavailable` or withhold a payload;
- **Asset claims.** An attachment proves a transfer, not intent. §19 binds it to the wallet that sent the message, in time and to the first message; it cannot prove what the payment was for, and it does not cover payments made by contract wallets;
- **Transfers of circuits.** A buyer inherits the container and its correspondents. §20 step 3 and §18.5 make the change visible; a message sealed just before a sale can still be readable by the seller;
- **Rendering and randomness.** Content is attacker-controlled (§16). Reusing `(kek, N)` or `(K, N)` breaks confidentiality.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).

## Appendix A. Access-layer contract interfaces

A kernel needs only the read-only functions below. Addresses are under Deployments; the interfaces are the same on every chain. Selectors are the first 4 bytes of `keccak256(signature)`; the reference kernel lists them in `kernel/src/selectors.js`, and its unit tests recompute them.

**Processor factory:** `cpuCount() → uint256`; `cpuAt(uint256 i) → address` (reverts when `i ≥ cpuCount()`); `isCPU(address) → bool`.

**Container opener:** `accountOf(address circuits, uint256 tokenId) → address` (deterministic ERC-6551 address, valid before the container is deployed); `isOpened(address circuits, uint256 tokenId) → bool`.

**Processor contract (ERC-721):** `ownerOf(uint256 tokenId) → address` (reverts when the #ID does not exist); `name() → string` (display only).

**Container (ERC-6551 account):** `token() → (uint256 chainId, address tokenContract, uint256 tokenId)`; the result must be recomputed with `accountOf` and compared (§4.3).

**Site store `SiteRegistry`:**

| Function | Returns | Notes |
|---|---|---|
| `fileInfo(address container, string path)` | `(uint32 size, string contentType, bytes32 sha256Hash, uint40 updatedAt, uint256 chunkCount)` | `chunkCount == 0`: no such file; all-zero `sha256Hash`: no hash declared |
| `read(address container, string path)` | `bytes` | Whole file; reverts `NoSuchFile()` if absent |
| `readRange(address container, string path, uint256 offset, uint256 len)` | `bytes` | Empty when `offset ≥ size`; `len` is clipped to the end of the file |
| `pathCount(address container)` | `uint256` | |
| `pathsRange(address container, uint256 from, uint256 n)` | `string[]` | Paged list |
| `paths(address container)` | `string[]` | All paths; avoid on large sites |
| `fallbackPath(address container)` | `string` | §7.2 step 4c |
| `isOpenedContainer(address container)` | `bool` | |
| `implementation()` | `address` | **Not** for pinning (§6.1) |

Writes (for site owners; the holder, or an operator set with `setOperator`): `putFile(address container, string path, string contentType, bytes32 sha256Hash, bytes data)` writes the first chunk (at most 24,000 bytes) and replaces an existing file; `appendChunk(address container, string path, uint256 expectIndex, bytes data)` appends a chunk when `expectIndex` equals the current chunk count; `removeFile(address container, string path)`; `setFallback(address container, string path)`; `setOperator(address container, address op, uint256 ttl)`. A file has at most 350 chunks. Events: `FileSet(address indexed container, string path, uint32 size, bytes32 sha256Hash, string contentType)`, `FileRemoved(address indexed container, string path)`, `FallbackSet(address indexed container, string path)`, `OperatorSet(address indexed container, address operator, address setBy, uint40 until)`.

**Payment contract `DomainBinding`:**

| Function | Returns | Notes |
|---|---|---|
| `isLive(string name, address container)` | `bool` | This name for this container is paid and not expired |
| `paidUntil(bytes32 nameHash, address container)` | `uint40` | `nameHash = keccak256(name)` |
| `isContainerLive(address container)` | `bool` | Any name or domain of this container is paid and not expired; reverts on implementations that lack it |
| `containerPaidUntil(address container)` | `uint40` | |
| `monthlyFee()` | `uint256` | Fee per 30 days, in the chain's native coin (wei) |
| `bind(string name, address container, uint256 months)` payable | — | §6.3. Only the container's effective holder may call (holds the circuit NFT, container opened, not listed on the market); `months` 1–120, at most ten years ahead; non-refundable; the name must be lowercase and contain a dot. As described in the tape:// specification v0.2, Appendix B.6 |
| `syncContainer(string name, address container)` | — | Anyone; can only raise `containerPaidUntil` |
| `unbind(string name, address container)` | — | Stops this name; no refund; does not lower the container-level expiry |

Events: `Bound(bytes32 indexed domainHash, string domain, address indexed container, uint40 paidUntil, uint256 paid)`, `ContainerPaid(address indexed container, uint40 paidUntil)`, `Unbound(bytes32 indexed domainHash, address indexed container)`, `FeeChanged(uint256 monthlyFee)`.

## Appendix B. Shell compliance checklist

- [ ] Accepts the input forms of §3.4, including area codes, and displays the on-chain name
- [ ] Resolves input without chain information on every active chain and reports `ambiguous`
- [ ] Adopts reads only when two operators agree; any disagreement is rejected
- [ ] Pins all reads of one site open to one block and rejects a stale pinned block
- [ ] Pins the site contract implementations per chain; a mismatch is `store-changed`
- [ ] Verifies every file's length and SHA-256, including cached files
- [ ] Displays only sites in state `ok`
- [ ] One independent origin per site, or an opaque origin for preview; sites cannot be framed by other origins
- [ ] Site code never runs in a privileged context
- [ ] No wallet in preview mode; wallet requests show the on-chain name; the TapeSend key signature is refused
- [ ] Scripts only from the chain; off-chain requests recorded and listed; "100% on-chain" only when §9 holds
- [ ] Resolution results, blocklists and node settings are out of reach of site code
- [ ] Blocklist consulted on every resolution; reporting supported
- [ ] (Service Worker gateways) open-source bootstrap without external resources; script-free, frame-proof gateway pages that echo nothing; `/sw.js` and `/.tape/` reserved; domain on the Public Suffix List

## Appendix C. History

**Access layer.** tape:// specification v0.1 and v0.2 (TapeKit `SPEC.md`, 2026-09-13): names, resolution, verification and shell isolation for BNB Smart Chain. This TAP replaces v0.2; the changes are under Backwards Compatibility.

**Messaging layer, draft v0.5 (2026-09-17) to v1.0 (2026-09-18):**

- The single-chain `TapeSendHub` with an address `to` is replaced by the DeWEB hub: endpoint IDs carry the chain ID; the hub keeps an on-chain inbox and outbox; `send` returns the inbox index; `publishKey` takes a receiving-chains bitmap; `keyFor` returns the endpoint and bitmap and zeroes key fields when unusable;
- The hub has the same address on every chain (boot implementation + proxy) and is upgradeable until sealed, with `selfAddress` and `proxiableUUID` checks;
- Payload format `0x02`: all labels are `v2`, and `X` binds endpoint IDs instead of addresses and a separate chain ID;
- Key derivation binds the endpoint ID; `Chain ID` in the text is the container's home chain;
- Message ID is computed from storage (`chainId`, hub, `to`, inbox index) instead of the transaction hash and log index;
- Content gains `attachments` (images and asset claims) with the verification rules of §19;
- Finality, the sending wallet, indirect senders and stranger folding are specified;
- The indexer and notification interfaces (v0.5 §10, §11) are removed.

**Messaging layer, v1.0 (2026-09-18) to this version:**

- **Chains:** Base (8453) and X Layer (196) are active (§2.1), with their hub implementations, constructor arguments and factory seal constants (Deployments). The chain table gains area codes, finality tags and max pin lag;
- **Names:** on chains other than BNB Smart Chain, names and display forms carry an area code (`#1@2.344`, `1.2.344`, `1.2.344.tape`) instead of the short-name suffix of v1.0 (`#15324@30.base`); a name with an area code resolves only on its own chain (§3.1, §4.1);
- **Keys:** the signed text keeps the name without an area code on every chain (§14.2, stated explicitly, not changed); clients offer to re-publish a key when a chain becomes active (§14.3); a public message to an endpoint without a usable key may be sent from any active chain (§14.4);
- **Finality:** uses each chain's finality tag (`finalized` or `safe`), counts operators instead of nodes, and has no fallback height on `safe` chains; clients may hide the `pending` indication there (§17);
- **Pinned block:** pinning counts operators, and freshness is checked by block lag instead of the client clock (§5.3); `clock-skew` is no longer produced (§18.6);
- **Resolution:** input without chain information is resolved on every active chain, with the new status `ambiguous` (§4.1, §18.6);
- **Reading and sending:** clients should read the inbox on every active chain (§18.2); sending checks the hub on the recipient's home chain and writes on the sender's home chain (§20);
- **Security Considerations:** freshness without a clock, Layer 2 finality and few operators;
- **Document:** type `Standards` as defined in TAP-01 (v1.0: `Standards Track`); RFC 8174 added; references point to TapeKit at a fixed commit;
- **Unchanged:** the hub contracts, interface, storage and authorization (§13.1, §13.3–§13.7), key derivation (§14.1, §14.2), payload format `0x02` (§15), content and attachments (§16), message IDs (§17), asset attachment verification (§19) and the test vectors (Test Cases).
