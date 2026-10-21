# SPDX-License-Identifier: MIT
"""Builds vectors/text-corpus.json and contracts/test/batch/GeneratedTextCorpus.sol: signed §5.1, §5.2 and
§5.3 messages whose text is written by tools/holder.py (Python), never read from the contract, for 1 to 8
calls and edge values (0, 1, 9, 10, 2^64 - 1, 2^256 - 1, addresses with leading zeros, chain IDs 1, 56 and
2^64 - 1, nonces up to 2^256 - 1, empty and long data). The Foundry test (TextCorpusTest) feeds the Python
signatures to isValidSignature, execute and executeBatch, so a writer bug that affected the contract's view
functions and its verification path alike could not hide (audit F-04). Uses the public TEST keys of
tools/cli.py (they hold nothing). Deterministic; run after `forge build`."""
import json
import os

import btc
import cli
import holder as H
from keccak import keccak256

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
U64, U256 = 2**64 - 1, 2**256 - 1
ADDRS = [bytes(20), bytes(19) + b"\x01", bytes.fromhex("0000000000000000000000000000000000001234"),
         bytes.fromhex("00000000000000ffffffffffffffffffffffffff"), b"\xff" * 20,
         bytes.fromhex("00000000000000000000000000000000000000b0")]
VALUES = [0, 1, 9, 10, 99, 100, 10**18, U64, 2**64, U256 - 1, U256]
GASES = [0, 1, 9, 10, 2300, 100000, U64]
DATAS = [b"", b"\x00", b"\xff" * 100, bytes(range(33))]
CHAINS = [1, 56, U64]
DEADLINES = [1, 9, 10, 2_000_000_000, U64]
NONCES = [0, 1, 9, 10, U64, U256 - 1]  # the test stores the nonce; 2^256 - 1 would overflow on success
TIPS = [0, 1, 10**16, U256]


def pick(xs, i):
    return xs[i % len(xs)]


holders = {}
for kind in ("p2tr", "p2wpkh"):
    sk, spk = cli.test_key(kind)
    holders[kind] = (sk, spk, H.holder_address(spk))

batches, calls1, signs = [], [], []
n = 0
for kind in ("p2tr", "p2wpkh"):
    sk, spk, h = holders[kind]
    for k in range(1, 9):
        for variant in range(3):  # 0: edge values; 1: an executable batch; 2: other edge values
            n += 1
            if variant == 1:
                cs = [(pick([ADDRS[0], ADDRS[2], ADDRS[3], ADDRS[5]], n + j), j % 2, b"", pick([0, 2300], j)) for j in range(k)]
                chain, nonce, tip, dl = pick(CHAINS, n), pick([0, 1, 9, 10, U64], n), pick([0, 1, 10**16], n), pick(DEADLINES, n)
            else:
                cs = [(pick(ADDRS, n * 3 + j + variant), pick(VALUES, n * 5 + j * 7 + variant), pick(DATAS, n + j),
                       pick(GASES, n * 2 + j + variant)) for j in range(k)]
                chain, nonce, tip, dl = pick(CHAINS, n + variant), pick(NONCES, n * 3 + variant), pick(TIPS, n + k), pick(DEADLINES, n * 7 + variant)
            msg = H.batch_message(h, chain, cs, tip, nonce, dl)
            assert H.parse_batch_message(msg)[0] == h
            sig = btc.sign_simple(sk, spk, msg)
            batches.append({"holder": kind, "executable": variant == 1, "chainId": chain, "nonce": nonce, "tip": tip,
                            "deadline": dl, "calls": [(t, v, d, g) for t, v, d, g in cs], "message": msg, "sig": sig})
    for i in range(12):
        t, v, d, g = pick(ADDRS, i), pick(VALUES, i * 3 + 1), pick(DATAS, i), pick(GASES, i * 5 + 2)
        executable = i % 4 == 1
        if executable:
            t, v, d, g = ADDRS[2], i % 2, b"", 0  # no code there (0x01 would be a precompile)
        chain, nonce, tip, dl = pick(CHAINS, i), pick(NONCES, i * 2), pick(TIPS, i) if not executable else 0, pick(DEADLINES, i + 1)
        msg = H.call_message(h, chain, t, v, d, g, tip, nonce, dl)
        calls1.append({"holder": kind, "executable": executable, "chainId": chain, "nonce": nonce, "tip": tip, "deadline": dl,
                       "call": (t, v, d, g), "message": msg, "sig": btc.sign_simple(sk, spk, msg)})
    for i, digest in enumerate([bytes(32), b"\xff" * 32, bytes(31) + b"\x01", bytes.fromhex("00" * 16 + "ab" * 16)]):
        chain = pick(CHAINS, i)
        msg = H.sign_message(h, chain, digest)
        signs.append({"holder": kind, "chainId": chain, "digest": digest, "message": msg, "sig": btc.sign_simple(sk, spk, msg)})


def x(b):
    return "0x" + b.hex()


def jcall(c):
    t, v, d, g = c
    return {"target": x(t), "value": str(v), "data": x(d), "callGas": str(g)}


