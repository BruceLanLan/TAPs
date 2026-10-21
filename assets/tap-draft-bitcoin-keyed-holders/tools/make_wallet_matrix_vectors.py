# SPDX-License-Identifier: MIT
"""Builds vectors/wallet-<name>-<version>.json and vectors/wallet-<name>-<version>-batch.json for the wallet matrix
(Xverse, Leather, OKX; the format of tools/make_wallet_vectors.py, which does UniSat) from the raw results of the
wallet-matrix run in interop/wallet-matrix/results/<name>/. Nothing is edited by hand: every message text is rebuilt
with tools/holder.py and must equal the text the wallet signed; every wallet output (the base64 string: for Xverse
and Leather the JSON-RPC field result.signature, which is wallet API, not TAP) is decoded with the §6.1 rules
(btc.witness_from_wallet), must equal the witness the run recorded, and must verify with the reference verifier.
Run after `forge build`.
usage: python3 tools/make_wallet_matrix_vectors.py            (all three wallets)"""
import json
import os
import re
import sys

import btc
import holder as H
from keccak import keccak256

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
WALLETS = [("xverse", "2.9.3", "Xverse browser extension 2.9.3 (Chrome Web Store), run on 2026-10-11"),
           ("leather", "6.114.0", "Leather browser extension 6.114.0 (Chrome Web Store), run on 2026-10-11"),
           ("okx", "4.18.1", "OKX Wallet browser extension 4.18.1 (Chrome Web Store), run on 2026-10-11")]


