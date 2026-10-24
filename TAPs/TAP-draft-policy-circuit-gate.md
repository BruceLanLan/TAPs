---
tap: TBD
title: Policy Circuit Gate
description: An agent's spending policy written as a netlist-bound circuit with fixed pins, bound by its principal to a mandate, an escrow session or an account, so that any counterparty can re-run the policy over a spend request and reach the same allow-or-deny answer.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/81
status: Draft
type: Application
created: 2026-10-24
requires: TAP-02, TAP-11, EIP-712
license: CC0-1.0
---

# TAP-TBD: Policy Circuit Gate

> **Conditional draft.** The netlist file format, its hash and the evaluation interface this text relies on are those of the netlist-NFT draft in TAPs pull request #67, which is not merged; the parts used are inlined in Specification 0 and 2 and this TAP names no draft in `requires`. The mandate and escrow drafts (#47, #60, #59) appear only in conditional clauses. Nothing here is a conformance claim about any deployed contract, and no contract of this TAP exists.

## Summary

An agent's spending limits are written as a small circuit whose bytes are hashed and bound to the agent's mandate or escrow session by the agent's principal, so that the services, escrows and other agents it deals with can run the same circuit over a request and see for themselves what the agent is allowed to spend, instead of taking the agent's or its wallet operator's word for it.

## Abstract

