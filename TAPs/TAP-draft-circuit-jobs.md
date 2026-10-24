---
tap: TBD
title: "Circuit Jobs: Settling Agent Jobs by a Dispute Game"
description: An evaluator-and-hook contract that settles an escrowed agent job whose task is a deterministic circuit run by the on-chain state of a verifiable-execution claim, with no discretion and no custody.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/82
status: Draft
type: Application
created: 2026-10-24
requires: ERC-165, ERC-8183 (the deployed kernel implementation pinned in Specification 1.2)
license: CC0-1.0
---

# TAP-TBD: Circuit Jobs: Settling Agent Jobs by a Dispute Game

> **Conditional draft.** The kernel facts this text relies on were measured on a local fork of BNB Smart Chain at block 129,352,831 (Specification 0.1, table M); the kernel is upgradeable, so they hold for the implementation of that block and have to be re-measured before any deployment. The text also builds on a draft under review (pull request #74 of the TAPs repository) and on one property of a game's economics that this TAP cannot check (table P). Nothing here is a conformance claim about any deployed contract.

## Summary

This TAP lets an agent pay another agent for running a circuit, with the escrow released or refunded by what a dispute game on chain decided about the run, so that no person and no committee has to judge the result.

## Abstract

An escrowed agent job on the deployed Agentic Commerce kernel of BNB Smart Chain names one evaluator account that calls `complete` or `reject`. This TAP defines `TapCircuitEvaluator`, a contract that is both the evaluator and the hook of such a job and that has no discretion: the job's task is a deterministic run of a `tapnet/2` netlist, fixed as a *job spec* (`netlistHash2`, `inputRoot`, `T`, `K`, budget, expiry, input provider) that the client binds before funding; the provider's deliverable is a *claim* about that run in a verifiable-execution game (`TAP-draft-large-netlists` §7, a draft under review as pull request #74; table P); and the evaluator completes the job when the game reports the claim accepted, rejects it when the game reports the claim rejected, and does nothing otherwise. The TAP inlines the three game views it reads (`claimSummary` with a `windowEnd` field, `maxSettlementSeconds`, `inputProvider`), pins the kernel implementation and selectors it was written against, and fixes ten rules (J-1 to J-10): binding before funding with `evaluator == hook == this`, an expiry that covers the game's settlement bound plus an immutable margin, a challenge window that still has at least an immutable minimum left at submission, a decision that is a pure function of the claim state (a missing claim reverts), hook entries within the kernel's gas limit with at most three external static calls, re-entry by design with terminal hook entries that only record, no custody and no owner, and a pinned kernel. Non-deterministic tasks are out of scope. The TAP grants nothing to anyone: budgets are the client's escrow, bonds belong to the game, and no party is promised a payment, a share or a return.

## Motivation

Agents on BNB Smart Chain already have an escrow for jobs: the Agentic Commerce kernel (ERC-8183) holds a client's budget, lets a provider submit a deliverable, and pays or refunds on the word of one evaluator account fixed at creation. This TAP is written in acknowledgement of ERC-8183 and in order to interoperate with its deployed kernel; it is not an official extension of that proposal, and it does not ask for a number from any registry. The kernel's own security section states the gap this TAP fills: without a dispute mechanism the evaluator decides as it likes, and the evaluators available today either are the client itself or decide by a vote of a listed quorum after a silent period. Both are fine for tasks nobody can recompute. They are the wrong tool for a task that *can* be recomputed exactly, because for such a task the chain can decide.

The TapeOut family already has the deciding machine. `TAP-draft-large-netlists` fixes how a run of a `tapnet/2` netlist is committed, segmented and checked one step at a time, and how a dispute game about a claimed run rejects a wrong claim whenever one honest party challenges it in time. What is missing is the adapter: a contract that is the job's evaluator and hook, that knows which claim the job is about, and that turns the game's verdict into the kernel's `complete` or `reject` without any further judgement. That adapter is small, but the rules around it are not obvious: the kernel's expiry refund cannot be hooked and can arrive before the game has finished; a claim made long before the submission can leave the client no time to challenge; a provider that is also the input provider of its claim can make the claim unchallengeable; a hook that does too much work blocks the job; and a hook that calls out while the kernel calls it can re-enter in ways the kernel's reentrancy guard then refuses. The ten rules of this TAP are those lessons.

**Who checks, honestly.** A client that can recompute a run cheaply does not need to hire anyone to run it; a client that cannot recompute it cannot challenge it either. The value of a circuit job is therefore not that it saves the client work. It is that the result is *settled on chain* in a form other contracts can read: an accepted claim's checkpoint leaves open the outputs of the run (`TAP-draft-large-netlists` Appendix C), a credential or a contest can cite the claim, and the payment is the wrapper that makes the provider run it. Settlement takes days, not seconds, under any realistic game parameters; this TAP is for batch results that will be read by third parties, not for interactive tasks.

**Target users.** Agents that *offer* a circuit as a service (a classifier, a game referee, a fixed computation) and agents that want such a result settled rather than merely asserted. An agent that only wants an identity or an ordinary job does not need this TAP.

**What was measured, and what is still open.** Three facts about the deployed kernel that earlier designs had to assume were measured on 2026-10-24 on a local fork of chain 56 at block 129,352,831, with throwaway keys and no transaction on a public chain (Specification 0.1, table M; the procedure is Annex B): a freshly deployed contract that reports the hook interface can be a job's evaluator and hook without any allow-list; `setBudget` can be called by the client and by the provider while the job is open, so the provider can change the price until the client funds; and the hook calling convention, the status enum and the time rules of the kernel are as §1.2 states, including that a job does not end by itself at its expiry, so that after `expiredAt` the evaluator's settlement and anyone's refund are a race. The kernel is upgradeable, so these facts hold for the implementation of that block and are re-measured before any deployment. Two items remain open, each repeated in Security Considerations:

1. that `maxSettlementSeconds()` of a game is a real upper bound: in the game economics this TAP was written against (a local design note, not submitted) it holds only while no more than a fixed number of disputes about the claim are open at once, and the counting rule is undecided;
2. that `TAP-draft-large-netlists` (pull request #74) is merged; until then its interfaces are inlined here and this TAP names no draft in `requires`.

**Builds on a draft not yet merged.** `requires` lists ERC-165 and the deployed kernel only. This text also refers to [#74](https://github.com/TapeOutProtocol/TAPs/pull/74), *Large Netlists and Verifiable Execution*, a draft under review in the TAPs repository, at commit `1d0d6f23b74d6746d4783240d5d826b08aece4dd`; every mention of `TAP-draft-large-netlists` in this text means that draft at that commit. Its claim rules and its reference game are what the views of §1.3 are read from, and §1.3 is inlined so that nothing normative here depends on the pull request. When it is merged and numbered, the references change to its number. The game economics this TAP was written against is a local design note that has not been submitted; this text names no rule of it and depends on none (table P, Pre-1).

The design uses the escrow and the game as they are; it changes neither. It uses the words "budget", "bond" and "escrow" for what the two contracts already hold, and promises nobody a payment for checking.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 0. Status, preconditions and scope

#### 0.1 Measured facts and preconditions

**Table M: facts measured on a local fork.** Measured on 2026-10-24 with a local `anvil` fork of BNB Smart Chain (chain 56) at block 129,352,831, implementation `0xe8d47866e2cc3dcaa50f0ad980355695b2f1d533` behind the proxy of §1.2, with throwaway keys; no transaction was sent to a public chain. Annex B gives the procedure and the expected results. The kernel is an upgradeable proxy: every fact below holds for that implementation at that block and MUST be re-measured, with the same procedure, before a deployment under this TAP is made and recorded in Deployments.

| # | Fact | Measured result |
|---|---|---|
| M-1 | **Route B: no hook allow-list.** The kernel accepts as `evaluator` and `hook` of `createJob` any contract that reports ERC-165 identifier `0x7ff6bc9e` and answers `afterAction(createJob)` without reverting | `createJob(provider, H, expiry, "routeB", H)` with a freshly deployed hook `H` succeeded as a transaction (`evaluator == hook == H`); a hook that reports every identifier, a hook without callbacks, an externally owned account and the zero address are refused (`HookMissingInterface`, `HookCallFailed`, `HookMissingInterface`, `HookRequired`); no allow-list getter exists; the full flow `setBudget → fund → submit → complete` from the hook contract paid the provider |
| M-2 | **`setBudget` caller.** | The client and the provider can both call `setBudget` while the job is `Open` (the last call wins); the evaluator and strangers get `Unauthorized`; from `Funded` on, `WrongStatus`. The provider can therefore change the price until `fund`; `fund(jobId, expectedBudget, optParams)` reverts `BudgetMismatch` when `expectedBudget != job.budget` |
| M-3 | **Hook calling convention.** | `msg.sender` in the hook is the kernel; `data` never carries the caller (the EIP's reference implementation prepends `msg.sender` to `data`; the deployed kernel does not); callbacks and encodings are those of §1.2; `createJob` calls only `afterAction`; `claimRefund` calls no hook; `gasleft()` at entry is about 993,935 in `beforeAction` and 998,845 in `afterAction` |
| M-4 | **States, authorisations and time rules.** | Status enum `0 Open, 1 Funded, 2 Submitted, 3 Completed, 4 Rejected, 5 Expired`; the authorisation matrix and the time rules of §1.2, including: a job does not end by itself at `expiredAt`; `submit` needs `now < expiredAt`; `claimRefund` needs `now ≥ expiredAt` and `Funded` or `Submitted`; after `expiredAt` the evaluator's `complete` or `reject` and anyone's `claimRefund` are a race that the first transaction wins |

**Table P: preconditions (unverified).** This TAP is conditional on the following items.

| # | Item | Status on 2026-10-24 | Settled by |
|---|---|---|---|
| Pre-1 | **`maxSettlementSeconds` is a bound.** The game economics this TAP was written against (a local design note, not submitted) states the bound only for claims that never have more than a fixed number of disputes open at once; the counting rule (per claim, per claimant, with or without a cap) is undecided | Open in that note. This TAP depends on the *semantics* of the view, not on its formula, and states the residual risk (Security Considerations) | A game whose stated bound holds unconditionally, or a revision of that note |
| Pre-2 | **`TAP-draft-large-netlists` unmerged.** The claim rules this TAP relies on (§7.1 of that draft) are in [pull request #74](https://github.com/TapeOutProtocol/TAPs/pull/74) at commit `1d0d6f23b74d6746d4783240d5d826b08aece4dd`, a draft under review | Open. The views of §1.3 are inlined; this TAP is their normative source until that draft, or a later one, adopts them and this TAP points there | Merge of that pull request |
| Pre-3 | **Kernel behaviour not covered by table M.** The kernel's reaction to an `afterAction` that reverts for `fund`, `submit`, `complete` or `reject` (only `beforeAction` reverts and the `createJob` `afterAction` revert were measured); a contract evaluator's `reject` in `Funded` (measured with an externally owned evaluator only) | Unmeasured; the rules of this TAP do not depend on either | Fork re-run |

An implementation MUST NOT be presented as conforming to this TAP, and a deployment of `TapCircuitEvaluator` against a public kernel MUST NOT be made under this TAP's name, until table M has been re-measured against the implementation the kernel proxy points to at that time and the re-measurement is recorded in Deployments. A tool that reads jobs under this TAP MUST treat a job whose evaluator was deployed before that record as unverified. Pre-1 is a residual risk the rules cannot remove (§3.2 item 10, Security Considerations). Pre-2 changes only where the text of §1.3 lives.

#### 0.2 Scope and non-claims

1. This TAP covers jobs whose task is a deterministic run of a `tapnet/2` netlist for `T` beats from the all-zero state with inputs committed by `inputRoot`, as a claim `(netlistHash2, T, K, inputRoot, checkpointRoot)` of `TAP-draft-large-netlists` §7.1 (pull request #74, draft under review) in a game that offers the views of §1.3. Nothing else is a circuit job. Non-deterministic tasks (text generation, retrieval, human judgement, any notion of quality) are out of scope and are not made deterministic by this TAP.
2. The evaluator does not decide whether a claim is right. It reads the state the game reports. Whether that state is right depends on the game, its parameters, and on at least one honest party having checked the run within the challenge window; this TAP does not promise that anyone checks (Security Considerations).
3. This TAP does not define bonds, their sizes, who may challenge, deadlines or any settlement of the game. It reads one duration from the game and nothing else about its economics.
4. This TAP does not move, hold or price anything. The budget is the kernel's escrow under the kernel's rules (including its platform fee: `platformFeeBP()` returned 0 and `MAX_PLATFORM_FEE_BP()` returned 1,000 basis points when read on 2026-10-24, Deployments); the bonds are the game's. No budget, bond, share, fee or return is promised to a checker, a challenger, the evaluator or anyone else.
5. This TAP does not write to any identity, reputation or validation registry. An earlier design wrote a per-job success value to a reputation registry from the evaluator; it is not part of this TAP (Rationale).

### 1. Terms, notation and pinned interfaces

#### 1.1 Terms

| Term | Meaning |
|---|---|
| Kernel | The deployed Agentic Commerce contract of §1.2 (one per chain), behind an upgradeable proxy |
| Job | A record of the kernel: `getJob(jobId)` returns `(id, client, provider, evaluator, description, budget, expiredAt, status, hook, submittedAt, deliverable)` |
| Client, provider | `job.client` (the account that created and funds the job) and `job.provider` (the account that submits and is paid) |
| Evaluator | The contract `TapCircuitEvaluator` of §2, equal to both `job.evaluator` and `job.hook` of every job it serves |
| Game | A contract that offers the views of §1.3 about claims of `TAP-draft-large-netlists` §7.1; one game per evaluator, fixed at construction |
| Claim | A record of the game identified by `claimId`; its state is one of §1.3 item 2 |
| Job spec | The tuple of §3.1 that fixes the task, the budget, the expiry and the input provider of a job |
| Bound | A job is bound when `bindJob` succeeded for it; a claim is bound to a job when `afterAction(submit)` recorded it |
| Decided | A bound claim whose state is accepted or rejected |
| Hook entry | One call of `beforeAction` or `afterAction` by the kernel |
| `now` | `block.timestamp` of the transaction being executed |

Byte strings are `0x` followed by lowercase hexadecimal digits; `keccak256` is the hash function of EIP-712; `abi.encode` is the ABI encoding of the Solidity specification; `‖` is concatenation. A selector is the first four bytes of `keccak256` of a canonical signature; an ERC-165 identifier is the exclusive or of the selectors of an interface's functions. A selector depends on argument types only: two views that differ only in their return values have the same selector and, alone, the same ERC-165 identifier (§1.3 item 3).

#### 1.2 The kernel (pinned)

The kernel is the `AgenticCommerceUpgradeable` contract of the BNBAgent SDK at the proxies below, with the implementation read from the EIP-1967 implementation slot `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` on 2026-10-24. This TAP is written against those implementations; a kernel whose proxy points elsewhere is not the pinned kernel (§8.2).

| Chain | Proxy | Implementation | `HOOK_GAS_LIMIT()` | `MAX_EXPIRY_DURATION()` |
|---|---|---|---|---|
| BNB Smart Chain (56) | `0xEa4DAa3100A767e86FDed867729ae7446476EBA6` | `0xe8d47866e2cc3dcaa50f0ad980355695b2f1d533` | 1,000,000 | 31,536,000 |
| BNB Smart Chain testnet (97) | `0xa206c0517B6371C6638CD9e4a42Cc9f02A33B0DE` | `0x55c3826b39a0f671b2c3e5d0f1372cad0b911421` | 1,000,000 | 31,536,000 |

Functions of the kernel this TAP calls or dispatches on, and the two fee views a tool reads, with the selectors of the deployed ABI:

| Function | Selector | Used by this TAP |
|---|---|---|
| `createJob(address provider, address evaluator, uint256 expiredAt, string description, address hook) returns (uint256)` | `0x41528812` | the client (Annex A); the kernel reverts `HookRequired()` `0x55c45de1` for a zero hook and `HookMissingInterface()` `0x1a5d3d5f` for a hook that does not report `0x7ff6bc9e` |
| `setProvider(uint256 jobId, address provider_, bytes optParams)` | `0xc9a84bb9` | the client, once, while the provider is unset (M-4) |
| `setBudget(uint256 jobId, uint256 amount, bytes optParams)` | `0xdd4ae9d4` | the client or the provider, while `Open` (M-2) |
| `fund(uint256 jobId, uint256 expectedBudget, bytes optParams)` | `0xd2e13f50` | the client; `beforeAction(fund)` is checked by §3.3 |
| `submit(uint256 jobId, bytes32 deliverable, bytes optParams)` | `0x9e63798d` | the provider; `afterAction(submit)` is checked by §5 |
| `complete(uint256 jobId, bytes32 reason, bytes optParams)` | `0xd75bbdf3` | the evaluator, from `settle` (§6) |
| `reject(uint256 jobId, bytes32 reason, bytes optParams)` | `0x41dd26f5` | the evaluator, from `settle` (§6) |
| `claimRefund(uint256 jobId)` | `0x5b7baf64` | anyone after `expiredAt`; not hooked, not preventable by the evaluator |
| `getJob(uint256 jobId)` | `0xbf22c457` | every check of this TAP |
| `platformFeeBP()`, `MAX_PLATFORM_FEE_BP()` | `0xff96092a`, `0x963913a7` | tools, to show the fee the kernel takes from the budget (Deployments); not called by the evaluator |
| `HOOK_GAS_LIMIT()`, `MAX_EXPIRY_DURATION()` | | the constructor (§2.3) |

Errors of the kernel that this TAP's flows meet: `WrongStatus()` `0x8e78f0cb`, `Unauthorized()`, `BudgetMismatch()`, `ExpiryTooShort()`, `ExpiryTooLong()`, `ZeroBudget()`, `ProviderNotSet()`, `ProviderAlreadySet()`, `HookCallFailed()` `0xa9e35b2f`, `ReentrancyGuardReentrantCall()`, `EnforcedPause()` (selectors in `vectors.json`, `interfaces.kernel.errors`). The kernel's job states are, in the order of its enum, `0 Open`, `1 Funded`, `2 Submitted`, `3 Completed`, `4 Rejected`, `5 Expired` (M-4). `Completed`, `Rejected` and `Expired` are terminal.

**Authorisations and time rules of the kernel (M-4).** `createJob` requires `now + 300 < expiredAt ≤ now + 31,536,000` (`ExpiryTooShort`, `ExpiryTooLong`). While `Open`: `setProvider` by the client, once; `setBudget` by the client or the provider; `fund` by the client (`ZeroBudget` for a zero budget, `ProviderNotSet` for a zero provider); `reject` by the client; everything else `WrongStatus`. While `Funded`: `submit` by the provider, only while `now < expiredAt`; `reject` by the evaluator (the kernel allows it; this TAP's evaluator never does it, J-6); `complete` by nobody. While `Submitted`: `complete` and `reject` by the evaluator, with no time condition. `claimRefund` by anyone while `Funded` or `Submitted` and `now ≥ expiredAt` (inclusive), refunding the client; it reverts `WrongStatus` before. A job does not change state at `expiredAt` by itself: after `expiredAt` the evaluator's `complete` or `reject` and anyone's `claimRefund` are a race that the first transaction wins, and the client can refund in the block whose timestamp equals `expiredAt`. The states `Completed` and `Rejected` are reached only through the evaluator, `Expired` only through `claimRefund`. `vectors.json` sections `kernelMatrix` and `kernelTiming` give every cell.

The hook interface of the kernel, ERC-165 identifier `0x7ff6bc9e` (`0xdc08fb1d ^ 0xa3fe4783`):

```solidity
interface IACPHook {
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external; // 0xdc08fb1d
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external;  // 0xa3fe4783
}
```

`selector` is the selector of the kernel function being executed. `msg.sender` in the hook is the kernel, and `data` never carries the caller (the EIP's reference implementation prepends `msg.sender` to `data`; the deployed kernel does not, M-3). The kernel calls the hook of a job with at most `HOOK_GAS_LIMIT()` gas (about 993,935 left at entry of `beforeAction` and 998,845 of `afterAction`, M-3) and treats a reverting hook as a failed action (`HookCallFailed`). Callbacks and `data` encodings (M-3):

| Kernel function | `beforeAction` | `afterAction` | `data` |
|---|---|---|---|
| `createJob` | no | yes | `abi.encode(address client, address provider, address evaluator)` |
| `setProvider` | yes | yes | `abi.encode(address provider, bytes optParams)` |
| `setBudget` | yes | yes | `abi.encode(uint256 budget, bytes optParams)` |
| `fund` | yes | yes | the raw `optParams` bytes, without ABI wrapping and without `expectedBudget` |
| `submit` | yes | yes | `abi.encode(bytes32 deliverable, bytes optParams)` |
| `complete` | yes | yes | `abi.encode(bytes32 reason, bytes optParams)` |
| `reject` | yes | yes | `abi.encode(bytes32 reason, bytes optParams)` |
| `claimRefund` | no | no | – |

A hook that reverts in `afterAction(createJob)` makes `createJob` fail; a hook that reverts blocks `complete` and `reject` but never `claimRefund`, so a hook can freeze a job until `expiredAt` and cannot lock the escrow. This TAP's evaluator reads `data` for nothing (§3.3, §5); the table is given so that an implementation can assert it and so that §7 item 3 is checkable.

#### 1.3 The game views (inlined; normative source)

A game is usable with this TAP if and only if it offers the following views. This TAP does not specify how a game computes them: `TAP-draft-large-netlists` §7 fixes when a claim may be accepted, and a game's own economics fix `maxSettlementSeconds`. This TAP is the normative source of this section; a later draft may adopt it, and this TAP then points there (Pre-2).

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

/// The state of one claim. ERC-165 identifier 0x58d08546 (the selector of claimSummary(uint256)).
interface ITapClaimSummary {
    /// status: 0 none, 1 open, 2 rejected, 3 accepted, 4 abandoned.
    /// windowEnd: the last timestamp at which a challenge is accepted (0 when status is 0).
    function claimSummary(uint256 claimId) external view returns (
        address claimant, bytes32 netlistHash2, uint64 T, uint64 K, bytes32 inputRoot,
        bytes32 checkpointRoot, uint32 leaves, uint8 status, uint64 windowEnd);        // 0x58d08546
}

/// The settlement bound of the game. ERC-165 identifier 0xfcd8e94e.
interface ITapSettlementBound {
    /// Seconds after a claim is made within which it is accepted or rejected, under the game's stated
    /// assumptions, provided that due moves are made. Constant for the life of the game.
    function maxSettlementSeconds() external view returns (uint64);                    // 0xfcd8e94e
}

/// The input provider of the game (TAP-draft-large-netlists §7.1). ERC-165 identifier 0xecef2c34.
interface ITapInputProvider {
    /// Zero: case (a), the game computes inputRoot from published inputs. Otherwise case (b): the account
    /// that publishes inputs, which can never be a claimant. Constant for the life of the game.
    function inputProvider() external view returns (address);                          // 0xecef2c34
}
```

1. A game under this TAP MUST implement all three views, MUST report ERC-165 identifier `0x58d08546`, and MUST return the same `maxSettlementSeconds()` and `inputProvider()` for its whole life.
2. `status` MUST be one of `0` (no claim with this id), `1` (open: the window has not ended, or a dispute is open), `2` (rejected: a challenger won a dispute), `3` (accepted: the window ended, no dispute open and none won by a challenger) or `4` (abandoned: a final state the game reports for a claim it will never accept or reject; this TAP does not define when a game reports it). States `2`, `3` and `4` are final. `claimSummary` of an unknown id MUST return `status = 0` and MUST NOT revert.
3. `claimSummary` MUST return exactly 288 bytes (nine words). An earlier local design of this view returned eight values without `windowEnd`; its selector and identifier are the same `0x58d08546`, so ERC-165 cannot tell the two apart. A caller MUST treat an answer shorter than 288 bytes as `BadGame` (a Solidity high-level decode of nine static values reverts on 256 bytes; a low-level call MUST check `returndata.length ≥ 288`).
4. `windowEnd` MUST be the last timestamp at which the game accepts a new challenge of the claim (`TAP-draft-large-netlists` §7.1, "Challengers and acceptance"). For a claim with `status = 1` whose window has ended, `windowEnd < now` and the claim is open only because a dispute is open.
5. A game MAY offer the permissionless `accept(uint256 claimId)` (`0x19b05f49`) of the reference game; the evaluator MAY call it (§6.2) and MUST NOT depend on it.
6. A game under this TAP SHOULD be non-upgradeable. A tool that shows a job whose game is behind an upgradeable proxy MUST show the job as settled by an upgradeable game.

### 2. The evaluator

#### 2.1 Interface

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

/// ERC-165 identifier 0x0b2be2a6 (exclusive or of the ten function selectors below).
/// The contract also reports 0x7ff6bc9e (IACPHook) and 0x01ffc9a7 (ERC-165).
interface ITapCircuitJob {
    struct JobSpec {
        address game;           // MUST equal game()
        bytes32 netlistHash2;   // TAP-draft-large-netlists §2.1
        bytes32 inputRoot;      // §4.4 of that draft
        uint64  T;              // beats, ≥ 1
        uint64  K;              // checkpoint spacing, ≥ 1
        uint256 budget;         // the kernel budget the client will fund, ≥ 1
        uint64  expiredAt;      // MUST equal job.expiredAt
        address inputProvider;  // MUST equal game().inputProvider(); zero for case (a)
    }

    /// Client only; job Open; once per job; see §3.2.
    function bindJob(uint256 jobId, JobSpec calldata spec) external;                 // 0x9349e872
    function specOf(uint256 jobId) external view returns (JobSpec memory);           // 0x20f20d9c
    function specHashOf(uint256 jobId) external view returns (bytes32);              // 0xa2334b66 (zero when unbound)
    function claimIdOf(uint256 jobId) external view returns (uint256 claimId, bool bound); // 0x0db32f94
    /// 0 pending, 1 complete, 2 reject; reverts NoClaim() when no claim is bound (§6.1).
    function check(uint256 jobId) external view returns (uint8 decision, bytes32 reason); // 0x5f72f450
    /// Anyone; see §6.2.
    function settle(uint256 jobId) external;                                         // 0x8df82800

    function kernel() external view returns (address);                               // 0xd4aae0c4
    function game() external view returns (address);                                 // 0xc3fe3e28
    function margin() external view returns (uint64);                                // 0x8f76691a, MARGIN
    function minRemainingWindow() external view returns (uint64);                    // 0x5db8081c, MIN_REMAINING_WINDOW

    event JobBound(uint256 indexed jobId, bytes32 indexed specHash, address indexed client);
    event ClaimBound(uint256 indexed jobId, uint256 indexed claimId);
    event JobSettled(uint256 indexed jobId, uint8 decision, bytes32 reason);

    error NotKernel(); error NotClient(); error NotOpen(); error NotEvaluator(); error AlreadyBound();
    error NotBound(); error BadGame(); error BadInputProvider(); error BadSpec(); error ExpiryMismatch();
    error ExpiryTooSoon(uint256 required); error BudgetMismatch(); error NotSubmitted(); error BadDeliverable();
    error ClaimMismatch(); error ClaimNotOpen(); error WindowTooShort(uint256 required); error NoClaim();
    error NotDecided(); error AlreadySettled();
}
```

Event topics and error selectors are listed in `vectors.json` (`interfaces.events`, `interfaces.errors`).

#### 2.2 Immutables

An evaluator has four immutables fixed at construction and readable through the views above: `kernel`, `game`, `MARGIN` (`margin()`) and `MIN_REMAINING_WINDOW` (`minRemainingWindow()`). It serves one kernel and one game. It MAY cache `game.inputProvider()` and `game.maxSettlementSeconds()` at construction, since §1.3 item 1 makes them constant; the reference implementation caches both.

#### 2.3 Constructor rules

The constructor MUST revert unless all of the following hold:

1. `kernel` and `game` have code;
2. `kernel.HOOK_GAS_LIMIT()` returns `1,000,000` and `kernel.MAX_EXPIRY_DURATION()` returns `31,536,000` (the values of the pinned implementations; J-10);
3. `game.supportsInterface(0x58d08546)` returns true, and `game.maxSettlementSeconds()` and `game.inputProvider()` each return one word (J-1);
4. `MARGIN ≥ 21,600` and `MIN_REMAINING_WINDOW ≥ 21,600` (six hours each; J-2, J-3);
5. `game.maxSettlementSeconds() + MARGIN < 31,536,000`: otherwise no job could satisfy both the kernel's `ExpiryTooLong` at creation and J-2 at binding (J-10).

The evaluator MUST report ERC-165 identifiers `0x01ffc9a7`, `0x7ff6bc9e` and `0x0b2be2a6` and MUST NOT report `0x58d08546` (it is not a game).

### 3. Binding a job

#### 3.1 Job spec, encoding and hash

The job spec is the `JobSpec` tuple of §2.1. Its encoding is `abi.encode` of the tuple in field order, eight words, 256 bytes:

```
word 0  game            (address, left-padded)
word 1  netlistHash2    (bytes32)
word 2  inputRoot       (bytes32)
word 3  T               (uint64)
word 4  K               (uint64)
word 5  budget          (uint256)
word 6  expiredAt       (uint64)
word 7  inputProvider   (address, left-padded)
specHash = keccak256(encoding)
```

`specHashOf(jobId)` returns `specHash` of the bound spec and zero for an unbound job. Two jobs with the same `specHash` have the same task, budget, expiry and input provider.

#### 3.2 `bindJob`

`bindJob(jobId, spec)` MUST perform the following checks in this order and revert with the named error at the first that fails; otherwise it MUST store the spec once, and emit `JobBound(jobId, specHash, job.client)`. `job` is `kernel.getJob(jobId)`.

| # | Check | Error | Rule |
|---|---|---|---|
| 1 | `msg.sender == job.client` | `NotClient` | J-1 |
| 2 | `job.status == Open` | `NotOpen` | J-1 |
| 3 | `job.evaluator == address(this)` and `job.hook == address(this)` | `NotEvaluator` | J-1 |
| 4 | the job is not already bound | `AlreadyBound` | J-1 |
| 5 | `spec.game == game` | `BadGame` | J-1 |
| 6 | `spec.inputProvider == game.inputProvider()` | `BadInputProvider` | J-1 |
| 7 | `spec.inputProvider == 0` or `spec.inputProvider != job.provider` | `BadInputProvider` | J-1 |
| 8 | `spec.T ≥ 1`, `spec.K ≥ 1`, `spec.budget ≥ 1`, `spec.netlistHash2 != 0` | `BadSpec` | J-1 |
| 9 | `spec.expiredAt == job.expiredAt` | `ExpiryMismatch` | J-1 |
| 10 | `job.expiredAt ≥ now + game.maxSettlementSeconds() + MARGIN` | `ExpiryTooSoon(required)` with `required` the right-hand side | J-2 |

Check 7 is the rule of `TAP-draft-large-netlists` §7.1 that an input provider never claims about the inputs it supplies, applied to the provider the kernel names at binding; the game applies it again to the claimant (§5). A job whose provider is still unset at binding MAY be bound; §5 checks the provider at submission. `bindJob` does not check `maxT`, `maxK` or any bound of the game: a claim outside them cannot be made, so the job cannot be submitted and ends by `claimRefund`. A client SHOULD check `largeStored(netlistHash2)` in the game's store and the game's bounds before it creates the job.

#### 3.3 `beforeAction(fund)`

On a hook entry with `selector == 0xd2e13f50` (`fund`) in `beforeAction`, the evaluator MUST revert `NotKernel` unless `msg.sender == kernel`, MUST revert `NotBound` unless the job is bound, and MUST revert `BudgetMismatch` unless `job.budget == spec.budget`. It MUST NOT read `data` (which is the raw `optParams` and does not carry `expectedBudget`, M-3). The kernel reaches `Funded` only through `fund`, so a funded job under this evaluator is always bound to a spec whose budget is the escrowed budget, whoever called `setBudget` last. Because the provider can change the budget until `fund` (M-2), a client MUST call `fund` with `expectedBudget == spec.budget` (the kernel then reverts `BudgetMismatch` on a changed price before the hook is reached) and MUST NOT pass a value read from `job.budget` without comparing it to `spec.budget`.

#### 3.4 Description convention (informative content, normative constraints)

`createJob` takes a free-form `description`. A client under this TAP SHOULD write the JSON object `{"tapCircuitJob": 1, "evaluatorType": "tap_circuit", "specHash": "0x…", "game": {"chainId": 56, "address": "0x…"}, "netlistHash2": "0x…", "T": 92, "K": 8}` so that indexers can find circuit jobs. The description is not read by the evaluator; `specOf` is authoritative and a tool MUST NOT present a description that disagrees with `specOf` as the job's task. The description MUST NOT state a price, a payment, a fee, a return or any amount: the job's amount is `job.budget` and nothing else.

### 4. States

| Kernel job | Bound | Claim state | `check` | `settle` | The job ends by |
|---|---|---|---|---|---|
| `Open` | no | – | `NotBound` | `NotBound` | the kernel (client `reject`, or expiry); `fund` is refused `NotBound` |
| `Open` | yes | – | `NoClaim` | `NoClaim` | `fund` → `Funded`, or the kernel |
| `Funded` | yes | – (provider claims in the game) | `NoClaim` | `NoClaim` | `submit` → `Submitted`, or `claimRefund` after `expiredAt` |
| `Submitted` | yes | `1` open | `0` pending | `NotDecided` | the game decides, then `settle`; or `claimRefund` after `expiredAt` |
| `Submitted` | yes | `2` rejected | `2` reject | `kernel.reject` → `Rejected`; budget to the client | `settle` |
| `Submitted` | yes | `3` accepted | `1` complete | `kernel.complete` → `Completed`; budget to the provider, less the kernel's fee | `settle` |
| `Submitted` | yes | `4` abandoned | `0` pending | `NotDecided` | `claimRefund` after `expiredAt` |
| `Completed`, `Rejected` | yes | final | `1` or `2`, as the claim stands (J-4) | `AlreadySettled` | – |
| `Expired` | yes | any | as the claim stands | `NotSubmitted` (the kernel would revert `WrongStatus`) | – |

A `Funded` job cannot be bound (`NotOpen`), so an unbound job is never funded. The evaluator never acts in `Open` or `Funded` and never prevents `claimRefund`. A `Funded` or `Submitted` job stays in its state after `expiredAt` until a transaction moves it (M-4): the rows above still apply at and after `expiredAt`, except that `submit` is refused by the kernel and that `settle` can be pre-empted by `claimRefund` (§6.2). `vectors.json` section `stateTable` gives every row.

### 5. Submission: the deliverable is a claim

The provider makes its claim in the game first (with the game's bond, which this TAP does not size), then calls `kernel.submit(jobId, deliverable, optParams)` with

```
deliverable = bytes32(uint256 claimId)     (the claim id as one big-endian word)
optParams   = ""                            (not read by the evaluator; SHOULD be empty)
```

On a hook entry with `selector == 0x9e63798d` (`submit`) in `afterAction`, the evaluator MUST perform the following checks in this order and revert with the named error at the first that fails; otherwise it MUST record `claimId` for the job once and emit `ClaimBound(jobId, claimId)`. `claimId = uint256(job.deliverable)` and `claim = game.claimSummary(claimId)`; `data` is not read.

| # | Check | Error | Rule |
|---|---|---|---|
| 1 | `msg.sender == kernel` | `NotKernel` | J-10 |
| 2 | the job is bound | `NotBound` | J-1 |
| 3 | `job.status == Submitted` | `NotSubmitted` | J-5 |
| 4 | no claim is bound to the job yet | `AlreadyBound` | J-5 |
| 5 | `claimSummary` returned at least 288 bytes | `BadGame` | J-5 |
| 6 | `claim.status != 0` | `BadDeliverable` | J-5 |
| 7 | `claim.claimant == job.provider` | `ClaimMismatch` | J-5 |
| 8 | `claim.netlistHash2 == spec.netlistHash2`, `claim.inputRoot == spec.inputRoot`, `claim.T == spec.T`, `claim.K == spec.K` | `ClaimMismatch` | J-5 |
| 9 | `claim.status == 1` | `ClaimNotOpen` | J-5 |
| 10 | `claim.windowEnd ≥ now + MIN_REMAINING_WINDOW` | `WindowTooShort(required)` | J-3 |
| 11 | `job.expiredAt ≥ now + game.maxSettlementSeconds() + MARGIN` | `ExpiryTooSoon(required)` | J-2 |

Check 9 refuses a claim that was already decided when submitted: the client could not have challenged it under this job. Check 10 refuses a claim made so long before the submission that the client has less than `MIN_REMAINING_WINDOW` left to challenge after seeing it. Check 11 repeats J-2 at the moment the provider commits, so that the game's bound plus the margin still fit before the kernel's refund becomes callable; the kernel itself only requires `now < expiredAt` for `submit` (M-4), which protects nobody. A reverting `afterAction(submit)` makes the kernel's `submit` fail (`HookCallFailed`) and the job stays `Funded`; the provider's claim stays in the game and is settled by the game alone.

The same claim MAY be the deliverable of several jobs with the same `netlistHash2`, `inputRoot`, `T` and `K` and the same provider: a claim is a statement about a run, and the evaluator records it per job.

### 6. Decision and settlement

#### 6.1 `check`

`check(jobId)` MUST revert `NotBound` for an unbound job and `NoClaim` for a bound job without a bound claim or whose claim reports `status = 0`, and otherwise MUST return a decision that is a function of `claim.status` alone (J-4):

| `claim.status` | `decision` | Meaning |
|---|---|---|
| `0` none | revert `NoClaim` | a claim that disappeared is not a decision |
| `1` open | `0` | pending |
| `2` rejected | `2` | reject |
| `3` accepted | `1` | complete |
| `4` abandoned | `0` | pending, for ever; the job ends by `claimRefund` |
| other | revert `BadGame` | not a claim state of §1.3 |

`reason = keccak256(abi.encode(address game, uint256 claimId, uint8 status))`. `check` MUST read nothing but `claimSummary` (and its own storage); it MUST NOT read the game's bonds, disputes or parameters.

#### 6.2 `settle`

`settle(jobId)` MAY be called by anyone. It MUST revert `NoClaim` where `check` would, `AlreadySettled` once it has settled the job, `NotDecided` while `check` returns `0`, and `NotSubmitted` unless `job.status == Submitted` (J-6). Otherwise it MUST call `kernel.complete(jobId, reason, "")` when the decision is `1` and `kernel.reject(jobId, reason, "")` when it is `2`, mark the job settled, and emit `JobSettled(jobId, decision, reason)` (J-6). Before it reads the claim, `settle` MAY call `game.accept(claimId)` (§1.3 item 5) with at most 200,000 gas, in a `try`, ignoring failure: a revert or an out-of-gas of `accept` MUST NOT make `settle` fail, and the decision is taken from the state read afterwards. Without the cap, a game whose `accept` consumed all available gas would leave `settle` too little to reach the kernel (the EVM keeps one sixty-fourth for the caller, EIP-150), and the protection of J-2 would be lost.

The evaluator MUST NOT call `kernel.reject` or `kernel.complete` in any other function or for any job whose bound claim is not decided, and MUST NOT expose any function by which an account causes `reject` before the provider has submitted (J-6). The kernel lets the evaluator `reject` a `Funded` job (M-4); J-6 is the evaluator's own restraint, and a tool checks it by reading the evaluator's code, not the kernel. A job that is never submitted, or whose claim is still open or abandoned at `expiredAt`, ends by the kernel's `claimRefund`, which nobody under this TAP can prevent.

Settlement after `expiredAt` is best effort only (M-4): the kernel still accepts `complete` and `reject` then, but anyone's `claimRefund` is accepted too, and the first transaction wins. A `settle` that loses the race reverts in the kernel (`WrongStatus`) and the evaluator records nothing. J-2 exists so that an honest provider's claim is decided before that race can start; a provider or a tool SHOULD call `settle` as soon as `check` is not `0`.

#### 6.3 `afterAction(complete)` and `afterAction(reject)`

On a hook entry with `selector == 0xd75bbdf3` (`complete`) or `0x41dd26f5` (`reject`) in `afterAction`, the evaluator MUST revert `NotKernel` unless `msg.sender == kernel`, and otherwise MUST only record that the job is settled and emit events; it MUST NOT call any contract (J-8). These entries are reached inside `settle`'s own call into the kernel (`settle → kernel.complete → afterAction`), which is re-entry of the evaluator by design; the kernel's reentrancy guard refuses any call back into the kernel from them.

### 7. Hook entries

1. Every hook entry MUST complete within `HOOK_GAS_LIMIT()` gas (`1,000,000` on the pinned kernels) and MUST make at most three external static calls (`getJob`, `claimSummary` and, when not cached under §2.2, `maxSettlementSeconds`); `afterAction(submit)` needs `getJob` and `claimSummary`, and the third only without the cache. The reference implementation targets under 300,000 gas per entry (J-7).
2. Every hook entry MUST revert `NotKernel` unless `msg.sender == kernel` (J-10).
3. For every `(phase, selector)` other than `beforeAction(fund)`, `afterAction(submit)`, `afterAction(complete)` and `afterAction(reject)`, the entry MUST return without reverting and without changing state (J-8). In particular `afterAction(createJob)` MUST return (a revert there makes `createJob` fail, M-3), and `setBudget` and `setProvider` entries, in either phase, have no effect: whoever changes the budget (M-2), it is pinned at `fund` by §3.3.
4. `beforeAction(submit)`, `beforeAction(complete)` and `beforeAction(reject)` are such no-effect entries. An implementation MAY assert the `data` encodings of §1.2 in a debug build and MUST NOT depend on them in the rules above.

### 8. Contract properties and the pinned kernel

#### 8.1 No custody, no discretion, no owner (J-9)

The evaluator MUST have no owner, administrator, pauser or upgrade path; MUST NOT hold, receive or transfer any token or native currency (no `receive`, no payable function); MUST NOT post, move or read the game's bonds; and MUST NOT have any function that changes a decision, a deadline, a spec or a bound claim. Its only state changes are the three recordings of §3.2, §5 and §6.

#### 8.2 Pinned kernel (J-10)

1. The evaluator is constructed for one kernel address and checks the two constants of §2.3 item 2. It is a conformance claim about the implementations of §1.2 only.
2. A tool that shows a job under this TAP MUST read the kernel proxy's EIP-1967 implementation slot at a recent block and MUST show the job as unverified when the implementation is not one listed in Deployments for that chain. The evaluator cannot detect an upgrade; the tool has to.
3. The evaluator's safety is bounded by the kernel's governance: an upgrade of the kernel, a pause (`EnforcedPause`), a fee change or a change of supported payment tokens is outside this TAP (Security Considerations).

#### 8.3 Rules summary

| Rule | Statement | Where |
|---|---|---|
| J-1 | Binding precedes funding; `job.evaluator == job.hook == this`; spec consistent with the game, its input provider and the kernel job | §3.2, §3.3 |
| J-2 | `job.expiredAt ≥ now + maxSettlementSeconds() + MARGIN` at binding and at submission; `MARGIN` immutable, at least 21,600 s | §3.2 item 10, §5 item 11 |
| J-3 | `claim.windowEnd ≥ now + MIN_REMAINING_WINDOW` at submission; immutable, at least 21,600 s | §5 item 10 |
| J-4 | The decision is a function of `claim.status` alone; status `0` reverts | §6.1 |
| J-5 | The deliverable is the claim id; the claim is the provider's, open, and equal to the spec | §5 |
| J-6 | `settle` only when decided and `Submitted`; never `reject` without a submitted, rejected claim | §6.2 |
| J-7 | Hook entries within `HOOK_GAS_LIMIT()`, at most three external static calls | §7 |
| J-8 | Terminal hook entries only record and emit; other entries have no effect; re-entry by design | §6.3, §7 |
| J-9 | No custody, no discretion, no owner, no upgrade | §8.1 |
| J-10 | One pinned kernel; constants checked; every entry from the kernel; tools check the implementation | §2.3, §7 item 2, §8.2 |

## Rationale

**Why the evaluator is the hook.** The kernel requires a hook that reports `IACPHook` and lets the client pick it freely (M-1), while the evaluator is just an address. Making one contract both gives it the two moments it needs, `beforeAction(fund)` to refuse funding of an unbound job and `afterAction(submit)` to refuse a deliverable that is not a matching open claim, and lets J-1 check `evaluator == hook == this`, without which a client could mount the evaluator as hook and name another account as evaluator, leaving `settle` unable to reach the kernel. Route A, a policy behind the deployed evaluator router, needs the router owner's allow-list and is not pursued here.

**Why the game is an immutable, not a spec field.** A spec that named any game would make the trust decision per job and would need an ERC-165 check inside a hook entry. With one game per evaluator the client inspects the game once, the evaluator caches the two constant views, and `spec.game` exists only so that `specHash` is self-describing.

**Why `deliverable = bytes32(claimId)`.** Earlier designs set `deliverable = keccak256(abi.encode(game, claimId))` and decoded `claimId` from `optParams` inside the hook's `data`. The encoding of `data` is now measured (M-3) and would allow that, but the game is fixed per evaluator, so domain separation buys nothing, and reading the claim id straight from `getJob` makes the submission check depend on nothing but the kernel's public state, survives a change of the hook convention in a later kernel, and lets anyone recover the claim from the `JobSubmitted` event.

**Why J-2 is checked twice.** The client knows `expiredAt` at creation, so a job that can never be submitted is refused at `bindJob` rather than after the provider has posted a bond and been refused at `submit` (a review of the earlier designs). The check at `submit` remains the one that protects the provider: between binding and submission time passes, and only the moment of commitment matters.

**Why `MARGIN` and `MIN_REMAINING_WINDOW` are immutables with a floor, not spec fields.** A review of the earlier designs showed that letting the client state `maxSettlementSeconds` (or a margin) in the spec lets it shorten `expiredAt` and refund itself through a dispute it stalls. The bound comes from the game, the margin from the evaluator's code, and neither party can lower them.

**Why `windowEnd` is in the view.** Without it a provider could make a claim long before the job, submit it when the window is nearly over, and leave the client no time to challenge; J-3 and §5 item 10 refuse that, and Security Considerations ("A claim made too early or already decided") states what remains. The field also lets a reader that sees only the view, such as the validation-registry adapter of the open questions or an indexer, tell whether a claim was accepted recently without searching the game's events; the reference game of `TAP-draft-large-netlists` (pull request #74) already stores it in its `claimOf` struct (Backwards Compatibility). Adding a return value does not change the selector; §1.3 item 3 says how an eight-value game is told apart.

**Why `inputProvider` is a view the evaluator reads.** The earlier designs required the spec's input provider to equal the game's but only through a wider economics interface of the game. A game that offers nothing but `claimSummary` and `maxSettlementSeconds` has no such value; the reference game has a public `inputProvider()` getter, and this TAP inlines it as the third view rather than require the whole economics interface.

**Why status `0` reverts and status `4` is pending.** A claim that is missing is not a decision and must not be read as one; a claim the game abandoned is a claim nobody settled, and the kernel's own expiry refund, not the evaluator, is the right end for it.

**Why no reputation write-back.** An evaluator that writes a per-job success value to a reputation registry becomes a single known rater, and a provider that hires itself through a puppet client, submits a trivial correct claim about its own small circuit and waits one window gets a perfect record at the price of gas and a bond it recovers. Such a value is not evidence about the provider. A tool that counts a provider's completed circuit jobs from `JobSettled` has to show the number of distinct clients beside the count, and nothing in this TAP calls such a count a success rate.

**Why there is no payment language.** The budget is the kernel's escrow; the bonds are the game's. This TAP neither prices checking nor promises a checker anything; a game's economics draft may define cost recovery for disputes, and this TAP does not read it.

**Alternatives.** The deployed optimistic policy (silence is consent, a listed quorum votes a dispute) decides by trust in the quorum and is not restricted to recomputable tasks; its failure direction is that a colluding quorum can reject any job, whereas here colluders cannot win against a correct claim but a wrong claim passes when nobody checks. A validation registry adapter (an account that answers validation requests from the claim state) is a separate, smaller piece and is left to a later draft. A generic arbiter interface would not fix what the job is about; the spec and its binding to a claim are the content of this TAP.

## Backwards Compatibility

- No deployed contract changes. The kernel is used through its public functions as deployed; the reference game of `TAP-draft-large-netlists` needs an adapter or a revision that adds the three views of §1.3 (its `claimOf` struct already carries every field, including `windowEnd`, and its `inputProvider` is already a public immutable).
- `claimSummary(uint256)` keeps selector `0x58d08546` with nine return values. The eight-value view of an earlier local draft is told apart by return data length (§1.3 item 3); no deployed contract returns eight values. Later drafts that read claims are expected to adopt the nine-value view and point to this section.
- A game whose wider interface contains `maxSettlementSeconds()` satisfies `ITapSettlementBound` whichever identifier it reports: §2.3 item 3 calls the function rather than check an identifier.
- A kernel upgrade that changes `HOOK_GAS_LIMIT()`, `MAX_EXPIRY_DURATION()`, the job struct, the status enum or the hook convention takes the evaluator out of this TAP (§8.2); a new evaluator is deployed against the new implementation after the measurement of Annex B is repeated.

## Test Cases

`assets/tap-draft-circuit-jobs/vectors.json` (format `tap-circuit-jobs-vectors/1`) is generated by `make_vectors.py` in the same directory and is reproducible byte for byte; its SHA-256 is `76a64e4d435260d93f1ede3c9a810be2895643db8becb0a0ad07316d4fa48662`. All addresses in it are placeholders except the two kernel proxies; `maxSettlementSeconds` is an arbitrary input chosen for the vectors (1,368,992 s, about 15.85 days), never recomputed. Sections:

- `interfaces`: the ERC-165 identifiers and every selector of `ITapClaimSummary`, `ITapSettlementBound`, `ITapInputProvider`, `IACPHook` and `ITapCircuitJob`, the kernel functions and errors this TAP uses with their deployed selectors, the kernel constants, and the evaluator's event topics and error selectors; with the note that `claimSummary` keeps `0x58d08546` with nine return values;
- `spec`: four job specs (the worked example, a case-(b) spec with an input provider, a minimal spec, a spec with every field at its maximum) with their 256-byte encoding and `specHash`;
- `deliverable`: claim ids `0`, `1`, `7`, `255`, `2^64` and `2^256 − 1` as deliverables and back, and `reason` values for accepted, rejected and open states;
- `decision`: every claim state `0` to `5` → `check` or revert (`NoClaim`, `BadGame`);
- `stateTable`: twelve rows of §4 (`Open`, `Funded` bound and unbound; `Submitted` with every claim state; the three terminal states);
- `bind`: a valid binding, a valid case-(b) binding, a binding at exactly the required expiry, and one case per check of §3.2 that fails exactly that check (two for `NotClient` and `NotOpen`, two for `NotEvaluator`, three for `BadInputProvider`, four for `BadSpec`, `ExpiryTooSoon` one second short and far short);
- `fund`: `beforeAction(fund)` from the kernel and from the client, unbound, with a changed budget and with a zero budget;
- `submit`: a valid submission, one at exactly the required remaining window, and one case per check of §5 that fails exactly that check (short return data, no such claim, a claimant that is not the provider, each of the four spec fields differing, a claim already accepted, rejected or abandoned, a window one second short and a window that ended, an expiry one second short at submission);
- `settle`: no claim, already settled, pending (open and abandoned), an `Expired` job with an accepted and with a rejected claim (`NotSubmitted`), and the two settlements with their `reason`;
- `hookRules`: entries that satisfy J-7, J-8 and J-10, and one entry per rule that breaks it (gas above and at the limit, four static calls, a terminal entry that calls out, a `setBudget` entry that changes state, an entry not from the kernel);
- `dispatch`: which check each `(phase, selector)` runs, for the seven kernel functions and an unknown selector;
- `expiry`: `requiredExpiry` and `requiredWindowEnd` at the boundary, one second below and one above, for several bounds and margins; the constructor conditions of §2.3 items 4 and 5 (`default`, margin and window below the floor, `maxSettlementSeconds + MARGIN` equal to and one below `MAX_EXPIRY_DURATION`, a bound of 103,295,104 s, which is infeasible); and, for a job created with the kernel's longest expiry, the last second at which J-2 holds;
- `kernelMatrix`: the authorisation matrix of §1.2 (M-4): for `Open`, `Funded`, `Submitted` and `Completed` and each of the seven kernel functions, the result for the client, the provider, the evaluator and a stranger (`ok`, `Unauthorized`, `WrongStatus`);
- `kernelTiming`: the time rules of §1.2 (M-4) at `expiredAt − 1`, `expiredAt` and `expiredAt + 1` for `claimRefund`, `submit`, `complete` and `reject` in `Funded`, `Submitted` and `Open`, whether a settlement at that time can still be pre-empted, and `createJob`'s expiry bounds at leads of 299, 300, 301 seconds, one year and one year plus one second;
- `hookData`: which phases the kernel calls for each function and the measured `data` encodings (M-3), with example encodings for every function (`fund` with empty and with two-byte `optParams`, `submit` with and without `optParams`, `claimRefund` with none) and the measured `gasleft()` at entry;
- `mlp`: the worked example of Annex A: spec, `specHash`, deliverable, a timeline, the results of `bindJob`, `beforeAction(fund)` and `afterAction(submit)` at those times, the three outcomes with their `reason`, and the gas figures of the demo.

`test_circuit_jobs.py` checks every vector against `circuit_jobs.py`, the keccak-256 known answers, every selector against the values confirmed with Foundry `cast sig` (and against `cast` itself when installed), the `abi.encode(bytes32, bytes)` example against `cast abi-encode`, that `specHash` changes when any field changes, the boundaries of J-2 and J-3, the constructor conditions, the measured kernel matrix and time rules, and the order of the checks of §3.2 and §5.

## Reference Implementation

In this repository, under `assets/tap-draft-circuit-jobs/` (MIT; Python 3.9+, standard library only):

- `circuit_jobs.py`: a small keccak-256; selectors and ERC-165 identifiers; the job spec encoding and `specHash`; the deliverable and `reason`; the job and claim state constants, the state table and the decision function; the expiry and window arithmetic and the constructor conditions; `bind_check`, `fund_check`, `submit_check` and `settle_check`, which return the first broken check in the order of this text; `hook_rule_check` and `hook_dispatch` for §7; and the measured facts of table M as functions (`hook_data`, `kernel_allows`, `kernel_time_rule`, `create_expiry_ok`);
- `make_vectors.py` writes `vectors.json` (`--check` compares); `test_circuit_jobs.py` runs the tests.

A Solidity reference is planned, not written. It is to consist of the interfaces of §1.3 and §2.1 (`ITapClaimSummary`, `ITapSettlementBound`, `ITapInputProvider`, `ITapCircuitJob`), `TapCircuitEvaluator`, an adapter that gives the reference game of `TAP-draft-large-netlists` the three views, a mock kernel built from the deployed ABI and the measured behaviour of table M, and Foundry tests that replay `vectors.json`. The fork procedure that produced table M, and is repeated before a deployment, is Annex B. The Solidity reference will be linked here at a fixed commit when it exists.

## Deployments

None. Nothing under this TAP is deployed, on any chain. The kernels of §1.2 are deployments of their own project, listed because this TAP is written against them; their proxies are upgradeable by their owner (a 2-of-3 Safe at the time of reading), and no upgrade path is sealed. The table of §1.2 is the record a tool compares against (§8.2 item 2).

Record of the fork measurement (table M): local `anvil` fork of chain 56 at block 129,352,831 (block timestamp about 1,792,772,423), archive source `bsc-mainnet.public.blastapi.io`, kernel implementation `0xe8d47866e2cc3dcaa50f0ad980355695b2f1d533`; a test hook contract (`TestHook.sol`, solc 0.8.28) that records `selector`, `data`, `msg.sender` and `gasleft()` per entry; throwaway keys; the procedure is Annex B, and the scripts and raw outputs of that run are the author's and are not part of this repository. Before any deployment the procedure of Annex B is run again against the implementation the proxy points to on that day, and the block and results are added here (Annex B.7).

Record of the fee reading (Specification 0.2 item 4): on 2026-10-24 at block 129,363,314, by read-only `eth_call` to the chain-56 proxy (implementation slot still `0xe8d47866e2cc3dcaa50f0ad980355695b2f1d533`), `platformFeeBP()` (`0xff96092a`) returned 0 and `MAX_PLATFORM_FEE_BP()` (`0x963913a7`) returned 1,000 (basis points, one tenth). A tool reads both the same way; the kernel owner can change the fee up to the maximum.

## Security Considerations

The evaluator has no discretion and no custody, so the usual evaluator threats become threats against the game, the kernel's expiry, or the readers of the result. Each item below says what an attacker can do, what the design protects and what it does not. The measured facts and the open preconditions of Specification 0.1 apply to everything here: the kernel facts hold for the implementation of block 129,352,831, and an upgrade that introduces a hook allow-list would stop every job under this TAP from being created, which is why the measurement is repeated before a deployment.

**Provider and evaluator collude.** Not a threat: the evaluator has no choice to sell. `check` is a pure function of the claim state (J-4), `settle` can be called by anyone, and the contract has no owner, pause or upgrade (J-9). What remains is collusion with the *game's* deployer: a game that reports `accepted` for anything is a game, and the evaluator will believe it. The client's trust decision is the game, made once when it picks an evaluator (the game is immutable in it); a tool shows jobs of an evaluator whose game it does not recognise as settled by an unverified game.

**Trust in the evaluator itself.** A client must read `kernel()`, `game()`, `margin()`, `minRemainingWindow()` and the code of the evaluator, or rely on a tool that did. An evaluator that passes the rules of this TAP can still be deployed by anyone, and two evaluators with the same game and constants are interchangeable; the one property that cannot be read from the chain is whether the game was audited.

**Stale expiry against the dispute window.** The kernel's `claimRefund` is callable by anyone from the block whose timestamp equals `expiredAt`, is not hooked and cannot be paused by the evaluator; the job does not end by itself at `expiredAt`, so from that moment the evaluator's settlement and the refund race and the first transaction wins (M-4). If a dispute runs past `expiredAt`, the client (or anyone) refunds the budget while the claim is still open; an honest provider loses the escrow and keeps only what the game returns. J-2 keeps `expiredAt` at least `maxSettlementSeconds() + MARGIN` ahead at binding and at submission; it is the only protection, and it protects exactly as far as `maxSettlementSeconds()` is a bound (Pre-1). Under the game economics this TAP was written against (Pre-1), a claim with more open disputes than the game's stated limit can take longer by a term that grows with the number of extra disputes, so a client, or puppets it funds, can delay a claim past `expiredAt` at the price of one bond per puppet and gas, and then refund itself. No fixed margin removes this; the design states it. A provider mitigates by requiring an `expiredAt` well above the bound, by reading the number of open disputes about its claim before the margin runs out, and by refusing jobs from clients it cannot identify. If a game's economics cap the extension by a counting rule, the residual risk shrinks and this TAP does not change.

**Self-hiring puppet clients.** A provider can create jobs from accounts it controls, fund them with its own tokens, submit trivial correct claims about its own small circuit and settle them. Each such job is a real escrow round trip minus the kernel's fee, so it costs only gas, a bond that returns, and time. It produces `JobSettled` events that look like work for others. This is why the evaluator writes nothing to a reputation registry (Specification 0.2 item 5) and why a count of completed jobs is not a success rate: an indexer that shows such counts shows the number of distinct clients and the budgets beside them, and never a rate without a per-client breakdown.

**Claim front-running and claim reuse.** The checkpoint leaves of a claim are public once the claim is made. An account that copies them into its own claim gains nothing against the job: §5 item 7 requires the claimant to be the job's provider, so the copy cannot be the deliverable, and the copier risks its bond for nothing. A provider may reuse one claim for several jobs with the same task (§5); that is a feature, since the claim is a statement about a run, not about a job.

**A claim made too early or already decided.** Without J-3 a provider could claim long before the job and submit with seconds left in the window; without §5 item 9 it could submit a claim that was accepted before the client ever saw it. Both are refused. A client still has to challenge in time: the evaluator cannot challenge for it, and nobody is paid by this TAP to do so.

**Nobody checks.** The game accepts an unchallenged claim when its window ends. If no party recomputes the run, a wrong claim is accepted and the job completes. This is the optimistic assumption of the game, inherited here and not promised away. The failure direction differs from the deployed optimistic policy's: there a colluding quorum can reject any job; here colluders cannot defeat a correct claim, but a wrong one passes in silence. For a result that matters, the client recomputes or has someone recompute within the window; this TAP does not say who or why.

**Input provider collusion.** In case (b) an input provider that is also the claimant can publish inputs `X` and commit `Y`, making its claim unchallengeable; `TAP-draft-large-netlists` §7.1 forbids it in the game, and §3.2 item 7 refuses the binding when the kernel's provider is the game's input provider. A client-controlled input provider cannot make a correct claim wrong; it can publish inputs the provider will not compute on, in which case the provider does not claim and the job expires.

**Hook as a denial of service.** A hook that reverts blocks the action. The evaluator reverts only for the reasons of §3.3 and §5, each of which the caller can read in advance from `getJob`, `specOf` and `claimSummary`; it never reverts in the terminal entries or in entries for other actions (J-8), so `createJob`, the client's own `reject` while `Open` and the kernel's refund are never blocked. Measured (M-3): a hook that reverts freezes `complete` and `reject` until `expiredAt` and cannot stop `claimRefund`, so no hook, this one included, can lock the escrow. A hook that runs out of gas blocks the action in the same way; J-7 keeps every entry far below `HOOK_GAS_LIMIT()` and pins the number of external calls.

**The evaluator's own restraint.** The kernel lets the evaluator `reject` a `Funded` job, and lets it `complete` or `reject` after `expiredAt` (M-4). J-6 forbids the former and the race makes the latter best effort. Both are properties of the evaluator's code, not of the kernel: a client that trusts "no claim, no reject" has to read the evaluator (or rely on a tool that compared its bytecode with the reference) and must not infer it from the kernel.

**Price changes before funding.** The provider can call `setBudget` until the client funds (M-2). A client that funds with a stale `expectedBudget` is stopped by the kernel's `BudgetMismatch`; a client whose tool reads `job.budget` and passes it blindly is not, which is why §3.3 requires the client to fund the budget it has read and bound (`spec.budget`), and the hook refuses any other budget.

**Re-entry.** `settle` calls the kernel, which calls `afterAction` on the evaluator in the same transaction. The terminal entries only record and emit (J-8); the kernel's own reentrancy guard refuses a call back into it, and the evaluator holds nothing that re-entry could take. A game's `accept`, when `settle` calls it, is called before the decision is read and inside a `try` with at most 200,000 gas (§6.2); a malicious game can make `accept` revert or burn that gas, not change the decision and not starve `settle`.

**Kernel governance.** The kernel is an upgradeable proxy whose owner can upgrade it, pause it (`EnforcedPause`), change the platform fee up to `MAX_PLATFORM_FEE_BP()` (1,000 basis points when read, Deployments) and change the supported payment tokens. The evaluator cannot see an upgrade; tools check the implementation slot against Deployments (J-10), and an evaluator's safety never exceeds the kernel's. A fee taken by the kernel is taken from the budget before the provider is paid.

**What this TAP does not protect.** The correctness of the game and its verifier; the validity of the netlist file (checked off chain, `TAP-draft-large-netlists` §7.1); the availability of the inputs and the chunks; the client's ability to recognise a good game; the value of the payment token; a kernel upgrade after block 129,352,831; and anything the open preconditions of Specification 0.1 turn out to break.

### Open questions

1. **Hook data.** The `data` encoding of `submit` is measured (M-3), so a later version could read `claimId` from `optParams` and keep the `keccak256(game, claimId)` deliverable of the earlier designs; this version prefers the convention that needs no decoding and survives a change of the hook convention.
2. **A second settlement path.** Should a provider be able to withdraw its submission (and so free its claim for another job) when the client refunds early? The kernel offers no such action; this is a kernel question.
3. **Game bounds at binding.** `bindJob` could read the game's bounds (`maxT`, `maxK`) when the game offers them and refuse a spec the game would refuse; this version keeps the binding independent of any game interface beyond §1.3.
4. **Where §1.3 lives.** Whether `TAP-draft-large-netlists` §7 (pull request #74) or a later economics draft adopts `ITapClaimSummary` with `windowEnd` and `ITapInputProvider` decides which draft this TAP points to after Pre-2.
5. **Attribution to an agent identity.** An indexer that wants to show a provider's circuit jobs next to an agent identity has to check that the identity's current owner is `job.provider` at the block it reads; this TAP defines no such display and no write to any registry.
6. **A validation registry adapter.** An account that answers validation requests `100` for an accepted claim and `0` for a rejected one is small and separate; its claimant rule and its display rules belong to a later draft.

## Annex A (informative): Worked example, verifiable inference

The demo of `TAP-draft-large-netlists` (`demo/inference` of its reference repository `BruceLanLan/tap-large-netlists` at commit `18e0c7bfb4c1fba7fe0bae3a6fa86d2863b1c3b3`; the commit that pull request #74 names, `4fa0c0ba…`, does not yet contain it) is a 64-16-10 digit classifier compiled to one `tapnet/2` file of 88,854 bytes (6 chunks); one inference is `T = 92` beats, and with `K = 8` a claim has 13 checkpoint leaves (times 0, 8, …, 88 and 92). In the reference game, disputes about one inference cost 2.6 to 6.7 million gas for all parties together, the costliest single move 4,961,813 gas, and an undisputed claim 362,959 gas. The numbers below use parameters chosen for the example as inputs (`maxSettlementSeconds = 1,368,992`, about 15.85 days; `challengeWindow = 108,000`), an evaluator with `MARGIN = MIN_REMAINING_WINDOW = 21,600`, and the timeline of `vectors.json` section `mlp`. It is a demonstration; the model is a toy, nothing is deployed, and a client that can run 92 beats in milliseconds has no economic reason to outsource them. The point is that the class the circuit computed is settled on chain and can be opened from the accepted claim's last checkpoint leaf by any contract or tool.

Participants: client C, provider P, the evaluator E (constructed for the chain-56 kernel and the game G), and any checker X. All calls are ordinary transactions from the parties' own wallets; nothing needs a permission from anyone.

1. **C creates the job.** `kernel.createJob(P, E, expiredAt, description, E)` with `expiredAt = created + 1,900,800` (22 days; the kernel requires more than 300 s and at most 31,536,000 s), and `description` the JSON of §3.4 with `specHash`. The kernel checks `E.supportsInterface(0x7ff6bc9e)` and calls `E.afterAction(createJob)`, which returns without effect (M-1, §7). Returns `jobId`.
2. **C binds the spec.** `E.bindJob(jobId, {G, netlistHash2, inputRoot, 92, 8, budget, expiredAt, 0})` 600 s after creation. §3.2 passes: `required = now + 1,368,992 + 21,600 = created + 1,391,192 < expiredAt`. Emits `JobBound`.
3. **C sets and funds the budget.** `token.approve(kernel, budget)`; `kernel.setBudget(jobId, budget, "")` (by C or by P; the last call before funding wins, M-2); `kernel.fund(jobId, budget, "")` with `expectedBudget = budget = spec.budget`, so that a price P changed in between is refused by the kernel (`BudgetMismatch`). `beforeAction(fund)` finds the job bound and `job.budget == spec.budget`. The job is `Funded`.
4. **P runs the circuit and claims.** P runs 92 beats off chain, computes the 13 checkpoint leaves, and calls `G.claim(netlistHash2, 92, 8, inputRoot, leaves, inputData)` with the game's bond and the 92 bytes of packed inputs (case (a)); the game computes `inputRoot` itself. Returns `claimId = 7`; `windowEnd = claimTime + 108,000`.
5. **P submits.** `kernel.submit(jobId, 0x0000…0007, "")` 300 s after the claim. `afterAction(submit)` reads `getJob` and `G.claimSummary(7)`: claimant P, fields equal to the spec, status `1`, `windowEnd ≥ now + 21,600`, `expiredAt ≥ now + 1,390,592`. Emits `ClaimBound(jobId, 7)`. The job is `Submitted`.
6. **Anyone checks.** Within the window X (or C) recomputes the 92 beats. If a leaf differs, X calls `G.challenge` and the dispute of `TAP-draft-large-netlists` §7.2 to §7.4 runs (9 to 10 rounds in the demo, one verifier call); a lying P loses its claim, a lying X loses its dispute. `E.check(jobId)` returns `0` throughout.
7. **Settlement.** After `windowEnd` with no dispute open, anyone calls `E.settle(jobId)`: E calls `G.accept(7)` (optional), reads status `3`, calls `kernel.complete(jobId, reason, "")`; the kernel pays the budget less its fee to P and calls `E.afterAction(complete)`, which records and emits `JobSettled(jobId, 1, reason)`. Had a challenger won, status `2` leads to `kernel.reject` and the budget returns to C.
8. **Reading the result.** C opens the output of beat 91 from the last checkpoint leaf (`TAP-draft-large-netlists` Appendix C) and reads the class. It trusts only an accepted claim.

If P never submits, or the claim is still open at `expiredAt` (for example because puppets delayed it, Security Considerations), anyone calls `kernel.claimRefund(jobId)` and the budget returns to C; the claim is settled by the game alone.

## Annex B (informative): Re-running the fork measurement of table M

This annex is the procedure behind table M, written so that anyone can repeat it against the implementation the kernel proxy points to on the day of a re-run (Specification 0.1). Everything runs on a local fork; no transaction is sent to a public chain, and no key that holds value is used. The expected results below are those of the first run (2026-10-24, block 129,352,831); a re-run that differs in any cell changes table M and is recorded in Deployments, not here.

**B.1 Environment.**

- Start `anvil` with `--fork-url <archive endpoint of chain 56> --fork-block-number <BLOCK> --chain-id 56` and point `ETH_RPC_URL` at it (`http://127.0.0.1:8545`). The public `bsc-dataseed` endpoints keep about 128 blocks of state and the fork soon fails with missing trie nodes; an archive endpoint is needed (the first run used `bsc-mainnet.public.blastapi.io`). To reproduce the first run, `<BLOCK>` is 129,352,831; before a deployment it is a recent block.
- Read the implementation first: `cast storage <proxy> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`, with the chain-56 proxy of §1.2 (`0xEa4DAa3100A767e86FDed867729ae7446476EBA6`). If the result differs from the implementation of §1.2, every row of table M is judged afresh, not only confirmed.
- Keys: four throwaway accounts from `cast wallet new` (client, provider, an externally owned evaluator, a stranger), given BNB with `anvil_setBalance`. The client's balance in a payment token the kernel accepts is written with `anvil_setStorageAt` into the token's balance mapping (in the first run an 18-decimal token whose mapping was at storage slot 51, the slot of the client's balance found with `cast index address <client> 51`).
- A test hook contract (solc 0.8.28 in the first run) that answers `supportsInterface` true for `0x01ffc9a7` and `0x7ff6bc9e` only; whose `beforeAction` and `afterAction` emit `selector`, `data`, `msg.sender` and `gasleft()` on every entry; and that has an owner-only `exec(address,bytes)` so that it can call the kernel as the evaluator. A variant whose `beforeAction` reverts for every selector is used in B.4.
- Every `cast send` goes to the local port only. A revert is classified by the four bytes of its revert data, compared with the error selectors of `vectors.json` (`interfaces.kernel.errors`).

**B.2 M-1: no hook allow-list (route B).**

1. Deploy the test hook `H`. With `EXP` seven days after the latest block timestamp, call `createJob(provider, H, EXP, "routeB", H)` from the client, first as `eth_call` and then as a transaction. Expected: success, and `getJob(id)` returns `evaluator == hook == H` (first run: job 57062, 265,696 gas).
2. Counter-examples by `eth_call`: `hook = 0` → `HookRequired` (`0x55c45de1`); an externally owned account as hook → `HookMissingInterface` (`0x1a5d3d5f`); a contract whose `supportsInterface(0x7ff6bc9e)` is false → `HookMissingInterface`; a contract that answers true for every identifier → `HookMissingInterface` (the kernel also probes an identifier that has to be false); a contract that reports the identifier but has no callbacks → `HookCallFailed`; `evaluator = 0` → `ZeroAddress` (a kernel error outside this TAP's flows, so not in `vectors.json`); any contract that is registered nowhere as evaluator → success.
3. Probe for an allow-list: `hookWhitelist(address)`, `isHookWhitelisted(address)`, `whitelistedHooks(address)` and `allowedHooks(address)` all revert as functions the kernel does not have.
4. Full flow: `setBudget` → token `approve` → `fund(id, budget, 0x)` by the client → `submit(id, deliverable, 0x)` by the provider → `H.exec(kernel, complete(id, reason, 0x))`. Expected: the provider's token balance rises by the budget less the platform fee (zero in the first run).

**B.3 M-2: who calls `setBudget`.**

On a fresh `Open` job with the provider set and budget 0, send `setBudget(id, amount, 0x)` from each role (amounts in whole tokens): client 5 → success; provider 7 → success, overwriting; client 3 → success; evaluator → `Unauthorized`; stranger → `Unauthorized`. Then `fund(id, 5, 0x)` while `job.budget` is 3 → `BudgetMismatch`; `fund(id, 3, 0x)` → success; any `setBudget` from then on → `WrongStatus`. On a job created with `provider = 0`: `setProvider` succeeds for the client once and reverts `ProviderAlreadySet` the second time; `fund` reverts `ProviderNotSet` while the provider is unset and `ZeroBudget` while the budget is 0.

**B.4 M-3: hook calling convention and gas.**

Run the flow of B.2 step 4 with the test hook and read, from its events, `(phase, selector, data, msg.sender, gasleft)` of every entry. Expected: the callbacks and `data` encodings of §1.2 and of `vectors.json` `hookData` (`createJob` calls `afterAction` only; `claimRefund` calls nothing; `fund` passes the bare `optParams`, so `0xccdd` arrives as `0xccdd` and empty as empty, without `expectedBudget`; the others pass `abi.encode(...)` as listed there); `msg.sender` is the kernel in every entry; `gasleft()` at entry about 993,935 in `beforeAction` and 998,845 in `afterAction`. Compare each `data` byte for byte with `circuit_jobs.hook_data(...)`. Then replace the hook with the reverting variant: `complete` and `reject` revert `HookCallFailed`, while a stranger's `claimRefund` after `expiredAt` still succeeds and refunds the client.

**B.5 M-4: status enum, authorisation matrix and time rules.**

- After every transition read the eighth field of `getJob(id)`: 0 `Open`, 1 `Funded`, 2 `Submitted`, 3 `Completed`, 4 `Rejected`, 5 `Expired`.
- Authorisation matrix, by `eth_call --from <role>` for each of the four roles and the seven kernel functions in `Open`, `Funded`, `Submitted` and `Completed`: every cell of `vectors.json` `kernelMatrix` (`Open`: `reject` by the client only; `Funded`: `submit` by the provider only, `reject` by the evaluator only, `complete` → `WrongStatus` for everyone; `Submitted`: `complete` and `reject` by the evaluator only; terminal states: everything `WrongStatus`).
- Time rules, with `evm_snapshot`, `evm_setNextBlockTimestamp` and `evm_revert`, for a job with `expiredAt = E` at `E − 1`, `E` and `E + 1`: `claimRefund` reverts `WrongStatus` at `E − 1` and succeeds from `E` on; `submit` succeeds at `E − 1` and reverts from `E` on; `complete` and `reject` of a `Submitted` job succeed at all three times; `claimRefund` of an `Open` job always reverts `WrongStatus`. Every cell of `vectors.json` `kernelTiming`.
- `createJob` expiry bounds, by the lead of `expiredAt` over the block timestamp: `+300` → `ExpiryTooShort`, `+301` → success, `+31,536,000` → success, `+31,536,001` → `ExpiryTooLong`.

**B.6 What a re-run of B.2 to B.5 does not cover.** The items of table P, Pre-3: the kernel's behaviour when `afterAction` reverts for `fund`, `submit`, `complete` or `reject`; a contract evaluator's `reject` in `Funded`; an end-to-end run with the reference game of `TAP-draft-large-netlists` and an evaluator under this TAP deployed on the fork; any later implementation; route A.

**B.7 Recording.** A re-run adds to Deployments the block, its timestamp, the implementation address, pass or fail for each of B.2 to B.5, and where the raw outputs are kept. Keys are not recorded.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
