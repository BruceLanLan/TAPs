*Working note, translated from the author's Chinese original; dated entries describe the state on that date.*

# Merged holder: final gas, sizes and addresses (2026-10-10, after the review fixes)

## Conclusion

- **Current build** (single-call path = gas lab O1–O5 + O7, without O6; plus `executeBatch`; after review fixes F-01/F-02, from commit 187749d): creation code **7,869 bytes**, keccak256 **`0x4bc9698ad9224fefccd7ba5d7205c1c0e8e9117eb53257873e64fae37f499c4f`** (`vectors/creation-code.hex`); runtime **7,092 bytes**. The merged build before the review (ce9fb86) was 7,985 / 7,208 bytes, keccak `0x40798cfa…cc0f`.
- **Deployment** P2TR **1,604,415**, P2WPKH **1,602,160** gas: 12.9% less than the draft baseline (1,842,326), and 380,077 more than the pure gas-optimised build (1,224,338); this is the price of the batch feature (1,751 more runtime bytes).
- **`isValidSignature`** (transaction) P2TR **37,838–37,877**, P2WPKH **40,468–40,587 (one ecrecover) / 43,845 (two)**: identical to the pure gas-optimised build. The part an EIP-1271 verifier pays inside the frame (GasBench static): P2TR 15,215, P2WPKH 20,563 (a signature that needs two ecrecovers).
- **`execute` of one ERC-721 transfer** P2TR **95,086** (77,998 when the nonce is already non-zero), **103,337 with a 0.01 tip**; P2WPKH 97,835 (one ecrecover) / 109,332 with tip (two). Within 80 gas of the pure gas-optimised build.
- **`executeBatch` of 1/2/4/8 ERC-721 transfers**: P2TR **98,747 / 123,404 / 172,830 / 266,790**; P2WPKH **101,374 / 129,411 / 178,715 / 269,527**. 8 transfers save **58% (P2TR) / 60% (P2WPKH)** compared with 8 separate `execute` calls, and 51% compared with the batch lab's candidate; each additional call costs about +24,000. With 1 call it costs about 3,700 more than `execute` (the specification says SHOULD NOT).
- **Return-data bomb (review F-01)**: with 8 callees each returning 200,000 bytes (callGas 400,000 per call), the gas used by `executeBatch` falls from **36,953,708 (before the fix, measured by the review) to 945,620** (same PoC on the new build); with 0 bytes returned 186,294 → 181,438. The remaining difference is what the 8 callees pay for their own 200,000 bytes of memory; the holder no longer spends extra.
- **Test holder addresses** (same on BSC / Base / X Layer, through the deterministic deployment proxy, salt 0): P2TR `bc1pdznq…258gca` → **`0x750d22d8b6dd3168c2a4a2efddd44a8bfe362647`**; P2WPKH `bc1qu357…xw008` → **`0xb73bee58fafd674831f355c17311d7849ccc2897`**. The proxy is present on all three chains (69 bytes), and neither address has code yet (read-only `eth_getCode`, 2026-10-10).

## 1. Method

