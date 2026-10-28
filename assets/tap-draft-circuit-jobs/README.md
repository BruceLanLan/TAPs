# Assets: Circuit Jobs: Settling Agent Jobs by a Dispute Game

Reference functions, vectors and a Solidity reference for `../../TAPs/TAP-draft-circuit-jobs.md`. The Python part needs Python 3.9+ (standard library only); the Solidity part needs Foundry. Nothing here sends a transaction to a public chain; nothing is deployed.

| File | Content |
|---|---|
| `circuit_jobs.py` | a small keccak-256; `selector`, `event_topic`, `interface_id` and the identifiers of `ITapClaimSummary` (`0x58d08546`), `ITapSettlementBound` (`0xfcd8e94e`), `ITapInputProvider` (`0xecef2c34`), `IACPHook` (`0x7ff6bc9e`) and `ITapCircuitJob` (`0x0b2be2a6`); `abi_encode` for static types; the job spec (`spec_encode`, `spec_hash`), the deliverable (`deliverable_of`, the claim id as one word) and `reason_of`; the kernel job states (0 Open … 5 Expired) and claim states (0 none … 4 abandoned), `decision` (status 0 reverts), `state_row`; the J-2/J-3 arithmetic (`required_expiry`, `expiry_ok`, `required_window_end`, `window_ok`), the constructor conditions (`constants_ok`) and `latest_bind_time`; `bind_check`, `fund_check`, `submit_check`, `settle_check` returning the first broken check in the order of the draft; `hook_rule_check`, `hook_dispatch`; and the facts measured on a local fork of chain 56 at block 129,352,831: `HOOK_CALLBACKS` and `hook_data` (the kernel's hook `data` encodings), `kernel_allows` (authorisation matrix), `kernel_time_rule`, `create_expiry_ok`, `settlement_guaranteed` |
| `make_vectors.py` | writes `vectors.json` (deterministic; `--check` compares) |
| `test_circuit_jobs.py` | 22 tests: keccak known answers; every selector against values confirmed with Foundry `cast sig` and against `cast` itself when installed; `abi.encode(bytes32,bytes)` against `cast abi-encode`; `specHash` sensitivity to every field; J-2/J-3 boundaries; constructor conditions and `ACCEPT_GAS_CAP`; every vector section recomputed; the order of the `bindJob` and `afterAction(submit)` checks; the measured kernel matrix, time rules and hook encodings |

```bash
python3 make_vectors.py --check && python3 test_circuit_jobs.py
```

`vectors.json` SHA-256: `76a64e4d435260d93f1ede3c9a810be2895643db8becb0a0ad07316d4fa48662` (format `tap-circuit-jobs-vectors/1`, 194 cases).

`maxSettlementSeconds` in the vectors is an arbitrary input chosen for them (1,368,992 s, about 15.85 days); it is never recomputed here, because the draft depends on the semantics of that view and not on its formula. `constants.ACCEPT_GAS_CAP` (200,000) is the gas `settle` gives the optional `game.accept` (draft §6.2). All addresses are placeholders except the two kernel proxies (`0xEa4DAa31…EBA6` on 56, `0xa206c051…B0DE` on 97) and the two implementation addresses read from their EIP-1967 slots on 2026-10-24.

## Solidity reference (`sol/`)

A Foundry project with no libraries (no forge-std; the few cheatcodes used are declared in `test/utils/Base.sol`). Not audited, not deployed, not a conformance claim (draft, Specification 0.1).

| File | Content |
|---|---|
| `src/Interfaces.sol` | the interfaces of the draft: `IACPHook`, the kernel functions used (`IAgenticCommerce`, with the `getJob` tuple as the deployed kernel returns it), `ITapClaimSummary`, `ITapSettlementBound`, `ITapInputProvider`, `ITapCircuitJob` |
| `src/TapCircuitEvaluator.sol` | the evaluator and hook: constructor conditions (2.3), `bindJob` (3.2), `beforeAction(fund)` (3.3), `afterAction(submit)` (5), `check`/`settle` (6), terminal entries (6.3); no owner, no payable function |
| `test/KernelFork.t.sol` | against the **deployed kernel** on a local fork of chain 56: full flows (accepted → `complete`, provider paid; rejected → `reject`, client refunded), the `bindJob` errors on real jobs, `fund` of an unbound job and a changed price (M-2), every `submit` refusal as the kernel reports it, the J-2/J-3 boundaries at submission, the expiry race (M-4), `settle` with a gas-burning or reverting `accept`, J-7 gas, the description length that exhausts `HOOK_GAS_LIMIT`, Pre-3 / M-5, and the M-3 entry order with `gasleft()` at entry |
| `test/VectorReplay.t.sol` | replays `../vectors.json` (sections `interfaces`, `spec`, `deliverable.reason`, `decision`, `bind`, `fund`, `submit`, `settle`, `expiry.constants`) against the evaluator; no fork |
| `test/utils/MockGame.sol` | **stand-in** game: the three views of Specification 1.3, claims made and decided by direct calls, nothing verified; an eight-value `claimSummary` mode and `accept` modes (accept, revert, burn all gas, missing) |
| `test/utils/StandInKernel.sol` | **stand-in** kernel used by the vector replay only (the vectors use placeholder addresses): `getJob`, the two constants, `complete`/`reject` |
| `test/utils/ProbeHook.sol` | a recording hook for the kernel measurements (Annex B style) |

Run (Foundry 1.x with solc 0.8.28 already installed; `offline = true` in `foundry.toml`, so nothing is fetched; without a local solc 0.8.28, remove that line and `forge build` downloads the compiler):

```bash
cd sol
forge test --match-contract VectorReplay            # no chain needed

# the kernel tests need a local fork of BNB Smart Chain from an archive endpoint, for example
anvil --fork-url https://bsc-mainnet.public.blastapi.io --fork-block-number 130339400 --chain-id 56 &
forge test --match-contract KernelFork -vv          # FORK_URL overrides http://127.0.0.1:8545
forge test --match-test test_J7_gas_of_hook_entries -vvvv   # trace: gas of each hook entry as the kernel calls it (J-7)
```

`setUp` checks that the fork is chain 56 and that the kernel proxy still points to the pinned implementation `0xe8d47866e2cc3dcaa50f0ad980355695b2f1d533`; a moved implementation fails every kernel test. All accounts are anvil's default test accounts, used through `prank` on the local fork; the client's payment-token balance is written into the token's balance mapping (slot 51, Annex B.1). Gas figures are taken after `vm.cool` on the kernel, its implementation, the token, the game and the evaluator, so that storage reads cost what they cost at the start of a transaction.

Last run (2026-10-29, Foundry 1.8.3, solc 0.8.28, fork of chain 56 at block 130,339,400, kernel implementation unchanged): 32 tests passed (`VectorReplay` 9, `KernelFork` 23). Measured there:

| Item | Result |
|---|---|
| J-7, hook entries as called by the kernel (trace, cooled storage, §3.4 description) | `beforeAction(fund)` 41,046 gas; `afterAction(submit)` 112,371 (of which `getJob` 34,097 and `claimSummary` 15,889); `afterAction(complete)` 3,803; no-effect entries 701 to 743. `beforeAction(fund)` called cold and directly: 60,046 |
| J-7, description length (cold) | 12,288 bytes: `fund` and `submit` pass; 13,312 bytes: `fund` passes, `afterAction(submit)` runs out of gas (`HookCallFailed`); 14,336 bytes: `beforeAction(fund)` runs out of gas |
| `settle` | 206,190 gas including `accept`, `kernel.complete`, the token transfer and `afterAction(complete)`; completes within 1,000,000 gas when `accept` burns its 200,000 cap |
| Pre-3 / M-5 | an `afterAction` revert for `fund`, `submit`, `complete` or `reject` fails the action with no state change; the kernel re-raises the hook's revert data (`Error(string)`, or the evaluator's own error) and raises `HookCallFailed` (`0xa9e35b2f`) only for an empty revert; a contract evaluator's `reject` in `Funded` succeeds and refunds the client |
| M-3 order | the kernel writes the new status and the deliverable before `afterAction`; `gasleft()` at entry 999,411 (`beforeAction`) and 999,455 (`afterAction`) for a hook that reads it first |


The procedure that produced the measured facts, and that is repeated before any deployment, is Annex B of the draft.
