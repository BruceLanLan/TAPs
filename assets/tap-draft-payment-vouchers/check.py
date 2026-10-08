# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Bruce (@BruceLanLan)
#
# Independent check of the arithmetic in the vectors of TAP-draft-payment-vouchers, written from the draft's text
# with the Python standard library only (Python 3.8+): run  python3 check.py  in this directory.
# It recomputes the conversions (§4.3) with decimal arithmetic, the mean ticks and reference rates (§4.5), the
# quote checks, the quote time rules (§4.4) and the charge records (§7) of envelopes.json, and the canonical bodies.
# It does not recompute Keccak-256 or secp256k1 (not in the standard library); gen.mjs does those.
import json, os, re, sys
from decimal import Decimal as D, getcontext, ROUND_CEILING

getcontext().prec = 200
here = os.path.dirname(os.path.abspath(__file__))
load = lambda n: json.load(open(os.path.join(here, n), encoding='utf-8'))
bad = []
def expect(cond, what):
    if not cond: bad.append(what)

PRICE = re.compile(r'^[0-9]+(\.[0-9]{1,8})?$'); RATE = re.compile(r'^[0-9]+(\.[0-9]{1,18})?$')
def charge(p, r, c):
    if not PRICE.match(p) or D(p) == 0: return {'error': 'priceUSD'}
    if not RATE.match(r) or D(r) == 0: return {'error': 'rate'}
    if not PRICE.match(c) or D(c) == 0: return {'error': 'priceBEM'}
    conv = int((D(p) / D(r) * D(10) ** 8).to_integral_value(rounding=ROUND_CEILING))
    cap = int(D(c) * D(10) ** 8)
    return {'converted': conv, 'charge': min(conv, cap), 'capped': conv > cap}

conv = load('conversion.json')
for x in conv['cases']:
    c = charge(x['priceUSD'], x['rate'], x['priceBEM'])
    expect(c['converted'] == int(x['converted']) and c['charge'] == int(x['charge']) and c['capped'] == x['capped'], 'conversion ' + x['name'])
    expect(D(x['bem']['amount']) * D(10) ** 8 == D(x['charge']) and len(x['bem']['amount'].split('.')[1]) == 8, 'amount form ' + x['name'])
for x in conv['invalid']:
    expect(charge(x['priceUSD'], x['rate'], x['priceBEM']).get('error') == x['refused'], 'invalid ' + x['name'])

rs = load('rate-source.json')
def mean_tick(c, w): return (int(c[1]) - int(c[0])) // w  # Python // rounds toward negative infinity
def ref(t, bem0, du):
    p = D('1.0001') ** t
    return p * D(10) ** (8 - du) if bem0 else 1 / (p * D(10) ** (du - 8))
rates = []
for s in rs['constructed']:
    t = mean_tick(s['tickCumulatives'], s['window'])
    expect(t == int(s['meanTick']), 'meanTick ' + s['name'])
    r = ref(t, s['bemIsToken0'], s['usdDecimals'])
    expect(abs(r - D(repr(s['rate']))) / r < D('1e-9'), 'rate ' + s['name'])
    rates.append(r)
m = (rates[0] + rates[1]) / 2
expect(abs(m - D(repr(rs['referenceOfFirstTwo']))) / m < D('1e-9'), 'median')
for x in rs['checks']:
    expect((D(x['rate']) * 10000 >= m * (10000 - x['toleranceBps'])) == x['accepted'], 'check ' + x['name'] + ' @' + str(x['toleranceBps']))
for x in rs['recordedReads']['reads']:
    expect(mean_tick(x['tickCumulatives'], x['window']) == int(x['meanTick']), 'recorded ' + x['pool'])

env = load('envelopes.json'); up = env['manifestExcerpt']['usdPricing']; cap = env['manifestExcerpt']['methods'][0]['priceBEM']
for e in env['cases']:
    expect(e['canonicalBody'] == json.dumps(e['body'], sort_keys=True, separators=(',', ':'), ensure_ascii=False), 'canonical ' + e['name'])
    data = e['body']['data'] if not e['ok'] else e['body']['charge']
    q = data.get('quote')
    if q:
        expect(q['asOf'] <= e['ts'] < q['validUntil'] + 1 and q['validUntil'] <= q['asOf'] + up['maxQuoteS'] and q['asOf'] < q['validUntil'], 'quote times ' + e['name'])
    if e['ok']:
        ch = data; c = charge(up['methods']['search'], ch['rate'], cap)
        expect(D(ch['amount']['amount']) * D(10) ** 8 == c['charge'] and ('capped' in ch) == c['capped'], 'charge record ' + e['name'])
    else:
        expect(int(data['price']) == charge(up['methods']['search'], q['rate'], cap)['charge'], 'price ' + e['name'])

print('mismatches: %d' % len(bad))
for b in bad: print('  ' + b)
sys.exit(1 if bad else 0)