- **Measure**: the `gasUsed` of the transaction receipt (including the 21,000 and calldata), on a **purely local anvil** (`--chain-id 56 --hardfork shanghai`, no fork); the deterministic deployment proxy is placed at `0x4e59…956C` with `anvil_setCode`. Scripts `scripts/final_gas.sh` (starts a fresh node for each creation code and shuts it down by its own recorded PID) + `scripts/final_gas.py`; raw results in `scripts/logs/final-gas/final-gas-<build>.json` (the merged build before the review is the two files with the `-ce9fb86` suffix).
- **The same set of cases runs on these builds**: draft baseline (834787a, 8,980 B), gas lab main line (O1–O7, 5c103b9), gas lab "deployment-optimal only" (O1–O5+O7, 6e5bf32), batch lab candidate (fc8864b, 11,107 B), merged build before the review (ce9fb86), **current build**, current build + O6 (only to answer the SWAR question, see §5, not committed).
- **Callee**: `contracts/test/batch/BenchERC721.sol`, a complete ERC-721 (owner, balances, clearing approvals, `Transfer` event, receiver check); the receiving address already holds one token, so each transfer writes a non-zero balance. **This is more expensive than the single-slot `BenchToken` used by GAS-REPORT**: for the same gas lab main-line build, `execute` is 70,867 there and 88,231 here; so the numbers in this file are only comparable with numbers in this file.
- **Each scenario starts from the same snapshot** (`evm_snapshot`/`evm_revert`): holder just deployed, nonce 0, holding 8 tokens, balance 1 native coin. A "nonce 0" call pays for the first write of the nonce slot, so numbers for "nonce already non-zero" are given separately.
- **P2WPKH noise**: the holder first tries v = 27, and v = 28 if that is wrong; whether a signature needs one or two `ecrecover` calls is decided by the signature (RFC 6979 deterministic k, and the text contains the holder address, so the count changes when the address changes); the difference is about 3,100–3,300 gas. The script computes the count for each measurement (the `ecrecover` field in the JSON), and the tables below give it in parentheses. P2TR has no such branch.
- callGas 100,000, deadline 4,000,000,000, tip 0.01 native coin, relayer is anvil default account 0.

## 2. Standard cases (P2TR)

| Case | Draft baseline | Gas lab O1–O5+O7 | Gas lab O1–O7 | Batch lab | Merged before review | **Current build** |
|---|---:|---:|---:|---:|---:|---:|
| creation code (bytes) | 8,980 | 6,118 | 6,353 | 11,107 | 7,985 | **7,869** |
| runtime (bytes) | 7,854 | 5,341 | 5,576 | 9,981 | 7,208 | **7,092** |
| Deployment | 1,842,326 | 1,224,338 | 1,274,343 | 2,303,743 | 1,629,559 | **1,604,415** |
| `isValidSignature` (range over 8 digests) | 71,933–71,997 | 37,838–37,877 | 32,869–32,920 | 71,939–72,015 | 37,838–37,877 | **37,838–37,877** |
| `execute` ERC-721 (nonce 0) | 145,298 | 95,013 | 88,231 | 145,356 | 95,089 | **95,086** |
| `execute` ERC-721 (nonce 1) | 128,730 | 77,913 | 71,131 | 128,764 | 77,992 | **77,998** |
| `execute` ERC-721 + 0.01 tip | 158,055 | 103,225 | 96,470 | 158,153 | 103,355 | **103,337** |
| `executeBatch` 1 call | — | — | — | 152,597 | 99,735 | **98,747** |
| `executeBatch` 2 calls | — | — | — | 207,982 | 124,882 | **123,404** |
| `executeBatch` 4 calls | — | — | — | 319,525 | 175,268 | **172,830** |
| `executeBatch` 8 calls | — | — | — | 542,002 | 271,187 | **266,790** |
| `executeBatch` 8 calls + 0.01 tip | — | — | — | 554,791 | 279,453 | **275,005** |
| `executeBatch` 4 calls (nonce 1) | — | — | — | 302,957 | 158,168 | **155,703** |
| First-time user (deployment + one `execute`) | 1,987,624 | 1,319,351 | 1,362,574 | 2,449,099 | 1,724,648 | **1,699,501** |

## 3. Standard cases (P2WPKH, ecrecover count in parentheses)