json.dump({
    "format": "tap-bitcoin-keyed-holders-text-corpus/1",
    "note": "Message texts written by tools/holder.py, signed by tools/btc.py with the public TEST keys. Never fund them.",
    "creationCodeKeccak": x(keccak256(H.creation_code())),
    "holders": {k: {"scriptPubKey": x(v[1]), "holder": x(v[2])} for k, v in holders.items()},
    "batches": [{**{k: v for k, v in b.items() if k not in ("calls", "message", "sig")}, "nonce": str(b["nonce"]), "tip": str(b["tip"]),
                 "calls": [jcall(c) for c in b["calls"]], "message": b["message"].decode(), "signature": x(b["sig"])} for b in batches],
    "calls": [{**{k: v for k, v in c.items() if k not in ("call", "message", "sig")}, "nonce": str(c["nonce"]), "tip": str(c["tip"]),
               **jcall(c["call"]), "message": c["message"].decode(), "signature": x(c["sig"])} for c in calls1],
    "signs": [{"holder": s["holder"], "chainId": s["chainId"], "digest": x(s["digest"]), "message": s["message"].decode(),
               "signature": x(s["sig"])} for s in signs],
}, open(os.path.join(ROOT, "vectors", "text-corpus.json"), "w"), indent=1)


def sb(b):
    return f'hex"{b.hex()}"'


def addr(b):
    return f'address(bytes20(hex"{b.hex()}"))'


idx = {"p2tr": 0, "p2wpkh": 1}
L = ["// SPDX-License-Identifier: MIT", "pragma solidity 0.8.28;",
     "// GENERATED by tools/make_text_corpus.py from the same data as vectors/text-corpus.json. Do not edit.", "",
     'import {BitcoinKeyedHolder as B} from "../../src/BitcoinKeyedHolder.sol";', "",
     "library GeneratedTextCorpus {",
     f"    bytes32 internal constant CREATION_CODE_KECCAK = {x(keccak256(H.creation_code()))};"]
for k, v in holders.items():
    L.append(f"    bytes internal constant SPK_{k.upper()} = {sb(v[1])};")
    L.append(f"    address internal constant HOLDER_{k.upper()} = {addr(v[2])};")
L += ["    struct BatchCase { uint8 holder; bool executable; uint256 chainId; uint256 nonce; uint256 tip; uint64 deadline; "
      "B.Call[] calls; bytes message; bytes sig; }",
      "    struct CallCase { uint8 holder; bool executable; uint256 chainId; uint256 nonce; uint256 tip; uint64 deadline; "
      "B.Call call; bytes message; bytes sig; }",
      "    struct SignCase { uint8 holder; uint256 chainId; bytes32 digest; bytes message; bytes sig; }",
      f"    function batchCount() internal pure returns (uint256) {{ return {len(batches)}; }}",
      f"    function callCount() internal pure returns (uint256) {{ return {len(calls1)}; }}",
      f"    function signCount() internal pure returns (uint256) {{ return {len(signs)}; }}",
      "    function batchCase(uint256 i) internal pure returns (BatchCase memory c) {"]
for i, b in enumerate(batches):
    L.append(f"        if (i == {i}) {{")
    L.append(f"            c.holder = {idx[b['holder']]}; c.executable = {str(b['executable']).lower()}; c.chainId = {b['chainId']}; "
             f"c.nonce = {b['nonce']}; c.tip = {b['tip']}; c.deadline = {b['deadline']};")
    L.append(f"            c.calls = new B.Call[]({len(b['calls'])});")
    for j, (t, v, d, g) in enumerate(b["calls"]):
        L.append(f"            c.calls[{j}] = B.Call({addr(t)}, {v}, {sb(d)}, {g});")
    L.append(f"            c.message = {sb(b['message'])};")
    L.append(f"            c.sig = {sb(b['sig'])};")
    L.append("        }")
L.append("    }")
L.append("    function callCase(uint256 i) internal pure returns (CallCase memory c) {")
for i, c in enumerate(calls1):
    t, v, d, g = c["call"]
    L.append(f"        if (i == {i}) {{")
    L.append(f"            c.holder = {idx[c['holder']]}; c.executable = {str(c['executable']).lower()}; c.chainId = {c['chainId']}; "
             f"c.nonce = {c['nonce']}; c.tip = {c['tip']}; c.deadline = {c['deadline']};")
    L.append(f"            c.call = B.Call({addr(t)}, {v}, {sb(d)}, {g});")
    L.append(f"            c.message = {sb(c['message'])};")
    L.append(f"            c.sig = {sb(c['sig'])};")
    L.append("        }")
L.append("    }")
L.append("    function signCase(uint256 i) internal pure returns (SignCase memory c) {")
for i, s in enumerate(signs):
    L.append(f"        if (i == {i}) {{ c.holder = {idx[s['holder']]}; c.chainId = {s['chainId']}; c.digest = 0x{s['digest'].hex()}; "
             f"c.message = {sb(s['message'])}; c.sig = {sb(s['sig'])}; }}")
L.append("    }")
L.append("}")
open(os.path.join(ROOT, "contracts", "test", "batch", "GeneratedTextCorpus.sol"), "w").write("\n".join(L) + "\n")
print("text corpus: %d batches (%d executable), %d calls, %d sign cases; batch message lengths %d..%d" % (
    len(batches), sum(b["executable"] for b in batches), len(calls1), len(signs),
    min(len(b["message"]) for b in batches), max(len(b["message"]) for b in batches)))
