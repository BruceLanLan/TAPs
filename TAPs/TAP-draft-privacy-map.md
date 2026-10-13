---
tap: TBD
title: Privacy Map for Container Sites, Messages and Services
description: What TAP-10, TAP-11 and TAP-13 make public today, to whom, what they protect and what they do not, with the section that says so for every item.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/42
status: Draft
type: Information
created: 2026-10-13
requires: TAP-10, TAP-11, TAP-13
license: CC0-1.0
---

# TAP-TBD: Privacy Map for Container Sites, Messages and Services

## Summary

A plain list of what anyone can learn about a TapeOut container, its website, its messages and the online service it runs, and of what stays hidden, so that holders, service providers and authors of later TAPs start from the same facts.

## Abstract

This Information TAP maps the privacy properties of three merged Drafts: TAP-10 (DeWEB access and messaging layers, version 1.1), TAP-11 (service manifest and holder delegation) and TAP-13 (signed responses), at the commits named in §1. For each observer (anyone reading the chain, the nodes a client reads through, a service provider and the network path to it, a shell and the servers a site contacts, the holders of message keys, and whoever receives a signed artefact) it lists what that observer learns, what the three TAPs protect and what they do not, and how the public items link to each other, including the limits of hashes over guessable values. Every item cites the section that establishes it. It states no requirements and proposes no mechanism; it answers part 1 of the Idea in issue #42 for merged TAPs only.

## Motivation

Everything that makes a container's site, messages and services checkable is public: identities, holders, files, manifests, delegations, keys and message metadata live on chain, and signed answers can be shown to anyone. Each TAP describes its own part in its Security Considerations, but nowhere is the whole picture written down. Holders want to know what a chain observer can learn about them; providers are asked what their callers reveal; authors of later payment, agent and messaging TAPs need to know what is already public before they decide what to hide. Issue #42 asked for such a map. The editors answered there that an Information TAP fits a map of this kind and that it cannot oblige other TAPs to consult it; they suggested limiting it to merged TAPs and naming their versions, since a map of drafts that are still changing would date quickly. This TAP follows that suggestion.

## Specification

This TAP is informative throughout. It states no requirements of its own; where it reports a requirement of another TAP, it cites the section that states it.

### 1. Scope and terms

The texts mapped are those in the TAPs repository at commit `075dd834a72c4c5b251d97f183cac9d42d8ccd66`:

| TAP | Status | Version or last change |
|---|---|---|
| TAP-10 | Draft | Version 1.1; file last changed in commit `8dc19e4be6249539f12f3dd9310adee12abc97a5` |
| TAP-11 | Draft | File last changed in commit `339a689dcd3ccb3fc8debba09fa896628f5729ff` |
| TAP-13 | Draft | File last changed in commit `78efad601ddbaf3325ee2ac9f19e8c3a4efbc473` |

All three are merged Drafts (a merge is not an adoption), and their text can still change. Other TAPs, merged or proposed, are not mapped (Rationale).

Terms are those of TAP-10 §1, TAP-11 §1 and TAP-13 §1. In addition:

- **Public** means readable by anyone, without a key, for as long as the chain's history is available.
- **Observer**: a party that can learn something, listed in §2.
- **Links**: two items link when an observer can tell that they concern the same container, wallet or key (§8).

### 2. Observers

| Observer | Reaches | Basis |
|---|---|---|
| **Chain observer** | Every state, event and transaction of every chain in the TAP-10 chain table, including history | TAP-10 §6.3 ("On-chain data is public and anyone can read it"), §10, §13.6 |
| **Node operator** | The read requests a client sends to the nodes it configured, and the client's network address | TAP-10 §5.1–§5.3, §18.2, §18.3 |
| **Provider** | The requests sent to its live endpoints and the caller's network address | TAP-11 Security Considerations ("Privacy"), TAP-13 §3, §7 |
| **Path** | Traffic between client and provider, as far as TLS lets it through; TAP-13's attacker model includes a proxy or CDN on the path | TAP-11 Security Considerations ("Transport and meaning"), TAP-13 Security Considerations |
| **Shell and off-chain servers** | What a shell shows a site, and what a site sends to off-chain servers when the shell lets it | TAP-10 §8.5, Security Considerations (access layer) |
| **Key holder** | Every sealed message whose key slots include a key it holds, including keys of earlier holders | TAP-10 §14.5, §15.3, Security Considerations (messaging layer) |
| **Recipient of an artefact** | Whatever a party passes on, such as a signed envelope or the opened content of a sealed message | TAP-13 §5, Security Considerations ("What the signature proves") |

