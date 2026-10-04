#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Recomputes every value in vectors.json from the field lists of TAP-draft-container-agent, Specification section 3,
# without the reference implementation. Dependencies: pycryptodome (Keccak-256 only). secp256k1 point arithmetic and
# public-key recovery are written out below from SEC 1 section 4.1.6. Run: python3 check.py
# Optional second opinion: if eth_account is installed, the typed digests are also computed with its EIP-712 encoder
# from the eth_signTypedData_v4 payloads in worked-examples.json.
import json, os, sys
from Crypto.Hash import keccak as _k

HERE = os.path.dirname(os.path.abspath(__file__))
V = json.load(open(os.path.join(HERE, 'vectors.json')))
W = json.load(open(os.path.join(HERE, 'worked-examples.json'))) if os.path.exists(os.path.join(HERE, 'worked-examples.json')) else {'examples': []}
fails = 0
def check(name, got, want):
    global fails
    ok = got == want
    if not ok: fails += 1
    print(('ok   ' if ok else 'FAIL ') + name + ('' if ok else f'\n     got  {got}\n     want {want}'))

def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def hx(b): return '0x' + b.hex()
def word_uint(n): assert 0 <= n < 2**256; return n.to_bytes(32, 'big')
def word_addr(a): return bytes(12) + bytes.fromhex(a[2:])
def word_b32(h): b = bytes.fromhex(h[2:]); assert len(b) == 32; return b
def word_bool(x): return word_uint(1 if x else 0)

# ---------- EIP-712, from the field lists (section 3.2 to 3.5) ----------
FIELDS = {
    'Scope': [('address', 'provider'), ('address', 'token'), ('uint256', 'cap')],
    'Mandate': [('address', 'principal'), ('address', 'agent'), ('address', 'agentKey'), ('uint8', 'mode'), ('bytes32', 'taskHash'),
                ('Scope[]', 'scope'), ('address', 'feeToken'), ('uint256', 'feeCap'), ('uint64', 'notBefore'), ('uint64', 'expires'),
                ('uint256', 'nonce'), ('bool', 'subdelegate')],
    'TaskOffer': [('address', 'principal'), ('address', 'agent'), ('bytes32', 'taskHash'), ('uint8', 'mode'), ('address', 'feeToken'),
                  ('uint256', 'fee'), ('uint64', 'deadline'), ('uint64', 'exp'), ('uint256', 'nonce')],
    'TaskVerdict': [('bytes32', 'mandateHash'), ('bytes32', 'deliverableHash'), ('uint8', 'verdict'), ('bytes32', 'reasonHash'), ('uint64', 'issued')],
    'MandateRevocation': [('address', 'principal'), ('bytes32[]', 'mandateHashes'), ('uint64', 'revokedBefore'), ('uint64', 'issued')],
}
def one(t): return t + '(' + ','.join(f'{ty} {n}' for ty, n in FIELDS[t]) + ')'
def encode_type(t): return one(t) + (one('Scope') if t == 'Mandate' else '')
def typehash(t): return keccak(encode_type(t).encode())
def enc(ty, v):
    if ty == 'address': return word_addr(v)
    if ty in ('uint256', 'uint64', 'uint8'): return word_uint(int(v))
    if ty == 'bytes32': return word_b32(v)
    if ty == 'bool': return word_bool(v)
    if ty == 'Scope[]': return keccak(b''.join(struct_hash('Scope', s) for s in v))
    if ty == 'bytes32[]': return keccak(b''.join(word_b32(x) for x in v))
    raise ValueError(ty)
def encode_data(t, m): return typehash(t) + b''.join(enc(ty, m[n]) for ty, n in FIELDS[t])
def struct_hash(t, m): return keccak(encode_data(t, m))
DOMAIN_TYPE = 'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'
def domain_sep(chain_id, d=V['domain']):
    return keccak(keccak(DOMAIN_TYPE.encode()) + keccak(d['name'].encode()) + keccak(d['version'].encode()) + word_uint(chain_id) + word_addr(d['verifyingContract']))
def typed_digest(chain_id, sh): return keccak(b'\x19\x01' + domain_sep(chain_id) + sh)

# ---------- secp256k1 (SEC 1), recovery with the TAP-11 section 4.4 item 1 range checks ----------
P = 2**256 - 2**32 - 977
N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798, 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)
def add(a, b):
    if a is None: return b
    if b is None: return a
    if a[0] == b[0] and (a[1] + b[1]) % P == 0: return None
    l = (3 * a[0] * a[0] * pow(2 * a[1], -1, P)) % P if a == b else ((b[1] - a[1]) * pow(b[0] - a[0], -1, P)) % P
    x = (l * l - a[0] - b[0]) % P
    return (x, (l * (a[0] - x) - a[1]) % P)
