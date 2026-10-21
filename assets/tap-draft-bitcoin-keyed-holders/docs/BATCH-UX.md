*Working note, translated from the author's Chinese original; dated entries describe the state on that date.*

> **Provenance note (holder-final-lab)**: this file was copied unchanged from holder-batch-lab (commits fc8864b / 5977119) and is kept as a historical record; it is superseded by `TAP-draft-bitcoin-keyed-holders.md`. The only specification change (copy all `data_i` before any gas check) is described in `docs/INTEGRATION-NOTES.md` §3. `BitcoinKeyedHolderBatch.sol`, `scripts/batch/`, the lab addresses and the creation code mentioned here refer to the candidate build in that repository, not to this repository's contract. [Translator's note: this describes the lab state as of 2026-10-10, the date of `docs/BATCH-REPORT.md` and `docs/BATCH-SPEC.md` from the same commits. Xverse, Leather and OKX Wallet were tested later, on 2026-10-11; see `docs/INTEGRATION-NOTES.md` §10.]

# Wallet experience for batched calls (BATCH-UX)

> This document is informative guidance, not specification; the normative requirements are in the §8 addition of `docs/BATCH-SPEC.md`. This document changes no page.
> The existing `tools/sign.html` is only a small tool that "hands one sentence to the wallet to sign"; "page" below means a static web page
> that builds the message itself, has the wallet sign it, decodes it and sends it through a relayer.

## 1. What the user actually sees

**Now (one signature per step)**: claiming mining-rig rewards, moving the rewards away and moving the circuit away are three `execute` calls. The user sees three wallet pop-ups,
each one an English sentence of about 290 characters (§5.2), and has to check the holder address, chain and nonce three times; in between, they have to wait for the previous transaction to land to get the
new nonce before signing the next (otherwise the page has to sign nonces n, n+1, n+2 in advance, and if one in the middle fails, all later signatures become invalid).

**With batching (one signature, several steps)**: only one pop-up, and the wallet shows a longer English sentence (about 600 characters for 3 calls, about 1,330 for 8), such as:

```
TapeOut Bitcoin-keyed holder 0xf819…25a6 on chain 56 makes 3 calls: (1) 0x…c1 with value 0 and data 0xa9a4…78e1, gas 100000; (2) 0x…b0 with value 1000000000000000 and data 0xc5d2…a470, gas 0; (3) 0x…c1 with value 0 and data 0x53eb…04fa, gas 100000; tip 10000000000000000, nonce 0, valid until 2000000000
```

(The wallet shows the full hex; it is shortened above for layout.) What the user can check in the wallet: the holder address, the chain, the **number of calls**,
each call's target address/amount/gas, the tip, the nonce and the deadline. **What they cannot see is what each call actually does**: data appears only as a hash.
So "is this call a circuit transfer or an approval of all tokens" can only be shown to the user by the page's decoding. This is the same as for a single §5.2 call; batching only amplifies it.

