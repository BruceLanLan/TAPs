# SPDX-License-Identifier: MIT
"""Bitcoin primitives for the Bitcoin-keyed holders TAP, dependency-free Python 3.

secp256k1, BIP-340 Schnorr, deterministic ECDSA (RFC 6979) with low s, taproot key
tweak (BIP-341/BIP-86), bech32/bech32m addresses (BIP-173/BIP-350), base58check WIF,
and BIP-322 "simple" signing and verification for P2TR key-path and P2WPKH.
Written for test vectors: not constant-time, never use it with keys that hold value.
"""
import base64
import re
import hashlib
import hmac

P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
     0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)


def sha256(b):
    return hashlib.sha256(b).digest()


def sha256d(b):
    return sha256(sha256(b))


def hash160(b):
    return hashlib.new("ripemd160", sha256(b)).digest()


def tagged(tag, data):
    t = sha256(tag.encode())
    return sha256(t + t + data)


# ------------------------------------------------------------------ curve

def add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0] and (a[1] + b[1]) % P == 0:
        return None
    if a == b:
        lam = 3 * a[0] * a[0] * pow(2 * a[1], P - 2, P) % P
    else:
        lam = (b[1] - a[1]) * pow(b[0] - a[0], P - 2, P) % P
    x = (lam * lam - a[0] - b[0]) % P
    return (x, (lam * (a[0] - x) - a[1]) % P)


def mul(k, pt=G):
    r = None
    while k:
        if k & 1:
            r = add(r, pt)
        pt = add(pt, pt)
        k >>= 1
    return r