def mul(k, pt):
    r = None
    while k:
        if k & 1: r = add(r, pt)
        pt = add(pt, pt); k >>= 1
    return r
def addr_of(pub):
    return to_checksum(keccak(pub[0].to_bytes(32, 'big') + pub[1].to_bytes(32, 'big'))[12:].hex())
def to_checksum(h40):
    d = keccak(h40.encode()).hex()
    return '0x' + ''.join(c.upper() if c.isalpha() and int(d[i], 16) >= 8 else c for i, c in enumerate(h40))
def recover(digest, sig):
    b = bytes.fromhex(sig[2:])
    if len(b) != 65: raise ValueError('not 65 bytes')
    r, s, v = int.from_bytes(b[:32], 'big'), int.from_bytes(b[32:64], 'big'), b[64]
    if v in (0, 1): v += 27
    if v not in (27, 28): raise ValueError('bad v')
    if not (1 <= r < N and 1 <= s <= N // 2): raise ValueError('r or s out of range, or high s')
    y2 = (pow(r, 3, P) + 7) % P
    y = pow(y2, (P + 1) // 4, P)
    if (y * y) % P != y2: raise ValueError('r is not an x coordinate')
    if (y & 1) != (v - 27): y = P - y
    R = (r, y)
    e = int.from_bytes(digest, 'big')
    rinv = pow(r, -1, N)
    Q = add(mul((s * rinv) % N, R), mul((-e * rinv) % N, G))
    return addr_of(Q)

# ---------- checks ----------
holder = addr_of(mul(int(V['holderKey'], 16), G))
check('holder address from the test key', holder, V['holderAddress'])
for t in FIELDS:
    check(f'encodeType {t}', encode_type(t), V['types'][t])
    check(f'typehash {t}', hx(typehash(t)), V['typeHashes'][t])
check('keccak256("") (empty Scope[] or bytes32[])', hx(keccak(b'')), '0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470')

# canonical JSON of the task: these members are ASCII and the numbers are safe integers, so sorting by name with no
# whitespace is the RFC 8785 form (TAP-11 section 6) for this value
t = V['task']
canon = json.dumps(t['value'], sort_keys=True, separators=(',', ':'), ensure_ascii=False)
check('task canonical JSON', canon, t['canonical'])
check('taskHash', hx(keccak(canon.encode('utf-8'))), t['taskHash'])

CID = V['domain']['chainId']
check('domain separator (TAP-11 Test Cases, chainId 56)', hx(domain_sep(CID)), '0xa73ee348b5672f12dbc174f66a7d162c69e0d64befdba88475d9d7e3c0fd3ac7')
for c in V['mandates']:
    n = c['name']
    for i, s in enumerate(c['scope']):
        check(f'mandate scope[{i}] hashStruct / {n}', hx(struct_hash('Scope', s)), c['intermediate']['scopeHashes'][i])
    sh = struct_hash('Mandate', c)
    check(f'mandate structHash / {n}', hx(sh), c['intermediate']['structHash'])
    dg = typed_digest(CID, sh)
    check(f'mandate digest = mandateHash / {n}', hx(dg), c['digest'])
    check(f'mandate signature recovers the holder / {n}', recover(dg, c['sig']), c['recoversTo'])
    phase0 = all(s['cap'] == '0' and int(s['token'], 16) == 0 for s in c['scope']) and c['feeCap'] == '0' and int(c['feeToken'], 16) == 0 and c['subdelegate'] is False
    print(f'     phase-0 rule (3.6) {"passes" if phase0 else "fails: phase0-no-funds"} / {n}')
oc = V['otherChain']
m0 = V['mandates'][oc['mandate']]
dg_oc = typed_digest(oc['chainId'], struct_hash('Mandate', m0))
check('the same mandate on chainId 196', hx(dg_oc), oc['digest'])
other = recover(dg_oc, m0['sig'])
check('mandate 0 signature checked against the chainId 196 digest does not recover the holder', other != V['holderAddress'], True)
print(f'     (it recovers {other})')
for key, t in [('offers', 'TaskOffer'), ('verdicts', 'TaskVerdict'), ('revocations', 'MandateRevocation')]:
    for c in V[key]:
        sh = struct_hash(t, c)
        check(f'{t} structHash / {c["name"]}', hx(sh), c['structHash'])
        dg = typed_digest(CID, sh)
        check(f'{t} digest / {c["name"]}', hx(dg), c['digest'])
        check(f'{t} signature recovers the holder / {c["name"]}', recover(dg, c['sig']), V['holderAddress'])
# the verdict and revocation vectors refer to mandate digests above
check('verdict mandateHash is mandate 0 digest', V['verdicts'][0]['mandateHash'], V['mandates'][0]['digest'])
check('revocation 0 lists mandates 0 and 1', V['revocations'][0]['mandateHashes'], [V['mandates'][0]['digest'], V['mandates'][1]['digest']])
# high-s twin of mandate 0's signature is refused although it would recover the same key
b = bytearray(bytes.fromhex(m0['sig'][2:])); s = int.from_bytes(b[32:64], 'big'); b[32:64] = (N - s).to_bytes(32, 'big'); b[64] = 55 - b[64]
try: recover(bytes.fromhex(m0['digest'][2:]), '0x' + b.hex()); check('high-s twin refused', False, True)
except ValueError: check('high-s twin refused', True, True)

# ---------- the worked examples: every intermediate is recomputed ----------
for ex in W['examples']:
    pt, msg = ex['typedData']['primaryType'], ex['typedData']['message']
    check(f'worked {pt}: encodeData', hx(encode_data(pt, msg)), ex['encodeData'])
    check(f'worked {pt}: structHash', hx(struct_hash(pt, msg)), ex['structHash'])
    check(f'worked {pt}: domainSeparator', hx(domain_sep(ex['typedData']['domain']['chainId'])), ex['domainSeparator'])
    pre = b'\x19\x01' + domain_sep(ex['typedData']['domain']['chainId']) + struct_hash(pt, msg)
    check(f'worked {pt}: 66-byte digest preimage', hx(pre), ex['digestPreimage'])
    check(f'worked {pt}: digest', hx(keccak(pre)), ex['digest'])
    check(f'worked {pt}: signature recovers', recover(keccak(pre), ex['sig']), ex['recoversTo'])

try:
    from eth_account.messages import encode_typed_data
    from eth_account import Account
    def ints(m, types, pt):
        out = {}
        for f in types[pt]:
            v = m[f['name']]
            if f['type'].startswith('uint'): v = int(v)
            elif f['type'] == 'Scope[]': v = [ints(x, types, 'Scope') for x in v]
            out[f['name']] = v
        return out
    for ex in W['examples']:
        td = json.loads(json.dumps(ex['typedData']))
        td['message'] = ints(td['message'], td['types'], td['primaryType'])
        sm = encode_typed_data(full_message=td)
        dg = keccak(b'\x19' + sm.version + sm.header + sm.body)
        check(f'eth_account EIP-712 digest of the worked {td["primaryType"]}', hx(dg), ex['digest'])
        check(f'eth_account recovery of the worked {td["primaryType"]}', Account.recover_message(sm, signature=ex['sig']), ex['recoversTo'])
except ImportError:
    print('     (eth_account not installed: second EIP-712 implementation skipped)')

# ---------- revocation file sizes (Rationale, "Revocation by file and by message") ----------
# 24 hashes, a 1,024-byte signature, every number at 2^53 - 1; compact must fit 4,096 bytes, pretty-printed does not
BIG = 2**53 - 1
rv = {'principal': '0x' + 'ab' * 20, 'mandateHashes': ['0x' + 'cd' * 32] * 24, 'revokedBefore': BIG, 'issued': BIG}
f = {'tapeapi-mandates': '0', 'chainId': BIG, 'revocation': rv, 'sig': '0x' + 'ef' * 1024}
check('revocation file, worst case, compact: 3,915 bytes', len(json.dumps(f, separators=(',', ':')).encode()), 3915)
check('revocation file, the same on chain 56 with a two-space indent: 4,118 bytes (over 4,096)', len(json.dumps(dict(f, chainId=56), indent=2).encode()), 4118)
# the other type hashes of the TAP-11 domain (ChannelKeys from the unmerged draft #12)
for name, s_, want in [('Delegation', 'Delegation(address container,address signer,uint64 expires)', '0xc5081f9dc7e79dfbe7f3b3220ed9e7a29d0bc53239ee74dc184e4ac1f810948c'),
                       ('ManifestContent', 'ManifestContent(address container,bytes32 contentHash)', '0x809c1147faa2cda8716cdc72c000b05406f238cb127fea6f0abed585c02aea1c'),
                       ('ChannelKeys', 'ChannelKeys(address container,bytes32 x25519,bytes32 ed25519,bytes32 inbox,uint64 issued,uint64 expires)', '0x4dcd46fdde436adbdcfd3c3541cdb782612b23122af4c1640f9f673211d32542')]:
    check(f'{name} typehash as stated in Test Cases', hx(keccak(s_.encode())), want)
    check(f'{name} typehash differs from every type of this draft', want in V['typeHashes'].values(), False)

print('\n%s: %d failure(s)' % ('FAILED' if fails else 'all checks passed', fails))
sys.exit(1 if fails else 0)
