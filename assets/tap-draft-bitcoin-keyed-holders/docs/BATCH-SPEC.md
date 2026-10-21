*Working note, translated from the author's Chinese original; dated entries describe the state on that date.*

> **Provenance note (holder-final-lab)**: this file was copied unchanged from holder-batch-lab (commits fc8864b / 5977119) and is kept as a historical record; it is superseded by `TAP-draft-bitcoin-keyed-holders.md`. The only specification change (copy all `data_i` before any gas check) is described in `docs/INTEGRATION-NOTES.md` §3. `BitcoinKeyedHolderBatch.sol`, `scripts/batch/`, the lab addresses and the creation code mentioned here refer to the candidate build in that repository, not to this repository's contract.

# Batched calls for Bitcoin-keyed holders (candidate extension)

Status: lab candidate, 2026-10-10. This text is written so that it can be merged into the TAP draft
`TAP-draft-bitcoin-keyed-holders.md` as new subsections §5.3 and §6.4, with the additions to §3.1 listed
below. The section numbers refer to that draft. The reference implementation is
`contracts/src/BitcoinKeyedHolderBatch.sol`, a subclass of the draft's `BitcoinKeyedHolder` that leaves every
inherited function unchanged. The vectors are in `vectors/batch-vectors.json` and the tests in
`contracts/test/Batch.t.sol` and `contracts/test/BatchFuzz.t.sol`. `docs/BATCH-REPORT.md` has the
measurements and the recommendation.

Adopting this text changes the holder's creation code (§3.2), and with it the holder address of every
Bitcoin address (§4). See "Effect on the rest of the draft" at the end.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED",
"NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119
and RFC 8174 when, and only when, they appear in all capitals.

### Additions to §3.1 (Interface)

| Function | Selector | Behaviour |
|---|---|---|
| `batchMessage((address target, uint256 value, bytes data, uint256 callGas)[] calls, uint256 callTip, uint256 callNonce, uint64 deadline) returns (bytes)` | `0xba195d76` | The message of §5.3. Reverts with `BadBatch()` unless `calls` has 1 to 8 elements |
| `executeBatch((address target, uint256 value, bytes data, uint256 callGas)[] calls, uint256 callTip, uint64 deadline, bytes sig) returns (bytes[])` | `0xc7826280` | §6.4 |
| `MAX_CALLS() returns (uint256)` | `0xb9add4b7` | 8 |
| `MAX_CALL_GAS() returns (uint256)` | `0x2ed55b1f` | 2^64 |

The row for `nonce()` changes to: "The number of successful calls of `execute` and `executeBatch`; starts at 0".
New errors: `BadBatch()` (`0x86bdc25c`) and `BatchCallFailed(uint256 index, bytes returnData)` (`0x651ab1b3`).
`executeBatch` emits the existing event `Called` once for each call (§6.4 step 9). It is not payable.

The sentence of §3.1 "no other way to move assets than §6.3" becomes "than §6.3 and §6.4".

### 5.3 Making several calls

A **batch** is an ordered list of K calls, where 1 ≤ K ≤ 8, together with one `callTip`, one `callNonce`
and one `deadline`. Call number i (counted from 1) has a `target_i`, a `value_i`, `data_i` and a `callGas_i`,
with the meanings of §5.2. The message is

prefix ‖ ` makes ` ‖ decimal(K) ‖ ` calls:` ‖ C_1 ‖ … ‖ C_K ‖ ` tip ` ‖ decimal(`callTip`) ‖ `, nonce ` ‖ decimal(`callNonce`) ‖ `, valid until ` ‖ decimal(`deadline`)

where each C_i is

` (` ‖ decimal(i) ‖ `) 0x` ‖ hex(`target_i`, 40 digits) ‖ ` with value ` ‖ decimal(`value_i`) ‖ ` and data 0x` ‖ hex(`keccak256(data_i)`, 64 digits) ‖ `, gas ` ‖ decimal(`callGas_i`) ‖ `;`

The message uses only the bytes 0x20 to 0x7e, so it has no line breaks. Example (informative), from the
test vectors (one line in the original):

```
TapeOut Bitcoin-keyed holder 0xf819c5e20f7dd75a9237db2e90d1dc304a9b25a6 on chain 56 makes 3 calls: (1) 0x00000000000000000000000000000000000000c1 with value 0 and data 0xa9a435fbbd955641df99510b0742564efd4a1b7f814e1051de8003215df478e1, gas 100000; (2) 0x00000000000000000000000000000000000000b0 with value 1000000000000000 and data 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470, gas 0; (3) 0x00000000000000000000000000000000000000c1 with value 0 and data 0x53eb100413d42c24830d57dcfe705f48c9c3a34e9c8895a1ac98c463da8204fa, gas 100000; tip 10000000000000000, nonce 0, valid until 2000000000
```

