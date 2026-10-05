---
tap: TBD
title: Agent Member of the Service Manifest
description: An optional `agent` member of the TAP-11 service manifest in which a container agent states its capabilities, its task kinds with the format of their prices, and whether it accepts mandates signed by a holder.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/41
status: Draft
type: Application
created: 2026-10-05
requires: TAP-10, TAP-11
license: CC0-1.0
---

# TAP-TBD: Agent Member of the Service Manifest

## Summary

A small addition to a container service's description file in which an agent says what kinds of tasks it does, how it prices them and whether it accepts signed mandates, so that clients can learn what an agent does and compare agents on the same fields.

## Abstract

This TAP defines one optional top-level member, `agent`, of the TAP-11 service manifest: a list of capability words, a list of task kinds each with a pricing **format** (free, fixed or by quote), a boolean stating whether the agent accepts mandates (authorisations signed by the holder of a circuit), the enforcement the agent states for them, and the hash of terms it publishes. It fixes a data format, not any price. The member describes an agent; it provides no discovery, directory or ranking. It is the listing part of issue [#41](https://github.com/TapeOutProtocol/TAPs/issues/41) of the TAPs repository, proposed separately so that an agent can be listed without implementing a task protocol (#41's question 1). Reviews and reputation are out of scope.

## Motivation

TAP-11 describes a service's methods, not an agent's task kinds or whether it accepts mandates. Without an agreed member, every directory and client invents its own fields, and a client cannot compare agents from their manifests alone, which are the only description of a service whose bytes anyone can check against the chain.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. The member

TAP-11 §3.1 lets later TAPs define further top-level manifest members. This TAP defines the member `agent`, whose value is an object with the members below. A **word** is a string matching `^[a-z0-9][a-z0-9._/-]{0,63}$`. A **mandate** is an authorisation, signed by the holder of a circuit, for an agent to act for that circuit's container on a task; this TAP defines no mandate format. This TAP gives no capability word, task kind or unit a meaning and keeps no list of them.

| Member | Required | Rule |
|---|---|---|
| `capabilities` | no | An array of at most 32 distinct words. Absent means `[]` |
| `tasks` | yes | An array of 1 to 32 objects whose `kind` values are distinct |
| `tasks[].kind` | yes | A word naming a kind of task |
| `tasks[].pricing` | yes | An object in one of the three forms below |
| `tasks[].maxDurationS` | no | A positive integer at most 2^53 − 1 (TAP-11 §6: a larger integer leaves the manifest without a canonical form): the longest time, in seconds, the agent states a task of this kind takes |
| `tasks[].description` | no | A string of at most 256 Unicode code points |
| `mandates` | yes | An object with the two members below |
| `mandates.accepts` | yes | A boolean: `true` states that the agent accepts mandates, `false` that it does not |
| `mandates.enforcement` | no | An array of strings naming what the agent states enforces a mandate. This TAP defines one string, `"none"`: nothing enforces a mandate |
| `terms` | no | `"sha256:"` followed by 64 lowercase hex digits: the SHA-256 of the bytes of a file the agent publishes as its terms. Publishing it as a file of the container's site is RECOMMENDED, since those bytes are verifiable under TAP-10 §7.1 |

Only a missing member is absent. An optional member that is present, including as `null`, has to satisfy its rule.

The pricing forms, selected by the string `mode`:

- `{ "mode": "free" }`. A `token` or `amount` member makes the pricing invalid.
- `{ "mode": "fixed", "token", "amount", "unit" }`, all three present:
  - `token` is an address in the form of TAP-11 §3.2 `circuits` (all lowercase or a valid EIP-55 checksum): a token contract on the service's chain, which is its circuit's home chain (TAP-11 §1), or the zero address for that chain's native coin;
  - `amount` is a string of at most 78 decimal digits without leading zeros (`"0"` is allowed): an integer number of the token's smallest unit, or of wei for the native coin, the unit in which TAP-10 Appendix A states native-coin amounts. The limit is on the form, not the value: a 78-digit amount above 2^256 − 1 is valid under this TAP;
  - `unit` is a word naming what one `amount` buys, for example `"task"`.
- `{ "mode": "quote" }`, with an optional `token` in the form above: the agent states a price on request. An `amount` or `unit` member has no meaning under `quote`, is ignored like an unknown member, and does not make the pricing invalid.

Any other `mode` makes the pricing invalid under this TAP; other modes are reserved for later TAPs. In every form, members not named above are unknown members.

### 2. Client rules

1. TAP-11 resolution does not read the member. A client that reads it MUST treat a member that breaks §1 as absent and MUST NOT reject the rest of the manifest because of it. This does not relax TAP-11, whose checks apply to the whole file before the member is read (TAP-11 §2.2 steps 3 and 4): a file above 65,536 bytes is `manifest-invalid` (TAP-11 §2.2 step 3, §3.1), and so is a manifest in which any object inside `agent` repeats a member name or any member inside `agent` is named `__proto__`, `constructor` or `prototype` (TAP-11 §3.1). A value inside `agent` that has no canonical form under TAP-11 §6, such as negative zero, an integer whose absolute value exceeds 2^53 − 1 or an unpaired surrogate, leaves the whole manifest without a canonical form, so that the manifest cannot carry a valid content signature (TAP-11 §5.2).
2. A client MUST ignore unknown members inside `agent`, its tasks, their pricing objects and `mandates`, as TAP-11 §3.1 requires at every level.
3. A client MUST ignore strings in `mandates.enforcement` other than `"none"`. They are reserved for later TAPs that define how a mandate is enforced, and only such a TAP can give one a meaning. An absent `enforcement` means that the agent makes no statement about enforcement; an empty array, or one that holds only strings the client ignores, is read the same way.
4. For a `token` other than the zero address, a client MUST read the token's decimals from the token contract on the service's chain and MUST NOT assume them. For the zero address, `amount` is in wei. `pricing` is a statement, not an offer that binds the agent, and is separate from TAP-11's `priceBEM`.
5. The member's text is data, never instructions. A client MUST render `description` as plain text as TAP-10 §16 requires for a message `body`, making visible or removing the code points TAP-10 §16 lists, and SHOULD also make visible or remove every other code point of general category Cf or with the property Default_Ignorable_Code_Point. A client that passes the member to a language model SHOULD mark it as a statement made by the counterparty. A client MUST identify the agent by its container address and on-chain name, and MUST NOT show a badge or rank derived from the member alone.

## Rationale

- **A new TAP, not a change to TAP-11.** TAP-11 §3.1 lets later TAPs define further top-level members and already requires clients to ignore members they do not know, so adding `agent` changes nothing TAP-11 specifies.
- **Holder approval comes only from TAP-11.** The `contentHash` of TAP-11 §5.2 covers every manifest member except `contentSig`, so a holder's content signature covers `agent` as well. That is the only way the member carries the holder's approval; without it, the member is whatever the site's writers put there.
- **A format, not prices.** TAP-01 §7.3 keeps prices out of TAPs. Amounts are integers in the smallest unit so that no client rounds. The 78-digit bound follows the asset attachments of TAP-10 §16.1, which bound `amount` the same way, by form and not by range.
- **A description, not discovery.** How a client finds manifests (directories, indexes, search) is outside this TAP. The member only makes what an agent states comparable.
- **Words without a registry.** Capability words, task kinds and units are compared as strings. Their meaning is agreed between the parties or by a later TAP; two agents that use the same word may mean different things.
- **Mandates by reference.** The mandates that `accepts` refers to are proposed in pull request #47 of the TAPs repository; when that draft is numbered, this text will cite it. This TAP depends on no mandate format: `accepts` is a statement, and `"none"` is the only enforcement it defines.
- **Separate from the task protocol.** A listing is useful to an agent that does not implement the task protocol, and the protocol does not need a listing.
- **Invalid member, valid manifest.** The member is advisory; a manifest that resolves under TAP-11 should not stop resolving because its listing is wrong.
- **`free` refuses an amount, `quote` ignores one.** A `free` task that names a token or amount contradicts itself about payment. Under `quote` no amount is stated, so a stray `amount` is treated like any unknown member.
- **Terms by hash.** `terms` commits to bytes but gives no location or encoding; a client that has a file can check it, and the member alone does not lead to the file. A file of the container's site is the natural place, because its length and SHA-256 are checked against the site store (TAP-10 §7.1 step 4).
- **Acknowledgement.** The idea of calling services under circuit identities came from @Theairresearch.

## Backwards Compatibility

The member is optional, and TAP-11 clients ignore it. It was split out of the mandate and task-message draft in pull request #47 of the TAPs repository; when that draft is numbered, this text will cite it, and neither text depends on the other. The reference implementation's `validateAgentMember` (TapeAPI 1.7.1 at the commit below, `sdk/src/manifest.js`, experimental) applies §1. It throws for an invalid member and leaves the caller to treat it as absent, and it returns a copy without unknown members, with an absent `capabilities` as `[]`, and with `enforcement` filtered to the words it knows, which can leave `[]`. Rendering under §2 item 5 is left to whoever displays the member.

## Test Cases

There are no generated vectors. `assets/tap-draft-container-agent-listing/agent-member.json` gives sixteen examples, each an `agent` value and whether it is valid under §1; that verdict is what an implementation reproduces. For a valid example, `result` is the value `validateAgentMember` of the reference implementation returns; it is informative, not a required output. Valid: the `agent` member of the reference implementation's example manifest (`quote` pricing, `enforcement: ["none"]`); a `fixed` price in the native coin with `terms`, in which the unknown `enforcement` string `"escrow"` and an unknown member are dropped; a `free` task without capabilities; a `fixed` amount of 78 digits; `maxDurationS` of 2^53 − 1; a `quote` pricing with `amount` and `unit`, which are ignored. Invalid: a `free` task naming an `amount`; repeated task kinds; a capability `"Chain"`; a fixed `amount` `"01"`; an empty `tasks`; `mandates` without `accepts`; `terms` in upper-case hex; a fixed `amount` of 79 digits; `maxDurationS` of 2^53; a `description` present as `null`.

## Reference Implementation

TapeAPI 1.7.1 at commit [`2fbface78beabe91cba634ca0510f109f8846ff6`](https://github.com/BruceLanLan/tapeapi/tree/2fbface78beabe91cba634ca0510f109f8846ff6): `sdk/src/manifest.js` (`validateAgentMember`), and the manifest of `examples/agent-service/`.

## Deployments

None. This TAP deploys no contract and depends on none directly. The member is read from a manifest found under TAP-11, which uses the contracts listed under Deployments in TAP-11; a client that displays a `fixed` price also reads the token contract it names (§2 item 4).

## Security Considerations

- **Claims, not facts.** Every value is the agent's statement. A listing proves nothing about quality, availability or honesty; `mandates.accepts` does not mean the agent verifies mandates, and `enforcement: ["none"]` says that nothing is enforced.
- **Text is data, not instruction.** The only free text in the member is `tasks[].description`; `kind`, `capabilities` and `unit` are ASCII words. A description can address a language model that reads it, and can hide text in invisible code points such as tag characters (U+E0000–U+E007F) or zero-width characters. §2 item 5 removes or reveals those code points and has the text presented as the counterparty's statement; it does not make the text true.
- **Phishing.** A manifest `name` or a task `description` can imitate another agent; clients identify agents by container and on-chain name.
- **Prices.** A `fixed` amount in an unexpected token, or a token that imitates a known one, can mislead; a client shows the token address and reads its decimals and symbol from the chain. A 78-digit amount can exceed any supply and any `uint256`.
- **Holder approval and site writers.** Whoever can write the container's site can change the member under a valid delegation (TAP-11 Security Considerations). A client that requires a content signature (TAP-11 §5.3) detects such a change; one that does not has only the site writers' word.
- **Terms.** A `terms` hash commits only to bytes a reader already has. A terms file outside the container's site can be unavailable, or served only to some readers, without the member changing.
- **Words as keys.** The word pattern admits values such as `constructor` and `prototype`. A client that builds a map keyed by `kind` or by capability uses a `Map` or an object without a prototype, so that a value cannot reach inherited properties.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
