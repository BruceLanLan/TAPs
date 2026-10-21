# Checks the real UniSat 1.7.22 signatures of results/unisat-1.7.22-merged-*.json on a LOCAL anvil fork of BNB Smart
# Chain, against holders of the current creation code deployed through the deterministic deployment proxy:
#   - the 8-transfer batch and the mixed batch (a test ERC-721 is put at 0x..c1 with anvil_setCode), each from the
#     freshly deployed holder (anvil snapshot / revert, since both were signed at nonce 0);
#   - EIP-1271 with the §5.1 signature (and with a byte changed, and for another digest);
#   - execute with the §5.2 signature, moving a real ERC-721 token, then the empty call signed at nonce 1;
#   - a replay of each, which must fail.
# Nothing is sent to a public network. Usage: CAST=cast ANVIL=anvil [FORK_URL=...] python3 fork_check.py
import json, subprocess, time, os, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__)); R = os.path.dirname(os.path.dirname(HERE)); RES = os.path.join(HERE, "results")
CAST = os.environ.get("CAST", "cast"); ANVIL = os.environ.get("ANVIL", "anvil")
RPC = "http://127.0.0.1:8549"; FORK = os.environ.get("FORK_URL", "https://bsc-dataseed.bnbchain.org")
FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C"
DEPLOYER = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
RELAYER = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
TOKEN = "0x00000000000000000000000000000000000000c1"
BENCH = os.path.join(R, "contracts", "out", "BenchERC721.sol", "BenchERC721.json")
def sh(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout.strip()
def rpc(m, p):
    req = urllib.request.Request(RPC, json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(), {"content-type":"application/json"})
    return json.load(urllib.request.urlopen(req)).get("result")
def cli(*a): return sh("python3", R+"/tools/cli.py", *a)
def send(to, cd):
    out = subprocess.run([CAST, "send", "-r", RPC, "--private-key", RELAYER, to, cd, "--json"], capture_output=True, text=True)
    try:
        j = json.loads(out.stdout); return j["status"] in ("0x1", 1), int(j["gasUsed"], 16)
    except Exception:
        return False, 0
def owner(nft, tid): return sh(CAST, "call", "-r", RPC, nft, "ownerOf(uint256)(address)", str(tid)).lower()
anvil = subprocess.Popen([ANVIL, "--fork-url", FORK, "--port", "8549", "--silent"])
try:
    for _ in range(90):
        if sh(CAST, "chain-id", "-r", RPC) == "56": break
        time.sleep(1)
    print("fork of chain 56 at block", sh(CAST, "block-number", "-r", RPC))
    relayer = sh(CAST, "wallet", "address", "--private-key", RELAYER)
    for a in (relayer, sh(CAST, "wallet", "address", "--private-key", DEPLOYER)):
        rpc("anvil_setCode", [a, "0x"])  # anvil's public default accounts carry EIP-7702 code on mainnet
    bench = json.load(open(BENCH))["deployedBytecode"]["object"]
    for kind in ("p2tr", "p2wpkh"):
        d = json.load(open(os.path.join(RES, f"unisat-1.7.22-merged-{kind}.json")))
        bt = json.load(open(os.path.join(RES, f"unisat-1.7.22-merged-batch-{kind}.json")))
        addr = d["accounts"][0]; ex = d["exec"]; holder = ex["holder"]
        print("==", d["atype"], "wallet", d["ext"], addr, "->", holder)
        sh(CAST, "send", "-q", "-r", RPC, "--private-key", DEPLOYER, FACTORY, cli("address", addr).splitlines()[-1])
        print(" holder code bytes:", (len(sh(CAST, "code", "-r", RPC, holder)) - 2)//2, "(address from the current build:",
              cli("address", addr).splitlines()[1].split()[-1].lower() == holder.lower(), ")")
        rpc("anvil_setBalance", [holder, "0x16345785D8A0000"])
        # batches, each from the state right after deployment
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
            print(" executeBatch %s (%d chars): %s, gasUsed %d, tokens moved %d, nonce %s" % (
                name, c["chars"], "ok" if ok else "FAILED", gas, moved, sh(CAST, "call", "-r", RPC, holder, "nonce()(uint256)")))
            print("  replay:", "rejected" if not send(holder, cd)[0] else "ACCEPTED?!")
            rpc("evm_revert", [snap])
        rpc("evm_revert", [before_mint])  # the test tokens go back to unminted for the next holder
        # EIP-1271 with the wallet's own output for the sign message
        wit = cli("witness", d["signs"]["sign"]["result"]["ok"])
        digest = "0x" + "ab"*32
        print(" isValidSignature, wallet output:", sh(CAST, "call", "-r", RPC, holder, "isValidSignature(bytes32,bytes)(bytes4)", digest, wit))
        bad = wit[:-2] + ("00" if wit[-2:] != "00" else "01")
        print(" isValidSignature, last byte altered:", sh(CAST, "call", "-r", RPC, holder, "isValidSignature(bytes32,bytes)(bytes4)", digest, bad) or "reverted/empty")
        print(" isValidSignature, other digest:", sh(CAST, "call", "-r", RPC, holder, "isValidSignature(bytes32,bytes)(bytes4)", "0x"+"cd"*32, wit) or "reverted/empty")
        # execute with the wallet's own signature: a real NFT
        nft, tid, recip = ex["nft"], ex["tokenId"], ex["recipient"]
        own = sh(CAST, "call", "-r", RPC, nft, "ownerOf(uint256)(address)", str(tid))
        rpc("anvil_impersonateAccount", [own]); rpc("anvil_setBalance", [own, "0x8AC7230489E80000"])
        sh(CAST, "send", "-q", "-r", RPC, "--unlocked", "--from", own, nft, "safeTransferFrom(address,address,uint256)", own, holder, str(tid))
        print(" ownerOf before:", owner(nft, tid), "(holder)")
        cd = cli("execute-calldata", nft, "0", ex["data"], str(ex["callGas"]), str(ex["tip"]), str(ex["deadline"]),
                 cli("witness", d["signs"]["exec"]["result"]["ok"]))
        ok, gas = send(holder, cd)
        print(" execute:", "ok" if ok else "FAILED", "gasUsed", gas, "; ownerOf after:", owner(nft, tid), "expected", recip.lower())
        print("  replay:", "rejected" if not send(holder, cd)[0] else "ACCEPTED?!")
        # the empty call signed at nonce 1
        m = d["signs"]["call"]["message"]
        target = m.split(" calls ")[1].split()[0]; dl = m.rsplit(" ", 1)[1]
        cd = cli("execute-calldata", target, "0", "0x", "0", "0", dl, cli("witness", d["signs"]["call"]["result"]["ok"]))
        ok, gas = send(holder, cd)
        print(" execute (empty call, nonce 1):", "ok" if ok else "FAILED", "gasUsed", gas, "; nonce now", sh(CAST, "call", "-r", RPC, holder, "nonce()(uint256)"))
        print("  replay:", "rejected" if not send(holder, cd)[0] else "ACCEPTED?!")
finally:
    anvil.terminate()