def build(NAME, VER, DESC):
    RES = os.path.join(ROOT, "interop", "wallet-matrix", "results", NAME)
    NOTE = {"xverse": "Signatures made by the wallet's own XverseProviders.BitcoinProvider.request('signMessage', {address, message, protocol: 'BIP322'}) (result.signature)",
            "leather": "Signatures made by the wallet's own LeatherProvider.request('signMessage', {message, paymentType, network: 'mainnet'}) (result.signature)",
            "okx": "Signatures made by the wallet's own okxwallet.bitcoin.signMessage(message, 'bip322-simple') with the BTC preferred address set to Taproot or Native SegWit"}[NAME]
    NOTE += " for the public BIP-39 test mnemonic 'abandon ... about'; never fund these addresses."
    U64, U256 = 2**64 - 1, 2**256 - 1


    def x(b):
        return "0x" + b.hex()


    def h2b(s):
        return bytes.fromhex(s[2:] if s.startswith("0x") else s)


    def witness(out, recorded):
        w = btc.witness_from_wallet(out)
        assert w == h2b(recorded), "decoded wallet output differs from the recorded witness"
        return w


    def check(spk, msg, w):
        assert btc.verify_simple(spk, msg, w), msg[:80]


    def shown(c):
        """Whether the confirmation page showed the whole text: at once, or after the user opened it (Xverse, OKX)."""
        e = c.get("expanded")
        return bool(c["popupContainsFullText"] if e is None else e["popupContainsFullText"])


    code_hash = keccak256(H.creation_code())
    single, batch = [], []
    for kind in ("p2tr", "p2wpkh"):
        d = json.load(open(os.path.join(RES, f"{NAME}-{VER}-{kind}.json")))
        assert d["atype"] == kind and d["ext"] == VER
        addr = d["accounts"][0]
        spk = btc.script_pubkey(addr)
        holder = H.holder_address(spk)
        ex = d["exec"]
        assert h2b(ex["holder"]) == holder, "the run used another holder address than the current build's"
        s = d["signs"]
        m1 = H.sign_message(holder, 56, bytes([0xAB]) * 32)
        assert s["sign"]["message"].encode() == m1
        w1 = witness(s["sign"]["result"]["ok"], s["sign"]["cliWitness"])
        check(spk, m1, w1)
        data = h2b(ex["data"])
        assert data[:4] == keccak256(b"transferFrom(address,address,uint256)")[:4] and data[16:36] == holder
        m2 = H.call_message(holder, 56, h2b(ex["nft"]), 0, data, ex["callGas"], ex["tip"], 0, ex["deadline"])
        assert s["exec"]["message"].encode() == m2
        w2 = witness(s["exec"]["result"]["ok"], s["exec"]["cliWitness"])
        check(spk, m2, w2)
        g = re.fullmatch(r"TapeOut Bitcoin-keyed holder 0x[0-9a-f]{40} on chain 56 calls 0x([0-9a-f]{40}) with value 0 and data "
                         r"0x[0-9a-f]{64}, gas 0, tip 0, nonce 1, valid until ([0-9]+)", s["call"]["message"])
        assert g, "unexpected call message"
        ctarget, cdl = bytes.fromhex(g.group(1)), int(g.group(2))
        m3 = H.call_message(holder, 56, ctarget, 0, b"", 0, 0, 1, cdl)
        assert s["call"]["message"].encode() == m3
        w3 = witness(s["call"]["result"]["ok"], s["call"]["cliWitness"])
        check(spk, m3, w3)
        single.append({
            "kind": kind, "bitcoinAddress": addr, "scriptPubKey": x(spk), "holder": x(holder), "chainId": 56,
            "signDigest": x(bytes([0xAB]) * 32), "signMessage": m1.decode(), "signWitness": x(w1), "signWalletOutput": s["sign"]["result"]["ok"],
            "exec": {"target": ex["nft"], "tokenId": ex["tokenId"], "recipient": ex["recipient"], "data": ex["data"],
                     "callGas": ex["callGas"], "tip": ex["tip"], "nonce": 0, "deadline": ex["deadline"], "message": m2.decode(),
                     "witness": x(w2), "walletOutput": s["exec"]["result"]["ok"]},
            "call": {"target": x(ctarget), "value": 0, "data": "0x", "callGas": 0, "tip": 0, "nonce": 1, "deadline": cdl,
                     "message": m3.decode(), "witness": x(w3), "walletOutput": s["call"]["result"]["ok"]},
        })
        b = json.load(open(os.path.join(RES, f"{NAME}-{VER}-batch-{kind}.json")))
        assert b["atype"] == kind and b["address"] == addr and h2b(b["holder"]) == holder and h2b(b["scriptPubKey"]) == spk
        cases = {}
        for name, key in (("transfers-8", "transfers_8"), ("mixed-3", "mixed_3"), ("longest", "longest")):
            c = b["cases"][name]
            calls = [(h2b(k["target"]), int(k["value"]), h2b(k["data"]), int(k["callGas"])) for k in c["calls"]]
            chain, tip, nonce, dl = int(c["chainId"]), int(c["tip"]), int(c["nonce"]), int(c["deadline"])
            m = H.batch_message(holder, chain, calls, tip, nonce, dl)
            assert c["message"].encode() == m and len(m) == c["chars"], name
            assert shown(c) and c["cliVerify"] == "valid", name
            w = witness(c["result"]["ok"], c["cliWitness"])
            check(spk, m, w)
            view = c.get("expanded") or c
            cases[key] = {"chainId": str(chain), "tip": str(tip), "nonce": str(nonce), "deadline": str(dl), "chars": len(m),
                          "calls": [{"target": x(t), "value": str(v), "data": x(dd), "callGas": str(gg)} for t, v, dd, gg in calls],
                          "message": m.decode(), "witness": x(w), "walletOutput": c["result"]["ok"],
                          "popupContainsFullText": True, "popupLayout": view["popupLayout"]}
        batch.append({"kind": kind, "bitcoinAddress": addr, "scriptPubKey": x(spk), "holder": x(holder), "cases": cases})

    os.makedirs(os.path.join(ROOT, "vectors"), exist_ok=True)
    json.dump({"format": "tap-bitcoin-keyed-holders-wallet-vectors/2", "wallet": DESC, "note": NOTE,
               "creationCodeKeccak": x(code_hash), "cases": single},
              open(os.path.join(ROOT, "vectors", f"wallet-{NAME}-{VER}.json"), "w"), indent=1)
    json.dump({"format": "tap-bitcoin-keyed-holders-wallet-batch-vectors/2", "wallet": DESC, "note": NOTE,
               "creationCodeKeccak": x(code_hash), "results": batch},
              open(os.path.join(ROOT, "vectors", f"wallet-{NAME}-{VER}-batch.json"), "w"), indent=1)
    print("%s %s: %d addresses x (1 sign + 2 call) single, 3 batch texts each; holders %s" % (
        NAME, VER, len(single), ", ".join(c["holder"] for c in single)))


for _name, _ver, _desc in WALLETS:
    build(_name, _ver, _desc)
