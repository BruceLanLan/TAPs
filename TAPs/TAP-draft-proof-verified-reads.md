---
tap: TBD
title: Proof-Verified Reads
description: How a client checks the TapeOut state it reads over JSON-RPC against EIP-1186 Merkle proofs of a pinned block's stateRoot, and where that state is stored in the listed TapeOut contract implementations.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/27
status: Draft
type: Standards
created: 2026-09-30
requires: TAP-10
license: CC0-1.0
---

# TAP-TBD: Proof-Verified Reads

## Summary

A way for TapeOut apps to double-check what blockchain nodes tell them, using cryptographic evidence from the chain itself that no single dishonest node can fake.

## Abstract

TAP-10 adopts a chain read when nodes of independent operators give the same answer, and its Security Considerations recommend that clients wanting a stronger guarantee verify state proofs (`eth_getProof`, EIP-1186) against block headers. This TAP says how. It defines where the state root comes from (the header of the TAP-10 §5.3 pinned block, adopted under TAP-10 §5.2 agreement); how to decode RLP canonically and walk a Merkle-Patricia proof, including embedded nodes and proofs of absence; how to check an EIP-1186 account and storage proof; the storage slots in which the listed implementations of the processor factory, the site store and the processor contracts keep `cpuCount`, `cpuAt`, `isCPU`, `ownerOf` and `fileInfo`, and the proven conditions under which each layout applies; and how a proven value is compared with the `eth_call` answer TAP-10 adopted, with three outcomes per read: `proven`, `proof-unavailable` and `proof-mismatch`. A proof adds a check and never replaces one.

## Motivation

TAP-10 §5.2 defeats a single lying node, not all configured operators lying together (TAP-10 Security Considerations, "Both layers"). A client that wants more has to check the answers against something the answering nodes cannot choose. On the chains of TAP-10 §2.1, every block header commits to the whole state through its `stateRoot`, and any node can prove a storage word against it with `eth_getProof`. That moves trust from "every node that answered told the truth about every value" to "independent operators agree on one 32-byte state root", and the proof itself may come from any node, trusted or not.

TAP-10 leaves open which block's `stateRoot` to use, which accounts and storage slots to prove, where the values TAP-10 reads live in contracts whose source layout is not part of any TAP, what to do when a proof disagrees with the agreed answer, and what to do when no node serves proofs. Without one answer, each client guesses slots, and a wrong guess turns a proof into a false alarm or into false confidence. This TAP writes down one answer that independent implementations can reproduce with the test vectors below.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms and notation

- **Pinned block**, **operator**, **answer**, **default agreement**, **strict agreement**, **site store**, **processor contract**, **processor factory**: as defined in TAP-10 §1. Contract addresses and accepted implementations are those of TAP-10 Deployments; the ones this TAP depends on are repeated under Deployments below.
- **State root**: the `stateRoot` field of a block header.
- **Proof answer**: the result of `eth_getProof` (EIP-1186): `accountProof`, `storageHash` and `storageProof` (a list of `{ key, value, proof }`), with other fields that this TAP ignores.
- **Word**: a 32-byte storage value, read as a big-endian unsigned integer. A word **is an address** when its upper 96 bits are zero; the address is then its lower 160 bits.
- **Layout gate**: the proven condition under which a storage layout of §7 applies (§7.2).
- **Proof-verified read**: a TAP-10 read whose outcome under §8 is `proven`.
- **Nibbles** of a byte string: each byte split into its high and then its low 4 bits.
- Notation follows TAP-10 §1: `‖` is concatenation and `uint256(x)` is the 32-byte big-endian encoding of `x`; an address inside `uint256(·)` is its 160-bit value. `keccak256` is the Keccak-256 hash used by Ethereum. Additions of slot numbers are modulo 2^256. `EMPTY_TRIE_ROOT` is `0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421` (`keccak256(0x80)`); `EMPTY_CODE_HASH` is `0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470` (`keccak256` of no bytes).

### 2. Scope

