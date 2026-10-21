# SPDX-License-Identifier: MIT
"""Command-line helper for Bitcoin-keyed holders. Dependency-free Python 3; never touches a network.

  python3 tools/cli.py address <bc1p…|bc1q…>
      scriptPubKey, holder address and the calldata that deploys it through the deterministic proxy
  python3 tools/cli.py sign-message <bitcoin address> <chain id> <digest>
  python3 tools/cli.py call-message <bitcoin address> <chain id> <target> <value> <data hex> <gas> <tip> <nonce> <deadline>
      the exact text the Bitcoin wallet signs (TAP §5.1 / §5.2)
  python3 tools/cli.py tap11-digest <chain id> <container> <signer> <expires>
      the TAP-11 §4.1 Delegation digest
  python3 tools/cli.py witness <wallet signature>
      the bytes to pass as `sig`: strips an 'smp' marker and decodes base64
  python3 tools/cli.py verify <bitcoin address> <message text> <wallet signature or 0x witness>
  python3 tools/cli.py execute-calldata <target> <value> <data hex> <gas> <tip> <deadline> <wallet signature or 0x witness>
      calldata for execute(), to be sent to the holder by any relayer
  python3 tools/cli.py batch-message <bitcoin address> <chain id> <tip> <nonce> <deadline> <call>...
      the text the wallet signs for executeBatch (TAP §5.3); each <call> is target,value,datahex,gas
  python3 tools/cli.py execute-batch-calldata <tip> <deadline> <wallet signature or 0x witness> <call>...
      calldata for executeBatch((address,uint256,bytes,uint256)[],uint256,uint64,bytes)
  python3 tools/cli.py test-sign <p2tr|p2wpkh> <message text>
      signs with the public TEST keys of the vectors (they hold nothing); for demos only
"""
import sys

import btc
import holder as H
from keccak import keccak256

HUB = bytes.fromhex("e61a9c7213a6aa616c246a2b569e555b417b25ee")  # TAP-11 §4.1 verifyingContract


def h2b(s):
    s = s.strip()
    return bytes.fromhex(s[2:] if s.startswith("0x") else s)


def w32(b):
    return bytes(32 - len(b)) + b


def u256(v):
    return int(v).to_bytes(32, "big")


def sig_bytes(s):
    return h2b(s) if s.startswith("0x") else btc.witness_from_wallet(s)


def abi_bytes(b):
    return u256(len(b)) + b + bytes(-len(b) % 32)


