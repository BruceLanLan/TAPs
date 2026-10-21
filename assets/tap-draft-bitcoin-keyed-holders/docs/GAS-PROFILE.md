*Working note, translated from the author's Chinese original; dated entries describe the state on that date.*

> **Provenance note (holder-final-lab)**: this file was copied unchanged from the `main` branch of holder-gas-lab (commit ff52eb9) (review finding F-07: it is not on the `variant/no-swar` branch, while `docs/FINAL-GAS.md` references it). The "main line" numbers here are those of 5c103b9, which includes O6; this repository chose 6e5bf32, without O6, plus batching. For the observation in §6 that "the accumulated hash differs, cause not found", see the "After the review" section of `docs/INTEGRATION-NOTES.md`.

# Gas profile: BitcoinKeyedHolder (baseline 834787a and optimised 5c103b9)

Conclusion first: in the baseline, two thirds of the execution cost of `isValidSignature` (about 49k, P2TR) goes into **building the message text** (the byte-by-byte Solidity loops of `_prefix`, `_hex` and `_dec`); the actual cryptography (6–11 sha256, 1–2 ecrecover, 1 modexp) is only about 10k; P2WPKH spends about 26k more on byte-by-byte DER parsing and copying the public key. Of the 1.84 million gas of deployment, 1.57 million is code storage (7,854 bytes × 200), 140k is the init code calldata, and 66k is writing `scriptPubKey` into storage. The incompressible parts of `execute` are the first write of the nonce (22,100), cold account accesses and the called contract itself.

## 1. Measures

| Name | Meaning | How measured |
|---|---|---|
| tx | The `gasUsed` of a real transaction: 21,000 + calldata (EIP-2028, no EIP-7623 floor under shanghai) + execution | `test/GasBench.t.sol`. forge 1.8 defaults to `isolate = true`, so each top-level CALL from the test contract is executed as a separate transaction (charged 21,000 and calldata, access list reset). Real receipts on a local anvil (chain id 56, shanghai) are consistently 412 (`isValidSignature`), 378 (`execute`) and 2,885 (deployment) lower than the GasBench numbers; the difference is the test contract's own call overhead; the differences between baseline and optimised are exactly the same (see GAS-REPORT §2). |
| static | The execution gas inside the callee's frame when a contract calls `isValidSignature` with STATICCALL (excluding 21,000 and calldata), i.e. the part an EIP-1271 verifier actually pays | The `static` rows of GasBench; frame gas in the trace. Baseline 49,335 / 78,829, consistent with "about 50,000 / 82,000" in the TAP draft. |
| step | Step-by-step instrumentation of the baseline logic | `test/profile/ProfiledHolder.sol` is a step-by-step expanded copy of the baseline code, with `gasleft()` between steps; it runs at the baseline holder's original address, so the baseline vector signatures are valid. The instrumentation itself (a 40-slot array and each probe) makes the sum about 1,000 more than the real frame. |

Inputs are fixed to the baseline vectors (`test/baseline/BaselineVectors.sol`): chain 56, P2TR uses `p2tr-56` (SIGHASH_DEFAULT, 66-byte witness), P2WPKH uses `p2wpkh-56` (108-byte witness). **This P2WPKH signature needs ecrecover's v = 28**, i.e. two ecrecover calls; random signatures need 1.5 on average, so the P2WPKH numbers are about 1,550 above the average case. For measurement, the optimised code is installed at the baseline holder address (run the constructor at that address, then etch the returned runtime code), so every version is measured with the same calldata and the same signature.

Calldata itself (same for every version): `isValidSignature` P2TR 196 bytes = 2,020 gas, P2WPKH 228 bytes = 2,652 gas; `execute` ERC-721 transfer P2TR 516 bytes = 3,360 gas, P2WPKH 548 bytes = 3,968 gas.

## 2. Baseline `isValidSignature` (step by step, inside the static frame)

| Step | P2TR | P2WPKH |
|---|---:|---:|
| Prefix: `_hex(holder)` + `_dec(chainid)` + `abi.encodePacked` | 13,403 | 13,403 |
| `_hex(digest)` (32 bytes, Solidity byte-by-byte loop, about 570/byte) | 18,228 | 18,228 |
| Message concatenation (`abi.encodePacked`) | 868 | 868 |
| Witness copied from calldata to memory | 525 | 530 |
| P2TR: shape check + rebuild spk | 431 | — |
| P2WPKH: DER parsing (byte by byte, with bounds checks) | — | 15,572 |
| P2WPKH: 33-byte public key copied byte by byte | — | 10,280 |
| P2WPKH: hash160 (sha256 + ripemd160) | — | 1,868 |
| P2WPKH: lift_x(public key) (modexp 1,349) + keccak | — | 2,370 |
| BIP-322 message hash (tagged sha256, copying the message) | 1,756 | 1,748 |
| to_spend serialisation + sha256d | 1,960 | 2,064 |
| BIP-341 signature hash (5 inner sha256 + tagged sha256) / BIP-143 (3 sha256d + sha256d) | 5,392 | 5,238 |
| BIP-340 challenge (tagged sha256, mod n) | 1,380 | — |
| ecrecover (3,000 + call) | 3,514 | 3,389 |
| Second ecrecover (v = 28) | — | 3,472 |
| BIP-340 lift_x(r) (modexp 1,349 + call) | 2,036 | — |
| keccak(R) + address comparison | 445 | — |
| **Instrumented copy total** | **49,938** | **79,030** |
| Real frame (trace) | 48,965 | 78,459 |
| + calldata + 21,000 = transaction gasUsed (anvil receipt) | 71,985 | 102,111 |

