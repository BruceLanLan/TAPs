#!/usr/bin/env python3
# Rechecks mcp-carriage.json from the text of TAP-draft-mcp-tools alone: the client side of Specification §4.3 (signed
# calls over MCP) and §7 (which service an MCP endpoint belongs to). Usage: python3 mcp-carriage-check.py [dir].
# Exits 1 on any mismatch. Standard library only. MIT License.
#
# Python's standard library has neither Keccak-256 nor secp256k1, so this script does not recompute signatures. It
# accepts a signature only when every input of the TAP-13 §5 digest that it computes from the client's own values (id,
# request object, ok, canonical body, ts, container) is byte-equal to those of a case of envelopes.json, whose digest,
# signature and recovered signer are given there and were recomputed independently; any other input gives another
# digest, so the signature is treated as not verifying. The canonical form below covers the values of these vectors
# (integers, strings, booleans, null, arrays, objects); it is not a complete implementation of TAP-11 §6.
import json, os, re, sys

D = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
REQ, ENV = 'fun.tapeapi/request', 'fun.tapeapi/envelope'


def canon(v):
    if isinstance(v, dict):
        keys = sorted(v, key=lambda k: k.encode('utf-16-be'))
        return '{' + ','.join(json.dumps(k, ensure_ascii=False) + ':' + canon(v[k]) for k in keys) + '}'
    if isinstance(v, list):
        return '[' + ','.join(canon(x) for x in v) + ']'
    if isinstance(v, bool) or v is None:
        return json.dumps(v)
    if isinstance(v, int):
        if abs(v) > 2 ** 53 - 1:
            raise ValueError('integer out of range')
        return str(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    raise ValueError('value outside the scope of this script')


def valid_id(i):
    return isinstance(i, str) and 1 <= len(i.encode('utf-16-le')) // 2 <= 128


def carriage(case, C, maxskew, signed):
    """Returns (outcome, reason) for one call, following §4.3 'Client'."""
    p = case['request']['params']
    rid = p['_meta'][REQ]['id']                      # the client's own id; the JSON-RPC id is not used
    method, params = p['name'], p.get('arguments', {})
    msg = case['response']
    if 'result' not in msg or not isinstance(msg['result'], dict):
        return 'transport failure', 'JSON-RPC error or no tool result'
    T = msg['result']
    e = T.get('_meta', {}).get(ENV) if isinstance(T.get('_meta'), dict) else None
    if not isinstance(e, dict) or not isinstance(e.get('sig'), str):
        return 'transport failure', 'no %s with a string sig' % ENV
    # TAP-13 §8 step 3 (own request malformed) needs a BAD_REQUEST; none of these vectors has one.
    ok = e.get('ok')
    if e.get('id') != rid:
        return 'binding failure', 'envelope id %r is not the id the client chose (%r)' % (e.get('id'), rid)
    if not isinstance(ok, bool) or ('result' in e) != ok or ('error' in e) == ok:
        return 'binding failure', 'ok, result and error do not agree'
    if not isinstance(e.get('container'), str) or e['container'].lower() != C.lower():
        return 'binding failure', 'container is not the resolved container'
    ts = e.get('ts')
    if not isinstance(ts, int) or isinstance(ts, bool) or not 0 <= ts <= 2 ** 53 - 1:
        return 'binding failure', 'ts out of range'
    if abs(case['now'] - ts) > maxskew:
        return 'binding failure', 'ts is more than maxSkew from the client clock'
    body = e['result'] if ok else e['error']
    inputs = (rid, canon({'method': method, 'params': params}), ok, canon(body), ts, C.lower(), e['sig'])
    if inputs not in signed:
        return 'binding failure', 'signature does not verify for the client\'s own id, method and params'
    # §4.3: the outer tool result is the signed one; resultType (revision 2026-07-28) is unsigned and must be "complete"
    if 'resultType' in T and T['resultType'] != 'complete':
        return 'binding failure', 'resultType is not "complete"'
    if ok:
        if set(T) - {'content', 'structuredContent', 'isError', '_meta', 'resultType'}:
            return 'binding failure', 'tool result has members the signed result does not'
        for k in ('content', 'structuredContent', 'isError'):
            if (k in T) != (k in body) or (k in T and canon(T[k]) != canon(body[k])):
                return 'binding failure', 'outer %s is not the signed %s' % (k, k)
        # §6 step 7
        c = body.get('content') if isinstance(body, dict) else None
        if not isinstance(c, list) or not all(isinstance(x, dict) and isinstance(x.get('type'), str) for x in c) \
                or ('isError' in body and not isinstance(body['isError'], bool)):
            return 'binding failure', 'signed result is not a tool result'
        return 'accepted result', ''
    if T.get('isError') is not True or 'structuredContent' in T or set(T) - {'content', 'isError', '_meta', 'resultType'} \
            or canon(T.get('content')) != canon([{'type': 'text', 'text': canon(body)}]):
        return 'binding failure', 'outer result of a signed error is not isError true with the error as text'
    return 'accepted error', ''


URL = re.compile(r'^https://[^/?#@\s]+(/[^?#\s]*)?$')


def usable(m):
    """§2: an mcp member that is an object with a valid endpoint and toolsSha256."""
    return isinstance(m, dict) and isinstance(m.get('endpoint'), str) and bool(URL.match(m['endpoint'])) \
        and isinstance(m.get('toolsSha256'), str) and bool(re.fullmatch(r'[0-9a-f]{64}', m['toolsSha256']))


def identity(case):
    """§7: serverInfoName is deliberately not read."""
    r = case['resolution']
    if r['outcome'] != 'resolved':
        return r['outcome']
    m = r['manifest'].get('mcp')
    if not usable(m):
        return 'no-mcp'
    return 'endpoint-bound' if case['url'] == m['endpoint'] else 'endpoint-not-listed'


def main():
    v = json.load(open(os.path.join(D, 'mcp-carriage.json'), encoding='utf-8'))
    ref = json.load(open(os.path.join(D, 'envelopes.json'), encoding='utf-8'))
    signed = set()
    for c in ref['cases']:                           # digest inputs whose signature envelopes.json gives
        e = c['envelope']
        assert c['canonicalRequest'] == canon({'method': c['method'], 'params': c['params']})
        assert c['canonicalBody'] == canon(e['result'] if e['ok'] else e['error'])
        assert c['recovered'] == ref['signerAddress']
        signed.add((c['id'], c['canonicalRequest'], e['ok'], c['canonicalBody'], e['ts'], ref['container'].lower(), e['sig']))
    bad = 0
    for c in v['carriage']:
        got, why = carriage(c, v['container'], v['maxSkew'], signed)
        mark = 'ok  ' if got == c['outcome'] else 'FAIL'
        bad += got != c['outcome']
        print('%s carriage  %-17s %s%s' % (mark, got, c['name'], ('  [' + why + ']') if why else ''))
    for c in v['endpointIdentity']:
        got = identity(c)
        mark = 'ok  ' if got == c['outcome'] else 'FAIL'
        bad += got != c['outcome']
        print('%s identity  %-19s %s' % (mark, got, c['name']))
    n = len(v['carriage']) + len(v['endpointIdentity'])
    print('%d of %d cases as expected' % (n - bad, n))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