1. This TAP adds checks to TAP-10 and changes none of its requirements. A client need not implement it. A client that presents a read as proof-verified, or offers a mode that does, **MUST** follow §3 to §9 for that read.
2. The client **MUST** still make every read exactly as TAP-10 requires, at the same pinned block and under the same agreement. A proof **MUST NOT** be used to adopt a read that TAP-10 §5.2 rejects or finds `unavailable`, nor to choose between answers that disagree (TAP-10 §21, item 6).
3. The reads this TAP covers are listed in §8. Any other read (among them `opener.accountOf`, `opener.isOpened`, `DomainBinding.isLive` and `isContainerLive`, a container's `token()`, and every hub read of TAP-10 §12 to §20 other than the implementation slot) **MUST NOT** be presented as proof-verified under this TAP.

### 3. The state root

1. The pinned block `B` is chosen as TAP-10 §5.3 specifies, including the `stale-block` check. Proofs are requested at `B`, the block of the reads they check.
2. The client reads the header of `B` with `eth_getBlockByNumber(<B as 0x-hex>, false)` and adopts its `number`, `hash` and `stateRoot`, compared as lowercase hex, under the agreement of the reads it protects: default agreement for access-layer reads, strict agreement when it protects a read that TAP-10 makes under strict agreement (for example TAP-10 §13.8). A result whose `stateRoot` is not 32 bytes of hex, or whose `number` is not `B`, is not an answer.
3. The state root counts only if nodes of at least two different operators reported it. A client configured with a single operator (TAP-10 §5.2) **MUST NOT** present any read as proof-verified.
4. If the header is not adopted (any two answers differ, or too few operators answered), no read at `B` is proven: each has the outcome `proof-unavailable` (§8.2). The client **MUST NOT** take a state root from a proof answer or from any other source.

### 4. RLP decoding

Proof nodes and leaf values are RLP (Ethereum Yellow Paper, Appendix B). An implementation **MUST** decode them as follows and **MUST** reject every input that these rules do not accept. An item is a byte string or a list of items. Let `p` be the first byte of an item:

1. `p` < `0x80`: the item is the one byte `p`.
2. `0x80` ≤ `p` ≤ `0xb7`: a byte string of `p − 0x80` bytes follows. If that length is 1, the byte **MUST** be at least `0x80`.
3. `0xb8` ≤ `p` ≤ `0xbf`: the next `p − 0xb7` bytes are the big-endian length `L` of the string, which follows them. The first length byte **MUST NOT** be zero and `L` **MUST** be at least 56.
4. `0xc0` ≤ `p` ≤ `0xf7`: a list whose payload of `p − 0xc0` bytes follows.
5. `0xf8` ≤ `p` ≤ `0xff`: the next `p − 0xf7` bytes are the big-endian payload length `L` of a list, with the same two rules as in item 3.
6. Every length **MUST** fit in the input, or, inside a list, in the list's payload. A list's payload **MUST** consist exactly of whole items.
7. The input **MUST** be exactly one item: an empty input is rejected, and so is any byte after the outermost item.
8. Lists nest at most 64 deep, counting the outermost list: a list that lies inside 64 enclosing lists is rejected.

The **encoded length** of a list is the length of its header plus its payload; §5 uses it.

### 5. Merkle-Patricia proofs

The input is a root (32 bytes), a key (a byte string), a proof (a list of byte strings, each written in JSON as a lowercase `0x` followed by an even number of hex digits in either case) and a mode, **plain** or **secure**. A proof that is not such a list is rejected. In secure mode (the state and storage tries of §6) the key **MUST** be 32 bytes. The result is a value (a non-empty byte string), **absent** (the proof shows that the key has no value), or rejection. An implementation **MUST** compute it as follows and reject in every case marked so:

1. If the root is `EMPTY_TRIE_ROOT`, the result is absent when the proof is empty or is exactly the one node `0x80`; any other proof is rejected.
2. Let `path` be the nibbles of the key, `i` = 0 the position in `path`, `j` = 0 the next proof node, and let the current reference be the root, a hash.
3. **Next node.** If the reference is a hash: reject if `j` equals the number of proof nodes; reject if `keccak256` of proof node `j` is not the reference; decode node `j` (§4), reject unless it is a list, and increment `j`. If the reference is an embedded node, that list is the node, and no proof node is consumed.
4. **Branch** (17 items). Items 0 to 15 **MUST** each be an empty string, a 32-byte string or a list, and item 16 **MUST** be a string; otherwise reject.
   - If `i` equals the length of `path`: in secure mode, reject; in plain mode, the result is item 16, or absent if item 16 is empty.
   - In secure mode, a non-empty item 16 is rejected.
   - Otherwise take the child at index `path[i]` and increment `i`. An empty child means absent; any other child is followed (item 6). Children that are not followed are checked only as above.
5. **Leaf or extension** (2 items). Item 0 **MUST** be a non-empty string, decoded by hex-prefix encoding (Yellow Paper, Appendix C): the flag is its first nibble and **MUST** be at most 3; flags 2 and 3 mark a leaf, 0 and 1 an extension. An odd flag (1, 3) means the second nibble of the first byte is the first nibble of the node's path; an even flag (0, 2) means the second nibble **MUST** be 0 and the path starts with the second byte. The node's path is the remaining nibbles.
   - **Leaf.** Item 1 **MUST** be a non-empty string. If the rest of `path` (from `i`) equals the node's path, the result is item 1. Otherwise, in secure mode, if the node's path is not exactly as long as the rest of `path`, reject; in all other cases the result is absent.
   - **Extension.** The node's path **MUST NOT** be empty. If the rest of `path` does not begin with the node's path (including when it is shorter), the result is absent. Otherwise add the length of the node's path to `i` and follow item 1 (item 6).
   - A node with any other number of items is rejected.
6. **Following a child.** A 32-byte string is the next reference (a hash). A list is an embedded node and **MUST** have an encoded length below 32 bytes. Anything else is rejected. Continue at item 3.
7. When a result (a value or absent) is reached, `j` **MUST** equal the number of proof nodes: a proof with unused nodes is rejected.

The root is always referenced by its hash; only nodes whose encoding is shorter than 32 bytes are embedded in their parent. These rules follow the Yellow Paper, Appendix D.

### 6. Account and storage proofs

A client requests `eth_getProof(address, [slot, …], <B as 0x-hex>)`, each slot written as `0x` and 64 hex digits, and checks the answer against the state root `R` of §3, for the address `A` (20 bytes) and the set of slots `Q` it asked for:

1. The answer **MUST** be a JSON object. If its `address` is a string, it **MUST** be `A` written as `0x` and 40 hex digits, compared case-insensitively; an `address` of any other JSON type is ignored.
2. **Account.** Walk `accountProof` in secure mode (§5) with root `R` and key `keccak256(A)`.
   - Absent: the account does not exist; its nonce and balance are 0, its storage root is `EMPTY_TRIE_ROOT` and its code hash is `EMPTY_CODE_HASH`.
   - A value: decoded (§4), it **MUST** be a list of exactly four strings `[nonce, balance, storageRoot, codeHash]`. `nonce` and `balance` are big-endian integers and **MUST NOT** begin with a zero byte (the empty string is 0); `storageRoot` and `codeHash` **MUST** be 32 bytes.
3. If the account exists and the answer carries `storageHash`, it **MUST** be `storageRoot` written as `0x` and 64 hex digits, compared case-insensitively.
4. **Slots.** `storageProof` **MUST** be a list, even when `Q` is empty. For each slot `s` in `Q`, it **MUST** contain exactly one entry whose `key` equals `s`; an entry that is not an object, or whose `key` is not a number as defined below, does not count. Walk that entry's `proof` in secure mode with root `storageRoot` and key `keccak256(uint256(s))`. Absent means the word is 0. A value, decoded (§4), **MUST** be a string of 1 to 32 bytes whose first byte is not zero; the word is that integer. The entry's `value` **MUST** be a number equal to the word. Here a number is a string that starts with `0x` and continues with one or more hex digits, letters in either case and leading zeros allowed.
5. Entries for slots not in `Q` are ignored. Only values derived in steps 2 to 4 are used; the answer's other fields (for example `balance`, `nonce`, `codeHash`) are not.

An answer that fails any step is an **invalid proof**. An invalid proof is not evidence about the state, since any node can serve one: the client **MAY** ask another node, and **SHOULD** try every configured node before it concludes that no proof can be had. It **MAY** stop asking, for a while, a node that refused the method or served an invalid proof; it **SHOULD NOT** stop asking a node for a rate limit or a timeout. A proof answer need not come from a node that took part in agreement.

The client **SHOULD** ask, in one `eth_getProof` for each contract, for every slot that the reads of one resolution or site open need at `B`, together with the slots of that contract's layout gate (§7), so that gate and values come from the same proof.

### 7. Storage layouts

#### 7.1 Layout-independent slots

- The ERC-1967 **implementation slot** `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` holds, in every ERC-1967 proxy, the address of the implementation. Proving it proves the implementation of any proxy listed in TAP-10 Deployments (site store, payment contract, processor factory, hub).
- The ERC-1967 **beacon slot** `0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50` holds the beacon of a beacon proxy.
- An account's **code hash** is proven by its account proof (§6 step 2).

A slot word that is to be read as an address and is not an address (§1) is treated as a different value: in a layout gate, the gate does not hold; compared with an answer, it is a mismatch.

#### 7.2 Layout gates

A storage slot means something only under the code that reads it. The layouts in §7.3 to §7.5 were measured on the implementations listed there (Deployments), and apply to an account at `B` only when the gate of that section holds for proven values at `B`. The implementations are those that TAP-10 Deployments accepts for each chain. When a gate does not hold, the reads of that contract have the outcome `proof-unavailable` (§8.2), not `proof-mismatch`. This is independent of TAP-10's own checks: if TAP-10 §6.1 rejects the read (`store-changed`), TAP-10 decides.

#### 7.3 Processor factory

Gate: the factory's implementation slot holds the factory implementation listed for the chain: `0xa68cCF4931d98ad0A4BE15eE40542eDc0DEc6422` on BNB Smart Chain; `0x74956236Ab64eD143933040B4137E8A352e4d17b` on Base and X Layer.

| Read | Slot | Word |
|---|---|---|
| `cpuCount()` | `6` (the length of the `address[]` of processor contracts) | The count |
| `cpuAt(n)` | `keccak256(uint256(6)) + n`, for `n` below the count | The processor contract, an address |
| `isCPU(a)` | `keccak256(uint256(a) ‖ uint256(7))` (a `mapping(address => bool)` at slot 7) | 1 for true, 0 for false; any other word is neither |

#### 7.4 Site store

Gate: the site store's implementation slot holds the site store implementation listed for the chain: `0x1d279D138A4D803378a7d4557c056f1beD53c261` on BNB Smart Chain; `0xa85c4143d1D4A77f54b8e4ecC9E6D1418Afea45f` on Base and X Layer.

For a container `c` and a path `p` (the exact string passed to `fileInfo`, after TAP-10 §7.2, as UTF-8 bytes):

```
S = keccak256(uint256(c) ‖ uint256(1))                 the container's record (mapping(address => Site) at slot 1)
F = keccak256(keccak256(p) ‖ uint256(S + 2))           the file's record (mapping(bytes32 => File) at S + 2, keyed by keccak256(p))
```

| Slot | Content |
|---|---|
| `F + 0` | `chunkCount` |
| `F + 1` | `size` = word mod 2^32; `updatedAt` = (word >> 32) mod 2^40 |
| `F + 2` | `sha256Hash` |
| `F + 3` | `contentType`, a Solidity storage string: if the word's lowest bit is 0, the length is (word mod 256) / 2 and at most 31, and the string is the first bytes of the word; if it is 1, the length is (word − 1) / 2 and the bytes are stored from slot `keccak256(uint256(F + 3))` on, 32 bytes per slot |

Only the bits named in this table are used; any other bits of `F + 1` are ignored and take no part in the comparison of §8.1. For a path that has never been written, all four words are 0, and `chunkCount` 0 means that there is no such file (TAP-10 §7.1 step 1).

#### 7.5 Processor contracts

Processor contracts are beacon proxies created by the factory. Gate, for processor contract `P` at `B`, all proven:

1. the code hash of `P` equals the processor proxy code hash listed for the chain: `0xd8c4b0216e0aadd615fbd134465b6af060a11769edc7c844d8f14d1b8a783992` on BNB Smart Chain; `0x57aa306fd0be97087da3534e03398f5ff4efd533b5be4e45a405ce86fa6717d5` on Base and X Layer;
2. the beacon slot of `P` holds the circuit beacon listed for the chain: `0xf8D6d8EB894d6971c8976Ad8b4971cbEFE028156` on BNB Smart Chain; `0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C` on Base and X Layer;
3. in the beacon's own proof, its code hash equals `0x964014cd563c5bc62e1f8a3b2995969d6385f25da1e4efa353a01a62e0b75cca` on BNB Smart Chain, or `0xc7cc9854e1465f48d6d8d6d220c04efa6509939832930be4b04ee7fe86575362` on Base and X Layer, and its slot 1 (the beacon's implementation; slot 0 is its owner) holds the circuit implementation listed for the chain: `0x8E1D125Def6d3826C278299273a0760D47626068` on BNB Smart Chain; `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2` on Base and X Layer.