**Length.** The message has 123 + |C| + |T| + |N| + |D| + Σ_i (142 + |v_i| + |g_i|) bytes, where |x| is the
number of decimal digits of x, and C, T, N and D are the chain ID, tip, nonce and deadline. That is a fixed
part of 123 bytes plus the digits of those four numbers, and 142 bytes per call plus the digits of its value
and gas. A call with value 0 and
gas 100000 adds 149 bytes. A batch of 8 such calls on chain 56 with tip 0, nonce 0 and a 10-digit deadline is
1,329 bytes. Since `executeBatch` accepts only `callGas_i` < 2^64 (20 digits) and `deadline` < 2^64, and a
uint256 has at most 78 digits, any batch that `executeBatch` can accept has a message of at most
2,219 + |C| bytes (2,239 bytes for a 20-digit chain ID). A client **MUST NOT** ask a wallet to sign a batch with
more than 8 calls or with no call. A client **SHOULD NOT** use a batch of one call. Its message is longer than
§5.2's and `executeBatch` costs more gas than `execute` for one call (`docs/BATCH-REPORT.md`).

**Unambiguity.** Each hex field has a fixed width. Each decimal field is followed by a literal that starts
with a byte that is not a digit (` `, `)`, `,` or `;`), or ends the message. The call count is written
before the calls, and every call carries its position. A message of §5.3 can therefore be parsed in only one
way, and two batches that differ in any field, in the order of their calls or in their number of calls have
different messages. After the prefix (whose chain ID is always followed by a space), §5.1 continues with
` signs`, §5.2 with ` calls` and §5.3 with ` makes`. No message of one kind therefore equals a message of
another kind.

### 6.4 `executeBatch`

`sig` is as in §6.1. `executeBatch(calls, callTip, deadline, sig)`:

1. If `block.timestamp > deadline`, revert with `Expired()`.
2. If `calls` has no element or more than 8, revert with `BadBatch()`.
3. If any `callGas_i` is at least 2^64, revert with `BadBatch()`.
4. If `sig` is not valid (§6.1) for the message of §5.3 for `calls`, `callTip`, `deadline` and `callNonce`
   equal to the current `nonce`, revert with `BadSignature()`.
5. Increase `nonce` by one. A batch uses exactly one nonce, whatever the number of its calls.
6. Let `need_i` be the value of §6.3 step 5 for `callGas_i` and `value_i`: the larger of ⌊`callGas_i` × 64 / 63⌋
   and `callGas_i` + 2,500, plus 3,100 when `value_i` is 0 and 37,100 otherwise. If the gas left is less than
   Σ `need_i`, revert with `InsufficientGas()`.
7. For each call i in order:
   1. If `data_i` is not empty and `target_i` has no code at this moment, revert with `NoCode()`.
   2. If the gas left is less than `need_i`, revert with `InsufficientGas()`.
   3. Call `target_i` with `value_i`, `data_i` and `callGas_i` as the call's gas argument. If the call fails,
      revert with `BatchCallFailed(i − 1, returnData)`, where i − 1 is the zero-based position of the call
      and `returnData` is the callee's return data (empty if the holder's balance is below `value_i`).
8. If `callTip` is not 0, call `msg.sender` with value `callTip`, empty data and all the gas that remains. If
   that call fails, revert with `TipFailed()`.
9. For each call i in order, emit `Called(callNonce, target_i, value_i, keccak256(data_i))`, where
   `callNonce` is the value of `nonce` before step 5. Return the callees' return data, in call order.

A batch is all or nothing. If any step reverts, nothing the batch did remains, the nonce is not used, and
the same signature can be relayed again until its deadline. In particular, a call that fails undoes every
earlier call of the batch, and no tip is paid.

Step 6 is a lower bound that the relayer can compute from the signed values alone. Step 7.2 is what
guarantees each callee at least `callGas_i`, by the argument of §6.3 step 5. Neither step reserves gas for
the holder's own work between calls, for the tip or for the events. A relayer that supplies too little for
those pays for a transaction that reverts.

Anyone **MAY** relay a signed batch. A signature of a §5.3 message authorises exactly that list of calls, in
that order, with those gas amounts and that one tip, on one chain, by one holder, at one nonce, until its
deadline. `execute` and `executeBatch` draw on the same nonce. Signing and relaying any call or batch at a
nonce therefore cancels every other signed call or batch at that nonce.

