#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Recomputes the values in visitor-grant.json from the text of TAP-draft-visitor-grants (Specification §3 to §6 and
# §9), with the Python standard library only: Keccak-256, the canonical JSON of TAP-11 §6 (the subset these vectors
# need, with its refusals), EIP-712 encoding and secp256k1 public-key recovery (SEC 1 v2 §4.1.6) are written out below.
# Nothing is imported from any implementation of the TAP. The code is taken from the independent Python check of the
# reference implementation (spec/vectors/verify.py of TapeAPI), reduced to this file.
# Run: python3 check.py        (Python 3.8 or later; exit code 0 when every check agrees)
import datetime, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
fails = 0
checked = 0


def check(name, got, want):
    global fails, checked
    checked += 1
    ok = got == want
    if not ok:
        fails += 1
    print(('ok   ' if ok else 'FAIL ') + name + ('' if ok else '\n     got  %s\n     want %s' % (got, want)))


# ---------- Keccak-256 (the original Keccak padding 0x01, not the 0x06 of SHA-3) ----------
_RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
       0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
       0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
       0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
       0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
       0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
        [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M = (1 << 64) - 1


def _rotl(x, n):
    return ((x << n) | (x >> (64 - n))) & _M


def _keccak_f(a):
    for rnd in range(24):
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rotl(c[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                a[x][y] ^= d[x]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rotl(a[x][y], _ROT[x][y])
        for x in range(5):
            for y in range(5):
                a[x][y] = b[x][y] ^ ((~b[(x + 1) % 5][y]) & _M) & b[(x + 2) % 5][y]
        a[0][0] ^= _RC[rnd]
    return a


def keccak256(data):
    rate = 136
    a = [[0] * 5 for _ in range(5)]
    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % rate != 0:
        padded.append(0x00)
    padded[-1] |= 0x80
    for off in range(0, len(padded), rate):
        blk = padded[off:off + rate]
        for i in range(rate // 8):
            a[i % 5][i // 5] ^= int.from_bytes(blk[i * 8:i * 8 + 8], 'little')
        a = _keccak_f(a)
    out = bytearray()
    for i in range(4):
        out += a[i % 5][i // 5].to_bytes(8, 'little')
    return bytes(out[:32])


# ---------- canonical JSON (TAP-11 §6): sorted by UTF-16 code units, JSON.stringify escapes ----------
# Numbers: only integers within +-(2^53 - 1) occur in these vectors; anything else is refused here rather than guessed.
_ESC = {'"': '\\"', '\\': '\\\\', '\b': '\\b', '\f': '\\f', '\n': '\\n', '\r': '\\r', '\t': '\\t'}
FORBIDDEN = {'__proto__', 'constructor', 'prototype'}


def _str(s):
    if any(0xD800 <= ord(ch) <= 0xDFFF for ch in s):
        raise ValueError('unpaired UTF-16 surrogate')
    out = ['"']
    for ch in s:
        if ch in _ESC:
            out.append(_ESC[ch])
        elif ord(ch) < 0x20:
            out.append('\\u%04x' % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return ''.join(out)


def canonical(v):
    if v is None:
        return 'null'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, int):
        if abs(v) > 2 ** 53 - 1:
            raise ValueError('integer outside +-(2^53 - 1)')
        return str(v)
    if isinstance(v, str):
        return _str(v)
    if isinstance(v, list):
        return '[' + ','.join(canonical(x) for x in v) + ']'
    if isinstance(v, dict):
        parts = []
        for k in sorted(v.keys(), key=lambda k: k.encode('utf-16-be')):
            if k in FORBIDDEN:
                raise ValueError('forbidden member name %r' % k)
            parts.append(_str(k) + ':' + canonical(v[k]))
        return '{' + ','.join(parts) + '}'
    raise ValueError('this check handles no %s (not needed by these vectors)' % type(v).__name__)


# ---------- EIP-712 and EIP-191 ----------
def h(x):
    return '0x' + x.hex()


def u64(n):
    return int(n).to_bytes(8, 'big')


def addr32(a):
    return bytes(12) + bytes.fromhex(a[2:])


def eip712_domain(name, version, chain_id, verifying):
    type_hash = keccak256(b'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
    return keccak256(type_hash + keccak256(name.encode()) + keccak256(version.encode()) +
                     int(chain_id).to_bytes(32, 'big') + addr32(verifying))


def typed_digest(domain_sep, struct_hash):
    return keccak256(b'\x19\x01' + domain_sep + struct_hash)


def eip191(digest32):
    return keccak256(b'\x19Ethereum Signed Message:\n32' + digest32)


# ---------- secp256k1 public-key recovery with the range checks of TAP-11 §4.4 item 1 ----------
_SP = 2 ** 256 - 2 ** 32 - 977
_SN = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
_SG = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
       0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)


def _add(A, B):
    if A is None:
        return B
    if B is None:
        return A
    if A[0] == B[0] and (A[1] + B[1]) % _SP == 0:
        return None
    if A == B:
        lam = 3 * A[0] * A[0] * pow(2 * A[1], _SP - 2, _SP) % _SP
    else:
        lam = (B[1] - A[1]) * pow(B[0] - A[0], _SP - 2, _SP) % _SP
    x = (lam * lam - A[0] - B[0]) % _SP
    return (x, (lam * (A[0] - x) - A[1]) % _SP)


def _mul(k, A):
    R = None
    while k:
        if k & 1:
            R = _add(R, A)
        A = _add(A, A)
        k >>= 1
    return R


def recover_address(digest32, sig_hex):
    """The lower-case address whose key made the 65-byte r || s || v signature over digest32, or None (high s refused)."""
    sig = bytes.fromhex(sig_hex[2:])
    if len(sig) != 65:
        return None
    r, s, v = int.from_bytes(sig[:32], 'big'), int.from_bytes(sig[32:64], 'big'), sig[64]
    if v >= 27:
        v -= 27
    if not (0 < r < _SN and 0 < s <= _SN // 2) or v not in (0, 1):
        return None
    y2 = (pow(r, 3, _SP) + 7) % _SP
    y = pow(y2, (_SP + 1) // 4, _SP)
    if y * y % _SP != y2:
        return None
    if y & 1 != v:
        y = _SP - y
    e = int.from_bytes(digest32, 'big')
    ri = pow(r, _SN - 2, _SN)
    Q = _add(_mul(s * ri % _SN, (r, y)), _mul((-e * ri) % _SN, _SG))
    if Q is None:
        return None
    return '0x' + keccak256(Q[0].to_bytes(32, 'big') + Q[1].to_bytes(32, 'big'))[12:].hex()


# ---------- the types (Specification §3, §4.1, §8.1) ----------
vg = json.load(open(os.path.join(HERE, 'visitor-grant.json'), encoding='utf-8'))
VG_FIELDS = [('string', 'statement'), ('address', 'user'), ('address', 'caller'), ('string', 'callerName'), ('address', 'callerHolder'),
             ('address', 'callerKey'), ('address', 'audience'), ('string', 'audienceName'), ('address', 'audienceHolder'),
             ('string[]', 'methods'), ('uint32', 'maxCalls'), ('uint64', 'notBefore'), ('uint64', 'expires'), ('bytes32', 'nonce')]
GR_FIELDS = [('address', 'user'), ('bytes32[]', 'grantHashes'), ('uint64', 'revokedBefore'), ('uint64', 'issued')]
TYPES = {'VisitorGrant': 'VisitorGrant(%s)' % ','.join('%s %s' % f for f in VG_FIELDS),
         'GrantRevocation': 'GrantRevocation(%s)' % ','.join('%s %s' % f for f in GR_FIELDS)}
for n, t in TYPES.items():
    check('type string ' + n, t, vg['types'][n])
    check('type hash ' + n, h(keccak256(t.encode())), vg['typeHashes'][n])
check('no amount, token, fee or cap in either type',
      any(w in (TYPES['VisitorGrant'] + TYPES['GrantRevocation']).lower() for w in ('amount', 'token', 'fee', ' cap')), False)
vd = vg['domain']
check('domain name and version are this TAP\'s, not TAP-11\'s "TapeAPI"', (vd['name'], vd['version']), ('TapeAPI Visitor Grant', '1'))
dsep = eip712_domain(vd['name'], vd['version'], vd['chainId'], vd['verifyingContract'])
check('domain separator', h(dsep), vg['domainSeparator'])
check('domain separator differs from the TAP-11 domain on the same chain and hub',
      dsep != eip712_domain('TapeAPI', '1', vd['chainId'], vd['verifyingContract']), True)


def enc(t, v):
    if t == 'string':
        return keccak256(v.encode('utf-8'))
    if t == 'string[]':
        return keccak256(b''.join(keccak256(x.encode('utf-8')) for x in v))
    if t == 'bytes32[]':
        return keccak256(b''.join(bytes.fromhex(x[2:]) for x in v))
    if t == 'address':
        return addr32(v)
    if t == 'bytes32':
        return bytes.fromhex(v[2:])
    return int(v).to_bytes(32, 'big')


def struct_hash(name, fields, m):
    return keccak256(keccak256(TYPES[name].encode()) + b''.join(enc(t, m[f]) for t, f in fields))


# ---------- the statement (Specification §4.3) ----------
def utc(s):
    return datetime.datetime.fromtimestamp(s, datetime.timezone.utc).strftime('%Y-%m-%d %H:%M:%S')


def statement(m, lang):
    ms, n = ', '.join(m['methods']), m['maxCalls']
    if lang == 'zh':
        return '允许 %s 代表我调用 %s 的方法：%s。最多 %d 次，%s 至 %s UTC 有效。本授权不含任何付款。可随时向 %s 撤销。' % (
            m['callerName'], m['audienceName'], ms, n, utc(m['notBefore']), utc(m['expires']), m['audienceName'])
    return ('Allow %s to call these methods of %s on my behalf: %s. At most %d call%s, valid from %s to %s UTC. '
            'This grant includes no payment. Revocable at any time with %s.') % (
        m['callerName'], m['audienceName'], ms, n, '' if n == 1 else 's', utc(m['notBefore']), utc(m['expires']), m['audienceName'])


# ---------- grants ----------
for c in vg['grants']:
    m = c['message']
    check('statement en / ' + c['name'], statement(m, 'en'), c['statements']['en'])
    check('statement zh / ' + c['name'], statement(m, 'zh'), c['statements']['zh'])
    check('statement is a v1 rendering / ' + c['name'], m['statement'] in (statement(m, 'en'), statement(m, 'zh')), True)
    check('statement names no address / ' + c['name'], '0x' in m['statement'], False)
    check('methods hash / ' + c['name'], h(enc('string[]', m['methods'])), c['methodsHash'])
    sh = struct_hash('VisitorGrant', VG_FIELDS, m)
    check('struct hash / ' + c['name'], h(sh), c['structHash'])
    dg = typed_digest(dsep, sh)
    check('digest (grant hash) / ' + c['name'], h(dg), c['digest'])
    check('user signature recovers to the user / ' + c['name'], recover_address(dg, c['userSig']), vg['userAddress'].lower())
    check('bounds of §4.2 / ' + c['name'],
          (1 <= len(m['methods']) <= 8, 1 <= m['maxCalls'] <= 10000, 0 < m['expires'] - m['notBefore'] <= 604800,
           m['callerKey'].lower() != m['user'].lower()), (True, True, True, True))
oc = vg['otherChain']
check('another chain, another grant hash',
      h(typed_digest(eip712_domain(vd['name'], vd['version'], oc['chainId'], vd['verifyingContract']),
                     struct_hash('VisitorGrant', VG_FIELDS, vg['grants'][0]['message']))), oc['digest'])

# ---------- call proofs (Specification §5) ----------
for p in vg['proofs']:
    pre = (vg['callProofPrefix'].encode() + bytes.fromhex(p['audience'][2:]) + bytes.fromhex(p['grantHash'][2:]) +
           keccak256(p['id'].encode('utf-8')) + keccak256(canonical({'method': p['method'], 'params': p['params']}).encode('utf-8')) +
           u64(p['ts']))
    check('proof preimage is 140 bytes / ' + p['name'], len(pre), 140)
    check('proof preimage / ' + p['name'], h(pre), p['preimage'])
    check('proof digest / ' + p['name'], h(keccak256(pre)), p['digest'])
    check('proof EIP-191 digest / ' + p['name'], h(eip191(keccak256(pre))), p['personalDigest'])
    check('proof signature recovers to the callerKey / ' + p['name'], recover_address(eip191(keccak256(pre)), p['sig']), vg['callerKeyAddress'].lower())
    check('proof prefix is not TAP-13\'s / ' + p['name'], pre[:14] != b'TAPI-1/resp/v2', True)

# ---------- revocations (Specification §8.1) ----------
for r in vg['revocations']:
    sh = struct_hash('GrantRevocation', GR_FIELDS, r['revocation'])
    check('revocation struct hash / ' + r['name'], h(sh), r['structHash'])
    check('revocation digest / ' + r['name'], h(typed_digest(dsep, sh)), r['digest'])
    check('revocation signature recovers to the user / ' + r['name'], recover_address(typed_digest(dsep, sh), r['sig']), vg['userAddress'].lower())

# ---------- the two type hashes are new ----------
# TAP-11 §4.1 and §5.2, the four types of the phase-0 container-agent draft (TAPs pull request #47) and the voucher
# of the escrow-channel draft (TAPs pull request #59), from their type strings.
OTHER = [
    'Delegation(address container,address signer,uint64 expires)',
    'ManifestContent(address container,bytes32 contentHash)',
    'Mandate(address principal,address agent,address agentKey,uint8 mode,bytes32 taskHash,Scope[] scope,address feeToken,'
    'uint256 feeCap,uint64 notBefore,uint64 expires,uint256 nonce,bool subdelegate)Scope(address provider,address token,uint256 cap)',
    'TaskOffer(address principal,address agent,bytes32 taskHash,uint8 mode,address feeToken,uint256 fee,uint64 deadline,uint64 exp,uint256 nonce)',
    'TaskVerdict(bytes32 mandateHash,bytes32 deliverableHash,uint8 verdict,bytes32 reasonHash,uint64 issued)',
    'MandateRevocation(address principal,bytes32[] mandateHashes,uint64 revokedBefore,uint64 issued)',
    'Voucher(address consumer,address provider,uint256 cumulative,uint64 expires)',
]
assert h(keccak256(OTHER[0].encode())) == '0xc5081f9dc7e79dfbe7f3b3220ed9e7a29d0bc53239ee74dc184e4ac1f810948c', 'Keccak-256 self-test (TAP-11 §4.1)'
assert h(keccak256(OTHER[1].encode())) == '0x809c1147faa2cda8716cdc72c000b05406f238cb127fea6f0abed585c02aea1c', 'Keccak-256 self-test (TAP-11 §5.2)'
other = [keccak256(t.encode()) for t in OTHER]
check('the two type hashes differ from Delegation, ManifestContent, the #47 types and the #59 voucher',
      len(set(other + [keccak256(t.encode()) for t in TYPES.values()])), len(other) + 2)

print('%s: %d checks, %d disagreed' % ('ok' if not fails else 'FAIL', checked, fails))
sys.exit(1 if fails else 0)