Layout: ERC-721 state lives in the ERC-7201 namespace `openzeppelin.storage.ERC721`, whose base is `keccak256(uint256(keccak256("openzeppelin.storage.ERC721")) − 1)` with the lowest byte cleared, `0x80bb2b638cc20bc4d0a60d66940f3ab4a00c1d7b313497ca82fb0b4ab0079300`. Owners are a `mapping(uint256 => address)` at base + 2:

| Read | Slot | Word |
|---|---|---|
| `ownerOf(t)` | `keccak256(uint256(t) ‖ uint256(0x80bb2b638cc20bc4d0a60d66940f3ab4a00c1d7b313497ca82fb0b4ab0079302))` | The holder, an address; 0 when the token does not exist |
| `circuitBeacon.implementation()` | Beacon slot 1 | The circuit implementation, an address |

### 8. Cross-checking and outcomes

#### 8.1 What equals what

For each covered read, the proven value is compared with the answer TAP-10 adopted at `B`:

| TAP-10 read | Equal when |
|---|---|
| ERC-1967 implementation slot of a listed proxy (`eth_getStorageAt`; TAP-10 §6.1, §13.8) | The proven word equals the adopted word |
| `factory.cpuCount()` (TAP-10 §4.2 step 1) | Slot 6 equals the answer |
| `factory.cpuAt(n)` returns `a` (TAP-10 §4.2 step 2) | `n` is below slot 6 and the element word is an address equal to `a` |
| `factory.cpuAt(n)` reverts | `n` is at least slot 6 |
| `factory.isCPU(a)` (TAP-10 §4.3 step 2) | The word is 1 and the answer true, or the word is 0 and the answer false |
| `processor.ownerOf(t)` returns `h` (TAP-10 §4.2 step 4) | The word is an address equal to `h`, and not 0 |
| `processor.ownerOf(t)` reverts | The word is 0 |
| `SiteRegistry.fileInfo(c, p)` (TAP-10 §7.1 step 1) | `size`, `updatedAt`, `sha256Hash`, `chunkCount` and `contentType` of §7.4 each equal the returned field. A client **MAY** prove only `size` and `sha256Hash`, which are what TAP-10 §7.1 verifies bytes against, and then presents only those two fields as proof-verified |
| The file's bytes (TAP-10 §7.1 step 4) | Their length equals the proven `size` and their SHA-256 equals the proven `sha256Hash` |
| `circuitBeacon.implementation()` (TAP-10 §13.8) | Beacon slot 1 is an address equal to the answer |

