---
tap: TBD
title: Payment Vouchers for Container Services
description: How a caller pays a container service per call with cumulative signed vouchers in BEM, for methods priced in BEM or in US dollars at a rate that the service states and the caller checks.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/38
status: Draft
type: Application
created: 2026-10-08
requires: TAP-10, TAP-11, TAP-13
license: CC0-1.0
---

# TAP-TBD: Payment Vouchers for Container Services

## Summary

A way to pay an online service that belongs to a TapeOut circuit for each call, with prices that can be set in US dollars, paid in BEM, and settled on chain only now and then.

## Abstract

This TAP defines the payment voucher that TAP-13 reserves: an EIP-712 message in which a caller states the total amount of BEM it owes one service container, how the voucher travels in a TAP-13 request, when a service asks for one (`PAYMENT_REQUIRED`) or refuses one (`BAD_VOUCHER`), and the `error.data` of both codes. It adds an optional top-level manifest member that prices methods in US dollars, and fixes how such a price becomes an amount of BEM: at a rate that the service states in a signed answer, that the caller compares with its own reading of named on-chain price sources before it signs, and that is capped by the method's `priceBEM`. Every priced answer records, inside its signed body, the BEM it charged, the rate it used and the caller's running total, so that a usage receipt and a later settlement can be checked against it. How a voucher is settled is Standards content and outside this TAP: the TAP names the settlement contract only through the manifest's `payment.escrow` (TAP-11 §3.2) and lists the four facts it reads from that contract.

## Motivation

TAP-11 lets a service publish a price per method and TAP-13 lets it sign every answer, but neither says how a caller pays. TAP-13 reserves the request member `voucher` and the codes `PAYMENT_REQUIRED` and `BAD_VOUCHER` for a payment TAP. Until one exists, a service that wants to charge has nothing to point to, every provider invents its own way of saying "I will pay for this", and a caller cannot tell a valid promise to pay from an invalid one.

Paying on chain for every call is too slow and too expensive for API traffic. A cumulative voucher lets a provider accept many calls off chain and settle rarely, while the caller's exposure toward each provider stays bounded by what it funded toward that provider.

Prices in BEM move with BEM's market price. Services and their users budget in US dollars, so a price that is fixed in dollars and paid in BEM, converted when each call is charged, keeps prices stable while BEM stays the asset that pays for services. The conversion needs a rate, and a rate that only the provider reports would let a provider charge what it likes; this TAP makes the rate a signed, checkable statement and bounds what any rate can cost.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms and notation

- **Container**, **holder**: as in TAP-10 §1. **Service**, **manifest**, **method**: as in TAP-11 §1 and §3. **Signer**, **provider**, **client**, **envelope**, **live endpoint**: as in TAP-13 §1.
- **BEM** is the ERC-20 token at `0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a` on BNB Smart Chain (chain ID 56), with 8 decimals (TAP-11 §3.3). A **base unit** is 10^-8 BEM.
- A method whose `priceBEM` is zero in value (for example `"0"` or `"0.00"`) is free. Every other method is a **priced method**. A **USD-priced method** is a priced method listed in the manifest member `usdPricing` (§4.1); every other priced method is **BEM-priced**.
- The **consumer** is the address that owes the payment. The **provider address** of a voucher is the service container. A **channel** is a pair (consumer, provider address).
- The **settlement contract** is the contract named by the manifest's `payment.escrow` (TAP-11 §3.2). **F1** to **F4** are the facts read from it (§2.2).
- A **voucher signer** is the address that signs a voucher: the consumer, or a key authorised by the consumer for that channel (§2.2 F3, §3.3).
- A **charge** is the number of base units that one call costs (§4.3, §5). A **quote** is a rate stated by the provider (§4.4). A **charge record** is the member `charge` of a priced result (§7).
- **Amount forms.** A *base-unit string* is a decimal integer without sign, fraction or leading zeros (`^(0|[1-9][0-9]*)$`). An *amount object* is `{ "currency": <code>, "amount": <string> }` with exactly these two members in this order, where `amount` matches `^[0-9]+\.[0-9]{8}$`. For `"BEM"`, the amount object of `n` base units has `amount` equal to `n` written with exactly 8 fraction digits (`2500000000` is `"25.00000000"`). For `"USD"`, `amount` is in US dollars with 8 fraction digits.
- Notation is that of TAP-13 §1. `ceil(a / b)` for positive integers is `(a + b − 1) div b`. Addresses are compared case-insensitively.

### 2. Settlement

#### 2.1 Asset and chain

Every voucher, charge and `cumulative` in this TAP is an amount of BEM on BNB Smart Chain, whatever chain the service's circuit is on. Prices can be stated in US dollars (§4); payment is always in BEM. `payment.escrow` is an address on BNB Smart Chain (chain ID 56).

#### 2.2 What this TAP reads from the settlement contract