This TAP specifies a **policy circuit**: a `tapnet/1` netlist of at most 49,152 bytes with 128 input pins and 8 output pins. The inputs carry one **request word**, a canonical encoding of a spend request (amount in policy-declared units with saturation and an overflow flag, an asset class, a counterparty class, a request kind, the UTC day, hour and weekday); the outputs carry one `allow` bit and a 7-bit reason code, and anything other than exactly `allow = 1, reason = 0` denies. A combinational policy answers one request; a policy with latches keeps state across the ordered requests one gatekeeper presents to it, so that daily limits and counters are circuits too. A **binding** is an EIP-712 statement in the TAP-11 domain, `PolicyBinding(netlistHash, subjectKind, subject, tablesHash, notBefore, expires, issued)`, signed by the party that the subject kind names (the holder of a mandate's principal, the consumer of an escrow channel, the holder of the circuit whose container is the account, never the account itself), that ties the policy and its class tables to a mandate hash, an escrow session, an account or a display label. The TAP fixes the pin convention, the request word, the tables, the binding and its revocation, the ordered checks a counterparty runs (re-evaluating off chain with the TAP-02 reference evaluator, or on chain through the `evalFile` / `stepFile` calls of the netlist-NFT draft when the policy is small), the two `tap.policy` metadata members, and what a gate does not prove: it constrains only the parties that check it, and the wallet that signs may ignore it.

## Motivation

An agent that spends for someone works under several limits at once: the limits its wallet operator keeps in a back end (per-day amounts by category, confirmation prompts), the limits its principal signs in a mandate, and the limits an escrow channel enforces by its balance. The first kind is invisible to everyone but the operator and the user: a service that is asked to serve first and settle later cannot read it, cannot confirm it exists, and cannot tell whether a particular request is inside it. The second kind is a record that enforces nothing by itself. The third kind is a hard ceiling but says nothing about *which* requests inside that ceiling are intended. A counterparty that wants to know "is this agent allowed to pay me this much, for this, now?" has today no object it can check.

Several Ethereum proposals and products draw a box around an agent: ERC-8196 (Final) registers, in a wallet contract that implements its interface, a policy of fixed fields (allowed actions, allowed and blocked contracts, a value per transaction and an optional value per day, a validity window, a minimum verification score) and names on-chain errors for violations; ERC-7710 delegations are redeemed through a manager whose caveats the text leaves to implementations; ERC-7715 is a request protocol between a dapp and a wallet with an opaque context; ERC-8354 proves in zero knowledge that a *private* ruleset allowed an action; ERC-8226 and ERC-8312 (proposed) define a mandate record and a spent-amount cursor; Coinbase's spend permissions and Safe's allowance module are numeric boxes kept by a module, and a custodial wallet's limits are settings in its provider's back end. In every one of them the policy is either a fixed schema of numbers, an opaque context, a private ruleset, or a back-end setting. None gives a counterparty a public, byte-exact description of the rule that it can re-run over a concrete request and that a dispute can be about.

The TapeOut family already has the right object for that: a netlist-bound token fixes a circuit byte for byte, its hash is defined, any contract on the token's chain can run it through the Eval extension, and anyone can run it off chain with the TAP-02 reference evaluator. What is missing is the convention: which pins mean what, how a spend request becomes input bits, who says that *this* circuit constrains *that* mandate or session, how long, and how a counterparty checks it. That is all this TAP adds.

**What this adds that ERC-8196 and its neighbours do not**, stated precisely:

1. The policy is an arbitrary boolean or sequential function, fixed as bytes with a defined hash, not a fixed schema of fields. A per-asset limit, an hour-of-day window, or any conjunction of rules is one file here; ERC-8196's schema fixes a contract allow-list and block-list, a per-transaction and an optional per-day value and a validity window.
2. The decision is recomputable by anyone from the hash alone. ERC-8196 does not define how its `policyHash` is derived, and `getPolicy` returns a subset of the fields; ERC-7715's `context` is opaque; ERC-8354's ruleset is private by design.
3. It defines no wallet and no account. A gate binds the *counterparty's* check, and can sit in an escrow-side vault, in a service's admission logic, in a job hook or in a delegation caveat, without the wallet taking part.

**And what it lacks**, with the same precision: ERC-8196 places the policy in the wallet contract and names on-chain errors for violations. This TAP enforces nothing that the checking party does not enforce. A custodial wallet whose policy lives in its provider's back end signs without consulting any on-chain rule; whether a particular wallet consults a policy circuit is not documented by this TAP and not claimed by it, and no text in this TAP changes that. A policy circuit gate is therefore a **counterparty-verifiable** limit, enforced only by the parties that check it: it protects the service or escrow that checks it, and it lets the principal show what it intended; it is not a signing guard, and it is not described as one.

**Target users.** Services and escrows that want to accept an agent's request only when a published rule allows it; principals who want the rule they gave an agent to be checkable by third parties and not only by themselves; and dispute or audit tools that need a decision they can replay. An agent whose counterparties do not check does not need this TAP.

**Vocabulary.** This text uses *limit*, *allow* and *deny*. It defines no asset, no fee and no return, and the amounts in a request word are the amounts of the requests the policy judges, nothing more.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 0. Status, preconditions and scope

#### 0.1 Texts this TAP builds on

| # | Text | Status on 2026-10-24 | How this TAP uses it |
|---|---|---|---|
| G-1 | TAPs pull request [#67](https://github.com/TapeOutProtocol/TAPs/pull/67), *Netlist-Bound NFTs*, at commit `3af6799008b6058ef7bf2aa20636e76be61af524` (**the netlist-NFT draft**) | Open | Its `tapnet/1` file (§2.1 there), its netlist hash `SHA-256(file)` (§2.3 there), the 49,152-byte bound its L1 contracts' `storeNetlist` accepts (§8.2 there) and the `ITapNetlistEval` functions `evalFile(bytes32,bytes)` and `stepFile(bytes32,bytes,bytes)` (§8.4 there) are **inlined** in §2 and §4.3 of this text, which is their normative source for this TAP; a revision of this TAP, not the merge of that draft, would point there instead |
| G-2 | TAP-02 | Draft, merged | Well-formedness, one beat, bit packing (§3, §4, §5 there); the reference evaluator |
| G-3 | TAP-11 | Draft, merged | The EIP-712 domain of §4.1 there, the holder check of §4.4 there, canonical JSON of §6 there |
| G-4 | Pull request [#47](https://github.com/TapeOutProtocol/TAPs/pull/47), mandates phase 0, at commit `50a5a6f92abfefb3cdde4af2c86a9b18c087a3d6` (**the mandate draft**) | Open | Conditional only (§5.1 row 1, §8.1): the subject kind `mandate` names mandates of that draft at the commit given; nothing else here depends on it |
| G-5 | Pull requests [#59](https://github.com/TapeOutProtocol/TAPs/pull/59) (escrow channels, commit `098de456152615d7c289c650a8a50533ccf53df1`) and [#60](https://github.com/TapeOutProtocol/TAPs/pull/60) (mandates phase 1, commit `42ce7aef2d16ef64c3d8ba94e255076c3db16a25`) (**the escrow drafts**) | Open; the escrow contract is not audited and not deployed | Conditional only (§5.1 row 2, §4.2 item 4, §8.2): the subject kind `escrow-session` and the cumulative-voucher rule name channels of that interface at the commits given |

In this version a verifier MUST NOT report a binding of subject kind 1 or 2 as `enforceable: true`; a binding of those kinds that passes every check of §5.3 is reported as `conditional`. A revision of this TAP, not the merge of another text, changes that; a verifier's answer never depends on which drafts it believes are merged. This TAP does not require any of G-4 and G-5 and names none of them in `requires`.

#### 0.2 Scope and non-claims

1. This TAP defines a policy circuit, a request word, a binding, its revocation, the checks a counterparty runs and two metadata members. It defines no wallet, no account, no escrow, no token and no contract of its own.
2. A gate constrains only the parties that check it. Whether a wallet, a module or a back end consults a policy circuit before signing is outside this TAP; a text that claims to follow this TAP MUST NOT describe a binding as a guarantee that the agent cannot spend outside the policy.
3. A policy judges one request word at a time. It does not see balances, prices, past requests other gatekeepers saw, or anything not in the word (§3.3) and its own state (§2.4).
4. A policy's state belongs to one gatekeeper (§4.2). A daily limit enforced by one escrow-side vault counts the requests that vault saw, not the agent's requests everywhere.

### 1. Terms and notation

- **Policy circuit** (or **policy**): a valid `tapnet/1` file that meets §2.2. **Netlist hash**: `SHA-256(file)`, written `0x` + 64 lowercase hex digits. **Combinational** policy: one without LATCH records; **stateful**: one with at least one.
- **Request**: the object of §3.2 (amount, asset, counterparty, kind, time). **Request word**: its 128-bit encoding of §3.3. **Tables**: the object of §3.1 that maps assets and counterparties to classes and fixes the amount unit.
- **Verdict**: `allow` or `deny`, with a **reason code** 0–127 (§2.3, §2.5).
- **Gatekeeper**: the party that presents requests to a policy and acts on the verdict: a contract (an escrow-side vault, a job hook, a caveat enforcer), a service deciding whether to serve, or a tool. **Trace**: the ordered list of the requests one gatekeeper presented under one binding (§4.2).
- **Binding**: a signed `PolicyBinding` (§5.2). **Binder**: the account the subject kind requires as its signer (§5.1). **Subject**: what the binding constrains, named by `subjectKind` and a 32-byte `subject` value. **Binding hash**: the binding's EIP-712 digest, its identity.
- **Principal**, **holder**, **mandate**, **mandate hash**: as in the mandate draft when it applies (§0.1 G-4). **Consumer**, **provider**, **channel**, **session key**, **voucher**, **cumulative**: as in the escrow drafts when they apply (G-5).
- `u32be`, `ceil`, `‖`: big-endian 32-bit integer, rounding up, byte concatenation. `keccak256` is Ethereum's; `canonicalJSON` is TAP-11 §6. Bit `i` of a packed byte string is bit `i mod 8` of byte `floor(i / 8)` (TAP-02 §5). `now` is the verifier's Unix time in seconds.

### 2. Policy circuits

#### 2.1 File

A policy is a `tapnet/1` file as the netlist-NFT draft defines it (inlined): bytes 0–5 ASCII `TAPNET`, byte 6 `0x01`, byte 7 `0x00`, bytes 8–11 `nIn` (`u32be`), bytes 12–15 `nOut` (`u32be`), then TAP-02 records, each a NAND (`0x00`, two 3-byte signal indices) or a LATCH (`0x01`, one 3-byte index); no REF record; the records with `nIn` and `nOut` well-formed under TAP-02 §3. The netlist hash is `SHA-256` of the whole file. A valid file is exactly `16 + 7·nand + 4·latch` bytes long.

#### 2.2 Validity

A file is a policy circuit under this TAP if and only if:

1. it is a valid `tapnet/1` file (§2.1);
2. `nIn = 128` and `nOut = 8`;
3. it is at most 49,152 bytes long (`MAX_POLICY_BYTES`, the size an L1 netlist-NFT contract's `storeNetlist` accepts).

A tool MUST reject a file that fails any item, reporting `policy-invalid-file`, `policy-bad-pins` or `policy-too-large`, and MUST NOT evaluate it. When a binding or a metadata member states whether the policy is stateful (§6.1), the statement MUST equal "the file has at least one LATCH record" (`policy-stateful-mismatch`). A file is identified by its netlist hash only; a tool MUST NOT accept a file whose hash differs from the one a binding names (`policy-hash-mismatch`), whatever the file computes.

#### 2.3 Result

The 8 output bits, packed as one byte `b` (TAP-02 §5): bit 0 is `allow`; bits 1–7, read as the integer `b >> 1`, are the **reason code**.

| `b` | Verdict |
|---|---|
| `0x01` | `allow`, reason 0 |
| bit 0 clear | `deny`, with the reason code |
| bit 0 set and reason ≠ 0 | **invalid result**: a gatekeeper MUST treat it as `deny` and a tool MUST report it as `invalid-result` with the code |

A gatekeeper MUST act on exactly `0x01` as an allowance and on every other value as a denial. A policy author SHOULD give every denial a non-zero reason; reason 0 with `allow = 0` is a denial without a stated reason.

#### 2.4 State

A combinational policy is evaluated as one beat of TAP-02 §4 with no state: this is `eval` of TAP-02 and `evalFile` of §4.3. A stateful policy is evaluated as one beat with a state of `latch` bits, packed in `ceil(latch / 8)` bytes; the beat returns the new state. The state at the start of a trace is all zeros. The gatekeeper advances the state by exactly one beat for every request it presents, in the order it presents them, whether the verdict was `allow` or `deny`; the policy itself decides what it remembers (the examples of §9 keep their state unchanged on a denial). A tool MUST NOT skip a denied request when replaying a trace.

#### 2.5 Reason codes

| Code | Name | Meaning |
|---|---|---|
| 0 | `none` | with `allow = 1`: allowed; with `allow = 0`: denied without a stated reason |
| 1 | `amount-over-limit` | the amount exceeds a per-request limit |
| 2 | `period-limit-reached` | allowing this request would exceed a limit over a period (a stateful policy) |
| 3 | `counterparty-not-allowed` | the counterparty class is not allowed |
| 4 | `asset-not-allowed` | the asset class is not allowed |
| 5 | `outside-time-window` | the day or hour is outside the policy's window |
| 6 | `amount-overflow` | the overflow bit is set (§3.3) |
| 7 | `kind-not-allowed` | the request kind is not allowed |
| 8–63 | reserved | a tool displays `reserved` |
| 64–127 | policy-defined | named, if at all, by `tap.policy.reasons` of the policy token (§6.1); a tool displays `policy-defined` |

A policy MAY use any code; a tool MUST display the codes of this table by name and MUST NOT refuse a verdict because of its code.

#### 2.6 Size and cost (informative)

The five example policies of §9 are 135 to 5,076 bytes (17 to 737 gates). The netlist-NFT draft measured its Solidity evaluator at about 290 gas per gate for a 1,204-gate file; at that rate a 1,000-gate policy costs about 0.3 million gas per request on chain. No evaluator was measured for this TAP.

### 3. Requests and the request word

#### 3.1 Tables

The tables of a binding are a JSON object with exactly the members:

| Member | Form | Meaning |
|---|---|---|
| `amountUnit` | decimal string, an integer in `[1, 2^256)` | base units of the asset per amount unit |
| `assets` | object: lowercase `0x` + 40 hex address → integer class in `[1, 255]` | the asset classes; an address not listed is class 0 |
| `counterparties` | object: the same form | the counterparty classes; an address not listed is class 0 |

`tablesHash = keccak256(utf8(canonicalJSON(tables)))`. A tool MUST reject tables of another form (`tables-malformed`): a checksummed or uppercase address, class 0 or above 255, a unit of 0, a member not listed, a non-integer. Class 0 is reserved for "not listed" and cannot be assigned.

#### 3.2 Request

A request is a JSON object with exactly the members `amount` (decimal string or integer, in `[0, 2^256)`, in base units of `asset`), `asset` (lowercase address), `counterparty` (lowercase address), `kind` (integer in `[0, 7]`, §3.4) and `ts` (Unix time in seconds, integer in `[0, 2^64)`). A tool MUST reject any other form (`request-malformed`). `ts` is the time the gatekeeper assigns to the request: `block.timestamp` for a contract, the time it received the request for a service, and the time recorded in the trace for a replay (§4.2).

#### 3.3 Request word

The request word is 128 bits, bit `i` of the word being input `i` of the policy (signal `2 + i` in TAP-02 numbering), packed into 16 bytes as TAP-02 §5:

| Bits | Width | Field | Value |
|---|---|---|---|
| 0–31 | 32 | `amount` | `u = ceil(amount / amountUnit)`; if `u < 2^32`, `u`; otherwise `2^32 − 1` |
| 32 | 1 | `overflow` | 1 if `u ≥ 2^32`, else 0 |
| 33–39 | 7 | reserved | 0 |
| 40–47 | 8 | `asset` | `assets[asset]`, or 0 if not listed |
| 48–55 | 8 | `counterparty` | `counterparties[counterparty]`, or 0 if not listed |
| 56–58 | 3 | `kind` | the request kind |
| 59–63 | 5 | reserved | 0 |
| 64–79 | 16 | `day` | `floor(ts / 86400) mod 65536` |
| 80–84 | 5 | `hour` | `floor(ts / 3600) mod 24` (UTC) |
| 85–87 | 3 | `weekday` | `(floor(ts / 86400) + 3) mod 7`; Monday is 0, Sunday is 6 |
| 88–127 | 40 | reserved | 0 |

An encoder MUST produce reserved bits as 0, and a tool that is handed a word rather than a request MUST reject one with a reserved bit set (`word-reserved-bits`). Amounts round **up**: a request of one base unit above a whole number of units is encoded as the next unit, so a policy never under-counts. A verifier MUST recompute the word from the request and the tables and MUST NOT trust a word it received. The example request `{ amount 10^15, asset of class 1, counterparty of class 1, kind 1, ts 1793008800 }` (Monday 2026-10-26 10:00:00 UTC) with `amountUnit = 10^15` encodes to ``0x010000000001010110510a0000000000``.

#### 3.4 Request kinds

| `kind` | Name | Meaning |
|---|---|---|
| 0 | `other` | a request of a kind not listed |
| 1 | `pay` | a payment to the counterparty (settling a voucher, paying for a call) |
| 2 | `fund` | a deposit into a channel or vault toward the counterparty |
| 3 | `call` | a service call without a payment in this request |
| 4 | `transfer` | a plain token transfer to the counterparty |
| 5–7 | reserved | a policy SHOULD deny them |

The gatekeeper chooses the kind from what it is about to do; a tool replaying a trace uses the recorded kind.

### 4. Evaluation

#### 4.1 One request

To evaluate a request `r` under a binding with policy `p` and tables `t`: build `w = word(r, t)` (§3.3); for a combinational `p`, run one beat with inputs `w` and no state and read the result (§2.3); for a stateful `p`, run one beat with inputs `w` and the gatekeeper's current state for that binding, read the result and store the new state. The result MUST equal that of the TAP-02 reference evaluator for every word and state. The reference implementation's `evaluate` does exactly this.

#### 4.2 Gatekeepers and traces

1. A gatekeeper keeps, per binding hash, the state of a stateful policy and a trace: the ordered requests it presented, each with its `ts`, and the verdicts it acted on. For a combinational policy the state is empty and the trace is kept for audit only.
2. `ts` values in a trace MUST be non-decreasing (`trace-not-monotone`) and inside `[notBefore, expires]` of the binding (`trace-before-binding`, `trace-after-binding`). A contract gatekeeper satisfies the first by construction.
3. A party that re-verifies replays the trace from the all-zero state with §4.1, request by request, and compares each computed verdict with the recorded one (`trace-mismatch`). The reference implementation's `replay` does this and returns the final state.
4. **Escrow channels (conditional, G-5).** When the subject is an escrow session, a trace entry carries the voucher's `cumulative` instead of an amount, and the request's amount is `cumulative − c`, where `c` is the `cumulative` of the last entry whose verdict was `allow` (0 before any). A `cumulative` below that `c` is `trace-cumulative-decreases` (a voucher that was denied was never settled, so a later one may state less than it did); an entry that carries both is `trace-malformed`. The gatekeeper is then the party that decides whether to settle or accept the voucher: a vault that wraps the escrow, or the provider. A voucher the gatekeeper denied can still be settled by anyone, since the escrow does not read the gate; the gate's `c` then lags the channel's claimed amount, which overstates the next delta and errs toward denial.
5. A trace is the gatekeeper's. A verifier MUST NOT combine traces of different gatekeepers into one state, and MUST NOT present a per-period limit as covering requests the gatekeeper did not see.

#### 4.3 On-chain call convention

A contract that acts as a gatekeeper on the chain where the policy file is stored by a netlist-NFT contract `E` that implements the Eval extension (inlined from the netlist-NFT draft §8.4: `evalFile(bytes32 netlistHash, bytes inputs) view returns (bytes outputs)`, selector `0xf822bb64`; `stepFile(bytes32 netlistHash, bytes state, bytes inputs) view returns (bytes newState, bytes outputs)`, selector `0x4b3ab3d4`; ERC-165 identifier of the extension `0xec7d7e20`):

1. MUST build the 16-byte word of §3.3 from the request it is about to act on, with `ts = block.timestamp`;
2. for a combinational policy MUST call `E.evalFile(netlistHash, word)`; for a stateful policy MUST call `E.stepFile(netlistHash, state, word)` with the state it stores for the binding hash and MUST store `newState` before acting;
3. MUST read the first byte of `outputs` as §2.3 and act on `0x01` only;
4. MUST treat a revert of `E` (file not stored, LATCH in `evalFile`) as a denial;
5. SHOULD check, when the binding is given to it, that `E.supportsInterface(0xec7d7e20)` is true and that the binding passed §5.3 at the time it was installed, and SHOULD record the binding hash it enforces so that anyone can read which policy it runs.

Such a contract is a gatekeeper of this TAP, not a wallet. Its interface, its installation and how it learns the binding are outside this TAP (Open questions).

#### 4.4 Off-chain verification by a counterparty

A counterparty handed a binding, its signature, its tables and the policy file (or the file fetched by the netlist hash) checks, in this order, and stops at the first failure: (1) §5.2 form; (2) §5.3 items 1–8, with the policy file at hand (without it, it denies: §7); (3) for the request at hand, §4.1, with its own state for the binding if the policy is stateful. It serves, settles or accepts only on `allow`. It MAY cache the file by its hash for ever and MUST re-run §5.3 items 6–8 (time and revocation) before every decision.

### 5. Bindings

#### 5.1 Subjects and binders

| `subjectKind` | Name | `subject` (32 bytes) | Binder (the required signer) | Enforceable |
|---|---|---|---|---|
| 1 | `mandate` | the mandate hash (the digest of the mandate draft §3.1), when G-4 applies | the current holder of the mandate's principal (mandate draft §4), checked as TAP-11 §4.4 | `conditional` (fixed in this version, §0.1) |
| 2 | `escrow-session` | `keccak256(escrow ‖ consumer ‖ provider ‖ key)` over the four 20-byte addresses, when G-5 applies | the channel's consumer; when the consumer is a contract, its holder under TAP-11 §4.4 | `conditional` (fixed in this version, §0.1) |
| 3 | `account` | the address of an account that is the container of a TapeOut circuit (as TAP-11 §1 uses the term), left-padded with 12 zero bytes | the current holder of that circuit, checked as TAP-11 §4.4; never the account itself | yes |
| 4 | `label` | `keccak256(utf8(label))` | any account; recorded for display | never: display only, binds nobody; a tool MUST NOT report enforcement for it |

A tool MUST reject a `subjectKind` not in this table (`binding-unknown-subject-kind`) and an `account` subject that is not padded as stated (`binding-malformed`).

A binding of kind 3 is the circuit holder's statement about the requests its container may make. The subject account, and any key that acts for it (an agent's hot wallet, a session key, an operator), is never the binder of a binding about that account. A verifier MUST report `binding-self-signed` when the recovered signer of a kind-3 binding is the subject account, whatever binder it was given; such a binding is never enforceable. An account that is not the container of a circuit has no binder under this version.

A runtime whose inputs include text from parties other than the binder (web pages, messages, tool results, files it did not write) MUST NOT sign a `PolicyBinding` or a `PolicyBindingRevocation`; bindings and revocations are signed with the binder's own key or console.

A tool that shows a `label` binding MUST show the words "display only, binds nobody" next to it and MUST NOT present it as a limit that any party enforces.

#### 5.2 The `PolicyBinding` type

```
PolicyBinding(bytes32 netlistHash,uint8 subjectKind,bytes32 subject,bytes32 tablesHash,uint64 notBefore,uint64 expires,uint64 issued)
BINDING_TYPEHASH = 0x9965afb004b518a9dc796972c26561bf05b7a2ed59a730e38276c10dd8b0a468
```

The domain is that of TAP-11 §4.1, unchanged: `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)` with `name` `"TapeAPI"`, `version` `"1"`, `verifyingContract` the hub `0xe61A9C7213a6Aa616C246a2B569e555B417b25ee` and `chainId` the chain of the subject: the principal's chain for a mandate, the escrow's chain for a session, the chain of the circuit for an account, the chain the signer names for a label. On BNB Smart Chain (56) the domain separator is `0xa73ee348b5672f12dbc174f66a7d162c69e0d64befdba88475d9d7e3c0fd3ac7`. The **binding hash** is `keccak256(0x19 ‖ 0x01 ‖ DOMAIN_SEPARATOR ‖ hashStruct(PolicyBinding, b))`; the same binding on another chain has another hash. A chain without the hub at that address is handled as TAP-11 §4.1 says.

Static rules, checked without the chain; a failure stops the check with the problem named:

| # | Rule | Problem |
|---|---|---|
| 1 | Exactly the seven members; `bytes32` values `0x` + 64 lowercase hex digits; integers in range | `binding-malformed` |
| 2 | `netlistHash` and `subject` are non-zero | `binding-malformed` |
| 3 | `subjectKind` is 1–4; an `account` subject is padded | `binding-unknown-subject-kind`, `binding-malformed` |
| 4 | `expires > notBefore` | `binding-window-empty` |
| 5 | `issued ≤ expires` | `binding-issued-after-expiry` |

The JSON form of a binding has the member names of the type, `bytes32` values as hex strings and integers as JSON numbers when below 2^53, otherwise decimal strings (TAP-11 §6).

A tool that prepares a binding for a binder MUST NOT propose by default a window (`expires − notBefore`) longer than 2,592,000 seconds (30 days), and SHOULD propose at most 604,800 seconds (7 days). A longer window is the binder's own choice; this TAP sets no upper bound beyond §8.1 and §8.2.

#### 5.3 Checks

After §5.2, a verifier checks and reports, in this order, every problem that applies:

| # | Check | Problem |
|---|---|---|
| 1 | `sig` present | `binding-unsigned` |
| 2 | `sig` recovers under TAP-11 §4.4 item 1 (65 bytes, low `s`, `v` in {27, 28} after mapping 0 and 1) to a signer; EIP-1271 under item 2 when the binder is a contract | `signature-bad-signature-length`, `signature-bad-v`, `signature-bad-r-s`, `signature-high-s` |
| 3 | for kind 3, the signer is not the subject account; the signer is the binder of §5.1, when the verifier knows it | `binding-self-signed`, `not-signed-by-binder` |
| 4 | `tablesHash` equals the hash of the tables handed over, and the tables are well-formed | `tables-hash-mismatch`, `tables-malformed` |
| 5 | when the policy file is at hand: it passes §2.2 and its hash is `netlistHash` | `policy-invalid-file`, `policy-bad-pins`, `policy-too-large`, `policy-stateful-mismatch`, `policy-hash-mismatch` |
| 6 | `notBefore ≤ now` | `binding-not-yet` |
| 7 | `now ≤ expires` | `binding-expired` |
| 8 | no revocation signed by the signer covers it (§5.4) | `binding-revoked` |

The result names the binding hash, the signer, the subject kind, the problems, whether the binder and the file were checked, whether the binding is display only (kind 4), and `enforceable`, decided in this order: false for kind 4; absent when the binder was not checked; false when there is any problem or when the policy file was not at hand and checked under item 5; `conditional` for kinds 1 and 2 (§0.1); true for kind 3. A binding checked without the policy file is not a checked policy: the verifier MUST say that the file was not checked and MUST NOT report `enforceable` as true or `conditional` (no file, no verdict: §7). A verifier that does not know the binder (item 3 skipped) MUST say so and MUST NOT report `enforceable`.

#### 5.4 Revocation and supersession

```
PolicyBindingRevocation(bytes32[] bindingHashes,uint64 revokedBefore,uint64 issued)
REVOCATION_TYPEHASH = 0x59612c001eea9fe0adaf57e3ba597d8896c9bdea0c6d95e1e6f081e9e521f8f9
```

Same domain; `bindingHashes` lists at most 24 non-zero hashes (`MAX_REVOKED_HASHES`, `revocation-too-many-hashes`); a `bytes32[]` member is encoded as `keccak256(e₀ ‖ e₁ ‖ …)`, the empty array as `keccak256("")`. A revocation **covers** a binding when the binding's hash is listed or the binding's `issued` is strictly below `revokedBefore` (a binding issued at `revokedBefore` is not covered; `revokedBefore` 0 means no time cut-off), and it applies only to bindings whose signer is the revocation's signer. A revocation has no expiry. Carriage is not restricted; a verifier applies every revocation it has seen.

A binder changes a policy by issuing a new binding for the same subject with a later `issued` and, if the old one should stop at once, a revocation of it. Two unrevoked bindings of the same signer and subject that are both in their window: a gatekeeper applies the one with the greater `issued`; equal `issued` with different hashes is `binding-ambiguous` and neither is applied. A policy file never changes: a different rule is a different hash, a different token and a different binding.

#### 5.5 What a passing binding means

A binding that passes §5.3 with the file at hand means exactly: the binder stated, at `issued`, that for this subject and these tables the circuit with this hash is the rule, between `notBefore` and `expires`. It does not mean that any party enforces it, that the agent's wallet consults it, that the agent cannot spend outside it elsewhere, or that the rule is a good one. A tool MUST NOT present a binding as a bound on what an agent can spend; it MAY present it as the bound the gatekeeper that checks it enforces.

### 6. Metadata members

#### 6.1 `tap.policy` on the policy token

A netlist-NFT token whose netlist is meant as a policy circuit carries, in the `tap` member of its metadata, `policy`:

| Member | Form | Meaning |
|---|---|---|
| `convention` | `"tap-policy/1"` exactly | the pin convention of this TAP |
| `stateful` | boolean | equals "the file has a LATCH record" |
| `reasons` | object, optional: decimal code `"64"`–`"127"` → text of 1–64 UTF-8 bytes | names of the policy-defined reason codes |

A tool MUST report `policy-member-missing`, `policy-member-malformed`, `policy-unknown-convention` (another string, including another case) or `policy-stateful-mismatch`, and, when `tap.netlist` carries `nIn`, `nOut` or `latch`, `policy-bad-pins` or `policy-stateful-mismatch` on a contradiction. The member does not change the netlist hash or the token; a token without it can still be named by a binding, and a token with it is not a binding.

#### 6.2 `tap.policy` in a subject record

A record that describes the subject (a task object of the mandate draft, a TAP-11 manifest, an agent's registration file, a message to a counterparty) MAY carry `tap.policy` with exactly: `chainId` (the domain's chain), `binding` (the JSON form of §5.2), `sig` (`0x` + 130 hex digits), `tables` (§3.1), and optionally `policy` `{ chainId, contract, tokenId }` naming the token that stores the file. The form is checked as `policy-member-malformed` plus the problems of §3.1 and §5.2. Carrying the member is not a verification: the reader runs §5.3.

### 7. Failure modes

| Situation | What a tool reports | What a gatekeeper does |
|---|---|---|
| File not obtainable | `policy-file-unavailable`; the file is not checked and `enforceable` is neither true nor `conditional` (§5.3) | denies (no file, no verdict) |
| File obtained but hash differs | `policy-hash-mismatch` | denies |
| File invalid or wrong pins | `policy-invalid-file`, `policy-bad-pins`, `policy-too-large` | denies |
| Binding expired, not yet, revoked, unsigned, wrong signer | the problem of §5.3 | denies |
| Tables changed after signing | `tables-hash-mismatch` | denies |
| Policy returns an invalid result | `invalid-result` with the code | denies |
| Evaluator reverts on chain | — | denies |
| Stateful policy, gatekeeper lost its state | `trace-unavailable` | MUST NOT restart from zero silently: it either refuses or records that the trace restarted at a stated `ts` |
| Two live bindings, same subject and signer | the later `issued` wins; equal: `binding-ambiguous` | applies the later; on a tie, denies |
| Policy denies everything by mistake | nothing: the file is what it is | denies until the binder issues a new binding |

A gatekeeper MUST fail closed in every row. A tool MUST NOT turn an unavailable read into a verdict.

### 8. Relationship to other limits (conditional)

#### 8.1 Mandates (G-4)

When the mandate draft applies, a binding of kind 1 names a mandate by its hash; the mandate's signed type is unchanged, and a mandate without a binding is verified as that draft says. The binder is the mandate's principal's current holder. A verifier that has read the mandate MUST report `binding-outlives-subject` when `[notBefore, expires]` of the binding is not inside the mandate's window. A verifier that reports a mandate SHOULD show its binding, if it was given one, as a separate line: the mandate says who may act and on what, the policy says which requests a gatekeeper allows; neither replaces the other.

#### 8.2 Escrow channels (G-5)

When the escrow drafts apply, a binding of kind 2 names one channel and one session key; the escrow contract is unchanged and does not read the binding. The gatekeeper is a vault that wraps the escrow or the provider that accepts vouchers; the escrow's balance remains the ceiling whether or not anyone checks the policy, and the policy is a finer rule inside that ceiling for the parties that check it. The amount of a request is the cumulative delta of §4.2 item 4. A verifier that has read the session's expiry at the pinned block MUST report `binding-outlives-subject` when the binding's `expires` is later.

#### 8.3 Other hosts (informative)

A gatekeeper contract of §4.3 can be the body of an ERC-8183 job hook, of an ERC-7710 caveat, or of an ERC-7579 hook; this TAP defines none of those adapters and depends on none of them.

### 9. Example policies (informative)

Built by `examples.py` of the reference folder; files under `policies/`, hashes in `vectors.json`.

| Name | Stateful | Bytes | Gates | Rule |
|---|---|---|---|---|
| `daily-cap` | yes (33 latches) | 5,076 | 737 | `pay` only; at most 500 units per request; at most 2,000 units per UTC day; state: 16-bit accumulator, 16-bit day, one `seen` bit; a denial leaves the state unchanged |
| `allowlist` | no | 1,584 | 224 | `pay` only; counterparty class 1 or 2; asset class 1; at most 1,000 units |
| `time-window` | no | 653 | 91 | `pay` or `call`; 09:00 ≤ UTC hour < 17:00; Monday to Friday; no amount limit |
| `deny-all` | no | 135 | 17 | denies everything, reason 7 |
| `per-asset-limits` | no | 2,340 | 332 | `pay` only; asset class 1 at most 1,000 units, class 2 at most 50; other assets denied |

The day field is 16 bits, so `daily-cap` sees two requests exactly 65,536 days apart as the same day; the vectors record this (it errs toward denial).

## Rationale

**A netlist, not a schema or a rules language.** A schema of numeric fields (ERC-8196, ERC-8226, spend permissions) is easy to display but fixes the shape of every rule in advance; a rules language needs an interpreter that every verifier has to agree on. A `tapnet/1` file is already both: TAP-02 fixes its meaning bit for bit, the reference evaluator and the on-chain evaluator agree by test, and a verifiable-execution game can be about it. The cost is that a policy is written as gates; the builder in the reference folder shows that the common rules are a few hundred gates.

**A fixed 128-bit word.** Policies and gatekeepers can only interoperate if the pins mean the same thing everywhere; the word is the whole interface. 128 bits leave 52 reserved for a later version without changing `nIn`. Amounts are 32 bits of policy-declared units rather than a 256-bit base-unit value because a 256-bit comparator per rule would dominate every policy and because a unit is what a human means by a limit; saturation plus an overflow bit lets a policy deny what it cannot count.

**Rounding up.** A request one base unit above a whole number of units counts as the next unit. Rounding down would let a request slip under a limit by a fraction of a unit.

**A day index in the word rather than a "new period" bit.** An earlier design had the encoder set a bit when the request's day differed from the previous request's. That makes the encoder stateful and the canonical encoding of a request dependent on the trace. Carrying the day index keeps the encoder a pure function of the request and the tables; the circuit remembers the day itself, at the cost of sixteen latches.

**Fail closed, one allowed value.** A gatekeeper that acts on "bit 0 set" would be fooled by an output byte with other bits set by mistake; a policy author who forgets a reason would allow by accident if `allow` were the inverse of "any reason". Exactly `0x01` allows.

**Who holds the state.** `stepFile` is a view and stores nothing; a stateful policy therefore belongs to a gatekeeper that stores state and keeps a trace. This is a limit of the design and the text says so rather than pretending that a daily limit is global.

**Bindings in the TAP-11 domain.** The mandate draft signs in that domain; a holder's console that can sign a mandate can sign a binding with the same key and the same display, and the chain ID separates chains without a new domain. The binder table pins the signer per subject kind because a binding anyone could sign would bind no one. For an account the binder is the holder of the circuit behind it, never the account's own key: the key that would be limited, often an agent's hot wallet that reads untrusted text, could otherwise loosen its own limit.

**No wallet.** Defining the policy as something the wallet runs would duplicate ERC-8196 and would be untrue for custodial wallets, which do not run it. A gate is the counterparty's.

**Alternatives rejected.** (1) Zero-knowledge policy verdicts (ERC-8354): private rules, a proving system and a fixed interpreter; the opposite trade-off, kept as a reference, not a competitor. (2) Putting the policy hash into the mandate type: the mandate draft's types have no spare field and changing one invalidates every signature. (3) A JSON rule language: a second interpreter to standardise. (4) On-chain only: most counterparties are services, not contracts. (5) `nIn = 64`: no room for the day index without dropping fields. (6) A new EIP-712 domain: one more thing for consoles to display. (7) A `PolicyGate` contract interface in this text: an Application TAP does not define contract interfaces; the call convention is given instead and the interface is left open.

**Differentiation, in one table.**

| Text | Policy is | Who evaluates | Third party can recompute | What this TAP adds / lacks |
|---|---|---|---|---|
| ERC-8196 (Final) | fixed fields (`allowedActions`, `allowedContracts`, `blockedContracts`, `maxValuePerTx`, `maxValuePerDay`, `validAfter`, `validUntil`, `minVerificationScore`) | a wallet contract implementing its interface (the text names errors for violations; the only field whose enforcement the text requires is `minVerificationScore`) | no (`policyHash` derivation unspecified; `getPolicy` partial) | adds an arbitrary, hashed, replayable rule and a counterparty check; lacks a place in the wallet's execution path |
| ERC-7710 (Draft) | caveats, unspecified in the text | the delegation manager | no (permission context is implementation-defined) | a gatekeeper can be a caveat body; this TAP does not define that adapter |
| ERC-7715 (Draft) | permission types with opaque `context` | the wallet | no | a binding could be shown in a permission request; not defined here |
| ERC-8354 (Draft) | a private ruleset, ZK-proved | a domain operator proves, a guard verifies | no, by design | public replay instead of private proof; both disclaim that the rule is right |
| ERC-8226 / ERC-8312 (proposed) | a mandate record / a spent cursor | the token or the executor | the record, not a decision function | the decision function |
| Spend permissions, Safe allowance module, custodial wallets' limits | numbers in a module or a provider's back end | the module or the provider | no | a public rule beside them; they stay where they are |

## Backwards Compatibility

Nothing existing changes. A policy circuit is an ordinary `tapnet/1` file, so any netlist-NFT token with the right pins can be named by a binding, with or without `tap.policy`; a token without the member is simply not announced as a policy. The mandate draft's signed types, the escrow interface and TAP-11's domain are used unchanged; a mandate or a channel without a binding is handled exactly as those texts say. A verifier that does not implement this TAP ignores `tap.policy` members and sees no binding; it loses nothing those texts gave it. If the netlist-NFT draft changes the file format or the Eval signatures before merging, a revision of this TAP changes §2.1 and §4.3 to follow it.

## Test Cases

`assets/tap-draft-policy-circuit-gate/vectors.json` is generated by `make_vectors.py`, reproducible byte for byte (`--check`), with SHA-256 `6232d588ba3ebb8faae8498b2a2040f2d56f9dc2afe30980a585d3abd942c93e`; 163 cases. Its sections:

- `vendored`: SHA-256 of the four copied files;
- `constants`: the word layout, kinds, reason codes, the domain and its separator for chains 56, 97 and 31337, the two types and typehashes, the subject kinds;
- `policies`: the five examples with file paths, parameters, hashes, metrics, state sizes and (for files up to 2,048 bytes) their hex; `policyChecks`: rejected files, one per rule of §2.2 (wrong `nIn`, wrong `nOut`, too large, a REF record, a truncated header) and the stateful declaration both ways; `tooLargeGenerator`: how to rebuild the 49,716-byte file;
- `results`: eleven output bytes and their interpretation (§2.3);
- `encoding`: eighteen requests with fields, words and the word as an integer (rounding up, saturation, class 0, the kinds, epoch, a Saturday, a Monday, the day wrap); `encodingErrors` and `tablesErrors`: malformed requests and tables; `wordDecode`: reserved bits set; `tables`: the example tables, their canonical JSON and hash;
- `evaluations`: 29 single requests across the five policies, including reason priority and `evalFile` on a stateful policy;
- `traces`: fifteen traces: the daily limit filling and resetting at midnight, denials that do not consume, non-`pay` kinds, recorded verdicts agreeing and disagreeing, time going backwards, entries outside the window, escrow cumulative deltas, a decreasing cumulative, an empty trace and the 65,536-day wrap;
- `bindings`: 36 checks: a holder-signed mandate binding with the file (`conditional`) and without it (not enforceable), wrong key, unsigned, another chain's signature, the window at both ends, changed tables, another file, a wrong stateful declaration, revocation by hash, by time, of another binding and by another signer, an escrow-session binding by the consumer and by someone else, a revocation whose `revokedBefore` equals `issued` (not covered) and one with `revokedBefore` 0, an account binding by the circuit holder with and without the file, an account binding signed by the account itself (`binding-self-signed`, with and without a known binder), a label binding with and without binder and file (display only, never enforceable), and seven static failures; `bindingHashes`; `subjects`; `keys` (test keys);
- `revocations`: cover by hash, by time, `revokedBefore` equal to `issued` (not covering) and one above it (covering), `revokedBefore` 0, not covering, too many hashes, a zero hash;
- `tokenMetadata` and `subjectMetadata`: the two `tap.policy` members, valid and broken one rule at a time; `example`: the two documents in full.

## Reference Implementation

Python, standard library only: `assets/tap-draft-policy-circuit-gate/policy_gate.py` (checks, encoding, evaluation, replay, bindings, revocations, metadata, canonical JSON), `examples.py` (a NAND/LATCH builder and the five policies with Python oracles), `make_vectors.py`, `test_policy_gate.py` (20 tests: byte-for-byte regeneration, regeneration under `python3 -I` from another directory, vendored digests, 4,000 random requests per policy against its oracle with stateful sequences, an exhaustive time-window check, the fail-closed result table, EIP-712 round trips cross-checked against `eth_account` when installed, and that no binding vector reports `enforceable` without a checked file, for a label, or when an account signed its own binding), with `tapnft.py` and `tap02_reference.py` copied unchanged from the netlist-NFT draft's assets and `credits.py`, `canon.py` copied unchanged from the Soulbound Credentials draft (keccak-256 and secp256k1 only). The copied files' SHA-256 digests are in the folder's `README.md` and in `vectors.json`. EIP-1271 binders (§5.3 item 2), network reads (so the binder, for kind 3 the holder of the circuit, is passed in by the caller) and `binding-outlives-subject` (§8.1, §8.2, which needs the mandate or the session) are not implemented. The three scripts insert their own directory into `sys.path`, so they run under `python3 -I`. There is no Solidity gatekeeper and nothing was measured on a chain.

## Deployments

None. This TAP depends on no deployed contract. A gatekeeper contract of §4.3 would depend on a netlist-NFT deployment with the Eval extension, which does not exist at the time of writing.

## Security Considerations

- **The wallet may ignore the gate.** The central limit of this TAP, stated in §0.2 and §5.5: a binding constrains the parties that check it. An agent whose wallet signs without consulting the policy can spend outside it toward any counterparty that does not check. A principal who wants a hard bound uses an escrow balance or a wallet-side limit; the gate is the rule inside that bound for those who look.
- **Fail closed.** Every unavailable read, invalid file, malformed binding or revert is a denial (§7). A gatekeeper that defaults to allowing on error is not a gatekeeper of this TAP.
- **Tables are part of the policy.** The classes an address maps to decide the verdict; that is why `tablesHash` is signed and why a verifier recomputes it. A binder who lists a counterparty under the wrong class has signed that mistake.
- **Rounding and units.** A unit too coarse makes small requests count as a whole unit each; a unit too fine saturates early. Saturation sets `overflow`, and a policy that does not test it allows what it cannot count only if its author wrote it so. The examples deny on `overflow`.
- **State belongs to one gatekeeper.** An agent that spreads requests over several gatekeepers is limited per gatekeeper, not in total; a lost state cannot be rebuilt without the trace, and a gatekeeper that restarts from zero without saying so has widened the limit (§7).
- **Replay of the request, not of the word.** A verifier that accepts a word from the agent accepts whatever classes and amounts the agent wrote. §3.3 forbids it.
- **Time.** A contract uses `block.timestamp`; a service uses its own clock; a replay uses the recorded `ts`. A gatekeeper that back-dates entries can make a window or a day look different; the trace's monotonic `ts` and the binding window bound that, and a counterparty that keeps its own copy of the trace detects it. Day and hour are UTC; a policy written for a local day is wrong by the offset.
- **Day index wrap.** Sixteen bits of day index wrap every 65,536 days; the collision errs toward denial.
- **Binder impersonation.** A binding is only as good as its signer being the binder of §5.1. A verifier that skips item 3 of §5.3 has checked a signature, not an authority, and must say so.
- **Supersession races.** Two bindings with different `issued` for the same subject are ordered; a gatekeeper that installed the earlier one and is never shown the later one keeps enforcing the earlier. The binder revokes the earlier one when that matters.
- **Reason codes leak intent.** A denial with reason 3 tells the counterparty it is not on the list. A binder who does not want that uses reason 0.
- **Malicious files.** A policy comes from a binding, that is from the binder; still, a tool bounds the file (49,152 bytes) before parsing, checks record lengths first and never executes anything but NAND and LATCH (TAP-02 §7).
- **Cost on chain.** A gatekeeper contract pays per gate per request; a large policy can make a hook exceed a host's gas budget and turn every request into a denial. Authors keep policies small (§2.6).
- **Prompt injection.** For no subject kind is the agent's runtime, or the account a kind-3 binding limits, the binder (§5.1); a kind-3 binding recovered to the subject account is reported as `binding-self-signed` and is not enforceable, and a runtime that reads untrusted text is barred from signing bindings and revocations. Text shown to an agent therefore yields a binding a verifier accepts only if the binder's own key signs what the text asks.
- **Holder changes.** When the circuit behind an account, or a mandate's principal, changes hands, earlier bindings fail item 3 of §5.3 against the new holder, as TAP-11 delegations do; the new holder issues its own. Revocations by the old holder keep applying to the old holder's bindings only.
- **Labels mislead if shown as limits.** A `label` binding can be signed by anyone, including the agent; §5.1 makes a tool say "display only, binds nobody" beside it.

### Open questions

1. Whether a gatekeeper contract interface (`check` / `apply` keyed by binding hash) should be specified, and by which TAP type, given that an Application TAP does not define contract interfaces.
2. Whether a later version should add a second word (`nIn = 256`) for a 32-bit day index, a nonce or a price field, and how a policy declares which version it reads.
3. Whether bindings of kind 1 and 2 should be carried inside the mandate thread of the mandate draft, and under which message, once that draft is merged.
4. Whether a verifiable-execution game (#74) should be named as the dispute path for a contested verdict over a large policy, or whether re-evaluation by the counterparty is always enough at these sizes.
5. Whether `label` bindings should exist at all, or display be left to the subject record.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
