*Working note, translated from the author's Chinese original; dated entries describe the state on that date.*

> **Provenance note (holder-final-lab)**: this file was copied unchanged from the `main` branch of holder-gas-lab (commit ff52eb9) (review finding F-07: it is not on the `variant/no-swar` branch, while `docs/FINAL-GAS.md` references it). The "main line" numbers here are those of 5c103b9, which includes O6; this repository chose 6e5bf32, without O6, plus batching. For the observation in §6 that "the accumulated hash differs, cause not found", see the "After the review" section of `docs/INTEGRATION-NOTES.md`.

# Gas optimisation report: BitcoinKeyedHolder

Conclusions within the lab repository (2026-10-10, baseline commit 834787a, main line ending at 5c103b9):

- **Deployment from 1,842,326 to 1,274,343 (−31%), `isValidSignature` P2TR from 71,985 to 32,908 (−54%), P2WPKH from 102,111 to 38,888 (−62%), `execute` ERC-721 transfer P2TR from 127,921 to 70,867 (−45%), P2WPKH from 154,806 to 73,592 (−52%)** (real receipts on a local anvil, chain id 56, shanghai). The gas an EIP-1271 verifier actually pays inside the frame falls from 48,965 / 78,459 to 9,888 / 15,236 (about −80%).
- No change alters the message format, interface, events, errors, return values or accept/reject rules; 15 differential tests (10 of them fuzz tests at 200,000 runs each) found no difference between the baseline bytecode and the optimised code. All 117 original tests pass (2 test files were adjusted in a documented way because of the bytecode change, see §3).
- **A security gap already present in the baseline was found along the way** (O5): with large `data` (≥ about 10 KB), a relayer giving the minimum gas can make the callee receive 1,792–5,174 gas less than `callGas`, which contradicts TAP §6.3 step 5, "the callee receives at least callGas". The fix costs only 232 gas; I recommend adopting it whether or not the other optimisations are adopted.
- Every item changes the creation code, and therefore every holder address; **all of them fall under "adoption requires changing the TAP text"** (§3.2 bytes and keccak, the example address in §5.2, the addresses in Test Cases, the measured-cost paragraph, the vectors in the assets), but no normative rule needs to change. §5 lists the exact places.
- The clone approach (shared implementation + a 79-byte proxy per holder) brings the deployment of a single holder down to about 80k, but each call costs about 3,000 more, and it introduces a shared implementation and DELEGATECALL; it was only measured and did not go into the main line (§4).

## 1. Standard cases: before and after

Transaction gasUsed, from local anvil receipts (`--chain-id 56 --hardfork shanghai`, deterministic deployment proxy preinstalled, default accounts first `anvil_setCode(addr, 0x)`). The call cases all use the baseline vectors (same calldata, same signature), with the optimised code installed at the baseline holder address; deployment uses each build's own creation code through the proxy with CREATE2. The "deployment-optimal combination only" column comes from branch `variant/no-swar` (main line without O6), computed as the GasBench numbers minus the fixed difference to the receipts (412 / 378 / 2,885, see GAS-PROFILE §1).

| Case | Baseline 834787a | Main line 5c103b9 (O1–O7) | Saved | Deployment-optimal only (O1–O5 + O7) |
|---|---:|---:|---:|---:|
| Deployment P2TR | 1,842,326 | 1,274,343 | −567,983 | 1,224,337 |
| Deployment P2WPKH | 1,795,655 | 1,272,087 | −523,568 | 1,222,081 |
| `isValidSignature` P2TR (transaction) | 71,985 | 32,908 | −39,077 | 37,865 |
| `isValidSignature` P2WPKH (transaction, this signature needs v=28) | 102,111 | 38,888 | −63,223 | 43,845 |
| `isValidSignature` P2TR (static frame, the part the verifier contract pays) | 48,965 | 9,888 | −39,077 | 14,845 |
| `execute` ERC-721 transfer P2TR | 127,921 | 70,867 | −57,054 | 77,649 |
| `execute` ERC-721 transfer P2WPKH | 154,806 | 73,592 | −81,214 | 80,374 |
| `execute` ERC-721 transfer + 0.01 tip P2WPKH | 167,615 | 81,843 | −85,772 | 88,625 |
| First-time user (deployment + one `execute` P2TR) | 1,970,247 | 1,345,210 | −625,037 | 1,301,986 |
| creation code | 8,980 B | 6,353 B | −2,627 B | 6,118 B |
| runtime | 7,854 B | 5,576 B | −2,278 B | 5,341 B |

