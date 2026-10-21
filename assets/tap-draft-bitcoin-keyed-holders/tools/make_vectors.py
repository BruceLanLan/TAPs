# SPDX-License-Identifier: MIT
"""Builds vectors/vectors.json and contracts/test/Generated.t.sol from the compiled contract and fixed test keys.

Run after `forge build` in contracts/: python3 tools/make_vectors.py
"""
import csv
import json
import os

import btc
import holder as H
from keccak import keccak256

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
UP = os.path.join(ROOT, "vectors", "upstream")
x = lambda b: "0x" + b.hex()


def key(label):
    return int.from_bytes(btc.sha256(("tap-bitcoin-keyed-holders vector key " + label).encode()), "big") % btc.N


K1, K2, K3 = key("1"), key("2"), key("3")
SPK1 = b"\x51\x20" + btc.taproot_tweak(K1)[1]  # P2TR
SPK2 = b"\x00\x14" + btc.hash160(btc.compressed(btc.mul(K2)))  # P2WPKH
SPK3 = b"\x51\x20" + btc.taproot_tweak(K3)[1]  # another P2TR key, for wrong-key cases
CODE = H.creation_code()
holders = {}
for name, sk, spk in (("p2tr", K1, SPK1), ("p2wpkh", K2, SPK2), ("p2tr-other", K3, SPK3)):
    ver = 1 if spk[0] == 0x51 else 0
    holders[name] = {"secret": sk, "spk": spk, "address": btc.segwit_address(ver, spk[2:]),
                     "holder": H.holder_address(spk, CODE), "initCodeHash": keccak256(H.init_code(spk, CODE))}

CHAINS = (56, 8453, 196)
sign_cases = []


def add_sign(name, holder_name, chain, digest, sig, expect, note):
    hd = holders[holder_name]
    sign_cases.append({"name": name, "holder": holder_name, "chainId": chain, "digest": x(digest),
                       "message": H.sign_message(hd["holder"], chain, digest).decode(),
                       "signature": x(sig), "expect": expect, "note": note})


for chain in CHAINS:
    d = keccak256(b"tap-bitcoin-keyed-holders digest on chain " + str(chain).encode())
    for hn in ("p2tr", "p2wpkh"):
        hd = holders[hn]
        msg = H.sign_message(hd["holder"], chain, d)
        add_sign(f"{hn}-{chain}", hn, chain, d, btc.sign_simple(hd["secret"], hd["spk"], msg), True,
                 "SIGHASH_DEFAULT" if hn == "p2tr" else "SIGHASH_ALL, strict DER, low s")
    hd = holders["p2tr"]
    add_sign(f"p2tr-sighash-all-{chain}", "p2tr", chain, d,
             btc.sign_simple(hd["secret"], hd["spk"], H.sign_message(hd["holder"], chain, d), sighash_all=True), True,
             "65-byte signature with SIGHASH_ALL, as Sparrow produces")

