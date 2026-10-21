*Working note, translated from the author's Chinese original; dated entries describe the state on that date.*

# Merge notes: gas-optimised build + `executeBatch` (holder-final-lab, 2026-10-10)

> **After the review (second round, same day)**: after an adversarial review organised by the author (not a third-party audit; no Critical/High/Medium, 1 Low, 6 Info), another round of changes was made; see §8. Current creation code 7,869 bytes, keccak `0x4bc9698ad9224fefccd7ba5d7205c1c0e8e9117eb53257873e64fae37f499c4f`, 200 tests. §1–§7 below describe the first round; the creation code, addresses and test counts in them are superseded by §8. For the merge into the main repository, the real-wallet re-signing and the final test count (204), see §9.

## Conclusion

- **One contract, one creation code, one holder address per Bitcoin address**: `contracts/src/BitcoinKeyedHolder.sol` has both `execute` and `executeBatch`. Creation code 7,985 bytes, keccak `0x40798cfa8961e0506faaae1df8ec4585d9a262180bfe30ece77de42153cfcc0f` (numbers in `docs/FINAL-GAS.md`).
- **The single-call path is unchanged**: relative to the gas lab's `variant/no-swar` (6e5bf32), not one line of the single-call path in the source changed (`git diff 6e5bf32 -- contracts/src` shows only additions and two comment lines); the differential tests against the frozen draft-baseline creation code, 10 fuzz tests at 200,000 runs each, all pass (`scripts/logs/final-tests/fuzz-200k-differential.log`). Three documented adjustments were made to the differential tests for this (§2.2).
- **The batch path matches the batch lab, with one change**: differential tests against the frozen batch-lab creation code (fc8864b, keccak `0x6bad…60dc`), 200,000 runs each for `executeBatch` and `batchMessage`, show no difference; the 6 batch signatures that the UniSat real wallet made for the batch-lab address all pass on the merged code.
- **A defect in the batch specification was found and fixed**: the batch lab copied `data_i` into memory only **after** each call's gas check (the same defect as the single-call one fixed by gas-lab O5), so a relayer giving the minimum gas could make the callee receive less gas: for one call with `data` of 16,000 / 24,000 bytes, **2,301 / 5,711 gas** less; the merged build copies all call data first, and the shortfall is **0** at all sizes (`BatchGasFloorTest`). The specification makes this a normative requirement in §6.3 step 5 and §6.4 (§3).
- **Everything else in BATCH-SPEC is unchanged**: signed text, selectors, errors, all or nothing, one nonce, the Σneed pre-check and the per-call checks, the tip paid once, events, the limit of 1–8 calls, callGas < 2^64.
- **194 tests pass from a clean build** (original 117 + gas lab 39 + batch lab 31 + 7 new); batch fuzzing of the signature path 200,000 runs, injectivity 100,000 runs (§5).
- **Still blocking adoption (state on 2026-10-10, first round)**: the UniSat real wallet has to re-sign 10 texts for the new addresses (needs the browser extension; listed in a re-signing checklist, not included); the batch part and the new assembly concatenation need an independent audit; TapeAPI interop (`interop/run.sh`) and the mining demo have not been rerun with the new build (§7). [Resolved later in this note: §9 records that the real-wallet re-signing was done on 2026-10-10 and that the TapeAPI interop and mining demo were rerun with the current build. The reviews that followed (§8 and `docs/AUDIT-2026-10-13.md`) were organised by the author, not independent audits.]

## 1. What changed in the contract

