# SPDX-License-Identifier: MIT
"""Gas of the standard cases from transaction receipts on a plain local anvil node (no fork), for one
holder creation code: deploy through the deterministic deployment proxy, isValidSignature sent as a
transaction, execute of an ERC-721 transfer (with and without a tip, at nonce 0 and at nonce 1), k separate
executes and one executeBatch of k transfers (k = 1, 2, 4, 8). Every scenario starts from the same snapshot.

Uses the public TEST keys of tools/cli.py and anvil's default account 0 as relayer; sends transactions only to
the node given by --rpc (scripts/final_gas.sh starts it). Prints one JSON document.
usage: python3 scripts/final_gas.py --rpc URL --code HEXFILE --label NAME"""
import argparse
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
sys.path.insert(0, os.path.join(ROOT, "tools"))
import btc  # noqa: E402
import cli  # noqa: E402
import holder as H  # noqa: E402
from keccak import keccak256  # noqa: E402

RELAYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # anvil default account 0
RECIPIENT = bytes.fromhex("00000000000000000000000000000000000000b0")
CALL_GAS = 100_000
TIP = 10**16
DEADLINE = 4_000_000_000
OUT = os.path.join(ROOT, "contracts", "out")
CAST = os.path.join(os.environ.get("FOUNDRY_BIN", os.path.expanduser("~/.foundry/bin")), "cast")
ENV = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}  # the node is local

p = argparse.ArgumentParser()
p.add_argument("--rpc", required=True)
p.add_argument("--code", required=True)
p.add_argument("--label", required=True)
args = p.parse_args()
RPC = args.rpc
CODE = bytes.fromhex(open(args.code).read().strip().removeprefix("0x"))


def cast(*a):
    r = subprocess.run([CAST, a[0], "--rpc-url", RPC, *a[1:]], capture_output=True, text=True, env=ENV, timeout=120)
    if r.returncode != 0:
        raise RuntimeError("cast %s: %s %s" % (a[0], r.stderr.strip()[-400:], r.stdout.strip()[-400:]))
    return r.stdout.strip()


def rpc(method, *params):
    return json.loads(cast("rpc", method, *[json.dumps(x) if not isinstance(x, str) else x for x in params]))


def send(to, data, expect_ok=True):
    out = cast("send", "--json", "--private-key", RELAYER_KEY, *(["--create", "0x" + data.hex()] if to is None
                                                                  else ["0x" + to.hex(), "0x" + data.hex()]))
    rc = json.loads(out)
    ok = rc["status"] in ("0x1", 1)
    if ok != expect_ok:
        raise RuntimeError("unexpected status %s: %s" % (rc["status"], rc["transactionHash"]))
    return rc


def gas(rc):
    return int(rc["gasUsed"], 16)


def artifact(rel):
    return bytes.fromhex(json.load(open(os.path.join(OUT, rel)))["bytecode"]["object"][2:])


def has_batch():
    return keccak256(b"executeBatch((address,uint256,bytes,uint256)[],uint256,uint64,bytes)")[:4] in CODE


