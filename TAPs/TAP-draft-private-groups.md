---
tap: TBD
title: Private Group Conversations Between Containers
description: An owner-run, end-to-end encrypted group of up to 32 circuit containers, with a group key per epoch sealed to each member's channel key, a roster that relays and chain observers cannot read, and messages signed by their senders.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/19
status: Draft
type: Application
created: 2026-09-30
requires: TAP-10, TAP-draft-private-channels
license: CC0-1.0
---

# TAP-TBD: Private Group Conversations Between Containers

## Summary

A way for a small group of TapeOut containers, up to 32, to hold one private conversation in which only the current members can read what is said and every member can see which member said it.

## Abstract

This TAP defines a **group**: an encrypted conversation among 1 to 32 circuit containers, run by one of them, the **owner**. The owner keeps the member list. Every change of membership starts a new **epoch** with a fresh group key, which the owner seals to each member's channel X25519 key in an owner-signed **epoch message**; the epoch message also carries the member list (the **roster**), encrypted under the group key, and a commitment to that key. The slots that carry the key name nobody, so a relay or a chain observer learns the number of members and not who they are. Members encrypt **group messages** under per-sender keys derived from the group key and sign them with their Ed25519 channel keys, so members can read each other and cannot impersonate each other. Identities, invites and transports are those of TAP-draft-private-channels: channel key records, sealed inbox invites, relays and the ChannelBus contract carry groups unchanged, under the two wire types that draft reserves for them.

## Motivation

TAP-draft-private-channels gives two containers a private channel, and its triple Diffie-Hellman handshake does not extend to more parties. An application that gathers several containers in one conversation, such as a table of card players, a working group of agents or a service with several clients in one session, can today either open a channel between every pair of members, which costs a handshake per pair and gives no common view of who is in the conversation, or send in the clear. TAP-10 TapeSend can seal one message to up to 16 keys (TAP-10 §15.3), but each message is a transaction, its metadata is public for ever, and its slot fingerprints show which keys it was sealed to.

This TAP adds the smallest group construction that keeps the channel draft's properties where they can be kept (end-to-end confidentiality, sender authentication, no trusted server, hidden membership) and states plainly where it cannot (Security Considerations). It defines a conversation and nothing else: no roles besides the owner, no application state, no settlement.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms and notation

- **Container**, **holder**, **pinned block**, **strict agreement**: as defined in TAP-10 §1.
- **Channel key record**, **inbox room**, **relay reference**, **relay**, **ChannelBus**, **wire message**: as defined in TAP-draft-private-channels (§3, §6.1, §5, §11, §12 and §10.2 of that draft).
- **Group ID** `gid`: 16 random bytes that the owner draws when it creates the group.
- **Owner**: the container that creates the group, keeps the roster and signs every epoch message. It is fixed for the life of the group.
- **Member**: a container listed in the roster of an epoch, the owner included. A member's **index** is its position in that roster, starting at 0.
- **Epoch** `n`: an integer from 0 to 2^32 − 1. Each epoch has its own group key `K`, roster and set of members.
- **Receiver**: a member processing an epoch message or a group message.
- Notation follows TAP-10 §1: `‖` is concatenation, `uint64(x)` and `uint32(x)` are big-endian, and ASCII labels such as `"TAP-27/room/v1"` are their raw bytes without a terminator. `X25519(k, U)` is RFC 7748; `HKDF-SHA256(IKM, salt, info, L)` is RFC 5869; XChaCha20-Poly1305 is draft-irtf-cfrg-xchacha-03 with a 32-byte key, a 24-byte nonce and a 16-byte tag, written `XChaCha20-Poly1305(key, nonce, aad).encrypt(plaintext)`; Ed25519 is RFC 8032, written `Ed25519(signer, message)`. "Hex" means lowercase hexadecimal; a field described as "`0x` hex" carries the prefix, one described as "bare hex" does not.
- The labels in this TAP begin with `TAP-27/`, which does not refer to any TAP number (see Backwards Compatibility).

### 2. What this TAP takes from TAP-draft-private-channels

An implementation of this TAP implements the following parts of TAP-draft-private-channels, which this TAP uses without change:

- canonical JSON and strict JSON (§2 of that draft);
- channel key records and how a client reads and verifies them (§3), with the X25519 key checks (§4.2) and the Ed25519 key check (§4.3);
- relay references and the ChannelBus address rule (§5);
- inbox rooms and sealed inbox wires of wire type `0x03` (§6.1);
- wire messages (§10.2): this TAP defines wire types `0x04` (epoch message, §5) and `0x05` (group message, §6), which that draft reserves for group messaging;
- the relay service (§11) and the ChannelBus (§12).

Every Ed25519 public key this TAP uses **MUST** pass §4.3 of that draft. Every Ed25519 signature this TAP defines is verified as RFC 8032 §5.1.7 specifies, with `S` below the group order, canonical encodings of `A` and `R` required (no ZIP-215 leniency), and the cofactored equation `[8][S]B = [8]R + [8][k]A`.

### 3. Identities and member verification

