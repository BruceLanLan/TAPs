*Working note, translated from the author's Chinese original; dated entries describe the state on that date.*

> **Provenance note (holder-final-lab)**: this file was copied unchanged from holder-batch-lab (commits fc8864b / 5977119) and is kept as a historical record; it is superseded by `TAP-draft-bitcoin-keyed-holders.md`. The only specification change (copy all `data_i` before any gas check) is described in `docs/INTEGRATION-NOTES.md` §3. `BitcoinKeyedHolderBatch.sol`, `scripts/batch/`, the lab addresses and the creation code mentioned here refer to the candidate build in that repository, not to this repository's contract.

# Batched calls and calldata compression: experiment report (2026-10-10)

## Conclusion

- **Batching (`executeBatch`) is worth doing; I recommend merging it into this TAP before submission, not opening a separate TAP later.**
  - Savings: 26%–30% gas for 2 steps, 41%–47% for 4 steps, 49%–56% for 8 steps.
  - Experience: wallet pop-ups go from N to 1.
  - Risk: none of the properties of the existing messages is weakened.
  - Cost: the holder's creation code changes, so **the holder address of every Bitcoin address changes**, and every vector that contains a holder address has to be redone, including the UniSat real-wallet set.
  - Why now: the draft has not been submitted yet and there are no official holders on chain, so this cost is lowest now. If a separate TAP were opened later, the same Bitcoin address would have two holder addresses, and the property "one Bitcoin address maps to one holder" would be lost.
- **Compressed calldata (a compact `execute`) is not recommended.**
  - It does save 57% of the bytes (292 bytes per transaction).
  - But on Base the total fee per transaction falls by only 1.1% (about 8.6×10⁻⁹ ETH).
  - On X Layer the L1 data fee parameters are 0, and it saves only 1.1% of L2 gas.
  - Maintaining a second ABI that has to be reviewed is not worth this little money. To save L1 bytes, batching itself already cuts the L1 fee of 8 steps by 82%.

## 1. Design (full specification text in `docs/BATCH-SPEC.md`)

- **Signed text** (new §5.3):
  - Format: `<prefix> makes K calls: (1) 0x<target> with value <amount> and data 0x<data hash>, gas <gas>; (2) …; tip <tip>, nonce <n>, valid until <deadline>`.
  - Only visible ASCII, no line breaks.
  - Each field is either fixed-width hex or decimal immediately followed by a non-digit literal, so there is only one way to parse it.
  - After the prefix, the three kinds of message begin with ` signs`, ` calls` and ` makes`, so they can never be equal.
  - The length is 123 + the digits of the chain ID, tip, nonce and deadline + per call (142 + digits of the amount + digits of the gas). A typical 8 steps is about 1,330 characters; the longest acceptable is 2,239 characters.
- **Contract function**:
  - Signature: `executeBatch((address,uint256,bytes,uint256)[] calls, uint256 callTip, uint64 deadline, bytes sig) returns (bytes[])`.
  - 1–8 calls; each `callGas` must be less than 2^64.
  - Order: check deadline → check count and gas cap → verify signature → increase nonce by one (one for the whole batch) → check that the relayer's gas is at least Σneed → call each in turn (before each call, check whether the target has code and the gas floor) → pay the tip once → emit K `Called` events in order (same nonce).
- **Failure semantics: all or nothing.** If any call fails, the whole batch reverts with `BatchCallFailed(index, returnData)`, the nonce is not used, and the signature can be sent again. Reason: what a user puts into one batch is usually a sequence of dependent steps, such as claim then transfer; if partial success were allowed, the result would not be what the user signed.
- **Gas floor**:
  - Before each call, the check of §6.3 is kept (the larger of callGas×64/63 and callGas+2,500, plus 3,100 or 37,100), which guarantees that each callee gets at least callGas.
  - In addition, Σneed is checked once before the first call, so that a relayer that gives too little gas fails before any call happens.
- **Tip, reentrancy, replay protection**:
  - The tip is paid once for the whole batch, with the same rules as §6.3.
  - The nonce has already been increased before the first call, so re-entry with the same signature is refused.
  - The prefix names the holder and the chain; together with the nonce and the deadline, replay protection is exactly as in §5.2.
  - `execute` and `executeBatch` share one nonce, so signing anything at the same nonce can cancel the other.
