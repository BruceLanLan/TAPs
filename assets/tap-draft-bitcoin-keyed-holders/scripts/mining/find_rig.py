#!/usr/bin/env python3
"""Find a circuit that is actively mining on the sealed PoD mining contract and is owned by an EOA.
usage: find_rig.py <rpc> <processor> <start id> <end id> [min pending]
Read-only eth_calls. Prints: id owner pending verifWeight status"""
import json, os, sys, urllib.request

MINING = "0x7E2E0DC66a3bD9103E69b766afA62d9f7b697b46"
rpc, proc, a, b = sys.argv[1], sys.argv[2].lower(), int(sys.argv[3]), int(sys.argv[4])
minpend = int(sys.argv[5]) if len(sys.argv) > 5 else 1


def post(batch):
    req = urllib.request.Request(rpc, json.dumps(batch).encode(), {"content-type": "application/json", "user-agent": "curl/8"})
    with urllib.request.urlopen(req, timeout=60) as r:
        out = json.load(r)
    return {x["id"]: x.get("result") for x in out}


def call(i, to, data):
    return {"jsonrpc": "2.0", "id": i, "method": "eth_call", "params": [{"to": to, "data": data}, "latest"]}


def u(v):
    return "%064x" % v


ids = list(range(a, b + 1))
# minerKey(address,uint256) selector and getMiner/pending need the key; compute key locally via keccak of packed
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
from keccak import keccak256  # dependency-free keccak from the holder repo (read-only import)

sel = lambda s: keccak256(s.encode())[:4].hex()
batch = []
keys = {}
for n, cid in enumerate(ids):
    key = keccak256(bytes.fromhex(proc[2:]) + cid.to_bytes(32, "big")).hex()
    keys[cid] = key
    batch.append(call(4 * n, proc, "0x" + sel("ownerOf(uint256)") + u(cid)))
    batch.append(call(4 * n + 1, MINING, "0x" + sel("getMiner(bytes32)") + key))
    batch.append(call(4 * n + 2, MINING, "0x" + sel("pending(bytes32)") + key))
res = {}
for i in range(0, len(batch), 60):
    res.update(post(batch[i:i + 60]))
owners = {}
for n, cid in enumerate(ids):
    o, m, p = res.get(4 * n), res.get(4 * n + 1), res.get(4 * n + 2)
    if not o or not m or len(m) < 2 + 64 * 22:
        continue
    words = [m[2 + 64 * k: 2 + 64 * (k + 1)] for k in range(22)]
    status = int(words[9], 16)
    vw = int(words[19], 16)
    pend = int(p, 16) if p else 0
    owner = "0x" + o[-40:]
    owners[cid] = (owner, pend, vw, status)
# code check for owners
cb = [{"jsonrpc": "2.0", "id": n, "method": "eth_getCode", "params": [owners[c][0], "latest"]} for n, c in enumerate(owners)]
codes = {}
for i in range(0, len(cb), 60):
    codes.update(post(cb[i:i + 60]))
for n, c in enumerate(owners):
    owner, pend, vw, status = owners[c]
    eoa = codes.get(n) in ("0x", None)
    if status == 1 and pend >= minpend:
        print(c, owner, "EOA" if eoa else "contract", "pending", pend, "verifWeight", vw, "status", status, "key 0x" + keys[c])