Main-line creation code keccak256: `0x4e91a70f59e4d6fe2d4b2c22e368099de91aa55046b7317890660d6ae9caf46c` (`vectors/creation-code.hex`).
Deployment-optimal combination only: `0xf0498c66f424d55c7f9d2e49ac8460fb48105005f4ed603bebe39ac5a6d86598` (branch `variant/no-swar`, commit 6e5bf32).

The TAP draft's "execute about 166k / 193k" is UniSat's measurement of transferring a real TapeOut circuit NFT on a BSC fork; that callee is much more expensive than the minimal ERC-721 here; the callee in this table does only one SSTORE.

## 2. Each optimisation

Numbers are GasBench (transaction measure; they differ from the receipts by a constant, and the differences agree with the receipts). Each step was committed separately, with the saving in the commit message.

| # | Commit | What changed | Measured | Risk: what could go wrong / what covers it | Recommendation |
|---|---|---|---|---|---|
| O1 | a36afaf | `scriptPubKey` is no longer written into storage; the getter rebuilds it from immutables | Deployment P2TR −72,955, P2WPKH −28,565; calls within ±50 | The getter must return exactly the same bytes; the nonce moves from slot 1 to slot 0 (the storage layout is not part of the TAP interface; any external tool that reads slot 1 directly will read the wrong value). Differential: constructor fuzz test comparing `scriptPubKey()`, `nonce()`, `supportsInterface`; raw-calldata fuzz test | Adopt (requires changing TAP §3.2) |
| O2 | 06d48e5 | Both messages are written sequentially into one buffer, with assembly writers for hex/decimal; `keccak256(data)` is computed only once | `isValidSignature` P2TR −25,849, P2WPKH −25,866; `execute` P2TR −41,646; deployment −133,270 | If the message differs by even one byte, all signatures become invalid (a usability risk; it cannot make another message be accepted). The writers write past the current position, into scratch space after the free pointer (stated in code comments). Covered by: byte-by-byte message differential 200,000 runs (random holder address, chain id, all uint values including the maximum), all vectors, bip322-js signatures, UniSat real-wallet signatures passing on the new code | Adopt |
| O3 | 88c2417 | to_spend, the BIP-341 signature message and the BIP-143 preimage are written with mstore into a fixed layout; sha_amounts, sha_sequences, sha_outputs, hashSequence and hashOutputs are precomputed as constants (4 fewer sha256); the holder applies the tagged hash to its own message in place | P2TR −6,776, P2WPKH −6,608; deployment −149,015 | A wrong constant or offset invalidates all signatures. `_messageHash` writes the tag into the two words in front of the message, which is safe only for messages produced by the builder (the builder leaves this space; stated in comments). Covered by: ConstantsTest checks each constant; upstream BIP-322 / BIP-340 vectors; library-level random message differential 200,000 runs | Adopt |
| O4 | ff69ec7 | The witness is read directly from calldata; strict DER parsing, public key, ecrecover and point address moved to assembly; no more byte-by-byte copying | P2WPKH −25,681 (static 46,421→20,740), P2TR −1,462; deployment −244,935 | If the parser became lax (accepting negative numbers, non-minimal encodings, high s, wrong lengths), that would be malleability and a violation of §6.1; out-of-bounds calldata reads return 0 instead of reverting. Covered by: re-encoding differential of valid signatures (negative, non-minimal, double zero, high s) 200,000 runs, structured random witnesses 200,000 runs, vector signature mutations (bit flip, truncate, extend, insert, delete, length byte) 200,000 runs, upstream invalid vectors | Adopt |
| O5 | 55a37b0 | **Security fix**: copy `data` into memory before the gas floor check | `execute` +232, deployment +9,551 | Baseline: with 16,000 / 24,000 bytes of data the callee gets 1,792 / 5,174 gas less (baseline rows of GasFloorTest); after the fix 0 at all sizes. Property test: a minimum-gas relayer and a relayer giving 30M make the callee see exactly the same gas, fuzzed 50,000 runs (callGas 30k–3M, value 0/1, data 0–24,000 bytes). The only observable difference is where `InsufficientGas` triggers; with enough gas the results are identical | **Adopt** (the specification text already promises this; no rule needs to change) |
| O6 | e222f16 | Hex conversion 16 bytes at a time (SWAR: spread nibbles, add 0x30, add 0x27 more if above 9) | `isValidSignature` −4,957, `execute` −6,782; but runtime +235 B, deployment +50,007 | Same as O2; SWAR writes a full 64 bytes (stated in comments). Coverage same as O2 | **Conditional**: pays off only if a holder makes more than about 10 `isValidSignature` or 7 `execute` calls in its life; a holder used once costs more. If first-time-user subsidy dominates, choose "deployment-optimal only" |
| O7 | 5c103b9 | `unchecked` where wrap-around is proven impossible (P2WPKH witness parsing, P−y in lift_x, N−x in BIP-340) | Deployment −27,366 (−124 B), P2WPKH −177, P2TR −72 | Proofs are in comments: all are sums of calldata lengths and bytes, or the operand is already below the modulus. `callGas * 64` and `nonce + 1` stay checked: the former must revert with Panic(0x11) for a huge callGas (original test `test_callGas_huge_is_insufficient`) | Adopt |
| X1 | Not committed | BIP-341 sha_scriptpubkeys computed at construction and stored as an immutable | P2TR calls −241, runtime +12 B (deployment about +3k; P2WPKH holders only pay, never gain) | — | Reject: gain too small, breaks even only after about 12 calls |
| X2 | Not committed | Use `mload` for the second use of the tag constant instead of pushing 32 bytes again | **0**: bytecode identical; the optimiser already reuses it | — | Not needed |
| C1 | Measured only | Compiler `optimizer_runs` | runs=1: runtime −42 B (deployment −9k), each call +110–220; runs=1000: +564 B (+116k), calls −80; runs=10,000: +1,489 B, calls about −360 | — | Keep 200; runs=1 is an optional small deployment optimisation |
| C2 | Measured only | Turn off via_ir | Compilation fails (stack too deep, `execute` has too many parameters) | — | Not feasible |
| C3 | Measured only | `evm_version = cancun` | runtime −29 B | Requires every chain to support cancun (X Layer would need to be confirmed first) | Not adopted |