Through the last-but-one row, the bytes of a file are proof-verified whenever `size` and `sha256Hash` are.

#### 8.2 Outcomes

Each read of §8.1 that a client sets out to prove has exactly one outcome:

- **`proven`**: the header was adopted (§3), a proof verified (§6), the gate holds (§7), and the values are equal (§8.1).
- **`proof-mismatch`**: a proof verified against the adopted state root and the gate holds, but the proven value differs from the answer TAP-10 adopted. The nodes that answered contradict the state root that the operators confirmed. The client **MUST** reject the read under every policy below and **MUST NOT** use either value. It **SHOULD** report the read, `B`, the state root and the proven value.
- **`proof-unavailable`**: anything else: the header was not adopted, no node served a proof that verifies, or the gate does not hold.

Every proof that verifies against one state root shows the same values, so the outcome does not depend on which node served the proof. Reads outside §8.1 have none of these outcomes and are not affected by the policies below; they keep the assurance of TAP-10 alone and are never presented as proof-verified (§2 item 3).

For `proof-unavailable` a client follows one of two policies, which it **MUST** make known to its user or caller:

- **Required**: the read is rejected.
- **Opportunistic**: the read keeps the answer TAP-10 adopted, but the client **MUST NOT** present it as proof-verified, and **MUST** report `proof-unavailable` for it.

