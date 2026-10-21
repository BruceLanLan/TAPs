# Checks the real wallet signatures of results/<wallet>/*.json on a LOCAL anvil fork of BNB Smart Chain, against
# holders of the TAP repository's current creation code, deployed through the deterministic deployment proxy
# (adapted from interop/unisat-extension/fork_check.py of the TAP repository). For each wallet and address type,
# from the state right after deployment (anvil snapshot / revert, since every wallet signed at nonce 0):
#   - executeBatch with the 8-transfer and the mixed batch (a test ERC-721 is put at 0x..c1 with anvil_setCode);
#   - EIP-1271 isValidSignature with the §5.1 signature (and with a byte changed, and for another digest);
#   - execute with the §5.2 signature, moving the real ERC-721 0x1f5c..f12c #920, then the empty call at nonce 1;
#   - a replay of each, which must fail.
# Nothing is sent to a public network: the fork is local, the deployer and relayer are anvil's public test keys.
# usage: LAB=<TAP repository> CAST=cast ANVIL=anvil [FORK_URL=...] [PORT=18549] python3 fork_check.py <results dir> <wallet>...
import json
import os
import subprocess
import sys
import time
import urllib.request

LAB = os.environ["LAB"]
RES = sys.argv[1]
WALLETS = sys.argv[2:]
CAST = os.environ.get("CAST", "cast")
ANVIL = os.environ.get("ANVIL", "anvil")
PORT = os.environ.get("PORT", "18549")
RPC = "http://127.0.0.1:" + PORT
FORK = os.environ.get("FORK_URL", "https://bsc-mainnet.public.blastapi.io")
FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C"
DEPLOYER = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"   # anvil test key 0
RELAYER = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"    # anvil test key 2
TOKEN = "0x00000000000000000000000000000000000000c1"
BENCH = os.path.join(LAB, "contracts", "out", "BenchERC721.sol", "BenchERC721.json")
OUT = {"forkUrl": FORK, "wallets": {}}


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout.strip()


def rpc(m, p):
    req = urllib.request.Request(RPC, json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode(),
                                 {"content-type": "application/json"})
    return json.load(urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req)).get("result")


def cli(*a):
    return sh("python3", LAB + "/tools/cli.py", *a)


def send(to, cd):
    out = subprocess.run([CAST, "send", "-r", RPC, "--private-key", RELAYER, to, cd, "--json"], capture_output=True, text=True)
    try:
        j = json.loads(out.stdout)
        return j["status"] in ("0x1", 1), int(j["gasUsed"], 16)
    except Exception:
        return False, 0


def owner(nft, tid):
    return sh(CAST, "call", "-r", RPC, nft, "ownerOf(uint256)(address)", str(tid)).lower()


def say(rec, key, val, text):
    rec[key] = val
    print(text)


