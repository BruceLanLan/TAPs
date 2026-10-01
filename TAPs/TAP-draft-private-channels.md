---
tap: TBD
title: Private Channels Between Containers
description: Holder-authorised channel keys, a triple Diffie-Hellman handshake and an encrypted frame format that let two circuit containers talk privately and in real time over relays, the ChannelBus contract or a direct connection.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/11
status: Draft
type: Standards
created: 2026-09-30
requires: TAP-10, TAP-11, TAP-draft-signed-responses
license: CC0-1.0
---

# TAP-TBD: Private Channels Between Containers

## Summary

A way for two TapeOut containers to open a private, fast conversation with each other, in which only the two of them can read what is said and each can be sure who the other is.

## Abstract

This TAP defines a **channel**: an end-to-end encrypted, mutually authenticated, ordered stream of messages between two circuit containers. It specifies a **channel key record** that the circuit's holder signs (EIP-712) and publishes in the container's DeWEB site; an **invite** that one party seals to the other's key and posts to the other's **inbox room**; a three-message **handshake** whose keys come from three X25519 Diffie-Hellman operations bound to a transcript of both identities; an encrypted **frame** format with per-direction keys and counter nonces; the **wire messages** that transports carry; and three transports: a **relay** published as a service, the **ChannelBus** contract, which carries wire messages as event logs, and an optional direct connection. Identities, endpoint IDs, key checks and chain reads follow TAP-10. The channel's confidentiality, integrity and ordering never depend on the transport.

## Motivation

TAP-10 gives every container a site and a mailbox. TapeSend writes every message to the chain: each costs gas, takes a block, and makes who wrote to whom public for ever; a key that later leaks opens every message sealed to it. That fits mail. It does not fit conversations that need many messages a second between two parties who must not be overheard: a card game with hidden hands, a negotiation, a service streaming results to one client, two agents coordinating. Today every such application would invent its own protocol, its own key distribution and its own server, and none of them would be bound to the on-chain identities the rest of DeWEB trusts.

This TAP provides that channel and nothing else. Keys are authorised by the circuit's holder and lapse when the circuit changes hands. Past conversations stay private if a long-term key leaks later (forward secrecy). Messages travel off chain by default, through relays that see only ciphertext; when no operator is wanted, the chain itself carries them through an ownerless, stateless contract. Games, state machines and settlement are left to applications built on top.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms and notation

- **Container**, **holder**, **processor contract**, **pinned block**, **strict agreement**, **hub**, **site store**: as defined in TAP-10 §1. The hub address is the one listed under TAP-10 Deployments (`0xe61A9C7213a6Aa616C246a2B569e555B417b25ee`, the same on every chain).
- **Endpoint ID**: `endpoint(container, chainId) = uint32(0) ‖ uint64(chainId) ‖ container`, exactly as TAP-10 §12.1 defines it, including its rejection of a `chainId` above 2^53 − 1.
- **Initiator** (A) and **responder** (B): the party that sends the invite and the party that receives it. `sA`, `SA` and `sB`, `SB` are their static X25519 private and public keys; `eA`, `EA` and `eB`, `EB` their ephemeral ones.
- **Service**: a container that publishes a service manifest as TAP-11 §3 specifies and answers calls as TAP-draft-signed-responses §3 and §4 specify. The relay transport (§11) and the relay references of §3.1 and §5 depend on these two drafts; the rest of this TAP depends only on TAP-10 and on the canonical JSON of TAP-11 §6 (§2).
- **Wire message**: the unit every transport carries (§10).
- Notation follows TAP-10 §1: `‖` is concatenation, `uint64(x)` and `uint32(x)` are big-endian, ASCII labels such as `"TAP-26/frame/v1"` are their raw bytes without a terminator. `DH(x, Y)` is X25519 (RFC 7748) of private key `x` and public key `Y`. HKDF-SHA256 is RFC 5869, written `HKDF-SHA256(IKM, salt, info, L)`; HMAC-SHA256 is RFC 2104; ChaCha20-Poly1305 is RFC 8439 (12-byte nonce); XChaCha20-Poly1305 is draft-irtf-cfrg-xchacha-03 (24-byte nonce). "Hex" means lowercase hexadecimal; a field described as "`0x` hex" carries the prefix, one described as "bare hex" does not.
- The labels in this TAP begin with `TAP-26/`. They are fixed constants and do not refer to any TAP number (see Rationale).

### 2. Canonical JSON and strict parsing

`canonicalJSON(v)` is the canonical JSON of TAP-11 §6: RFC 8785 (JCS) together with that section's items 1 to 5 (repeated member names; numbers that are not finite or are negative zero; integers whose absolute value exceeds 2^53 − 1; the member names `__proto__`, `constructor` and `prototype`; unpaired UTF-16 surrogates). An implementation **MUST** refuse to produce a canonical form for a value that has none under that section, and **MUST** reject input that needs one.

A **strict JSON** text is UTF-8 without a byte order mark, parses as JSON (RFC 8259) and has neither a repeated member name nor a member named `__proto__`, `constructor` or `prototype` (TAP-11 §6 items 1 and 4). Every JSON text this TAP receives (records, invites, handshake messages) **MUST** be parsed strictly; a text that is not strict JSON is rejected.

### 3. Channel key record

#### 3.1 File and format

A container's channel identity is a file in its DeWEB site at the site-store path `.well-known/tape-channel.json` (no leading `/`), at most 4,096 bytes, whose content is a JSON object with these members:

| Member | Type | Rule |
|---|---|---|
| `tapechannel` | string | `"1"` |
| `container` | string | The container, `0x` and 40 hex digits; compared case-insensitively |
| `chainId` | number | The container's home chain (TAP-10 §2.1) |
| `x25519` | string | `0x` and 64 hex digits: the static X25519 public key |
| `ed25519` | string | `0x` and 64 hex digits: an Ed25519 public key (RFC 8032). Not used by this TAP; reserved for group messaging defined elsewhere. It is signed and **MUST** pass §4.3 |
| `issued` | number | Integer, Unix seconds |
| `expires` | number | Integer, Unix seconds |
| `sig` | string | `0x` and 130 to 2,048 hex digits (65 to 1,024 bytes): the holder's signature (§3.2) |
| `inbox` | object | Optional. `relays`: optional array of at most 4 relay references `{ "url": string, "container": string }` under the rules of §5; `bus`: optional ChannelBus address, `0x` and 40 hex digits, on the chain §12.1 names |

Other members are ignored and are not covered by the signature.

Example (informative):

```json
{ "tapechannel": "1", "container": "0x86DDaEF00401E3F10418398D67D7189fc458eA95", "chainId": 56,
  "x25519": "0xad438bfae31f6c093d61d4339255ea798092c9fadd07b97827f4b0ae9dee7c1c",
  "ed25519": "0x66f975e51bd242b7d52b0744c933af11734a4a5888054cc13485b822ca7427ad",
  "issued": 1789000000, "expires": 1790000000, "sig": "0x6b59…091c",
  "inbox": { "relays": [ { "url": "https://relay.example/tapeapi/v1", "container": "0x3e1a3e1a3e1a3e1a3e1a3e1a3e1a3e1a3e1a3e1a" } ] } }
```

#### 3.2 The holder's signature

The holder signs EIP-712 typed data with:

```
EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
  name = "TapeAPI", version = "1", chainId = the record's chainId,
  verifyingContract = 0xe61A9C7213a6Aa616C246a2B569e555B417b25ee   (the TAP-10 hub)

ChannelKeys(address container,bytes32 x25519,bytes32 ed25519,bytes32 inbox,uint64 issued,uint64 expires)
```

`inbox` in the struct is the hash of the record's `inbox`, normalised:

```
norm  = { "relays": [ { "url": r.url, "container": r.container } for each r in inbox.relays ] }   -- [] when absent
        plus "bus": inbox.bus, only when inbox.bus is present
inbox = keccak256( UTF-8( canonicalJSON(norm) ) )
```

Each relay is reduced to exactly `url` and `container`; strings are hashed as they appear in the record. The digest is `keccak256(0x19 ‖ 0x01 ‖ domainSeparator ‖ hashStruct)` with the standard EIP-712 encoding (addresses and `uint64` values padded to 32 bytes, `bytes32` values as they are). The signature therefore covers the keys, the validity period and where invites to the container go.

`sig` is accepted when either:

- it is 65 bytes `r ‖ s ‖ v`, with `v` in {27, 28} after mapping 0 and 1 to 27 and 28, 0 < `r` < n, 0 < `s` ≤ n/2 (n the secp256k1 order), and ECDSA recovery over the digest (the digest itself, without an EIP-191 prefix) yields the holder; or
- the holder has code and `holder.isValidSignature(digest, sig)` (EIP-1271, selector `0x1626ba7e`) returns data whose first 32 bytes are exactly `0x1626ba7e` followed by 28 zero bytes. A revert or any other result means not accepted.

The service delegation of TAP-11 §4.1 uses the same domain with the primary type `Delegation(address container,address signer,uint64 expires)`; because the primary types differ, a signature made for one can never be taken for the other (`channel-keys.json` has the case).

#### 3.3 Reading and verifying a record

A client reads a container's record on the container's home chain, at one pinned block (TAP-10 §5.3), with every read under strict agreement (TAP-10 §5.2), after the chain check of TAP-10 §5.4. It accepts the record only if all of the following hold:

1. The container resolves to a circuit as TAP-10 §4.3 specifies (`token()` on the chain being read, `factory.isCPU`, and `opener.accountOf(processor contract, #ID)` equal to the container). The holder is `ownerOf(#ID)` (TAP-10 §4.2 step 4);
2. The implementations of the site store and the payment contract are both accepted under TAP-10 §6.1; otherwise the client stops with `store-changed`. The remaining site statuses of TAP-10 §6.2 (`not-opened`, `blocked`, `unpaid`) do not apply to this file: a channel is messaging, and TAP-10 §12.2 excludes them for messaging;
3. The file is read and verified as TAP-10 §7.1 specifies; its declared size is 1 to 4,096 bytes, its `sha256Hash` is not all zeros, and its length and SHA-256 match;
4. It is strict JSON (§2) and every member satisfies §3.1; `container` equals the container and `chainId` equals the chain being read;
5. `x25519` passes §4.2 and `ed25519` passes §4.3;
6. With `now` the client's current Unix time: `issued` ≥ 0 and `issued` ≤ `now` + 300; `expires` > `now`; `expires` > `issued`; `expires` ≤ `now` + 31,622,400 (366 days);
7. `sig` is accepted under §3.2 for the holder read in step 1 (for EIP-1271, at the same pinned block);
8. `issued` is not lower than the highest `issued` this client has accepted for the same chain and container. The client **MUST** remember that value when it accepts a record and **SHOULD** persist it.

A client **MAY** reuse an accepted record for at most 300 seconds; after that, and whenever the application asks for a fresh read, it reads again. A client **MUST NOT** cache a failure caused by unavailable or disagreeing nodes.

The result is the container, its chain, circuit and holder, `x25519`, `ed25519`, `issued`, `expires`, the relays and bus of `inbox`, and the container's inbox room (§6.1).

#### 3.4 Publishing, replacing and withdrawing

The holder writes the record through the site store like any site file. A replacement **MUST** carry a higher `issued` than the record it replaces. The holder withdraws the identity by removing the file. Holders **SHOULD** keep `expires − issued` at most 90 days and renew. Because step 7 checks the current holder, a record stops verifying as soon as the circuit changes hands.

### 4. Static keys

#### 4.1 Key kinds

Both parties of a channel authenticate with static X25519 keys of one kind, which the invite names in `keys` (§5):