# A real TAP-11 §4.1 delegation digest: the holder authorises a service signer for its circuit's container.
HUB = bytes.fromhex("e61a9c7213a6aa616c246a2b569e555b417b25ee")
CONTAINER = bytes.fromhex("00000000000000000000000000000000000c0b7a")
SIGNER = bytes.fromhex("000000000000000000000000000000000005197e")
EXPIRES = 1790000000
w32 = lambda b: bytes(32 - len(b)) + b
domain = keccak256(keccak256(b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
                   + keccak256(b"TapeAPI") + keccak256(b"1") + (56).to_bytes(32, "big") + w32(HUB))
typehash = keccak256(b"Delegation(address container,address signer,uint64 expires)")
assert typehash.hex() == "c5081f9dc7e79dfbe7f3b3220ed9e7a29d0bc53239ee74dc184e4ac1f810948c"
tap11 = keccak256(b"\x19\x01" + domain + keccak256(typehash + w32(CONTAINER) + w32(SIGNER) + EXPIRES.to_bytes(32, "big")))
TAP11 = {"chainId": 56, "hub": x(HUB), "container": x(CONTAINER), "signer": x(SIGNER), "expires": EXPIRES, "digest": x(tap11)}
for hn in ("p2tr", "p2wpkh"):
    hd = holders[hn]
    add_sign(f"tap11-delegation-{hn}", hn, 56, tap11,
             btc.sign_simple(hd["secret"], hd["spk"], H.sign_message(hd["holder"], 56, tap11)), True,
             "a TAP-11 §4.1 Delegation digest (container, signer and expires in tap11Delegation)")

# Negative cases, all on chain 56.
D = keccak256(b"tap-bitcoin-keyed-holders digest on chain 56")
D2 = keccak256(b"another digest")
t, w = holders["p2tr"], holders["p2wpkh"]
good_tr = btc.sign_simple(t["secret"], t["spk"], H.sign_message(t["holder"], 56, D))
good_wp = btc.sign_simple(w["secret"], w["spk"], H.sign_message(w["holder"], 56, D))
add_sign("wrong-chain", "p2tr", 8453, D, good_tr, False, "signed for chain 56, checked on chain 8453")
add_sign("other-holder", "p2tr", 56, D, good_wp, False, "the P2WPKH holder's signature given to the P2TR holder")
add_sign("other-digest", "p2tr", 56, D2, good_tr, False, "signature over another digest")
o = holders["p2tr-other"]
add_sign("wrong-key", "p2tr", 56, D, btc.sign_simple(o["secret"], o["spk"], H.sign_message(t["holder"], 56, D)), False,
         "the right message signed by another key")
add_sign("raw-65-bytes", "p2tr", 56, D, good_tr[2:] + b"\x01", False,
         "65 bytes: TAP-11 §4.4 clients read this as ECDSA and never reach EIP-1271; the holder rejects it too")
add_sign("hash-type-zero-explicit", "p2tr", 56, D, b"\x01\x41" + good_tr[2:] + b"\x00", False,
         "SIGHASH_DEFAULT spelled as a 65-byte signature is invalid under BIP-341")
add_sign("hash-type-none", "p2tr", 56, D, b"\x01\x41" + good_tr[2:] + b"\x02", False, "SIGHASH_NONE is not accepted")
add_sign("p2tr-two-items", "p2tr", 56, D, b"\x02\x40" + good_tr[2:], False, "witness that claims two stack items")
# P2WPKH malleations
sl = good_wp[1]
der_sig = good_wp[2:1 + sl]
r, s = btc.parse_der_strict(der_sig)


def wp_with(der_bytes):
    d = der_bytes + b"\x01"
    return b"\x02" + bytes([len(d)]) + d + good_wp[2 + sl:]


add_sign("high-s", "p2wpkh", 56, D, wp_with(btc.der(r, btc.N - s)), False, "the same signature with s replaced by n - s")
pad = lambda v: b"\x02" + bytes([len(v) + 1]) + b"\x00" + v
rb = r.to_bytes(32, "big").lstrip(b"\x00")
rb = b"\x00" + rb if rb[0] & 0x80 else rb
sb = s.to_bytes(32, "big").lstrip(b"\x00")
sb = b"\x00" + sb if sb[0] & 0x80 else sb
nonmin = pad(rb) + b"\x02" + bytes([len(sb)]) + sb
add_sign("non-minimal-der", "p2wpkh", 56, D, wp_with(b"\x30" + bytes([len(nonmin)]) + nonmin), False,
         "r encoded with an unnecessary leading zero byte")
uncompressed = btc.mul(w["secret"])
add_sign("uncompressed-key", "p2wpkh", 56, D,
         good_wp[:2 + sl] + b"\x41\x04" + uncompressed[0].to_bytes(32, "big") + uncompressed[1].to_bytes(32, "big"),
         False, "an uncompressed key: wrong length and wrong hash160")
add_sign("empty", "p2tr", 56, D, b"", False, "no signature")
# The same negative classes for the P2WPKH holder (so that an implementation of the P2WPKH path alone has them too).
add_sign("p2wpkh-wrong-chain", "p2wpkh", 8453, D, good_wp, False, "signed for chain 56, checked on chain 8453")
add_sign("p2wpkh-other-holder", "p2wpkh", 56, D, good_tr, False, "the P2TR holder's signature given to the P2WPKH holder")
add_sign("p2wpkh-other-digest", "p2wpkh", 56, D2, good_wp, False, "signature over another digest")
spk3w = b"\x00\x14" + btc.hash160(btc.compressed(btc.mul(K3)))
add_sign("p2wpkh-wrong-key", "p2wpkh", 56, D, btc.sign_simple(K3, spk3w, H.sign_message(w["holder"], 56, D)), False,
         "the right message signed by another P2WPKH key: valid ECDSA, but its hash160 is not the holder's")
add_sign("p2wpkh-hash-type-byte-2", "p2wpkh", 56, D, good_wp[:1 + sl] + b"\x02" + good_wp[2 + sl:], False,
         "the valid DER signature with its hash type byte changed from 0x01 to 0x02")

# execute(): transfer token 1 of a test ERC-721 from the holder to RECIPIENT.
TOKEN = bytes.fromhex("00000000000000000000000000000000000000c1")
RECIPIENT = bytes.fromhex("00000000000000000000000000000000000000b0")
DEADLINE = 2000000000
CALL_GAS = 100000
CALL_TIP = 0
call_cases = []
for hn in ("p2tr", "p2wpkh"):
    hd = holders[hn]
    data = bytes.fromhex("42842e0e") + bytes(12) + hd["holder"] + bytes(12) + RECIPIENT + (1).to_bytes(32, "big")
    msg = H.call_message(hd["holder"], 56, TOKEN, 0, data, CALL_GAS, CALL_TIP, 0, DEADLINE)
    call_cases.append({"name": f"transfer-{hn}", "holder": hn, "chainId": 56, "target": x(TOKEN), "value": 0,
                       "data": x(data), "gas": CALL_GAS, "tip": CALL_TIP, "nonce": 0, "deadline": DEADLINE, "message": msg.decode(),
                       "signature": x(btc.sign_simple(hd["secret"], hd["spk"], msg))})

# A plain value transfer: empty data to an address without code, callGas 0 (the EVM adds its stipend).
hd = holders["p2tr"]
msg = H.call_message(hd["holder"], 56, RECIPIENT, 10**18, b"", 0, 0, 1, DEADLINE)
call_cases.append({"name": "value-transfer-p2tr", "holder": "p2tr", "chainId": 56, "target": x(RECIPIENT), "value": 10**18,
                   "data": "0x", "gas": 0, "tip": 0, "nonce": 1, "deadline": DEADLINE, "message": msg.decode(),
                   "signature": x(btc.sign_simple(hd["secret"], hd["spk"], msg))})


# A call with a relay tip: the token goes to RECIPIENT and 0.01 coin to whoever relays it.
hd = holders["p2wpkh"]
tdata = bytes.fromhex("42842e0e") + bytes(12) + hd["holder"] + bytes(12) + RECIPIENT + (7).to_bytes(32, "big")
msg = H.call_message(hd["holder"], 56, TOKEN, 0, tdata, CALL_GAS, 10**16, 0, DEADLINE)
call_cases.append({"name": "token-with-tip-p2wpkh", "holder": "p2wpkh", "chainId": 56, "target": x(TOKEN), "value": 0,
                   "data": x(tdata), "gas": CALL_GAS, "tip": 10**16, "nonce": 0, "deadline": DEADLINE, "message": msg.decode(),
                   "signature": x(btc.sign_simple(hd["secret"], hd["spk"], msg))})

# Constructor acceptance (section 3.1).
def tr(xv):
    return b"\x51\x20" + xv.to_bytes(32, "big")


ctor = [("p2tr-test-key", SPK1), ("p2wpkh-test-key", SPK2), ("p2tr-x-1", tr(1)), ("p2tr-x-0", tr(0)),
        ("p2tr-x-5-not-on-curve", tr(5)), ("p2tr-x-n-minus-1", tr(btc.N - 1)), ("p2tr-x-n", tr(btc.N)),
        ("p2tr-x-p-minus-1", tr(btc.P - 1)), ("p2wsh", b"\x00\x20" + bytes(32)), ("p2tr-33-bytes", SPK1[:33]),
        ("p2wpkh-21-bytes", SPK2[:21]), ("wrong-prefix", b"\x51\x21" + SPK1[2:]), ("empty", b"")]


def ctor_ok(spk):
    if len(spk) == 34 and spk[:2] == b"\x51\x20":
        xv = int.from_bytes(spk[2:], "big")
        return xv != 0 and xv < btc.N and btc.lift_x(xv) is not None
    return len(spk) == 22 and spk[:2] == b"\x00\x14"


constructor_cases = [{"name": n, "scriptPubKey": x(v), "expect": "accept" if ctor_ok(v) else "reject"} for n, v in ctor]
assert [c["expect"] for c in constructor_cases][:4] == ["accept", "accept", "accept", "reject"]

# Human-readable parts (section 1): the same P2WPKH program under bc, tb and bcrt; only bc yields a holder.
hrp_cases = []
_p = btc.script_pubkey(holders["p2wpkh"]["address"])[2:]
for _h in ("bc", "tb", "bcrt"):
    _a = btc.segwit_address(0, _p, _h)
    try:
        btc.script_pubkey(_a)
        _r = "accept"
    except ValueError:
        _r = "reject"
    hrp_cases.append({"name": "p2wpkh-" + _h, "address": _a, "expect": _r})
assert [c["expect"] for c in hrp_cases] == ["accept", "reject", "reject"]

# Wallet output decoding (section 6.1).
import base64 as _b64

w_tr = btc.sign_simple(K1, SPK1, H.sign_message(holders["p2tr"]["holder"], 56, D), sighash_all=True)  # 67 bytes: base64 ends in "="
b = _b64.b64encode(w_tr).decode()
_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
assert b.endswith("=="), "the 67-byte signature has a one-byte tail: two characters and two padding characters"
_nz = b[:-3] + _ALPHA[_ALPHA.index(b[-3]) | 1] + "=="  # the same bytes, with unused bits that are not zero
assert _b64.b64decode(_nz) == w_tr and _nz != b
wallet = [("plain-base64", b), ("smp-marker", "smp" + b), ("surrounding-whitespace", " \t" + "smp" + b + "\r\n"),
          ("interior-space", b[:10] + " " + b[10:]), ("full-signature", "ful" + b), ("proof-of-funds", "pof" + b),
          ("missing-padding", b.rstrip("=")), ("uppercase-marker", "SMP" + b), ("not-base64", "smp" + b[:-4] + "!!!!"),
          ("padding-in-the-middle", b[:20] + "=" + b[21:]), ("extra-padding-character", b + "="),
          ("nonzero-trailing-bits", _nz)]
wallet_outputs = []
for n, v in wallet:
    try:
        out = x(btc.witness_from_wallet(v))
    except Exception:
        out = "reject"
    wallet_outputs.append({"name": n, "input": v, "expect": out})
_accept = {"plain-base64", "smp-marker", "surrounding-whitespace", "nonzero-trailing-bits"}
assert all((w["expect"] == x(w_tr)) == (w["name"] in _accept) and (w["expect"] == "reject") == (w["name"] not in _accept) for w in wallet_outputs)

# Signatures made by an independent BIP-322 library (tools/wallet-lib-check, see its sign.mjs).
lib_cases = []
lib_path = os.path.join(HERE, "wallet-lib-check", "results.json")
if os.path.exists(lib_path):
    lib_res = json.load(open(lib_path))
    for c in lib_res["tap"]["cases"]:
        if c["lib"] != "bip322-js@4.0.0":
            continue
        spk = btc.script_pubkey(c["address"])
        wit = btc.witness_from_wallet(c["signature"])
        assert btc.verify_simple(spk, c["message"].encode(), wit), c["messageKind"]
        holder_hex = c["message"].split("holder 0x")[1][:40]
        assert H.holder_address(spk).hex() == holder_hex, "holder address in the library's message differs from the build"
        lib_cases.append({"library": c["lib"], "address": c["address"], "scriptPubKey": x(spk), "kind": c["messageKind"],
                          "message": c["message"], "signature": c["signature"], "witness": x(wit), "expect": True})

# Library-level vectors from the BIPs, at a fixed commit.
bips_commit = open(os.path.join(UP, "BIPS_COMMIT")).read().strip()
bip340 = []
for row in csv.DictReader(open(os.path.join(UP, "test-vectors.csv"))):
    bip340.append({"index": int(row["index"]), "publicKey": "0x" + row["public key"].lower(),
                   "message": "0x" + row["message"].lower(), "signature": "0x" + row["signature"].lower(),
                   "expect": row["verification result"] == "TRUE"})
bip322 = []
for f in ("basic-test-vectors.json", "generated-test-vectors.json"):
    for v in json.load(open(os.path.join(UP, f)))["simple"]:
        if v["type"] not in ("p2tr", "p2wpkh"):
            continue
        spk = btc.script_pubkey(v["address"])
        for sg in v["bip322_signatures"]:
            wit = btc.witness_from_wallet(sg)
            assert btc.verify_simple(spk, v["message"].encode(), wit)
            bip322.append({"source": f, "type": v["type"], "address": v["address"], "scriptPubKey": x(spk),
                           "message": v["message"], "signature": sg, "witness": x(wit), "expect": True})
bip322_errors = []
for f in ("basic-test-vectors.json", "generated-test-vectors.json"):
    for v in json.load(open(os.path.join(UP, f))).get("error", []):
        if not v["address"].startswith(("bc1q", "bc1p")):
            continue
        try:
            spk = btc.script_pubkey(v["address"])
        except ValueError:
            continue
        try:
            wit = btc.witness_from_wallet(v["signature"])
        except Exception:
            bip322_errors.append({"source": f, "description": v["description"], "address": v["address"],
                                  "message": v["message"], "signature": v["signature"], "expect": "reject-decoding"})
            continue
        assert not btc.verify_simple(spk, v["message"].encode(), wit), v["description"]
        bip322_errors.append({"source": f, "description": v["description"], "address": v["address"], "scriptPubKey": x(spk),
                              "message": v["message"], "signature": v["signature"], "witness": x(wit), "expect": "invalid"})
sparrow = {"source": "Sparrow drongo commit f47d5de / Bitcoin Core PR #24058 (P2TR, SIGHASH_ALL)",
           "address": "bc1ppv609nr0vr25u07u95waq5lucwfm6tde4nydujnu8npg4q75mr5sxq8lt3", "message": "Hello World",
           "signature": "AUHd69PrJQEv+oKTfZ8l+WROBHuy9HKrbFCJu7U1iK2iiEy1vMU5EfMtjc+VSHM7aU0SDbak5IUZRVno2P5mjSafAQ=="}
sparrow["scriptPubKey"] = x(btc.script_pubkey(sparrow["address"]))
sparrow["witness"] = x(btc.witness_from_wallet(sparrow["signature"]))
sparrow["expect"] = True
assert btc.verify_simple(btc.script_pubkey(sparrow["address"]), b"Hello World", btc.witness_from_wallet(sparrow["signature"]))
bip322.append(dict(sparrow, type="p2tr"))

for c in sign_cases:
    hd = holders[c["holder"]]
    got = btc.verify_simple(hd["spk"], H.sign_message(hd["holder"], c["chainId"], bytes.fromhex(c["digest"][2:])),
                            bytes.fromhex(c["signature"][2:]))
    assert got == c["expect"], c["name"]

# Raw outputs of real wallets (interop/wallet-matrix/results, 2026-10-11), as the wallet API returned them, and the string
# that is given to the decoding of section 6.1. Taking `result.signature` out of a JSON-RPC response (Xverse,
# Leather) is the wallet's API, not part of the TAP: the TAP decodes the base64 string.
WM = os.path.join(ROOT, "interop", "wallet-matrix", "results")
wallet_raw = []
for wname, wver, api in (("xverse", "2.9.3", "JSON-RPC result.signature"), ("leather", "6.114.0", "JSON-RPC result.signature"),
                         ("okx", "4.18.1", "return value")):
    for kind in ("p2tr", "p2wpkh"):
        d = json.load(open(os.path.join(WM, wname, f"{wname}-{wver}-{kind}.json")))
        pb = json.load(open(os.path.join(WM, wname, f"{wname}-{wver}-batch-{kind}.json")))["probes"]["long4000"]
        spk = btc.script_pubkey(d["accounts"][0])
        for label, r in (("5.1 message", d["signs"]["sign"]), ("4,000-character probe (not a TAP text)", pb)):
            s = r["result"]["ok"]
            if api.startswith("JSON-RPC"):
                assert r["raw"]["result"]["signature"] == s
            else:
                assert r["raw"] == s
            w = btc.witness_from_wallet(s)
            assert w.hex() == r["cliWitness"][2:]
            assert btc.verify_simple(spk, r["message"].encode(), w)
            wallet_raw.append({"wallet": f"{wname} {wver}", "kind": kind, "text": label, "chars": len(r["message"]),
                               "scriptPubKey": x(spk), "message": r["message"], "api": api, "apiResult": r["raw"], "input": s, "expect": x(w), "validSimpleSignature": True})
okx_x = json.load(open(os.path.join(WM, "okx", "okx-4.18.1-extras.json")))["p2wpkh-default-ecdsa"]
w = btc.witness_from_wallet(okx_x["output"])
assert len(w) == 65 and not btc.verify_simple(btc.script_pubkey(okx_x["address"]), okx_x["message"].encode(), w)
wallet_bip137 = {"wallet": "okx 4.18.1", "kind": "p2wpkh", "call": "okxwallet.bitcoin.signMessage(message) without a type (default 'ecdsa')",
                 "bitcoinAddress": okx_x["address"], "scriptPubKey": x(btc.script_pubkey(okx_x["address"])), "message": okx_x["message"], "input": okx_x["output"], "decoded": x(w),
                 "decodedLength": 65, "validSimpleSignature": False,
                 "note": "A BIP-137 compact signature: section 6.1 decodes it to 65 bytes, which is not a simple signature and is "
                         "the length that TAP-11 clients read as ECDSA; a client should refuse it and ask for 'bip322-simple'."}
xv = json.load(open(os.path.join(WM, "xverse", "xverse-2.9.3-extras.json")))["p2sh-bip322"]
w = btc.witness_from_wallet(xv["output"])
try:
    btc.script_pubkey(xv["address"])
    raise SystemExit("P2SH should be unsupported")
except ValueError:
    pass
wallet_p2sh = {"wallet": "xverse 2.9.3", "kind": "p2sh-p2wpkh (unsupported, section 2)", "bitcoinAddress": xv["address"],
               "message": xv["message"], "input": xv["output"], "decoded": x(w), "decodedLength": len(w),
               "note": "A witness-only 'BIP322' signature for a P2SH address, which BIP-322 says needs the full format; the "
                       "address kind is unsupported, so no holder exists for it."}

out = {
    "format": "tap-bitcoin-keyed-holders-vectors/1",
    "about": "Test keys are derived from fixed strings and hold nothing. Hex is 0x-prefixed lowercase.",
    "build": {"solc": "0.8.28", "evmVersion": "shanghai", "optimizer": True, "runs": 200, "viaIR": True,
              "bytecodeHash": "none", "cborMetadata": False, "creationCodeKeccak": x(keccak256(CODE))},
    "factory": x(H.FACTORY), "salt": x(H.SALT),
    "holders": {k: {"bitcoinAddress": v["address"], "scriptPubKey": x(v["spk"]), "initCodeKeccak": x(v["initCodeHash"]),
                    "holder": x(v["holder"])} for k, v in holders.items()},
    "tap11Delegation": TAP11, "signCases": sign_cases, "callCases": call_cases,
    "constructorCases": constructor_cases, "hrpCases": hrp_cases, "walletOutputs": wallet_outputs, "walletRawOutputs": wallet_raw,
    "walletBip137Default": wallet_bip137, "walletP2shOutput": wallet_p2sh, "independentLibrary": lib_cases,
    "upstream": {"bipsCommit": bips_commit, "bip340": bip340, "bip322Simple": bip322, "bip322Errors": bip322_errors},
}
json.dump(out, open(os.path.join(ROOT, "vectors", "vectors.json"), "w"), indent=1)
open(os.path.join(ROOT, "vectors", "creation-code.hex"), "w").write(CODE.hex() + "\n")

# ------------------------------------------------------------------ Solidity test with the same data
L = []
L.append("// SPDX-License-Identifier: MIT\npragma solidity 0.8.28;\n// GENERATED by tools/make_vectors.py from the same data as vectors/vectors.json. Do not edit.\n")
L.append("library GeneratedVectors {")
L.append(f"    bytes32 internal constant CREATION_CODE_KECCAK = {x(keccak256(CODE))};")
for k, v in holders.items():
    nm = k.replace("-", "_").upper()
    L.append(f'    bytes internal constant SPK_{nm} = hex"{v["spk"].hex()}";')
    L.append(f'    address internal constant HOLDER_{nm} = address(bytes20(hex"{v["holder"].hex()}"));')
L.append("    struct SignCase { string name; uint8 holder; uint256 chainId; bytes32 digest; bytes message; bytes sig; bool expect; }")
L.append("    struct CallCase { string name; uint8 holder; address target; uint256 value; bytes data; uint256 gas; uint256 tip; uint256 nonce; uint64 deadline; bytes message; bytes sig; }")
L.append("    struct CtorCase { string name; bytes spk; bool accept; }")
L.append("    struct LibCase { uint8 kind; uint256 chainId; bytes32 digest; bytes spk; bytes message; bytes witness; }")
L.append("    struct Bip340Case { uint256 index; bytes32 px; bytes message; bytes sig; bool expect; }")
L.append("    struct Bip322Case { bytes spk; bytes message; bytes witness; }")
idx = {"p2tr": 0, "p2wpkh": 1, "p2tr-other": 2}


def sol_bytes(b):
    return f'hex"{b.hex()}"'


L.append(f"    function signCases() internal pure returns (SignCase[] memory c) {{\n        c = new SignCase[]({len(sign_cases)});")
for i, c in enumerate(sign_cases):
    L.append(f'        c[{i}] = SignCase("{c["name"]}", {idx[c["holder"]]}, {c["chainId"]}, {c["digest"]}, '
             f'{sol_bytes(c["message"].encode())}, {sol_bytes(bytes.fromhex(c["signature"][2:]))}, {str(c["expect"]).lower()});')
L.append("    }")
L.append(f"    function callCases() internal pure returns (CallCase[] memory c) {{\n        c = new CallCase[]({len(call_cases)});")
for i, c in enumerate(call_cases):
    L.append(f'        c[{i}] = CallCase("{c["name"]}", {idx[c["holder"]]}, address(bytes20(hex"{c["target"][2:]}")), {c["value"]}, {sol_bytes(bytes.fromhex(c["data"][2:]))}, '
             f'{c["gas"]}, {c["tip"]}, {c["nonce"]}, {c["deadline"]}, {sol_bytes(c["message"].encode())}, {sol_bytes(bytes.fromhex(c["signature"][2:]))});')
L.append("    }")
L.append(f"    function bip340Cases() internal pure returns (Bip340Case[] memory c) {{\n        c = new Bip340Case[]({len(bip340)});")
for i, c in enumerate(bip340):
    L.append(f'        c[{i}] = Bip340Case({c["index"]}, {c["publicKey"]}, {sol_bytes(bytes.fromhex(c["message"][2:]))}, '
             f'{sol_bytes(bytes.fromhex(c["signature"][2:]))}, {str(c["expect"]).lower()});')
L.append("    }")
L.append(f"    function bip322Cases() internal pure returns (Bip322Case[] memory c) {{\n        c = new Bip322Case[]({len(bip322)});")
for i, c in enumerate(bip322):
    L.append(f'        c[{i}] = Bip322Case({sol_bytes(bytes.fromhex(c["scriptPubKey"][2:]))}, {sol_bytes(c["message"].encode())}, '
             f'{sol_bytes(bytes.fromhex(c["witness"][2:]))});')
L.append("    }")
L.append(f"    function ctorCases() internal pure returns (CtorCase[] memory c) {{\n        c = new CtorCase[]({len(constructor_cases)});")
for i, c in enumerate(constructor_cases):
    L.append(f'        c[{i}] = CtorCase("{c["name"]}", {sol_bytes(bytes.fromhex(c["scriptPubKey"][2:]))}, {str(c["expect"] == "accept").lower()});')
L.append("    }")
L.append(f"    function libCases() internal pure returns (LibCase[] memory c) {{\n        c = new LibCase[]({len(lib_cases)});")
for i, e in enumerate(lib_cases):
    is_sign = " signs 0x" in e["message"]
    chain = int(e["message"].split(" on chain ")[1].split(" ")[0])
    dig = ("0x" + e["message"].rsplit(" signs 0x", 1)[1]) if is_sign else "0x" + "00" * 32
    kind = 0 if e["scriptPubKey"].startswith("0x5120") else 1
    L.append(f'        c[{i}] = LibCase({kind}, {chain if is_sign else 0}, {dig}, {sol_bytes(bytes.fromhex(e["scriptPubKey"][2:]))}, {sol_bytes(e["message"].encode())}, {sol_bytes(bytes.fromhex(e["witness"][2:]))});')
L.append("    }")
errs = [e for e in bip322_errors if e["expect"] == "invalid"]
L.append(f"    function bip322ErrorCases() internal pure returns (Bip322Case[] memory c) {{\n        c = new Bip322Case[]({len(errs)});")
for i, e in enumerate(errs):
    L.append(f'        c[{i}] = Bip322Case({sol_bytes(bytes.fromhex(e["scriptPubKey"][2:]))}, {sol_bytes(e["message"].encode())}, {sol_bytes(bytes.fromhex(e["witness"][2:]))});')
L.append("    }\n}\n")
open(os.path.join(ROOT, "contracts", "test", "GeneratedVectors.sol"), "w").write("\n".join(L))
print("holders", {k: "0x" + v["holder"].hex() for k, v in holders.items()})
print("independent library signatures:", len(lib_cases))
print("sign cases %d (valid %d), call cases %d, constructor %d, wallet outputs %d, bip340 %d, bip322 %d, bip322 errors %d" % (
    len(sign_cases), sum(c["expect"] for c in sign_cases), len(call_cases), len(constructor_cases), len(wallet_outputs),
    len(bip340), len(bip322), len(bip322_errors)))