### 3. Public on chain: identity and sites (TAP-10 Parts I and II)

| Item | What it reveals | Section |
|---|---|---|
| Name, processor contract, #ID, container | The container behind a name, and the name behind a container; anyone can derive one from the other | TAP-10 §3.1, §4.2, §4.3 |
| Holder | The wallet that holds the circuit, at every block; a transfer of the circuit is a public transfer of the NFT | TAP-10 §1 (Holder), §4.3 |
| Opened | Whether the container's opening fee was paid | TAP-10 §1 (Opened) |
| Activation payments | `bind` is called by the holder with the fee in the chain's native coin; `Bound(domainHash, domain, container, paidUntil, paid)` and `ContainerPaid(container, paidUntil)` record the name, the container, until when and how much | TAP-10 §6.3, Appendix A |
| Site files | Every file's path, content type, size, SHA-256 and bytes; files are readable whether or not the name is activated | TAP-10 §6.3, §7.1, Appendix A |
| Site history | `FileSet`, `FileRemoved` and `FallbackSet` record every change; a removed or replaced file stays in the chain's history | TAP-10 §10 ("Nothing on chain can be deleted"), §11, Appendix A |
| Site operators | `OperatorSet(container, operator, setBy, until)` records which address may write the site and until when | TAP-10 Appendix A |

### 4. Public on chain: services (TAP-11)

A manifest is a site file at the registry key `.well-known/tapeapi.json` (TAP-11 §2.2 step 3), so everything in §3 applies to it, history included.

| Item | What it reveals | Section |
|---|---|---|
| `endpoints.live` | The HTTPS URLs at which the service answers, and so the hosts behind the container | TAP-11 §3.2 |
| `endpoints.async` | Whether the service accepts requests as TAP-10 messages | TAP-11 §3.2 |
| `methods` | Method names, prices in BEM, informative parameter and return types, descriptions | TAP-11 §3.3 |
| `payment.escrow` | The escrow address the service names for paid methods | TAP-11 §3.2 |
| `signer` | The address that signs the service's answers | TAP-11 §3.2 |
| `delegation` | The holder's EIP-712 signature authorising the signer, and its expiry | TAP-11 §3.2, §4 |
| `contentSig` | When present, the holder's signature over the rest of the manifest | TAP-11 §5 |
| Earlier manifests | Earlier signers, endpoints and prices stay in the site's history; whoever can write the site can put an older manifest back until its delegation expires | TAP-11 §7.3, Security Considerations ("Site writers") |

Resolving a service reads only public chain state and writes nothing (TAP-11 Security Considerations, "Privacy").

### 5. Public on chain: messages (TAP-10 Part III)