| `keys` | Static key | Support |
|---|---|---|
| `"tape-channel/v1"` | `x25519` of the party's channel key record (§3) | REQUIRED |
| `"tapesend/v1"` | The party's TAP-10 messaging key, obtained by resolving its endpoint as TAP-10 §12.2 specifies and applying TAP-10 §14.4 steps 1 to 3 (`keyFor` at a fresh pinned block under strict agreement; `suite` 1; `usable` true; the key checks). Step 4 does not apply | OPTIONAL |

An implementation that does not support a kind **MUST** reject an invite that names it. An implementation **MUST NOT** derive a TAP-10 private key other than as TAP-10 §14.2 permits.

A client **MUST** obtain a peer's static key only as this table specifies, and **MUST NOT** take it from any message of this TAP.

#### 4.2 X25519 key checks

Every X25519 public key a client looks up or receives (a static key, `invite.e`, `accept.e`, the `E` of a sealed invite) **MUST** pass TAP-10 §14.4 step 3: 32 bytes, top bit of byte 31 clear, little-endian value below 2^255 − 19, not one of the listed low-order points; any X25519 error or an all-zero shared secret also means rejection. A failed check abandons the handshake or the record.

#### 4.3 Ed25519 key check

An Ed25519 public key **MUST** be 32 bytes that decode to a point of Ed25519 (RFC 8032 §5.1.3), and that point **MUST NOT** be of small order.

### 5. Invite

The initiator draws a random 16-byte channel ID `cid` and a fresh ephemeral key pair `(eA, EA)`, and builds a JSON object:

| Member | Type | Rule |
|---|---|---|
| `v` | number | `1` |
| `kind` | string | `"tape.channel/invite"` |
| `cid` | string | `cid`, 32 bare hex digits |
| `e` | string | `EA`, 64 bare hex digits |
| `exp` | number | Integer Unix seconds; at most 3,600 seconds after the time of sending (RECOMMENDED: 600) |
| `from` | object | `{ "container": "0x…", "chainId": number }`: the initiator. REQUIRED |
| `keys` | string | The key kind (§4.1). REQUIRED |
| `relays` | array | Optional; at most 4 relay references `{ "url", "container" }` on which A listens |
| `bus` | string | Optional; the address of a ChannelBus, on the chain §12.1 names, on which A listens |
| `webrtc` | object | Optional (§13) |

- A relay reference's `url` **MUST** be an `https` URL of at most 512 characters (`http` is allowed only for a loopback host, for development) and its `container` **MUST** be the relay's service container, `0x` and 40 hex digits. The client reaches a relay by resolving that container as TAP-11 §2 specifies; the `url` is only a hint. A reference without `container` cannot be used and makes the invite or record that contains it invalid.
- An invite **SHOULD** name at least one relay or a bus; one that names neither can only be answered out of band.
- The whole invite is hashed into the handshake (§8), so every member, including `webrtc`, **MUST** have a canonical form (§2).
- Channel IDs are compared as bytes.

The initiator obtains the responder's static key per §4.1 before sending, and seals nothing to any other key.

### 6. Delivering an invite

#### 6.1 Inbox rooms and sealed invites (wire type `0x03`)

Every container that has a channel key record has an **inbox room**:

```
inboxRoom(container, chainId) = SHA-256( "TAP-26/inbox/v1" ‖ endpoint(container, chainId) )     (32 bytes)
```

on every relay and ChannelBus that its record lists under `inbox`. To post content `m` (a JSON object) to B's inbox, a sender with B's record `x25519` key `R`:

```
e  = 32 random bytes;  E = X25519(e, 9);  N = 24 random bytes;  room = inboxRoom(B)
K  = HKDF-SHA256( IKM = DH(e, R), salt = "TAP-26/inbox/v1", info = E ‖ R ‖ room, L = 32 )
C  = XChaCha20-Poly1305-Encrypt( K, N, UTF-8(canonicalJSON(m)), aad = "TAP-26/inbox/v1" ‖ E ‖ room )
wire = 0x03 ‖ E ‖ N ‖ C                                                        (at most 16,448 bytes)
```

and posts `wire` to `room` on one or more of B's listed transports. The sender **MUST** use fresh `e` and `N` for every wire and **MUST** erase `e` after use. Anyone may post; nothing in the wire authenticates the sender, and the handshake does not rely on it doing so.

The recipient opens a wire with its static private key `r` (`R = X25519(r, 9)`): it checks `E` (§4.2), derives `K` the same way, decrypts, and requires strict JSON (§2) that is an object with `v` = 1 and a string `kind`. It dispatches on `kind`: `"tape.channel/invite"` is handled under §7; other kinds are defined by other specifications and are ignored by a client that does not implement them. A wire that fails any step is dropped.

#### 6.2 Other transports

An invite may reach the responder by any other transport, for example a TapeSend message sent as TAP-10 §15 and §16 specify. In that case TAP-10 governs the message completely: it is sealed to the recipient's usable TAP-10 key (TAP-10 §14.4, §15.3), and the content is the invite object. This TAP defines no other encapsulation. A TAP-10 client that does not implement this TAP decodes such content as `unsupported` (TAP-10 §16) and does nothing with it.

Whatever the transport, the responder treats the invite under §7; no transport vouches for the invite's contents or sender.

### 7. Handshake

#### 7.1 Accept (B → A)

On an invite, the responder:

1. requires `v` = 1, `kind` = `"tape.channel/invite"` and every rule of §5; `now < exp ≤ now + 3600`; `e` passes §4.2;
2. looks up the initiator's static key from `from.container` and `from.chainId`, by the kind `keys` names (§4.1). If the lookup fails, or the party found is not the one `from` names, it stops;
3. **SHOULD** refuse a `cid` it has already accepted, remembering accepted IDs until their `exp`;
4. draws a fresh ephemeral key pair `(eB, EB)`, computes the keys and tags of §8, and **MUST** erase `eB` once they are computed;
5. posts to the room `toInitiator` (§10.1) of the first transport the invite names that it can reach, in the order the invite lists them (relays, then the bus), and **MAY** post to all of them, the handshake message:

```json
{ "t": "accept", "cid": "<32 bare hex>", "e": "<EB, 64 bare hex>", "confirm": "<confirmResponder, 64 bare hex>" }
```

An `accept` or `ready` **MAY** carry additional members, such as `webrtc` (§13); receivers ignore members they do not use.

The responder **MAY** send frames immediately after `accept`, but **MUST NOT** accept any inbound frame until it has verified `ready` (§7.2).

#### 7.2 Ready (A → B)

The initiator listens for `accept` on every relay and bus the invite names, from sending the invite until `exp`. For each `accept` whose `cid` matches, while `now < exp`:

1. `e` passes §4.2; the initiator computes §8 and compares `confirm` with `confirmResponder` in constant time;
2. an `accept` that does not verify is discarded, creates no session, and does not end the wait;
3. after the first `accept` that verifies, the initiator **MUST** erase `eA`, posts to `toResponder` on the transport the `accept` arrived on

```json
{ "t": "ready", "cid": "<32 bare hex>", "confirm": "<confirmInitiator, 64 bare hex>" }
```

   and **MUST NOT** complete the same handshake again.

The responder verifies `ready.confirm` against `confirmInitiator` in constant time and accepts `ready` only while `now < exp`.

The initiator's pending state (`eA` and everything derived from it) **MUST NOT** be persisted or copied: completing one handshake twice would derive the same keys and restart the frame counters, reusing nonces. A handshake whose state is lost is restarted with a new invite.

### 8. Key schedule

```
inviteHash = SHA-256( UTF-8( canonicalJSON(invite) ) )                    -- the invite object exactly as received
transcript = SHA-256( "TAP-26/transcript/v1" ‖ cid ‖ endpointA ‖ endpointB ‖ SA ‖ SB ‖ EA ‖ EB ‖ uint64(exp) ‖ inviteHash )
ikm        = DH(eA, SB) ‖ DH(sA, EB) ‖ DH(eA, EB)                         -- B computes DH(sB, EA) ‖ DH(eB, SA) ‖ DH(eB, EA)
okm        = HKDF-SHA256( IKM = ikm, salt = transcript, info = "TAP-26/keys/v1", L = 128 )
kAB ‖ kBA ‖ cA ‖ cB = okm                                                  -- 32 bytes each
confirmInitiator = HMAC-SHA256( cA, "TAP-26/confirm/initiator" ‖ transcript )
confirmResponder = HMAC-SHA256( cB, "TAP-26/confirm/responder" ‖ transcript )
```

`endpointA` = `endpoint(from.container, from.chainId)` and `endpointB` the responder's endpoint ID; `cid` is 16 bytes. `kAB` encrypts frames from A to B and `kBA` frames from B to A; neither is used for the other direction. Implementations **SHOULD** erase `ikm`, `okm`, `cA`, `cB` and the three DH outputs once the tags are computed.

### 9. Frames and sessions

```
frame = uint64(seq) ‖ ChaCha20-Poly1305-Encrypt( key, nonce = uint32(0) ‖ uint64(seq), plaintext, aad )
aad   = "TAP-26/frame/v1" ‖ cid ‖ dir ‖ uint64(seq)          -- dir = 0x00 for A→B (key kAB), 0x01 for B→A (key kBA)
```

- Each direction has its own `seq`, starting at 0 and increasing by 1 per frame. A sender **MUST NOT** reuse a `seq` and **MUST** open a new channel before `seq` reaches 2^32.
- The plaintext is at most 16,384 bytes, so a frame is 24 to 16,408 bytes. A receiver rejects a frame outside that range.
- A receiver **MUST** reject a frame whose `seq` is not greater than the highest `seq` it has accepted in that direction, and **MUST** reject a frame that fails authentication; a rejected frame changes nothing.
- A receiver **MUST** accept a gap (a `seq` more than one above the highest accepted) and **SHOULD** report its size to the application.
- A receiver that delivers plaintext as text **MUST** decode it as UTF-8 before advancing its highest accepted `seq`, and **MUST** reject an authentic frame that is not valid UTF-8 without consuming it.
- There is no authenticated end of a channel; applications that need one send their own final message.

### 10. Rooms and wire messages

#### 10.1 Channel rooms

```
room(dir) = SHA-256( "TAP-26/room/v1" ‖ cid ‖ dir )      toInitiator = room(0x00), toResponder = room(0x01)
```

Messages to the initiator (`accept`, B's frames) go to `toInitiator`; messages to the responder (`ready`, A's frames) go to `toResponder`. A room ID is written as 64 hex digits on relays and as `bytes32` on a ChannelBus.

#### 10.2 Wire messages

| First byte | Content | Posted to |
|---|---|---|
| `0x01` | UTF-8 strict JSON: an `accept` or `ready` object (§7) | A channel room |
| `0x02` | A frame (§9) | A channel room |
| `0x03` | A sealed inbox wire (§6.1) | An inbox room |
| `0x04`, `0x05` | Reserved for group messaging defined elsewhere | — |

Every wire message is 1 to 16,448 bytes. A receiver decodes each wire message independently, drops one it cannot decode or does not implement, and continues with the next. The member order of an `0x01` object is not significant; its bytes are never hashed. A receiver **MUST** treat identical wire messages that arrive on several transports as one.

### 11. Relay service

#### 11.1 Methods

A relay is a service (§1) whose manifest lists these methods. Every implementation **MUST** support this transport. A client resolves the relay from the relay reference's `container` under TAP-11 §2 and calls the methods through the manifest's live endpoints with the requests of TAP-draft-signed-responses §3, verifying each answer under its §8:

| Method | Params | Result | Price |
|---|---|---|---|
| `relaySend` | `{ "room": <64 hex>, "frame": <base64> }` | `{ "i": <integer>, "epoch": <hex> }` | Set by the operator in the manifest; can be zero |
| `relayHandshake` | `{ "room": <64 hex>, "frame": <base64> }` | `{ "i": <integer>, "epoch": <hex> }` | **MUST** be free |
| `relayRecv` | `{ "room": <64 hex>, "after": <integer ≥ −1>, "waitMs": <integer ≥ 0>, "epoch": <hex or null, optional> }` | `{ "frames": [ { "i": <integer>, "frame": <base64> } ], "next": <integer>, "epoch": <hex or null> }` | **MUST** be free |

`frame` is one wire message (§10.2) in standard base64 with padding (RFC 4648 §4). How a priced call is paid is outside this TAP. The channel relies on none of the service protocol's guarantees (such as signed answers) for its confidentiality, integrity or ordering.

#### 11.2 Relay behaviour

- **Rooms.** Only `relaySend` and `relayHandshake` create a room. `relayRecv` on a room that does not exist returns `{ "frames": [], "next": after, "epoch": null }` (after waiting, if asked) and creates nothing.
- **Epoch.** A relay **MUST** give each room a random `epoch` when it creates the room (RECOMMENDED: 8 random bytes); every `epoch` **MUST** match `^[0-9a-f]{1,32}$`. Every method returns the room's current `epoch`.
- **Indices.** Within one epoch, `i` starts at 0 and increases by exactly one for every accepted post, whatever the wire type.
- **Receiving.** `relayRecv` returns stored wire messages with `i > after`, in increasing `i`. If the request's `epoch` is present and differs from the room's (including `null`), the relay **MUST** answer as if `after` were −1. A relay **SHOULD** accept a request without `epoch` and answer it from `after` as given. If nothing is available, the relay **MAY** hold the request up to `waitMs`, capped below its own response deadline, and answer as soon as a message arrives. An answer **MUST** fit the response size cap of TAP-draft-signed-responses §4 (1 MiB): the relay returns as many messages as fit a byte budget, always at least one when any is available. `next` is the last returned `i`; `after` when nothing was returned; −1 when the epoch changed and nothing was returned.
- **Free handshake path.** `relayHandshake` accepts only a wire that decodes to `0x01` followed by a JSON object whose `t` is `"accept"` or `"ready"`, and **MAY** cap its size and the number of such messages per room. Rooms created by this path **SHOULD** have their own count limit and a shorter lifetime until a `relaySend` to the room adopts them.
- **Protected inbox messages.** A relay **MUST** store wire types `0x03` and `0x04` under a bound of their own that other types cannot evict. It **SHOULD** limit such posts per room per source within a window and refuse the excess as a caller error (`BAD_REQUEST`, TAP-draft-signed-responses §6). The **source** is the payer a paid call proves; otherwise the caller's network address; a caller the relay cannot identify counts as one source for the whole room.
- **Bounds.** A relay **SHOULD** bound messages per room, room lifetime, the number of rooms and the number of held requests, and **SHOULD** keep an idle room for at least 600 seconds. It **MAY** drop a room's oldest `0x01`/`0x02` messages. It **MUST NOT** remove a room that has not expired in order to create another; when full, it refuses the new room.

Values used by the reference relay (informative): 22,000 base64 characters per `frame`; 2,048 per handshake frame and 8 handshake messages per room; 256 other messages and 64 protected messages per room; 8 protected posts per source per room per 600 seconds; 1,000 handshake-only rooms living 10 minutes; room lifetime 900 seconds after last use; `waitMs` capped at 20,000 ms; answers budgeted at 512 KiB.

#### 11.3 Client behaviour

A client **MUST** start a room with `after` = −1 and `epoch` = `null`, send the last `epoch` it saw with every `relayRecv`, and reset its cursor to −1 when the returned `epoch` differs. It **MUST NOT** trust a relay for content, order or completeness; §9 provides all three. Handshake messages **SHOULD** be sent with `relayHandshake` when the manifest prices `relaySend`.

### 12. ChannelBus

#### 12.1 Interface

A ChannelBus is a contract with this interface. A ChannelBus named in a record (§3.1) or an invite (§5) is on BNB Smart Chain (chainId 56), where the deployment listed under Deployments serves; any contract with this interface and behaviour serves equally.

```solidity
uint256 public constant MAX_WIRE = 16448;                  // MAX_WIRE()  0x1d5cb38c
uint256 public constant MAX_BATCH = 16;                    // MAX_BATCH() 0x950bff9f
event Wire(bytes32 indexed room, bytes wire);              // topic0 0x46fffab6f2033c7dc33390d2a1329b6809abdcb8baf711dc44a9144ccf4b1431
error EmptyWire();                                         // 0x959c5c96
error WireTooLarge(uint256 length);                        // 0xd4b92400
error BadBatch();                                          // 0x86bdc25c
function send(bytes32 room, bytes calldata wire) external;         // 0x4fdf7085
function sendMany(bytes32 room, bytes calldata packed) external;   // 0x95b97a92
```

- `send` emits one `Wire(room, wire)`. It reverts `EmptyWire` for an empty `wire` and `WireTooLarge(length)` above 16,448 bytes.
- `sendMany` parses `packed` as 1 to 16 repetitions of `uint16(length) ‖ wire` and emits one `Wire` per element, in order, each checked as for `send`. It reverts `BadBatch` if `packed` is empty, holds more than 16 elements, or ends inside a length or an element.
- The contract has no owner, no fee, no storage, no payable function and no upgrade path, and the event carries no sender.

`room` is a room ID of §6.1 or §10.1 and `wire` the raw wire message (not base64). Anyone may post; posts that fail to decode or authenticate change nothing for the parties. A party **SHOULD** post from an account it uses for nothing else: the posting account, the time and the size of every post are public for ever.

#### 12.2 Reading

A reader collects the `Wire` logs of the bus address whose topic1 is a room it reads (or all `Wire` logs of the bus, filtered locally), and processes them in (block number, log index) order.