| Case | Draft baseline | Gas lab O1–O5+O7 | Batch lab | **Current build** |
|---|---:|---:|---:|---:|
| Deployment | 1,795,655 | 1,222,082 | 2,257,070 | **1,602,160** |
| `isValidSignature` (1) | 98,654–98,850 | 40,504–40,587 | 98,654–98,850 | **40,468–40,587** |
| `isValidSignature` (2) | 101,903–102,111 | 43,750–43,845 | 101,915–102,111 | **43,845** |
| `execute` ERC-721 (nonce 0) | 175,416 (2) | 97,640 (1) | 171,987 (1) | **97,835 (1)** |
| `execute` ERC-721 + 0.01 tip | 184,756 (1) | 105,962 (1) | 188,045 (2) | **109,332 (2)** |
| `executeBatch` 1 / 2 / 4 / 8 calls | — | — | 179,475 (1) / 234,610 (1) / 349,422 (2) / 572,073 (2) | **101,374 (1) / 129,411 (2) / 178,715 (2) / 269,527 (1)** |
| `executeBatch` 8 calls + 0.01 tip | — | — | 584,641 (2) | **280,878** |

## 4. Batch vs separate calls (current build)

"k separate" = k consecutive `execute` calls from the same snapshot (the first moves nonce 0→1, the rest have a non-zero nonce), each with its own signature and transaction.

| Transfers | P2TR k separate | P2TR one batch | Saved | P2WPKH k separate | P2WPKH one batch | Saved | Batch message characters | Batch calldata bytes |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 95,086 | 98,747 | −3.9% | 97,835 | 101,374 | −3.6% | 286 | 612 / 644 |
| 2 | 173,084 | 123,404 | 28.7% | 181,828 | 129,411 | 28.8% | 435 | 932 / 964 |
| 4 | 329,107 | 172,830 | 47.5% | 349,814 | 178,715 | 48.9% | 733 | 1,572 / 1,604 |
| 8 | 636,341 | 266,790 | **58.1%** | 674,458 | 269,527 | **60.0%** | 1,329 | 2,852 / 2,884 |

