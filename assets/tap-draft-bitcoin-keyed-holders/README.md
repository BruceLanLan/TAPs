# Assets of the draft TAP "Bitcoin-Keyed Holders"

The TAP itself is `TAPs/TAP-draft-bitcoin-keyed-holders.md` (status Draft; the creation code, and with it every holder address and vector, is provisional until Review). This directory holds everything the draft refers to: the Solidity reference implementation and its tests, dependency-free Python tools, the test vectors, the interoperability and fork demonstrations with their logs, and the measurement, integration and review notes. Code files are MIT, everything else CC0, as `LICENSE` of this repository says. Nothing here was sent to a public network.

## Layout

| Path | What it is |
|---|---|
| `contracts/src/` | `BitcoinKeyedHolder.sol` (the holder), `BIP322.sol` (BIP-322 "simple" verification), `BIP340.sol` (Schnorr through `ecrecover`) |
| `contracts/test/`, `contracts/foundry.toml` | 231 Foundry tests, 65 of them fuzz tests: every vector below, the tests of the three reviews, differential and batch-property tests |
| `vectors/creation-code.hex` | the normative creation code of §3.2 (7,869 bytes) |
| `vectors/vectors.json`, `vectors/batch-vectors.json` | holder addresses, messages, signatures and calls from three public test keys, in the format the draft's Test Cases describe |
| `vectors/wallet-*.json` | the output of four browser wallets (UniSat 1.7.22, Xverse 2.9.3, Leather 6.114.0, OKX Wallet 4.18.1) for a P2TR and a P2WPKH address, single and batch messages; `vectors/legacy/` is the same for earlier builds |
| `vectors/upstream/` | BIP-340 and BIP-322 vectors copied from bitcoin/bips at the commit in `BIPS_COMMIT` |
| `vectors/text-corpus.json`, `vectors/diff-fuzz-corpus.json` | inputs of the signer check against bip322-js |
| `tools/` | Python, standard library only: secp256k1, BIP-340, RFC 6979, bech32/bech32m, BIP-322, holder addresses and the three message formats (`holder.py`, `btc.py`), vector generators (`make_*.py`), a command-line tool (`cli.py`) and a local page that asks a browser wallet to sign (`sign.html`) |
| `tools/wallet-lib-check/` | JavaScript signer check against bip322-js, pinned to exact package versions, with its results |
| `interop/run.sh`, `interop/run.log` | an unmodified TAP-11 client (TapeAPI SDK) resolving a delegation signed by a Bitcoin key on a local fork |
| `interop/unisat-extension/`, `interop/wallet-matrix/` | how the wallet outputs were obtained, with screenshots and findings |
| `scripts/demo_fork.sh`, `scripts/mining/`, `scripts/logs/` | the end-to-end flows on local forks of BNB Smart Chain, Base and X Layer, and their logs; `scripts/live_conformance.py` runs the shipped runtime on the live chains through `eth_call` with a state override, without sending anything |
| `scripts/final_gas.sh`, `scripts/logs/final-gas/` | the gas measurements |
| `docs/` | `TEST-REPORT.md` (what the tests show, file by file), `TEST-RUN-2026-10-13.txt` (the recorded run), `AUDIT-2026-10-10.md` and `AUDIT-2026-10-13.md` (the reviews the author organised; not third-party audits), `FINAL-GAS.md`, `GAS-REPORT.md`, `GAS-PROFILE.md`, `BATCH-SPEC.md`, `BATCH-REPORT.md`, `BATCH-UX.md`, `INTEGRATION-NOTES.md` |

## Checking it

Run from this directory.

```
# 1. the creation code of §3.2
python3 -c "import tools.keccak as k; print(k.keccak256(bytes.fromhex(open('vectors/creation-code.hex').read().strip())).hex())"
# 0x4bc9698ad9224fefccd7ba5d7205c1c0e8e9117eb53257873e64fae37f499c4f

# 2. the contracts: Foundry and forge-std v1.17.0
cd contracts && forge install foundry-rs/forge-std@v1.17.0 && forge build && forge test && cd ..
# 231 passed; the build's creation code is byte for byte vectors/creation-code.hex (solc 0.8.28, shanghai, optimizer 200 runs, viaIR, no metadata)

# 3. the vectors reproduce from the test keys (plain python3, after the build above: the script reads the build artifact and imports its sibling btc.py)
python3 tools/make_vectors.py --check
```

`interop/run.sh` and `scripts/demo_fork.sh` need Foundry's `anvil` and an RPC endpoint of the chain they fork; their recorded logs sit next to them.

## What this package does not claim

The reviews are the author's own adversarial rounds, not a third-party audit. Four browser wallets were tested, no hardware signer and not Sparrow. The TAP-11 client used in `interop/` is the author's own. The wallets' extensions were exercised as any web page can call them; no wallet vendor has reviewed or endorsed this draft. See the draft's Security Considerations for the limits that matter to users.
