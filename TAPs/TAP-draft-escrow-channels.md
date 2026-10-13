---
tap: TBD
title: Escrow Channels for Paying Container Services
description: A non-upgradeable contract interface that holds one ERC-20 token in one channel per consumer and provider, pays cumulative signed vouchers out of that channel to the provider, and returns funds to the consumer only after a public, delayed request.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/38
status: Draft
type: Standards
created: 2026-10-13
requires: TAP-10
license: CC0-1.0
---

# TAP-TBD: Escrow Channels for Paying Container Services

> **Not audited, not deployed.** The reference contract of this TAP has not been audited and is not deployed on any chain; it is not usable on mainnet, and no client's list of audited deployments contains it. This TAP specifies an interface and its behaviour. It does not claim that the interface or the reference contract is secure. If editors merge it, it is merged as a Draft, and merging a Draft does not mean the proposal is accepted (TAP-01 §5).

## Summary

A contract in which a caller sets money aside for one online service, the service collects what the caller's signed running total says it is owed, and the caller can take the rest back only after announcing it in public and waiting.

## Abstract

This TAP specifies the interface of an escrow instance: a contract that holds exactly one ERC-20 token, keeps one channel per pair (consumer, provider), and pays out of a channel only to that channel's provider, against an EIP-712 voucher in which the consumer, or a session key it authorised for that channel, states the cumulative amount it owes. It specifies the functions with their selectors, the events with their topics, the errors with their selectors, the order of every check, and the state machine of a channel: funding (immediate), settlement (by anyone, partial when the channel is short), withdrawal (a public request, a 48-hour cooldown, then a 7-day window), session keys (per channel, at most 30 days ahead, extend-only, no revoke), and an optional maintenance contribution that a provider sets for itself and that is accrued for a treasury. It states what the token of an instance has to satisfy, the views that answer the four facts the payment-voucher draft (#52) reads from a settlement contract, and the identities that anyone can check from the logs. Amounts are in base units of the instance's token. The token that TAP-11 prices refer to is BEM on BNB Smart Chain.

**Builds on drafts not yet merged.** None of the following is normative for this TAP; they are listed so that readers can follow the dependencies in both directions.