env = dict(os.environ, NO_PROXY="127.0.0.1,localhost")
anvil = subprocess.Popen([ANVIL, "--fork-url", FORK, "--port", PORT, "--silent"], env=env)
try:
    for _ in range(120):
        if sh(CAST, "chain-id", "-r", RPC) == "56":
            break
        time.sleep(1)
    OUT["forkBlock"] = sh(CAST, "block-number", "-r", RPC)
    print("fork of chain 56 at block", OUT["forkBlock"])
    relayer = sh(CAST, "wallet", "address", "--private-key", RELAYER)
    for a in (relayer, sh(CAST, "wallet", "address", "--private-key", DEPLOYER)):
        rpc("anvil_setCode", [a, "0x"])  # anvil's public default accounts carry EIP-7702 code on mainnet
    bench = json.load(open(BENCH))["deployedBytecode"]["object"]
    for kind in ("p2tr", "p2wpkh"):
        base = rpc("evm_snapshot", [])
        deployed = None
        for w in WALLETS:
            single = [f for f in os.listdir(os.path.join(RES, w)) if f.endswith("-%s.json" % kind) and "-batch-" not in f]
            if not single:
                continue
            d = json.load(open(os.path.join(RES, w, single[0])))
            bt = json.load(open(os.path.join(RES, w, single[0].replace("-" + kind, "-batch-" + kind))))
            addr = d["accounts"][0]
            ex = d["exec"]
            holder = ex["holder"]
            rec = OUT["wallets"].setdefault("%s-%s" % (w, d["ext"]), {}).setdefault(kind, {"address": addr, "holder": holder})
            print("==", w, d["ext"], kind, addr, "->", holder)
            rpc("evm_revert", [base])
            base = rpc("evm_snapshot", [])
            sh(CAST, "send", "-q", "-r", RPC, "--private-key", DEPLOYER, FACTORY, cli("address", addr).splitlines()[-1])
            say(rec, "holderCodeBytes", (len(sh(CAST, "code", "-r", RPC, holder)) - 2) // 2, " holder code bytes: %d" % ((len(sh(CAST, "code", "-r", RPC, holder)) - 2) // 2))
            rpc("anvil_setBalance", [holder, "0x16345785D8A0000"])
            rpc("anvil_setCode", [TOKEN, bench])
            before_mint = rpc("evm_snapshot", [])
            for i in range(1, 9):
                sh(CAST, "send", "-q", "-r", RPC, "--private-key", DEPLOYER, TOKEN, "mint(address,uint256)", holder, str(i))
            for name in ("transfers-8", "mixed-3"):
                snap = rpc("evm_snapshot", [])
                c = bt["cases"][name]
                calls = ["%s,%s,%s,%s" % (k["target"], int(k["value"]), k["data"], int(k["callGas"])) for k in c["calls"]]
                wit = cli("witness", c["result"]["ok"])
                cd = cli("execute-batch-calldata", str(int(c["tip"])), str(int(c["deadline"])), wit, *calls)
                ok, gas = send(holder, cd)
                moved = sum(owner(TOKEN, i) == "0x00000000000000000000000000000000000000b0" for i in range(1, 9))
                rep = not send(holder, cd)[0]
                rec[name] = {"ok": ok, "gasUsed": gas, "tokensMoved": moved, "replayRejected": rep}
                print(" executeBatch %s (%d chars): %s, gasUsed %d, tokens moved %d; replay %s" % (
                    name, c["chars"], "ok" if ok else "FAILED", gas, moved, "rejected" if rep else "ACCEPTED?!"))
                rpc("evm_revert", [snap])
            rpc("evm_revert", [before_mint])
            wit = cli("witness", d["signs"]["sign"]["result"]["ok"])
            digest = "0x" + "ab" * 32
            r1 = sh(CAST, "call", "-r", RPC, holder, "isValidSignature(bytes32,bytes)(bytes4)", digest, wit)
            bad = wit[:-2] + ("00" if wit[-2:] != "00" else "01")
            r2 = sh(CAST, "call", "-r", RPC, holder, "isValidSignature(bytes32,bytes)(bytes4)", digest, bad) or "reverted/empty"
            r3 = sh(CAST, "call", "-r", RPC, holder, "isValidSignature(bytes32,bytes)(bytes4)", "0x" + "cd" * 32, wit) or "reverted/empty"
            rec["isValidSignature"] = {"walletOutput": r1, "lastByteAltered": r2, "otherDigest": r3}
            print(" isValidSignature: wallet output %s, last byte altered %s, other digest %s" % (r1, r2, r3))
            nft, tid, recip = ex["nft"], ex["tokenId"], ex["recipient"]
            own = sh(CAST, "call", "-r", RPC, nft, "ownerOf(uint256)(address)", str(tid))
            rpc("anvil_impersonateAccount", [own])
            rpc("anvil_setBalance", [own, "0x8AC7230489E80000"])
            sh(CAST, "send", "-q", "-r", RPC, "--unlocked", "--from", own, nft, "safeTransferFrom(address,address,uint256)", own, holder, str(tid))
            ob = owner(nft, tid)
            cd = cli("execute-calldata", nft, "0", ex["data"], str(ex["callGas"]), str(ex["tip"]), str(ex["deadline"]),
                     cli("witness", d["signs"]["exec"]["result"]["ok"]))
            ok, gas = send(holder, cd)
            oa = owner(nft, tid)
            rep = not send(holder, cd)[0]
            rec["execute"] = {"nft": nft, "tokenId": tid, "ownerBefore": ob, "ok": ok, "gasUsed": gas, "ownerAfter": oa,
                              "expected": recip.lower(), "replayRejected": rep}
            print(" execute NFT #%s: owner before %s, %s gasUsed %d, owner after %s (expected %s); replay %s" % (
                tid, ob, "ok" if ok else "FAILED", gas, oa, recip.lower(), "rejected" if rep else "ACCEPTED?!"))
            m = d["signs"]["call"]["message"]
            target = m.split(" calls ")[1].split()[0]
            dl = m.rsplit(" ", 1)[1]
            cd = cli("execute-calldata", target, "0", "0x", "0", "0", dl, cli("witness", d["signs"]["call"]["result"]["ok"]))
            ok, gas = send(holder, cd)
            n = sh(CAST, "call", "-r", RPC, holder, "nonce()(uint256)")
            rep = not send(holder, cd)[0]
            rec["emptyCallNonce1"] = {"ok": ok, "gasUsed": gas, "nonceAfter": n, "replayRejected": rep}
            print(" execute empty call (nonce 1): %s gasUsed %d, nonce now %s; replay %s" % (
                "ok" if ok else "FAILED", gas, n, "rejected" if rep else "ACCEPTED?!"))
        rpc("evm_revert", [base])
finally:
    anvil.terminate()
    anvil.wait()
json.dump(OUT, open(os.path.join(RES, "fork-check.json"), "w"), indent=1)