This TAP does not define the settlement contract. It relies on four facts about it:

| Fact | Content |
|---|---|
| **F1** | The token the contract settles |
| **F2** | For a channel, the amount the contract has already paid to the provider address (the **amount paid**) |
| **F3** | For a channel and a key, whether the consumer has authorised the key to sign vouchers for that channel, and until when |
| **F4** | For a channel and an amount, whether the funds the contract holds for the channel cover that amount |

Each fact is defined by the settlement contract's own specification. A client and a provider obtain them for the contracts they choose to use, by configuration where no specification is available to them.

- A client MUST NOT sign a voucher for a settlement contract unless it has established through F1 that the contract settles BEM on chain 56. A client that cannot establish it MUST NOT sign.
- A provider that cannot obtain F2 for a channel MUST treat the amount paid as unknown and MUST NOT accept vouchers on that channel.

### 3. Voucher

#### 3.1 Domain and type

| Item | Value |
|---|---|
| Domain type | `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)` |
| `name` | `"TapeAPIEscrow"` |
| `version` | `"1"` |
| `chainId` | `56` |
| `verifyingContract` | The manifest's `payment.escrow` |
| Primary type | `Voucher(address consumer,address provider,uint256 cumulative,uint64 expires)` |
| `VOUCHER_TYPEHASH` | `keccak256("Voucher(address consumer,address provider,uint256 cumulative,uint64 expires)")` = `0x8e017cc56e9f2cb1f0fd1af4419f7c77b8d3f92099263f2b8aba4ba44cf50407` |

```
DOMAIN_SEPARATOR = keccak256(abi.encode(
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
    keccak256("TapeAPIEscrow"), keccak256("1"), 56, escrow))
structHash       = keccak256(abi.encode(VOUCHER_TYPEHASH, consumer, provider, cumulative, uint64 expires))
digest           = keccak256(0x19 ‖ 0x01 ‖ DOMAIN_SEPARATOR ‖ structHash)
sig              = r ‖ s ‖ v      // 65 bytes, secp256k1 over digest, without the EIP-191 prefix
```

- `provider` MUST be the service container.
- `cumulative` is the total number of base units the consumer owes the provider on this channel, over all calls. Across the vouchers of one channel it MUST NOT decrease.
- A voucher is valid while the current time is at most `expires` (inclusive).
- `sig` is 65 bytes. A signer MUST set `v` to 27 or 28 and MUST produce low-`s` signatures. A verifier MUST reject a `v` other than 27 or 28, including 0 and 1 (unlike TAP-13 §5, which reads 0 and 1 as 27 and 28), and MUST reject `r` outside [1, n − 1] and `s` outside [1, n/2], where n is the order of secp256k1 (TAP-13 §5).

#### 3.2 Wire form

A voucher travels in the `voucher` member of a TAP-13 request (TAP-13 §3):

```json
"voucher": { "consumer": "0x…", "provider": "0x…", "cumulative": "5833333334", "expires": 1789003600, "sig": "0x…", "signer": "0x…", "rate": "0.0003" }
```

| Member | Required | Content |
|---|---|---|
| `consumer` | yes | `0x` and 40 hex digits |
| `provider` | yes | `0x` and 40 hex digits |
| `cumulative` | yes | A base-unit string whose value is at most 2^256 − 1 |
| `expires` | yes | A JSON integer, Unix seconds, 0 ≤ `expires` ≤ 2^53 − 1 |
| `sig` | yes | `0x` and 130 hex digits |
| `signer` | no | `0x` and 40 hex digits: the voucher signer, when it is not the consumer. Informative: the provider uses the address it recovers |
| `rate` | for a USD-priced method | The rate of the quote the client used (§4.4), exactly as the quote wrote it |

As TAP-13 §3 states, `voucher` is not part of the request object and is not covered by the envelope's signature; the charge record (§7) binds the accepted voucher to the answer.

#### 3.3 Who signs

- The voucher signer MUST be recovered from `digest` and `sig` by ECDSA. EIP-1271 signatures are not accepted.
- The voucher is acceptable only if the recovered address is the consumer, or a key that F3 reports, at the time of the check, as authorised by the consumer for this channel and not expired. A key authorised for another channel of the same consumer is not authorised for this one.
- A consumer that is a contract (for example a container, which is an ERC-6551 account, or a multisig wallet) cannot sign a voucher itself. It authorises a key for the channel with the settlement contract, by a transaction it sends, and that key signs the vouchers.

### 4. Prices in US dollars

#### 4.1 Manifest member `usdPricing`

This TAP defines the top-level manifest member `usdPricing` (TAP-11 §3.1). It is optional; a manifest without it has only BEM-priced methods.