def lift_x(x):
    if x >= P:
        return None
    c = (pow(x, 3, P) + 7) % P
    y = pow(c, (P + 1) // 4, P)
    if y * y % P != c:
        return None
    return (x, y if y % 2 == 0 else P - y)


def xb(pt):
    return pt[0].to_bytes(32, "big")


def compressed(pt):
    return bytes([2 + (pt[1] & 1)]) + xb(pt)


# ------------------------------------------------------------------ BIP-340

def schnorr_sign(seckey, msg, aux=bytes(32)):
    d0 = seckey
    pt = mul(d0)
    d = d0 if pt[1] % 2 == 0 else N - d0
    t = (d ^ int.from_bytes(tagged("BIP0340/aux", aux), "big")).to_bytes(32, "big")
    k0 = int.from_bytes(tagged("BIP0340/nonce", t + xb(pt) + msg), "big") % N
    assert k0 != 0
    r = mul(k0)
    k = k0 if r[1] % 2 == 0 else N - k0
    e = int.from_bytes(tagged("BIP0340/challenge", xb(r) + xb(pt) + msg), "big") % N
    sig = xb(r) + ((k + e * d) % N).to_bytes(32, "big")
    assert schnorr_verify(xb(pt), msg, sig)
    return sig


def schnorr_verify(px, msg, sig):
    pt = lift_x(int.from_bytes(px, "big"))
    if pt is None or len(sig) != 64:
        return False
    r, s = int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big")
    if r >= P or s >= N:
        return False
    e = int.from_bytes(tagged("BIP0340/challenge", sig[:32] + px + msg), "big") % N
    rr = add(mul(s), mul(N - e, pt))
    return rr is not None and rr[1] % 2 == 0 and rr[0] == r


# ------------------------------------------------------------------ ECDSA (RFC 6979, low s)

def _rfc6979_k(seckey, h):
    x = seckey.to_bytes(32, "big")
    v, k = b"\x01" * 32, b"\x00" * 32
    k = hmac.new(k, v + b"\x00" + x + h, hashlib.sha256).digest()
    v = hmac.new(k, v, hashlib.sha256).digest()
    k = hmac.new(k, v + b"\x01" + x + h, hashlib.sha256).digest()
    v = hmac.new(k, v, hashlib.sha256).digest()
    while True:
        v = hmac.new(k, v, hashlib.sha256).digest()
        c = int.from_bytes(v, "big")
        if 1 <= c < N:
            return c
        k = hmac.new(k, v + b"\x00", hashlib.sha256).digest()
        v = hmac.new(k, v, hashlib.sha256).digest()


def ecdsa_sign(seckey, h):
    k = _rfc6979_k(seckey, h)
    r = mul(k)[0] % N
    s = pow(k, N - 2, N) * (int.from_bytes(h, "big") + r * seckey) % N
    if s > N // 2:
        s = N - s
    return r, s


def ecdsa_verify(pub, h, r, s):
    if not (1 <= r < N and 1 <= s < N):
        return False
    w = pow(s, N - 2, N)
    pt = add(mul(int.from_bytes(h, "big") * w % N), mul(r * w % N, pub))
    return pt is not None and pt[0] % N == r


def der(r, s):
    def enc(v):
        b = v.to_bytes(32, "big").lstrip(b"\x00") or b"\x00"
        if b[0] & 0x80:
            b = b"\x00" + b
        return b"\x02" + bytes([len(b)]) + b
    body = enc(r) + enc(s)
    return b"\x30" + bytes([len(body)]) + body


# ------------------------------------------------------------------ keys and addresses

def taproot_tweak(seckey):
    """BIP-86 single-key output: returns (tweaked secret key, x-only output key)."""
    pt = mul(seckey)
    d = seckey if pt[1] % 2 == 0 else N - seckey
    t = int.from_bytes(tagged("TapTweak", xb(pt)), "big")
    q = add(lift_x(pt[0]), mul(t))
    return (d + t) % N, xb(q)


_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def _polymod(values):
    gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    chk = 1
    for v in values:
        top = chk >> 25
        chk = (chk & 0x1ffffff) << 5 ^ v
        for i in range(5):
            chk ^= gen[i] if (top >> i) & 1 else 0
    return chk


def _hrp_expand(hrp):
    return [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]


def _convertbits(data, frm, to, pad):
    acc, bits, out = 0, 0, []
    for v in data:
        acc = (acc << frm) | v
        bits += frm
        while bits >= to:
            bits -= to
            out.append((acc >> bits) & ((1 << to) - 1))
    if pad and bits:
        out.append((acc << (to - bits)) & ((1 << to) - 1))
    elif not pad and (bits >= frm or (acc << (to - bits)) & ((1 << to) - 1)):
        return None
    return out


def segwit_address(version, program, hrp="bc"):
    const = 1 if version == 0 else 0x2bc830a3
    data = [version] + _convertbits(program, 8, 5, True)
    poly = _polymod(_hrp_expand(hrp) + data + [0] * 6) ^ const
    return hrp + "1" + "".join(_CHARSET[d] for d in data + [(poly >> 5 * (5 - i)) & 31 for i in range(6)])


def decode_segwit(addr, hrps=("bc",)):
    """Returns (version, program) for a bech32/bech32m segwit address, or raises ValueError. Only mainnet (`bc`) addresses by
    default: the TAP (section 1) forbids deriving a holder from another human-readable part, although the contract sees only
    the scriptPubKey and could not tell them apart."""
    if addr.lower() != addr and addr.upper() != addr:
        raise ValueError("mixed case")
    addr = addr.lower()
    pos = addr.rfind("1")
    hrp, rest = addr[:pos], addr[pos + 1:]
    if hrp not in hrps or len(rest) < 7:
        raise ValueError("hrp: only mainnet bc1 addresses are supported (TAP section 1)")
    data = [_CHARSET.index(c) for c in rest]
    poly = _polymod(_hrp_expand(hrp) + data)
    version = data[0]
    if poly != (1 if version == 0 else 0x2bc830a3):
        raise ValueError("checksum")
    program = bytes(_convertbits(data[1:-6], 5, 8, False) or b"")
    if version == 0 and len(program) not in (20, 32) or version == 1 and len(program) != 32:
        raise ValueError("program length")
    if segwit_address(version, program, hrp) != addr:
        raise ValueError("round trip")
    return version, program


def script_pubkey(addr):
    if addr[:1] in ("1", "3"):
        raise ValueError("unsupported address type: only native SegWit bc1q... (P2WPKH) and Taproot bc1p... (P2TR) addresses work; "
                         "P2PKH and P2SH-wrapped addresses cannot sign BIP-322 'simple' messages")
    version, program = decode_segwit(addr)
    if version == 1:
        return b"\x51\x20" + program
    if version == 0 and len(program) == 20:
        return b"\x00\x14" + program
    raise ValueError("only P2TR and P2WPKH addresses are supported")


_B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def wif_secret(wif):
    n = 0
    for c in wif:
        n = n * 58 + _B58.index(c)
    raw = n.to_bytes(38, "big")
    payload, check = raw[:-4], raw[-4:]
    assert sha256d(payload)[:4] == check and payload[0] == 0x80 and payload[-1] == 0x01
    return int.from_bytes(payload[1:33], "big")


# ------------------------------------------------------------------ BIP-322 simple

def message_hash(message):
    return tagged("BIP0322-signed-message", message)


def to_spend_txid(message, spk):
    tx = (bytes(4) + b"\x01" + bytes(32) + b"\xff\xff\xff\xff" + b"\x22\x00\x20" + message_hash(message)
          + bytes(4) + b"\x01" + bytes(8) + bytes([len(spk)]) + spk + bytes(4))
    return sha256d(tx)


def taproot_sighash(txid, spk, hash_type):
    sig_msg = (b"\x00" + bytes([hash_type]) + bytes(4) + bytes(4) + sha256(txid + bytes(4)) + sha256(bytes(8))
               + sha256(bytes([len(spk)]) + spk) + sha256(bytes(4)) + sha256(bytes(8) + b"\x01\x6a")
               + b"\x00" + bytes(4))
    return tagged("TapSighash", sig_msg)


def segwit_v0_sighash(txid, key_hash):
    pre = (bytes(4) + sha256d(txid + bytes(4)) + sha256d(bytes(4)) + txid + bytes(4)
           + b"\x19\x76\xa9\x14" + key_hash + b"\x88\xac" + bytes(8) + bytes(4)
           + sha256d(bytes(8) + b"\x01\x6a") + bytes(4) + b"\x01\x00\x00\x00")
    return sha256d(pre)


def sign_simple(seckey, spk, message, sighash_all=False):
    """The BIP-322 simple signature (serialized witness) of `message` by the address with scriptPubKey `spk`."""
    txid = to_spend_txid(message, spk)
    if spk[:2] == b"\x51\x20":
        tweaked, out_key = taproot_tweak(seckey)
        assert out_key == spk[2:]
        sig = schnorr_sign(tweaked, taproot_sighash(txid, spk, 1 if sighash_all else 0))
        return b"\x01\x41" + sig + b"\x01" if sighash_all else b"\x01\x40" + sig
    if spk[:2] == b"\x00\x14":
        pub = compressed(mul(seckey))
        assert hash160(pub) == spk[2:]
        r, s = ecdsa_sign(seckey, segwit_v0_sighash(txid, spk[2:]))
        d = der(r, s) + b"\x01"
        return b"\x02" + bytes([len(d)]) + d + b"\x21" + pub
    raise ValueError("unsupported scriptPubKey")


def verify_simple(spk, message, witness):
    """Python mirror of the contract's rules (BIP322.sol). Returns bool."""
    txid = to_spend_txid(message, spk)
    if spk[:2] == b"\x51\x20":
        if len(witness) == 66 and witness[:2] == b"\x01\x40":
            ht = 0
        elif len(witness) == 67 and witness[:2] == b"\x01\x41" and witness[66] == 1:
            ht = 1
        else:
            return False
        return schnorr_verify(spk[2:], taproot_sighash(txid, spk, ht), witness[2:66])
    if spk[:2] == b"\x00\x14":
        if len(witness) < 2 or witness[0] != 2:
            return False
        sl = witness[1]
        if sl < 9 or sl > 73 or 2 + sl + 34 != len(witness) or witness[1 + sl] != 1 or witness[2 + sl] != 0x21:
            return False
        d = witness[2:1 + sl]
        parsed = parse_der_strict(d)
        if parsed is None:
            return False
        r, s = parsed
        if not (1 <= r < N and 1 <= s <= N // 2):
            return False
        pub = witness[3 + sl:]
        if hash160(pub) != spk[2:] or pub[0] not in (2, 3):
            return False
        pt = lift_x(int.from_bytes(pub[1:], "big"))
        if pt is None:
            return False
        if pub[0] == 3:
            pt = (pt[0], P - pt[1])
        return ecdsa_verify(pt, segwit_v0_sighash(txid, spk[2:]), r, s)
    return False


def parse_der_strict(d):
    if len(d) < 8 or d[0] != 0x30 or d[1] != len(d) - 2:
        return None
    out, i = [], 2
    for _ in range(2):
        if i + 2 > len(d) or d[i] != 2:
            return None
        ln = d[i + 1]
        v = d[i + 2:i + 2 + ln]
        if ln == 0 or ln > 33 or len(v) != ln or v[0] & 0x80 or (v[0] == 0 and (ln == 1 or not v[1] & 0x80)):
            return None
        if ln == 33 and v[0] != 0:
            return None
        out.append(int.from_bytes(v, "big"))
        i += 2 + ln
    return tuple(out) if i == len(d) else None


def witness_from_wallet(text):
    """Wallet output to witness bytes (TAP §6.1): trim ASCII whitespace, refuse 'ful'/'pof', drop 'smp', strict base64."""
    text = text.strip(" \t\r\n")
    if text.startswith(("ful", "pof")):
        raise ValueError("BIP-322 full signatures and proofs of funds are not supported")
    if text.startswith("smp"):
        text = text[3:]
    # RFC 4648 section 4 with padding: a multiple of 4 characters, "=" only as the last one or two
    if len(text) % 4 or not re.fullmatch(r"[A-Za-z0-9+/]*={0,2}", text):
        raise ValueError("not strict base64")
    return base64.b64decode(text, validate=True)
