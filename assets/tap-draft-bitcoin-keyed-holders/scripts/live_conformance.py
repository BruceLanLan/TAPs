# SPDX-License-Identifier: MIT
# -*- coding: utf-8 -*-
# Read-only live check: inject the holder's runtime code at its predicted address via eth_call state
# override on each public RPC, and ask isValidSignature for the chain-specific vectors. No transaction.
import json, subprocess, sys, time, urllib.request, os
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
v = json.load(open(f'{REPO}/vectors/vectors.json'))
creation = open(f'{REPO}/vectors/creation-code.hex').read().strip().removeprefix('0x')
FACTORY = '0x4e59b44847b379578588920cA78FbF26c0B4956C'
PROXY = '7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3'
def rpc(url, method, params, timeout=40):
    req = urllib.request.Request(url, json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode(), {'content-type':'application/json','user-agent':'curl/8.0'})
    return json.load(urllib.request.urlopen(req, timeout=timeout))
# 1. local anvil: deploy both holders, read runtime code
anvil = subprocess.Popen([os.path.expanduser('~/.foundry/bin/anvil'), '--port', '8599', '--silent'])
print('anvil pid', anvil.pid)
try:
    L = 'http://127.0.0.1:8599'
    for _ in range(60):
        try: rpc(L, 'eth_chainId', []); break
        except Exception: time.sleep(0.5)
    rpc(L, 'anvil_setCode', [FACTORY, '0x'+PROXY])
    acct = rpc(L, 'eth_accounts', [])['result'][0]
    runtime = {}
    for kind in ('p2tr', 'p2wpkh'):
        h = v['holders'][kind]; spk = h['scriptPubKey'].removeprefix('0x')
        L_ = len(spk)//2; pad = spk + '00'*((32 - L_ % 32) % 32)
        init = creation + '%064x' % 32 + '%064x' % L_ + pad
        txh = rpc(L, 'eth_sendTransaction', [{'from': acct, 'to': FACTORY, 'data': '0x' + '00'*32 + init, 'gas': '0x400000'}])['result']
        for _ in range(50):
            r = rpc(L, 'eth_getTransactionReceipt', [txh])['result']
            if r: break
            time.sleep(0.2)
        assert r['status'] == '0x1', r
        code = rpc(L, 'eth_getCode', [h['holder'], 'latest'])['result']
        assert len(code) > 100, 'no code'
        runtime[kind] = code
        print(kind, h['holder'], 'runtime bytes', len(code)//2 - 1)
finally:
    anvil.terminate(); anvil.wait()
    print('anvil stopped')
# 2. live eth_call with state override
SEL = '1626ba7e'
def enc_call(digest, sig):
    s = sig.removeprefix('0x'); n = len(s)//2
    return '0x' + SEL + digest.removeprefix('0x') + '%064x' % 0x40 + '%064x' % n + s + '00'*((32 - n % 32) % 32)
chains = {56: 'https://bsc-dataseed.bnbchain.org', 8453: 'https://mainnet.base.org', 196: 'https://xlayerrpc.okx.com'}
for cid, url in chains.items():
    assert int(rpc(url, 'eth_chainId', [])['result'], 16) == cid
    for c in v['signCases']:
        if c['chainId'] != cid: continue
        h = v['holders'][c['holder']]
        res = rpc(url, 'eth_call', [{'to': h['holder'], 'data': enc_call(c['digest'], c['signature'])}, 'latest', {h['holder']: {'code': runtime[c['holder']]}}])
        got = res.get('result', res.get('error'))
        ok = isinstance(got, str) and got[2:10] == SEL
        print(f'chain {cid} {c["name"]:28s} expect={c["expect"]} got={"magic" if ok else got} {"OK" if ok == c["expect"] else "MISMATCH"}')
    # negative: a chain-56 signature on the other chains
    c = v['signCases'][0]
    if cid != 56:
        h = v['holders'][c['holder']]
        res = rpc(url, 'eth_call', [{'to': h['holder'], 'data': enc_call(c['digest'], c['signature'])}, 'latest', {h['holder']: {'code': runtime[c['holder']]}}])
        print(f'chain {cid} {"p2tr-56 replayed":28s} expect=False got={res.get("result", res.get("error"))}')