```json
"usdPricing": {
  "methods": { "search": "0.01" },
  "toleranceBps": 200,
  "maxQuoteS": 120,
  "rateSources": [ { "type": "v3-twap", "pool": "0x…", "usd": "0x…", "window": 1800 } ]
}
```

| Member | Type | Required | Rule |
|---|---|---|---|
| `methods` | object | yes | Non-empty. Method name to price in US dollars. Each name MUST be the `name` of a priced method of the manifest. Each price MUST match `^[0-9]+(\.[0-9]{1,8})?$` and MUST NOT be zero in value |
| `toleranceBps` | integer | yes | 1 to 2000. How far, in basis points, a quote can lie below the reference rate (§4.5) |
| `maxQuoteS` | integer | yes | 1 to 900. The longest time a quote is valid for, counted from its `asOf` (§4.4) |
| `rateSources` | array | yes | Non-empty. Where a reference rate is read (§4.5) |

A manifest whose `usdPricing` breaks any rule of this table is invalid for this TAP: a client MUST NOT pay a USD-priced method of that service. It MAY still call the service's free methods and pay its BEM-priced methods.

#### 4.2 `priceBEM` of a USD-priced method

For a USD-priced method, `priceBEM` is the most BEM that one call can cost: the **cap**. It is not zero in value, so a USD-priced method is a priced method in the sense of TAP-13 §3 and §6, and a provider asks for a voucher for it exactly as for a BEM-priced method.

#### 4.3 Conversion

For a USD-priced method with USD price `p`, cap `c` and a quote with rate `r`:

```
U         = p as an integer number of 10^-8 USD           ("0.01" is 1000000)
R         = r as an integer number of 10^-18 USD per BEM  ("0.0004" is 400000000000000)
P         = c as an integer number of base units           ("100" is 10000000000)
converted = ceil(U × 10^18 / R)
charge    = min(converted, P)
capped    = (converted > P)
```

Implementations MUST use exact integer arithmetic with no upper bound and MUST NOT use floating point. The charge of a BEM-priced method is its `priceBEM` in base units, and `capped` does not apply to it.

#### 4.4 Quotes

A quote is a JSON object with exactly these members:

| Member | Type | Content |
|---|---|---|
| `rate` | string | US dollars per 1 BEM. Matches `^[0-9]+(\.[0-9]{1,18})?$` and is not zero in value |
| `asOf` | integer | Unix seconds: the end of the period over which the provider measured the rate. Not later than the `ts` of the envelope that carries the quote |
| `validUntil` | integer | Unix seconds: the last second at which the provider honours this rate. `asOf` < `validUntil` ≤ `asOf` + `maxQuoteS` |

- A provider states quotes only inside signed envelopes: in the `error.data` of `PAYMENT_REQUIRED` and `BAD_VOUCHER` for a USD-priced method (§6), and in the charge record of every USD-priced result (§7).
- A provider MUST honour every quote it has stated, at every live endpoint and on every instance that answers for the service, until its `validUntil`: it MUST accept a voucher whose `rate` equals the `rate` of such a quote, compared as strings, and charge at that rate. It MUST NOT accept a `rate` it has not stated, or one whose quotes have all passed their `validUntil`.
- A client MUST accept a quote only from an envelope that it verified under TAP-13 §8 for this service, MUST NOT use it after its `validUntil`, and MUST reject a quote that breaks the rules of the table above.

#### 4.5 Reference rate and the client's check

Each element of `rateSources` names a time-weighted average price over one pool that implements the oracle of Uniswap v3 (`observe(uint32[])`, selector `0x883bdbfd`; PancakeSwap v3 pools implement the same function):

| Member | Type | Rule |
|---|---|---|
| `type` | string | `"v3-twap"`. A client MUST ignore an element of a type it does not know |
| `pool` | string | The pool on BNB Smart Chain, `0x` and 40 hex digits. One of its two tokens MUST be BEM |
| `usd` | string | The pool's other token, a token that the holder states is worth one US dollar, `0x` and 40 hex digits |
| `window` | integer | 600 to 86400. The averaging period in seconds |

A client SHOULD treat an element whose `usd` it does not recognise as a US dollar token as an element of a type it does not know. If no element of `rateSources` remains, the client treats `usdPricing` as invalid (§4.1).

The **reference rate** of one source, at a block `B` that the client reads under TAP-10 node agreement:

1. Read `token0()` (selector `0x0dfe1681`) and `token1()` (selector `0xd21220a7`) of `pool`, and `decimals()` (selector `0x313ce567`) of `usd`, as `d_U`. If the two tokens are not BEM and `usd`, the source has no reference rate.
2. Call `observe([window, 0])` on `pool` at `B`, giving tick cumulatives `c0` and `c1`. If the call fails (for example because the pool keeps too few observations for `window`), the source has no reference rate.
3. `meanTick = floor((c1 − c0) / window)`, rounding toward negative infinity.
4. `p = 1.0001^meanTick`, the price of one base unit of `token0` in base units of `token1`.
5. With `d_B` = 8: if BEM is `token0`, the rate is `p × 10^(d_B − d_U)`; if BEM is `token1`, it is `1 / (p × 10^(d_U − d_B))`.