- **Implementation**: in `contracts/src/BitcoinKeyedHolderBatch.sol`, a subclass of the draft contract; the original `BitcoinKeyedHolder.sol` is untouched. The keccak of the original creation code is still `0xb093…d4a7`, verified after clearing the cache and recompiling. The subclass's creation code is 11,107 bytes, keccak `0x6bad…60dc`, also reproducible.

## 2. Measured savings (anchored on transaction receipts on forks)

**Method**: `scripts/batch/measure.sh` forks Base (block 52,407,020) and X Layer (block 72,834,314) on a local anvil, both with `--network optimism`.

- Deployed: the draft holder, the batch holder, and a plain ERC-721 (`contracts/test/BenchERC721.sol`).
- Transactions: each moves one NFT, done once as "k separate `execute`" and once as "1 `executeBatch`".
- Data sources: gas is the receipt's `gasUsed`, which includes the 21k base cost and the calldata cost. The L1 data fee is `getL1Fee(bytes)` of the Fjord GasPriceOracle (`0x420…0F`) on the signed raw transaction. This is the real predeploy on the fork, not a formula of my own. One deviation: Fjord's `getL1Fee` expects an **unsigned** transaction and adds 68 bytes internally for the signature; I passed the signed transaction, so every L1 fee number counts about 65–68 signature bytes too many. This changes no conclusion, because the L1 fee is only 0.2% of the total fee; but it makes the compact version's "L1 fee −11.4%" ratio slightly low.
- Raw data: `scripts/batch/logs/measure-base.json`, `measure-xlayer.json`. All transactions were sent only to the local anvil.

**Base (8453)**: L2 gas price taken as 0.006 gwei, the public RPC's `eth_gasPrice` at the time. L1 fees in units of 10⁻⁹ ETH.

| Address | Steps | k execute gas | 1 executeBatch gas | Saved | calldata bytes (separate→batch) | L1 fee (separate→batch) | Total fee (separate→batch, 10⁻⁹ ETH) | Total fee saved |
|---|---|---|---|---|---|---|---|---|
| P2TR | 1 | 145,884 | 153,287 | **−5.1%** | 516 → 612 | 1.92 → 2.04 | 877 → 922 | −5.1% |
| P2TR | 2 | 258,788 | 192,052 | 25.8% | 1,032 → 932 | 3.85 → 2.15 | 1,557 → 1,154 | 25.8% |
| P2TR | 4 | 517,512 | 303,583 | 41.3% | 2,064 → 1,572 | 7.69 → 2.37 | 3,113 → 1,824 | 41.4% |
| P2TR | 8 | 1,036,747 | 530,930 | **48.8%** | 4,128 → 2,852 | 15.37 → 2.82 | 6,236 → 3,188 | 48.9% |
| P2WPKH | 1 | 172,597 | 179,917 | **−4.2%** | 548 → 644 | 2.19 → 2.30 | 1,038 → 1,082 | −4.2% |
| P2WPKH | 2 | 312,334 | 218,916 | 29.9% | 1,096 → 964 | 4.38 → 2.42 | 1,878 → 1,316 | 29.9% |
| P2WPKH | 4 | 624,840 | 333,728 | 46.6% | 2,192 → 1,604 | 8.73 → 2.62 | 3,758 → 2,005 | 46.6% |
| P2WPKH | 8 | 1,263,963 | 557,792 | **55.9%** | 4,384 → 2,884 | 17.51 → 3.10 | 7,601 → 3,350 | 55.9% |

**X Layer (196)**: gas differs from Base by only a few hundred (P2TR 8 steps 1,034,183 → 530,611, 48.7% saved; P2WPKH 8 steps 1,270,790 → 557,277, 56.1% saved). Full data in the logs.

- On this chain, the GasPriceOracle at the fork block has both `baseFeeScalar` and `blobBaseFeeScalar` at 0, and `getL1Fee` returns 0, which means **there is currently no L1 data fee**. This was read from the chain, not inferred.
- The L2 gas price at the time was 0.02 gwei (OKB).

**How to read these numbers**:

- **Do not use a batch for 1 step**: it costs about 7,300 gas more than `execute`, because the message is longer and the ABI larger. The specification says SHOULD NOT.
- **Each additional step costs a batch only about 54,000 gas.** A separate `execute` costs 129,600 (P2TR) or 158,000 (P2WPKH) each. So each additional step saves about 75,600 (P2TR) or 104,000 (P2WPKH) gas; what is saved is the 21k base cost, one signature verification, one message build, and the cold accesses to the holder and the token contract.
- **On Base the L1 data fee is currently only 0.2%–0.25% of the total fee**; the main cost is L2 execution.
- **Sensitivity**: 62% of Base's L1 fee comes from the blob fee. Even if the blob fee rose 100 times, the total fee saving of an 8-step batch would only go from 48.9% to 53.2%; at 1000 times it becomes 68.7%. These lines are extrapolated from the Fjord formula and the parameters on the fork.
- **A simplified ERC-721 was used**: the transfers in this experiment are cheaper than real TapeOut circuits. In the UniSat run, which transferred a real circuit on a BSC fork, a single `execute` was 166k (P2TR) and 193k (P2WPKH). The absolute saving hardly depends on the token (75k–104k gas saved per additional step), so an 8-step batch of real circuits is estimated to save 40%–50%. This is an **extrapolation, not measured on real circuits**. Real circuits are proxy contracts, and accesses after the first in a batch are warm, so the actual saving may be larger.

**Wallet pop-ups**: N steps go from N pop-ups to 1. Another benefit is that there is no longer a need to "sign the first, wait for it to land, get the new nonce, sign the second", and no situation where "n, n+1, n+2 are signed in advance and one failure in the middle invalidates all later ones".

## 3. Calldata compression (task 4)

I built a **measurement-only** prototype `contracts/test/CompactLab.sol`, **not proposed for adoption**. It takes a compact encoding through `fallback`: tag 4 bytes, target 20, value uint96, callGas uint32, tip uint96, deadline uint32 (**absolute** Unix seconds; a "relative time" cannot be signed, because the relayer cannot know when the transaction will be included), data length uint16, data, and the signature takes all remaining bytes. The signed text is still the original §5.2 message. On the same contract, 3 transactions were sent with the ABI version and 3 with the compact version, and the last of each was compared:

| | ABI `execute` | Compact | Difference |
|---|---|---|---|
| calldata (P2TR) | 516 bytes (390 zero bytes) | 224 bytes (101 zero bytes) | −292 (−57%) |
| L2 gas (P2TR, Base) | 129,429 | 128,032 | −1,397 (−1.1%) |
| L1 fee (P2TR, Base) | 1.923×10⁻⁹ ETH | 1.705×10⁻⁹ ETH | −11.4% |
| Total fee per transaction (Base) | 778.5×10⁻⁹ ETH | 769.9×10⁻⁹ ETH | **−1.10%** |
| Total fee per transaction (X Layer) | — | — | −1.12% (L2 calldata gas only) |

P2WPKH is similar: −283 bytes, total fee −0.92%.

- **Zero bytes compress well**: Fjord estimates the compressed size with FastLZ, and the zero bytes of ABI padding are cheap anyway, so 57% fewer bytes buy only 11% less L1 fee.
- **Even with a higher blob fee it does not pay**: at 100 times the compact version saves 2.5% per transaction, at 1000 times 7.3%.
- **Judgement: reject.** The cost is a second ABI: every relayer, page, indexer and review has to implement and check two encodings; `fallback` also has to guard against selector clashes and misaligned length fields. The gain is only about 1% of the fee, about 0.00003 dollars per transaction at an **assumed** 1 ETH = 4,000 dollars. Batching already cuts L1 bytes by 82% at 8 steps; compression's 1% is not worth that review surface.

## 4. Test evidence

- **All tests** (`scripts/batch/logs/forge-test.log`): 147 tests all pass, including all 117 original ones, plus 30 new.
  - `Batch.t.sol`, 24:
    - Vectors and behaviour: 17 Python vector sets (P2TR and P2WPKH, 1–8 steps each, plus a mixed batch with a tip), text and calldata checked byte for byte, each executed.
    - Rejection paths: replay, expiry, other chain, other holder or other key are all rejected; swapping the order, one step fewer or one step more invalidates the signature.
    - Failure and limits: a failing middle step reverts the whole batch, pays no tip and uses no nonce; insufficient balance or an unpayable tip reverts the whole batch.
    - Gas: at minimum gas each callee gets exactly the same gas as with a generous relayer, and 1 gas less fails; the Σ pre-check has its own test.
    - Tip, reentrancy and limits: the tip is paid only once, to `msg.sender`; callee re-entry and tip-recipient re-entry are tested; a 9th step and 0 steps give `BadBatch`, and callGas reaching 2^64 also gives `BadBatch`.
    - Other: a contract deployed by an earlier step can be called by a later step; 20,000 runs of random calldata and 5,000 runs of random signatures.
  - `BatchFuzz.t.sol`, 3, **100,000 runs each**:
    - The text, parsed back by an independent parser, gives exactly the original batch, is byte-identical to the text built independently with `vm.toString`, and is all visible ASCII.
    - Under single-field mutation, swapping two steps, or adding or removing a step, the texts are equal if and only if the batches are equal.
    - The same property between two independent random batches. This one almost never draws equal batches; it mainly shows that there are no collisions.
  - **Validity check**: deliberately breaking the implementation (one extra digit appended after the gas) makes the parse-back test fail immediately. The single-field mutation test cannot catch this kind of ambiguity where "two fields change together", so the main evidence of injectivity is the parse-back test.
  - The other 3: `WalletUnisatBatch.t.sol`, 2 (see below), `CompactLab.t.sol`, 1.