A client that offers proof verification **SHOULD** offer the required policy. A read rejected under this section is treated as a read that could not be adopted: where TAP-10 would then report `unavailable`, the client does so, and **SHOULD** also show the more specific outcome. These outcomes are client-local: they add nothing to the status codes of TAP-10 §4.4 and §6.4, and a TAP-10 status that applies (for example `stale-block` or `store-changed`) takes precedence.

### 9. Limits

1. The RLP nesting limit of §4 item 8 and the unused-node rule of §5 item 7 **MUST** be enforced.
2. Proof answers are untrusted input. A malformed answer of any shape **MUST** end in an invalid proof, never in an accepted value or in a failure of the client. A client **SHOULD** bound the size of an answer before parsing it; the reference implementation accepts at most 4 MiB per JSON-RPC response.
3. Proven values hold for `B` only and **MUST NOT** be reused as proven for another pinned block.
4. The layout gates are re-checked at every `B`; a gate that held at an earlier block proves nothing about a later one.

## Rationale

- **Standards, not Information.** This TAP defines client verification rules (TAP-01 §3) with requirements and test vectors that every implementation claiming proof verification must reproduce, and fixes storage layouts that such clients must agree on to reach the same outcome. An Information TAP carries no requirements. The layouts depend on upgradeable contracts; this TAP handles that as TAP-10 does, by accepting a layout only behind a proven implementation gate, and follows the Candidate path of TAP-01 §5.1 until those contracts are sealed.
- **State root by agreement, proofs from anyone.** A proof is only as good as its root. Taking the root from the header that independent operators report for the TAP-10 pinned block keeps TAP-10's trust assumption and narrows what the operators must get right to one value. A node that serves a wrong proof fails the check, so proofs need no agreement, and a node that is not trusted at all, or is not among the agreeing operators, can still serve them.
- **A proof adds, never replaces.** TAP-10 §21 fixes that disagreement means rejection. Using a proof to settle a disagreement, or to skip agreement, would change that rule and would make a wrong layout a silent error. Keeping every TAP-10 read also means that a client which turns proofs off behaves exactly as a TAP-10 client.
- **Three outcomes.** A node can serve an invalid proof at no cost, so an invalid proof is not evidence of anything (`proof-unavailable`). Only a proof that verifies against the agreed root, under a proven layout gate, and contradicts the agreed answer is evidence that the answering nodes are wrong (`proof-mismatch`), and it is rejected in every policy. A pre-release version of the reference implementation only warned in that case under its opportunistic policy, which let a forged answer through; review caught it before release.
- **Gates by implementation.** The layouts are measured, not derived from a published storage layout. A gate that fails makes the read `proof-unavailable` rather than `proof-mismatch`, so an upgrade that moves storage neither looks like an attack nor passes as proven. The processor contracts are beacon proxies; their gate uses the code hash (the same one the hub checks, TAP-10 §13.4 step 2), the beacon slot and the beacon's implementation, all provable in two proof answers.
- **Two operators, even with one configured.** With one operator, the root and the answers come from the same party, and the proof checks only its consistency. TAP-10 §5.2 lets such a client adopt reads; this TAP does not let it call them proof-verified.
- **No header-hash check.** Recomputing the block hash from the header would bind the state root to the hash, but the header encodings of BNB Smart Chain, Base and X Layer differ and change with forks. Agreement on both the hash and the state root, under the same operators, gives the same assurance with far less code.
- **The TAP-10 pinned block, not a finalized one.** Proofs are checked at the block of the reads they protect, and TAP-10 §5.3 pins near the head. Nodes that serve proofs keep recent state (Security Considerations), so this choice also makes proofs easier to obtain.
- **A nesting limit of 64.** A node referenced by hash is at least 32 bytes long, so any list embedded in a node is shorter than 32 bytes, and each nesting level costs at least one header byte: no valid trie node nests more than 32 lists. The limit leaves room and stops unbounded recursion on hostile input.
- **Not covered.** `opener.accountOf` is a pure function of chain constants that a client can recompute from ERC-6551 (TAP-10 §13.4 step 5); `isOpened`, the payment records and the hub's records live in layouts that have not been measured. They can be added by a later revision once their layouts are measured and gated.
- **Alternatives.** A light client that verifies headers by consensus would remove the trust in operators for the state root, but BNB Smart Chain, Base and X Layer each need a different one; it is left to a future TAP. Trusting a single proof-serving node for both header and proof was rejected: it is no stronger than trusting that node's `eth_call`.

## Backwards Compatibility

Nothing in TAP-10 changes, and a client that does not implement this TAP is unaffected. The three outcomes are client-local.

**History.** The proof mode was first published in the TapeAPI repository as an informative note in "TAP-20" §3.2 and §6.5 (renamed TAPI-20 on 2026-09-30; neither is a TAP number), with vectors in `spec/vectors/tap-20-proof.json`; that file name is historical. This TAP replaces the note with requirements. There are no frozen on-chain constants.

**Differences from the reference implementation** at the commit below, and the planned changes (its proof mode is experimental and off by default, so they break no stable interface):