Baseline measurement before O5 (GasFloorTest, callGas 1,000,000, value 0):

| data bytes | 0 | 1,000 | 4,000 | 8,000 | 16,000 | 24,000 |
|---|---:|---:|---:|---:|---:|---:|
| Baseline: gas the callee is short | 0 | 0 | 0 | 0 | 1,792 | 5,174 |
| After the fix | 0 | 0 | 0 | 0 | 0 | 0 |

## 3. Security and equivalence evidence

**Definition of "same result"**: at the same address, in the same state, with the same input, both sides have the same success/failure, return or revert data (including selector and arguments), events (emitter, topics, data), nonce, holder/target/sender balances and target contract state. Gas is the only quantity allowed to differ. When the outer gas is tight (20k–620k): if the baseline succeeds or fails for a non-gas reason, the optimised version must be exactly the same; if the baseline fails because of gas (empty revert data, `InsufficientGas`, `TipFailed`) and the optimised version gets further, the baseline rerun with 15 million gas must be exactly the same as the optimised version.

How: each time, the baseline creation code (frozen in `test/baseline/BaselineCode.sol`, keccak matching TAP §3.2) and the current source each run their constructor at the same address and install their runtime code, with the state restored from a snapshot in between. P2WPKH is signed with `vm.sign`; P2TR takes the point with `vm.createWallet` and computes s per BIP-340, with the signature hash from the frozen baseline library, so every fuzz run produces a real valid signature.