1. Every query **MUST** use explicit numeric block ranges; the end of a range **MUST NOT** be above the pinned block of TAP-10 §5.3 for that chain.
2. Agreement between nodes **MUST NOT** be required. The reader queries its nodes independently and takes the **union** of their answers, identifying a log by (block hash, or block number when absent; log index; transaction hash; data) and dropping logs marked `removed`. A range is read once at least one node has returned all of it. A node that refuses a range as too large, or returns more logs than it or the reader accepts, has the range split, down to a single block, which **MAY** be read from `eth_getBlockReceipts`.
3. **Hold, never skip.** The reader **MUST NOT** move its cursor past a block unless some node returned that block's logs, or every configured node refused that block with a permanent answer (for example: the method is not served, or the block is older than the history the node keeps) that the reader had recorded before the current poll and that the node repeats in it. Any other failure holds the cursor, and logs already returned during a held poll are kept for the next.
4. On every poll, and when resuming from a saved cursor, the reader **MUST** re-read at least the 16 blocks below its cursor, and **SHOULD NOT** hand over a log it has already handed over.
5. A reader with no saved position **SHOULD** start at least 600 blocks before the pinned block.

Frames authenticate themselves (§9), so a node can only withhold messages (another node supplies them, or §9 reports a gap) or add ones that fail to decode.

### 13. Direct transport (OPTIONAL)

Parties **MAY** carry wire messages over a WebRTC data channel. The initiator's SDP offer **MAY** travel in `invite.webrtc` and the answer in `accept`. Frames on the direct transport are the same frames with the same keys and counters, so a channel can move between transports without renegotiation. Whether a DeWEB page may open such a connection is a shell decision under TAP-10 §8.5.

## Rationale

- **Holder-signed channel keys, not the TapeSend key.** The TAP-10 key is derived from a wallet signature over text telling the holder to sign it only on the official TapeSend site (TAP-10 §14.2); a third-party application that asked for it would teach users to ignore that warning. A typed-data record states what it authorises, supports contract holders (EIP-1271), costs one site write, and lapses by itself when the circuit changes hands. The TAP-10 key remains an optional key kind for clients allowed to derive it.
- **Triple Diffie-Hellman.** X25519 cannot sign. `DH(eA,SB) ‖ DH(sA,EB) ‖ DH(eA,EB)` authenticates both sides (each static key takes part), gives forward secrecy (the ephemerals are erased) and resists key-compromise impersonation (a stolen `sA` does not let anyone pose as B to A). It is the core of X3DH without prekeys.
- **Everything in the transcript.** Both endpoints, all four keys, `cid`, `exp` and a hash of the whole invite enter the HKDF salt. Leaving any one out enables unknown-key-share or identity-misbinding attacks. Hashing the whole invite also authenticates its relay list and `webrtc` offer, whatever path the invite took.
- **Counter nonces, strict order, reported gaps.** Keys are unique per channel and direction, so a counter nonce is safe and needs no randomness per frame. Strict monotonicity stops replay and reordering; accepting gaps keeps a lossy transport usable while making every loss visible.
- **Inbox rooms instead of TapeSend for invites.** Posting to an inbox room needs no holder transaction and shows only the room and the size. An earlier version of this design also defined a TapeSend delivery sealed to the channel key instead of the recipient's TAP-10 key; that conflicts with TAP-10 §15.3 step 2, and official clients would show such a message as `not-for-key`. This TAP therefore defines no TapeSend encapsulation: an invite sent by TapeSend is an ordinary TAP-10 message (§6.2).
- **Relays as services.** A relay inherits identity, discovery and call format from the two service drafts and needs no new infrastructure. A long poll is one HTTPS request, which works through proxies, serverless hosts and shell network rules where WebSockets may not. The handshake is free even on a priced relay because the responder must answer before it has any reason to have paid the relay.
- **Epochs and protected inbox storage.** When a relay restarts or a room expires, indices restart at 0; without an epoch a client that remembered index N would silently skip the first N + 1 messages of the new room. Without protected storage and per-source limits, a flood of free frames could push an invite out of a room before its recipient reads it.
- **A contract as the transport of last resort.** A relay needs an operator and can be switched off. ChannelBus has no operator, state or owner; the price is gas and permanent public metadata, which a party accepts by choosing it. Events suffice; storage would cost more and add nothing.
- **Union of node answers for bus logs, not agreement.** TAP-10 §5.2 requires agreement for reads a client must trust. A bus log is not trusted: every frame authenticates itself, a forged log fails to decode, and an omitted one is supplied by another node or reported as a gap. Requiring agreement would stop the channel whenever one node lags, prunes history or refuses `eth_getLogs`. ChannelBus is not a TapeOut contract, so TAP-10 §2.2's rule against learning addresses from messages does not cover it; a bus address in an invite or record is covered by the transcript or the holder's signature.
- **How a record is read.** A channel record decides whom a party encrypts to and authenticates, which is what TAP-10 §12.2 and §14.4 protect with strict agreement at a fresh pinned block, so §3.3 does the same (TAP-11 adopts most of its reads under default agreement). Two site rules of TAP-10 are treated differently, for different reasons. *Activation* (TAP-10 §6.3) decides whether a shell displays a site and is how the site fee is enforced; TAP-10 §12.2 exempts messaging from it, and a channel is messaging, so §3.3 does not check it. TAP-11 does gate a service on activation; the idea issue asks editors about this difference. *Implementation pinning* (TAP-10 §6.1) guards the bytes of every site file a client reads, and TAP-10 forbids reading a site under a store implementation it does not accept, so §3.3 checks it, although TAP-10 §12.2 lets TapeSend proceed without it: TapeSend reads no site file.
- **Fixed labels.** Labels, `kind` values and the record tag are inside deployed key derivations, digests and signatures. They begin with `TAP-26/` because this design was first published under that self-assigned name; they are constants, not references to a TAP number, and never change (Backwards Compatibility). They are disjoint from TAP-10's `TAP-10/…` labels, so no key or digest of one protocol can be taken for the other's.
- **Not chosen:** signing handshakes with the `ed25519` key (a second signature scheme where DH already authenticates, adding non-repudiation the parties may not want); carrying frames as TapeSend messages (a transaction per frame, public metadata, no forward secrecy).