def ecrecover_calls(sk, spk, msg):
    """P2WPKH: the holder tries v = 27 first, then 28; 1 or 2 ecrecover calls for this signature."""
    h = btc.segwit_v0_sighash(btc.to_spend_txid(msg, spk), spk[2:])
    k = btc._rfc6979_k(sk, h)
    R = btc.mul(k)
    s = pow(k, btc.N - 2, btc.N) * (int.from_bytes(h, "big") + (R[0] % btc.N) * sk) % btc.N
    parity = (R[1] & 1) ^ (1 if s > btc.N // 2 else 0)
    return 1 if parity == 0 else 2


chain = int(cast("chain-id"))
rpc("anvil_setCode", "0x" + H.FACTORY.hex(), "0x" + H.FACTORY_RUNTIME.hex())
token = bytes.fromhex(send(None, artifact("BenchERC721.sol/BenchERC721.json"))["contractAddress"][2:])
MINT = keccak256(b"mint(address,uint256)")[:4]
send(token, MINT + cli.w32(RECIPIENT) + cli.u256(10**6))  # every measured transfer writes a nonzero balance

res = {"label": args.label, "chainId": chain, "creationCodeBytes": len(CODE), "creationCodeKeccak": "0x" + keccak256(CODE).hex(),
       "callGas": CALL_GAS, "tip": TIP, "kinds": {}}
holders = {}
BASE = {"p2tr": 0, "p2wpkh": 100}  # token ids BASE + 1 .. BASE + 8 belong to the holder of each kind
for kind in ("p2tr", "p2wpkh"):
    sk, spk = cli.test_key(kind)
    addr = H.holder_address(spk, CODE)
    rc = send(H.FACTORY, H.SALT + H.init_code(spk, CODE))
    runtime = bytes.fromhex(cast("code", "0x" + addr.hex())[2:])
    assert runtime, "not deployed"
    for i in range(1, 9):
        send(token, MINT + cli.w32(addr) + cli.u256(BASE[kind] + i))
    rpc("anvil_setBalance", "0x" + addr.hex(), hex(10**18))
    holders[kind] = (sk, spk, addr)
    res["kinds"][kind] = {"holder": "0x" + addr.hex(), "deploy": gas(rc), "runtimeBytes": len(runtime)}

snap = [rpc("evm_snapshot")]


def fresh():
    rpc("evm_revert", snap[0])
    snap[0] = rpc("evm_snapshot")


def xfer(addr, tid):
    return keccak256(b"safeTransferFrom(address,address,uint256)")[:4] + cli.w32(addr) + cli.w32(RECIPIENT) + cli.u256(tid)


def nonce_of(addr):
    return int(cast("call", "0x" + addr.hex(), "nonce()(uint256)").split()[0])


def owner(tid):
    return cast("call", "0x" + token.hex(), "ownerOf(uint256)(address)", str(tid)).lower()


def execute(kind, tid, tip):
    sk, spk, addr = holders[kind]
    tid += BASE[kind]
    data = xfer(addr, tid)
    msg = H.call_message(addr, chain, token, 0, data, CALL_GAS, tip, nonce_of(addr), DEADLINE)
    sig = btc.sign_simple(sk, spk, msg)
    rc = send(addr, cli.execute_calldata(token, 0, data, CALL_GAS, tip, DEADLINE, sig))
    assert owner(tid) == "0x" + RECIPIENT.hex()
    return {"gas": gas(rc), "ecrecover": ecrecover_calls(sk, spk, msg) if kind == "p2wpkh" else None}


def batch(kind, k, tip, first=1):
    sk, spk, addr = holders[kind]
    calls = [(token, 0, xfer(addr, BASE[kind] + t), CALL_GAS) for t in range(first, first + k)]
    n = nonce_of(addr)
    msg = H.batch_message(addr, chain, calls, tip, n, DEADLINE)
    onchain = cast("call", "0x" + addr.hex(),
                   "batchMessage((address,uint256,bytes,uint256)[],uint256,uint256,uint64)(bytes)",
                   "[" + ",".join("(0x%s,%d,0x%s,%d)" % (t.hex(), v, d.hex(), g) for t, v, d, g in calls) + "]",
                   str(tip), str(n), str(DEADLINE))
    assert bytes.fromhex(onchain[2:]) == msg, "contract and Python texts differ"
    sig = btc.sign_simple(sk, spk, msg)
    cd = cli.execute_batch_calldata(calls, tip, DEADLINE, sig)
    rc = send(addr, cd)
    for t in range(first, first + k):
        assert owner(BASE[kind] + t) == "0x" + RECIPIENT.hex()
    return {"gas": gas(rc), "chars": len(msg), "calldataBytes": len(cd),
            "ecrecover": ecrecover_calls(sk, spk, msg) if kind == "p2wpkh" else None}


for kind in ("p2tr", "p2wpkh"):
    sk, spk, addr = holders[kind]
    r = res["kinds"][kind]
    # isValidSignature as a transaction, for eight digests (P2WPKH: 1 or 2 ecrecover calls, see ecrecover)
    r["isValidSignature"] = []
    for i in range(8):
        fresh()
        digest = hashlib.sha256(b"final-gas digest %d" % i).digest()
        msg = H.sign_message(addr, chain, digest)
        sig = btc.sign_simple(sk, spk, msg)
        assert cast("call", "0x" + addr.hex(), "isValidSignature(bytes32,bytes)(bytes4)", "0x" + digest.hex(),
                    "0x" + sig.hex()) == "0x1626ba7e"
        rc = send(addr, keccak256(b"isValidSignature(bytes32,bytes)")[:4] + digest + cli.u256(64) + cli.abi_bytes(sig))
        r["isValidSignature"].append({"gas": gas(rc), "ecrecover": ecrecover_calls(sk, spk, msg) if kind == "p2wpkh" else None})
    fresh()
    r["execute"] = execute(kind, 1, 0)
    r["executeNext"] = execute(kind, 2, 0)  # the same holder at nonce 1: the nonce slot is already nonzero
    fresh()
    r["executeTip"] = execute(kind, 1, TIP)
    r["separate"] = {}
    for k in (1, 2, 4, 8):
        fresh()
        xs = [execute(kind, t, 0) for t in range(1, k + 1)]
        r["separate"][k] = {"gas": sum(x["gas"] for x in xs), "txs": k}
    if has_batch():
        r["batch"] = {}
        for k in (1, 2, 4, 8):
            fresh()
            r["batch"][k] = batch(kind, k, 0)
        fresh()
        r["batch8Tip"] = batch(kind, 8, TIP)
        fresh()
        execute(kind, 1, 0)
        r["batch4Next"] = batch(kind, 4, 0, first=2)  # the same holder at nonce 1
print(json.dumps(res, indent=1))