- **`execute` behaviour unchanged**: with `HOLDER_UNDER_TEST=batch`, the original execution, tip and BIP-322/340 audit tests were run against the batch holder; 71 of 73 passed (`scripts/batch/logs/execute-suites-on-batch-holder.log`). The 2 failures are fixed vectors signed for the draft holder address, which must fail once the address changes. This itself shows the cost "the address changes".
- **Independent signing libraries**: `bip322-js` 4.0.0 and 3.0.0 signed the 17 vector messages and the longest 2,239-character message; the reference verifier accepted 38/38 and rejected after one character was changed (`tools/wallet-lib-check/sign-batch.log`).
- **Real wallet**: the UniSat extension 1.7.22 in headless Chromium signed batch messages of 610, 1,329 and 2,239 characters for both P2TR and P2WPKH; 6/6 valid.
  - Display: the confirmation page puts the full text in a scrollable box. At 8 steps the end is below the fold; the longest message needs about 230 pixels of scrolling.
  - Contract verification: the contract executed 8-step transfers and a mixed batch with a tip; the longest message passed signature verification and then overflowed when the nonce was increased. This was caused by deliberately setting the nonce to 2^256−1, which cannot happen in practice.
  - Material: `vectors/wallet-unisat-1.7.22-batch.json`, the screenshots in `interop/unisat-extension/batch/`, `contracts/test/WalletUnisatBatch.t.sol`.

## 5. Risks

1. **Address change**: any new function changes the creation code and therefore every holder address. It must be frozen once, before submission. The single-call optimisations of the other lab (holder-gas-lab) also change the bytecode; the two should be merged and frozen together, so that the addresses change only once.
2. **Long texts hide things more easily**: data is shown only as a hash. An "approve all tokens" can sit among 7 harmless transfers, and users will hardly read every line. The only practical defence is decoding by the page (`docs/BATCH-UX.md`). Batching amplifies this problem, which §5.2 already has, but introduces no new kind of problem.
3. **Composition risk**: steps that are harmless alone can be harmful together (approve, then let the approved party act), and atomically, with no way to interrupt.
4. **Wallet display tested only on UniSat**: how Xverse, Leather, OKX, Sparrow and hardware wallets display messages above 644 characters is unverified.
5. **New review surface**: about 90 more lines in the contract, 2 new error types and the Σ gas pre-check; Python and relayers have to implement nested dynamic ABI. My Python encoding was checked byte for byte against `cast calldata`. This part needs an independent audit before going live.
6. **Semantic change**: `nonce` no longer equals the number of calls; one nonce can correspond to K `Called` events. An indexer that deduplicates only by nonce will lose events.
7. **The Σ pre-check is more conservative**: the relayer must provide Σneed even if the callees use less (with 8 steps at 100k callGas each, about 845,000 gas must be reserved while only about 530,000 is used; Σneed = 8 × 105,600 = 844,800). The OP stack charges only for actual use, so there is no extra cost; only the gas limit has to be set higher.

## 6. Recommendation

**Merge into this TAP**, on these conditions:

- Merge `executeBatch` into `BitcoinKeyedHolder.sol` itself (no subclass), and freeze the creation code again together with the gas optimisations.
- Redo all vectors and rerun the UniSat automation.
- Add an independent audit of the batch part.

**If the author wants to freeze now and not redo the vectors, do not do it**, and do not choose "a separate TAP later": that would give the same Bitcoin address two holder addresses, with funds and circuits split between them.

## 7. What has to change (checklist)

