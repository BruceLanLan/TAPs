*Working note, translated from the author's Chinese original; dated entries describe the state on that date.*

# Real-wallet signature check: UniSat browser extension

Question: do the signatures that a wallet's interface actually produces match the decoding rules of TAP §6.1 and the contract's verification? Before this, the only evidence came from independent wallet libraries and test vectors.

**Current build (2026-10-10, after merging the gas optimisations and `executeBatch`):** the same extension (UniSat 1.7.22) re-signed all messages for the new holder addresses (P2TR `0xc692…dd64`, P2WPKH `0xfec7…cb0b`): for each address type 1 §5.1 message, 2 §5.2 messages (one real NFT transfer, one empty call at nonce 1) and 3 §5.3 batches (8 transfers, 1,329 characters; a mixed batch of 3 with a tip, 610 characters; the longest, 2,239 characters). Every confirmation window held the full text in a scrollable box (`popupContainsFullText` is true), and the reference implementation's `verify` found all of them valid. The raw output is in `results/unisat-1.7.22-merged-*.json`; `tools/make_wallet_vectors.py` produces `vectors/wallet-unisat-1.7.22*.json` from it (not edited by hand); screenshots are in `batch/merged/`. `fork_check.py` uses these signatures on a local BSC fork: for both address types it executed the 8-transfer batch and the mixed batch (test ERC-721 placed at `0x…c1`), EIP-1271 (rejected after changing a byte and after changing the digest), an `execute` of the real NFT `0x1f5c…f12c` #920 (gasUsed 115,835 / 121,720) and the empty call at nonce 1; the replay of every one was rejected (`results/fork-check.log`).

Below is the first check, made on 2026-10-09 against the addresses of the draft build (834787a). The raw output of that run moved to `results/legacy/`, the screenshots of the batch-lab run are in `batch/legacy/`, and the corresponding vectors are in `vectors/legacy/`; the tests `WalletUnisatLegacyTest` and `WalletUnisatBatchLegacyTest` install the current code at those old addresses and verify, which shows that the real wallet's signatures for the old addresses are equally valid on the merged verifier.

**Conclusion (2026-10-09): for both Taproot and Native SegWit addresses, the raw output of `signMessage(msg, "bip322-simple")` from the UniSat extension 1.7.22 (the current version in the Chrome store) is accepted by the decoder without any modification, verified by the contract, and successfully completed a real transfer through `execute` (local BSC fork). The TAP text does not need to change for this.**

| | Address | Output | Reference implementation `verify` | Contract `isValidSignature` | NFT transfer through `execute` on the fork |
|---|---|---|---|---|---|
| Taproot | `bc1p5cyxn…qkedrcr` | Plain base64, witness stack 66 bytes (`01 40 <64-byte Schnorr>`, SIGHASH_DEFAULT) | valid | `0x1626ba7e` | Success, gas 165,968 |
| Native SegWit | `bc1qcr8te…306fyu` | Plain base64, witness stack 108 bytes (strict DER, low s, SIGHASH_ALL) | valid | `0x1626ba7e` | Success, gas 192,865 |

For each address type, three kinds of message were signed (authorising a digest, an empty call, a real NFT transfer), all valid. Negative checks: after changing the last byte or the digest, the contract returns `0xffffffff`; a replay of the same signature is rejected.

In the same round, our wallet page (`btc-experiments/unisat-page`) was connected to the real extension and completed "connect → generate call text → wallet signs → page decodes to `execute` calldata", with the holder address matching the reference implementation.

## What was tested and what was not

- **Tested**: the real `signMessage` of the UniSat extension 1.7.22, and that the text shown in the real pop-up matches our generated text character for character. The wallet used the public test mnemonic (`abandon … about`, the one in the BIP-39 documentation).
- **Not tested**: Sparrow, Xverse, Leather, OKX; hardware wallets; other UniSat versions (1.7.4 from GitHub was only downloaded to compare the interface, without signing); Taproot SIGHASH_ALL output (UniSat gives SIGHASH_DEFAULT for P2TR); P2SH-wrapped addresses (not supported by the specification anyway).
- **Do not fund any address of this mnemonic**: it is public and watched by bots. It is used here only on a local fork, and no transaction was sent to a public network.

## Reproduce

```
npm i playwright && npx playwright install chromium     # needs a Chromium with extension support; official Chrome 137+ no longer supports --load-extension
# download and unpack the UniSat extension (Chrome store ID ppbibelpcjmhbdihakflkdcoccbgbkpo) to <EXTDIR>
python3 -m http.server 8765 --bind 127.0.0.1 --directory .   # serves blank.html
ATYPE='Taproot (P2TR)' EXTDIR=<EXTDIR> PROFILE=profile node step.mjs $PWD sign
ATYPE='Native Segwit (P2WPKH)' EXTDIR=<EXTDIR> PROFILE=profile2 node step.mjs $PWD sign
CAST=cast ANVIL=anvil python3 fork_check.py                  # BSC fork, reads results/unisat-1.7.22-merged-*.json (run forge build in contracts/ first)
```

`results/` holds the raw output (pop-up text, wallet return value, witness bytes) and `fork-check.log`; those for the old addresses are in `results/legacy/`. Batch signatures use `steps/batch.mjs` (messages from `batch/mkmsgs.py`). In headless mode UniSat's confirmation pop-up does not open a window by itself, so the script opens `notification.html` directly to click confirm.
