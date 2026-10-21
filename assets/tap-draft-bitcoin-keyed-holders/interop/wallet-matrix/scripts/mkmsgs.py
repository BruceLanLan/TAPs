# Builds every text a wallet is asked to sign in this lab, for one Bitcoin address, with the TAP repository's own
# reference code (tools/holder.py, tools/btc.py). Usage: python3 mkmsgs.py <bitcoin address> <TAP repository> <deadline>
# Prints JSON. Big numbers are strings so that JavaScript does not round them.
#   single.sign   §5.1, digest 0xab..ab, chain 56 (as in the UniSat run)
#   single.exec   §5.2, transferFrom(holder, 0x..0c0b7a, 920) on the real BSC ERC-721 0x1f5c..f12c, nonce 0
#   single.call   §5.2, an empty call to 0x..aa, gas 0, nonce 1
#   batch.*       §5.3, the three batches of the UniSat run: transfers-8 (1,329 chars), mixed-3, longest (2,239 chars)
#   probe.long4000  a 4,000-character printable-ASCII text (not a TAP message), to probe length limits only
import json
import sys

sys.path.insert(0, sys.argv[2] + "/tools")
import btc  # noqa: E402
import holder as H  # noqa: E402
from keccak import keccak256  # noqa: E402

addr, deadline = sys.argv[1], int(sys.argv[3])
spk = btc.script_pubkey(addr)
h = H.holder_address(spk)
w32 = lambda b: bytes(32 - len(b)) + b  # noqa: E731
NFT = bytes.fromhex("1f5cb4aeae1807bf60c3b9c0d8adbcc14e91f12c")
RECIP = bytes.fromhex("00000000000000000000000000000000000c0b7a")
TOKEN = bytes.fromhex("00000000000000000000000000000000000000c1")
R = bytes.fromhex("00000000000000000000000000000000000000b0")
xdata = keccak256(b"transferFrom(address,address,uint256)")[:4] + w32(h) + w32(RECIP) + (920).to_bytes(32, "big")
x = lambda b: "0x" + b.hex()  # noqa: E731
out = {"address": addr, "scriptPubKey": x(spk), "holder": x(h),
       "exec": {"holder": x(h), "nft": x(NFT), "recipient": x(RECIP), "tokenId": 920, "data": x(xdata),
                "callGas": 150000, "tip": 0, "deadline": deadline},
       "single": {}, "batch": {}, "probe": {}}
out["single"]["sign"] = H.sign_message(h, 56, b"\xab" * 32).decode()
out["single"]["exec"] = H.call_message(h, 56, NFT, 0, xdata, 150000, 0, 0, deadline).decode()
out["single"]["call"] = H.call_message(h, 56, bytes.fromhex("00" * 19 + "aa"), 0, b"", 0, 0, 1, deadline).decode()


def xfer(i):
    return keccak256(b"safeTransferFrom(address,address,uint256)")[:4] + w32(h) + w32(R) + i.to_bytes(32, "big")


def add(name, chain, calls, tip, nonce, dl):
    m = H.batch_message(h, chain, calls, tip, nonce, dl).decode()
    out["batch"][name] = {"chainId": str(chain), "tip": str(tip), "nonce": str(nonce), "deadline": str(dl), "message": m,
                          "chars": len(m), "calls": [{"target": x(t), "value": str(v), "data": x(d), "callGas": str(g)}
                                                     for t, v, d, g in calls]}


add("transfers-8", 56, [(TOKEN, 0, xfer(i + 1), 100000) for i in range(8)], 0, 0, 2000000000)
add("mixed-3", 56, [(TOKEN, 0, xfer(1), 100000), (R, 10**15, b"", 0), (TOKEN, 0, xfer(2), 100000)], 10**16, 0, 2000000000)
M = 2**256 - 1
add("longest", 2**64 - 1, [(bytes.fromhex("ff" * 20), M, b"x" * 100, 2**64 - 1)] * 8, M, M, 2**64 - 1)
unit = "TapeOut wallet length probe, printable ASCII only, no line breaks; "
t = "".join("%04d %s" % (i, unit) for i in range(100))[:4000]
assert len(t) == 4000 and all(0x20 <= ord(c) <= 0x7e for c in t)
out["probe"]["long4000"] = t
print(json.dumps(out))
