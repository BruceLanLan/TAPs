---
tap: TBD
title: Container Agent Mandates Enforced by Escrow Channels, Phase 1
description: Phase 1 of the container-agent Ideas #40 and #41, in which a mandate that names amounts is backed by one escrow channel per capped provider, the agent's key is a session key on those channels only, and every verifier reports enforcement escrow-channel only when the chain shows exactly that.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/40
status: Draft
type: Application
created: 2026-10-08
updated: 2026-10-13
requires: TAP-10, TAP-11, TAP-13
license: CC0-1.0
---

# TAP-TBD: Container Agent Mandates Enforced by Escrow Channels, Phase 1

> **Experimental; not usable on mainnet.** The escrow contract this text relies on is **not audited and not deployed** on any chain, and no escrow instance is on any client's audited list. The rules have been checked only on local chains and in tests (Test Cases), and nothing here charges anyone today. Phase 1 guarantees only what Security Considerations lists as G1 to G5; what it does not guarantee is listed there as N1 to N9.

## Summary

Bounded agents, an experimental design that is not usable on mainnet while the escrow contract it relies on is neither audited nor deployed: an agent may spend for a container, and the most it can lose is fixed by the escrow contract and checkable on chain, because the circuit's holder funds one escrow channel per service the agent may pay and the agent's one-off key can spend only from those channels until the mandate expires.

## Abstract

This TAP specifies **bounded agents** (experimental: the escrow contract is not audited and not deployed, and nothing here is usable on mainnet): an agent may spend for a container, and the most it can lose is fixed by the escrow contract and checkable on chain. The bound is the sum of the balances of the channels the holder funded for the mandate, each one reachable only by the mandate's agent key, only toward the provider it names and only until the mandate expires; a verifier reports the mandate as enforced only when it reads exactly that at one pinned block. This is phase 1 of the container-agent design of issues [#40](https://github.com/TapeOutProtocol/TAPs/issues/40) and [#41](https://github.com/TapeOutProtocol/TAPs/issues/41). It builds on the phase-0 draft in TAPs pull request [#47](https://github.com/TapeOutProtocol/TAPs/pull/47) (mandates and task messages, enforced by nothing), which this text calls **the phase-0 draft**, and changes none of its signed types. It gives meaning to the values the phase-0 draft reserves (§3.8 there: a non-zero cap or token in a mandate), defines the verifier value `enforcement: "escrow-channel"`, and specifies: how each capped scope item maps to one channel `(consumer, provider)` of a TapeAPI escrow instance and how the agent key maps to a session key on it (§3); the static rules (§4); what a verifier reads, at one pinned block, before it reports `escrow-channel` (§5); the session-key and channel rules a holder's console follows (§6); the holder's unsigned transaction plan, its read-back and its close-out (§7); the agent runtime's own spend limit (§8); what providers do (§9); a spend statement a delivery may carry and its reconciliation (§10); and revocation (§11). The escrow enforces the bound; a mandate remains a checked record. Instant revocation, per-task isolation and spending outside metered services are out of scope.

**Builds on drafts not yet merged.** The `requires` field lists only TAPs merged as Drafts: TAP-10, TAP-11 and TAP-13 (merging a Draft does not mean that it is accepted, TAP-01 §5). This text also builds on the following pull requests and issues of the TAPs repository. Each pull request is cited at the commit named here, the version this text was checked against; when one is merged and numbered, `requires` and the references in this text change to its number.

