#!/usr/bin/env python3
# Rechecks hidden-text.json against TAP-11 §3.5 items 1 and 2, which TAP-draft-mcp-tools §3.4 cites, applied to the covered
# members of a tool list. Usage: python3 -I hidden-text-check.py [hidden-text.json]. Exits 1 on any mismatch.
# Standard library only. MIT License.
#
# The Unicode properties and NFC come from unicode-15.1.json in this directory, which is byte for byte the table file of
# TAP-11 §3.5 (assets/tap-11/unicode-15.1.json); the digest below is the one that section states. The Python
# `unicodedata` module is not used: its Unicode version is not the pinned one. The NFC code is UAX #15 over the tables.
import hashlib, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TABLES_SHA256 = 'a5fc0644d85d4638999ab5bb2d09f50514cfe10e7db6b4134638682a7c9fc4fd'
_raw = open(os.path.join(HERE, 'unicode-15.1.json'), 'rb').read()
if hashlib.sha256(_raw).hexdigest() != TABLES_SHA256:
    sys.exit('unicode-15.1.json does not match the digest stated in TAP-11 section 3.5')
T = json.loads(_raw.decode('utf-8'))


def _ranges(lst):
    out = []
    for r in lst:
        lo, _, hi = r.partition('-')
        out.append((int(lo, 16), int(hi or lo, 16)))
    return tuple(out)


CC, CF, DI, BIDI, EMOJI, FCE = (_ranges(T[k]) for k in (
    'Cc', 'Cf', 'Default_Ignorable_Code_Point', 'Bidi_Control', 'Emoji', 'Full_Composition_Exclusion'))
CCC = {}
for _v, _lst in T['ccc'].items():
    for _lo, _hi in _ranges(_lst):
        for _c in range(_lo, _hi + 1):
            CCC[_c] = int(_v)
DECOMP = {int(k, 16): [int(x, 16) for x in v.split()] for k, v in T['decomposition'].items()}


def _in(table, cp):
    lo, hi = 0, len(table) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        a, b = table[mid]
        if cp < a: hi = mid - 1
        elif cp > b: lo = mid + 1
        else: return True
    return False


COMPOSE = {(d[0], d[1]): c for c, d in DECOMP.items() if len(d) == 2 and not _in(FCE, c)}
SB, LB, VB, TB, LC, VC, TC = 0xAC00, 0x1100, 0x1161, 0x11A7, 19, 21, 28


def _decompose(c, out):
    if SB <= c < SB + LC * VC * TC:
        n = c - SB
        out.append(LB + n // (VC * TC)); out.append(VB + (n % (VC * TC)) // TC)
        if n % TC: out.append(TB + n % TC)
    elif c in DECOMP:
        for x in DECOMP[c]: _decompose(x, out)
    else:
        out.append(c)


def _pair(a, b):
    if LB <= a < LB + LC and VB <= b < VB + VC: return SB + ((a - LB) * VC + (b - VB)) * TC
    if SB <= a < SB + LC * VC * TC and (a - SB) % TC == 0 and TB < b < TB + TC: return a + (b - TB)
    return COMPOSE.get((a, b))


def nfc(s):
    d = []
    for ch in s: _decompose(ord(ch), d)
    for i in range(1, len(d)):                       # canonical ordering, stable
        c = CCC.get(d[i], 0)
        if c == 0: continue
        j = i
        while j > 0 and CCC.get(d[j - 1], 0) > c:
            d[j - 1], d[j] = d[j], d[j - 1]; j -= 1
    if not d: return ''
    sp, sc, last, n = 0, d[0], (0 if CCC.get(d[0], 0) == 0 else 256), 1
    for i in range(1, len(d)):
        ch, cl = d[i], CCC.get(d[i], 0)
        comp = _pair(sc, ch)
        if comp is not None and (last < cl or last == 0):
            d[sp] = comp; sc = comp
        else:
            if cl == 0: sp, sc = n, ch
            last = cl; d[n] = ch; n += 1
    return ''.join(chr(c) for c in d[:n])


def first_fault(s, lf_tab_ok):
    """The first fault of the string s under TAP-11 §3.5 items 1 and 2: (reason, code point or None), or None."""
    for ch in s:                                     # items 1, third bullet: unpaired surrogates
        if 0xD800 <= ord(ch) <= 0xDFFF: return ('unpaired-surrogate', ord(ch))
    prev = None
    for ch in s:
        cp = ord(ch)
        if _in(BIDI, cp): return ('bidi-control', cp)
        if lf_tab_ok and cp in (0x0A, 0x09):
            prev = cp; continue
        if 0xFE00 <= cp <= 0xFE0F or 0xE0100 <= cp <= 0xE01EF:      # variation selectors
            ok = cp in (0xFE0E, 0xFE0F) and prev is not None and _in(EMOJI, prev) \
                and not (0xFE00 <= prev <= 0xFE0F or 0xE0100 <= prev <= 0xE01EF)
            if not ok: return ('hidden-text', cp)
        elif _in(CF, cp) or _in(CC, cp) or _in(DI, cp) or cp in (0x2028, 0x2029, 0x2800, 0x1D159):
            return ('hidden-text', cp)
        prev = cp
    if nfc(s) != s: return ('not-nfc', None)         # item 2
    return None


def found(tools):
    """The first fault of every string and member name in the covered members, in a fixed walk order. U+000A and U+0009
    are allowed in a string that is the value of a member named description, at any depth (TAP-draft-mcp-tools §3.4)."""
    out = []
    def walk(v, key):
        if isinstance(v, str):
            f = first_fault(v, key == 'description')
            if f is not None: out.append(f)
        elif isinstance(v, list):
            for x in v: walk(x, None)
        elif isinstance(v, dict):
            for k, x in v.items():
                f = first_fault(k, False)
                if f is not None: out.append(f)
                walk(x, k)
    for t in tools if isinstance(tools, list) else []:
        if not isinstance(t, dict): continue
        for f in ('name', 'title', 'description', 'inputSchema', 'outputSchema', 'annotations'):
            if f in t: walk(t[f], f)
    return out


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'hidden-text.json')
    doc = json.load(open(path, encoding='utf-8'))
    bad = 0
    for c in doc['cases']:
        got = found(json.loads(c['toolsJson']))
        want_cps = [int(m, 16) for m in re.findall(r'U\+([0-9A-F]{4,6})$', '\n'.join(c['problems']), re.M)]
        got_cps = [cp for _, cp in got if cp is not None]
        ok = (len(got) > 0) == c['refused'] and got_cps == want_cps and [r for r, _ in got] == c['reasons']
        print(('ok       ' if ok else 'MISMATCH ') + c['name'] + ('' if ok else ' got %r want %r %r' % (
            got, want_cps, c['reasons'])))
        bad += not ok
    print('%d cases, %d mismatches' % (len(doc['cases']), bad))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
