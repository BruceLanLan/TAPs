#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Recomputes the expected R, state and problems of thread-revocation-vectors.json from TAP-draft-container-agent
# sections 7.4 to 7.6 alone (no reference implementation). The cases are abstract: every message is valid and signed
# unless the case says otherwise, so only the rules about order, times and revocation are exercised.
#   case members: offer {exp, deadline}; accept {ts, exp}; mandate {notBefore, expires, refused}; deliveries [{ts, exp}];
#   verdict {of, issued, verdict} (judges delivery number `of`); revocations [{issued, hashes, revokedBefore}] where
#   hashes lists "mandate" when the revocation names the thread's mandate; site: the covering-or-not revocation in the
#   principal's site file, read while checking the mandate (null: none published); messages: the order presented,
#   "deliver:<i>" and "revocation:<i>" naming items of those lists; at.
# Problem order is not fixed by the draft, so problems are compared as multisets.
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
T = json.load(open(os.path.join(HERE, 'thread-revocation-vectors.json')))

def covers(rev, mandate):                         # section 3.5
    return 'mandate' in rev['hashes'] or mandate['notBefore'] < rev['revokedBefore']

def one_pass(c, R):
    """Section 7.4: the messages other than `revocation`, in the order presented; R = None means no
    message-after-revocation checks (the first pass of 7.5)."""
    problems, state = [], None
    applied_mandate, site_rev, accept_ts, last = False, None, None, None
    after = lambda ts: R is not None and ts > R
    for m in c['messages']:
        kind, _, idx = m.partition(':')
        if kind == 'revocation':
            continue                               # considered apart (7.5)
        if kind == 'offer':
            if state is not None: problems.append('out-of-order'); continue
            state = 'Offered'
        elif kind == 'accept':
            if state != 'Offered': problems.append('out-of-order'); continue
            a = c['accept']
            if a['ts'] > c['offer']['exp']: problems.append('offer-expired'); continue
            if after(a['ts']): problems.append('message-after-revocation'); continue
            accept_ts, state = a['ts'], 'Accepted'
        elif kind == 'mandate':
            if state != 'Accepted': problems.append('out-of-order'); continue
            md = c['mandate']
            # every problem refuses it except mandate-not-yet, mandate-expired and mandate-revoked (not reported)
            if md['refused']: problems.append(md['refused']); continue
            applied_mandate, state = True, 'Active'
            if c['site'] is not None and covers(c['site'], md): site_rev = c['site']['issued']
        elif kind == 'deliver':
            if state not in ('Active', 'Rejected'): problems.append('out-of-order'); continue
            d, md = c['deliveries'][int(idx)], c['mandate']
            if after(d['ts']): problems.append('message-after-revocation'); continue
            if not (md['notBefore'] <= d['ts'] <= md['expires']): problems.append('deliver-outside-mandate'); continue
            if d['exp'] < d['ts']: problems.append('message-malformed'); continue
            if d['ts'] < accept_ts: problems.append('deliver-before-accept'); continue
            if d['ts'] > c['offer']['deadline']: problems.append('deliver-after-deadline')   # reported, applied
            last, state = int(idx), 'Delivered'
        elif kind == 'acceptance':
            if state != 'Delivered': problems.append('out-of-order'); continue
            v = c['verdict']
            if v['of'] != last: problems.append('verdict-mismatch'); continue
            if v['issued'] < c['deliveries'][last]['ts']: problems.append('verdict-before-delivery'); continue
            state = 'Settled' if v['verdict'] == 1 else 'Rejected'
    return {'problems': problems, 'state': state, 'mandate': applied_mandate, 'site': site_rev, 'last': last}

def thread(c):
    first = one_pass(c, None)
    times, rev_problems = [], []
    if first['site'] is not None: times.append((first['site'], 'site'))
    for m in c['messages']:
        kind, _, idx = m.partition(':')
        if kind != 'revocation': continue
        if first['state'] is None: rev_problems.append('out-of-order'); continue   # no offer applied
        r = c['revocations'][int(idx)]
        applies = covers(r, c['mandate']) if first['mandate'] else r['revokedBefore'] > 0
        if not applies: rev_problems.append('revocation-mismatch'); continue
        times.append((r['issued'], 'message'))
    R, via = (min(times, key=lambda t: t[0]) if times else (None, None))
    second = one_pass(c, R) if R is not None else first
    state, at = second['state'], c['at']
    # 7.6, in this order
    if state in ('Offered', 'Accepted', 'Active') and R is not None and R <= at: state = 'Cancelled'
    elif state == 'Offered' and at > c['offer']['exp']: state = 'Expired'
    elif state == 'Accepted' and at > c['accept']['exp']: state = 'Expired'
    elif state == 'Active' and at > c['mandate']['expires']: state = 'Expired'
    return {'R': R, 'via': via, 'state': state, 'problems': second['problems'] + rev_problems}

fails = 0
for i, c in enumerate(T['cases']):
    got, want = thread(c), c['expect']
    ok = got['R'] == want['R'] and got['via'] == want['via'] and got['state'] == want['state'] and sorted(got['problems']) == sorted(want['problems'])
    if not ok: fails += 1
    print(('ok   ' if ok else 'FAIL ') + f'thread case {i}: {c["name"]}' + ('' if ok else f'\n     got  {got}\n     want {want}'))
# cases the vectors say give the same result (a revocation as a message or from the site file)
for a, b in T.get('sameResult', []):
    ra, rb = thread(T['cases'][a]), thread(T['cases'][b])
    same = ra['state'] == rb['state'] and ra['R'] == rb['R'] and sorted(ra['problems']) == sorted(rb['problems'])
    if not same: fails += 1
    print(('ok   ' if same else 'FAIL ') + f'cases {a} and {b} give the same R, state and problems')
print('\n%s: %d failure(s)' % ('thread checks passed' if not fails else 'thread checks FAILED', fails))
sys.exit(1 if fails else 0)