Every member, the owner included, has a channel identity: the `x25519` and `ed25519` keys of its channel key record. A roster is the owner's statement of who is in the group; it proves nobody's keys. A receiver learns the owner's keys by reading the owner's record, and checks every other member's keys against that member's own record (§5.4 step 6).

To **verify a member** `(container, chainId, x25519, ed25519)`, a client reads that container's channel key record on chain `chainId` as TAP-draft-private-channels §3.3 specifies and compares the record's `x25519` and `ed25519` with the member's, as bytes. The outcome is one of:

- **match**: the record is accepted and both keys are equal;
- **mismatch**: the record is definitively not accepted (absent, invalid, expired, or no longer signed by the circuit's current holder), or it is accepted and a key differs;
- **no answer**: the client could not obtain an answer it may adopt (nodes unavailable or disagreeing). No answer decides nothing.

A client **MAY** reuse an accepted record for member verification within the 300-second limit of TAP-draft-private-channels §3.3, so that a sold circuit or a removed record takes effect within minutes. It **MAY** share that cache with other uses of channel key records. It **MUST NOT** cache a "no answer".

### 4. Group ID and group room

All traffic of a group, epoch messages and group messages alike, goes to one room:

```
groupRoom(gid) = SHA-256( "TAP-27/room/v1" ‖ gid )                         (32 bytes)
```

on every relay and ChannelBus the current roster names (§5.2). A room ID is written as 64 hex digits on relays and as `bytes32` on a ChannelBus (TAP-draft-private-channels §10.1).

### 5. Epoch messages (wire type `0x04`)

#### 5.1 Construction

The owner starts epoch `n` by drawing, from a cryptographically secure generator and fresh for every epoch, a 32-byte group key `K`, a 32-byte X25519 private key `e` with `E = X25519(e, 9)`, and a 24-byte nonce `N`. With members `0 … count − 1` in roster order, `R_i` the `x25519` key of member `i` and `rosterObject` the roster of §5.2:

```
commit   = SHA-256( "TAP-27/commit/v1" ‖ K )
header   = 0x04 ‖ gid (16) ‖ uint64(n) ‖ E (32) ‖ N (24) ‖ commit (32) ‖ count (1)      (114 bytes)
kek_i    = HKDF-SHA256( IKM = X25519(e, R_i), salt = "TAP-27/wrap/v1", info = E ‖ R_i ‖ gid ‖ uint64(n), L = 32 )
slot_i   = XChaCha20-Poly1305( kek_i, N, aad = header ).encrypt( K )                      (48 bytes)
slots    = slot_0 ‖ slot_1 ‖ … ‖ slot_(count−1)
roster   = XChaCha20-Poly1305( K, N, aad = header ‖ slots ).encrypt( UTF-8( canonicalJSON(rosterObject) ) )
body     = header ‖ slots ‖ uint32(|roster|) ‖ roster
sig      = Ed25519( owner's ed25519 private key, "TAP-27/epoch/v1" ‖ body )             (64 bytes)
wire     = body ‖ sig
```

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | Wire type `0x04` |
| 1 | 16 | `gid` |
| 17 | 8 | `uint64(n)`, with `n` at most 2^32 − 1 |
| 25 | 32 | `E` |
| 57 | 24 | `N` |
| 81 | 32 | `commit` |
| 113 | 1 | `count`, 1 to 32 |
| 114 | 48 · `count` | `slots`, one per member, in roster order |
| 114 + 48 · `count` | 4 | `uint32(L)`, the length of `roster` |
| 118 + 48 · `count` | `L` | `roster`, the encrypted roster including its 16-byte tag |
| 118 + 48 · `count` + `L` | 64 | `sig` |

A slot is only a wrapped key: it carries no key fingerprint or other identifier of the member it is for. The owner **MUST** erase `e` once the slots are built and **MUST NOT** reuse `K`, `e` or `N` in another epoch. The first epoch of a group is 0, and each later epoch is one more than the previous; an owner whose epoch counter would pass 2^32 − 1 creates a new group.

#### 5.2 Roster

The owner builds the roster object with exactly these keys (`bus` only when present) and **MUST** encode it as canonical JSON:

| Key | Type | Rule |
|---|---|---|
| `v` | number | `1` |
| `kind` | string | `"tape.group/roster"` |
| `gid` | string | `gid`, 32 bare hex digits |
| `epoch` | number | `n` |
| `issued` | number | Integer Unix seconds: when the owner built the message |
| `prev` | string | 64 bare hex digits: `SHA-256` of the roster plaintext bytes of epoch `n − 1` exactly as they were sent (the bytes a member decrypted, never a re-encoding); 64 zeros for epoch 0 |
| `owner` | object | `{ "container": "0x…", "chainId": number }`: the owner |
| `members` | array | `count` entries in member order, each exactly `{ "container", "chainId", "x25519", "ed25519" }`: `container` is `0x` and 40 hex digits in lowercase; `chainId` is an integer from 1 to 2^53 − 1 (TAP-10 §12.1); `x25519` and `ed25519` are `0x` and 64 hex digits in lowercase. `members[0]` is the owner |
| `relays` | array | At most 4 relay references `{ "url", "container" }` under TAP-draft-private-channels §5; may be empty |
| `bus` | string | Optional: the address of a ChannelBus on the chain TAP-draft-private-channels §12.1 names, `0x` and 40 hex digits |

No two entries of `members` share a (`container`, `chainId`) pair, an `x25519` key or an `ed25519` key. Every `x25519` passes TAP-draft-private-channels §4.2 and every `ed25519` passes its §4.3. The owner **SHOULD** name at least one relay or a bus.

Example (informative; the full value is in `epoch.json`):

```json
{"epoch":0,"gid":"678391a8b4bcd8e6fd09112d3b525e66","issued":1789000000,"kind":"tape.group/roster",
 "members":[{"chainId":56,"container":"0x0000000000000000000000000000000000000a11","ed25519":"0xa12d…749b","x25519":"0x7d5b…8b62"}, …],
 "owner":{"chainId":56,"container":"0x0000000000000000000000000000000000000a11"},"prev":"0000…0000",
 "relays":[{"container":"0x3e1a3e1a3e1a3e1a3e1a3e1a3e1a3e1a3e1a3e1a","url":"https://relay.example/tapeapi/v1"}],"v":1}
```

#### 5.3 Size

An epoch message is one wire message, and an owner **MUST NOT** post one larger than 16,448 bytes (TAP-draft-private-channels §10.2). Its length is `114 + 48 · count + 4 + L + 64`, with `L` at least 16. With relay URLs whose characters are ASCII and need no escaping in JSON, the largest epoch message the rules of §5.2 allow (32 members, every `chainId` 2^53 − 1, four relays with 512-character URLs, and a bus) is 12,186 bytes; a group of 32 members on one chain with one relay of usual length takes about 9,500 bytes.

#### 5.4 Acceptance

A receiver processes epoch messages one at a time, and the epoch it holds never decreases. An epoch message is **well formed** when its first byte is `0x04`; its length is at least 246 and at most 16,448 bytes; `count` is 1 to 32; its length equals `114 + 48 · count + 4 + L + 64` for the `L` read at offset `114 + 48 · count`; and the value of its epoch field is at most 2^32 − 1. A receiver **MUST** reject a message that is not well formed, and **MUST** accept a well-formed message only if all of the following hold, checked in this order; a rejected message changes no state.

1. **Owner.** `gid` is the group's, and `sig` verifies (§2) as the owner's Ed25519 signature over `"TAP-27/epoch/v1" ‖ body`, where `body` is the wire without its last 64 bytes. The owner's key is the `ed25519` of the owner's channel key record, read when the receiver joined (§7).
2. **Duplicates and equivocation.** Two epoch messages are the **same** when their `body` bytes are equal. If the receiver has already accepted a message for epoch `n`, the same message is a duplicate and is ignored without error. A different message for the same `n` that passes step 1 is evidence that the owner equivocated (§5.6): the receiver **MUST** reject it and **MUST** report the equivocation to the application. A receiver **SHOULD** remember the `body` hash of every epoch message it accepted for the epochs from 64 below the newest it accepted up to the newest; an epoch it no longer remembers is handled by step 3.
3. **Newer.** `n` is greater than the epoch the receiver holds, and not below the minimum epoch it was given after a restart (§10).
4. **Key.** With its channel X25519 private key `r` and public key `R`, the receiver computes `X25519(r, E)` once, rejecting the message if that fails or gives 32 zero bytes, derives `kek` as in §5.1 with its own `R`, and tries every slot. Exactly one slot **MUST** open, and `SHA-256("TAP-27/commit/v1" ‖ K)` for the `K` it yields **MUST** equal `commit`.
5. **Roster.** `roster` decrypts under `K`, `N` and `aad = header ‖ slots`; the plaintext is strict JSON (TAP-draft-private-channels §2) whose value is an object, and:
   - `v` is 1 and `kind` is `"tape.group/roster"`; `gid` and `epoch` equal the header's;
   - `issued` is an integer, not more than 3,600 seconds after the receiver's clock and not more than 2,592,000 seconds (30 days) before it;
   - `owner` names the owner (its `container` compared case-insensitively, and its `chainId`);
   - `members` has exactly `count` entries, each in the form of §5.2 with no other keys, and passes the uniqueness rule and key checks of §5.2;
   - `members[0]` is the owner, and its `ed25519` equals the owner's key of step 1;
   - the entry at the index of the slot that opened in step 4 is this receiver: its `container` and `chainId` are the receiver's, and its `x25519` and `ed25519` are the receiver's own keys;
   - if the receiver holds epoch `n − 1`, `prev` equals the bare hex of `SHA-256` of the roster plaintext bytes it decrypted for `n − 1`;
   - `relays` and `bus` satisfy §5.2.

   The receiver hashes the plaintext bytes as received and never re-encodes them; it does not require them to be canonical. It ignores keys of the roster object that this TAP does not define.
6. **Channel key records.** The receiver verifies every member of the roster (§3), the owner included. Any mismatch rejects the message. If any verification gives no answer, the receiver **MUST NOT** install the epoch and **MAY** process the same message again later; it is not rejected for good.

A receiver **MUST** present the roster of every epoch it installs to its application, so that membership changes can be shown to users.

#### 5.5 Installing an epoch, and the previous epoch

When a receiver accepts epoch `n` it installs it: `n` becomes the epoch it holds, and the epoch it held before, `p`, becomes the **previous epoch**. Every epoch older than `p` is discarded with its keys. Under the previous epoch the receiver:

- **MUST NOT** accept any group message 600 seconds or more after it installed `n`, and then discards `p`;
- **MUST** reject group messages from a sender whose (`container`, `chainId`) is absent from the roster of `n`;
- **MUST** reject group messages from a sender after it has accepted a group message from that same sender under `n`.

A receiver **MUST NOT** accept group messages under any epoch other than the one it holds and the previous epoch.

#### 5.6 Equivocation evidence

Two wires `w1` and `w2` are evidence that the owner of a group equivocated when both are well formed (§5.4), carry the same `gid` and the same `n`, have different `body` bytes, and both signatures verify under step 1 with the owner's key. Anyone who knows the owner's key can check such evidence. A receiver that reports an equivocation **SHOULD** keep both wires.

### 6. Group messages (wire type `0x05`)

#### 6.1 Construction

A member **MUST** send only under the epoch it holds, with its own index `s` in that epoch's roster:

```
key_s  = HKDF-SHA256( IKM = K, salt = gid ‖ uint64(n), info = "TAP-27/sender/v1" ‖ uint32(s), L = 32 )
header = 0x05 ‖ gid (16) ‖ uint64(n) ‖ uint32(s) ‖ uint64(seq) ‖ nonce (24)                    (61 bytes)
ct     = XChaCha20-Poly1305( key_s, nonce, aad = header ).encrypt( plaintext )
sig    = Ed25519( the sender's ed25519 private key, "TAP-27/msg/v1" ‖ header ‖ ct )          (64 bytes)
wire   = header ‖ ct ‖ sig
```

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | Wire type `0x05` |
| 1 | 16 | `gid` |
| 17 | 8 | `uint64(n)`, with `n` at most 2^32 − 1 |
| 25 | 4 | `uint32(s)`, the sender's index |
| 29 | 8 | `uint64(seq)` |
| 37 | 24 | `nonce` |
| 61 | `|plaintext|` + 16 | `ct` |
| end − 64 | 64 | `sig` |

`nonce` is 24 bytes drawn from a cryptographically secure generator for every message; it **MUST NOT** be derived from `seq` or from other state. The plaintext **MUST NOT** exceed 16,000 bytes, so a group message is 141 to 16,141 bytes.

#### 6.2 Sequence numbers

`seq` is an unsigned 64-bit integer that **MUST** strictly increase for each sender within an epoch. Whenever a sender installs an epoch or restarts, it **MUST** set its next `seq` to a value that is at least `floor(unix milliseconds) · 2^16` and greater than any `seq` it knows it has used; it then adds one per message. A sender therefore needs no saved state to avoid reusing a `seq`, and one that keeps its last `seq` (§10) is also safe against a clock that stepped back.

#### 6.3 Receiving

A receiver **MUST** process a group message in this order and **MUST** reject it, changing no state, at the first step that fails:

1. The first byte is `0x05`, the length is 141 to 16,448 bytes, `gid` is the group's, and the value of the epoch field is at most 2^32 − 1.
2. Epoch `n` is the epoch the receiver holds or its previous epoch (§5.5), and `s` is below the number of members of that epoch's roster.
3. `sig` verifies (§2) with the `ed25519` key of `members[s]` in that epoch's roster over `"TAP-27/msg/v1" ‖ header ‖ ct`, where `header` is the first 61 bytes and `ct` lies between `header` and the last 64 bytes. The receiver **MUST** verify the signature before it decrypts or changes any state, including for its own messages.
4. If `s` is the receiver's own index, the message was sent under the receiver's own identity; the receiver **MAY** stop here and ignore it without error.
5. If `n` is the previous epoch, the rules of §5.5 hold for sender `s`.
6. `seq` is greater than the highest `seq` the receiver has accepted from `s` in epoch `n`.
7. `ct` decrypts under `key_s` with `aad = header`. A receiver that delivers the plaintext as text **MUST** decode it as UTF-8 at this step and **MUST** reject an authentic message that is not valid UTF-8 without consuming its `seq`.

The receiver then records `seq` as the highest accepted from `s` in epoch `n`. It **MUST** accept a gap (a `seq` more than one above the previous highest) and **SHOULD** report it to the application, as TAP-draft-private-channels §9 does for frames: as `seq − high − 1` when that is below 2^16, and otherwise as a gap of unknown size (the sender restarted).

### 7. Invites and joining

To invite a container, the owner reads its channel key record (§3) and posts to that container's inbox room, on one or more of the relays and buses its record lists under `inbox`, a sealed inbox wire (TAP-draft-private-channels §6.1, wire type `0x03`) whose content is:

| Key | Type | Rule |
|---|---|---|
| `v` | number | `1` |
| `kind` | string | `"tape.group/invite"` |
| `gid` | string | `gid`, 32 bare hex digits |
| `owner` | object | `{ "container": "0x…", "chainId": number }`: the owner |
| `relays` | array | Optional: at most 4 relay references (TAP-draft-private-channels §5) on which the group room can be read |
| `bus` | string | Optional: a ChannelBus address, as in §5.2 |

The owner then posts an epoch message that includes the new member to the group room (§9). The invite and the epoch message go to different rooms: an owner that posts only the epoch message leaves the new member nothing to read.

A container that opens such an invite from its inbox:

1. requires `v` = 1, `kind` = `"tape.group/invite"`, `gid` of 32 bare hex digits, an `owner` with a `container` of `0x` and 40 hex digits and a `chainId`, and `relays` and `bus` valid under TAP-draft-private-channels §5; it ignores keys it does not use;
2. reads the owner's channel key record under TAP-draft-private-channels §3.3, from `owner.container` and `owner.chainId`, and takes the owner's Ed25519 key from that record, never from the invite;
3. reads the group room on the relays and bus the invite names, and accepts epoch messages under §5.4.

The invite is trusted for nothing but where to look: a receiver accepts only epoch messages that the owner signed and that list it, so a forged invite cannot make anyone join. Once a receiver has accepted an epoch, it uses the `relays` and `bus` of the roster it holds, which the owner signed, and no longer those of the invite.

The owner's key is fixed when a member joins. There is no transfer of ownership and no change of the owner's keys within a group: a group that needs another owner, or an owner with other channel keys, is a new group.

### 8. Membership changes

- The owner **MUST** start a new epoch when it removes a member, and at least once every 30 days, since receivers reject older rosters (§5.4 step 5). Adding a member also takes a new epoch, since only an epoch message can carry the new member's slot. The owner **SHOULD** also start epochs periodically (RECOMMENDED: at least daily in an active group).
- Whenever it starts an epoch, the owner verifies every member (§3) and **SHOULD** read each record afresh rather than reuse one, since a stale record would keep a sold member for a whole epoch; the first epoch **MAY** use records the owner has just read. A member whose verification is a mismatch is left out of the new roster, and the owner **SHOULD** report it; if any verification gives no answer, the owner **MUST NOT** start the epoch.
- The owner cannot be removed. A removed member keeps every key it already had and can read everything up to the epoch that removed it; it cannot open the slots of any later epoch. A new member cannot read anything before the epoch that added it.

### 9. Delivery

Epoch messages and group messages are wire messages (TAP-draft-private-channels §10.2), posted to the group room (§4) on the relays and bus of the roster the poster holds: on a relay with the `relaySend` method (§11.1 of that draft), on a ChannelBus with `send` or `sendMany` (§12.1 of that draft). A ChannelBus is on BNB Smart Chain whatever the members' home chains (§12.1 of that draft): a group with members on Base (8453) or X Layer (196) uses relays, or a ChannelBus on BNB Smart Chain, each poster posting from an account funded there. Members read the group room as §11.3 and §12.2 of that draft specify, treat identical wire messages that arrive on several transports as one, and pass each to §5.4 or §6.3 by its first byte. Relays keep epoch messages under the protected bound of §11.2 of that draft, which other traffic cannot evict.

A new epoch message is the only checkpoint of a group. The owner **SHOULD** repost the current epoch message, unchanged, whenever it invites a container and at least as often as its transports forget data, so that a member returning from a long absence can catch up (RECOMMENDED: every 30 minutes on a ChannelBus read through public nodes, and every 10 minutes on a relay whose idle rooms expire after 15 minutes). A repost is a duplicate for every member that already holds the epoch (§5.4 step 2).

Note (informative): public BNB Smart Chain nodes measured by the author in September 2026 served `eth_getLogs` for roughly the last 5,000 to 10,000 blocks, about 40 to 75 minutes; the reference relay expires an idle room 900 seconds after its last use (TAP-draft-private-channels §11.2).

### 10. State across restarts

Nothing in this TAP needs saved state to keep confidentiality or authentication: nonces are random and `seq` starts from the clock (§6.2). Three values are still worth keeping:

- A member **SHOULD** persist the highest epoch it has accepted and, after a restart, use it as the minimum epoch of §5.4 step 3. Otherwise a relay can replay an older epoch message, within the 30-day bound on `issued`, that still lists a since-removed member, and the restarted member would send under a key that member holds.
- A sender **SHOULD** persist, after sending, a value at least as large as the last `seq` it used, and start above it after a restart (§6.2).
- The owner persists the roster plaintext bytes of the epoch it holds, which contain no secret, so that the next epoch's `prev` chains to them. An owner that restarts without the key of the epoch it holds can neither send nor read in that epoch, and **SHOULD** start a new epoch at once.

## Rationale

- **An owner, not consensus.** Agreement among many parties on membership is the hard part of group protocols, and much of MLS (RFC 9420) is devoted to it. One owner who signs every roster is simple, verifiable and enough for a group that someone creates and runs. Its cost, a single point of control and of failure, is stated under Security Considerations.
- **Slots without fingerprints, unlike TAP-10 §15.3.** TAP-10's sealed payload gives each slot a fingerprint, `SHA-256(R)[0..8) ‖ wrapped`, 56 bytes per slot, so that a reader finds its slot at once and can tell `damaged` from `not-for-key`; TAP-10's Security Considerations state the other side of that choice, that slot fingerprints reveal which key a message was sealed to. For a TapeSend message, whose sender and recipient are public in any case, this is a reasonable trade. For a group, the member list is what this TAP sets out to hide, and channel key records are public, so fingerprints would let anyone who hashes the published keys read a group's membership. The slots of this TAP are therefore the 48-byte wrapped key alone, and a receiver tries every slot, at the cost of one X25519 and at most 32 AEAD openings per epoch message. What is given up is the distinction between a damaged message and one not sealed to the reader: a receiver whose key opens no slot learns only that.
- **The same primitives as TAP-10, in their own domain.** The suite is TAP-10's suite 1 (§14.1), the key commitment follows TAP-10 §15.3's `D`, and the key wrap binds `E ‖ R ‖ gid ‖ uint64(n)` as TAP-10 binds `E ‖ R ‖ X`. Every label begins with `TAP-27/` and differs from TAP-10's and from the channel draft's, so no key, ciphertext or signature of one protocol can be taken for another's.
- **A key commitment in the signed header.** XChaCha20-Poly1305 is not key-committing: a malicious owner could build a roster ciphertext that opens under two keys, or wrap different keys for different members. Committing to `K` in the header the owner signs makes every member hold the same key or reject the message (`negative.json` has an owner that tries).
- **An encrypted roster.** The channel draft hides from relays who talks to whom. Publishing a group's member list in clear would undo that, so the roster travels under the epoch key, and the slot count is all that shows.
- **Per-sender keys and random nonces.** Every member encrypts under keys derived from one epoch key; separate keys per sender keep senders apart, and a 24-byte random nonce makes a collision negligible without any counter to save. A nonce built from `seq` would need state that survives restarts: a member that restarted and accepted the same epoch again would reuse a (key, nonce) pair and reveal the XOR of two plaintexts.
- **Signatures, not MACs.** With only a shared key, any member could forge another member's messages. Ed25519 signatures with each member's published key let every member verify the sender. The cost, non-repudiation inside the group, is stated under Security Considerations.
- **Verifying every member against its record, at every epoch.** A roster is only the owner's word. Checking each entry against the member's own holder-signed record stops an owner from putting keys it controls under another container's name, and re-checking at every epoch drops a circuit that has been sold.
- **A chained, dated roster.** `prev` lets a member that follows the group detect a roster that does not descend from the one it holds; `issued` bounds how old a replayed epoch message can be. The future bound only rejects nonsense and is wide, 3,600 seconds, so that an owner whose clock runs a few minutes fast does not silently stop its group.
- **At most 32 members.** Every member of a group this size can check every other member's record at every epoch, and the largest epoch message the roster allows, 12,186 bytes (§5.3), fits one wire message with room to spare. A format for larger groups is not part of this TAP; it would be proposed separately.

## Backwards Compatibility

This TAP changes nothing in TAP-10 and nothing in TAP-draft-private-channels: it uses the wire types `0x04` and `0x05` that the channel draft reserves for group messaging, and relays and ChannelBus carry them as they carry any wire message. A client that does not implement this TAP drops them (TAP-draft-private-channels §10.2) and ignores group invites, whose `kind` it does not know (§6.1 of that draft).

**Historical name.** This specification was first published in the TapeAPI repository as TAP-27 (renamed TAPI-27 on 2026-09-30; neither is a TAP number). The number of this TAP is assigned by the editors. The strings `tape.group/roster` and `tape.group/invite` were fixed under the old name and are frozen.

**Labels.** The labels of §4 to §6 still begin with `TAP-27/`: `TAP-27/room/v1`, `TAP-27/wrap/v1`, `TAP-27/commit/v1`, `TAP-27/epoch/v1`, `TAP-27/sender/v1`, `TAP-27/msg/v1`. In #11 the editors asked for the labels of the channel draft to use a prefix that does not look like a TAP number, and said that the same applies to `TAP-27/`. The author agrees, and these labels will change to `tape-group/…`, with the same suffixes, before merge. The new labels will ship with the next major version of the reference implementation, TapeAPI 2.0: it holds these labels as frozen constants of its version 1 and makes breaking changes only in a major version. The test vectors and the Reference Implementation commit will be updated in the same change.

**Larger groups.** The reference implementation also carries, as an experimental option, a second format for groups of up to 128 members. It is not part of this TAP and would be proposed separately. It marks the high half of the epoch field, so every receiver that follows this TAP rejects its epoch messages and group messages (§5.4, §6.3).

**Differences from the reference implementation** at the commit below, and the planned changes, none of which changes a message that the reference implementation produces:

1. Member verification reads channel key records as the reference implementation reads them for the channel draft, which differs from TAP-draft-private-channels §3.3 in the ways listed in that draft's Backwards Compatibility (item 2); the planned option that follows §3.3 exactly will cover group verification too.
2. The reference member verifier (`api.groupVerifier()`) reads records only on the chain its client is configured for. For a member on another chain it fails with `GROUP_INVALID`, the same code as a rejection, so such an epoch is not installed and the application cannot tell the cause from the code; an application can pass a verifier that reads each member's own chain. The verifier will do so by default, and will report a failure to read as no answer.
3. The reference receiver is more lenient than §5.2, §5.4 and §7 on four points: it accepts a roster that begins with a UTF-8 byte order mark (which strict JSON excludes), a member `chainId` above 2^53 − 1, a roster `owner` or invite `owner` without `chainId` (taken as 56) and a roster without `relays` (taken as empty); and it checks only that an invite's `owner.container` is a string. The reference owner produces none of these inputs. The receiver will be tightened to this draft in a 1.x release, as an erratum.
4. The reference invite reader also recognises an invite key `format`, used by the experimental larger-group format, and refuses values other than 1 and 2 instead of ignoring the key. This will stay until that format is proposed or withdrawn.

The wire formats, labels and signatures are unchanged, so every group in use remains valid.

## Test Cases

Test vectors are in `assets/tap-draft-private-groups/` (directory name as asked in #7). Every file gives inputs and exact expected outputs:

| File | Covers |
|---|---|
| `epoch.json` | §4, §5.1 to §5.3: three members with their keys, `gid`, `K`, `e`, `N` and `issued`; the group room, `E`, `commit`, header, roster object and its exact bytes, each member's X25519 output, `kek` and slot, the roster ciphertext, the owner's signature and the epoch message |
| `messages.json` | §6.1, §6.2: the three sender keys of that epoch and two signed messages (one with non-ASCII text), with header, ciphertext and signature |
| `membership.json` | §5.5, §6.3, §7, §8: a sealed invite to member-1's inbox room; epoch 1, which removes member-2, with `prev`, slots and sender keys; messages in both epochs; and a sequence of steps with expected outcomes: messages still in flight under the previous epoch accepted, a removed member's and a moved-on sender's previous-epoch messages rejected, the previous epoch expiring after 600 seconds, and the removed member unable to accept epoch 1 |
| `negative.json` | §5.4, §5.5, §6.3: 50 cases, each with the receiver's state and clock: forged, re-signed and tampered epoch messages; an owner giving one member another key; equivocation and duplicates; rollback with and without a persisted minimum epoch; the 30-day and 3,600-second bounds at and past their limits; malformed, non-canonical-form and inconsistent rosters; broken `prev` chains; replayed, reattributed, tampered, cross-group, out-of-range and wrongly keyed messages; gaps; non-UTF-8 text; oversize wire messages |

The epoch message, sender keys and messages of `epoch.json` and `messages.json` are those of `spec/vectors/tap-27-group.json` at the commit below, which `spec/vectors/verify.py`, an independent Python implementation, recomputes. The reference implementation at that commit reproduces every value and every outcome in the four files; the positive values have also been recomputed from their inputs with the Python primitives of `verify.py`. Channel key records (§5.4 step 6) are taken, in the vectors, to hold exactly the keys listed.

## Reference Implementation

[BruceLanLan/tapeapi at `fda84db889d2a732915f264a799af24073177a85`](https://github.com/BruceLanLan/tapeapi/tree/fda84db889d2a732915f264a799af24073177a85) (TapeAPI 1.3.0, MIT licensed):

| Component | Location |
|---|---|
| Groups: `createGroup`, `joinGroup` (with `minEpoch`), `resumeGroup`, `openGroupInvite`, `acceptEpoch`, `seal`, `open`, `addMembers`, `removeMembers`, `rotate`, `inviteFor`, `snapshot` | `sdk/src/group.js` |
| Posting an epoch message and its invites in one call; reading an inbox for invites | `sdk/src/group-delivery.js` (`deliverGroupUpdate`, `checkGroupInvites`) |
| Member verifier over channel key records | `sdk/src/index.js` (`api.groupVerifier()`) |
| Inbox sealing, relay and bus transports, key checks | `sdk/src/channel.js` |
| Tests | `sdk/test/group.test.mjs`, `sdk/test/audit-group.test.mjs` |
| Vectors and independent check | `spec/vectors/tap-27-group.json`, `spec/vectors/verify.py` |

Reference error codes (informative): `GROUP_INVALID` for a rejected epoch message or group message, `GROUP_EQUIVOCATION` for §5.4 step 2, with the SHA-256 of both `body`s. The same commit also contains the experimental larger-group format (`tap-27-group-v2.json`, `group-v2.test.mjs`), which is not part of this TAP. No part has had an independent audit.

## Deployments

This TAP deploys no contract. Groups can be carried by the ChannelBus of TAP-draft-private-channels, whose deployment is recorded there and was read back again for this draft:

| Chain (chainId) | Contract | Address | Implementation it must point to | How to verify read-only | Sealed? |
|---|---|---|---|---|---|
| BNB Smart Chain (56) | ChannelBus | `0x486110c35d9b90a9d6D85c8063A065f9e7b6b707` | None: not a proxy; the address holds the code itself | `eth_getCode` returns 977 bytes with keccak256 `0xfad4937dfb5166b2cf9621b5c6d05a137c0136c38e08ba6ee08a8de01dce6be0`; `MAX_WIRE()` (`0x1d5cb38c`) returns 16,448 and `MAX_BATCH()` (`0x950bff9f`) 16 | Not applicable: no owner, no storage, no upgrade path |

Read back on 2026-09-30 at 14:53 UTC from two operators: `bsc-dataseed.bnbchain.org` (block 124927880) and `bsc-rpc.publicnode.com` (block 124927883); both returned the same code and constants.

Channel key records are read through the TapeOut and site contracts listed under TAP-10 Deployments, which are upgradeable and not yet sealed; this TAP therefore follows TAP-10's status path (Candidate until they are sealed, TAP-01 §5.1).

## Security Considerations

**What the design protects.**

- **Confidentiality** of rosters and group messages against relays, nodes, ChannelBus observers and non-members, given that members' X25519 private keys and every party's randomness are sound.
- **Removal.** A removed member cannot open any slot of a later epoch, so it cannot read what is sent under later epochs. Its messages under the previous epoch are rejected once a receiver has installed the epoch that removed it (§5.5).
- **Late joiners.** A new member receives only the key of the epoch that added it and cannot read earlier epochs.
- **Sender authentication.** Every group message is signed with the sender's published Ed25519 key, checked against the sender's own holder-signed record; members cannot impersonate each other, and a relay cannot move a message to another sender, epoch or group.
- **One key for everyone.** The signed commitment makes every member who accepts an epoch hold the same `K` and read the same roster.
- **Detectable equivocation.** An owner that signs two different epoch messages for one epoch is caught by any member that sees both, and the two wires prove it to anyone who knows the owner's key (§5.6).
- **Replay, reordering and rollback.** Strictly increasing `seq` rejects replayed and reordered messages. The epoch a member holds never decreases; a persisted minimum epoch and the 30-day bound on `issued` limit how far a member can be rolled back after a restart.
- **Hidden roster.** Slots carry no fingerprint and the roster is encrypted, so relays and chain observers, even one that reads every channel key record on chain, learn the number of members and not who they are.

**What it does not protect.**

- **What a removed member already has.** A removed member keeps every key and message it received, can read everything sent before its removal, and can pass it on. Removal takes effect for each sender only when that sender installs the new epoch: until then, a sender that has not yet received the new epoch message still sends under the old key, which the removed member holds.
- **The owner is trusted for membership, and is a single point.** The owner decides who is in the group and can add anyone at any time, itself included under another container it controls; members see every roster, and applications should show changes. It can split the group by withholding epoch messages from some members, stop the group by not starting epochs (members reject rosters older than 30 days), and leave a removed member in place by not starting an epoch. An attacker who holds the owner's Ed25519 key controls membership in the same way. The owner cannot read what it does not have a slot for, cannot impersonate members, and cannot give members different keys undetected. There is no owner transfer.
- **Members are trusted for confidentiality.** Any member can reveal `K` or plaintexts to outsiders. A thief of a member's X25519 key reads every epoch sealed to it until the owner starts an epoch without that member, or the record is replaced and the owner re-verifies; a thief of its Ed25519 key can sign as that member meanwhile.
- **Forward secrecy per epoch only.** A leaked epoch key exposes all messages of that epoch, and there is no recovery within an epoch. Rotate epochs (§8).
- **Non-repudiation inside a group.** Unlike a two-party channel, a group message is signed with the sender's published long-term key, so any member can prove to a third party what another member said. Applications that must not create such evidence use two-party channels.
- **Metadata.** Relays and chain observers see the group ID, the room, the number of members (the slot count), the sender's index, and the size and time of every message; on a ChannelBus, also the posting account, for ever. A relay sees the network addresses of whoever posts and polls. The nodes a member asks for channel key records learn which containers it looks up at every epoch, and so can infer the roster; members that do not want this use their own nodes. Lengths are not padded.
- **Clocks.** The 30-day bound and the 3,600-second future bound rely on members' clocks. A member that does not persist its highest epoch can, after a restart, be rolled back to any epoch message less than 30 days old that it is shown, including one that still lists a since-removed member (§10). A sender whose clock stepped back and that kept no state may have messages rejected as replays until the clock passes its previous high.
- **One identity, one device.** Two devices holding one channel identity each start `seq` from their own clock, so receivers reject the messages of whichever device has the lower `seq` as replays or reordering.
- **Stale readers and denial of service.** A member offline longer than its transports keep data cannot catch up until the owner reposts an epoch message; messages sent in between are lost to it, and the gap is visible. Relays can drop or delay traffic, as for channels.
- **Invites.** A forged invite cannot make anyone join, since it brings no epoch message the owner signed, but it can make a container contact a relay an attacker chose, and so expose its network address to that relay.
- **Before the TAP-10 seals.** Member verification rests on channel key records and so on TAP-10's contracts. Until they are sealed, whoever controls them can impersonate containers and holders (TAP-10 Security Considerations), and groups inherit that trust.
- **Randomness and endpoints.** Reusing `e`, `N`, `K` or a message nonce, or a weak generator, breaks confidentiality. Implementations in garbage-collected languages cannot guarantee that erased secrets leave memory. Nothing here stops a member from recording or leaking what it receives.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
