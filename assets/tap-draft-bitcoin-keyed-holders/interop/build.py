#!/usr/bin/env python3
# r8-interop: test keys, holder addresses, TAP-11 digest, manifests and BIP-322 signatures.
# Uses the repo's dependency-free tools (btc.py, holder.py, keccak.py) read-only. TEST KEYS ONLY: derived from fixed
# strings exactly as tools/make_vectors.py does; they hold nothing.
import hashlib
import json
import os
import sys
import time

TOOLS = os.environ.get("TAP_TOOLS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
VECTORS = os.environ.get("TAP_VECTORS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "vectors"))
sys.path.insert(0, TOOLS)
import btc  # noqa: E402
import holder as H  # noqa: E402
from keccak import keccak256  # noqa: E402

x = lambda b: "0x" + b.hex()
w32 = lambda b: bytes(32 - len(b)) + b
HUB = bytes.fromhex("e61a9c7213a6aa616c246a2b569e555b417b25ee")
CHAIN = 56


def key(label):  # same derivation as tools/make_vectors.py
    return int.from_bytes(btc.sha256(("tap-bitcoin-keyed-holders vector key " + label).encode()), "big") % btc.N


def creation_code():
    return bytes.fromhex(open(os.path.join(VECTORS, "creation-code.hex")).read().strip())


def holders():
    K1, K2, K3 = key("1"), key("2"), key("3")
    code = creation_code()
    out = {}
    for name, sk, spk in (("p2tr", K1, b"\x51\x20" + btc.taproot_tweak(K1)[1]),
                          ("p2wpkh", K2, b"\x00\x14" + btc.hash160(btc.compressed(btc.mul(K2)))),
                          ("p2tr-other", K3, b"\x51\x20" + btc.taproot_tweak(K3)[1])):
        ver = 1 if spk[0] == 0x51 else 0
        out[name] = {"secret": sk, "spk": spk, "address": btc.segwit_address(ver, spk[2:]),
                     "holder": H.holder_address(spk, code), "init": H.init_code(spk, code)}
    return out


def evm_key(label):
    sk = int.from_bytes(hashlib.sha256(("r8-interop evm test key " + label).encode()).digest(), "big") % btc.N
    px, py = btc.mul(sk)
    addr = keccak256(px.to_bytes(32, "big") + py.to_bytes(32, "big"))[12:]
    return sk, addr


def tap11_digest(container, signer, expires):
    domain = keccak256(keccak256(b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
                       + keccak256(b"TapeAPI") + keccak256(b"1") + CHAIN.to_bytes(32, "big") + w32(HUB))
    typehash = keccak256(b"Delegation(address container,address signer,uint64 expires)")
    return keccak256(b"\x19\x01" + domain + keccak256(typehash + w32(container) + w32(signer) + expires.to_bytes(32, "big")))


def cmd_setup(live_manifest_path, out_dir):
    hs = holders()
    live = json.load(open(live_manifest_path))
    container = bytes.fromhex(live["container"][2:])
    signer_sk, signer = evm_key("signer")
    expires = int(time.time()) + 300 * 86400
    digest = tap11_digest(container, signer, expires)
    t, o, w = hs["p2tr"], hs["p2tr-other"], hs["p2wpkh"]
    msg = H.sign_message(t["holder"], CHAIN, digest)
    good = btc.sign_simple(t["secret"], t["spk"], msg)          # the P2TR key that owns the holder
    wrong = btc.sign_simple(o["secret"], o["spk"], msg)         # another P2TR key signs the very same message
    assert btc.verify_simple(t["spk"], msg, good) and not btc.verify_simple(t["spk"], msg, wrong)
    msg_w = H.sign_message(w["holder"], CHAIN, digest)
    good_w = btc.sign_simple(w["secret"], w["spk"], msg_w)
    assert btc.verify_simple(w["spk"], msg_w, good_w)

    def manifest(sig):
        m = dict(live)
        m["signer"] = x(signer)
        m["delegation"] = {"expires": expires, "sig": x(sig)}
        return json.dumps(m, separators=(",", ":")).encode()

    os.makedirs(out_dir, exist_ok=True)
    files = {}
    for name, sig in (("manifest-good.json", good), ("manifest-wrongkey.json", wrong)):
        b = manifest(sig)
        open(os.path.join(out_dir, name), "wb").write(b)
        files[name] = {"bytes": len(b), "sha256": x(hashlib.sha256(b).digest()), "hex": x(b)}
    setup = {
        "chainId": CHAIN, "hub": x(HUB), "container": x(container),
        "circuits": live["circuits"], "tokenId": live["tokenId"],
        "signer": x(signer), "signerSecret": hex(signer_sk), "expires": expires, "digest": x(digest),
        "holders": {k: {"bitcoinAddress": v["address"], "scriptPubKey": x(v["spk"]), "holder": x(v["holder"]),
                        "initCode": x(v["init"]), "initCodeKeccak": x(keccak256(v["init"]))} for k, v in hs.items()},
        "messageP2TR": msg.decode(), "sigGood": x(good), "sigWrongKey": x(wrong),
        "messageP2WPKH": msg_w.decode(), "sigP2WPKH": x(good_w),
        "creationCodeKeccak": x(keccak256(creation_code())),
        "files": files,
    }
    json.dump(setup, open(os.path.join(out_dir, "setup.json"), "w"), indent=1)
    print(json.dumps({k: v for k, v in setup.items() if k not in ("holders", "files", "signerSecret")}, indent=1))
    for k, v in setup["holders"].items():
        print(k, v["bitcoinAddress"], "holder", v["holder"], "initCodeKeccak", v["initCodeKeccak"])


def cmd_sign_call(which, target, value, data_hex, gas, tip, nonce, deadline):
    """BIP-322 signature by holder `which` over the §5.2 call message for execute()."""
    hd = holders()[which]
    data = bytes.fromhex(data_hex[2:] if data_hex.startswith("0x") else data_hex)
    msg = H.call_message(hd["holder"], CHAIN, bytes.fromhex(target[2:]), int(value), data, int(gas), int(tip), int(nonce), int(deadline))
    sig = btc.sign_simple(hd["secret"], hd["spk"], msg)
    assert btc.verify_simple(hd["spk"], msg, sig)
    print(json.dumps({"message": msg.decode(), "sig": x(sig)}))


if __name__ == "__main__":
    if sys.argv[1] == "setup":
        cmd_setup(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "sign-call":
        cmd_sign_call(*sys.argv[2:10])
    else:
        sys.exit("usage: build.py setup <live-manifest.json> <out-dir> | sign-call <holder> <target> <value> <data> <gas> <tip> <nonce> <deadline>")