| Test | Runs (main line 5c103b9) | Result |
|---|---:|---|
| `testFuzz_diff_execute` (9 kinds of target, value, tip, callGas boundary values, deadline, wrong nonce, EOA/contract relayer accepting or refusing the tip, nested execute, two in a row, tight gas) | 200,000 | No difference |
| `testFuzz_diff_isValid_p2tr_signed` / `_p2wpkh_signed` (fresh keys, random digest and chain id, optional mutation) | 200,000 each | No difference |
| `testFuzz_diff_isValid_p2wpkh_encodings` (negative, non-minimal, double zero, high s) | 200,000 | No difference |
| `testFuzz_diff_isValid_vector_mutated` / `_structured` | 200,000 each | No difference |
| `testFuzz_diff_library_random_messages` (messages of any length, library level) | 200,000 | No difference |
| `testFuzz_diff_messages` (signMessage / callMessage byte for byte) | 200,000 | No difference (the first run stopped at 126,339 runs because `vm.assume` rejected too many; changed to derived addresses and rerun) |
| `testFuzz_diff_raw_calldata` (random calldata for every entry point, with/without value) | 200,000 | No difference |
| `testFuzz_diff_constructor` | 200,000 | No difference |
| Vectors: 23 signature cases, 4 call cases, 13 constructor cases, 12 bip322-js signatures, upstream BIP-322/340 | Deterministic | No difference |
| `testFuzz_floor_minimal_relayer_forwards_callGas` | 50,000 (once); 2,000 routinely | Pass |
| Differential suite at each optimisation commit | 10,000 each | No difference |

- All tests: 156 pass (original 117 + 39 new), run after `forge clean && forge build --force`. Only two changes in the original test files: `GeneratedVectors.sol` regenerated by `make_vectors.py`; `WalletUnisat.t.sol` now first checks that the address the wallet signature is for really is the CREATE2 address of the baseline creation code, and then installs the current code at that address to verify (real-wallet signatures cannot be redone without the extension).
- Validity of the differential tests themselves: 9 defects were injected deliberately and 7 were caught (event nonce, decimal, hex, P2WPKH odd y, negative DER, high s, NoCode length); the 2 missed were the BIP-340 e == 0 check (probability 2^-256, unreachable) and the gas reserve when value is non-zero (differential tests cannot catch it; covered by GasFloorTest).
- Three-way check of the vectors: `make_vectors.py` is deterministic for the same build (rerunning leaves git unchanged). The baseline and final `vectors.json` have exactly the same structure; the parts that contain no address, such as upstream, constructorCases and tap11Delegation, are byte-identical; the 23 + 4 messages are byte-identical after substituting the holder address (and the hash of data that contains the address), and so are the 12 bip322-js messages; signatures, witnesses and wallet outputs differ only because the messages contain the address. bip322-js Schnorr signatures use random aux and change on every regeneration, independent of the code. The reference implementation (`tools/btc.py`) checked every vector, bip322-js and `tools/cli.py` check each other, and the contract tests check once more.

## 4. Clone approach (measured only, `contracts/test/lab-clone/`)

Design: `HolderImpl` is the current holder logic, with the key read via EXTCODECOPY from the end of the code of the clone that calls it; each holder is a 45-byte ERC-1167 proxy + scriptPubKey (67 / 79 bytes in total); the clone's 68-byte creation header refuses value and STATICCALLs `checkScript(spk)`, so an unsupported script fails with `UnsupportedScript()` as in the constructor. The implementation itself is also deployed through the deterministic deployment proxy, so its address depends only on its creation code; a clone's address depends only on the implementation address and the scriptPubKey.

| | Main-line holder | Clone |
|---|---:|---:|
| Shared implementation deployment (once per chain) | — | 1,313,494 |
| Deploying one holder P2TR / P2WPKH | 1,254,619 / 1,252,342 | 80,741 / 73,366 |
| Each `isValidSignature` / `execute` | — | +2,958 to +3,068 (cold DELEGATECALL 2,600 + copying calldata and return value + reading parameters) |
| Break-even | — | The clone is cheaper for each holder within about 390 calls |

On all 23 baseline signature vectors, the clone gives the same results as the baseline bytecode.

Trust trade-off (in three sentences): the clone replaces "each holder is a self-contained, immutable piece of bytecode" with "all holders DELEGATECALL the same immutable implementation". A defect in the implementation affects all holders, as it does today, but DELEGATECALL appears in holder code for the first time, and the review surface gains two points: the correctness of the implementation address, and "the implementation never contains SELFDESTRUCT/DELEGATECALL" (on shanghai chains SELFDESTRUCT still deletes code). Whether a holder can be used on a chain depends on whether the implementation has been deployed on that chain (anyone can deploy it from the fixed bytes, and its address is determined by the creation code, so it cannot be impersonated); in addition, a 2,300-gas stipend transfer (Solidity `send`/`transfer`) to a clone fails, while the main-line holder can receive it (test `test_clone_rejects_stipend_transfers`). The TAP would have to rewrite §3.2 and §4: specify the implementation's creation code and address, the bytes of the clone creation header and runtime template, the parameter layout, and the new address formula (the init code becomes the clone creation code).