1. **Pinned block.** The SDK pins to the block that each node reports for the `finalized` (BNB Smart Chain) or `safe` tag, confirmed by nodes of two operators, and judges freshness by the block time against the client clock. §3 uses the TAP-10 §5.3 pinned block. A TAP-10 pinning mode is planned.
2. **State root.** The SDK takes the state root when nodes of two operators report the same hash and state root, and does not count a node that omits it, as §3 requires. When two state roots are reported for one hash it fails the whole resolution (`RPC_DISAGREE`), where §3 item 4 makes each read `proof-unavailable`.
3. **One operator.** Configured with a single operator (`allowSingleNode`), the SDK takes that operator's state root and records reads as proven; §3 item 3 forbids this. It will report them as `proof-unavailable`.
4. **Outcomes.** The SDK's `proofs: 'strict'` is the required policy and `proofs: true` the opportunistic one. Its code `PROOF_UNAVAILABLE` corresponds to `proof-unavailable`; its code `PROOF_INVALID` is used both for `proof-mismatch` and, in strict mode, for a read where every served proof was invalid, which this TAP classes as `proof-unavailable`. The codes will be split.
5. **Gates.** The SDK proves `ownerOf` without the gate of §7.5 and relies on equality with the `eth_call` answer, so a changed layout would appear as `PROOF_INVALID`. Its gates for the factory and the site store accept the implementation listed for either chain on every chain, where §7.3 and §7.4 accept only the one listed for the chain. Both will be fixed.
6. **Coverage.** The SDK proves `size` and `sha256Hash` of `fileInfo` (not `chunkCount`, `updatedAt` or `contentType`), proves `cpuAt` and checks the array length only when a name gave the processor number, proves the implementation slots of the factory and site store only as gates, and does not prove the payment contract's or the hub's implementation slot or the beacon's implementation. These will be added.
7. **Number formats.** The SDK reads a storage entry's `key` and `value` with JavaScript `BigInt`, which also accepts an uppercase `0X` prefix, decimal strings, JSON numbers and surrounding white space; §6 step 4 does not. It will be tightened.
8. **Independent checker.** `spec/vectors/verify.py` at that commit does not reject an account nonce or balance with a leading zero byte, nor an answer whose `address` names another account (§6 steps 1 and 2), and it reads an address word as its low 160 bits without checking the upper 96 (§1, §7.1); the SDK does all three. Three account cases of `negative.json` show the first two; the checker will be tightened.

## Test Cases