Formatting (the first three rows) is 66% of the P2TR frame (32,499). The precompiles themselves: sha256 costs 72–156 each, about 1,000 in total for 10 calls (P2TR) / 11 calls (P2WPKH), plus 100 per STATICCALL and argument encoding.

## 3. Baseline `execute` (ERC-721 transfer, P2TR, step by step)

| Step | gas |
|---|---:|
| Deadline check + cold SLOAD of nonce | 2,285 |
| Prefix | 13,400 |
| `_hex(target)` (20 bytes) | 11,706 |
| `_dec(value)` | 360 |
| `keccak256(data)` | 555 |
| `_hex(dataHash)` (32 bytes) | 18,225 |
| `_dec` × 4 (gas, tip, nonce, deadline) | 6,957 |
| Concatenation (14-part `abi.encodePacked`) | 2,030 |
| Signature verification (witness copy … keccak comparison, same as the second half of P2TR in §2) | 18,049 |
| NoCode check (cold EXTCODESIZE) | 2,864 |
| SSTORE nonce 0→1 (slot already warmed by SLOAD: 20,000 + overhead) | 20,192 |
| Gas floor check | 418 |
| CALL to target (target already warm) + callee execution (one SSTORE to change owner) | 6,078 |
| Tip (just a branch when tip = 0) | 196 |
| `emit Called` (keccak(data) computed again + LOG3) | 2,576 |
| **Instrumented copy total** | **105,891** |
| Transaction gasUsed (anvil receipt, including 21,000 and calldata 3,360) | 127,921 |

With a tip (0.01 BNB to the relayer), the tip row becomes 7,107 (CALL with value 9,000 minus the 2,300 stipend, plus cold access). The incompressible parts: 21,000, calldata 3,360, first write of the nonce 22,100, cold access to the target 2,600, callee about 5,700, event about 1,900, precompiles and their calls about 6,000: about 62,700 in total, so the optimised 70,867 is only about 8,000 above the floor.

## 4. Deployment (CREATE2 through the deterministic deployment proxy, P2TR)

| Part | Baseline | Optimised (5c103b9) |
|---|---:|---:|
| 21,000 | 21,000 | 21,000 |
| calldata: salt + init code (9,140 / 6,513 bytes) | 142,844 | 98,952 |
| CREATE2 32,000 + init code hashing and EIP-3860 word cost (8 gas/word) | 34,280 | 33,624 |
| Constructor: check the output public key (modexp 1,349 etc.) | ~3,000 | ~3,000 |
| Constructor: write `scriptPubKey` into storage (P2TR 3 slots, P2WPKH 1 slot) | 66,300 | 0 |
| Code storage 200 × runtime bytes (7,854 / 5,576) | 1,570,800 | 1,115,200 |
| Proxy execution, memory copy | ~4,100 | ~2,600 |
| **Total (anvil receipt)** | **1,842,326** | **1,274,343** |

The marginal deployment cost per byte is about 216 gas per runtime byte (200 storage + about 16 calldata); this is the conversion rate used when choosing optimisations.

## 5. Composition of the optimised build (5c103b9) (trace)

| | P2TR `isValidSignature` | P2WPKH `isValidSignature` |
|---|---:|---:|
| Static frame total | 9,888 | 15,236 |
| sha256 precompile (P2TR 7 calls: message, to_spend×2, sha_prevouts, sha_scriptpubkeys, signature hash, challenge; P2WPKH 8 calls) | 768 | 768 |
| ripemd160 | — | 720 |
| modexp | 1,349 | 1,349 |
| ecrecover | 3,000 | 6,000 (v = 28, twice) |
| 100 per precompile call | 900 | 1,200 |
| Rest: dispatch and ABI decoding, message building (SWAR hex, decimal), memory, parsing and modular arithmetic | 3,871 | 5,199 |
| Transaction gasUsed (21,000 + calldata + frame) | 32,908 | 38,888 |

`execute` (ERC-721, P2TR) transaction 70,867 = 21,000 + calldata 3,360 + frame 46,507; in the frame: nonce 22,100, NoCode cold access 2,600, callee 5,682, precompiles 5,117 + 900, event about 1,900; the remaining about 8,200 is message building, verification logic and call overhead.

## 6. Reproduce

```
cd contracts
forge build --force                                  # required: see the cache problem in GAS-REPORT §6
forge test --match-contract GasProfile -vv           # baseline, step by step
forge test --match-contract GasBench -vv             # tx / static numbers per version
forge test --match-test test_bench_isValidSignature_p2tr -vvvv   # trace: gas per precompile call
```