### TAP draft `TAP-draft-bitcoin-keyed-holders.md`

1. Summary/Abstract: add one sentence "can also execute up to 8 calls in order with one signature".
2. §3.1:
   - Add to the interface table `batchMessage` (`0xba195d76`), `executeBatch` (`0xc7826280`), `MAX_CALLS` (`0xb9add4b7`), `MAX_CALL_GAS` (`0x2ed55b1f`).
   - Change `nonce()` to "the number of successful `execute` and `executeBatch` calls".
   - Add to the error list `BadBatch()` (`0x86bdc25c`), `BatchCallFailed(uint256,bytes)` (`0x651ab1b3`).
   - Change "no other way to move assets than §6.3" to "§6.3 and §6.4".
   - State that `executeBatch` is not payable, and explain the multiple-event semantics of `Called`.
3. §3.2: new creation code length and keccak; regenerate `creation-code.hex`.
4. §5: change the opening "Both messages" to "The three messages"; add §5.3 (the text of BATCH-SPEC.md).
5. §6: add §6.4; after the last paragraph of §6.3, "A signature authorises exactly one call", add one sentence: a §5.3 signature authorises the whole batch.
6. §8: add the batch display requirements (the §8 addition of BATCH-SPEC.md).
7. Rationale:
   - Add paragraphs "Why not sign a hash", "All or nothing", "Gas pre-check", "Code check before each step", "At most 8 steps", "One `Called` per step", "`BatchCallFailed`".
   - Change the paragraph "A separate message for calls" to say that the three kinds of message are never equal.
8. Security Considerations: add entries on long texts, composition risk, wallet display limits and indexer deduplication; add the batch case to "Relayers" and "The tip".
9. Test Cases:
   - Regenerate all holder addresses and the vectors that contain addresses: 23 signature cases, 4 call cases, 12 bip322-js signatures.
   - Add the batch vectors (17 sets) and the 100,000-run injectivity test.
   - Redo the UniSat real-wallet vectors with the new addresses, both single and batch; also update the example in the "Address binding" paragraph.
10. Reference Implementation: test count and fuzz runs.
11. Other parts of the repository:
    - The example addresses in the Chinese translation and the README.
    - The logs of `scripts/demo_fork.sh`, `scripts/mining/` and `interop/run.sh` must be rerun with the new addresses.
    - `scripts/make_tap_package.py` must pack the new files into assets.

### Relayer

1. Besides `execute` (`0x70111125`), also accept `executeBatch` (`0xc7826280`). After decoding `calls`:
   - check that the count is 1–8 and each callGas is less than 2^64;
   - simulate with `eth_call`, and on failure translate `BatchCallFailed(index, data)` into "step index+1 failed" for the page.
2. Set the gas limit to at least Σneed_i plus the holder's own overhead. 8 steps measured at about 530,000 gas, but the Σ pre-check requires at least 844,800 gas available (with 8 × 100k callGas). Bisecting with `eth_estimateGas` finds this value naturally, because the contract gives `InsufficientGas` when it is not enough.
3. Tip policy per batch: a batch pays one tip, and the relayer should decide whether to accept based on the estimated fee of the whole batch.
4. Indexing: one transaction will contain K `Called` events with the same nonce; record them in log order and do not deduplicate by nonce.
5. Keep submitting through a private channel, because the tip is paid to `msg.sender`; this does not change.

### Page (outside the scope of this change; guidance in `docs/BATCH-UX.md`)

Build the §5.3 text; self-check byte for byte with `batchMessage`; decode and display each step; limit the number of steps by wallet type; pre-run with `eth_call`; show the position from `BatchCallFailed`.

## 8. Not done

- **Batch gas on real circuits not measured**: only a simplified ERC-721 was measured; the saving ratio for real circuits is extrapolated. BSC was not measured either; it has no L1 data fee, so its gas saving equals the L2 part of the table.
- **Other real wallets and hardware wallets not tested**: only UniSat 1.7.22 was tested with long messages, and in a 1000×800 headless viewport, not the real pop-up size.
- **X Layer's L1 fee of 0 is only the parameter read at the fork block**: OKX may change the scalars later.
- **Batch message building is not gas-optimised**: about 10,000 gas per step goes into hex and decimal conversion. The other lab's single-call optimisations (assembly hex, etc.) can be applied directly; they were deliberately left alone here.
- **The TAP draft text was not changed**: as the task required, only the checklist and the specification text are given.