Test vectors are in `assets/tap-draft-proof-verified-reads/` (directory name as asked in #7). Every file gives inputs and exact expected outputs:

| File | Covers |
|---|---|
| `trie.json` | §5: nine tries whose keys, values and roots are copied unchanged from `ethereum/tests` at commit `c67e485ff8b5be9abc8ad15345ec21aa22e290d9` (`TrieTests/trieanyorder.json`, `trieanyorder_secureTrie.json`, `hex_encoded_securetrie_test.json`; MIT License), plain and secure, with 53 proofs of present and absent keys, some through embedded nodes. A checker rebuilds each root from the keys and values and walks each proof |
| `mainnet-bsc-11.1013.json` | §6, §7.3 to §7.5 slots, §8.1: the `eth_getProof` answers of one resolution of `11.1013.tape` on BNB Smart Chain (block 124815911, 2026-09-30) for the factory, the processor contract and the site store, an empty slot and an address with no account; the `eth_call` answers they equal; 252 single-byte changes of proof nodes, each of which must be rejected; and a wrong state root that rejects every answer |
| `layouts-mainnet.json` | §3, §7, §8.1 on live chains, 2026-09-30, at blocks pinned as TAP-10 §5.3 specifies: BNB Smart Chain `4246.0.tape` (block 124927736; every field of §7.4 including `contentType`, all gates of §7.3 to §7.5) and Base `1.3.1.tape` (block 51995298; a file that does not exist, all gates). For each: inputs, computed slots, proof answers, gates, decoded values and the equal `eth_call` answers |
| `negative.json` | §4 to §7.1 counterexamples and boundaries (in its trie cases `key` is already the path in the trie, 32 bytes in secure mode, while in `trie.json` it is the original key and `path` the hashed one): 17 RLP cases (wrapped single byte, short and long form boundaries, leading-zero lengths, overruns, trailing bytes, 64 and 65 nested lists), 23 trie cases (hex-prefix flags and padding, empty extension, leaf without value, branch shapes, embedded nodes of 32 bytes, followed or not, secure-mode rules, unused and missing nodes, the empty trie), 15 account cases (leading zeros in nonce, balance and storage values, wrong item counts and lengths, a claimed value or `storageHash` the proof does not show, a slot answered zero times or twice, another address) and 3 address-word cases |

The reference implementation at the commit below (`sdk/src/proof.js`) reproduces every accept or reject result and every proven account and slot value in these files, and the slots of the reads it covers (Backwards Compatibility, item 6). The other slots and decoded values of `layouts-mainnet.json` (`chunkCount`, `updatedAt`, `contentType`) and its `gates` entries follow directly from §7 and equal the recorded `eth_call` answers and the constants of §7.3 to §7.5; the reference implementation does not yet compute them (Backwards Compatibility, items 5 and 6). `spec/vectors/verify.py` at the same commit, an independent Python implementation written from the Yellow Paper and EIP-1186, recomputes `trie.json` and `mainnet-bsc-11.1013.json` (both taken unchanged from `spec/vectors/tap-20-proof.json` there). Its functions also reproduce the proof answers of `layouts-mainnet.json` and every RLP, trie and account case of `negative.json` except the three noted under Backwards Compatibility, item 8; it has no function for the address-word cases.

The file vector of `layouts-mainnet.json` agrees with TAP-10 Test Cases: `index.html` of `4246.0.tape` is 19,770 bytes with SHA-256 `0x275c896aa347670b19e8ed11256165dbabadb0f9e3c947370b591130acb507b8`, updated 2026-09-21T09:00:31Z.

## Reference Implementation

[BruceLanLan/tapeapi at `fda84db889d2a732915f264a799af24073177a85`](https://github.com/BruceLanLan/tapeapi/tree/fda84db889d2a732915f264a799af24073177a85) (TapeAPI 1.3.0, MIT licensed):

| Component | Location |
|---|---|
| RLP, Merkle-Patricia and EIP-1186 checks, slot computations, layout implementations | `sdk/src/proof.js` |
| Proof sessions, prover selection, comparison with agreed answers (`createTapeAPI({ pin: true, proofs })`) | `sdk/src/index.js` |
| Confirmed block with state root (`confirmedBlock(tag, { stateRoot: true })`), response size limit | `sdk/src/rpc.js` |
| Tests | `sdk/test/proof.test.mjs`, with `sdk/test/fixtures/mainnet-11-1013-proof.json` and `sdk/test/fixtures/ethereum-trie-tests.json` |
| Vectors and independent check | `spec/vectors/tap-20-proof.json`, `spec/vectors/verify.py` |

The proof mode is experimental in that release and off by default. No part has had an independent audit.

## Deployments

This TAP deploys nothing. It depends on the contracts below, all listed in TAP-10 Deployments, and on the storage layouts of the listed implementations. The code hashes of the two circuit beacons are not in TAP-10 and were measured for this TAP.

| Chain (chainId) | Contract | Address | Implementation or code it must have | How to verify read-only | Sealed? |
|---|---|---|---|---|---|
| BNB Smart Chain (56) | Processor factory (UUPS proxy) | `0x68224F668083c29e9800Be2a646d42d18cedF7e2` | `0xa68cCF4931d98ad0A4BE15eE40542eDc0DEc6422` | Implementation slot (`eth_getStorageAt` or `eth_getProof`) | No |
| BNB Smart Chain (56) | Site store (UUPS proxy) | `0xd006ffdd5Ae313B17729621A00999cD3C71CE5e6` | `0x1d279D138A4D803378a7d4557c056f1beD53c261` | Implementation slot | No (upgradeable) |
| BNB Smart Chain (56) | Processor contracts (beacon proxies) | `factory.cpuAt(n)` | Code hash `0xd8c4b0216e0aadd615fbd134465b6af060a11769edc7c844d8f14d1b8a783992`; beacon slot `0xf8D6d8EB894d6971c8976Ad8b4971cbEFE028156` | Account proof (code hash), beacon slot | Follows the factory |
| BNB Smart Chain (56) | Circuit beacon | `0xf8D6d8EB894d6971c8976Ad8b4971cbEFE028156` | Code hash `0x964014cd563c5bc62e1f8a3b2995969d6385f25da1e4efa353a01a62e0b75cca`; slot 1 `0x8E1D125Def6d3826C278299273a0760D47626068`; slot 0 (owner) the factory | Account proof; slots 0 and 1; `implementation()`, `owner()` | Owned by the factory, not sealed |
| Base (8453), X Layer (196) | Processor factory (UUPS proxy) | `0x1f09DAeFA827f02CBb40967cc91b259763760761` | `0x74956236Ab64eD143933040B4137E8A352e4d17b` | As above | No |
| Base (8453), X Layer (196) | Site store (UUPS proxy) | `0xd6EFb7adCc9c83dC4924Ad56f6a8E4e969b9ADB6` | `0xa85c4143d1D4A77f54b8e4ecC9E6D1418Afea45f` | As above | No (upgradeable) |
| Base (8453), X Layer (196) | Processor contracts (beacon proxies) | `factory.cpuAt(n)` | Code hash `0x57aa306fd0be97087da3534e03398f5ff4efd533b5be4e45a405ce86fa6717d5`; beacon slot `0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C` | As above | Follows the factory |
| Base (8453), X Layer (196) | Circuit beacon | `0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C` | Code hash `0xc7cc9854e1465f48d6d8d6d220c04efa6509939832930be4b04ee7fe86575362`; slot 1 `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2`; slot 0 the factory | As above | Owned by the factory, not sealed |

The implementation slots of the payment contract and of the hub (TAP-10 Deployments) are covered by §7.1 alone and need no layout.

**How the layouts were verified**, read-only, on 2026-09-30 (times UTC), each time against the `eth_call` answers at the same block:

| Chain | Method and blocks | What was read | Result |
|---|---|---|---|
| BNB Smart Chain | `eth_getProof` at blocks 124927187 (14:48) and 124927736 (14:52), pinned as TAP-10 §5.3 specifies, headers reported identically by nodes of two operators (three at the first block); earlier, block 124815911 | `cpuCount` (1,173), `cpuAt(0)`, `isCPU`, `ownerOf(4246)`, every field of `fileInfo` for `index.html` of `4246.0.tape`, the beacon's implementation and owner; at the earlier block, the resolution of `11.1013.tape` | Every value equal, every gate held |
| Base | `eth_getProof` at blocks 51995188 and 51995298 | The gates of the factory, the processor contract `0x0565EA48CA41Ae559d8d491dbb0a9ec945DB551b`, the beacon and the site store; `cpuCount`, `cpuAt(1)`, `isCPU`, `ownerOf(1)`, the beacon's implementation; the file fields only for a file that does not exist, as no container on Base had a site file (`1.3.1.tape` has none) | Every value equal, every gate held. The site store implementation has the same code on Base as on X Layer (14,377 bytes, keccak256 `0xec8c29acef66eb1bf973d6e80202258830631b7b2849f75d04365c6f80443e6d`, `eth_getCode` on both chains) |
| X Layer | `eth_getStorageAt` at block 72010735 (14:49), since no configured node served `eth_getProof` (Security Considerations) | The same slots for `1.2.230.tape` (`index.html`, 13,614 bytes) | Every word equal, every gate value held. This verifies the layout, not a proof. Separately, a node outside the default list, which serves `eth_getProof` only for `latest`, returned a proof of the site store's implementation slot that verified under §6 against the state root of block 72011760 (15:06) reported identically by two operators, consistent with X Layer keeping its state in the same Keccak-256 Merkle-Patricia trie |

Anyone can repeat these checks with `eth_getProof`, `eth_getStorageAt`, `eth_getCode` and `eth_call`, or with the vectors above. As recorded in TAP-10 Deployments, none of these contracts is sealed; like TAP-10, this TAP can become Final only when they are (TAP-01 §5.1).

## Security Considerations

**What an attacker can do, and what the design protects.**

- **Nodes that agree on false state.** If every node that answers an `eth_call` colludes, TAP-10 agreement adopts the forged answer. With a proof-verified read, the forged value contradicts the state root and the read is rejected (`proof-mismatch`), provided the operators that reported the state root are not all among the colluders. This covers the processor a name resolves to, whether it is a processor, its holder, and the declared size and hash of a site file, and through the hash the file's bytes.
- **A lying prover.** A node that serves proofs cannot make a false value verify; it can serve invalid proofs, refuse, or stay silent, which yields `proof-unavailable`. Under the required policy that is a denial of service, never an acceptance.
- **Hostile encodings.** Every proof node is bound to its parent by hash or embedded in it. Canonical RLP gives each node one decoding; the embedded-node rule, the secure-mode rules and the unused-node rule leave no room for extra or reinterpreted nodes; the nesting limit bounds the work on hostile input; and malformed input ends in rejection (§9).

**What it does not protect.**

- **Upgrades are real state.** Until the contracts are sealed, their owners can change what they store and what they return (TAP-10 Security Considerations). Every proof then confirms the new state. The gates make a lasting change of implementation visible as `proof-unavailable`, but an upgrade that rewrites storage and restores an accepted implementation within one transaction (TAP-10 §13.8) leaves only proven, genuine-looking state.
- **All operators forging the header.** If every operator that reports the header colludes, it can build a state trie of its own and serve matching proofs. This TAP narrows what those operators must forge to one header; it does not remove the trust in them. A light client is out of scope.
- **Freshness and reorganization.** A proof shows the state of `B`, nothing later. Freshness is TAP-10 §5.3's pin-lag check, with its limits. On Base and X Layer a block near the head can still be replaced (TAP-10 Security Considerations, "Layer 2 finality"); a proof does not change that.
- **Reads outside §8.** Container derivation, activation, `isOpened`, hub records and logs are not covered; they keep the assurance of TAP-10 agreement alone.
- **Layouts are measured.** They were read back on the listed implementations, not derived from published, verified source. The gates limit the risk to those implementations; a measurement error would show as `proof-mismatch` on honest chains, which the test vectors guard against.
- **Privacy.** A proof request names the contract and the slots, from which a node can learn which container, path or token the client is looking at, as it can from the `eth_call` itself.

**Proof support among nodes (informative).** Measured on 2026-09-30 between 14:48 and 14:53 UTC with the default node list of the reference implementation (`sdk/src/rpc-defaults.js` at the commit above), at a block pinned as TAP-10 §5.3 specifies (2 blocks below the second-highest operator head) and at the block of each chain's finality tag (TAP-10 §2.1):

| Chain | Default nodes (operators) | Served verifying proofs at the TAP-10 pinned block | At the finality-tag block | Others answered |
|---|---|---|---|---|
| BNB Smart Chain | 3 (3) | 1 | 1 (`finalized`) | One refused the method with a limit error; one lacked the state ("missing trie node") at both blocks |
| Base | 4 (4) | 1 for every request, 2 more for some requests | 2 (`safe`) | Rate limits; "no state found" on some requests; one refused blocks outside its proof window; at `safe`, a second node reported its proof window exceeded |
| X Layer | 3 (2) | 0 | 0 (`safe`) | One operator's two nodes do not offer the method; the other operator had no state for either block. One node outside the list served proofs, but only for `latest` |

So at that time a client using only these defaults could obtain proofs on BNB Smart Chain and Base, relying on one or two nodes, and not at all on X Layer; users can add nodes, including self-hosted ones (TAP-10 §5.1). Support changes often; these numbers only describe that day.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
