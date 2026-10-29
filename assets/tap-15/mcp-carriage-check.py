#!/usr/bin/env python3
# Rechecks mcp-carriage.json from the text of TAP-draft-mcp-tools alone: the client side of Specification §4.3 (signed
# calls over MCP), §4.2 (well-formed tool results), §4.4 (manifest text in tool definitions) and §7 (which service an MCP
# endpoint belongs to). Usage: python3 -I mcp-carriage-check.py [dir].
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


def well_formed(r, revision):
    """§4.2: a tool result that is well-formed in a revision."""
    if not isinstance(r, dict) or not isinstance(r.get('content'), list):
        return False
    if not all(isinstance(x, dict) and isinstance(x.get('type'), str) for x in r['content']):
        return False
    if 'isError' in r and not isinstance(r['isError'], bool):
        return False
    if 'structuredContent' in r and revision == '2025-11-25' and not isinstance(r['structuredContent'], dict):
        return False
    return True


def is_error_value(o):
    """§4.3: an absent isError is read as false, in the outer result and in the signed one alike."""
    return canon(o['isError']) if 'isError' in o else 'false'


def carriage(case, C, maxskew, signed):
    """Returns (outcome, reason) for one call, following §4.3 'Client'."""
    p = case['request']['params']
    revision = case.get('revision', '2025-11-25')   # the revision the client's request declares
    own = p.get('_meta', {}).get(REQ) if isinstance(p.get('_meta'), dict) else None
    rid = own.get('id') if isinstance(own, dict) else None   # the client's own id; the JSON-RPC id is not used
    method, params = p['name'], p.get('arguments', {})
    msg = case['response']
    if 'result' not in msg or not isinstance(msg['result'], dict):
        return 'transport failure', 'JSON-RPC error or no tool result'
    T = msg['result']
    e = T.get('_meta', {}).get(ENV) if isinstance(T.get('_meta'), dict) else None
    if not isinstance(e, dict) or not isinstance(e.get('sig'), str):
        return 'transport failure', 'no %s with a string sig' % ENV
    # TAP-13 §8 step 3 (own request malformed) needs a BAD_REQUEST; none of these vectors has one.
    if not valid_id(rid):
        return 'binding failure', 'the client sent no valid %s, so it has no id to bind the envelope to' % REQ
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
        for k in ('content', 'structuredContent'):
            if (k in T) != (k in body) or (k in T and canon(T[k]) != canon(body[k])):
                return 'binding failure', 'outer %s is not the signed %s' % (k, k)
        if is_error_value(T) != is_error_value(body):
            return 'binding failure', 'outer isError is not the signed isError (an absent one reads as false)'
        if revision == '2025-11-25' and 'structuredContent' in T and not isinstance(T['structuredContent'], dict):
            return 'binding failure', 'structuredContent is not an object in an exchange under 2025-11-25'
        # §6 step 7
        if not well_formed(body, revision):
            return 'binding failure', 'signed result is not a tool result'
        return 'accepted result', ''
    if T.get('isError') is not True or 'structuredContent' in T or set(T) - {'content', 'isError', '_meta', 'resultType'} \
            or canon(T.get('content')) != canon([{'type': 'text', 'text': canon(body)}]):
        return 'binding failure', 'outer result of a signed error is not isError true with the error as text'
    return 'accepted error', ''


_LABEL = r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
URL = re.compile(r"^https://((?:%s\.)*[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?)(?::([1-9][0-9]{0,4}))?"
                 r"(/(?:[A-Za-z0-9._~!$&'()*+,;=:@/-]|%%[0-9A-F]{2})*)?$" % _LABEL)


def url_ok(u):
    """TAP-11 §3.5 item 5, the grammar part: no IP host, no user name, lowercase scheme and host, a port from 1 to 65535
    other than 443, no dot segments, no query, fragment or backslash. Python has no WHATWG parser, so the round trip that
    item 5 also requires is not checked here."""
    m = URL.match(u) if isinstance(u, str) and u.isascii() and ' ' not in u else None
    if not m or len(m.group(1)) > 253:
        return False
    if m.group(2) is not None and (int(m.group(2)) > 65535 or m.group(2) == '443'):
        return False
    return not any(re.fullmatch(r'(\.|%2[eE])(\.|%2[eE])?', seg) for seg in (m.group(3) or '/').split('/'))


def usable(m):
    """§2: an mcp member that is an object with a valid endpoint and toolsSha256."""
    return isinstance(m, dict) and url_ok(m.get('endpoint')) \
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


def quote_text(text):
    """TAP-11 §3.4 item 2: a JSON string literal in which <, > and & are written as lowercase \\u escapes."""
    q = json.dumps(text, ensure_ascii=False)
    for ch in '<>&':
        q = q.replace(ch, '\\u%04x' % ord(ch))
    return q


def covered_strings(tool):
    """Every string and member name in the covered members of a tool (§3.2), at any depth."""
    out = []
    def walk(v):
        if isinstance(v, str): out.append(v)
        elif isinstance(v, list):
            for x in v: walk(x)
        elif isinstance(v, dict):
            for k, x in v.items(): out.append(k); walk(x)
    for f in ('name', 'title', 'description', 'inputSchema', 'outputSchema', 'annotations'):
        if f in tool: walk(tool[f])
    return out


def quoted(case):
    """§4.4: every piece of manifest text that occurs in the tool definition occurs only as the literal of TAP-11 §3.4
    item 2, directly after a label that names the service (its chain and on-chain name). Returns (outcome, reason)."""
    m, svc = case['method'], case['service']
    pieces = [x for x in [m.get('description')] + list(m.get('params', {}).values()) + list(m.get('returns', {}).values())
              if isinstance(x, str) and x]
    for text in covered_strings(case['tool']):
        for piece in pieces:
            q = quote_text(piece)
            plain = json.dumps(piece, ensure_ascii=False)
            if plain != q and plain in text:
                return 'does-not-conform', 'the literal of %r lacks the escapes of TAP-11 section 3.4 item 2' % piece
            rest, i = text, 0
            while True:
                i = rest.find(q)
                if i < 0: break
                label = rest[max(0, i - 160):i]
                label = label[label.rfind('. ') + 2:] if '. ' in label else label
                if svc['name'] not in label or svc['chain'] not in label:
                    return 'does-not-conform', 'the literal of %r is not directly after a label naming the service' % piece
                rest = rest[:i] + rest[i + len(q):]
            if piece in rest:
                return 'does-not-conform', '%r occurs outside the literal of TAP-11 section 3.4 item 2' % piece
    return 'conforms', ''


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
    for c in v['quotedManifestText']:
        got, why = quoted(c)
        mark = 'ok  ' if got == c['outcome'] else 'FAIL'
        bad += got != c['outcome']
        print('%s quoting   %-16s %s%s' % (mark, got, c['name'], ('  [' + why + ']') if why else ''))
    for c in v['wellFormed']:
        got = well_formed(c['result'], c['revision'])
        mark = 'ok  ' if got == c['wellFormed'] else 'FAIL'
        bad += got != c['wellFormed']
        print('%s well-formed %-5s %s' % (mark, got, c['name']))
    for c in v['isErrorEquality']:
        got = is_error_value(c['outer']) == is_error_value(c['signed'])
        mark = 'ok  ' if got == c['equal'] else 'FAIL'
        bad += got != c['equal']
        print('%s isError   %-5s %s' % (mark, got, c['name']))
    n = (len(v['carriage']) + len(v['endpointIdentity']) + len(v['quotedManifestText']) + len(v['wellFormed'])
         + len(v['isErrorEquality']))
    print('%d of %d cases as expected' % (n - bad, n))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
