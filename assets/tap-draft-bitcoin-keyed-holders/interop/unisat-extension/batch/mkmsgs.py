import json, sys
sys.path.insert(0, sys.argv[2] + "/tools")
import btc, holder as H
from keccak import keccak256
addr = sys.argv[1]
spk = btc.script_pubkey(addr)
h = H.holder_address(spk)  # the holder of the current build (contracts/out)
TOKEN = bytes.fromhex("00000000000000000000000000000000000000c1")
R = bytes.fromhex("00000000000000000000000000000000000000b0")
w32 = lambda b: bytes(32 - len(b)) + b
def xfer(i):
    return keccak256(b"safeTransferFrom(address,address,uint256)")[:4] + w32(h) + w32(R) + i.to_bytes(32, "big")
out = {"address": addr, "scriptPubKey": "0x" + spk.hex(), "holder": "0x" + h.hex(), "cases": {}}
def add(name, chain, calls, tip, nonce, dl):
    m = H.batch_message(h, chain, calls, tip, nonce, dl).decode()
    out["cases"][name] = {"chainId": chain, "tip": tip, "nonce": nonce, "deadline": dl, "message": m, "chars": len(m),
                          "calls": [{"target": "0x" + t.hex(), "value": v, "data": "0x" + d.hex(), "callGas": g} for t, v, d, g in calls]}
add("transfers-8", 56, [(TOKEN, 0, xfer(i + 1), 100000) for i in range(8)], 0, 0, 2000000000)
add("mixed-3", 56, [(TOKEN, 0, xfer(1), 100000), (R, 10**15, b"", 0), (TOKEN, 0, xfer(2), 100000)], 10**16, 0, 2000000000)
M = 2**256 - 1
add("longest", 2**64 - 1, [(bytes.fromhex("ff" * 20), M, b"x" * 100, 2**64 - 1)] * 8, M, M, 2**64 - 1)
print(json.dumps(out))