| Location | Content |
|---|---|
| `struct Call { address target; uint256 value; bytes data; uint256 callGas; }` | Defined in `BitcoinKeyedHolder`; ABI type `(address,uint256,bytes,uint256)`, so the selectors are the same as the batch lab's: `executeBatch` `0xc7826280`, `batchMessage` `0xba195d76`, `MAX_CALLS` `0xb9add4b7`, `MAX_CALL_GAS` `0x2ed55b1f` |
| `MAX_CALLS = 8`, `MAX_CALL_GAS = 1 << 64` | Public constants, kept in the interface (BATCH-SPEC's interface table has them; removing each saves about 30 bytes, but that would be a specification change) |
| Errors `BadBatch()`, `BatchCallFailed(uint256,bytes)` | Same as the batch lab |
| `batchMessage(...)` | `external view` (the lab had `public`, same ABI). First computes the keccak of each `data_i` into a memory array, then writes the whole text into one buffer with the single-call path's `_prefixAt` / `_decAt` / `_hexAt` and literal `mstore`s (`_batchMessage`) |
| `executeBatch(...)` | See the order below |
| `_need(callGas, value)` | The formula of §6.3 step 5; `unchecked`, because callGas < 2^64 is guaranteed before the call (64/63 times plus 37,100 is far below 2^256) |
| `nonce` | Slot 0 (gas lab O1); comment changed to "number of successful `execute` and `executeBatch` calls" |

Order of `executeBatch`:
1. `Expired()`; 2. count not in 1–8 → `BadBatch()`;
3. In one loop: `callGas_i ≥ 2^64` → `BadBatch()`, accumulate Σneed, **copy `data_i` into memory** (`bytes[] inputs`), and compute the keccak from the memory copy (`bytes32[] hashes`);
4. Build the §5.3 text from `hashes` and verify the signature, otherwise `BadSignature()`; 5. `nonce = n + 1`; allocate `rets`;
6. Gas left < Σneed → `InsufficientGas()`;
7. Per call: `inputs[i]` not empty and target has no code → `NoCode()`; gas left < need_i → `InsufficientGas()`; `call{gas: callGas_i, value: value_i}(inputs[i])`, on failure → `BatchCallFailed(i, ret)`;
8. Tip; 9. `emit Called(n, target_i, value_i, hashes[i])` in order, return `rets`.

**Two hazards in how this is written, and how they are avoided:**
- `_messageHash` writes the BIP-322 tag into the two words in front of the message (the length word and the empty word the concatenator leaves), which is safe only for messages that start with `_prefixAt` and end with `_allocate`. So the batch text **cannot** be built with `abi.encodePacked` and handed to `_verify` (that would overwrite other memory in front of the message); only the writer can be used. This is also the answer to the brief's "use the writer where it is safe": here only the writer can be used.
- The free memory pointer does not move during writing, so the loop must not contain anything that allocates memory or uses `mload(0x40)` as scratch space (`keccak256(calldata slice)` and `_keccakCalldata` both write there). Therefore all data hashes are computed before the buffer is opened; the loop only reads calldata fields, reads `hashes[i]`, runs the writer and does literal `mstore`s.

## 2. Deviations from the two labs (item by item)

### 2.1 Relative to the batch lab (holder-batch-lab fc8864b / 5977119)

| # | Change | Reason | Evidence |
|---|---|---|---|
| B1 | **Copy all `data_i` before any gas check** (the lab copied via `call(c.data)` after the check of step 7.2) | The lab's code breaks "each callee receives at least callGas" (§3) | `BatchGasFloorTest`: lab, 1 call of 16,000 / 24,000 bytes, short by 2,301 / 5,711; merged build 0; merged-build fuzzing 1,000 runs (1–4 calls, callGas 30k–1M, with and without value, 0–24,000 bytes per call, callee exhausting gas or not) all 0 |
| B2 | The text is built with the assembly writer (the lab used Solidity `abi.encodePacked` + `_hex`/`_dec`) | Gas: 8-call batch 542,002 → 271,187 | `testFuzz_lab_batchMessage` 200,000 runs byte-identical (each field random up to 2^256−1, random chain ID, 0–99 bytes of data, 0 and 9 calls both give `BadBatch`); 17 Python vector sets; 6 UniSat real-wallet signatures; 34 bip322-js signatures |
| B3 | The data hash is computed once, and the event uses the same value | K fewer keccak computations | Events byte-identical (`testFuzz_lab_executeBatch` compares logs) |
| B4 | Subclass → one contract; nonce in slot 0 | The brief asked for one creation code; O1 | The "longest text" test of `WalletUnisatBatch` changes the `vm.store` slot from 1 to 0 |
| B5 | `batchMessage` changed from `public` to `external` | It is no longer called internally | ABI and selector unchanged |
| B6 | Internal order: copying and hashing are in the loop of step 3 | Consequence of B1 | Gas is observable only for well-formed calldata; malformed ABI input reverts on both sides, but which revert happens first and what the revert data is were **not compared** (`testFuzz_malformed_calldata` only requires failure with the nonce unchanged) |

The only substantive change to the specification text is the sentence that corresponds to B1 (§3). `docs/BATCH-SPEC.md`, `BATCH-REPORT.md` and `BATCH-UX.md` are historical files copied unchanged from the batch lab; the specification is now `TAP-draft-bitcoin-keyed-holders.md`.

**Ported tests** (`contracts/test/batch/`): `Batch.t.sol` 24 original tests + 1 new test `test_vectors_bip322js`; `BatchFuzz.t.sol` 3 (100,000 runs each, inline config); `WalletUnisatBatch.t.sol` 2; `CompactLab.t.sol` 1. Changes:
- `test_vectors_creation_code_and_addresses`: used to assert "the batch holder and the draft holder have different bytecode"; now asserts that the keccak of the batch vectors is the keccak of the single contract.
- `WalletUnisatBatch`: the real wallet signed texts for the batch-lab address. The test first asserts that the recorded address is the CREATE2 address, through the proxy, of the frozen batch-lab creation code (`test/batchlab/BatchLabCode.sol`), then runs the merged constructor there and installs the merged runtime to verify (the same approach the gas lab used for the single-call UniSat vectors); nonce slot changed to 0.
- `CompactLab.sol` (the lab's measurement prototype, **not proposed**): the base class's `callMessage` is now `external`, so the prototype calls `_callMessage(..., keccak256(data), ...)` instead; it keeps the lab's `execute` code of that time (copy after check), as its comment says. It is counted among the 31 ported tests only because the brief named those 30.

### 2.2 Relative to the gas lab (holder-gas-lab variant/no-swar 6e5bf32)

The single-call source is unchanged (end of §1). Three test adjustments, all in `contracts/test/diff/Differential.t.sol`:
1. **Random-calldata differential**: the fuzzer collects constants from the bytecode and vectors and uses real `executeBatch` calldata as input. The draft baseline has no such function (empty revert), while the merged build reaches signature verification (`BadSignature`). This is a new feature, not a difference: for any input whose first 4 bytes are one of the four new selectors, the test now only asserts that the baseline rejects with empty data and does not compare further (`isNewEntry`). The first 200,000-run attempt hit this (the counterexample input was exactly a piece of `executeBatch` calldata).
2. **"Holder calls itself" in the `execute` differential**: likewise, if the random data happens to be a call of a new function, it is replaced with empty data.
3. **"Generous gas" was not generous enough**: the original test used 15M outer gas as "generous", but callGas itself can come close to 15M (this time run 134,668 drew 14,625,579), so the side with less gas passed the check and then ran out after the call, while the other side stopped at the check: both are correct, but the test reported a difference. Now, for callGas ∈ [10M, 2^64), 60M is given; the counterexample is kept as the regression test `test_diff_execute_callGas_near_outer_gas` (it fails without the change and passes with it; both were actually run). This weakness was already in the gas lab's tests; the main line's 200,000 runs not drawing it was luck.

### 2.3 Original (draft) tests

Only two files differ from the draft, both because of the addresses: `GeneratedVectors.sol` is regenerated by `make_vectors.py`; `WalletUnisat.t.sol` keeps the gas lab's change (check that the recorded address is the address of the baseline creation code, then install the current code there), not changed again this time. The other Audit*/Holder/Secp256k1Ref tests are untouched and all pass.

### 2.4 Tools and vectors

- `tools/holder.py`: `batch_message`, `parse_batch_message` (from the batch lab); `batch_creation_code` removed (there is only one artifact); `tools/cli.py`: `batch-message` and `execute-batch-calldata` compute addresses from the main artifact.
- `tools/make_batch_vectors.py`: writes `contracts/test/batch/GeneratedBatchVectors.sol`; if `tools/wallet-lib-check/results-batch.json` exists, it checks each bip322-js 4.0.0 signature with the Python verifier and writes it into the vectors (`libSig`), and the tests use them to execute every batch.
- `tools/wallet-lib-check/sign-batch.mjs`: now writes `results-batch.json`; `scripts/regen_vectors.sh` rebuilds all vectors in dependency order (forge build → sign.mjs → make_vectors → make_batch_vectors → sign-batch.mjs → make_batch_vectors → forge build). Rerunning the two Python generators on the same results gives no git difference (deterministic). bip322-js Schnorr signatures use random aux, so they change on re-signing, independent of the code.
- A helper script that produces a re-signing checklist (not included in this submission): it rebuilds each old text from the two real-wallet JSON files and checks it byte for byte, then computes the 10 texts to re-sign for the new addresses (texts whose data contains the holder address are replaced as well). **No signature was fabricated.**
- The packaging script `scripts/make_tap_package.py` gains an optional draft path argument (`TAP-draft-bitcoin-keyed-holders.md`), and packs the batch vectors and the re-signing checklist into assets; it was actually run with both the original draft and the merged draft.

## 3. Reconciling the O5 specification text with the batch gas floor

The problem: §6.3 step 5 (and step 7.2 of BATCH-SPEC's §6.4) says "if the gas left is not less than need, the callee receives at least callGas". This reasoning holds only if **no cost that grows with the data length remains between the check and the call**; EVM memory expansion is quadratic, and in a batch memory grows with each later call, so the problem gets worse. Both the draft and the batch lab placed the copy after the check.

What the merged build does: in execution order, all `data_i` are copied into memory before step 6 (Σneed); between step 7.2 and the CALL only constant work remains (reading the array; EXTCODESIZE was already done in 7.1; the CALL itself no longer expands memory; return data is copied only after the call).

Specification text (already written into `TAP-draft-bitcoin-keyed-holders.md`):
- At the end of §6.3 step 5: "The holder **MUST** make this check when nothing whose cost depends on `data` remains to be done before the call: in particular, `data` is already in memory (the copy and the memory it takes grow with the length of `data`). The callee therefore receives at least `callGas`."
- After the steps of §6.4: "The holder **MUST** make the checks of steps 6 and 7.2 when nothing whose cost depends on any `data_i` remains to be done before the call, as in §6.3 step 5: in particular, every `data_i` is already in memory before step 6."
- Security Considerations gets an entry "The gas check before a call", stating the measured shortfall of the old bytecode (about 1,800 / 5,200).

Why "copy everything before step 6" and not "copy each call before 7.2": the latter also protects each callee, but then the Σneed pre-check is no longer "a lower bound computable from the signed values alone" (the copy cost would fall after the pre-check and be required again by each per-call check); copying once up front makes both checks depend only on the signed values, at the cost of 8 copies in memory at the same time (Solidity does not free memory anyway, so there is no extra cost).

Measured (`BatchGasFloorTest.test_batch_floor_shortfall_by_data_size`, callGas 1,000,000, value 0):

| Data bytes per call | 0 | 1,000 | 4,000 | 8,000 | 16,000 | 24,000 |
|---|---:|---:|---:|---:|---:|---:|
| Batch lab, 1 call: max shortfall for the callee | 0 | 0 | 0 | 0 | **2,301** | **5,711** |
| Merged build, 1 call | 0 | 0 | 0 | 0 | 0 | 0 |
| Batch lab, 4 calls (callee exhausts gas) | 0 | 0 | 0 | 0 | 0 | 0 |
| Merged build, 4 calls (callee exhausts gas) | 0 | 0 | 0 | 0 | 0 | 0 |

With 4 calls the lab also shows no shortfall, because the 64/63 margins of the earlier calls accumulate and cover the copy cost; the defect appears in the tightest case (the first or only call, large data), so the 1-call row is the counterexample.

## 4. Equivalence rules for the differential tests (stated first; the tests assert them)

- **(i) Single-call path vs draft baseline** (the gas lab's `DifferentialTest`, keeping its rules): same address, same state, same input; success or failure, return or revert data, events, nonce, balances and target state are all the same; when the outer gas is tight, the side that uses less gas may get further, and then the other side must match when rerun with generous gas. Adjustments in §2.2.
- **(ii) A one-call batch vs `execute`** (`BatchVsExecuteTest`, same merged code, each with its own signature):
  - One succeeds if and only if the other does; on success the logs (the same `Called` and the callee's logs), nonce, holder/relayer/target balances and target state are the same; `execute` returns R, `executeBatch` returns [R].
  - On failure neither side changes anything, and the revert data is either the same holder error (`Expired`, `BadSignature`, `NoCode`, `InsufficientGas`, `TipFailed`), or, when the callee fails with R, `execute` reverts with R and `executeBatch` with `BatchCallFailed(0, R)`.
  - callGas ≥ 2^64: `executeBatch` must revert with `BadBatch` (or `Expired` first), and `execute` must also fail.
  - When the same mutation is applied to two different signatures, it may be a no-op for one of them (setting a byte to the value it already has); in that case neither side is mutated (the first 200,000-run attempt hit this at run 2,450).
  - When the outer gas is tight (a third of the runs), the side that failed because of gas (empty revert, `InsufficientGas`, `TipFailed`, `BatchCallFailed(0, "")`) is rerun with 15M and then compared; the two sides use different amounts of gas anyway, so where each one runs out is not compared.
- **(iii) Batch properties** (`BatchInvariantsTest`): see the comment at the top of `contracts/test/batch/BatchInvariants.t.sol`. A failure changes nothing and the error is one of those listed in the specification, and the index of `BatchCallFailed` is within the batch; an unmutated signature at the correct nonce, before the deadline, with compliant callGas never gives `BadSignature`; a mutated signature or a wrong nonce never succeeds; on success: one nonce, the tip paid exactly once to `msg.sender` (plus that call's amount if the relaying contract is also the target of one of the calls; the first 200,000-run attempt hit this accounting issue at run 446, and it was a problem in the test), the holder spends exactly the stated amounts plus the tip, K `Called` events in order with the same nonce, K return values, no replay; swapping two different calls, deleting the last call or adding a call makes the same signature be rejected.
- **(iv) Batch path vs batch lab** (`BatchLabDiffTest`): with generous gas everything is the same; with tight outer gas the side that failed because of gas is rerun. When the holder calls itself, only 0–2 bytes of data are used: adding a real function call (such as a nested `executeBatch`) together with a finite callGas would amount to comparing how much gas each code uses. The first 200,000-run attempt showed exactly that difference here ("the lab runs out of gas in the inner call, the merged build reaches signature verification"); it is an expected gas difference, not a semantic one.

## 5. Test counts and runs

| Suite | Tests | Notes |
|---|---:|---|
| Original draft tests (Audit*, Holder, WalletUnisat, etc.) | 117 | Unchanged (except the regenerated vectors) |
| Gas lab (diff, GasBench, profile, lab-clone, Constants, GasFloor) | 39 + 1 | The +1 is the regression test of §2.2 |
| Ported from the batch lab (Batch 25, BatchFuzz 3, WalletUnisatBatch 2, CompactLab 1) | 31 | `test_vectors_bip322js` among them is new |
| New: BatchInvariants 1, BatchVsExecute 1, BatchLabDiff 2, BatchGasFloor 2 | 6 | |
| **Total** | **194** | `forge clean && forge build --force && forge test`: 194 passed, 0 failed (`scripts/logs/final-tests/forge-test-full.log`) |

Fuzz runs: default 512; inline config: the 3 BatchFuzz tests 100,000 each, Batch random calldata 20,000, random signatures 5,000, batch gas floor 1,000, single-call gas floor 2,000. In addition, run separately with `--fuzz-runs 200000`: the 10 fuzz tests of `DifferentialTest`, `BatchInvariantsTest`, `BatchVsExecuteTest`, and the 2 of `BatchLabDiffTest`, all passing at 200,000 runs (logs in `scripts/logs/final-tests/`). These cover the brief's requirement of "signature path ≥ 200,000, injectivity ≥ 100,000".

Independent signers: `bip322-js` 4.0.0 and 3.0.0 signed the new holders' §5.1/§5.2 messages (`results.json`; the vectors include 12 signatures from 4.0.0) and 17 §5.3 messages plus the longest 2,239-character text; 38/38 were accepted by the Python verifier, and all were rejected after changing one character (`sign-batch.log`); the contract tests executed all 17 batches with the 4.0.0 signatures.

## 6. Files

- Regenerated: `vectors/vectors.json`, `vectors/creation-code.hex`, `vectors/batch-vectors.json`, `contracts/test/GeneratedVectors.sol`, `contracts/test/batch/GeneratedBatchVectors.sol`, `tools/wallet-lib-check/results.json`, `results-batch.json`, `sign-batch.log`.
- Not changed, and must not be changed: `vectors/wallet-unisat-1.7.22.json`, `vectors/wallet-unisat-1.7.22-batch.json` (real-wallet output, for the old addresses; the tests install the merged build at those addresses to verify).
- Frozen: `contracts/test/batchlab/BatchLabCode.sol` (compiled from a copy of the batch-lab source in a temporary directory, keccak matching its report; nothing was written in that repository).

## 7. What still blocks adoption (state on 2026-10-10, first round)

1. **UniSat real-wallet re-signing**: 10 texts (2 addresses × §5.1, §5.2, three batches), which must be signed with the browser extension; a re-signing checklist (not included) listed the original texts and the next steps. The Test Cases of the merged draft carry an explicit editor's note. [Resolved later in this note: §9 records that the re-signing was done on 2026-10-10.]
2. **Independent audit**: of the batch part (about 170 new source lines, including the new assembly concatenation and the Σneed pre-check). The gas lab's optimisations were covered by differential tests, but a differential test only proves "same as the old code", not that the old code itself is correct. [Later in this note: §8 records an adversarial review organised by the author on 2026-10-10 (not a third-party audit); a second author-organised round followed on 2026-10-13 (`docs/AUDIT-2026-10-13.md`).]
3. **Demos not rerun with the new build**: TapeAPI interop (`interop/run.sh`, needs an SDK clone) and the mining demo (`scripts/mining/demo_mining.sh`); the merged draft states that they used an earlier build and that the single-call behaviour is proven identical by the differential tests. `scripts/demo_fork.sh` has been rerun on all three chains with the new build. [Resolved later in this note: §9 records that the TapeAPI interop and the mining demo were rerun with the current build.]
4. **Long texts in wallets**: no wallet other than UniSat has been tested with messages above 644 characters; hardware wallets are untested. [Later in this note: §10 records tests of Xverse, Leather and OKX Wallet on 2026-10-11; hardware wallets are not covered there.]
5. **O6 trade-off**: see `docs/FINAL-GAS.md` §5; batching brings O6's break-even point down from 7–8 single calls to about 1.2 batches of 8; the author has to decide based on expected use.
6. **TAP text**: (in the first round the root draft was kept as it was and the merged draft was a separate copy; it has now been replaced, see §9.)

## 8. After the review (second round, from commit 187749d)

The review report is outside the repository (`holder-final-lab-audit/AUDIT.md`); the object of the review was ce9fb86. As requested, F-01 and F-02 were fixed, tests were added for F-04, and documentation was added for F-05, F-06 and F-07; F-03 (non-canonical init code can also deploy a working holder; the baseline behaves the same way) was not requested and remains unhandled.

### 8.1 What changed

| Finding | Change | Specification text |
|---|---|---|
| F-01 (Low) return-data amplification | `executeBatch` **no longer returns any data**; each call and the tip use `call(g, target, value, in, len, 0, 0)`, and on success **not one byte of return data is copied** | §3.1 interface row drops `returns (bytes[])`; §6.4 step 9 "Return nothing"; §6.4 adds **MUST NOT** copy the return data of a call that succeeds; **MAY** simulate with `eth_call` to obtain results; Rationale "The gas of a batch" rewritten |
| F-02 (Info) revert bomb | On failure only the first 256 bytes of revert data are copied, and `BatchCallFailed(i, first 256 bytes)` is ABI-encoded by hand at the free memory pointer; the memory the holder touches is at most 100 + 256 + 32 bytes | §3.1 error description and §6.4 step 7.3 state the truncation; **MUST NOT** copy more than 256 bytes of revert data |
| F-04 (Info) tests sign the contract's own text | `tools/make_text_corpus.py` writes, in Python, and signs the texts of 48 batches (1–8 calls, three variants each, 16 of them executable), 24 single calls and 8 digests; `TextCorpusTest` passes the signatures directly to `isValidSignature` / `execute` / `executeBatch` and requires them to pass verification (the executable ones must succeed), requires `BadSignature` after changing one signed value, and only at the end compares the view functions' text with Python | Test Cases gets an entry |
| F-05 (Info) `batchMessage` renders batches that cannot execute | No code change | §8 adds **MUST NOT** ask a user to sign a batch that `executeBatch` will refuse in any case; Security Considerations adds "Texts for batches that cannot run" |
| F-06 (Info) a front-run relayer's loss grows with the data | No code change (documentation only, as requested) | Security Considerations adds "What a relayer pays for": read `nonce()` before sending, use a private channel, ask a higher tip for batches with much data |
| F-07 (Info) documentation | `docs/GAS-REPORT.md` and `docs/GAS-PROFILE.md` copied unchanged from the gas lab's `main` (ff52eb9), with a provenance note | — |

**`execute` is not changed.** Today it returns the callee's return data (§6.3 step 8, also the draft baseline's behaviour), copied once: with a callee returning 200,000 bytes `execute` costs about 1,160,000 gas, with 0 bytes about 79,000 (measured by the review; remeasured in this round with the review's PoC on the new build, see §8.3). I chose not to change it, because: (1) its external behaviour (the return value) is part of the specification and of the differential equivalence proof, and changing it would mean giving up the strongest evidence, "the single-call path is byte-for-byte equivalent to the draft"; (2) it has only one copy, without the quadratic amplification of a batch's "k copies stacked", so the cost is of the same order as the callee's own cost of producing the data; (3) the minimal change (truncating the return value) also changes external behaviour. The cost is written into Security Considerations ("What a relayer pays for": a callee whose return size depends on state can make an `execute` that passed simulation fail on chain, and relayers should leave a margin). The tip call of `execute` is also kept as it is: it discards the return value, and even if the compiler copies the data the relayer returns, the size of that data is chosen by the relayer and the cost is borne by the relayer.

### 8.2 Numbers (details in `docs/FINAL-GAS.md`)

- Creation code 7,985 → **7,869** bytes, runtime 7,208 → **7,092** (less `bytes[]` encoding and return logic); deployment P2TR 1,629,559 → **1,604,415**.
- `isValidSignature` unchanged; `execute` unchanged (±10, the dispatcher's selector order changed).
- `executeBatch` 1/2/4/8 calls P2TR: 99,735 / 124,882 / 175,268 / 271,187 → **98,747 / 123,404 / 172,830 / 266,790**.
- 8 callees each returning 200,000 bytes (callGas 400,000 per call): before the fix 36,953,708 (measured by the review, ce9fb86) → after the fix see `docs/FINAL-GAS.md` §6 (the review's PoC remeasured on the new build); in-repository regression test `test_return_bomb_costs_the_holder_nothing`: 181,838 with 0 bytes returned, 939,128 with 200,000 bytes; the difference of 757,290 is exactly the roughly 95,000 that each of the 8 callees pays for its own 200,000 bytes of memory, and the holder itself spends nothing extra.
- A callee that reverts with 300,000 bytes (callGas 1,000,000): a relayer that gives "what the signature requires + about 225,000" gets `BatchCallFailed(1, first 256 bytes)` (`test_revert_bomb_truncated_to_256_bytes`, which also covers 0/31/255/256/257 bytes).

### 8.3 Corresponding changes to the tests and differential rules

- `Batch.t.sol`: `test_return_data_per_call` replaced by `test_no_return_data`; new `test_return_bomb_costs_the_holder_nothing` and `test_revert_bomb_truncated_to_256_bytes`; `test_earlier_call_creates_later_target` used the return value 42 to tell that the second call ran; now the created contract writes a storage slot that is then read back.
- `BatchVsExecuteTest`: on success `execute` returns R and `executeBatch` returns nothing; on failure `BatchCallFailed(0, first 256 bytes of R)`.
- `BatchLabDiffTest`: on success the merged build must return no data (the lab returns `bytes[]`, not compared); on failure the lab's `BatchCallFailed` data is truncated to 256 bytes before comparing.
- `BatchInvariantsTest`: on success the return data must be empty; the data of `BatchCallFailed` is at most 256 bytes.
- These four groups and the differential tests pass at 200,000 runs each on the new build (`scripts/logs/final-tests/fuzz-200k-after-audit.log`); the full suite from `forge clean && forge build --force` passes 200 tests (65 fuzz tests).
- The review's PoCs (`poc/contracts/*.t.sol`) were copied into a copy of the repository in a temporary directory and rerun against the new build; one line was changed only so that it compiles (`test_batch_calls_holder_itself` can no longer receive a `bytes[]` return value, so the assertion on the `scriptPubKey()` return value was removed). Results in `docs/FINAL-GAS.md` §6.
- `make_batch_vectors.py`: when the old `results-batch.json` does not match the new texts, it no longer aborts; it first leaves out the bip322-js signatures (the tests require them, so they cannot be silently missing), and takes them in on a second pass after `sign-batch.mjs` re-signs; `regen_vectors.sh` gains two steps, the text corpus and the re-signing checklist.

### 8.4 F-07: the "accumulated hash differs" observation in GAS-REPORT §6

Still **unexplained**. That version of the differential test was not committed and cannot be reproduced; the review checked the holder's assembly block by block and found no write to allocated memory, and the effect happened in the test contract's own frame (the holder has separate memory on every call). Possible causes (none confirmed): the memory array accumulated across `vm.revertToState` in the test interacting with the order in which `vm.getRecordedLogs()` is consumed, or fields in the accumulated hash that the field-by-field printout did not cover. The current differential tests compare field by field and do not rely on an accumulated hash, so this observation affects no conclusion.

### 8.5 What still blocks adoption (state after the second round, 2026-10-10)

The same as §7, plus: F-03 (the same key can deploy several working addresses with non-canonical init code) is not handled; if it is to be handled, the minimal approach is to state in §4 that only the address derived from the canonical init code is recognised. [Resolved later in this note: §9 records the re-signing and the demo reruns; see the pointers in §7.]

## 9. Merge into the main repository (tap-bitcoin-keyed-holders, branch final-gas-batch)

- All changes from the lab were applied as one commit to a new branch `final-gas-batch` of the main repository (main untouched); later changes were all committed on this branch.
- **Real-wallet re-signing is done**: on 2026-10-10 UniSat 1.7.22 signed all messages for the new addresses (for each address type 1 §5.1, 2 §5.2 and 3 §5.3 messages; 12/12 valid). The raw output is in `interop/unisat-extension/results/unisat-1.7.22-merged-*.json`; `tools/make_wallet_vectors.py` produces `vectors/wallet-unisat-1.7.22*.json` from it (each text rebuilt and compared, each output decoded under §6.1 and verified). The tests `WalletUnisatTest` and `WalletUnisatBatchTest` deploy the holders at the new addresses through the proxy and execute these signatures one by one; the real-wallet signatures for the old addresses moved to `vectors/legacy/`, and the corresponding tests were renamed `*LegacyTest` and kept (they show that the real-wallet signatures for the old addresses are equally valid on the merged verifier, at very low cost). The re-signing checklist was deleted, and the helper script that generated it now only checks whether the vectors match the current build, and produces a list only when they do not.
- The root `TAP-draft-bitcoin-keyed-holders.md` and its Chinese translation have been replaced by the merged draft (with the new real-wallet section and 204 tests), and `docs/TAP-draft-merged*.md` was deleted; `docs/TAP-CHANGES.md` now lists the changes relative to the main (3b82d4d) draft, with the full diff.
- TapeAPI interop (`interop/run.sh`), the mining demo (65/65), `scripts/demo_fork.sh` (BSC) and `interop/unisat-extension/fork_check.py` (the real-wallet signatures executing two batches, EIP-1271 and an `execute` of a real NFT on a BSC fork) were all rerun with the current build and pass.
- The review summary is in `docs/AUDIT-2026-10-10.md` (the full report is a separate file).

## 10. Wallet matrix (2026-10-11)

- The measurements of wallet-matrix-lab (d82a533) on Xverse 2.9.3, Leather 6.114.0 and OKX Wallet 4.18.1 were merged in: raw results in `interop/wallet-matrix/results/`; vectors `vectors/wallet-<name>-<version>.json` and `-batch.json` produced by `tools/make_wallet_matrix_vectors.py` (byte-identical to the lab's files). 6 TAP signatures per wallet per address type, 48 in total including UniSat, all tested on the merged contract (deployed at the CREATE2 address, `isValidSignature` valid and rejected after changing a byte or the digest, `execute` of a token transfer and of an empty call, three batches). 217 tests.
- The §6.1 decoding vectors (`vectors.json`) gain `walletRawOutputs` (the results as returned by the wallet APIs and the base64 strings handed to §6.1, including a 4,000-character probe), `walletBip137Default` (OKX's 65-byte BIP-137 signature when no type is specified, which the holder rejects) and `walletP2shOutput` (Xverse's witness-only signature for a P2SH address). Taking `result.signature` from the Xverse/Leather JSON-RPC response is part of the wallet API, not of the TAP; the TAP decodes the base64 string.
- Specification changes: §6.1 adds "a client that receives a 65-byte `sig` SHOULD reject it and say why"; §8 adds three points: MUST explicitly request BIP-322 simple (OKX defaults to BIP-137), MUST request signatures only for P2TR/P2WPKH addresses (Xverse gives a non-standard signature for P2SH addresses), MUST NOT rely on the wallet window for the user to understand the calls and SHOULD tell the user where the wallet shows the full text (wallets collapse it, hide it behind a link, or truncate it horizontally). The real-wallet section of Test Cases becomes a four-wallet matrix; Security Considerations adds "What the wallet shows", and the length notes in "Batches" are updated.
