# SPDX-License-Identifier: MIT
"""Builds vectors/wallet-unisat-1.7.22.json and vectors/wallet-unisat-1.7.22-batch.json from the raw outputs of
the UniSat browser extension 1.7.22 in interop/unisat-extension/results/unisat-1.7.22-merged-*.json
(steps/sign.mjs and steps/batch.mjs). Nothing is edited by hand: every message text is rebuilt here from its
fields with tools/holder.py for the holder of the current creation code and must equal the text the wallet
signed; every wallet output is decoded with the §6.1 rules (btc.witness_from_wallet), must equal the witness
the run recorded, and must verify with the reference verifier. Run after `forge build`.
usage: python3 tools/make_wallet_vectors.py"""
import json
import os
import re

import btc
import holder as H
from keccak import keccak256

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
RES = os.path.join(ROOT, "interop", "unisat-extension", "results")
WALLET = "UniSat browser extension 1.7.22 (Chrome Web Store), run on 2026-10-10"
NOTE = ("Signatures made by the wallet's own signMessage(msg, 'bip322-simple') for the public BIP-39 test mnemonic "
        "'abandon ... about'; never fund these addresses.")
KINDS = (("p2tr", "Taproot (P2TR)"), ("p2wpkh", "Native Segwit (P2WPKH)"))
U64, U256 = 2**64 - 1, 2**256 - 1


def x(b):
    return "0x" + b.hex()


def h2b(s):
    return bytes.fromhex(s[2:] if s.startswith("0x") else s)


def witness(out, recorded=None):
    w = btc.witness_from_wallet(out)
    if recorded is not None:
        assert w == h2b(recorded), "decoded wallet output differs from the recorded witness"
    return w


def check(spk, msg, w):
    assert btc.verify_simple(spk, msg, w), msg[:80]


code_hash = keccak256(H.creation_code())
single, batch = [], []
for kind, atype in KINDS:
    d = json.load(open(os.path.join(RES, f"unisat-1.7.22-merged-{kind}.json")))
    assert d["atype"] == atype and d["ext"] == "1.7.22"
    addr = d["accounts"][0]
    spk = btc.script_pubkey(addr)
    holder = H.holder_address(spk)
    ex = d["exec"]
    assert h2b(ex["holder"]) == holder, "the run used another holder address than the current build's"
    s = d["signs"]
    # §5.1
    digest = bytes([0xAB]) * 32
    m1 = H.sign_message(holder, 56, digest)
    assert s["sign"]["message"].encode() == m1
    w1 = witness(s["sign"]["result"]["ok"], s["sign"]["cliWitness"])
    check(spk, m1, w1)
    # §5.2, a real ERC-721 transfer out of the holder
    data = h2b(ex["data"])
    assert data[:4] == keccak256(b"transferFrom(address,address,uint256)")[:4] and data[16:36] == holder
    m2 = H.call_message(holder, 56, h2b(ex["nft"]), 0, data, ex["callGas"], ex["tip"], 0, ex["deadline"])
    assert s["exec"]["message"].encode() == m2
    w2 = witness(s["exec"]["result"]["ok"], s["exec"]["cliWitness"])
    check(spk, m2, w2)
    # §5.2, an empty call at nonce 1 (to an address without code, no data, callGas 0)
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
        "signDigest": x(digest), "signMessage": m1.decode(), "signWitness": x(w1), "signWalletOutput": s["sign"]["result"]["ok"],
        "exec": {"target": ex["nft"], "tokenId": ex["tokenId"], "recipient": ex["recipient"], "data": ex["data"],
                 "callGas": ex["callGas"], "tip": ex["tip"], "nonce": 0, "deadline": ex["deadline"], "message": m2.decode(),
                 "witness": x(w2), "walletOutput": s["exec"]["result"]["ok"]},
        "call": {"target": x(ctarget), "value": 0, "data": "0x", "callGas": 0, "tip": 0, "nonce": 1, "deadline": cdl,
                 "message": m3.decode(), "witness": x(w3), "walletOutput": s["call"]["result"]["ok"]},
    })

    b = json.load(open(os.path.join(RES, f"unisat-1.7.22-merged-batch-{kind}.json")))
    assert b["atype"] == atype and b["address"] == addr and h2b(b["holder"]) == holder and h2b(b["scriptPubKey"]) == spk
    cases = {}
    for name, key in (("transfers-8", "transfers_8"), ("mixed-3", "mixed_3"), ("longest", "longest")):
        c = b["cases"][name]
        if name == "longest":  # the run's JSON holds these numbers as floats; the exact values of steps/batch.mjs
            calls = [(b"\xff" * 20, U256, b"x" * 100, U64)] * 8
            chain, tip, nonce, dl = U64, U256, U256, U64
        else:
            calls = [(h2b(k["target"]), int(k["value"]), h2b(k["data"]), int(k["callGas"])) for k in c["calls"]]
            chain, tip, nonce, dl = int(c["chainId"]), int(c["tip"]), int(c["nonce"]), int(c["deadline"])
        m = H.batch_message(holder, chain, calls, tip, nonce, dl)
        assert c["message"].encode() == m and len(m) == c["chars"], name
        assert c["popupContainsFullText"] is True and c["cliVerify"] == "valid", name
        w = witness(c["result"]["ok"], c["witness"])
        check(spk, m, w)
        cases[key] = {"chainId": str(chain), "tip": str(tip), "nonce": str(nonce), "deadline": str(dl), "chars": len(m),
                      "calls": [{"target": x(t), "value": str(v), "data": x(dd), "callGas": str(gg)} for t, v, dd, gg in calls],
                      "message": m.decode(), "witness": x(w), "walletOutput": c["result"]["ok"],
                      "popupContainsFullText": True, "popupLayout": c["popupLayout"]}
    batch.append({"kind": kind, "bitcoinAddress": addr, "scriptPubKey": x(spk), "holder": x(holder), "cases": cases})

json.dump({"format": "tap-bitcoin-keyed-holders-wallet-vectors/2", "wallet": WALLET, "note": NOTE,
           "creationCodeKeccak": x(code_hash), "cases": single},
          open(os.path.join(ROOT, "vectors", "wallet-unisat-1.7.22.json"), "w"), indent=1)
json.dump({"format": "tap-bitcoin-keyed-holders-wallet-batch-vectors/2", "wallet": WALLET, "note": NOTE,
           "creationCodeKeccak": x(code_hash), "results": batch},
          open(os.path.join(ROOT, "vectors", "wallet-unisat-1.7.22-batch.json"), "w"), indent=1)
print("wallet vectors: %d addresses x (1 sign + 2 call) single, %d x 3 batch texts (%s chars); holders %s" % (
    len(single), len(batch), "/".join(str(c["chars"]) for c in batch[0]["cases"].values()),
    ", ".join(c["holder"] for c in single)))