The tip of a batch is paid once, after all its calls, to `msg.sender`, as in §6.3 step 7. Everything that
§6.3 and the Security Considerations say about the tip applies unchanged.

**Events.** A batch of K calls emits K `Called` events with the same `nonce`. They are contiguous in the
transaction's log, in call order, and come after any event emitted during the calls, including the events
of a call or batch that re-entered the holder with the next nonce. An indexer **MUST NOT** assume that `nonce`
identifies one event. It orders the holder's calls by `nonce` and then by log position. An indexer that needs
to know which events came from one batch reads the `executeBatch` calldata, or the call trace when
`executeBatch` was called by a contract.

### Addition to §8 (Wallets and user interfaces)

A user interface that asks a user to sign a message of §5.3 **MUST** build the text from the calls it shows,
**MUST** show every call decoded as §8 requires for §5.2 (target, function and arguments, value), numbered
as in the message, together with the number of calls and the tip converted to the chain's coin, and
**SHOULD** read the deployed holder's `batchMessage(...)` through `eth_call` and compare it byte for byte
with the text before asking the wallet. It **SHOULD** say plainly that the calls happen together or not at
all. It **SHOULD NOT** offer a batch to a wallet or signing device whose display of the message is known to
truncate it or to fall back to showing a hash. `docs/BATCH-UX.md` is informative guidance.

## Rationale (informative)

**Why not sign a digest of the calls.** A single hash of the list would keep the message short, but the
draft's own argument against digests (Rationale, "A separate message for calls") applies with more force:
the user would see nothing but a hash. The batch message shows each call's target, value, gas and data hash,
as §5.2 does, and adds only the count and the numbering.

**All or nothing, not per-call success flags.** The calls a user groups are usually steps that depend on one
another: claim a reward, then move it; move a circuit, then delegate. If a later step ran after an earlier
one failed, the outcome would be one the user did not sign for, and the nonce would be used anyway.
Per-call flags would also need a rule for the tip of a partly failed batch. With all or nothing, a batch
either does what the text says or does nothing, which is the guarantee `execute` gives for one call. A user
who wants independent calls signs separate messages.

**Gas.** Each call keeps its own signed `callGas`, for the reason given in the draft's Rationale. The check
before each call is the one of §6.3. The up-front check (step 6) makes a relayer that cannot cover the signed
total fail before any callee runs, so that the required gas follows from the signed values alone, whatever the
callees actually use. The 2^64 cap keeps step 6 from overflowing and is far above any block gas limit.

**The code check before each call, not up front.** A call may create the target of a later call. For example,
call 1 deploys a contract (an ERC-6551 account, say) and call 2 uses it. A check of every target before the
first call would refuse such a batch. Because a batch is all or nothing, checking later loses nothing.

**At most 8 calls.** The limit bounds the text that a user has to read (at most about 2,200 bytes, about
1,300 for typical calls) and the work of one transaction. The measured saving per extra call levels off: a
batch of 8 already saves about half of the gas of 8 separate calls (`docs/BATCH-REPORT.md`). A later version
may raise the limit with new creation code.

**One `Called` per call, after the tip.** Existing indexers of `Called` see every call without change. Emitting
the events together at the end, as `execute` does after its tip, keeps one batch's events contiguous.

**`BatchCallFailed` instead of the callee's raw revert.** `execute` bubbles the callee's revert data unchanged.
A batch also has to say which call failed, so that an interface can tell the user.

## Security considerations (informative, to be merged into the draft's)

- **A long text hides things more easily.** Each call shows only a hash of its data, as in §5.2. A batch can
  therefore place an approval of every token among seven harmless transfers, and the user sees eight lines
  that look alike. Long texts are also skimmed. The count at the start ("makes 8 calls") and the numbering
  let a user check that the wallet shows the whole text, but not what each call does. The only real
  protection is the interface's decoding (§8 addition). Users should treat a batch request from an unknown
  site as they would eight separate requests.
- **Order and composition.** Calls that are harmless one at a time can be harmful together. For example, call
  1 approves an operator and call 2 lets that operator act, in one atomic step that no one can interrupt.
  An interface should decode and show the calls in order and flag approvals and operator changes.