| Item | What it reveals | Section |
|---|---|---|
| Key record | `KeyPublished(container, holder, suite, keyIndex, key, version, chains)`: the container's public key, the holder wallet that published it, the chains on which the holder reads its inbox (the receiving-chains bitmap), and every rotation; `KeyRevoked` likewise | TAP-10 §13.5, §14.3, §14.5 |
| Inbox and outbox entries | For every message: sender container, recipient endpoint (which carries its chain), block number, block time and digest; the outbox links each sent message to its recipient | TAP-10 §12.1, §13.6 |
| `Sent` event | `to`, `from`, `ref`, both indices and the whole payload | TAP-10 §13.5 |
| Public payload | The content in the clear: `subject`, `body`, the sender-claimed `ts`, attachments | TAP-10 §15.2, §16 |
| Sealed payload | The ephemeral key, nonce and key commitment; the number of key slots and an 8-byte fingerprint of each recipient key; the length of the encrypted content, which is not padded | TAP-10 §15.3, Security Considerations ("Metadata is public and permanent") |
| Sending wallet | The transaction's sender, from which a client determines the wallet that sent the message, or that it was sent through a contract (`indirect`) | TAP-10 §18.5 |
| Asset transfers | A transfer attached to a message is an ordinary transaction from the sender's wallet to the recipient's container; the hub never touches it | TAP-10 §16.1, §19, §20 step 4 |
| `ref` | Chosen by the sender, public, unverified | TAP-10 §17 |

TAP-10 states the result in its Security Considerations: who wrote to whom, when, how much, and which chains are used are visible to everyone; only sealed content is protected.

Consequences that follow from the table:

- **Slot count.** A sealed payload has one slot per key it was sealed to (TAP-10 §15.3 step 2: the recipient's key, and the sender's own key when the sender's client adds it). The count shows whether the sender kept a copy it can read.
- **Fingerprints.** A slot fingerprint is the first 8 bytes of the SHA-256 of a published public key, so it names which published key a message was sealed to, and hence the key index in use (TAP-10 §15.3 step 4, Security Considerations).
- **Transfers and sealed claims.** A sealed payload hides an attachment's claim, not the transfer. TAP-10 §19 accepts a transfer only when it comes from the message's sending wallet, goes to the recipient's container, lies at most 3,600 seconds before the message, and no other message from the same sender reached that inbox between the transfer and the message (steps 6, 7, 10, 12 and 14). A chain observer who sees a transfer and a message with these properties can infer that they belong together, without opening the payload.

### 6. What node operators see

A client reads the chain through nodes it configured (TAP-10 §5.1); nothing in TAP-10, TAP-11 or TAP-13 hides those reads from the nodes. From the reads the three TAPs define, a node operator learns:

- which names, containers or circuits a client resolves (TAP-10 §4, §12.2; TAP-11 §2.2), and which site files or manifests it reads (TAP-10 §7.1; TAP-11 §2.2 step 3);
- under strict agreement, every configured node receives the read, not only one (TAP-10 §5.2);
- for messaging, which endpoint's inbox a client lists on each chain it reads (at least the chains of its own bitmap and, as a rule, every active chain), which container's outbox it lists on the home chain (TAP-10 §18.2), and which block and recipient it fetches payloads for (TAP-10 §18.3);
- the client's network address, and any identifier carried in a node URL (TAP-10 §5.1 forbids writing such URLs into public files and offering them to site code; it does not hide the requests).

### 7. What a provider and the path see (TAP-11, TAP-13)

| Item | Who learns it | Section |
|---|---|---|
| The caller's network address and the whole request (`id`, method, `params`, and `voucher` when present) | The provider | TAP-11 Security Considerations ("Privacy"); TAP-13 §3 |
| The request and the answer in transit | Protected by TLS between client and endpoint; a party that terminates TLS in front of the provider (a proxy or CDN) reads them | TAP-11 §3.2 (`https://` URLs), Security Considerations ("Transport and meaning"); TAP-13 §4 (Transport) |
| The caller's identity | Not part of a TAP-13 request: a provider knows only what the network and the request reveal. For rate limiting it uses the host's view of the caller, never a value the client supplies | TAP-13 §3, §7 |
| The chain height the provider used | The client, through the unsigned `block` member | TAP-13 §4 |

No call is written to the chain by TAP-11 or TAP-13. A call becomes public only if a party publishes the request, the envelope or a value derived from them.

### 8. Links

The public items of §3–§5 share identifiers, so an observer can join them:

| Identifier | Links |
|---|---|
| Container address | The site, the manifest, the messaging endpoint on its home chain and every message it sent (TAP-10 §1, §12.1; TAP-11 §3.2) |
| Endpoint ID | One container on one chain; the same container address gives a different endpoint ID on another chain (TAP-10 §12.1) |
| Holder wallet | The circuit (`ownerOf`), its key record (`KeyPublished`), the activation payments, the messages it sent (sending wallet) and the asset transfers it made (TAP-10 §4.3, §6.3, §13.5, §18.5, §19) |
| Signer address | Every service whose manifest names it; TAP-13's Security Considerations note that two services can use the same signer key |
| Endpoint URLs | The container and the hosts that serve it (TAP-11 §3.2) |
| Earlier holders | A transfer of the circuit leaves earlier holders, their key records and their messages in the history; TAP-10 §18.5 and §20 step 3 let clients show that a circuit changed hands |

### 9. Hashes and guessable values

A hash hides a value only when the value cannot be guessed.

- **Signed answers.** The TAP-13 digest covers `keccak256(utf8(id))`, the hash of the canonical request object and the hash of the canonical body (TAP-13 §5). An artefact that carries these hashes without the values hides the values only if they cannot be enumerated: params drawn from a small set (an address, a token ID, a price pair) and short results can be confirmed by hashing the candidates.
- **Message digests.** The inbox digest `keccak256(ref ‖ keccak256(payload))` hides nothing, since `ref` and the payload are in the `Sent` event (TAP-10 §13.5, §13.6).
- **Key commitment.** The commitment `D` of a sealed payload is a hash of a random 32-byte key that is fresh for every message, so it cannot be guessed (TAP-10 §15.3 sealing steps 1 and 3).
- **Fingerprints.** A slot fingerprint is a hash of a public key and identifies that key by design (§5).
- **Files.** A site file's SHA-256 is published with its bytes (TAP-10 §7.1).
- **`ref`.** A `ref` that is the hash of something guessable reveals it; TAP-10 leaves `ref` to the sender (§17).

### 10. What the three TAPs protect

| Protection | Against whom | Section |
|---|---|---|
| Sealed content (`subject`, `body`, `ts`, attachment claims) | Everyone without a key listed in the payload's slots | TAP-10 §15.3 |
| A sealed payload does not open when replayed from another sender, to another recipient, with another `ref`, on another chain or through another hub | Replay across messages | TAP-10 §15.3 ("Because `to`, `from`…") |
| The messaging private key is derived from a wallet signature and is never stored on chain or on a server; the official client keeps the signature and the key on the device | Servers and the chain | TAP-10 §14.2 |
| Node URLs that carry an API key or identify the caller are kept out of public files and away from site code | Visitors of a site, and the site | TAP-10 §5.1 |
| Off-chain requests a site makes are recorded by the shell, which as a rule lists them to the user, and are reflected in its on-chain indication | The user's ignorance of them (it does not stop them) | TAP-10 §8.5, §9 |
| Requests and answers in transit to a live endpoint | The network, up to the TLS endpoint | TAP-11 §3.2, Security Considerations ("Transport and meaning") |
| An `INTERNAL` error carries no upstream node URLs, keys or internal host names | Callers of the service | TAP-13 §6 |

### 11. What the three TAPs do not protect

- **Message metadata.** Sender, recipient, time, chains, size and amounts of attached transfers are public and permanent (TAP-10 Security Considerations).
- **Content length.** Sealed payloads are not padded (TAP-10 Security Considerations).
- **Past messages after a key is exposed.** There is no forward secrecy: whoever later obtains a private key, or the signature it came from, can open every message sealed to it (TAP-10 Security Considerations, §14.2).
- **Messages after a transfer.** Messages sealed to an earlier key stay readable by whoever holds it; a message sealed just before a sale can be readable by the seller (TAP-10 §14.5, Security Considerations).
- **Public messages.** A message to an endpoint without a usable key can only be public, and the sender is told so (TAP-10 §14.4).
- **Deletion.** Nothing on chain can be deleted: files, manifests, key records and messages stay in the history (TAP-10 §10, §13.6).
- **Unlinkability.** None of the three TAPs hides the links of §8.
- **Read privacy.** None of the three TAPs hides from node operators what a client reads (§6).
- **Caller anonymity.** A provider sees the caller's network address and request (TAP-11 Security Considerations).
- **Privacy from a site.** A shell that allows off-chain data cannot promise privacy from the site (TAP-10 Security Considerations, access layer).
- **Signed artefacts once passed on.** A signed envelope proves to anyone who receives it that the service's signer gave that answer to that request at that time (TAP-13 Security Considerations, "What the signature proves"); a signed refusal is a statement the provider cannot later deny (TAP-13 §6). Whoever passes an envelope on passes on the request and the answer with that proof.

## Rationale

- **Merged TAPs only, with their commits.** In #42 the editors noted that an Information TAP goes to Final and then takes errata only (TAP-01 §5.1, §5.3), so a map of drafts that are still changing would date quickly, and suggested limiting it to merged TAPs and naming their versions. TAP-11 and TAP-13 carry no `version` field, so §1 names the commit at which each file was read.
- **No mechanisms.** An Information TAP gives background and states no requirements (TAP-01 §3). Parts 2 to 4 of #42 (where proof systems would and would not help, alternatives that need none, and when not to build one) concern mechanisms that no merged TAP defines; they are left out. In #42 the TapeOut team gave its view on who should learn who pays whom ("Everyone, by default"), as a view and not an editor requirement; payment is not defined by any of the three TAPs mapped here, so this TAP records only what TAP-11 §3.2 and §3.3 publish about prices and the escrow address.
- **Three TAPs, not every merged one.** TAP-01 (process) and TAP-02 (circuit netlists) hold no container, site, message or service data. TAP-12 (Sealed Commitments and Verdicts over TapeSend) is a merged Application Draft built on TAP-10 messages and is not mapped here: the map covers the three TAPs on which the author's own work depends. A section on TAP-12 from someone who relies on it is welcome, as a suggestion on this pull request or in a later revision.
- **Open drafts.** Open drafts in the repository, by pull request number, that bear on privacy include private channels (#12), private groups (#20), AI usage receipts (#26), container agents (#47), payment vouchers (#52) and reviews (#54). Each states its own Security Considerations and may still change. A later Information TAP, or a successor to this one, can map them once they are merged.
- **Observers, not attackers.** The map is organised by who learns what, because that is the question a holder or provider asks. What an attacker can forge is covered by each TAP's own Security Considerations, which this TAP cites and does not repeat.
- **Consequences stated as such.** §5 states three consequences that follow from the cited sections without being written in them (the slot count, the fingerprints, the inferred pairing of transfers with sealed messages). Each names the sections it follows from.

## Backwards Compatibility

None. This TAP changes nothing in any TAP, contract or format.

## Test Cases

None. This TAP states no requirements.

## Reference Implementation

None; there is nothing to implement. As an informative example of §9, one implementation of TAP-11 and TAP-13, TapeAPI 2.0.0 at commit [`e29bcd00a0314946e5d97db9b444f59031e8877c`](https://github.com/BruceLanLan/tapeapi/tree/e29bcd00a0314946e5d97db9b444f59031e8877c), offers verification links that carry the receipt of a TAP-13 answer with `params` and the result replaced by the two hashes the signature covers, and its documentation (`docs/guides/mcp.md`, "Two forms of the link") states the limit of §9: values from a small set can be confirmed by hashing the candidates. As an example of §6, the same release keeps reads of other chains off by default because turning them on sends a client's queries to the public nodes of those chains (`README.md`, "Privacy, plainly").

## Deployments

None. This TAP deploys no contract. The contracts it describes are listed under Deployments in TAP-10 and TAP-11.

## Security Considerations

This TAP describes what TAP-10, TAP-11 and TAP-13 make public; it adds nothing to them and guarantees nothing. A reader who relies on it for a TAP whose text has changed since the commits of §1 should check the current text. An item missing from this map is not thereby protected.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