A reference rate is used only for the comparison below, so an implementation MAY compute it in floating point.

**The client's check.** Before signing a voucher at a quote's rate, a client MUST obtain a reference rate and MUST refuse the quote when `rate` × 10000 < reference × (10000 − `toleranceBps`). The reference rate is the client's own: it SHOULD be the median of the reference rates of the sources it read from `rateSources`, read at a block no older than `maxQuoteS` seconds. A client MAY use a smaller tolerance than `toleranceBps`, and MAY instead use another source it trusts, such as a rate its user confirmed. A quote whose rate is above the reference passes: it makes the call cheaper for the client.

A provider SHOULD derive its quotes from the sources it lists, and SHOULD set `asOf` to the time of the block at which its averaging period ended.

### 5. Provider

#### 5.1 When a voucher is required

- For a free method, a provider ignores `voucher` (TAP-13 §3).
- For a priced method, a request without `voucher` MUST be answered with `PAYMENT_REQUIRED`, and a request whose voucher fails any check of §5.2 MUST be answered with `BAD_VOUCHER`. Both are signed envelopes whose `error.data` follows §6.

#### 5.2 Checks

`last` is the larger of the highest `cumulative` the provider has accepted on the channel and the amount paid on it (F2). The provider MUST keep its record of accepted vouchers consistent with F2: it MUST NOT accept a voucher whose `cumulative` is at or below the amount paid, even after a restart or on another instance.

Before it serves a priced call, a provider MUST check, and on the first failure refuse with the `reason` given:

1. `voucher` is an object whose members satisfy the table of §3.2 (`malformed`);
2. `provider` equals the service container (`provider`);
3. the current time is at most `expires` (`expired`). A provider MAY require a minimum remaining lifetime of the voucher and of the authorisation of its signer (F3), so that it can settle in time; one that does MUST state the minimum as `minVoucherLifeS` in every `PAYMENT_REQUIRED`, and in every `BAD_VOUCHER` that the minimum causes (`lifetime`);
4. the signature satisfies §3.1 and recovers to a voucher signer acceptable under §3.3 (`signature`);
5. for a USD-priced method, `rate` is present and honoured under §4.4 (`rate`);
6. `cumulative` − `last` is at least the charge of the call: §4.3 at the voucher's `rate` for a USD-priced method, `priceBEM` for a BEM-priced one (`stale` when `cumulative` ≤ `last`, `insufficient` otherwise).

A provider SHOULD also check, through F4, that the funds held for the channel cover `cumulative` minus the amount paid, and refuse with `funds` when they do not. A provider that serves without this check extends credit at its own risk.

#### 5.3 Serving and charging

- A provider MUST process the priced calls of one channel one at a time, or otherwise ensure that no two calls are accepted against the same `last`.
- When a call is served, the provider records the voucher as accepted, and the charge of the call is `cumulative` − `last`, which is at least the charge of §4.3 and is more when the client signed for more.
- The result of a priced call MUST be a JSON object and MUST contain the charge record of §7 as its member `charge`. A method's own result MUST NOT use the member name `charge` for anything else.
- An answer with `ok` `false`, including `INTERNAL` (TAP-13 §4, §6), charges nothing: the provider MUST NOT count the voucher of that request as accepted, and MUST accept the next voucher of the channel against the same `last`.
- A provider MUST keep the voucher with the highest `cumulative` of each channel until it is settled or expired.

### 6. `error.data` of `PAYMENT_REQUIRED` and `BAD_VOUCHER`

| Member | `PAYMENT_REQUIRED` | `BAD_VOUCHER` | Content |
|---|---|---|---|
| `reason` | absent | REQUIRED | One of `malformed`, `provider`, `expired`, `lifetime`, `signature`, `rate`, `stale`, `insufficient`, `funds` (§5.2). A client MUST treat a value it does not know as a refusal |
| `price` | REQUIRED | REQUIRED | Base-unit string: the charge of this call now. For a USD-priced method, at the rate of `quote` |
| `priceUSD` | USD-priced only | USD-priced only | Amount object in `"USD"`: the method's price in `usdPricing` |
| `quote` | USD-priced only | USD-priced only | A current quote (§4.4) |
| `minVoucherLifeS` | §5.2 item 3 | §5.2 item 3 | Integer seconds |
| `lastCumulative` | absent | with `stale` | Base-unit string: `last` (§5.2) |
| `onChainClaimed` | absent | with `stale` | Base-unit string: the amount paid on the channel (F2) |
| `voucher` | absent | with `stale`, when the provider holds one | `{ "cumulative", "expires", "sig" }`: the accepted voucher whose `cumulative` equals `lastCumulative`, as the consumer's voucher signer signed it |

