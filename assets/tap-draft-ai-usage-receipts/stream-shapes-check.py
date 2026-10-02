#!/usr/bin/env python3
# Rechecks stream-shapes.json from the text of TAP-draft-ai-usage-receipts alone (Specification §5.2, §6.1 and §9.3
# item 8): a whole-text event-stream parser on bytes, written independently of the reference implementation.
# Usage: python3 stream-shapes-check.py [stream-shapes.json]. Prints one line per case and exits 1 on any mismatch.
# MIT License.
import base64, hashlib, json, os, sys

BOM = b'\xef\xbb\xbf'
SENTINEL = {'openai-chat': b'[DONE]', 'openai-responses': b'[DONE]', 'anthropic-messages': None}
# §6.1: event names of `event:` final lines, and data values of `data:` final lines.
FINAL_EVENTS = {'openai-chat': set(), 'openai-responses': {b'response.completed', b'response.incomplete', b'response.failed'},
                'anthropic-messages': {b'message_stop'}}
FINAL_DATA = {'openai-chat': {b'[DONE]'}, 'openai-responses': {b'[DONE]'}, 'anthropic-messages': set()}


def shapes(body, fmt):
    sentinel = SENTINEL[fmt]
    pos = 3 if body.startswith(BOM) else 0          # §5.2 rule 1: one U+FEFF at the very start is skipped
    hashed = []                                       # data values hashed, in order
    end = None                                        # (offset, events hashed at the end)
    amb_before = amb_after = 0
    data, name, fields = None, b'', False             # the event being read
    while True:
        # the next line end: CR LF, LF or CR
        cr, lf = body.find(b'\r', pos), body.find(b'\n', pos)
        ends = [x for x in (cr, lf) if x >= 0]
        if not ends:
            partial = pos < len(body)                 # bytes after the last line end: a line not finished
            break
        j = min(ends)
        line = body[pos:j]
        nxt = j + 2 if body[j:j + 2] == b'\r\n' else j + 1
        pos = nxt
        if line.startswith(BOM):                      # §5.2: an ambiguous line
            if end is None: amb_before += 1
            else: amb_after += 1
        if line == b'':                               # rule 4, 5: dispatch at an empty line, if it had data
            if data is not None:
                d = b'\n'.join(data)
                if not (sentinel is not None and d == sentinel):
                    hashed.append(d)
                if end is None and (name in FINAL_EVENTS[fmt] or d in FINAL_DATA[fmt] or (sentinel is not None and d == sentinel)):
                    end = (nxt, len(hashed))           # §6.1: the end, just after this empty line
            data, name, fields = None, b'', False
            continue
        if line.startswith(b':'):                     # rule 2: a comment
            continue
        fields = True                                 # rule 3: a field line
        k = line.find(b':')
        field, value = (line, b'') if k < 0 else (line[:k], line[k + 1:])
        if value.startswith(b' '):
            value = value[1:]
        if field == b'data':
            data = (data or []) + [value]
        elif field == b'event':
            name = value
    unfinished = partial or fields or data is not None    # §5.2: the bytes close while an event is unfinished
    digest = lambda ds: hashlib.sha256(b''.join(d + b'\n' for d in ds)).hexdigest()
    n_end = end[1] if end else len(hashed)
    covered_fail = amb_before > 0 or (end is None and unfinished)
    after_fail = end is not None and (len(hashed) - n_end > 0 or amb_after > 0 or unfinished)
    return {
        'end': end[0] if end else None,
        'eventsAtEnd': n_end,
        'responseSha256': digest(hashed[:n_end]),
        'wholeStreamSha256': digest(hashed),
        'eventsAfterEnd': len(hashed) - n_end,
        'ambiguousLinesBeforeEnd': amb_before,
        'ambiguousLinesAfterEnd': amb_after,
        'unfinishedAtClose': unfinished,
        'item8': {'stopsAtEnd': 'fail' if covered_fail else 'pass',
                  'passesEverythingOn': 'fail' if covered_fail or after_fail else 'pass'},
    }


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'stream-shapes.json')
    doc = json.load(open(path, encoding='utf-8'))
    bad = 0
    for c in doc['cases']:
        body = base64.b64decode(c['streamBase64'])
        if body != c['streamText'].encode('utf-8'):
            print('MISMATCH streamText', c['name']); bad += 1
        got = shapes(body, c['format'])
        diff = [k for k in got if got[k] != c[k]]
        print(('ok      ' if not diff else 'MISMATCH ') + c['format'] + ': ' + c['name'] + ('' if not diff else ' ' + repr(diff)))
        bad += bool(diff)
    print('%d cases, %d mismatches' % (len(doc['cases']), bad))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