## 5. What has to change on adoption

- TAP §3.2: byte count 8,980 → 6,353 (or 6,118), keccak replaced with the value in §1; `assets/.../creation-code.hex`, `vectors.json`.
- The holder addresses in the TAP §5.2 example message and in Test Cases: P2TR `0xee27…31b8` → `0x6219e33529b42b40470b70290412656b6c5920af`, P2WPKH `0xa0b8…6d41` → `0xf04d59de794b53136db8328c45eb4a91bafade29` (main line 5c103b9; another combination gives other addresses).
- The TAP "Measured cost" paragraph: use the numbers in §1.
- `tools/wallet-lib-check/results.json` (already re-signed at each commit, see the individual commits); the example addresses in the README and the Chinese draft.
- **The UniSat real-wallet vectors need to be re-signed with the extension** (state on 2026-10-10; the procedure in `interop/unisat-extension/README.md`, which needs the extension downloaded from the Chrome store); until then, the lab repository's tests only prove that the old signatures are still valid on the new code (placed at the old address).
- Normative rules, interface table, events, errors: none need to change. O5 makes the implementation meet the promise already made in §6.3 step 5.

## 6. What could not be done, what is not explained, and pitfalls

- **Incremental forge builds can miss recompilation**: when only `src/` changes, test contracts that embed `type(BitcoinKeyedHolder).creationCode` are sometimes not recompiled, so the differential tests compare old bytecode with the baseline (this produced false negatives in the defect-injection experiment). All numbers and test conclusions were obtained after `forge build --force` (the last time after `forge clean`); any verification in this repository must do the same.
- In the first version of the differential test, the call cases accumulated a hash in a memory array across snapshots; the field-by-field printouts of both sides were exactly the same, but the accumulated hashes differed; the cause was not found, and after switching to field-by-field comparison the test passed. Recorded as an observation.
- The "minimum outer gas" that `GasFloorTest` finds by bisection is not monotonic in the data length (1,000 bytes needs a few thousand less than 0 bytes); this does not affect the conclusion (at the boundary found, the callee gets the same gas as with a generous relayer), but whether there are isolated success points below the boundary was not exhausted.
- Compilation fails with via_ir turned off; an intermediate state of the BIP-340 tagged hash cannot be used (the sha256 precompile does not accept an intermediate state), so only the full hash can be precomputed.
- No re-signing with a real wallet (needs the browser extension); no transaction on a public network; anvil was run only locally and shut down by PID afterwards.

## 7. Further ideas not pursued (estimates)

| Idea | Expected | Why not done |
|---|---|---|
| Hand-written calldata decoding instead of the ABI decoder (`execute` has 7 parameters) | −300 to −400 per call, runtime about −300 B (deployment −60k) | It must reproduce, case by case, how the ABI decoder reverts on malformed input (such as dirty high bits in `uint64`); a raw-calldata differential could cover it, but the review burden is large |
| Write the whole verifier as a few pieces of assembly to cut bytes | runtime another 10–20% less (deployment −100k to −200k) | Limited gain, high review cost |
| P2WPKH with only one ecrecover (recover R and compare x) | About 0 on average: saves the second ecrecover, 1,500 on average, but needs one more modexp for the inverse (1,349) and one lift_x | Calculated as not worth it; it would also reject public keys with x ≥ n (probability 2^-128) |
| Write the nonce as non-zero at construction | First `execute` −17,100, deployment +22,100 | Only moves cost from the first call to deployment; the first-time user's total does not fall |
| Merge tip, event and nonce into one slot write | 0 | There is only one storage slot; already minimal |
| `optimizer_runs = 1` | Deployment −9k, each call +110–220 | See C1; marginal |
| Clone approach | Single holder deployment −1.17 million, each call +3,000 | Changes the trust model and the address formula; see §4 |

## 8. Reproduce

```
cd contracts
forge clean && forge build --force
forge test                                                        # 156 tests
forge test --match-contract DifferentialTest --fuzz-runs 200000   # about 3 minutes (10 cores)
forge test --match-contract GasBench -vv                          # standard cases
forge test --match-contract GasFloorTest -vv                      # gas floor gap, baseline and current
forge test --match-contract CloneBenchTest -vv                    # clone approach
python3 ../tools/make_vectors.py                                  # after forge build; the result should match what is committed
```