`price`, `priceUSD` and `quote` are hints. A client that finds `price` different from the charge it computed from its copy of the manifest MUST reread the service (TAP-11 §7.1) before it signs a voucher for more.

### 7. Charge record

The member `charge` of a priced result is an object:

| Member | Type | Content |
|---|---|---|
| `consumer` | string | The consumer of the accepted voucher |
| `cumulative` | string | Base-unit string: the `cumulative` of the accepted voucher |
| `amount` | object | Amount object in `"BEM"`: the charge of this call (§5.3) |
| `price` | object | USD-priced only. Amount object in `"USD"`: the method's price in `usdPricing` |
| `rate` | string | USD-priced only. The rate the call was charged at, as in the voucher |
| `rateAsOf` | integer | USD-priced only. The `asOf` of the quote with that rate |
| `capped` | boolean | USD-priced only. Present, as `true`, exactly when `capped` of §4.3 is true |
| `quote` | object | USD-priced only. A current quote (§4.4) for the next call |

The charge record is part of the envelope's body and therefore covered by its signature (TAP-13 §5).

### 8. Client

#### 8.1 Before paying

- A client MUST resolve the service under TAP-11 §2 and SHOULD reread it as TAP-11 §7.1 recommends before an action that spends funds.
- `last` for a channel is the highest `cumulative` that the client has seen in a charge record it accepted under §8.3, or adopted under the next item; it is 0 for a new channel.
- A client MUST NOT raise `last` to a figure taken from `BAD_VOUCHER` unless either F2 reports at least that amount as paid on the channel, or the attached `voucher` recovers under §3 to the consumer or to a key acceptable under §3.3, with a `cumulative` equal to that figure.

#### 8.2 Signing

For each priced call a client computes the charge (§4.3), signs a voucher with `cumulative` = `last` + charge, and sends it in the request. For a USD-priced method it MUST first:

1. take a quote that it accepted under §4.4 and that is still valid;
2. pass the check of §4.5;
3. confirm that the charge does not exceed the cap.

A client MAY require the user, or a budget the user set, to approve a charge before it signs.

#### 8.3 After the answer

On an *accepted result* (TAP-13 §8) of a priced call, the client checks the charge record:

1. If `charge` is absent, or its `consumer` or `cumulative` differs from the voucher the client sent: either the voucher was replaced on the path (TAP-13 does not sign it) or the provider erred, and the client cannot tell which. The client MUST NOT raise `last` from this record, and MUST NOT sign further vouchers for the service before it has reread the service and read F2 for the channel.
2. Otherwise, if `amount` is not equal in value to `cumulative` − `last`, or, for a USD-priced method, `price` is not equal in value to the manifest's price, `rate` differs from the voucher's `rate`, or `capped` is present when `capped` of §4.3 is false or absent when it is true: this is a provider fault, signed by the provider. The client MUST NOT sign further vouchers for the service before it rereads the service, and SHOULD keep the envelope as evidence.
3. Otherwise the client sets `last` to `cumulative`.

On an *accepted error*, `last` does not change.

## Rationale