## Backwards Compatibility

This TAP changes nothing in TAP-10: no contract, hub function, payload version or content kind. A TAP-10 client that receives an invite by TapeSend shows it as `unsupported`.

**Historical name.** This specification was previously published in the TapeAPI repository under the self-assigned name "TAP-26" (renamed "TAPI-26" on 2026-09-30, with the related documents TAP-20 to TAP-27 renamed TAPI-20 to TAPI-27). Neither name is a TAP number; the number of this TAP is assigned by the editors. The following constants contain the old name or were fixed under it. They are frozen, do not denote any TAP number, and will never change:

- Labels: `TAP-26/inbox/v1`, `TAP-26/transcript/v1`, `TAP-26/keys/v1`, `TAP-26/confirm/initiator`, `TAP-26/confirm/responder`, `TAP-26/frame/v1`, `TAP-26/room/v1`;
- Strings: `tape.channel/invite`, `tape-channel/v1`, `tapesend/v1`, the record tag `"tapechannel": "1"`, the path `.well-known/tape-channel.json`;
- EIP-712: domain name `TapeAPI`, version `1`, type `ChannelKeys(...)` (§3.2).

**Possible label collision (question for editors).** A future official TAP-26 that chose labels of the form `TAP-26/…` could repeat one of these strings. Distinct suffixes make this unlikely; editors may prefer that such a TAP avoid the prefix or check this list.

**Differences from the reference implementation** at the commit below, and the planned changes (all additive for existing users):

1. The earlier text defined a TapeSend "durable fallback" sealed to the channel key (see Rationale). It is removed here; the SDK's helpers for it will be documented as producing TAP-10 content only, to be sent by a TAP-10 client.
2. The SDK reads a channel key record with its own node quorum at the latest block, derives the container with `hub.accountOf` (plus `factory.isCPU`) rather than `opener.accountOf`, does not check `eth_chainId`, and by default only warns when the site store implementation is not accepted. A mode that follows §3.3 exactly (strict agreement at one pinned block, TAP-10 §4.3, §5.4 and §6.1) is planned as an option, and later as the default.
3. The SDK reads the `tapesend/v1` key with ordinary rather than strict agreement; the same option will cover it.
4. The SDK accepts endpoint `chainId` values up to 2^64 − 1; TAP-10 §12.1 requires rejecting values above 2^53 − 1. All supported chains are far below both limits.
5. The SDK's bus reader computes the end of its ranges differently (the lowest head reported by its quorum, minus 2 blocks); the result is never above the TAP-10 pinned block, so it already meets §12.2.
6. The earlier text did not name the chain of `bus`; the only deployment is on BNB Smart Chain, and §12.1 now says so.
7. The SDK is more lenient than §2, §5 and §7 on two points: its UTF-8 decoder removes a leading byte order mark instead of rejecting the text (as §2 and TAP-10 §16 do), and it accepts `0x`-prefixed or uppercase hex where bare lowercase hex is specified. Both will be tightened.

The wire formats, labels, record format and signatures are unchanged, so every channel, record and deployment in use remains valid.

## Test Cases

Test vectors are in `assets/tap-draft-private-channels/` (directory name to be confirmed by editors). Every file gives inputs and exact expected outputs:

| File | Covers |
|---|---|
| `channel-keys.json` | §2, §3: the record, `inbox` normalisation and hash (with and without `bus`, empty, extra members), domain separator, struct hash, digest, holder signature and recovered address; rejections: a `Delegation` signature presented as `ChannelKeys`, a high-`s` signature, a changed `issued`, a changed relay URL, another chain's domain |
| `inbox.json` | §6.1: endpoint, inbox room, shared secret, `K`, AAD and the sealed invite; rejections: another container, another chain, another key, a flipped byte |
| `handshake.json` | §5, §7, §8: keys, invite and its canonical form, `inviteHash`, the three DH outputs, transcript, `kAB`, `kBA`, `cA`, `cB`, both confirmation tags, `accept` and `ready` |
| `session.json` | §9, §10.1: both rooms and four frames (one empty, one with non-ASCII text) with their nonces and AADs |
| `wire.json` | §10.2, §11, §12: wire bytes and base64, relay parameters (examples), `send` and `sendMany` calldata, the `Wire` event encoding |
| `channel-bus.json` | §12.1: reverts and successes of the deployed contract (empty, 16,448 and 16,449 bytes; empty, 16-, 17-element and truncated batches) |
| `negative.json` | §4 to §10: low-order, non-canonical and top-bit X25519 keys; small-order and off-curve Ed25519 keys; invites that expired, expire too far ahead, name another `from`, an unknown key kind or bad relays, or were replayed; an `accept` over a tampered invite (and the genuine `accept` still completing afterwards); forged and late `accept` and `ready`; frames before `ready`, replayed, reordered, tampered, reflected, too short or too long; non-UTF-8 text frames; unknown and malformed wire messages |

The reference implementation at the commit below reproduces every value. The handshake, session, record and sealed-invite values are also those of `spec/vectors/tap-26-channel.json` and `spec/vectors/tap-26-identity.json` at that commit, which `spec/vectors/verify.py`, an independent Python implementation, recomputes.

## Reference Implementation