- Each additional call in a batch costs about 24,000 gas (P2TR (266,790 − 98,747) / 7 = 24,006); a separate call costs about 78,000 each (with the nonce already non-zero). So, whatever the number of calls, the saving compared with separate calls is at most about 69%.
- Compared with the batch lab: for the same 8 calls, 266,790 against 542,002 (−51%). In the batch lab each additional call costs about 55,600, in the current build about 24,000; the difference comes mostly from message building (Solidity byte by byte vs the gas lab's assembly writer), and the review fix (not copying return data) saves about 500 more per call.
- Real TapeOut circuits are more expensive than BenchERC721 (in the UniSat run that transferred a real circuit on a BSC fork, a single `execute` in the draft version was about 166k); the callee part does not change with the implementation, so the absolute saving (about 54k per additional call) carries over, and the ratio will be somewhat smaller. This sentence is an extrapolation.

## 5. About O6 (SWAR hex): keep "without O6", but batching makes the choice close

The choice of `variant/no-swar` is kept, as requested. The argument of GAS-REPORT (`docs/GAS-REPORT.md`) is: O6 costs +50,007 at deployment, saves 4,957 per `isValidSignature` and 6,782 per `execute`, and a holder needs about 10 signature checks or 7 `execute` calls to break even. I applied O6 (`_hexAt` from e222f16) unchanged to the current build and measured the same set of cases (`final-gas-merged-swar.json`, creation 8,104 B):

| | Current build | Current build + O6 | Difference |
|---|---:|---:|---:|
| Deployment P2TR | 1,604,415 | 1,654,408 | +49,993 |
| `isValidSignature` P2TR (lowest) | 37,838 | 32,869 | −4,969 |
| `execute` ERC-721 P2TR | 95,086 | 88,343 | −6,743 |
| `executeBatch` 1 / 2 / 4 / 8 calls | 98,747 / 123,404 / 172,830 / 266,790 | 91,965 / 111,665 / 151,150 / 225,336 | −6,782 / −11,739 / −21,680 / −41,454 |

**My view: I do not object to this choice, but it is no longer a clear winner.** Each call in a batch has 52 bytes to convert to hex (target 20 + data hash 32), and O6 saves about 5,200 per call; one 8-call batch saves 41,454, so **one 8-call batch plus two single calls (or about 1.2 batches of 8) exceeds the extra 49,993 that O6 costs**, while with single calls only it takes 7–8. So the conclusion depends on the expected use of a holder: if most holders only "receive a circuit and sign one or two TAP-11 delegations" (deployment is the main cost, subsidised for first-time users), leaving out O6 is still cheaper; if batches are used often (claiming mining-rig rewards and moving them, moving circuits in bulk), O6 pays for itself after the first large batch. The difference is small (±3% of deployment), and either is acceptable; if the author expects batches to be the main use, I would switch to including O6.

## 6. Results of the review PoCs on the current build

The review's `poc/contracts/*.t.sol` were copied into a copy of the repository in a temporary directory (the review directory was not changed) and rerun against the current build with the review's seed `0x5eed2`. One line was changed only so that it compiles: `test_batch_calls_holder_itself` used to receive the `bytes[]` return value of `executeBatch`, which no longer exists, so the assertion on the `scriptPubKey()` return value was removed.

| PoC | Before the fix (review log, ce9fb86) | Current build | Judgement |
|---|---|---|---|
| `test_returndata_bomb_cost`: 8 calls each returning 0 / 32,000 / 100,000 / 200,000 bytes | 186,294 / 1,650,139 / 9,830,442 / **36,953,708** | 181,438 / 224,465 / 412,823 / **945,620** | F-01 fixed: the growth left is only the callees' own memory cost (linear) |
| `test_returndata_bomb_cost_execute`: returning 0 / 200,000 bytes | 78,570 / 1,160,718 | 78,567 / 1,160,715 | `execute` deliberately unchanged (single copy, the return value is part of the specification), written into Security Considerations |
| `test_revert_bomb_turns_typed_error_into_oog`: revert with 300,000 bytes, given 1.2M / 3M | revert data 0 / 300,100 bytes | **356 / 356** bytes (`BatchCallFailed` + first 256 bytes) | F-02 fixed |
| `test_frontrun_cost_to_relayer`: 8 calls × 0 / 24,000 bytes, execution gas before `BadSignature` | 118,351 / 1,030,861 | 118,782 / 1,031,292 | F-06 documentation only, as requested (Security Considerations) |
| `test_batchMessage_renders_unexecutable_batch` | Renders; execution gives `BadBatch` | Same | F-05 documentation only, as requested (§8 MUST NOT + Security Considerations) |
| `test_noncanonical_init_code_gives_other_working_holders` | All four addresses work | Same | F-03 not requested, still open |
| Other PoCs and fuzzing (ABI mutation, messages vs reference text, signature differential, Python judge corpus) | Pass | See below | — |

All 35 PoC tests pass on the current build (`scripts/logs/final-tests/audit-poc-rerun.log`): semantics 17/17; adversarial ABI encoding 3×60,000; messages vs independent reference text 3×100,000 plus end-to-end signing through `execute`/`executeBatch` 2×50,000; signature path differential 400,000 + 400,000 + 300,000 + 150,000; Python judge corpus, 6 sets (regenerated, about 6,500 adversarial witnesses each), agreeing with both versions of the verifier. The PoCs in the table are themselves measurements (they assert only the selector at 3M gas), so "pass" does not mean that a defect is still present or has been fixed; the judgement comes from the numbers: the numbers for F-01 and F-02 changed as expected, and the behaviour for F-03, F-05 and F-06 was kept as requested and written into the specification.

## 7. GasBench (forge, transaction measure and static frame measure)

The current build was installed at the baseline holder address and measured with the baseline vectors (the same signature) (`forge test --match-contract '^GasBench$' -vv`):

| | Current build | Merged before review | Gas lab O1–O5+O7 (from the description of commit 6e5bf32) |
|---|---:|---:|---:|
| `isValidSignature` P2TR, transaction / static frame | 38,277 / 15,215 | 38,277 / 15,215 | 38,277 / — |
| `isValidSignature` P2TR SIGHASH_ALL, transaction / static | 38,361 / 15,275 | 38,361 / 15,275 | — |
| `isValidSignature` P2WPKH (v = 28), transaction / static | 44,257 / 20,563 | 44,257 / 20,563 | 44,257 / — |
| `execute` (single-slot BenchToken) P2TR / P2WPKH / P2WPKH + tip | 78,139 / 80,864 / 89,115 | 78,142 / 80,867 / 89,118 | 78,027 / 80,752 / 89,003 |
| Deployment P2TR / P2WPKH (forge measure, 2,885 more than the receipt) | 1,607,300 / 1,605,045 | 1,632,444 / 1,630,188 | 1,227,222 / — |

## 8. Addresses and on-chain checks

| Bitcoin test address (public test private key, must never be funded) | scriptPubKey | Holder (same on BSC 56 / Base 8453 / X Layer 196) |
|---|---|---|
| `bc1pdznq5ty2978g55m83a4uanyqw8mkvnjhl3ky7rp5ald95zhd697q258gca` (P2TR) | `0x512068a60a…dd17c` | `0x750d22d8b6dd3168c2a4a2efddd44a8bfe362647` |
| `bc1qu357xdh0ps3wsc8dued9vupduqxky2ndpxw008` (P2WPKH) | `0x0014e469e3…2a6d` | `0xb73bee58fafd674831f355c17311d7849ccc2897` |

- Address = `keccak256(0xff ‖ 0x4e59b44847b379578588920cA78FbF26c0B4956C ‖ bytes32(0) ‖ keccak256(creation code ‖ abi.encode(spk)))[12:]`, independent of the chain; `tools/cli.py address` agrees with the test `test_vectors_creation_code_and_addresses` and with `TextCorpusTest` (which asserts after deploying through the proxy).
- Read-only RPC (`eth_getCode`) on 2026-10-10: on BSC (bsc-dataseed.bnbchain.org), Base (mainnet.base.org) and X Layer (xlayerrpc.okx.com) the proxy is 69 bytes (keccak `0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989`, checked in the first round); neither holder address has code. **No public-network transaction was sent.**
- Earlier addresses for comparison: draft `0xee27…31b8` / `0xa0b8…6d41`; gas lab main line `0x6219…20af` / `0xf04d…de29`; gas lab "deployment-optimal only" `0x1406…c912` / `0xcae7…5e93`; batch lab `0xf819…25a6` / `0x50be…ca83`; merged build before the review `0x4efd…2383` / `0x3a7b…b0f9`.

## 9. Local fork end to end (`scripts/demo_fork.sh`)

Run once on each of the three chains (current build), logs in `scripts/logs/demo-*.log` (anvil is shut down by the script's own PID; the EIP-7702 code of the default accounts is cleared with `anvil_setCode(addr, 0x)`). BSC (block 126,783,311, P2TR): deploy, runtime 7,092 bytes → real NFT `0x1f5c…f12c` #920 transferred in → TAP-11 delegation `isValidSignature` with right / wrong key `0x1626ba7e` / `0xffffffff` (`eth_estimateGas` 40,576) → signed `execute` transfers it back, the relayer receives exactly the signed tip, replay rejected → step 5: after transferring it in again, one signed `executeBatch` transfers the NFT back and sends 0.0002 BNB at the same time; `batchMessage(...)` is byte-identical to the Python text, gasUsed 116,519 (118,021 before the review), two `Called` events, tip and amounts match the signature, nonce 1→2, replay rejected. X Layer (P2WPKH, RIG voucher #3, batch gasUsed 212,532) and Base (P2TR, 113,966) pass the same way; on Base "relayer balance change + gas" is slightly less than the tip, which is the OP Stack L1 data fee.

## 10. Reproduce

```
cd contracts && forge clean && forge build --force && cd ..
sh scripts/final_gas.sh <output directory> merged=vectors/creation-code.hex [other build=<creation code hex>]
(cd contracts && forge test --match-contract '^GasBench$' -vv)
FORK_URL=https://bsc-dataseed.bnbchain.org sh scripts/demo_fork.sh bsc p2tr
```