- **Wallet display limits.** No wallet limit on the length of a BIP-322 message is documented. Earlier research
  for this draft (archive notes, research round 10) had libraries sign messages up to 644 characters. It found
  the only display limit in Ledger's legacy message signing, which shows a hash above 640 characters and is
  not the BIP-322 path. In this lab, two versions of `bip322-js` signed batch texts of up to 2,239 characters,
  and the reference verifier accepted every one (`tools/wallet-lib-check/sign-batch.log`). The UniSat browser
  extension 1.7.22 (headless Chromium, P2TR and P2WPKH) signed batch texts of 610, 1,329 and 2,239 characters.
  In each case its confirmation page held the whole text in a scrollable box, and the holder accepted the
  signatures (`vectors/wallet-unisat-1.7.22-batch.json`, `contracts/test/WalletUnisatBatch.t.sol`). That box was
  384 pixels high in a 1000×800 viewport, so the end of an 8-call text was below the fold. The user has to
  scroll, and the real extension popup is smaller. **Other wallets (Xverse, Leather, OKX, Sparrow) and hardware
  signers are untested for texts above 644 characters.** A wallet or signing device that cuts off the text, or
  shows a hash instead, would hide later calls. A batch should not be offered to such a device.
- **Replay and other chains.** As for §5.2: the prefix names the holder and the chain, and the nonce and
  deadline bind the batch to one use and a time window. A §5.3 signature is never accepted by `execute` or
  `isValidSignature`, and the reverse is also true.
- **Reentrancy.** The nonce is increased before the first call. A callee or the tip recipient that re-enters
  with the same signature is therefore refused. One that re-enters with a valid signature for the next nonce
  succeeds, as with `execute`.
- **Relayers.** A relayer cannot reorder, drop, add or partly execute calls. It can only relay the whole batch
  or not relay it. A relayer that supplies too little gas pays for a reverted transaction and uses no nonce.
- **Value and tip.** Σ `value_i`, the tip and anything the calls spend come from the holder's balance. A
  shortfall at any point reverts the whole batch.

## Effect on the rest of the draft

- §3.2: the creation code changes. The lab build is 11,107 bytes with `keccak256`
  `0x6bad18530bb2d453989d12047dc06ee49bfcd76d41138f271c6c61071bc560dc` (subclass layout. A merged single
  contract would have other bytes). As a result, the holder address of every Bitcoin address changes (§4), for
  example `bc1pdznq…` → `0xf819c5e20f7dd75a9237db2e90d1dc304a9b25a6` in the lab build.
- Test Cases: every vector that names a holder address must be regenerated. That includes the 23 signature
  cases, the 4 call cases, the 12 `bip322-js` signatures and the UniSat 1.7.22 real-wallet vectors, because
  each signed text contains the holder address. The UniSat test would have to be repeated against the new
  address.
- Backwards Compatibility: unchanged in substance, since nothing has been deployed under the draft.

## Addendum (holder-final-lab, after the author-organised adversarial review of 2026-10-10)

This addendum is not part of the lab's text above; the normative text is `TAP-draft-bitcoin-keyed-holders.md`. It
records what changed relative to this document, with the reasons in `docs/INTEGRATION-NOTES.md`.

- **Gas checks after the copy** (before the audit): every `data_i` is in memory before step 6, and nothing
  whose cost depends on any `data_i` happens between the check of step 7.2 and the call.
- **No return data** (audit F-01): `executeBatch` returns nothing. The holder MUST NOT copy the return data of
  a call that succeeds (the calls and the tip). Returning each callee's data made the holder copy and keep all
  of it, so its own gas grew with the square of the total returned (8 callees returning 200,000 bytes each:
  about 37,000,000 gas against 186,000 with empty returns), which no signed number bounds. A client that needs
  the results simulates the batch with `eth_call` and reads them from the trace.
- **Revert data cut to 256 bytes** (audit F-02): `BatchCallFailed(index, returnData)` carries the first 256
  bytes of the failed call's revert data (all of it if shorter); the holder copies no more than that, so a
  callee that reverts with a lot of data cannot turn the typed error into an out-of-gas revert.
- **Security considerations added** (audit F-05, F-06):
  - *Texts for batches that cannot run.* `batchMessage` renders the text of a batch with a `callGas_i` of
    2^64 or more, which `executeBatch` always refuses. Such a signature is wasted, not dangerous; an interface
    MUST NOT ask a user to sign one (§8 of the merged draft).
  - *What a front-run relayer pays.* The holder copies and hashes all call data before it checks the
    signature, so a relayer whose transaction fails because the nonce was used first pays for that work:
    about 1,030,000 gas for 8 calls of 24,000 bytes, about 120,000 for 8 calls without data. A relayer should
    read `nonce()` just before sending, send through a private channel, and ask a larger tip for batches with
    much call data.
- **Tests that do not trust the contract's own text** (audit F-04): `tools/make_text_corpus.py` writes 48
  batch texts (1 to 8 calls), 24 call texts and 8 digest texts in Python with edge values; the Foundry test
  `TextCorpusTest` gives their Python signatures to the verification paths without reading the views.
