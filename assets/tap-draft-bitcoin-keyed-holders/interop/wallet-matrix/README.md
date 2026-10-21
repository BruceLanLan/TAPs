*Working note, translated from the author's Chinese original; dated entries describe the state on that date.*

> **Provenance note**: this file was copied unchanged from wallet-matrix-lab (commit d82a533). In this repository the raw results are in `interop/wallet-matrix/results/`, the vectors are produced by `python3 tools/make_wallet_matrix_vectors.py` (replacing the lab's `scripts/make_vectors.py`, with byte-identical output), and the tests are `contracts/test/WalletUnisat.t.sol` and `contracts/test/batch/WalletUnisatBatch.t.sol`; the screenshots (about 12 MB) were not copied and stay in the lab. Taking `result.signature` from the JSON-RPC responses of Xverse and Leather is a matter of the wallet API, not of the TAP: TAP §6.1 decodes that base64 string.

# Real-wallet matrix: Bitcoin-Keyed Holders TAP draft

Question: besides UniSat 1.7.22, can the BIP-322 signatures produced by other real wallets be decoded as they are by TAP §6.1 and accepted by the contract? Does the confirmation interface show the user the full text to be signed?

**Conclusion: for the three Chrome extensions Xverse 2.9.3, Leather 6.114.0 and OKX Wallet 4.18.1, with both P2TR and P2WPKH addresses, the §5.1, §5.2 (two) and §5.3 (three) messages and a 4,000-character probe text, all 42 signatures decode as they are under §6.1 and are all judged valid by the reference implementation; on a local BSC fork, the contract returns `0x1626ba7e` for the §5.1 signatures, `execute` moves a real NFT, `executeBatch` moves 8 test NFTs, and every replay is rejected. The TAP's decoding rules do not need to change.** All three wallets' confirmation pages allow signing without seeing the full text (Xverse collapses it to one line by default, OKX does not show it by default, Leather truncates long hex fields horizontally); details and optional candidate text changes are in `FINDINGS.md`. Phantom and Magic Eden have no Bitcoin signing interface available to dapps, and Sparrow has no signing entry point that can be automated; none of them was tested.

Test date 2026-10-11; TAP repository `main` (merged holder, creation code keccak `0x4bc9698a…9c4f`); P2TR holder `0xc692…dd64`, P2WPKH holder `0xfec7…cb0b` (the same as in the UniSat run: the same mnemonic gives the same `bc1p5cyxn…kedrcr` and `bc1qcr8te…306fyu`).

## Matrix

Each cell covers 7 texts: §5.1 (156 characters), §5.2 real NFT transfer (273), §5.2 empty call at nonce 1 (268), §5.3 eight transfers (1,329), mixed three (610), longest batch (2,239), and a 4,000-character non-TAP probe text.

| Wallet | Address | Raw output format | Witness bytes | sighash / DER | `cli.py verify` | Contract on fork | Does the confirmation page give the full text | Largest length tested | Notes |
|---|---|---|---|---|---|---|---|---|---|
| Xverse 2.9.3 | P2TR `bc1p…` | JSON-RPC object, `result.signature` is plain base64, no `smp` | 66 | SIGHASH_DEFAULT (`01 40`+64) | 7/7 valid | 1271 ✓, execute ✓, executeBatch ✓ ×2 | By default only one line plus an ellipsis; after clicking "Message" the full text wraps | 4,000, accepted | Called as `request('signMessage',{address,message,protocol:'BIP322'})` |
| Xverse 2.9.3 | P2WPKH `bc1q…` | Same as above | 107/108 | DER 70/71, low-s, SIGHASH_ALL | 7/7 valid | Same as above | Same as above | 4,000, accepted | A new wallet defaults to Native SegWit; can be changed to Nested SegWit (P2SH, not supported by the TAP, see F3) |
| Leather 6.114.0 | P2TR | JSON-RPC object, `result.signature` is plain base64, no `smp` | 66 | SIGHASH_DEFAULT | 7/7 valid | Same as above | Full text inline, but 40/64-digit hex fields are cut off horizontally and need horizontal scrolling inside the box | 4,000, accepted | `request('signMessage',{message,paymentType:'p2tr',network:'mainnet'})` |
| Leather 6.114.0 | P2WPKH | Same as above | 107/108 | DER 70/71, low-s, SIGHASH_ALL | 7/7 valid | Same as above | Same as above | 4,000, accepted | `paymentType:'p2sh'` is rejected (-32602) |
| OKX 4.18.1 | P2TR | Plain base64 string, no `smp` | 66 | SIGHASH_DEFAULT | 7/7 valid | Same as above | The confirmation page does not show the message; only clicking "Data" opens a panel with the full text | 4,000, accepted | `okxwallet.bitcoin.signMessage(msg,'bip322-simple')`; the dapp only sees the "preferred address" (Taproot by default) |
| OKX 4.18.1 | P2WPKH | Same as above | 107/108 | DER 70/71, low-s, SIGHASH_ALL | 7/7 valid | Same as above | Same as above | 4,000, accepted | The preferred address must be switched to Native SegWit on the BTC coin page; without a type argument it defaults to `ecdsa` and outputs a 65-byte BIP-137 signature (see F2) |

For the same P2WPKH address and the same text, the signatures of the three wallets and UniSat are byte-identical (RFC 6979); all three batch texts were checked.

P2SH and other unsupported addresses (TAP §2 says they are not supported; this holds):

| Wallet | Behaviour |
|---|---|
| Xverse | Signs anyway for the Nested SegWit address `37Vuc…Shgf`, returning a 107-byte witness-only non-standard "BIP322" signature; `cli.py` rejects this address type |
| Leather | Accepts only `p2tr` / `p2wpkh`; the `p2sh` parameter fails validation |
| OKX | With a Nested SegWit or Legacy preferred address, clicking confirm gives `Can not finalize input #0` |

## Fork check (`results/fork-check.log`, `results/fork-check.json`)

`anvil --fork-url https://bsc-mainnet.public.blastapi.io` (block 126,957,655); first the EIP-7702 code on the anvil default accounts is cleared, then the holders are deployed through the deterministic deployment proxy (with the init code given by `tools/cli.py address`); each wallet starts from the post-deployment snapshot:

| | P2TR (three wallets) | P2WPKH (three wallets) |
|---|---|---|
| `isValidSignature` (the wallet's raw §5.1 signature) | `0x1626ba7e`; after changing the last byte or the digest, `0xffffffff` | Same |
| `execute` transferring real ERC-721 `0x1f5c…f12c` #920 to `0x…c0b7a` | Success, gas 115,808–115,835 | Success, gas 118,462–121,803 |
| Empty call at nonce 1 | Success, gas 56,243–56,270 | Success, gas 58,980–62,238 |
| `executeBatch` eight transfers / mixed three | Success, gas 284,753–284,792 / 196,238–196,265, moving 8 / 2 NFTs | Success, gas 290,665 / 202,245 |
| Replay of each one | All rejected | All rejected |

## Vectors

`vectors/wallet-<name>-<version>.json` and `-batch.json` have the same format as the TAP repository's `vectors/wallet-unisat-1.7.22*.json` (`tap-bitcoin-keyed-holders-wallet-vectors/2`, `…-wallet-batch-vectors/2`, identical keys), and are produced from `results/` by `scripts/make_vectors.py`: each text is rebuilt with the TAP's `tools/holder.py` and compared byte for byte with the text the wallet signed, and each output is decoded under §6.1 (`btc.witness_from_wallet`), matches the witness recorded at run time, and passes the reference verifier. For Xverse and OKX, `popupLayout` records the view after the user expands it (the default view is in the top-level fields of the record of the same name in `results/`).

## How it was done

- The extension IDs come from the vendors' websites or store pages (`results/extensions.json` records the source URL, version and CRX sha256); the CRX3 was downloaded from the store's update endpoint, unpacked after skipping the header, and loaded in Playwright's bundled Chromium (Chrome for Testing 156, headless, `--load-extension`).
- Each wallet imported the public test mnemonic `abandon … about` into a fresh profile, and the wallet's dapp interface was called from a plain `http://127.0.0.1:<port>/blank.html` page (Xverse: the Sats Connect documentation docs.xverse.app/sats-connect; Leather: leather.gitbook.io/developers/bitcoin-methods/signmessage; OKX: the documentation page web3.okx.com/build/dev-docs/sdks/chains/bitcoin/provider returned 404 that day, so the interface was taken from the extension's injected `scripts/lib/inpage.js`).
- For each signature, screenshots were taken at the pop-up size the wallet itself requested (top, scrolled to the bottom, full page; Xverse/OKX also after expanding), the size and overflow style of the element holding the text were recorded, then confirm was clicked and the raw return value was passed to the TAP's `tools/cli.py verify` and `witness`.

## Reproduce

```
cd scripts && npm i playwright@1.64 && npx playwright install chromium
# download and unpack the extensions to <EXT>/<name> (IDs in results/extensions.json)
python3 -m http.server 18791 --bind 127.0.0.1 --directory .          # serves blank.html
EXTDIR=<EXT>/xverse  PROFILE=<new directory> LAB=<TAP repository> OUT=../results/xverse  SHOTS=../screenshots/xverse  node run.mjs xverse
EXTDIR=<EXT>/leather PROFILE=<new directory> LAB=<TAP repository> OUT=../results/leather SHOTS=../screenshots/leather node run.mjs leather
EXTDIR=<EXT>/okx     PROFILE=<new directory> LAB=<TAP repository> OUT=../results/okx     SHOTS=../screenshots/okx     node run.mjs okx
LAB=<TAP repository> CAST=cast ANVIL=anvil python3 fork_check.py ../results xverse leather okx   # run forge build in the TAP repository's contracts/ first
python3 make_vectors.py <TAP repository> .. xverse 2.9.3 "Xverse browser extension 2.9.3 (Chrome Web Store), run on 2026-10-11"
```

Files: `scripts/run.mjs` (common flow), `scripts/wallets/*.mjs` (each wallet's import, connect, sign, confirm and extra probes), `scripts/common.mjs` (pop-up handling, interface probing, calling `cli.py`), `scripts/mkmsgs.py` (generates all texts with the TAP code), `results/<wallet>/*.json` (raw returns, pop-up text and layout, `verify`/`witness` results, extra probes), `screenshots/<wallet>/`.

**Do not fund any address of this mnemonic**: it is public, and OKX shows about 13,000 dollars of bait assets sitting on it on other chains. This experiment executed transactions only on a local fork.
