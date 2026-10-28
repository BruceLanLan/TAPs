# secp256k1.py: minimal secp256k1 ECDSA for the vectors of TAP-draft-agent-passport. MIT License.
# Python 3.9+, standard library only (plus the vendored keccak.py in this folder).
#
# recover() is used by the verifier (passport.py) to check listing signatures (Specification §5.5).
# sign() is used only by make_vectors.py, with published test keys. It is deterministic (RFC 6979,
# HMAC-SHA256) and normalises s to the lower half, so its output equals that of common Ethereum
# libraries; test_passport.py checks it against the published vectors of TAP-11 (delegation.json).
# This code is not constant-time and must never be used with a key that protects anything.
from __future__ import annotations

import hashlib
import hmac
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keccak import keccak256  # noqa: E402

P = 2 ** 256 - 2 ** 32 - 977
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
     0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)


def _add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0] and (a[1] + b[1]) % P == 0:
        return None
    if a == b:
        lam = 3 * a[0] * a[0] * pow(2 * a[1], -1, P) % P
    else:
        lam = (b[1] - a[1]) * pow(b[0] - a[0], -1, P) % P
    x = (lam * lam - a[0] - b[0]) % P
    return (x, (lam * (a[0] - x) - a[1]) % P)


def _mul(k: int, pt):
    r = None
    while k:
        if k & 1:
            r = _add(r, pt)
        pt = _add(pt, pt)
        k >>= 1
    return r


def address_of_point(pt) -> str:
    return "0x" + keccak256(pt[0].to_bytes(32, "big") + pt[1].to_bytes(32, "big"))[12:].hex()


def address_of_key(priv: int) -> str:
    return address_of_point(_mul(priv, G))


def _rfc6979_k(priv: int, digest: bytes) -> int:
    x = priv.to_bytes(32, "big")
    h = (int.from_bytes(digest, "big") % N).to_bytes(32, "big")
    v, k = b"\x01" * 32, b"\x00" * 32
    k = hmac.new(k, v + b"\x00" + x + h, hashlib.sha256).digest()
    v = hmac.new(k, v, hashlib.sha256).digest()
    k = hmac.new(k, v + b"\x01" + x + h, hashlib.sha256).digest()
    v = hmac.new(k, v, hashlib.sha256).digest()
    while True:
        v = hmac.new(k, v, hashlib.sha256).digest()
        cand = int.from_bytes(v, "big")
        if 1 <= cand < N:
            return cand
        k = hmac.new(k, v + b"\x00", hashlib.sha256).digest()
        v = hmac.new(k, v, hashlib.sha256).digest()


def sign(priv: int, digest: bytes) -> bytes:
    """65 bytes r ‖ s ‖ v with low s and v in {27, 28}. Test keys only."""
    if not 1 <= priv < N or len(digest) != 32:
        raise ValueError("bad key or digest")
    z = int.from_bytes(digest, "big")
    k = _rfc6979_k(priv, digest)
    R = _mul(k, G)
    r = R[0] % N
    s = pow(k, -1, N) * (z + r * priv) % N
    if r == 0 or s == 0 or R[0] >= N:
        raise ValueError("degenerate signature; choose another test digest")
    rec = R[1] & 1
    if s > N // 2:
        s, rec = N - s, rec ^ 1
    sig = r.to_bytes(32, "big") + s.to_bytes(32, "big") + bytes([27 + rec])
    assert sig[64] in (27, 28)
    return sig


def recover(digest: bytes, sig: bytes):
    """The address that signed `digest`, or None.

    Applies the range checks of TAP-11 §4.4 item 1: 65 bytes; v in {27, 28}, with 0 and 1 read as 27 and 28;
    r and s in [1, n - 1]; s at most n / 2. A signature that fails them recovers to nobody (None)."""
    if len(digest) != 32 or len(sig) != 65:
        return None
    r = int.from_bytes(sig[:32], "big")
    s = int.from_bytes(sig[32:64], "big")
    v = sig[64]
    if v in (0, 1):
        v += 27
    if v not in (27, 28) or not 1 <= r < N or not 1 <= s <= N // 2:
        return None
    x = r
    ysq = (pow(x, 3, P) + 7) % P
    y = pow(ysq, (P + 1) // 4, P)
    if y * y % P != ysq:
        return None
    if (y & 1) != (v - 27):
        y = P - y
    z = int.from_bytes(digest, "big")
    ri = pow(r, -1, N)
    q = _add(_mul(s * ri % N, (x, y)), _mul((-z * ri) % N, G))
    if q is None:
        return None
    return address_of_point(q)