- Idea [#38](https://github.com/TapeOutProtocol/TAPs/issues/38), the discussion thread of this TAP. An editor noted there that contract interfaces are Standards content and that the voucher and its transport (Application) and the settlement interface (Standards) are two TAPs.
- Pull request [#52](https://github.com/TapeOutProtocol/TAPs/pull/52), "Payment Vouchers for Container Services" (Application): the voucher's signing rules, its transport in a TAP-13 request, prices in US dollars and the provider's checks. It names the settlement contract only through the manifest's `payment.escrow` and lists four facts F1 to F4 it reads from it; §12 of this TAP gives those facts as functions. The voucher type and domain of #52 §3.1 are the ones `settle` verifies here (§8.1).
- Pull request [#53](https://github.com/TapeOutProtocol/TAPs/pull/53), a change to TAP-11 that leaves the chain of `payment.escrow` to "the TAP that defines settlement"; §2.3 names it.
- Pull request [#47](https://github.com/TapeOutProtocol/TAPs/pull/47), container agent mandates, phase 0, which reserves a cap and a token per provider in a mandate; Ideas [#40](https://github.com/TapeOutProtocol/TAPs/issues/40) and [#41](https://github.com/TapeOutProtocol/TAPs/issues/41) describe a phase 1 in which those values are enforced by channels of this interface.

## Motivation

A cumulative voucher is only a promise. A provider that accepts one off chain needs to know, before it serves, that the money exists, that nobody else can take it first, and that the voucher it holds can still be paid when it settles. A consumer needs to know that a provider can never take more than it set aside for that provider, and that it can recover what is left. Neither can know this from the voucher alone: it depends on the contract that pays it.

TAP-11 lets a manifest name that contract (`payment.escrow`), and #52 says what a client and a provider read from it, but no TAP says what the contract does. Without a specification, every provider has to audit the contract a service names before accepting its vouchers, a client cannot tell a settlement contract from a contract that only reports the right token, and two implementations of "the escrow" can disagree on when a withdrawal takes effect or which key may sign.

This TAP fixes the interface and the behaviour, so that independent implementations of providers, clients, agents and monitoring tools read the same functions and events, and so that a deployment can be checked against a text rather than against one team's code.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms and notation

- **Instance**: a deployed contract that implements this interface. **Token**: the one ERC-20 contract an instance holds, returned by `token()`. A **base unit** is the smallest unit of the token (for BEM, 10^-8 BEM). Every amount in this TAP is a `uint256` number of base units of the instance's token.
- **Consumer**: the account that funds a channel and owes the payments. **Provider**: the account a channel pays. **Channel**: the pair (consumer, provider) in one instance. Two channels with the same consumer and different providers share nothing.
- **Container**, **circuit**, **holder**, **hub**: as in TAP-10 §1 and §13. The hub's `accountOf(address circuits, uint256 tokenId)` (TAP-10 §13.5) derives a container address.
- **Voucher**: the EIP-712 message of §8.1. **Session key**: a key that a consumer authorised to sign vouchers for one channel (§7).
- **now** is `block.timestamp` of the transaction being executed. Time values are Unix seconds.
- Function, event and error signatures are written in Solidity syntax. A selector is the first 4 bytes of the keccak-256 hash of the canonical signature; an event's topic0 is the full hash.

### 2. Instance, token and chain

#### 2.1 One token per instance

- An instance MUST hold exactly one token, fixed at construction and never changed. `token()` MUST return it.
- An instance MUST NOT convert between tokens, MUST NOT read the token's `decimals()` to compute any amount, and MUST count only its own token. Tokens sent to the instance by a plain transfer are not credited to any channel (§13).
- An instance MUST NOT be upgradeable: it MUST NOT be a proxy, and its runtime code MUST NOT contain `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`.
- An instance MUST NOT have a pause, a freeze, a sweep or rescue function, or any other function through which any account other than the consumer moves money out of a channel, except `settle` (§8).

#### 2.2 What the token has to satisfy

A deployer MUST NOT deploy an instance for a token that fails any of these, each of which can be checked on chain or against the token's verified source:

1. The token is not upgradeable: every EIP-1967 slot (implementation, admin, beacon) and the EIP-1822 slot is zero, it has no `upgradeTo` function, and its runtime code contains no `DELEGATECALL` or `SELFDESTRUCT`.
2. No account can freeze, pause or block transfers to or from an address, or burn another address's balance.
3. Transfers are plain: no fee on transfer, no rebasing, no hook into the receiver; `transfer` and `transferFrom` return `true` or return nothing; a transfer into a contract address succeeds.
4. `decimals()` is fixed and 8 ≤ `decimals()` ≤ 18.

A client SHOULD NOT fund or sign for an instance whose token it has not checked against these items, or found checked in a source it trusts.

#### 2.3 Chain

An instance is on one chain, and its voucher domain names that chain's `chainId` (§8.1). Where another TAP refers to an instance by address alone, as the manifest member `payment.escrow` of TAP-11 does, the address is on BNB Smart Chain (chain ID 56).

#### 2.4 BEM

BEM is the ERC-20 token at `0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a` on BNB Smart Chain (chain ID 56), with 8 decimals: the token in which TAP-11's `priceBEM` is stated. An instance whose token is BEM is the instance this TAP specifies for paying methods priced under TAP-11. Instances for other tokens use the same interface; this TAP does not list them, and how a manifest prices a method in another token is not specified.

### 3. Interface

#### 3.1 Functions that change state

| Function | Selector | Caller |
|---|---|---|
| `fund(address provider, uint256 amount)` | `0x7b1837de` | The consumer (§5) |
| `requestWithdraw(address provider, uint256 amount)` | `0x397a1b28` | The consumer (§6) |
| `cancelWithdraw(address provider)` | `0xe9919629` | The consumer (§6) |
| `withdraw(address provider)` | `0x51cff8d9` | The consumer (§6) |
| `authorizeSession(address provider, address key, uint64 expires)` | `0x30aacc89` | The consumer (§7) |
| `settle(address consumer, address provider, uint256 cumulative, uint64 expires, bytes sig)` | `0x2fc8323f` | Anyone (§8) |
| `setContribution(address circuits, uint256 tokenId, uint16 bps)` | `0x49160ca6` | The circuit's holder (§9) |
| `claimTreasury() returns (uint256 amount)` | `0x003bdc74` | Anyone (§10) |
| `setTreasury(address treasury)` | `0xf0f44260` | The owner (§10, §11) |
| `transferOwnership(address newOwner)` | `0xf2fde38b` | The owner (§11) |
| `acceptOwnership()` | `0x79ba5097` | The nominated owner (§11) |

#### 3.2 Views

| Function | Selector | Returns |
|---|---|---|
| `token() returns (address)` | `0xfc0c546a` | The token (§2.1) |
| `channelOf(address consumer, address provider) returns (uint256)` | `0xe67ca677` | The channel's balance: the most the provider can still be paid from it |
| `claimedOf(address consumer, address provider) returns (uint256)` | `0x9cf00275` | The total paid out of the channel by `settle`; never decreases |
| `sessionExpiry(address consumer, address provider, address key) returns (uint64)` | `0x93909a87` | The last second at which `key` may sign for the channel; 0 if never authorised |
| `pendingWithdraw(address consumer, address provider) returns (uint256 amount, uint64 requestedAt)` | `0x742e1c0f` | The channel's withdrawal request, `(0, 0)` if none; a request whose window has passed stays visible (§6.4) |
| `WITHDRAW_COOLDOWN() returns (uint64)` | `0x950d91e9` | `172800` (48 hours) |
| `WITHDRAW_WINDOW() returns (uint64)` | `0x30f81250` | `604800` (7 days) |
| `MAX_SESSION() returns (uint64)` | `0xaed6ff12` | `2592000` (30 days) |
| `DOMAIN_SEPARATOR() returns (bytes32)` | `0x3644e515` | §8.1, computed with the current `chainId` |
| `VOUCHER_TYPEHASH() returns (bytes32)` | `0x94739e87` | §8.1 |
| `voucherDigest(address consumer, address provider, uint256 cumulative, uint64 expires) returns (bytes32)` | `0xea75bd27` | The digest of §8.1 |
| `contributionOf(address provider) returns (uint16)` | `0xd7805ece` | §9 |
| `DEFAULT_CONTRIBUTION_BPS() returns (uint16)` | `0xa7ec64ee` | `100` (§9) |
| `MAX_CONTRIBUTION_BPS() returns (uint16)` | `0x5ace2eee` | `2000` (§9) |
| `hub() returns (address)` | `0x365a86fc` | The hub used by `setContribution` (§9) |
| `treasury() returns (address)` | `0x61d027b3` | §10 |
| `treasuryAccrued() returns (uint256)` | `0xcc279009` | §10 |
| `owner() returns (address)` | `0x8da5cb5b` | §11 |
| `pendingOwner() returns (address)` | `0xe30c3978` | §11 |

The constants of this table MUST have exactly the values given. Every instance MUST implement the first eleven rows. An instance that implements §9 MUST also implement the last eight; one that does not implement §9 omits them, and omits the last five functions of §3.1.

#### 3.3 Events

| Event | topic0 |
|---|---|
| `Funded(address indexed consumer, address indexed provider, uint256 amount)` | `0x3b5083eec1a1116c56de5d6841cff8efc6a0aec9850e836ec509d6ce024ea561` |
| `WithdrawRequested(address indexed consumer, address indexed provider, uint256 amount, uint64 availableAt)` | `0x37cfe096bfb86f6d34b6486bcaf1c1513cb7ad34ec77e1cb2c717d6dd0960434` |
| `WithdrawCancelled(address indexed consumer, address indexed provider)` | `0x7abd2977b9ef845f4eaf363c91095279c6531ff44d5d0ed1b2774c2604b60791` |
| `Withdrawn(address indexed consumer, address indexed provider, uint256 amount)` | `0xd1c19fbcd4551a5edfb66d43d2e337c04837afda3482b42bdf569a8fccdae5fb` |
| `SessionAuthorized(address indexed consumer, address indexed provider, address indexed key, uint64 expires)` | `0x2f842a8cea03e9cec49358626dab2a1d89c2ed4967f6fe7322c3766245792953` |
| `Settled(address indexed consumer, address indexed provider, uint256 paid, uint256 contribution, uint16 bps)` | `0xb4c3b78f5893c36548b47dc070064ba3b52178fa6de48c8274a9c66d8e1b3b8c` |
| `ContributionSet(address indexed provider, uint16 bps)` | `0xeb16511d6a42bf209c829b49f09abe16df0e63c53b6396a42675f829c9c7083c` |
| `TreasuryChanged(address indexed oldTreasury, address indexed newTreasury)` | `0x8c3aa5f43a388513435861bf27dfad7829cd248696fed367c62d441f62954496` |
| `TreasuryClaimed(address indexed treasury, uint256 amount)` | `0x0dafe5fda3d3c12f5534ba82c4393aaf90fe68d6198d310d71a7d9a6ea3cc1e0` |
| `OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)` | `0x38d16b8cac22d99fc7c124b9cd0de2d3fa1faef420bfe791d8c362d765e22700` |
| `OwnershipTransferred(address indexed previousOwner, address indexed newOwner)` | `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` |

#### 3.4 Errors

| Error | Selector | Error | Selector |
|---|---|---|---|
| `ZeroAddress()` | `0xd92e233d` | `SessionTooLong(uint64 max)` | `0xc3ce5f49` |
| `ZeroAmount()` | `0x1f2a2005` | `SessionShorteningNotSupported()` | `0x63afa2e3` |
| `BadProvider()` | `0xf4d31811` | `BadSignature()` | `0x5cd5d233` |
| `BadTreasury()` | `0x9718e702` | `NothingToSettle()` | `0x618104e8` |
| `InsufficientBalance()` | `0xf4d678b8` | `NotHolder()` | `0x7623fb52` |
| `NoPendingWithdraw()` | `0xf6fc7daa` | `ContributionTooHigh(uint16 bps)` | `0x6dc6502e` |
| `CooldownActive(uint64 availableAt)` | `0x15f3b7ab` | `TransferFailed()` | `0x90b8ec18` |
| `WithdrawWindowClosed()` | `0x03537235` | `Reentrancy()` | `0xab143c06` |
| `AmountTooLarge()` | `0x06250401` | `NotOwner()` | `0x30cd7471` |
| `Expired()` | `0x203d82d8` | `NotPendingOwner()` | `0x1853971c` |

Each section below lists the checks of a function in the order an instance MUST apply them. A failed check MUST revert with the error named, and MUST leave no state change. A function guarded against re-entry (§13.2) reverts `Reentrancy()` before any other check when entered during another guarded call.

### 4. Channel state

For each channel an instance keeps: the balance `channelOf`, the amount paid `claimedOf`, one withdrawal request `(amount, requestedAt)`, and for each key a session expiry. All four are keyed by (consumer, provider) and, for sessions, by key. No function reads or writes the state of one channel when called for another, except through the views.

```
             fund (immediate)
   ┌──────────────────────────────┐
   ▼                              │
 [funded: channelOf > 0] ──settle (anyone, voucher)──► paid to provider, claimedOf += paid
   │
   │ requestWithdraw(amount)          cancelWithdraw
   ▼                                  ▲
 [request in cooldown] ───────────────┘
   │  now ≥ requestedAt + 48 h
   ▼
 [request executable] ──withdraw──► min(amount, channelOf) to consumer, request cleared
   │  now > requestedAt + 48 h + 7 d
   ▼
 [request lapsed: inert, still visible; a new request replaces it]
```

`settle` and `fund` remain available in every state.

### 5. Funding

`fund(provider, amount)`, guarded (§13.2):

1. `amount == 0`: `ZeroAmount()`.
2. `provider` is the zero address or the instance itself: `BadProvider()`.
3. Add `amount` to `channelOf(msg.sender, provider)`.
4. Pull `amount` from `msg.sender` with `transferFrom` (§13.1).
5. Emit `Funded(msg.sender, provider, amount)`.

Funding takes effect at once and does not change a withdrawal request on the channel or its clock. The instance has no function that funds a channel for another consumer.

### 6. Withdrawal

#### 6.1 Request

`requestWithdraw(provider, amount)`:

1. `amount == 0`: `ZeroAmount()`.
2. `amount > channelOf(msg.sender, provider)`: `InsufficientBalance()`.
3. `amount > 2^192 − 1`: `AmountTooLarge()`.
4. Record `(amount, requestedAt = now)` for the channel, replacing any earlier request and its clock.
5. Emit `WithdrawRequested(msg.sender, provider, amount, now + WITHDRAW_COOLDOWN)`. The last argument is `availableAt`.

#### 6.2 Cancel

`cancelWithdraw(provider)`:

1. The channel has no request (`requestedAt == 0`): `NoPendingWithdraw()`.
2. Clear the request.
3. Emit `WithdrawCancelled(msg.sender, provider)`.

A lapsed request (§6.4) can be cancelled.

#### 6.3 Execute

`withdraw(provider)`, guarded (§13.2), with `availableAt = requestedAt + WITHDRAW_COOLDOWN`:

1. The channel has no request (`amount == 0`): `NoPendingWithdraw()`.
2. `now < availableAt`: `CooldownActive(availableAt)`.
3. `now > availableAt + WITHDRAW_WINDOW`: `WithdrawWindowClosed()`.
4. `paid = min(amount, channelOf(msg.sender, provider))`, read now. If `paid == 0`: `InsufficientBalance()`, and the request stays as it was.
5. Clear the request, subtract `paid` from the channel, transfer `paid` to `msg.sender` (§13.1).
6. Emit `Withdrawn(msg.sender, provider, paid)`.

The request is consumed in full even when `paid < amount`. Both bounds of the window are inclusive: at `availableAt` and at `availableAt + WITHDRAW_WINDOW` the withdrawal succeeds.

#### 6.4 Live request

A request is **live** while `requestedAt ≠ 0` and `now ≤ requestedAt + WITHDRAW_COOLDOWN + WITHDRAW_WINDOW`. After that it is **lapsed**: `withdraw` reverts `WithdrawWindowClosed()` and the request has no effect, but the instance does not clear it, and `pendingWithdraw` still returns it until it is cancelled or replaced. A reader MUST judge whether a request is live by this rule and not by the view alone.

### 7. Session keys

`authorizeSession(provider, key, expires)`:

1. `key` is the zero address: `ZeroAddress()`.
2. `provider` is the zero address or the instance itself: `BadProvider()`.
3. `expires ≤ now`: `Expired()`.
4. `expires > now + MAX_SESSION`: `SessionTooLong(now + MAX_SESSION)`.
5. `expires < sessionExpiry(msg.sender, provider, key)`: `SessionShorteningNotSupported()`.
6. Set `sessionExpiry(msg.sender, provider, key) = expires`.
7. Emit `SessionAuthorized(msg.sender, provider, key, expires)`.

A session is authorised for one channel only: a key authorised for (consumer, P) is not authorised for (consumer, Q). An instance MUST NOT provide any function that revokes a session or shortens its expiry. A key whose session has passed can be authorised again through steps 1 to 7; vouchers it signed earlier then become settleable again (Security Considerations).

### 8. Vouchers and settlement

#### 8.1 What `settle` verifies

| Item | Value |
|---|---|
| Domain type | `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)` |
| `name` | `"TapeAPIEscrow"` |
| `version` | `"1"` |
| `chainId` | The chain ID at the time of the call (`block.chainid`) |
| `verifyingContract` | The instance |
| Primary type | `Voucher(address consumer,address provider,uint256 cumulative,uint64 expires)` |
| `VOUCHER_TYPEHASH` | `0x8e017cc56e9f2cb1f0fd1af4419f7c77b8d3f92099263f2b8aba4ba44cf50407` |

```
DOMAIN_SEPARATOR = keccak256(abi.encode(
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
    keccak256("TapeAPIEscrow"), keccak256("1"), block.chainid, address(this)))
structHash       = keccak256(abi.encode(VOUCHER_TYPEHASH, consumer, provider, cumulative, expires))
digest           = keccak256(0x19 ‖ 0x01 ‖ DOMAIN_SEPARATOR ‖ structHash)
```

This is the domain and type of #52 §3.1, byte for byte; for an instance on BNB Smart Chain, `chainId` is 56 as #52 states. How a voucher is signed, carried and checked off chain is #52's subject and is not repeated here.

`sig` is 65 bytes `r ‖ s ‖ v`. The instance recovers the signer with `ecrecover(digest, v, r, s)` and treats the signature as invalid, recovering no signer, when: `sig` is not 65 bytes; `v` is not 0, 1, 27 or 28 (0 and 1 are read as 27 and 28); `s > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0`; or `ecrecover` returns the zero address. An instance MUST NOT accept EIP-1271 signatures. An instance MAY refuse a `v` of 0 or 1; the reference implementation accepts them, and #52 requires off-chain verifiers to refuse them, so a voucher signed as #52 requires is accepted either way.

#### 8.2 Settle

`settle(consumer, provider, cumulative, expires, sig)`, callable by anyone, guarded (§13.2):

1. `now > expires`: `Expired()`. A voucher is valid up to and including the second `expires`.
2. `provider` is the zero address or the instance itself: `BadProvider()`.
3. Recover the signer of `voucherDigest(consumer, provider, cumulative, expires)` (§8.1). No signer: `BadSignature()`.
4. The signer is not `consumer` and `sessionExpiry(consumer, provider, signer) < now`: `BadSignature()`. The session has to be live at settlement; it does not have to outlive the voucher.
5. `cumulative ≤ claimedOf(consumer, provider)`: `NothingToSettle()`.
6. `delta = cumulative − claimedOf`; `paid = min(delta, channelOf(consumer, provider))`. If `paid == 0`: `InsufficientBalance()`.
7. `bps = contributionOf(provider)` as it stands now (0 for an instance without §9); `contribution = floor(paid × bps / 10000)`.
8. Add `paid` to `claimedOf`, subtract `paid` from `channelOf`, add `contribution` to `treasuryAccrued`.
9. Transfer `paid − contribution` to `provider` (§13.1). This is the only token call of `settle`; it MUST NOT transfer anything to the treasury.
10. Emit `Settled(consumer, provider, paid, contribution, bps)`.

`paid < delta` is a **partial settlement**: `claimedOf` rises by what was paid, and the same voucher can be settled again for the rest, until `expires`, after the channel is funded again. `settle` pays only `provider`, whoever calls it.

### 9. Maintenance contribution (optional)

An instance MAY leave out this section and §10. An instance that leaves them out MUST NOT have `setContribution`, `contributionOf`, a treasury or an owner; its `settle` uses `bps = 0`, so `Settled` carries `contribution = 0` and `bps = 0`. A client that finds no `contributionOf` on an instance MUST treat the contribution as 0. An instance that implements this section MUST implement all of it and §10.

- `contributionOf(provider)` is the contribution, in basis points, carved out of each settlement paid to `provider`. Until the provider's value has been set it MUST return `DEFAULT_CONTRIBUTION_BPS` = `100` (1 %). Once set, it MUST return the value set, 0 included: the instance MUST keep "never set" apart from "set to 0".
- `DEFAULT_CONTRIBUTION_BPS` and `MAX_CONTRIBUTION_BPS` = `2000` (20 %) MUST be constants of the code. No function may change them.
- `setContribution(circuits, tokenId, bps)`:
  1. `IERC721(circuits).ownerOf(tokenId) ≠ msg.sender`: `NotHolder()`. (A revert of `ownerOf` reverts the call.)
  2. `bps > MAX_CONTRIBUTION_BPS`: `ContributionTooHigh(bps)`.
  3. `provider = hub.accountOf(circuits, tokenId)`; the zero address: `ZeroAddress()`.
  4. Record `bps` as set for `provider`.
  5. Emit `ContributionSet(provider, bps)`.

  `hub` is fixed at construction. Only the current holder of a circuit can set its container's value, and a transfer of the circuit moves that right with it.
- A new value applies from the next settlement on. A settlement made before is never recomputed; a voucher not yet settled is split at the value in force when it settles.
- The contribution reduces only what the provider receives. It never changes `paid`, `claimedOf` or `channelOf`, and so never what a consumer pays.
- An instance MUST NOT have any fee other than this contribution, and MUST NOT let any account other than the circuit's holder set or change a provider's value.

### 10. Treasury

- `treasury` is set at construction and is never the zero address, the instance or the token.
- `claimTreasury()`, callable by anyone, guarded (§13.2):
  1. `treasuryAccrued == 0`: `ZeroAmount()`.
  2. Set `treasuryAccrued` to 0 and transfer the previous value to the current `treasury` (§13.1). If the transfer fails: `TransferFailed()`, and nothing changes.
  3. Emit `TreasuryClaimed(treasury, amount)` and return `amount`.
- `setTreasury(newTreasury)`:
  1. `msg.sender ≠ owner`: `NotOwner()`.
  2. Inside a guarded call: `Reentrancy()`. (`setTreasury` checks the guard and does not take it.)
  3. `newTreasury` is the zero address: `ZeroAddress()`.
  4. `newTreasury` is the instance or the token: `BadTreasury()`.
  5. `newTreasury` equals `treasury`: return; nothing changes and nothing is emitted.
  6. If `treasuryAccrued > 0`, attempt `claimTreasury()` for the current (outgoing) treasury in a separate call frame. If the attempt fails for any reason, every effect of it is rolled back, including any effect inside the token, and the rotation continues; the accrual then stays for the new treasury.
  7. Set `treasury = newTreasury` and emit `TreasuryChanged(old, newTreasury)`.

A treasury that cannot receive the token never blocks a settlement (§8.2 step 9) and never blocks its own replacement (step 6).

### 11. Owner

- An instance that implements §9 has an owner, initially the deployer. The owner's only powers are `setTreasury` and nominating a successor. The owner MUST NOT be able to change any rate, constant or provider's contribution, pause anything, move or freeze any channel, or pay the accrual to anyone but `treasury`.
- Ownership moves in two steps. `transferOwnership(newOwner)`: `NotOwner()` unless called by the owner; `ZeroAddress()` for the zero address; sets `pendingOwner` (a new nomination replaces the previous one) and emits `OwnershipTransferStarted(owner, newOwner)`. `acceptOwnership()`: `NotPendingOwner()` unless called by `pendingOwner`; emits `OwnershipTransferred(owner, pendingOwner)`, makes it the owner and clears `pendingOwner`.

### 12. Facts for other TAPs

#52 §2.2 reads four facts from a settlement contract. For an instance of this TAP they are:

| Fact | Read as |
|---|---|
| F1, the token settled | `token()`, on the instance's chain (§2.3) |
| F2, the amount paid on a channel | `claimedOf(consumer, provider)` |
| F3, whether a key is authorised for a channel, and until when | `sessionExpiry(consumer, provider, key)`: authorised at time `t` exactly when the result is at least `t` |
| F4, whether the channel's funds cover an amount `a` | `a ≤ available`, where `available = channelOf(consumer, provider) − amount` while the channel's request is live (§6.4) and `channelOf(consumer, provider)` otherwise, never below 0 |

A reader that cannot read these views at one block MUST treat the facts as unknown.

### 13. Token calls, guards and accounting

#### 13.1 Token calls

A token call made by an instance (`transferFrom` in `fund`, `transfer` in `withdraw`, `settle` and `claimTreasury`) counts as successful only if it does not revert and either returns no data from an address that has code, or returns at least 32 bytes whose first 32-byte word is exactly 1. Any other outcome, including `false`, 1 to 31 bytes of return data, and a first word other than 1, MUST revert the calling function with `TransferFailed()`. An instance SHOULD copy at most 32 bytes of return data.

#### 13.2 Re-entry

`fund`, `withdraw`, `settle` and `claimTreasury` are **guarded**: while one of them runs, a call into any of them reverts `Reentrancy()`, and so does `setTreasury`. Every state change of a guarded function is made before its token call.

#### 13.3 Construction

The constructor of an instance that implements §9 takes `(address token, address hub, address treasury)`. It MUST revert `ZeroAddress()` if any argument is the zero address, and `BadTreasury()` if `treasury` is the token or the instance, and it emits `OwnershipTransferred(0, deployer)` and `TreasuryChanged(0, treasury)`. An instance that does not implement §9 takes the token and no hub or treasury, and MUST revert `ZeroAddress()` for a zero token.

#### 13.4 Identities

At every block, for every instance that follows this TAP:

1. `token.balanceOf(instance) ≥ Σ channelOf + treasuryAccrued`. It is `≥` and not `=` because anyone can transfer tokens to the instance directly; such tokens stay there, are paid to nobody, and no function depends on the instance's own balance.
2. For each channel: `Σ Funded.amount − Σ Withdrawn.amount − Σ Settled.paid = channelOf`, and `Σ Settled.paid = claimedOf`.
3. For each `Settled` event: `contribution = floor(paid × bps / 10000)`, and the provider received `paid − contribution` in the same transaction.
4. `Σ Settled.contribution = treasuryAccrued + Σ TreasuryClaimed.amount`.

Identities 2 to 4 can be checked from the instance's logs alone.

## Rationale

- **One topic, one type.** The editors' answer in #38 put the line between the voucher and its transport (Application, #52) and anything about the settlement contract (Standards, this TAP). This TAP therefore specifies only what the contract does. It names the voucher's type and domain because `settle` verifies them (§8.1), and leaves how a voucher is signed, carried and checked off chain to #52. `requires` names only TAP-10: the contract uses the container derivation of TAP-10 and nothing of TAP-11 or TAP-13, and an editor's check in #12 named a Standards TAP that depends normatively on Application TAPs as something to remove. #52 and the later phases of #40 are the TAPs that would require this one.
- **One channel per (consumer, provider), not a shared pool.** The first design (version 1, never deployed) kept one balance per consumer, an allowance per provider that the consumer could lower after a delay, commitment accounting for vouchers not yet settled, and a revoke delay for session keys. A review before any deployment found a critical flaw (C-01): through a second provider it controlled, a consumer could pay itself out of the shared balance money that an honest provider had already earned. Version 2 replaced the pool with channels: the balance of a channel is the cap, there is nothing shared to race for, and the flaw cannot be expressed rather than being defended against. That removed the allowance delay, commitment accounting and the revoke delay, and left one delay, the withdrawal cooldown. Version 3 kept every rule of version 2 and changed four things: the token became an immutable constructor argument of any decimals; the contribution is accrued and paid to the treasury in a separate call; the solvency identity reads `≥`; and every token answer other than success is `TransferFailed()`. Later reviews of version 3 (not audits) added the rule that a treasury rotation first pays the outgoing treasury and the refusal of the instance and the token as treasury. The reference implementation is version 3.
- **One delay, per request.** A consumer can shrink a channel in exactly one way, a withdrawal request, and the request takes effect only after a public event and 48 hours. Funding only adds, a session only extends, and nothing revokes. So a provider that settles within 48 hours of the event is always paid for what it served within the channel (`testFuzz_A2_claim_settleInsideCooldownAlwaysPaysInFull`). The 7-day window stops a request from being armed weeks ahead. The clock belongs to the request, not to the channel: a top-up during a live request can leave with it, which is why F4 subtracts a live request (§12) and why a provider does not serve against it.
- **No revoke.** A revoke would be a second consumer action that shrinks what a provider can settle, and it would need its own delay, as version 1 had. Instead a session is bounded by one channel's balance and by `MAX_SESSION`, and both bounds are visible on chain before a provider serves. The cost is that a leaked key stays usable until its session ends; a consumer limits that by short sessions and small channels. #40 states this limitation for agents. A delayed revoke would be a change to this interface and would need a new version of it.
- **Constants, not minimums.** The cooldown, the window and the longest session are fixed values that every instance returns from its views. Providers, clients and agents can then reason about every instance the same way, and the provider's guarantee is one number. The views exist, so implementations read the values instead of assuming them, and a later version could allow other values without changing any function.
- **The maintenance contribution.** The protocol takes no fee. The contribution funds the upkeep of the standard and the reference implementation; it is carved out of the provider's share, so the consumer's price never changes; it starts at 1 % and each provider sets its own value from 0 to 20 %. Both bounds are constants and no owner or operator can change them or any provider's value. A provider at 0 gets exactly the same settlement as any other. The contribution is optional in this TAP because the channel rules do not depend on it: an instance without it is a complete settlement contract, and `Settled` keeps one shape for both, with `bps` 0.
- **Pull treasury, and rotation pays the outgoing treasury.** If `settle` paid the treasury, a treasury that the token refuses would block every settlement of every provider with a non-zero contribution. Accruing the contribution and letting anyone pay it out later keeps settlement independent of the treasury. A rotation first pays the outgoing treasury, so an owner cannot rotate and claim in one transaction what a working treasury has earned; when that payment fails, the rotation still succeeds, so a frozen treasury can be replaced.
- **Settlement by anyone, to the provider only.** Anyone may submit a voucher, so a provider can use a relayer or a keeper, and nobody but the provider can be paid by it.
- **The voucher does not name the token.** `verifyingContract` pins a voucher to one instance and an instance has one immutable token, so a voucher cannot be replayed against another token. A token member would change the type hash and protect against nothing that the domain does not cover.
- **ECDSA only.** An EIP-1271 answer can change between the moment a provider accepts a voucher and the moment it settles, so an accepted voucher could become unsettleable. A consumer that is a contract (a container, a multisig) authorises a session key with one transaction and that key signs, as #52 §3.3 states.
- **Non-upgradeable, no pause.** An upgrade path or a pause would be a power over every channel. A pausable or freezable token would bring that power back from outside, which is why §2.2 excludes such tokens rather than handling them in the contract.
- **Existing TapeOut mechanisms.** In #38 the editors listed what the merged TAPs offer: `DomainBinding` (TAP-10 §6.3) takes activation fees from a container's holder in the chain's native coin, and TapeSend attachments (TAP-10 §19, §20) are transfers sent with a message. Neither holds funds for a provider against later per-call claims, so this TAP adds a contract. It uses ERC-20 and EIP-712 where they fit (TAP-01 §10).
- **Open questions.** The authors would welcome views on these.
  1. *Constants or bounds.* This draft fixes 48 hours, 7 days and 30 days as constants. The alternative is minimums for the cooldown and window and a maximum for sessions, with each instance's values read from its views. Constants are recommended here because the provider's guarantee then has one value, and #52 and the phase 1 of #40 can state it.
  2. *No revoke.* This draft keeps sessions extend-only with no revoke, as the reference implementation does. A delayed revoke could be added in a later version.
  3. *The contribution in a Standards TAP.* §9 and §10 are optional parts. Should they stay in this TAP, or move to a separate TAP so that this one specifies channels only?
  4. *`v` of 0 or 1.* §8.1 lets an instance accept or refuse them. Should this TAP require instances to refuse them, as #52 requires of off-chain verifiers? The reference implementation would then need a change before deployment.
- **Acknowledgement.** Thanks to @Theairresearch, from whom the idea for TapeAPI came.

## Backwards Compatibility

This TAP adds a contract interface and changes no TAP. Nothing is deployed, so no deployment or channel has to migrate.

The interface was published in the TapeAPI repository as "TAPI-22" (§3.3 to §3.5 there; called "TAP-22" until 2026-09-30, and neither is a TAP number). The reference implementation is version 3 of that document's escrow. Compared with that document, this text:

- specifies only the contract: the provider's checks, the wire form of a voucher and prices in US dollars are in #52;
- makes the maintenance contribution and the treasury optional parts (§9, §10), as TAPI-22 §3.4 already allowed for other deployments;
- states the token requirements of TAPI-22 §3.5 as requirements on deployment (§2.2);
- names the four facts of #52 as views (§12);
- leaves to directories and clients how they show the contribution, which TAPI-22 §3.4 also regulated for directories (no ranking or badges by it).

The voucher domain, type, type hash and digest are unchanged, so every voucher signed under TAPI-22 verifies under §8.1.

## Test Cases

**Voucher digest.** With the domain of §8.1, `chainId` 56 and `verifyingContract` `0x00000000000000000000000000000000000E5c70` (a test value, not a deployment):

```
keccak256("TapeAPIEscrow") = 0x9e119fcf121b28516e9297f2c41bbb6b5899ca62f3f2122145a86c0b2ddf863a
keccak256("1")             = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6
EIP712Domain type hash     = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f
DOMAIN_SEPARATOR           = 0xfcb38f1f78a21786bfb0ac1785ebedcc83cf8fbd996f678f4a7a1d799977f38e

consumer   0x5CbDd86a2FA8Dc4bDdd8a8f69dBa48572EeC07FB
provider   0x86DDaEF00401E3F10418398D67D7189fc458eA95
cumulative 10000
expires    1789003600
structHash = 0xa7ca7a8ac0e17eb48726efa34cf1fe831e8bce5ea5bcccc928a96beb22850867
digest     = 0x6799d6d7892fbd0a4221652fd7b8869ec6b4ce77483187046a1bfb824375495d
```

More vouchers, with signatures and recovered addresses, are in [`spec/vectors/tapi-22-voucher.json`](https://github.com/BruceLanLan/tapeapi/blob/e29bcd00a0314946e5d97db9b444f59031e8877c/spec/vectors/tapi-22-voucher.json) at the fixed commit below, and in `assets/tap-draft-payment-vouchers/voucher.json` of #52. The selectors and topics of §3 are the keccak-256 hashes of the signatures as written there.

**Contract behaviour.** The reference implementation's Foundry tests at commit `e29bcd00a0314946e5d97db9b444f59031e8877c`, run with `forge test` in `contracts/` (Foundry 1.8.3, solc 0.8.28, EVM version paris, fuzz seed `0x4444`), report **268 passed, 0 failed, 8 skipped** (276 tests in 22 suites). The 8 skipped tests read BNB Smart Chain and run only when `BSC_RPC_URL` is set. One test outside the escrow (`ConsoleBytecode.t.sol`) reads `site/console/channelbus.json`, so the run needs the whole repository at that commit, not only `contracts/`. The suites that test the escrow:

| Suite | Tests | What it pins |
|---|---|---|
| `TapeAPIEscrow.t.sol` | 62 | Every function and error of §5–§11, including `test_domainSeparator_andDigest_matchSpec`, `test_settle_partialSettlement_isCreditFlow`, `test_settle_sessionKey_validAtSettlementNotBeyondVoucher`, `test_authorizeSession_extendOnly_noRevoke`, `test_setContribution_unsetIsDefault_zeroIsZero`, `test_withdraw_window_openAtBoundaries_closedAfter`, `test_settle_acceptsV0or1` |
| `Attacks.t.sol` (`EscrowAttacksTest`) | 18 | Earlier findings replayed: `test_attack_C01_selfDealDrain_isInexpressible`, `test_attack_E01_frontRunSettle_noInstantShrinkExists`, `test_attack_E03_prearmedWithdraw_providerThatSettlesInsideCooldownIsPaid`, `test_attack_N03_reauthorisedKeyRevivesOldVoucher_boundedByClaimedAndChannel`, `test_attack_R01_voucherReplayAcrossEscrows`, `test_attack_leakedSessionKeyIsBoundedByOneChannelAndMaxSession` |
| `Audit2_Escrow.t.sol` | 23 | Claims of the design checked one by one, including `testFuzz_A2_claim_settleInsideCooldownAlwaysPaysInFull` and `test_A2_finding03_topUpDuringLiveRequestIsWithdrawableInstantly` |
| `R19_Review.t.sol` | 22 | Treasury rotation (§10), token answers (§13.1), `test_R19_ownerCannotCaptureUnclaimedAccrual_atomically`, `test_R19_voucherReplay_differentTokenInstance_rejected` |
| `MaliciousTokens.t.sol` | 17 | Re-entering, false-returning, silent, codeless, fee-on-transfer, rebasing, freezing and pausing tokens; why §2.2 excludes the last four |
| `ClockBoundaries.t.sol` | 8 | Every time boundary to the second, including `test_edge_sameSecondAtAvailableAt_settleAndWithdraw_bothOrders` |
| `TokenDecimals.t.sol` | 6 | The full cycle at 6, 8 and 18 decimals without reading `decimals()`; direct transfers to the instance |
| `MutationKills.t.sol` | 3 | Tests added to kill surviving mutants |
| `SplitSettlement.t.sol` | 2 | Splitting a settlement moves at most rounding dust from the treasury to the provider |
| `EscrowInvariant.t.sol` | 1 | Stateful campaign, 256 runs × depth 128 = 32,768 calls: `invariant_solvency`, `invariant_contributionConservation`, `invariant_claimedMonotone`, `invariant_noOverpayment_andInRangeVouchersPayInFull`, `invariant_callSummary` |
| `DeployEscrow.t.sol` | 11 (8 skipped) | The deployment script's pre-flight checks on the token and the treasury |

These are 173 tests: 165 passed and 8 skipped. The other 103 are `Phase1*.t.sol` (42, which check the use of channels described for the phase 1 of #40), and tests of other contracts of the repository (61). The identities of §13.4 are the invariants `invariant_solvency` (1 and 2) and `invariant_contributionConservation` (4); identity 3 is asserted on every settlement inside the campaign's handlers.

## Reference Implementation

Not audited and not deployed. TapeAPI 2.0.0, commit [`e29bcd00a0314946e5d97db9b444f59031e8877c`](https://github.com/BruceLanLan/tapeapi/tree/e29bcd00a0314946e5d97db9b444f59031e8877c):

- [`contracts/src/TapeAPIEscrow.sol`](https://github.com/BruceLanLan/tapeapi/blob/e29bcd00a0314946e5d97db9b444f59031e8877c/contracts/src/TapeAPIEscrow.sol): the instance, implementing §9 and §10;
- [`contracts/src/interfaces.sol`](https://github.com/BruceLanLan/tapeapi/blob/e29bcd00a0314946e5d97db9b444f59031e8877c/contracts/src/interfaces.sol): the errors, the two-step owner and the signature recovery of §8.1;
- [`contracts/test/`](https://github.com/BruceLanLan/tapeapi/tree/e29bcd00a0314946e5d97db9b444f59031e8877c/contracts/test): the tests listed under Test Cases;
- [`contracts/script/Deploy.s.sol`](https://github.com/BruceLanLan/tapeapi/blob/e29bcd00a0314946e5d97db9b444f59031e8877c/contracts/script/Deploy.s.sol): the deployment script and its pre-flight checks. At this commit the script's default token is still the USDT-pegged token of BNB Smart Chain, which the TapeAPI document planned before BEM; deploying a BEM instance with it needs an explicit override, and its checks of a BEM token have not been written.

Differences from this text: none in behaviour. The reference implementation accepts a `v` of 0 or 1, which §8.1 allows.

## Deployments

| Chain (chainId) | Contract | Address | Implementation it must point to | How to verify read-only | Sealed? |
|---|---|---|---|---|---|
| None | None | None | None | None | None |

No instance is deployed on any chain, and none has been audited.

## Security Considerations

The attacker considered can call every function, run its own providers, consumers and contracts, choose any token for an instance it deploys, observe and reorder pending transactions, and may hold a consumer's session key, a provider's keys or the owner's key.

- **Status.** The reference contract is not audited and not deployed. Reviews during development, which are not audits, reported no way to lock or take funds in version 3; their findings are tests listed under Test Cases. This TAP specifies an interface; it does not show that the interface or any implementation is secure, and an instance holds funds safely only if its code does what this text says.
- **What a channel bounds.** A consumer's exposure toward a provider is the channel's balance. A provider, or anyone holding a voucher, cannot be paid more than the channel holds and cannot touch another channel of the same consumer. A consumer may fund a channel toward itself; that moves only its own money.
- **The cooldown is the provider's protection.** A provider is paid for what it served within the channel if it settles before `availableAt` of every request on the channel (§6.1). At exactly `availableAt` both `settle` and `withdraw` succeed and the order of transactions decides who is paid, so a provider that waits for that second can lose. A provider that is offline for more than the cooldown can lose what it has not settled. A top-up made during a live request can leave with it, up to the amount requested, which is why F4 subtracts the live request (§12). Partial settlement is credit: a provider that serves beyond the channel is paid the rest only if the consumer funds again.
- **The window works the other way too.** A consumer who wants its money back waits at least 48 hours, while a provider can settle at any moment. When the token's market price falls, the provider can act at once and the consumer cannot; modest channels limit what is at stake.
- **Session keys.** A leaked key can sign vouchers only for its channel, up to the channel's balance, until its session ends, which is at most 30 days after the transaction that authorised it. It cannot be revoked. A key authorised again after its session ended revives the vouchers it signed before, bounded by `cumulative − claimedOf` on that channel (`test_attack_N03_reauthorisedKeyRevivesOldVoucher_boundedByClaimedAndChannel`), so a fresh key for each engagement is safer than a reused one. A voucher does not record when it was signed.
- **Re-entry and token behaviour.** Each guarded function changes its state before its one token call, and a call back into any guarded function or `setTreasury` reverts (§13.2). A token that returns `false`, returns malformed data or has no code makes the call revert `TransferFailed()` (§13.1). Tokens that charge a fee on transfer or rebase break identity 1 of §13.4; a token that can pause transfers lets a withdrawal cooldown run out while settlements revert, and then lets the consumer and the provider race; a token that can freeze the instance's address stops every channel at once; an upgradeable token can become any of these. §2.2 excludes all of them, and the contract cannot defend against them. Whether a token meets §2.2 is checked when an instance is deployed, not by the instance.
- **BEM.** A read-only check of BEM at BNB Smart Chain block 126436586 found 2,205 bytes of runtime code with every proxy slot zero and no `DELEGATECALL`, `SELFDESTRUCT`, `CALLCODE`, `CALL` or `CREATE` outside the compiler metadata; no owner and no freeze, pause, blacklist, burn, rescue or upgrade function; `transfer` and `transferFrom` that return `true` and move exactly the amount; and `decimals()` = 8. Whether the source is verified on the block explorer was not checked. One contract, `minter()`, can mint BEM up to `MAX_SUPPLY`; it is itself an upgradeable proxy. Issuance changes BEM's value, not what the instance holds or owes.
- **Treasury and owner.** The owner can only rotate the treasury and nominate a successor. A rotation pays the outgoing treasury first, so it cannot redirect what a treasury able to receive the token has earned; if that payment fails, the accrual goes to the new treasury. The owner can starve that payment of gas only for a token whose transfer costs roughly 130,000 to 150,000 gas or more, far above an ordinary ERC-20 transfer (`test_R19_rotation_gasSweep_neverSkipsPayout`). An owner that is a single key can be lost or stolen; the loss is bounded by the contributions accrued and not yet claimed, and every rotation emits `TreasuryChanged`.
- **The hub.** `setContribution` trusts `hub.accountOf` and the `ownerOf` of whatever contract the caller names as `circuits`. The hub is upgradeable until it is sealed (TAP-10 §13.7, §13.8). A hub owner who changed `accountOf` could let a circuit's holder set the contribution of another provider, bounded by 20 % of that provider's later settlements and never touching any channel. A contract that is not a circuits contract derives addresses that are no real container, so it can set only those. Settlement, funding and withdrawal never read the hub.
- **Providers that are not containers.** The instance pays any non-zero address other than itself. #52 requires a provider to be the service container; the instance does not check it. An address that is no circuit's container can never have its contribution set, so it always carries the default.
- **Containers on other chains.** An instance pays its provider on the instance's chain. For a container of a circuit on Base or X Layer (TAP-10 §2.1), this TAP does not establish that the circuit's holder can move tokens paid to the same address on BNB Smart Chain. Until that is shown, a provider whose circuit is on another chain risks being paid at an address it cannot use.
- **Prices in US dollars (#52).** The instance knows nothing of prices or rates. The rate that #52 adds travels with a voucher but is not part of its signed type, so `settle` pays the signed `cumulative` in base units whatever rate the two sides agreed. A wrong charge is visible in the provider's signed answers under #52, not in the instance, and the channel's balance bounds what any rate can cost.
- **Lookalike contracts and approvals.** A manifest can name any address as `payment.escrow`. A contract can copy the domain name `"TapeAPIEscrow"`, return BEM's address from `token()` and still take everything a consumer approves to it. A signature for a fake instance is worthless on a real one, because `verifyingContract` differs, but an approval is not. Clients therefore fund only instances on a list of deployments they trust, compare the code at the address with the reference build, and approve the exact amount they fund.
- **Deadlines.** A voucher whose `expires` is close to the current time can become unsettleable a block later (`test_A2_finding02_consumerChosenDeadlinesAreUnsettleableOneBlockLater`); a provider leaves itself time to settle, as #52 §5.2 allows it to require.
- **Arithmetic.** `paid × bps` overflows only for a single settlement above about 5.8 × 10^73 base units, far above any admissible supply; the reference implementation then reverts that settlement with a panic, and smaller vouchers still settle (`test_R19_payTimesBpsOverflow_isPanicOnly`).
- **What is public.** Every fund, request, withdrawal, session and settlement is a transaction that reveals the consumer, the provider, the session key and every amount; a settlement reveals the running total at that moment. A consumer that wants its channels unlinked uses separate consumer addresses.
- **Replay.** `chainId` and `verifyingContract` are in the domain, so a voucher for one instance or chain is meaningless on another; `consumer` and `provider` are in the type, so a voucher for one channel cannot be settled on another.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