[BruceLanLan/tapeapi at `fda84db889d2a732915f264a799af24073177a85`](https://github.com/BruceLanLan/tapeapi/tree/fda84db889d2a732915f264a799af24073177a85) (TapeAPI 1.3.0, MIT licensed):

| Component | Location |
|---|---|
| Handshake, key schedule, frames, rooms, wire messages, inbox sealing, relay and bus transports | `sdk/src/channel.js` |
| `ChannelKeys` typed data and signature checks | `sdk/src/sig.js` |
| Canonical JSON and strict parsing | `sdk/src/canon.js` |
| Record reading and publishing (`chain.channelKeys`, `tx.publishChannelKeys`) | `sdk/src/index.js` |
| Relay room store and methods | `examples/relay-service/relay-core.mjs` |
| ChannelBus | `contracts/src/ChannelBus.sol`, tests `contracts/test/ChannelBus.t.sol` |
| Tests | `sdk/test/channel.test.mjs`, `sdk/test/channel-keys.test.mjs`, `sdk/test/bus-transport.test.mjs`, `examples/relay-service/relay.test.mjs` |
| Vectors and independent check | `spec/vectors/tap-26-channel.json`, `spec/vectors/tap-26-identity.json`, `spec/vectors/verify.py` |

A reference deployment of the relay core runs at `https://relay.tapeapi.fun`; its on-chain name was not activated at the time of writing, so TAP-11 resolves it as `unpaid`. No part has had an independent audit.

## Deployments

| Chain (chainId) | Contract | Address | Implementation it must point to | How to verify read-only | Sealed? |
|---|---|---|---|---|---|
| BNB Smart Chain (56) | ChannelBus | `0x486110c35d9b90a9d6D85c8063A065f9e7b6b707` | None: not a proxy; the address holds the code itself | `eth_getCode` returns 977 bytes with keccak256 `0xfad4937dfb5166b2cf9621b5c6d05a137c0136c38e08ba6ee08a8de01dce6be0`; `MAX_WIRE()` returns 16,448 and `MAX_BATCH()` 16 | Not applicable: no owner, no storage, no upgrade path |

Read back on 2026-09-30 at 09:44 UTC from two operators: `bsc-dataseed.bnbchain.org` (block 124886765) and `bsc-rpc.publicnode.com` (block 124886768); both returned the same code and constants. At 09:49 UTC the cases of `channel-bus.json` were reproduced with `eth_call` at the latest block on both. The code can also be rebuilt from `contracts/src/ChannelBus.sol` at the commit above with solc `0.8.28+commit.7893614a`, optimizer on with 200 runs, EVM `paris`, metadata hash `ipfs`; because the metadata hash is embedded, only byte-identical source reproduces the last 53 bytes.

The EIP-712 domain of §3.2 names the TAP-10 hub proxy address; it is used only as a domain value, and its deployment and seal status are those recorded in TAP-10 Deployments. Records are read through the TapeOut and site contracts listed there, which are upgradeable and not yet sealed; this TAP therefore follows TAP-10's status path (Candidate until they are sealed, TAP-01 §5.1), although ChannelBus itself cannot be upgraded.

## Security Considerations

**What the design protects.**

- **Confidentiality and integrity of frames**, against relays, nodes, ChannelBus observers and anyone who reads an invite in transit, given that each party's static private key and the client's randomness are sound.
- **Mutual authentication.** A completed handshake proves that the peer held the static key its container's record (or TAP-10 key) names at the time of the lookup; a man in the middle who swaps ephemerals or alters the invite produces tags that do not verify (§7, `negative.json`).
- **Forward secrecy.** Once both ephemerals are erased, a later compromise of either static key does not open past channels.
- **Key-compromise impersonation.** A thief of `sA` can pose as A to others but cannot pose as B to A.
- **Replay and reflection.** A replayed invite yields a handshake no one can complete, since only the real initiator holds `eA`; responders also refuse `cid`s they have accepted. Frames replayed, reordered, moved to the other direction or to another channel fail §9.
- **Transfer of a circuit.** A record verifies only against the current holder, so after a transfer neither the new nor the old holder can open new channels with the old record, once the record cache lapses (at most 300 seconds, §3.3).
- **Record rollback.** Whoever can write the site (the holder or an operator it set) cannot put back an older record once a client has seen a newer one (the `issued` floor), and cannot redirect invites without the holder's signature, because `inbox` is signed.

**What it does not protect.**

- **Metadata.** A relay sees room IDs, sizes, timing and the network addresses of whoever posts and polls, and can link the two rooms of a channel. An inbox room identifies its container, so anyone can see that a container received something. On a ChannelBus the room, posting account, time and size of every message are public for ever. A node that serves `eth_getLogs` for named rooms learns which rooms a reader follows, unless the reader fetches all `Wire` logs and filters locally. A direct connection reveals each party's network address to the other.
- **Denial of service.** A relay can drop, delay or truncate traffic; the parties see gaps or silence and can move to another transport the invite names. Junk posted to an inbox room is bounded by relays (§11.2) and fails to open. There is no authenticated end of a channel, so a transport can cut off its tail undetected.
- **Stolen keys and open channels.** A stolen static key lets the thief open new channels as that container until the holder replaces or removes the record or it expires; clients that have seen a replacement refuse the old record, others accept it until `expires` (hence the short validity of §3.4). Removing a record, letting it expire or transferring the circuit stops new handshakes but does not end channels already open; an application that must cut off a removed party re-reads the peer's record and closes the channel itself.
- **Before the TAP-10 seals.** Record reads rest on TAP-10's contracts. Until the factory and hub are sealed, whoever controls them can impersonate containers and holders (TAP-10 §13.8, Security Considerations); channels inherit that trust.
- **Clocks.** Record validity and invite expiry use the client's clock; a badly wrong clock can reject valid records or accept an expired one within the bounds of §3.3 and §7.
- **Non-repudiation.** Frames are authenticated with shared keys, so either party could have produced any frame. An application that must prove to a third party what the other side said needs signatures of its own.
- **Endpoints and the application.** Nothing here stops a peer from recording or leaking what it receives. Implementations in garbage-collected languages cannot guarantee that erased secrets leave memory, and JavaScript gives no constant-time guarantee; each forged tag costs the attacker a fresh handshake.
- **Randomness.** Reusing `eA`, `eB`, the sealed-invite `e` or `N`, or restoring a handshake from a copy (§7.2), breaks confidentiality.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