- Pull request [#47](https://github.com/TapeOutProtocol/TAPs/pull/47), *Container Agent Mandates and Task Messages, Phase 0*, at commit [`a95bc703cf32d7999aa51322adf1af8df88dd20f`](https://github.com/TapeOutProtocol/TAPs/blob/a95bc703cf32d7999aa51322adf1af8df88dd20f/TAPs/TAP-draft-container-agent.md): the phase-0 draft. Its terms, signed types, checks, thread rules and reserved values are used as they stand at that commit, and section numbers "of the phase-0 draft" refer to it; this text changes none of its signed types.
- Pull request [#52](https://github.com/TapeOutProtocol/TAPs/pull/52), *Payment Vouchers for Container Services*, at commit [`04519189cfbed7b15240c86cfb9a1aa1285df75d`](https://github.com/TapeOutProtocol/TAPs/blob/04519189cfbed7b15240c86cfb9a1aa1285df75d/TAPs/TAP-draft-payment-vouchers.md): the voucher that the agent key signs and its wire form in a TAP-13 request (§3 there), to which §9 adds unsigned members, and the facts a client reads from the settlement contract (§2.2 there), which §5 reads from the escrow.
- Pull request [#53](https://github.com/TapeOutProtocol/TAPs/pull/53), *TAP-11: let a later TAP read `priceBEM` as a per-call upper bound; name where the escrow's chain comes from*, at commit [`593164785728196c1a00a8ad76428f97323d3da6`](https://github.com/TapeOutProtocol/TAPs/blob/593164785728196c1a00a8ad76428f97323d3da6/TAPs/TAP-11.md): TAP-11 does not fix the chain on which `payment.escrow` is an address, and #53 leaves it to the TAP that defines settlement; this text reads the escrow on the mandate's chain (§5.3 item 3). The reference implementation takes a method's `priceBEM` as the price that §8 and §10.2 use; for a method that #52 prices in US dollars, #53 lets `priceBEM` be read as the most one call can cost.
- Pull request [#49](https://github.com/TapeOutProtocol/TAPs/pull/49), *Agent Member of the Service Manifest*, at commit [`5a3e3ecd5dee13192fe6862dedae769a568671e0`](https://github.com/TapeOutProtocol/TAPs/blob/5a3e3ecd5dee13192fe6862dedae769a568671e0/TAPs/TAP-draft-container-agent-listing.md): §12 gives a meaning to one string its rule 3 reserves.
- Ideas [#40](https://github.com/TapeOutProtocol/TAPs/issues/40) (bounded payment delegation for container agents; the discussion thread of this text), [#41](https://github.com/TapeOutProtocol/TAPs/issues/41) (agent task protocol and agent listings), [#38](https://github.com/TapeOutProtocol/TAPs/issues/38) (payment vouchers, where the escrow interface was discussed) and [#42](https://github.com/TapeOutProtocol/TAPs/issues/42) (what container services and agents make public; see N8 under Security Considerations).
- **The escrow interface.** §5 reads an escrow whose interface and semantics are described by TAPI-22 §3 of the reference implementation at commit [`e29bcd00a0314946e5d97db9b444f59031e8877c`](https://github.com/BruceLanLan/tapeapi/blob/e29bcd00a0314946e5d97db9b444f59031e8877c/spec/TAPI-22.md) (status Experimental; TAPI-22 is not a TAP). A draft that proposes this interface as a Standards TAP will be submitted separately, and this text will then require it instead. Until then, TAPI-22 §3 at that commit is the normative input of §5, and §5.1 restates the part used.

This draft will not be proposed for Review before #47 is numbered and the escrow Standards TAP exists, and its Deployments section stays empty until an escrow instance is audited and deployed.

## Motivation

An agent that works for someone has to pay for the services it calls. Today that means either holding the principal's assets or holding a key that can move them, and then the most the principal can lose is bounded by nothing but the agent's good behaviour and the safety of its machine. The phase-0 draft records who may act for a container and on which task, but enforces nothing: a mandate names no amount, and a payment is an ordinary transfer.

A bounded agent turns this around. Before any work starts, the principal fixes the most it can lose; a contract that neither the agent nor the providers control enforces that figure; and anyone, the principal included, can read the figure on chain instead of trusting the agent's account of it. The agent never holds the principal's assets and never receives the holder key, as #40 proposes for this step; a leaked or misbehaving agent key can cost the principal at most what was put in its channels, and only toward the providers the mandate names.

A TapeAPI escrow channel `(consumer, provider)` already has the needed properties: its balance is a hard ceiling on what can ever be settled to that provider; a session key authorised on one channel signs for that channel only; a session expires and cannot be shortened; and a consumer can recover what is left only after a public, delayed withdraw request. Mapping a mandate onto such channels gives the bound on chain without changing any contract and without changing the mandate type the phase-0 draft fixed.

Independent implementations then need the same answers to: which channel belongs to which scope item; which account is the consumer; when a verifier may say the mandate is enforced; how a console funds, reads back and closes a mandate's channels without funding twice; what an agent may sign; and what a delivery proves about the money. Without one answer, an agent could start work on channels that do not bound it, and a console could fund a key more than the mandate says.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms and notation

- Every term of the phase-0 draft §1 keeps its meaning: **principal**, **holder of the principal**, **agent**, **agent key**, **provider**, **verifier**, **thread**, **problem**, **unavailable**. **Pinned block** and **strict agreement**: TAP-10 §5. **Manifest**, **signer**: TAP-11 §1.
- **Mandate that names funds**: a mandate in which some `scope[i].cap`, `scope[i].token`, `feeCap` or `feeToken` is not zero. Any other mandate is a **phase-0 mandate** and is verified exactly as the phase-0 draft says.
- **Capped scope item**: a scope item with `cap` other than `0`. **Evidence-only item**: one with `cap` `0` and `token` the zero address.
- **Escrow instance**: a contract with the interface of §5.1, holding one ERC-20 token (`token()`). A provider's escrow instance is the address its manifest names as `payment.escrow`, read as in §5.2.
- **Audited list**: the escrow instances a client accepts. It is chosen by the client; this TAP fixes no list. (Informative: the reference implementation's list is empty, and local tests add instances explicitly.)
- **Scope channel** of capped item `i`: the channel `(consumer, scope[i].provider)` on that provider's escrow instance. **Fee channel**: `(consumer, agent)` on the agent's escrow instance, when `feeCap` is not `0`.
- **Funding path** and **consumer**: `holder` (the consumer is the principal's current holder) or `container` (the consumer is the principal container itself), §3.2.
- **Live withdraw request**: a request with `requestedAt ≠ 0` and `now ≤ requestedAt + WITHDRAW_COOLDOWN + WITHDRAW_WINDOW` (§5.1). A request past that time is not live, whatever the escrow's view still returns.
- **Available** on a channel: `channelOf` minus the amount of a live withdraw request on it, never below 0.
- `claimedOf(t)` is the escrow's `claimedOf(consumer, provider)` read at time `t`. Amounts are decimal strings of base units of the instance's token, as `uint256` in phase-0 draft §3.7.

### 2. Overview (informative)

```
principal holder (console)            agent                                provider P_i (TAP-13 service)
  offer ──────────────────────────────►
                                     ◄── accept (agentKey, new for this offer)
  mandate (mode 1, scope[i].cap > 0) ─►
  [chain, holder pays gas] approve(escrow, exact) · fund(P_i, …) · authorizeSession(P_i, agentKey, expires)
  read back: allowance 0, channel, session = expires
                                         check (§5), one pinned block: record claimedOf at start
                                         call P_i with a voucher signed by agentKey ───────► TAPI-22 provider checks
                                                                                       ◄─── signed answer; P_i settles
                                     ◄── deliver (receipts, optional spend statement §10)
  acceptance ─────────────────────────►
  [close-out] requestWithdraw(P_i, all) → after 48 h, within 7 days: withdraw(P_i)
```

### 3. Mapping a mandate onto escrow channels

#### 3.1 Fields

For a mandate that names funds:

| Field | Meaning in phase 1 | On chain | Rule |
|---|---|---|---|
| `principal` | The principal container | — | As the phase-0 draft |
| `agent` | The agent's container; the provider of the fee channel | `channelOf(consumer, agent)` | As the phase-0 draft |
| `agentKey` | A key new for this offer; the session key on each scope channel | `sessionExpiry(consumer, P_i, agentKey)` | §6.1 |
| `mode` | `0`: the agent pays its own upstream calls; `1`: the agent spends the principal's channels | — | §4 |
| `scope[i].provider` | The provider of one channel | `voucher.provider` | A provider appears in at most one capped item |
| `scope[i].token` | The token of that provider's escrow instance | `token()` | Zero exactly when `cap` is `0` |
| `scope[i].cap` | The console's funding target for that channel, in base units of `token` | — | Not a bound by itself: the bound is the channel's balance (§5.3) |
| `feeToken`, `feeCap` | The token and target of the fee channel | `channelOf(consumer, agent)` | Zero together |
| `notBefore`, `expires` | The mandate's window; `expires` is also every scope session's end | `sessionExpiry` | §6.1 |
| `subdelegate` | Still `false` | — | `subdelegate-not-allowed` |

A mandate carries no escrow address. The escrow instance of a provider is the one its manifest names (§5.2).

#### 3.2 Funding paths and the binding rule

The escrow credits `fund(provider, amount)` to `msg.sender`; it has no way to fund for another account. The consumer of every channel of a mandate is therefore the account that funds it:

- **`holder` path**: the consumer is the principal's current holder (phase-0 draft §4), sending ordinary `approve`, `fund` and `authorizeSession` transactions from its wallet.
- **`container` path**: the consumer is the principal container, and the holder sends each call through the container's `execute`. A principal on this path MUST be deployed (have code) and opened; a counterfactual container cannot be a consumer. This precondition holds for this path only; the phase-0 draft's statement that a principal need not be opened is unchanged for phase-0 mandates.

Both paths are allowed. A verifier checks the channels of exactly one consumer per verification, chosen by the caller of the verification; this TAP fixes no default. A voucher belongs to a mandate that names funds when its `consumer` is the principal or the principal's current holder at verification time, its signer is `agentKey`, and its `provider` is a capped item's provider.

The escrow accepts only ECDSA signatures and reads no EIP-1271: a container, or a holder that is a contract, cannot sign vouchers itself and spends only through a session key.

#### 3.3 The `container` path through `execute` (informative)

On the `container` path the holder calls the principal container's `execute(address to, uint256 value, bytes data, uint8 operation)` for each of `approve`, `fund`, `authorizeSession`, `requestWithdraw` and `withdraw`. On BNB Smart Chain the container charges a fee per call, paid to its treasury; it has no getter. A console finds it by simulating a harmless call with `value` 0 from the holder: the call reverts with selector `0xafd49700` and the words `(paid, required)`; it then simulates again with `required` attached, and a call that still reverts is refused (the container is not paid for, not opened, or its circuit is listed: the conditions are not specified by any TAP and can change with an upgrade). A console should accept the fee only up to a maximum the holder states, check that the holder can pay every fee of the plan, and show the total. If a `fund` fails midway, the plan ends with `approve(escrow, 0)`. A verifier reads only the escrow's state and never needs `execute`.

### 4. Static rules

A verifier asked for phase 1 (§5.4) checks a mandate that names funds, without reading the chain, and reports, in this order:

| Order | Check | Problem |
|---|---|---|
| 1 | The form of phase-0 draft §3.2 and §3.7 | `mandate-malformed` (and stops) |
| 2 | Each scope item: `token` is the zero address exactly when `cap` is `0` | `scope-token-cap-mismatch` |
| 3 | `feeToken` is the zero address exactly when `feeCap` is `0` | `fee-token-cap-mismatch` |
| 4 | No provider appears in two capped items | `scope-duplicate-provider` |
| 5 | `mode` `0` has no capped item; `mode` `1` may have them | `mode-scope-mismatch` |
| 6 | `subdelegate` is `false` | `subdelegate-not-allowed` |

It also reports, never refusing, `scope-includes-agent` when a capped item's provider is the agent (statically) or has the same holder as the agent (on chain, §5.3). A static problem is reported like `phase0-no-funds` for the nonce rule: the nonce is not recorded (phase-0 draft §5.2).

### 5. Verifying enforcement

#### 5.1 What the escrow does

The verification reads these views of an escrow instance, whose semantics are those of TAPI-22 §3.1 to §3.3 of the reference implementation at commit [`e29bcd00a0314946e5d97db9b444f59031e8877c`](https://github.com/BruceLanLan/tapeapi/blob/e29bcd00a0314946e5d97db9b444f59031e8877c/spec/TAPI-22.md) (status Experimental; TAPI-22 is the reference implementation's own document, not a TAP), implemented by `contracts/src/TapeAPIEscrow.sol` at that commit (version 3, not audited, not deployed). This section restates the part used; where the two differ, TAPI-22 §3 at that commit prevails.

```
token() → address                                    // the one ERC-20 of the instance
channelOf(address consumer, address provider) → uint256
claimedOf(address consumer, address provider) → uint256
sessionExpiry(address consumer, address provider, address key) → uint64
pendingWithdraw(address consumer, address provider) → (uint256 amount, uint64 requestedAt)
WITHDRAW_COOLDOWN = 172800 (48 hours), WITHDRAW_WINDOW = 604800 (7 days), MAX_SESSION = 2592000 (30 days)
Voucher(address consumer,address provider,uint256 cumulative,uint64 expires)
  VOUCHER_TYPEHASH = 0x8e017cc56e9f2cb1f0fd1af4419f7c77b8d3f92099263f2b8aba4ba44cf50407; domain name "TapeAPIEscrow", version "1"
```

The properties relied on: `settle(consumer, provider, cumulative, expires, sig)` may be called by anyone, accepts a signer that is the consumer or holds a session on that channel still live at settlement (`sessionExpiry ≥ block.timestamp`), takes at most `min(cumulative − claimedOf, channelOf)` out of the channel and pays it to `provider` only, less the maintenance contribution that TAPI-22 §3.4 carves out of the provider's share, and raises `claimedOf` by what it takes; `claimedOf` never decreases. A session is per channel, extend-only, at most `MAX_SESSION` ahead, and cannot be revoked. A withdraw request can be executed only inside `[requestedAt + WITHDRAW_COOLDOWN, requestedAt + WITHDRAW_COOLDOWN + WITHDRAW_WINDOW]`; the escrow never clears a lapsed request from the view; `cancelWithdraw` takes effect at once; a top-up does not restart a request's clock.

#### 5.2 The provider's escrow instance

For each capped item, a verifier resolves the provider under TAP-11 §2 and reads its manifest **at the pinned block of this verification**, from the site store and with the checks TAP-11 §2 uses, never from a copy cached across verifications. The manifest's `payment.escrow` is the provider's escrow instance; a manifest without it, or a provider that does not resolve, is `provider-unresolvable`.

#### 5.3 Checks

Only when the static rules pass, the verifier reads, at one pinned block under strict agreement, with the consumer of the chosen funding path, and reports in this order (items 2 to 6 for each capped item in scope order):

| Order | Check | Problem |
|---|---|---|
| 1 | Phase-0 draft §5.1 steps 3–9 (window, length, expected agent and key, principal, holder signature, nonce, revocation) | As the phase-0 draft |
| 2 | §5.2 | `provider-unresolvable` |
| 3 | The escrow instance is on the verifier's audited list; it has code on the mandate's chain; its `token()` equals `scope[i].token` | `escrow-not-allowed`, `escrow-other-chain`, `escrow-token-mismatch` |
| 4 | `sessionExpiry(consumer, P_i, agentKey)` is not 0 and is `≥ now`, and equals `expires` | `session-missing`, `session-expiry-mismatch` |
| 5 | No live withdraw request (§1); available is above 0 | `withdraw-pending`, `channel-empty` |
| 6 | `channelOf(consumer, P_i) ≤ cap` | `channel-exceeds-cap` |
| 7 | When `feeCap` is not 0: the agent resolves and names an escrow instance (as item 2, `agent-unresolvable`); `sessionExpiry(consumer, agent, agentKey) = 0`; when the caller gives an amount due on the fee channel, available on it is at least that amount | `agent-unresolvable`, `agent-key-on-fee-channel`, `fee-channel-short` |

A verifier MUST judge a withdraw request by the lifetime rule of §1 and MUST NOT judge it by the view alone. A node failure, a disagreement between nodes or a stale pin makes the verification unavailable; it MUST NOT be reported as a problem. An escrow without `token()`, or a token without `decimals()`, is a problem of the counterparty's choice, not an unavailable read (`decimals()` is read for display only; a value above 255 is shown as unknown). A chain problem (items 2 to 7) does not stop the nonce from being recorded: the same mandate can be verified again once the holder has fixed the channel, and a mandate with other content needs another nonce.

When `feeCap` is `0`, the verifier does not read the fee channel.

#### 5.4 Result

A verifier implements phase 1 only on the caller's request (in the reference implementation, the option `enforcement: "escrow-channel"`). Without it, a mandate that names funds is `phase0-no-funds` exactly as in the phase-0 draft.

A phase-1 result MUST state `enforcement: "escrow-channel"` only when every check of §4 and §5.3 passes, and `enforcement: "none"` otherwise. Every phase-1 result MUST also state:

- that the bound is each channel's balance and not the mandate's cap (`bound: "channel"` in the reference implementation);
- the consumer and the funding path;
- for each capped item: `provider`, `escrow`, `token`, `decimals`, `cap`, `channel`, `available`, the withdraw request `{ amount, requestedAt, live }`, `sessionExpiry` and **`claimedAtCheck`** (`claimedOf` at this verification's pinned block);
- for a fee channel, the same readings with the agent key's session on it;
- the warnings (`scope-includes-agent`).

A thread verifier with the same request passes it to the check of the thread's mandate (phase-0 draft §7.4, row `mandate`). The thread's own result states `enforcement: "escrow-channel"` only when the whole thread passes and its applied mandate's check states it; otherwise `"none"`, while the mandate's own check keeps its value. A mandate check's result MUST NOT be presented as an authorisation of any payment beyond what the channels it read can pay.

### 6. Session keys and channels

#### 6.1 One key per mandate, session end equal to `expires`

- An agent MUST announce a new agent key for every offer it accepts (strengthening phase-0 draft §7.3).
- A console MUST NOT call `authorizeSession` for a key that already appears in its session history (§6.3) for another mandate, or for the same mandate with another end. When a session, a channel or a funding path must change, the agent accepts a new key and the holder signs a new mandate. (Re-authorising a key revives the vouchers it signed and did not settle.)
- Every scope session MUST end exactly at the mandate's `expires`. A console SHOULD sign the mandate, check it, and only then authorise the sessions, at or after `notBefore` (the escrow has no "not before").
- A console MUST NOT authorise the agent key on the fee channel.

#### 6.2 One mandate per channel

A console SHOULD follow, and MUST NOT build a plan against, these rules:

1. At most one mandate that names funds uses a channel `(consumer, P)` at a time, and while it does, the holder signs nothing else on that channel.
2. At the start the channel holds at most the cap; top-ups keep it at most at the cap minus what the key has spent (§7.2).
3. A channel is not funded for a new mandate before every earlier key's session on it has ended.
4. A channel with a live withdraw request is not topped up; to continue, `cancelWithdraw` first.
5. What the key spent on a channel is `claimedOf(t) − claimedOf(t₀)`, `t₀` being when the work started (§8). Under rule 1, this is what the agent key spent.
6. When the task ends or the mandate expires, every channel with a balance is closed out (§7.3).

A verifier cannot enumerate the session keys of a channel; rules 1 and 3 rest on the console's session history.

#### 6.3 Session history

A console MUST keep, for every session it authorises, an entry `{ chainId, escrow, consumer, provider, key, expires, mandateHash, claimedAtPlan, block }` (`claimedAtPlan`: `claimedOf` on that channel when the plan first funded it; `block`: the block the plan's facts were read at). A later record of the same session only fills a missing `claimedAtPlan`, never replaces one. A console MAY rebuild missing entries from the escrow's `SessionAuthorized` logs while nodes still serve them; such an entry has no `mandateHash`.

### 7. The holder's plan, read-back and close-out

#### 7.1 The plan

A console builds the holder's transactions from facts read at one pinned block under strict agreement: the principal's current holder; each capped provider's escrow instance (§5.2), its code and `token()`; each channel's balance, live request, `claimedOf` and the agent key's session; on the `container` path also the principal's code, whether it is opened, and the fee the container's `execute` charges (§3.3). The plan is, for each escrow instance, one `approve(escrow, amount)` for exactly the total it funds, then per capped item `fund(P_i, amount)` and `authorizeSession(P_i, agentKey, expires)`; on the `container` path each call goes through `execute` with the fee attached. The console MUST build `approve` only for an escrow on its audited list and only for that exact amount, and MUST NOT build `approve` in any other flow.

The console MUST refuse to build a plan when any of the following holds, and SHOULD report the first in this order: a static rule fails (§4); nothing to plan; the session would end in the past or more than `MAX_SESSION` ahead (`session-expired`, `session-too-long`); the sender is not the principal's current holder (`holder-not-current`); the signed mandate's signer is not the sender (`holder-changed-since-signing`); on the `container` path the principal has no code or is not opened (`principal-not-deployed`, `principal-not-opened`), the fee is above the most the caller accepts per call (`execute-fee-too-high`), the holder cannot pay one fee (`holder-short-of-fee`), or the call still reverts with the fee (`execute-reverts`); the key is recorded for another mandate (`key-reused`); a recorded entry of this mandate or of a channel it funds is at or after the pinned block (`pin-not-after-record`). Then, per capped item: the provider is the agent (`agent-key-on-fee-channel`), the consumer (`provider-is-consumer`) or an escrow of the plan (`provider-is-escrow`); §5.2 and §5.3 item 3 fail (`provider-unresolvable`, `escrow-not-allowed`, `escrow-other-chain`, `escrow-token-mismatch`); the history records this mandate's key toward this provider on another channel that is not released (`funded-elsewhere`, §7.2); the other funding path's channel to this provider holds money or a session of the key (`other-path-funded`); a live request (`withdraw-pending`); the channel is above the cap (`channel-exceeds-cap`); the key has a session on the channel ending at another time (`key-already-authorised`); the session already equals `expires` and the channel is below the cap without a recorded `claimedAtPlan` for this session, or at the cap with anything settled (`channel-spent`); the channel is above the budget (`channel-exceeds-budget`); the budget is 0 on an empty channel without a session (`budget-exhausted`); another recorded key's session on the channel has not ended (`channel-session-live`). Last, on the `container` path, the holder cannot pay every fee of the plan (`holder-short-of-fee`).

A console that is given no session history MUST say so and MUST NOT treat it as an empty history.

#### 7.2 The budget and the cross-channel invariant

For each capped item: **budget** = `cap − Σ released channels elsewhere (claimedOf − their smallest claimedAtPlan) − this channel (claimedOf − this session's smallest claimedAtPlan)`, at least 0, the last term counting only when the key's session on this channel already equals `expires`. The plan funds `budget − channelOf` and never more. A channel elsewhere (another escrow instance of the same provider, or another consumer) recorded for this mandate's key is **released** only when its consumer is this plan's, its entry has `claimedAtPlan`, and it reads, at the pinned block, balance 0, no live request and a `claimedOf`; a channel of another consumer is never released.

The invariant a console MUST keep: for each (mandate, capped provider), what the agent key has spent on every channel the session history records, plus what is still open to it on those channels, is at most the cap, however often the plan is run. A channel the history does not record cannot be seen; this is why a lost history is not an empty one.

#### 7.3 Read-back and close-out

After the plan's transactions are final, a console reads back at a later pinned block: each instance's allowance MUST be 0 (otherwise it sends `approve(escrow, 0)`); each channel plus what the key spent since the plan equals the cap minus what it spent on earlier channels of the mandate; each session equals `expires`. A channel below that target is never topped up from the reading alone: the key may have spent.

Close-out is also the revoke button: for each channel with a balance, `requestWithdraw(P_i, channelOf)`, then `withdraw(P_i)` inside the window. A live request is executed, not re-made (a new request restarts the clock); a lapsed one is re-made. A console MUST NOT show a revocation as complete before every channel's request is live on chain, and MUST show it as not complete again after any `cancelWithdraw` or a missed window.

### 8. The agent runtime

An agent working on a mandate that names funds:

- MUST verify it with phase 1 (§5) before it starts, and MUST NOT start unless the result states `escrow-channel`;
- MUST record, at that starting check and for each capped provider, the escrow instance, the consumer and `claimedAtStart` = that check's `claimedAtCheck`, and MUST NOT move `claimedAtStart` up afterwards;
- MUST NOT sign out a voucher to `P_i` whose `cumulative` is above `claimedAtStart + cap_i`, nor one for another escrow instance, consumer or chain than the start recorded;
- SHOULD record the highest cumulative before the voucher leaves, and MUST NOT sign with a key for which it has no such record;
- SHOULD verify again before every call and every milestone; a live request or an empty channel refuses that step, while another escrow instance, another consumer, another mandate hash, a revoked or an expired mandate stops the work for good;
- SHOULD bound the price of one call (the price the provider published when the work started, or a stated maximum).

These limits bound what a misled agent signs; they do not bound a leaked key (Security Considerations).

### 9. Providers

A provider needs nothing beyond the provider checks of TAPI-22 §3.2 at the commit of §5.1: signer and session live, expiry, cumulative, and at most what is available on the channel counting a live withdraw request. A voucher signed by an agent key MAY carry the unsigned members `mandateHash` and, until the provider has accepted one voucher of that payer, `mandate` (`{ "mandate": <Mandate>, "sig": <hex> }`); a provider that does not check mandates ignores them. A provider that checks mandates MAY additionally accept from an agent key only a cumulative at most one price above the last; this is hygiene and not a bound, since the key holder can settle directly.

### 10. Spend statement in a delivery

#### 10.1 Statement

A `deliver` result of a thread whose mandate names funds MAY carry a member `spend`: an array of at most one entry per capped item, each

| Member | Content |
|---|---|
| `provider`, `escrow` | The capped provider and the escrow instance the work started on |
| `claimedAtStart` | `claimedOf` at the check that started the work (§8) |
| `claimedAtDelivery` | `claimedOf` at the agent's last check before it signed the delivery |
| `spent` | `claimedAtDelivery − claimedAtStart` |

amounts as `uint256` JSON forms. The statement is part of the signed result (phase-0 draft §7.2) and is not covered by `receiptsHash`. An agent MUST NOT include an entry for a channel its last check did not read on the recorded escrow for the recorded consumer, or read below `claimedAtStart`.

#### 10.2 Reconciliation

A verifier with the phase-1 request, given a `spend` member and a mandate that names funds, reports these problems for the delivery (phase-0 draft §8), in this order: `spend-evidence-malformed` (not an array, more entries than capped items, an entry without the form of §10.1, or a provider named twice); `spend-provider-out-of-scope` (not a capped item); `spend-evidence-inconsistent` (`claimedAtDelivery < claimedAtStart` or `spent` not their difference). It SHOULD report these warnings, which never fail the delivery: `spend-escrow-changed` (its own reading is on another escrow instance); `spend-above-chain` (its `claimedOf` on the same instance at its pinned block is below `claimedAtDelivery`); `spend-above-cap` (the amount measured, as defined next, above the cap); `spend-exceeds-receipts` or `spend-below-receipts` (the amount measured, its own `claimedOf − claimedAtStart` when it reads the same instance at or above the start, else `spent`, against the sum of the prices of the delivery's verified receipts with `ok` true to that provider; a receipt whose method is not listed in the provider's manifest leaves that provider unreconciled, and a method listed with price 0 counts as 0); and last `spend-evidence-incomplete` for each capped provider no entry names. Without the phase-1 request, or for a phase-0 mandate, a verifier MUST ignore the member.

### 11. Revocation

Revocation is as the phase-0 draft §6 says, and binds only those who read it. A holder who revokes a mandate that names funds SHOULD also close out every channel of it (§7.3): a revocation does not stop a holder of the agent key, and a provider that reads no mandate keeps serving until the channel's available amount is 0 or the session ends.

### 12. Reserved values

This TAP gives meaning to these values reserved by the phase-0 draft §3.8: a non-zero cap or token in a scope item, and a non-zero `feeCap` or `feeToken`, as §3 says. `subdelegate` `true` stays reserved. In the agent listing's manifest member (TAPs pull request #49, rule 3), `"escrow-channel"` names this TAP's enforcement; a client that does not implement this TAP ignores it as that rule says.

### 13. Rules for every verifier

The rules of phase-0 draft §10 apply. Every escrow read of §5 and §7 MUST be made at the verification's pinned block under strict agreement (TAP-10 §5). A console that shows the holder a mandate that names funds SHOULD show, in words, that signing it moves no money, that only the holder's own `fund` and `authorizeSession` transactions do, that the agent can then spend up to each channel's balance until `expires`, and every amount in whole tokens from the instance's `decimals()`.

## Rationale

- **No contract change.** Every guarantee comes from behaviour the escrow already has and that its tests pin: per-channel balances and sessions, extend-only sessions, the session check at settlement, the delayed withdraw. Changing the escrow before its audit would widen the audit; changing it after would mean a new audit and a redeployment.
- **One channel per capped provider, one mandate per channel.** The escrow keys channels by `(consumer, provider)`, not by mandate. A channel dedicated to one mandate makes its balance equal to the mandate's exposure toward that provider; sharing it would let one key spend what another mandate funded.
- **The cap is a target, the channel is the bound.** Nothing on chain reads the cap. Saying so in every result keeps a verifier from presenting the cap as a limit, and failing a channel above its cap keeps the two equal at the start.
- **Session end equal to `expires`.** A later end lets a leaked key spend after the mandate expired; an earlier one cuts the agent short. Since sessions cannot be shortened, the key must be new.
- **Both funding paths.** The `holder` path needs no container call, is readable field by field in a wallet, and lets an EOA holder sign its own vouchers; the `container` path keeps the money in the container but depends on the container's `execute`, its fee and its gates, which no TAP specifies. Which path a console proposes first is a product choice outside this text.
- **No mandate hash in the voucher.** The escrow cannot verify a mandate (another domain, a holder read, EIP-1271, revocation files); a field would be a label at the cost of a new voucher type and a new audit. The unsigned voucher members of §9 carry the same information for providers that want it.
- **A plan that refuses rather than tops up.** Re-running a plan after the key spent, moving a provider to another escrow instance, changing the circuit's holder or switching funding paths would otherwise fund the same mandate twice. The budget of §7.2 and the refusals of §7.1 keep the invariant across channels; refusing a missing history keeps an omitted history from passing as an empty one.
- **The spend statement is approximate.** `claimedOf` moves only when a provider settles, up to 48 hours after a call; a hash-only receipt signs its request hash, not its method; and a price is read from today's manifest. A mismatch is therefore information for the principal, not a verdict.
- **ERCs considered.** ERC-7710 and ERC-7715 delegations and smart-account session keys are enforced by the account; a circuit container's `execute` is owner-only, and the escrow already offers per-channel session keys.
- **Acknowledgement.** The idea of calling services under circuit identities, on which this work builds, came from @Theairresearch.

## Backwards Compatibility

- No signed type, type hash, domain or digest of the phase-0 draft changes; every phase-0 vector is unchanged. A phase-0 mandate is verified exactly as before, with or without the phase-1 request.
- A verifier of the phase-0 draft refuses a mandate that names funds (`phase0-no-funds`), so an agent that does not implement this TAP does not start on one: the failure is safe.
- A verifier implementing this TAP keeps phase-0 behaviour unless the caller asks for phase 1, so its default results do not change.
- Providers need no change: the reference provider ignores unknown voucher members and unknown request members.
- A `spend` member in a deliver result is ignored by phase-0 verifiers.

**Differences between this text and the reference implementation.** The reference implementation follows §3–§10 on local chains only. It does not implement a provider that checks mandates (§9, optional), nor the fee channel's acceptance flow beyond the checks of §5.3 item 7. Its escrow-funded calls require a BEM-priced escrow, since pricing in another token is not specified; the plan builds `approve` and `fund` for the instance's own token outside that restriction, for local verification only. Beyond this text, its verifier also reports the warning `spend-evidence-absent` when a delivery under a mandate that names funds carries no `spend` member (§10.2 does not list it); its spend limiter applies, when the caller states no per-call maximum, a default of 10% of the item's cap, rounded down (§8 leaves the bound to the agent); and its agent runtime can resume an order after a restart, with the agent key stored encrypted, which this text does not specify.

## Test Cases

The vector file is `assets/tap-draft-container-agent-phase1/container-agent.json`, copied unchanged from `spec/vectors/container-agent.json` of the reference implementation at the commit given under Reference Implementation (815211 bytes, SHA-256 `9de2283e1fa77f4167676debb2ccc0eb1693a6ee2e5e880be780b24c50257eb0`). Keys and addresses in it are test values; the escrow and provider addresses are not deployments. This TAP uses its member `phase1`. The other members test the phase-0 draft; those that its assets also contain (in `vectors.json` and `thread-revocation-vectors.json`, at the commit named in the Abstract) are equal to them in every input and expected output. The members `phase1.resume` and `phase1.keyVault` test the reference runtime's restart and key storage, which this TAP does not specify. The expected values were written by hand from the rule text in `phase1.rules`, not produced by the SDK; where that wording and this TAP differ, this TAP prevails.

The groups of `phase1` this TAP uses, with the number of cases:

- `static` (22 mandates): the static rules and warnings of §4, with and without the phase-1 request, and whether the nonce is recorded;
- `mapping` (32 abstract chain states) and `liveness` (6): the checks of §5.3 in order, the readings, and the lifetime of a withdraw request at its edges;
- `plan` (124), `history` (10), `closeOut` (33), `applied` (13): the plan's steps and refusals in order, the budget across channels, the session history, the close-out and the read-back of §6–§7;
- `spend` (45) and `recheck` (19): the agent's limit of §8;
- `statement` (10) and `evidence` (36): the spend statement and its reconciliation of §10.

Reproduced at that commit:

- **SDK.** `sdk/test/agent-phase1.test.mjs` (`static`, `plan`; 13 tests), `agent-phase1-chain.test.mjs` (`mapping`, `liveness`; 16), `agent-phase1-plan.test.mjs` (`closeOut`, `applied`; 32), `agent-phase1-spend.test.mjs` (`spend`, `recheck`; 28) and `agent-phase1-evidence.test.mjs` (`statement`, `evidence`; 8): 97 tests, all passing (`node --test`, Node.js 20 or later). The 10 `history` cases are not read by these files; the SDK's `sessionHistory` reproduces all 10.
- **Independent Python.** `spec/vectors/verify.py`, written from the rule text with the Python standard library only, agrees with every expected value: 1695 checks over all vector files, 0 disagreements; 755 of them check `phase1`, of which 704 check the groups above (`static` 132, `mapping` 116, `liveness` 7, `plan` 229, `history` 10, `closeOut` 69, `applied` 31, `spend` 45, `recheck` 19, `statement` 10, `evidence` 36) and 51 check `resume` and `keyVault`.
- **Escrow.** Foundry tests on a local copy of the unchanged escrow, nothing broadcast, 42 tests, all passing: `contracts/test/Phase1Mapping.t.sol` (12) pins the escrow behaviour §5.1 relies on; `Phase1Claims.t.sol` (9) the residual windows of Security Considerations (a leaked key draining every channel in one transaction without a provider, a full request being no barrier to the key, a lapsed request exposing the channel again, re-authorisation reviving a voucher); `Phase1Plan.t.sol` (15) executes the plans the SDK builds and reads them back; `Phase1Spend.t.sol` (6) executes the vouchers the agent's limiter signs, up to exactly the cap.

## Reference Implementation

TapeAPI 2.0.0 at commit [`e29bcd00a0314946e5d97db9b444f59031e8877c`](https://github.com/BruceLanLan/tapeapi/tree/e29bcd00a0314946e5d97db9b444f59031e8877c) (MIT licensed, experimental, not audited; the escrow is not deployed); paths are relative to that commit. The SDK exposes phase 1 only under its experimental subpath `@tapeapi/sdk/agent` (`sdk/src/agent-public.js`), and only when the caller asks for it (§5.4):

- `sdk/src/agent-sig.js`: §4 and the wallet payload of §13;
- `sdk/src/agent-verify.js`: §5 and the thread and evidence rules of §5.4 and §10.2 (`createAgentKit`: `verifyMandate`, `verifyTaskThread`, `verifyEvidence`, `holderPlan`, `afterPlan`, `closeOut`, `sessionLogs`);
- `sdk/src/agent-pay.js`: §6–§8 and §10 as pure functions (`escrowPlan`, `planApplied`, `closeOutPlan`, `sessionHistory`, `createSpendLimiter`, `spendDecision`, `spendRecheck`, `spendStatement`, `spendEvidence`);
- `sdk/types/agent.d.ts`: the interface;
- `spec/TAPI-22.md` §3 and `contracts/src/TapeAPIEscrow.sol`: the escrow (version 3, not audited, not deployed);
- `spec/vectors/container-agent.json` and `spec/vectors/verify.py`: the vectors and the independent Python check of Test Cases;
- `contracts/test/Phase1Mapping.t.sol`, `Phase1Claims.t.sol`, `Phase1Plan.t.sol`, `Phase1Spend.t.sol`: the Foundry tests of Test Cases;
- `examples/agent-service/`: an agent runtime with a spend order end to end on a simulated chain.

## Deployments

None yet. This TAP deploys no contract of its own, and no escrow instance is deployed or audited. After an instance is audited and deployed, this section will list, per chain, the instance's address, its token, how anyone can verify read-only that the deployed code is the audited one, and that the escrow has no upgrade path. Resolving parties and reading files use the contracts listed under Deployments in TAP-11.

## Security Considerations

**What phase 1 guarantees, on chain, without trusting anyone but the escrow's correctness** (experimental: checked on local chains and in tests only, since no escrow instance is audited or deployed):

- **G1** For each capped item, what vouchers signed with the agent key can pay from the consumer to `P_i` is at most the channel's balance (including any top-up while the session lives).
- **G2** Money flows only to the capped providers; their contribution comes out of the provider's share, not the consumer's.
- **G3** After the session ends (`expires`), no voucher of the agent key can be settled.
- **G4** The agent key is a session key, not ownership: it cannot call the container's `execute` or touch the holder's other assets (as long as the container keeps `execute` owner-only; its implementation can be upgraded by its owner).
- **G5** The agent key has no session on the fee channel, so the agent cannot pay itself (checked by verifiers; kept by consoles).

**What it does not guarantee:**

- **N1 Instant revocation.** Sessions cannot be revoked and channels shrink only through a 48-hour delayed withdraw.
- **N2 Per-mandate isolation.** Channels are per `(consumer, provider)`; two mandates or the holder on one channel share its balance.
- **N3 Per-call limits.** Only the channel bounds a voucher.
- **N4 Attribution to a key on chain.** `Settled` names no signer.
- **N5 Money spent on the task.** `taskHash` binds the task text; receipts do not prove a call was needed or right.
- **N6 Providers reading the mandate.** Providers need not check it.
- **N7 Fair exchange.** There is no arbiter.
- **N8 Privacy.** `Funded`, `SessionAuthorized` and `Settled` are indexed: consumer, agent key, provider, amounts and times are public; on the `holder` path the holder's wallet is linked to the task.
- **N9 Enumerable sessions.** A verifier cannot list a channel's session keys, nor see that a key was authorised before.

**Worst case.** A leaked agent key, or an agent out of control, can make the consumer pay the sum of the scope channels' balances, in one transaction, without any provider's cooperation (`settle` is open to anyone). The attacker gains nothing unless it controls one of the capped providers; otherwise the money reaches honest providers. The bound is how much was funded, not how quickly the holder revokes; the time bound is `expires` (at most 30 days).

| Situation | Honest provider | Holder of the key | Exposure |
|---|---|---|---|
| Key leaked, unnoticed | Serves | Settles every channel at any time before `expires` | Σ balances |
| Revoked, no chain action | Serves until `expires` | As above | Σ balances |
| Revoked and full `requestWithdraw` on every channel | Stops (available 0), unless it chose to extend credit | Can still settle everything for 48 hours | Σ balances |
| `cancelWithdraw` after that | Serves again at once | As above | Σ balances |
| `withdraw` executed | — | Session still live until `expires` | 0, but any top-up before `expires` is exposed |
| Request not executed within its 7-day window | Serves again | Can spend the whole balance while the session lives | Σ balances again |
| `container` path, `execute` blocked (a listing, a fee or gate change) | — | As above | Σ balances, and the money cannot be withdrawn until `execute` works |

Mitigations are small channels (funding by milestone), short mandates, and close-out as the revoke button (§7.3), with a reminder to execute the withdrawal inside its window.

**Other risks.**

- **The "one price per step" rule is not a bound** (§9): the key holder can bypass providers.
- **The agent paying itself.** A principal who lists the agent's own container, or a container with the agent's holder, among capped providers pays the agent directly; verifiers warn (`scope-includes-agent`).
- **Price rises.** A provider may raise a price or publish an expensive method; the agent's per-call limit (§8) bounds this within the cap.
- **Old keys spending new money.** Funding a channel while an earlier key's session lives exposes the new funds to that key (§6.2 rule 3); re-authorising an old key revives its unsettled vouchers (§6.1).
- **Lapsed requests.** The escrow's view keeps a lapsed withdraw request; a verifier that reads the view alone fails closed for ever (§5.3).
- **Top-up during a live request.** The top-up is both spendable and withdrawable (§6.2 rule 4).
- **A provider changing its escrow instance.** The agent stops (§8); the old channel must be closed out before the same mandate is funded on the new instance, and the new funding is only what the key has not spent (§7.2).
- **A circuit changing hands or being listed.** The old mandate stops verifying at once, but the sessions live until `expires`: on the `container` path the buyer inherits the channels; on the `holder` path the seller remains exposed. Close out before listing.
- **Phishing consoles.** A console can ask the holder to fund an attacker's provider for an attacker's key; on the `container` path the wallet shows only an opaque `execute`. Only what the wallet shows is reliable; the `holder` path shows every field.
- **The container's implementation.** `execute`'s owner-only rule, its fee and its gates can change with an upgrade by the container's owner.
- **Tokens.** Only tokens that cannot be frozen or paused are suitable; a token's value is not protected.
- **Lying nodes.** Strict agreement and a pinned block let a lying node only make an agent start for nothing; they cannot move money.
- **Lost session history.** The cross-channel invariant (§7.2) holds only over the channels the history records.
- **The spend statement** is the agent's signed claim; only its comparison with the chain is evidence, and settlement lag makes "below the receipts" normal for up to 48 hours. An honest agent's `spent` is at most what its key authorised on a channel that only this mandate uses; a dishonest agent can state less than it spent, and what the key can make a channel pay is bounded by G1 alone.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
