*Working note, translated from the author's Chinese original; dated entries describe the state on that date.*

> **Provenance note**: this file was copied unchanged from wallet-matrix-lab (commit d82a533). In this repository the raw results are in `interop/wallet-matrix/results/`, the vectors are produced by `python3 tools/make_wallet_matrix_vectors.py` (replacing the lab's `scripts/make_vectors.py`, with byte-identical output), and the tests are `contracts/test/WalletUnisat.t.sol` and `contracts/test/batch/WalletUnisatBatch.t.sol`; the screenshots (about 12 MB) were not copied and stay in the lab. Taking `result.signature` from the JSON-RPC responses of Xverse and Leather is a matter of the wallet API, not of the TAP: TAP §6.1 decodes that base64 string.

# Findings (2026-10-11)

Tested: Xverse 2.9.3, Leather 6.114.0, OKX Wallet 4.18.1 (current versions in the Chrome store, see `results/extensions.json`), against the `main` branch of the TAP draft (creation code keccak `0x4bc9698a…9c4f`). Only the public test mnemonic `abandon … about` was used, and no transaction was sent to a public network.

## Conclusion first

For P2TR and P2WPKH addresses and the three kinds of message §5.1 / §5.2 / §5.3, using the BIP-322 call each wallet documents, the three wallets' raw output **all decodes as it is under §6.1, is all judged valid by the reference implementation, and is accepted by the contract on a local BSC fork** (`isValidSignature` returns `0x1626ba7e`, `execute` moves the real NFT #920, `executeBatch` moves 8 test NFTs, every replay is rejected). **No output appeared that §6.1 cannot decode, so there is no finding that requires a change to the decoder.**

F2 and F3 are outputs that "decode but are not simple signatures"; they are listed as **optional** candidate text changes for §6.1 / §8. F4 is a display issue in the three wallets' confirmation interfaces, relevant to §8.

## F1 Output format (no change needed)

| Wallet | What the dapp receives | String to hand to §6.1 | `smp` prefix |
|---|---|---|---|
| Xverse 2.9.3 | JSON-RPC object `{jsonrpc, id, result:{address, messageHash, signature, protocol:"BIP322"}}` | `result.signature` (plain base64) | None |
| Leather 6.114.0 | JSON-RPC object `{jsonrpc, id, result:{signature, address, message}}` | `result.signature` (plain base64) | None |
| OKX 4.18.1 | Plain base64 string | The return value itself | None |

- P2TR: all three wallets give a 66-byte witness stack `01 40 ‖ 64-byte Schnorr` (SIGHASH_DEFAULT); no 67-byte SIGHASH_ALL appeared.
- P2WPKH: 107 or 108 bytes, `02 ‖ len ‖ DER ‖ 01 ‖ 21 ‖ 33-byte public key`, DER 70 or 71 bytes, all low-s, SIGHASH_ALL.
- For the same text and the same P2WPKH address, the signatures from Xverse, Leather, OKX and the earlier UniSat 1.7.22 are **byte-identical** (all three batch texts were checked; RFC 6979 deterministic nonce), which can serve as a cross-check between vectors.
- Xverse's `messageHash` field has an inconsistent format: sometimes hex, sometimes base64 (`results/xverse/xverse-2.9.3-extras.json`). The field is of no use to the TAP, and clients should not rely on it.

## F2 Optional §6.1 change candidate: OKX's default type outputs a 65-byte BIP-137 signature

When `okxwallet.bitcoin.signMessage(msg)` is called without a second argument, the type defaults to `ecdsa` (extension inject script `scripts/lib/inpage.js`: `signMessage(n,o)`, `type:a="ecdsa"`). For the §5.1 text of a Native SegWit address, OKX outputs:

```
H8/Cqqpv6B56uvt/qY2sVhHiCelwjgxjgyBy4lDtioEVFkBCgNkckeifG5Klv6LQFSJrotJrsF5hjoSpr/tdJNo=
→ 65 bytes 0x1fcfc2aaaa6fe81e7abafb7fa98dac5611e209e9708e0c63832072e250ed8a811516404280d91c91e89f1b92a5bfa2d015226ba2d26bb05e618e84a9affb5d24da
```

This is a BIP-137 compact signature (header byte `0x1f`). It is valid base64, so the decoding steps of §6.1 **accept it anyway**, giving 65 bytes; the reference implementation's `verify` judges it INVALID, and the contract also rejects it. The problem is that 65 bytes is exactly the length that TAP-11 §4.4 reads as ECDSA, so through a TAP-11 client it never reaches EIP-1271, and the user sees a misleading error such as "signer does not match" rather than "wrong signature format".

Candidate text (end of §6.1 or §8): "A client **SHOULD** reject outright a signature that is 65 bytes after decoding, and say that it is a BIP-137 / legacy message signature and that BIP-322 simple must be requested (for example OKX's `'bip322-simple'`). A valid simple signature is never 65 bytes (P2TR 66/67, P2WPKH in practice 107/108)."

## F3 P2SH-wrapped addresses: the TAP's "not supported" holds, but Xverse signs anyway

- **Xverse**: after switching Preferred Bitcoin Address to Nested SegWit in the settings, the payment address from `getAddresses` becomes `37VucYSaXLCAsxYyAPfbSi9eh4iEcbShgf` (`addressType:"p2sh"`). `signMessage` for it, with or without `protocol:"BIP322"`, returns `protocol:"BIP322"` and a 107-byte signature that is "witness only, with the scriptSig left out":

  ```
  AkcwRAIgKT3Q8TWFWab3nRuNJZeGw5NmuTGvcuvW/UQngGO/nu8CID0yCpORaQuKcbNUgMhmiNJNKD2eIPBPpFte6PWAw0zlASEDmztpS4/FteB/sGnHg8rHVPXTjD4IvtGWDjH9sd2jXCQ=
  → 0x024730440220293dd0f1358559a6f79d1b8d259786c39366b931af72ebd6fd44278063bf9eef02203d320a9391690b8a71b35480c86688d24d283d9e20f04fa45b5ee8f580c34ce50121039b3b694b8fc5b5e07fb069c783cac754f5d38c3e08bed1960e31fdb1dda35c24
  ```

  Checked separately: verified as "to_spend output script is this P2SH, BIP-143 scriptCode is this public key hash, scriptSig omitted", it is a valid ECDSA signature; verified against the P2WPKH address of the same public key, `bc1qlxgx0xk2lcjuyas4xua5p0ezg3kjfl6yd3h8y6`, `verify_simple` is false (to_spend differs). BIP-322 requires the full format for P2SH addresses, so this is non-standard output. `cli.py verify` explicitly reports "unsupported address type" for `3…` addresses. **Conclusion: the TAP's statement that P2SH-P2WPKH is not supported holds, and this output cannot be reused for any holder.**
- **Leather**: `paymentType:'p2sh'` is rejected outright: `-32602 Validation error: Invalid option: expected one of "p2tr"|"p2wpkh" at "paymentType"`.
- **OKX**: after switching the BTC preferred address to Nested SegWit or Legacy, `signMessage(msg,'bip322-simple')` still shows the confirmation page, and after clicking confirm returns the error `Error: Can not finalize input #0`.
- **Documentation does not match behaviour**: the Xverse documentation says payment (p2sh) addresses use ECDSA by default; in 2.9.3, without `protocol`, both P2WPKH and P2SH gave BIP-322. Clients should still pass `protocol:'BIP322'` explicitly.

Candidate text (§8): "Xverse's payment address may be P2SH-P2WPKH (`addressType:"p2sh"`), and the wallet still returns a witness-only 'BIP322' signature for it. A client **MUST** first check the address prefix or `addressType`, request signatures only for `bc1p…` / `bc1q…`, and for P2SH ask the user to switch to Native SegWit or use a Taproot address."

## F4 Relevant to §8: none of the three wallets' confirmation pages shows the full text on opening

| Wallet | First view | What the user must do to see the full text | 4,000-character text |
|---|---|---|---|
| Xverse 2.9.3 (pop-up 375×600) | The "Message" collapsible section shows only one line, ending in an ellipsis (`text-overflow: ellipsis`), with "Message Hash" below | Click the expand arrow to the right of "Message"; once expanded the full text wraps and the whole page scrolls vertically | Accepted; after expanding the full text is there |
| Leather 6.114.0 (pop-up 390×756) | Full text shown inline, but **long tokens do not wrap**: the holder address, target address and 64-digit data hash are cut off on the right (message box `clientWidth` 338, `scrollWidth` 673, `overflow:auto`) | Scroll horizontally inside the message box (`screenshots/leather/leather-p2tr-batch-transfers-8-hscroll-*.png`) | Accepted |
| OKX 4.18.1 (pop-up 360×720) | The confirmation page **does not show the message at all**, only a "Data ›" line | Click "Data"; a bottom panel opens with the full text wrapped, scrolling vertically inside the panel | Accepted |

All three wallets allow **signing without seeing the full text**; a user who does not expand or scroll horizontally does not see the call targets and data hashes. This is not the "truncation" or "falling back to a hash" that §8 refers to, but for §5.2 / §5.3 it means the same thing: the wallet itself cannot be taken as evidence that "the user has seen what the calls are". §8 already requires the interface to decode and show the calls itself; I suggest naming these three behaviours in the wallet notes of §8, and extending "SHOULD NOT offer a batch to a wallet … known to truncate it" to wallets that "hide the text by default or truncate it horizontally". For comparison: UniSat 1.7.22 puts the full text in a vertically scrollable box.

## F5 Length and characters

- 156, 268/273, 610, 1,329, 2,239 and 4,000 characters were all accepted by the three wallets and produced valid signatures; no limit was hit.
- Xverse and Leather put the message into the query string of the pop-up URL (Leather uses form encoding, where a space becomes `+`). TAP texts contain only 0x20–0x7e and no `+ & %`; a separate test with `a+b=c&d=%41 #frag` showed that Leather's echo and signature are both correct, so the encoding round trip is fine.

## F6 Other

- OKX exposes only the "BTC preferred address" to dapps (Taproot by default). To sign with P2WPKH, the user must first click the switch icon next to "Receiving address" on the BTC coin page and change it to Native SegWit.
- In OKX, the public test mnemonic shows about 13,000 dollars of assets on other chains (bait, or a sweeper bot's holdings). Again: read-only, never fund, never send transactions on a public network.
- In `results/okx/okx-4.18.1-extras.json`, the item `p2wpkh-default-ecdsa.cliVerify` was computed after the run: at run time `common.mjs` did not capture the `INVALID` that `cli.py verify` writes to stdout when it fails (it only recorded "Command failed"); after the fix it was recomputed with the same `cli.py verify` command and written back. All other fields in `results/` are the run's output as is.
- Two workarounds for the headless environment, neither of which changes the wallets' signing behaviour: the extensions' call `chrome.windows.create({type:'popup', top, left})` fails in headless Chromium because "the window is not on screen", so the script retries without top/left (same size and type; see `patchPopups` in `scripts/common.mjs`); when a notification page is already open, OKX shows the request in that page, so the script closes it after import.

## Wallets that could not be tested

- **Phantom 26.32.0**: the injected scripts `phantom.js` / `solana.js` have no `bitcoin` namespace at all (only solana / ethereum / sui), so there is no Bitcoin `signMessage` that a dapp can call. There are internal chain IDs such as `bip122_p2tr`, but dapps cannot use them. No mnemonic was imported.
- **Magic Eden Wallet 3.3.1**: the only injectable resources are `ethereum-provider.js`, `solana-provider.js` and `management-provider.js`, with no Bitcoin provider; the store page was last updated 2026-04-02. No mnemonic was imported.
- **Sparrow**: a desktop GUI, with no automation. The dialogs of `--terminal` mode have no message signing (the `terminal/` directory of `sparrowwallet/sparrow`; the command-line arguments are only `--dir/--network/--level/--terminal/--version`), so there is no CLI for headless signing. The signing logic is in the library `sparrowwallet/drongo`, `src/main/java/com/sparrowwallet/drongo/crypto/Bip322.java` (latest commit 3779317388, 2026-05-22, "update bip322 implementation to match completed spec"): the return value of `signMessageBip322` always gets the `smp` prefix, and only P2WPKH and P2TR are supported (P2SH-P2WPKH throws an exception). Calling it needs a JDK + Gradle, which, as instructed, were not installed, so **this round has no measured output from Sparrow**; the TAP's existing Sparrow evidence is still the unit-test samples cited earlier. Addendum 10/11: the four public signatures in the drongo tests (three P2WPKH, including one with a 72-byte DER; one P2TR, 65-byte witness, explicit SIGHASH_ALL, same key) were all run through `BIP322.sol`, and all four pass; the counterexample (a signature for "Hello World" used for the empty message) is rejected; see `contracts/test/SparrowDrongo.t.sol` (with it there are 221 tests in total; the package submitted with the TAP still has 217). This only proves that we accept the bytes produced by Sparrow's library; it is not a measurement of Sparrow's interface.
