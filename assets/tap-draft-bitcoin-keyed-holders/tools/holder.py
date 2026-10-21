# SPDX-License-Identifier: MIT
"""Messages and addresses of the Bitcoin-keyed holders TAP (§3 to §5), dependency-free Python 3."""
import json
import os
import re

import btc
from keccak import keccak256

FACTORY = bytes.fromhex("4e59b44847b379578588920ca78fbf26c0b4956c")  # deterministic deployment proxy
FACTORY_RUNTIME = bytes.fromhex(
    "7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3")
SALT = bytes(32)
HERE = os.path.dirname(os.path.abspath(__file__))
ARTIFACT = os.path.join(HERE, "..", "contracts", "out", "BitcoinKeyedHolder.sol", "BitcoinKeyedHolder.json")
MAX_CALLS = 8
MAX_CALL_GAS = 1 << 64


def creation_code():
    return bytes.fromhex(json.load(open(ARTIFACT))["bytecode"]["object"][2:])


def init_code(spk, code=None):
    """Creation code followed by the ABI encoding of the constructor argument `bytes scriptPubKey`."""
    code = creation_code() if code is None else code
    padded = spk + bytes(-len(spk) % 32)
    return code + (32).to_bytes(32, "big") + len(spk).to_bytes(32, "big") + padded


def holder_address(spk, code=None):
    h = keccak256(b"\xff" + FACTORY + SALT + keccak256(init_code(spk, code)))
    return h[12:]


def _dec(v):
    return str(v).encode()


def prefix(holder, chain_id):
    return b"TapeOut Bitcoin-keyed holder 0x" + holder.hex().encode() + b" on chain " + _dec(chain_id)


def sign_message(holder, chain_id, digest):
    return prefix(holder, chain_id) + b" signs 0x" + digest.hex().encode()


def call_message(holder, chain_id, target, value, data, gas, tip, nonce, deadline):
    return (prefix(holder, chain_id) + b" calls 0x" + target.hex().encode() + b" with value " + _dec(value)
            + b" and data 0x" + keccak256(data).hex().encode() + b", gas " + _dec(gas) + b", tip " + _dec(tip) + b", nonce " + _dec(nonce)
            + b", valid until " + _dec(deadline))


def batch_message(holder, chain_id, calls, tip, nonce, deadline):
    """Batch message (TAP §5.3). `calls` is a list of (target bytes20, value, data bytes, callGas)."""
    if not 1 <= len(calls) <= MAX_CALLS:
        raise ValueError("a batch has 1 to %d calls" % MAX_CALLS)
    m = prefix(holder, chain_id) + b" makes " + _dec(len(calls)) + b" calls:"
    for i, (target, value, data, gas) in enumerate(calls):
        if len(target) != 20:
            raise ValueError("target must be 20 bytes")
        m += (b" (" + _dec(i + 1) + b") 0x" + target.hex().encode() + b" with value " + _dec(value)
              + b" and data 0x" + keccak256(data).hex().encode() + b", gas " + _dec(gas) + b";")
    return m + b" tip " + _dec(tip) + b", nonce " + _dec(nonce) + b", valid until " + _dec(deadline)


_BATCH_RE = re.compile(
    rb"TapeOut Bitcoin-keyed holder 0x([0-9a-f]{40}) on chain (0|[1-9][0-9]*) makes ([1-9][0-9]*) calls:"
    rb"((?: \((?:[1-9][0-9]*)\) 0x[0-9a-f]{40} with value (?:0|[1-9][0-9]*) and data 0x[0-9a-f]{64}, gas (?:0|[1-9][0-9]*);)+)"
    rb" tip (0|[1-9][0-9]*), nonce (0|[1-9][0-9]*), valid until (0|[1-9][0-9]*)")
_CALL_RE = re.compile(rb" \(([1-9][0-9]*)\) 0x([0-9a-f]{40}) with value (0|[1-9][0-9]*) and data 0x([0-9a-f]{64}), gas (0|[1-9][0-9]*);")


def parse_batch_message(m):
    """Inverse of batch_message, with data hashes in place of data. Raises ValueError unless `m` is exactly
    a batch message; used by the injectivity check and by interfaces that display a text they received."""
    g = _BATCH_RE.fullmatch(m)
    if not g:
        raise ValueError("not a batch message")
    calls = []
    for j, c in enumerate(_CALL_RE.finditer(g.group(4))):
        if int(c.group(1)) != j + 1:
            raise ValueError("calls out of order")
        calls.append((bytes.fromhex(c.group(2).decode()), int(c.group(3)), bytes.fromhex(c.group(4).decode()), int(c.group(5))))
    if len(calls) != int(g.group(3)) or not 1 <= len(calls) <= MAX_CALLS:
        raise ValueError("wrong number of calls")
    return (bytes.fromhex(g.group(1).decode()), int(g.group(2)), calls, int(g.group(5)), int(g.group(6)), int(g.group(7)))


def request(address, chain_id, digest_hex):
    """What a wallet user is asked to sign: (holder address, exact message text)."""
    spk = btc.script_pubkey(address)
    holder = holder_address(spk)
    return holder, sign_message(holder, chain_id, bytes.fromhex(digest_hex.removeprefix("0x"))).decode()


if __name__ == "__main__":
    import sys
    if len(sys.argv) not in (4, 5):
        sys.exit("usage: python3 holder.py <bc1p… or bc1q… address> <chain id> <32-byte digest hex> [wallet signature]")
    h, msg = request(sys.argv[1], int(sys.argv[2]), sys.argv[3])
    print("holder: 0x" + h.hex())
    print("message to sign (BIP-322, exactly this text):")
    print(msg)
    if len(sys.argv) == 5:
        wit = btc.witness_from_wallet(sys.argv[4])
        ok = btc.verify_simple(btc.script_pubkey(sys.argv[1]), msg.encode(), wit)
        print("signature (witness hex): 0x" + wit.hex())
        print("valid:", ok)