- **One topic, one type.** This TAP covers the voucher, its transport, prices and the evidence of each charge: conventions an application adopts on top of TAP-11 and TAP-13. The settlement contract's interface is Standards content (TAP-01 §3) and outside this TAP, as TAP-11 §3.3 leaves "how a price is paid and settled" outside. Section 2.2 lists the only four facts this TAP needs from that contract, so that the TAP stays complete whichever contract a service names.
- **Cumulative vouchers.** A voucher states a running total, so it needs no nonce, a lost voucher is superseded by the next one, and the provider settles once for many calls.
- **The voucher format is unchanged.** The domain, type and type hash are those of the TapeAPI document "TAPI-22", which the reference implementation has signed and verified since 2026-09-20. The voucher does not name the token: `verifyingContract` pins it to one settlement contract, that contract settles one token (F1), and this TAP admits only BEM (§2.1). Adding a token member would change the type hash and protect against nothing that `verifyingContract` does not already cover.
- **`v` of 27 or 28 only.** TAP-13 §5 reads a `v` of 0 or 1 as 27 or 28, and so do some contracts. Widely used on-chain recovery routines, such as OpenZeppelin's `ECDSA.recover`, refuse 0 and 1. A provider that accepted such a voucher off chain might find it unsettleable; requiring 27 or 28 makes off-chain and on-chain acceptance the same under either kind of contract.
- **ECDSA only.** A provider accepts a voucher off chain and settles it later. With EIP-1271 the answer of the consumer's contract can change between those two moments (a contract's `isValidSignature` may depend on its state), so an accepted voucher could become unsettleable; ECDSA recovery gives the same answer at both moments, off chain and on chain. A contract consumer authorises a key instead, which costs one transaction per channel and leaves the contract in control of the amount it funds.
- **US dollar prices, BEM settlement.** This follows the preference the TapeOut team stated in #38: prices stay stable in dollars, and BEM remains the asset that pays for services. A new top-level member (TAP-11 §3.1) was chosen over a change to TAP-11 §3.2–§3.3, so that manifests and clients that know only TAP-11 keep working.
- **`priceBEM` as a cap.** TAP-13 ties `voucher` and `PAYMENT_REQUIRED` to a non-zero `priceBEM`, so a USD-priced method needs one. TAP-11 §3.3 describes `priceBEM` as an amount of BEM; for a USD-priced method this TAP reads that amount as the most BEM one call can cost. A one-line clarification of TAP-11 §3.3 to that effect is proposed separately; TAP-11's text is otherwise unchanged. The cap gives the price a meaning a caller can rely on: it is published in the manifest, which the holder controls through the site (TAP-10), while quotes are signed by the online signer key. Whatever the rate, a stolen signer key or a manipulated price source can cost a caller at most the cap per call. The alternative, a floor, would protect the provider, which already chooses its own quotes. The cost: when BEM falls far enough, the cap binds and the provider is paid less than its dollar price until the holder raises it.
- **The rate is signed inside the answer.** Putting quotes in `error.data` and in the charge record makes them part of the TAP-13 body, so they are signed with no new signature format and are verifiable with the envelope already in hand. The quote in each priced answer serves the next call, so a client pays without an extra round trip once it has a quote. The cost is that the result of a priced method must be an object with a reserved member; TAP-13 §4 allows any JSON value as a result, and no envelope member is defined for extensions.
- **A quote is a promise for a short time.** The client names the rate in its voucher and the provider must honour any rate it stated until `validUntil`, so a client never signs at one rate and is charged at another, and a provider never has to accept a rate older than `maxQuoteS`.
- **The client checks the rate against its own reading, one-sided.** A quote above the reference rate makes the call cheaper for the client, so only a quote below it is refused. Combining the two options the TapeOut team described in #38 gives each side what it needs: the provider commits to one rate per call in a signed statement, and the client does not have to trust it. A time-weighted average is used rather than a pool's current price, which one large trade can move within a block; to move a 30-minute average, a trader has to hold the pool's price away from the market for 30 minutes against arbitrage. The sources are named in the manifest because a client needs to know where to look, and so that a provider whose quotes stray from its own sources is visibly in the wrong. BEM's markets are small (Security Considerations), which is why the cap bounds every call whatever the sources say. An oracle network was not chosen because none publishes a BEM/USD price that we know of.
- **The charge record.** Each priced answer states the charge, the running total and the rate in its signed body, as #38 asked, so that the provider cannot later claim a different charge for an answer, and a usage receipt or a settlement can be checked against the answers.
- **Units shared with the AI usage receipts draft (pull request #26).** Both state amounts as amount objects with 8 fraction digits, and BEM has 8 decimals, so a receipt's `"BEM"` amount and a charge record's `amount` are the same unit. A receipt states what an answer is worth under a published price table and moves no funds; a voucher commits the caller to pay, and a charge record states what was taken against it. Methods priced by measured usage, such as the AI formats of that draft, are not covered by this version. Their charge is known only after the answer, which needs either payment after the answer or a voucher that covers an upper bound, each with trade-offs that deserve their own discussion; and that draft's §7.2 forbids its sidecar to add members to `result`, so a charge record of §7 cannot be placed in those answers as they are.
- **Who learns what.** Funding, key authorisation and settlement are on chain and public. The TapeOut team stated in #42 that who pays whom for container services may be public by default; offers and deliveries that need privacy can travel in an encrypted channel. This TAP adds nothing on chain beyond what settlement already needs.
- **Acknowledgement.** Thanks to @Theairresearch, from whom the idea for TapeAPI came.

## Backwards Compatibility

This TAP defines names that TAP-13 §6 reserves for it (`voucher`, `PAYMENT_REQUIRED`, `BAD_VOUCHER`) and does not change TAP-13. It does not change TAP-11 either; for USD-priced methods it reads `priceBEM` as a cap (Rationale). A client that implements only TAP-13 is unaffected: it treats both codes as errors, as TAP-13 §8 requires. A client that knows only TAP-11 reads the cap of a USD-priced method as its price, which overstates the cost but never understates it.

When a Standards TAP that specifies a settlement interface providing F1 to F4 has a number, this TAP can add it to `requires`; until then §2.2 states what is needed from any settlement contract.

The format was published in the TapeAPI repository as "TAPI-22" (called "TAP-22" until 2026-09-30; neither is a TAP number). The voucher's domain, type, type hash and digest are unchanged, so every voucher signed under that document with `v` of 27 or 28 verifies under this one. Compared with that document, this text:

- admits BEM only, where the TapeAPI document lets one settlement contract per token settle any admitted token;
- adds prices in US dollars (`usdPricing`, quotes, the cap), the member `rate` of a voucher, the member `reason` of `BAD_VOUCHER`, and the charge record of priced results;
- refuses a voucher `v` of 0 or 1, which the TapeAPI implementation reads as 27 or 28;
- leaves the settlement contract's interface, the funds check and the withdrawal delay to the settlement contract's own specification;
- states that a contract consumer authorises a key and that EIP-1271 is not accepted.

No settlement contract is deployed, and the TapeAPI services that answer today serve only free methods, so no payment made under that document has to be migrated.

## Test Cases

The vector files are in `assets/tap-draft-payment-vouchers/`. Keys and addresses in them are published test values; the settlement contract address `0x00000000000000000000000000000000000E5c70` and the pool addresses `0x…0B0010` to `0x…0B0012` are not deployments. `gen.mjs` (MIT) generates every file from the text of this TAP with Node.js and two npm packages at fixed versions (`package.json`); `check.py` (MIT) recomputes the arithmetic with the Python standard library.

- `conversion.json` (§4.3): 9 conversions from a USD price, a rate and a cap to `converted`, `charge` and `capped` (exact division, rounding up once, the cap applying, a converted amount equal to the cap, 18 fraction digits in the rate, the smallest price, an integer rate, values beyond 2^64, leading zeros), and 10 inputs that are refused (a zero rate, 19 fraction digits, exponent form, a missing integer part, a trailing dot, a sign, a zero USD price, 9 fraction digits in a price, a cap of zero in value).
- `voucher.json` (§3): the domain separator, 3 vouchers with struct hash, digest, signature and recovered address (one signed by a session key), and 4 encodings of the first signature that a verifier refuses (`v` of 0 or 1, the high-`s` twin, `v` = 29, 64 bytes).
- `envelopes.json` (§4.4, §6, §7): the manifest excerpt they assume, and 4 TAP-13 envelopes signed by the test signer `0x1563915e194D8CfBA1943570603F7606A3115508` for container `0x86DDaEF00401E3F10418398D67D7189fc458eA95`: a `PAYMENT_REQUIRED` with a quote, a priced result with its charge record and the next quote, a `BAD_VOUCHER` for a rate the provider never quoted, and a `BAD_VOUCHER` for a stale `cumulative` carrying the consumer's own voucher.
- `rate-source.json` (§4.5): 3 constructed sources (each orientation of BEM in the pool, 18 and 6 decimals, divisions with and without a remainder) with their mean ticks and reference rates, the median of two, and 4 quotes checked against it at 200 and 300 basis points. It also records two reads of real pools on BNB Smart Chain at block 126412948 with their mean ticks only.

Example, the second conversion:

```
priceUSD "0.01"   rate "0.0003"   priceBEM "100"
U = 1000000   R = 300000000000000   P = 10000000000
converted = ceil(1000000 × 10^18 / 300000000000000) = 3333333334
charge    = 3333333334  ("33.33333334" BEM),  capped = false
```

## Reference Implementation

Partly implemented, in TapeAPI 1.8.1 at commit [`4a1ac4fe2a0b2e3327652a794794765dd5da98ef`](https://github.com/BruceLanLan/tapeapi/tree/4a1ac4fe2a0b2e3327652a794794765dd5da98ef):

- [`sdk/src/sig.js`](https://github.com/BruceLanLan/tapeapi/blob/4a1ac4fe2a0b2e3327652a794794765dd5da98ef/sdk/src/sig.js): the voucher digest, signing and low-`s` recovery (§3.1);
- [`server/src/index.js`](https://github.com/BruceLanLan/tapeapi/blob/4a1ac4fe2a0b2e3327652a794794765dd5da98ef/server/src/index.js): a provider's checks and charging for BEM-priced methods (§5), `PAYMENT_REQUIRED` and `BAD_VOUCHER` with `price`, `minVoucherLifeS`, `lastCumulative`, `onChainClaimed` and the proof voucher (§6), per-channel serialisation and the reconciliation with the amount paid;
- [`sdk/src/index.js`](https://github.com/BruceLanLan/tapeapi/blob/4a1ac4fe2a0b2e3327652a794794765dd5da98ef/sdk/src/index.js): a client's voucher signing and its rule for adopting a stale figure (§8.1).

To be implemented: `usdPricing`, quotes, the conversion, the reference rate and check of §4.5, the member `rate` of a voucher, the member `reason`, the charge record, and the refusal of a voucher `v` of 0 or 1.

## Deployments

None. This TAP deploys no contract. It reads the token that the settlement contract settles (§2.2) and, for the reference rate, the pools named in `rateSources` (§4.5). No settlement contract is deployed.

## Security Considerations

The attacker considered can read, delay, drop, replay and modify traffic between client and provider, can run services of its own, can trade in the pools that price sources read, and may hold a provider's signer key.

- **What a voucher proves.** That the consumer, or a key it authorised for the channel, committed to owe the provider container at most `cumulative` base units of BEM in total, until `expires`, payable through one settlement contract on one chain. It does not prove that any call was made or answered, that an answer was correct, or that the price was fair. The charge record proves that the provider's signer stated, for one request, the charge, the running total and the rate; it makes a wrong charge attributable, not impossible.
- **Exposure of a caller.** A caller's loss toward one provider is bounded by what it funded toward that provider in the settlement contract. Within that, a client that follows §8 signs at most one call's charge ahead of the answers it has received. A provider that takes a voucher and does not answer can keep it and settle it; the caller then loses that one charge, and no more unless it keeps calling that provider. A client that signs a voucher for more than the charge pays the difference: the provider can settle the whole `cumulative`.
- **Stale running totals.** A provider could claim a higher `last` than the truth so that the client signs a voucher for an arbitrary amount. §8.1 refuses any figure that is not proved by F2 or by the consumer's own signature.
- **Rates: what the check protects, and what it does not.** `rateSources`, `usd`, `toleranceBps` and `priceBEM` are all written by the holder in the manifest. The client's check protects against the signer key and the provider's software straying from what the holder published; it does not protect against the holder, who can name a pool it controls, a token it calls a dollar, the widest tolerance and a high cap. A client that does not recognise a `usd` token treats the source as unknown (§4.5). Within the rules, a tolerance of 2000 basis points lets a provider quote 20 % below the reference, which charges 25 % more BEM than the reference rate would; the cap bounds every call at `priceBEM` whatever the rate.
- **Rates: moving the reference.** The reference itself can be pushed down by trading in the named pools. A time-weighted average makes that cost the trader the arbitrage losses of holding the price away for the whole window, but BEM's pools are small: at the time of writing, the deepest BEM/USD stablecoin pools on BNB Smart Chain hold in the order of 10^5 US dollars, and a trade of roughly 2 × 10^4 US dollars would move the spot price of the deepest of them by about 10 %, of the next by about 2 × 10^3 US dollars. With two sources the median is their mean, so moving the shallower pool's average by 20 % moves the reference by 10 %. Such an attack is open to anyone, not only the provider, and also lowers the rate for every other user of the pool. A cap close to the dollar price, more sources and a tight tolerance keep the possible gain small. A stablecoin that loses its peg moves the reference rate in the same proportion.
- **Quote replay.** A quote is valid for at most `maxQuoteS` from its `asOf`, and a client names the rate it signed at, so an old quote cannot be applied to a new call after its `validUntil`. A provider cannot charge a client at a rate the client did not name.
- **Signer key.** Whoever holds the signer key can state quotes and sign charge records for the service, but cannot sign vouchers. Stating a low rate, it can make a client pay at most the cap per call, and only for calls the client chose to make. Stating an arbitrarily high rate, it can give the service away for almost nothing: a loss to the holder, not to callers. TAP-13's Security Considerations apply to the envelopes.
- **Voucher signer keys.** A key authorised for one channel can sign vouchers only for that channel and only up to its funds; its lifetime and revocation are defined by the settlement contract. A fresh key per channel and modest channel balances keep a leaked key's reach small.
- **Replay across contracts and chains.** `chainId` and `verifyingContract` are in the domain, so a voucher for one settlement contract is meaningless in another; `provider` is in the type, so a voucher for one service cannot be used by another.
- **Settlement.** A voucher is only as good as the settlement contract that pays it. Until a settlement contract is deployed and independently audited, a provider that accepts vouchers is extending credit. A client signs only for a contract that settles BEM (§2.2), and a hostile manifest can name any address as `payment.escrow`; whether a client funds such a contract is outside this TAP, and so are the risks of the contract itself.
- **What is public.** Funding a channel, authorising a key and settling are transactions on BNB Smart Chain: they reveal the consumer, the provider container, the voucher signer key and every amount funded, withdrawn and settled, and settlement reveals the running total at the moment of settling. Off chain, the provider learns every request; the charge record repeats the consumer and the running total to whoever holds the answer. A consumer that wants its activities unlinked uses separate consumer addresses.
- **BEM itself.** BEM is not upgradeable and has no owner, but one contract (its `minter()`, itself an upgradeable proxy) can mint new BEM up to `MAX_SUPPLY` (21,000,000 BEM, many times the supply at the time of writing). Issuance moves BEM's price and therefore the rate, and every amount owed is in BEM; this is value risk to both sides, not a risk this TAP can remove.
- **Trust inherited from resolution.** The provider container, the signer, `payment.escrow` and `usdPricing` come from a manifest resolved under TAP-11, and inherit its assumptions.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