Known facts and unknowns:
- The message contains only visible ASCII 0x20–0x7e and no line breaks (line breaks may be rewritten to CRLF or dropped in different wallets' text boxes, so they are not used).
  Wallets display it as one long text with automatic wrapping.
- Signatures from two versions of `bip322-js` on batch messages of up to 2,239 characters were all accepted by the reference verifier (`tools/wallet-lib-check/sign-batch.log`).
- **UniSat 1.7.22 (real extension, headless Chromium) has been tested**: it signed batch messages of 610, 1,329 and 2,239 characters for both P2TR and P2WPKH;
  the confirmation page puts the full text in a scrollable box (box height 384 pixels, viewport 1000×800), and all signatures were accepted by the reference verifier and the contract
  (`vectors/wallet-unisat-1.7.22-batch.json`, the screenshots in `interop/unisat-extension/batch/`). But with 8 calls,
  the trailing `valid until …` is already below the fold and can only be seen after scrolling; the real extension pop-up is smaller than this viewport, so more scrolling is needed.
- **Other wallets not tested**: how Xverse, Leather, OKX and Sparrow display messages above 644 characters is unverified; how hardware wallets display long BIP-322 messages is also unverified
  (Ledger's legacy message signing path shows only a hash above 640 characters, but that is not the BIP-322 path). Until these are tested, a page should treat 8 calls as the limit,
  and by default not offer batches on hardware wallets (see §4).

## 2. How a page should present a batch

Before signing, the page shows a "batch confirmation card" **before** the wallet pop-up, item by item matching the message:

1. **A one-sentence title**: `The holder 0xf819…25a6, controlled by Bitcoin address bc1p…ca, does 3 things at once on BNB Chain: all succeed or none happen.`
2. **A numbered list**, numbered the same as `(1)`, `(2)`… in the message, each item with one line in plain language + one line of raw fields:
   - Plain language: `(1) Transfer circuit #920 to 0x1234…abcd` (decoded by the page from known contract ABIs: function name, arguments, token id, recipient).
   - Raw: target `0x…c1`, amount `0`, data hash `0xa9a4…78e1`, gas `100000`.
   - A call that cannot be decoded must be clearly marked in red: `(2) Unknown call: target 0x…, selector 0x12345678, cannot be interpreted`; do not quietly show it as "other operation".
   - Risky calls are flagged separately: `setApprovalForAll`, `approve`, changing owner/operator, sending native coin to an unverified contract, large transfers.
3. **Totals**: total native coin (Σ value, converted to BNB/ETH/OKB) + tip (converted the same way), and "whether the holder's balance is sufficient".
4. **Validity and nonce**: `Valid until 2033-05-18; uses nonce 0 (cancels any other operation signed but not sent at nonce 0)`.
5. **Original text**: the full message text, collapsible, exactly the bytes that will be handed to the wallet, with a hint to the user: "the wallet should show the same text, starting with
   `… makes 3 calls:` and ending with `… valid until 2000000000`", so that the user can at least check the start, the end and the number of calls.

Self-checks before signing (inside the page, without bothering the user):
- When the holder is deployed, read `batchMessage(calls, tip, nonce, deadline)` with `eth_call` and compare it byte for byte with the locally built text; if they differ, refuse to continue.
- Read the current `nonce()` and build the message with it.
- Simulate `executeBatch` once with `eth_call` (after signing); on failure, use the returned `BatchCallFailed(index, data)` to tell the user "call index+1 will fail" and why;
  do not hand a batch that is bound to fail to a relayer.
- When estimating gas, note: the relayer must give at least Σ need_i (each call about callGas×64/63 plus 3,100 or 37,100), otherwise the contract refuses outright.

After signing:
- Decode the wallet output (§6.1 rules: trim leading and trailing whitespace, reject `ful`/`pof`, strip `smp`, base64-decode), verify locally, then hand it to the relayer.
- Once on chain, tick off each item using the K `Called` events in one transaction (same nonce, in log order).

## 3. When to use a batch and when not

- **2 or more related steps** (claim rewards → move rewards → move circuit): use a batch: one pop-up, 26%–56% gas saved (`docs/BATCH-REPORT.md`).
- **Only 1 step**: use the original `execute`: a batch of 1 call costs about 7,300 gas more, and the message is longer.
- **Unrelated operations that should succeed or fail independently**: sign separately: a batch is all or nothing, and one failure reverts everything.
- **More than 8 steps**: split into several batches, one nonce each, sent in order.

## 4. Conservative policy for devices and wallets (until real wallets are tested)

| Situation | Recommendation |
|---|---|
| UniSat extension (1.7.22 tested) | Allow batches, limit 8; on first use, show the hint "the text in the wallet is long, please scroll to the end and check `valid until`" |
| Other browser extension wallets (Xverse, Leather, OKX, long messages untested) | Allow, but limit to 4 (about 730 characters) until tested, with the same hint to scroll to the end |
| Desktop wallets (Sparrow, message pasted by hand) | Allow; the page offers a "copy message" button; the message is one line, so pasting introduces no line breaks |
| Hardware wallets | Do not offer batches by default, until a test confirms that the whole text is displayed; otherwise fall back to one `execute` per call |
| Wallet type cannot be determined | Allow, but lower the call limit to 4 (message about 730 characters, close to the tested 644 characters) |

Real-wallet tests still needed: Xverse, Leather, OKX, Sparrow and at least one hardware wallet, each signing one 8-call message (about 1,330 characters) and one
longest message (2,239 characters), confirming that the interface can scroll to the end and that the contract accepts the signature. UniSat has been done with `interop/unisat-extension/steps/batch.mjs`
as automation; the other wallets' extensions or devices need someone to operate them. Also, the UniSat result comes from a 1000×800 headless viewport, so a screenshot at the real pop-up size is also worth adding.