def tap11_digest(chain_id, container, signer, expires):
    domain = keccak256(keccak256(b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
                       + keccak256(b"TapeAPI") + keccak256(b"1") + u256(chain_id) + w32(HUB))
    typehash = keccak256(b"Delegation(address container,address signer,uint64 expires)")
    return keccak256(b"\x19\x01" + domain + keccak256(typehash + w32(container) + w32(signer) + u256(expires)))


def execute_calldata(target, value, data, gas, tip, deadline, sig):
    """execute(address,uint256,bytes,uint256,uint256,uint64,bytes)"""
    head_len = 7 * 32
    off_data = head_len
    off_sig = off_data + len(abi_bytes(data))
    sel = keccak256(b"execute(address,uint256,bytes,uint256,uint256,uint64,bytes)")[:4]
    return (sel + w32(target) + u256(value) + u256(off_data) + u256(gas) + u256(tip) + u256(deadline)
            + u256(off_sig) + abi_bytes(data) + abi_bytes(sig))


def parse_call(s):
    t, v, d, g = s.split(",")
    target = h2b(t)
    if len(target) != 20:
        raise ValueError("target must be 20 bytes")
    return target, int(v), h2b(d), int(g)


def execute_batch_calldata(calls, tip, deadline, sig):
    """executeBatch((address,uint256,bytes,uint256)[],uint256,uint64,bytes)"""
    if not 1 <= len(calls) <= H.MAX_CALLS:
        raise ValueError("a batch has 1 to %d calls" % H.MAX_CALLS)
    sel = keccak256(b"executeBatch((address,uint256,bytes,uint256)[],uint256,uint64,bytes)")[:4]
    tuples = [w32(t) + u256(v) + u256(4 * 32) + u256(g) + abi_bytes(d) for t, v, d, g in calls]
    offs, pos = b"", 32 * len(tuples)
    for t in tuples:
        offs += u256(pos)
        pos += len(t)
    arr = u256(len(tuples)) + offs + b"".join(tuples)
    head_len = 4 * 32
    return sel + u256(head_len) + u256(tip) + u256(deadline) + u256(head_len + len(arr)) + arr + abi_bytes(sig)


def test_key(kind):
    label = {"p2tr": "1", "p2wpkh": "2"}[kind]
    sk = int.from_bytes(btc.sha256(("tap-bitcoin-keyed-holders vector key " + label).encode()), "big") % btc.N
    spk = (b"\x51\x20" + btc.taproot_tweak(sk)[1] if kind == "p2tr"
           else b"\x00\x14" + btc.hash160(btc.compressed(btc.mul(sk))))
    return sk, spk


def main(a):
    cmd = a[0] if a else ""
    if cmd == "address" and len(a) == 2:
        spk = btc.script_pubkey(a[1])
        h = H.holder_address(spk)
        print("scriptPubKey: 0x" + spk.hex())
        print("holder:       0x" + h.hex())
        print("init code keccak: 0x" + keccak256(H.init_code(spk)).hex())
        print("deploy: send to 0x" + H.FACTORY.hex() + " the calldata")
        print("0x" + (H.SALT + H.init_code(spk)).hex())
    elif cmd == "sign-message" and len(a) == 4:
        h = H.holder_address(btc.script_pubkey(a[1]))
        print(H.sign_message(h, int(a[2]), h2b(a[3])).decode())
    elif cmd == "call-message" and len(a) == 10:
        h = H.holder_address(btc.script_pubkey(a[1]))
        print(H.call_message(h, int(a[2]), h2b(a[3]), int(a[4]), h2b(a[5]), int(a[6]), int(a[7]), int(a[8]), int(a[9])).decode())
    elif cmd == "tap11-digest" and len(a) == 5:
        print("0x" + tap11_digest(int(a[1]), h2b(a[2]), h2b(a[3]), int(a[4])).hex())
    elif cmd == "witness" and len(a) == 2:
        print("0x" + btc.witness_from_wallet(a[1]).hex())
    elif cmd == "verify" and len(a) == 4:
        ok = btc.verify_simple(btc.script_pubkey(a[1]), a[2].encode(), sig_bytes(a[3]))
        print("valid" if ok else "INVALID")
        return 0 if ok else 1
    elif cmd == "execute-calldata" and len(a) == 8:
        print("0x" + execute_calldata(h2b(a[1]), int(a[2]), h2b(a[3]), int(a[4]), int(a[5]), int(a[6]), sig_bytes(a[7])).hex())
    elif cmd == "batch-message" and len(a) >= 7:
        h = H.holder_address(btc.script_pubkey(a[1]))
        print(H.batch_message(h, int(a[2]), [parse_call(c) for c in a[6:]], int(a[3]), int(a[4]), int(a[5])).decode())
    elif cmd == "execute-batch-calldata" and len(a) >= 5:
        calls = [parse_call(c) for c in a[4:]]
        print("0x" + execute_batch_calldata(calls, int(a[1]), int(a[2]), sig_bytes(a[3])).hex())
    elif cmd == "test-sign" and len(a) == 3:
        sk, spk = test_key(a[1])
        print("0x" + btc.sign_simple(sk, spk, a[2].encode()).hex())
    elif cmd == "test-address" and len(a) == 2:
        _, spk = test_key(a[1])
        print(btc.segwit_address(1 if spk[0] == 0x51 else 0, spk[2:]))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except ValueError as e:
        sys.exit("error: %s" % e)
