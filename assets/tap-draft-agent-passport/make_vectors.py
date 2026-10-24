# make_vectors.py: writes vectors.json for TAP-draft-agent-passport (deterministic). MIT License.
#   python3 make_vectors.py           write vectors.json
#   python3 make_vectors.py --check   compare with the file on disk, write nothing
#
# Every case carries a hand-written expectation; the generator also runs the reference verifier and
# stops if the two differ, so the file cannot drift from the rules silently.
# Chain state in "synthetic" cases is invented for the test (addresses are keccak-derived and belong to
# nobody). The two "bsc-mainnet-read" cases are real reads, listed with their block (README.md).
from __future__ import annotations

import copy
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import passport as P  # noqa: E402
from keccak import keccak256  # noqa: E402

FORMAT = "tap-agent-passport-vectors/1"
OUT = os.path.join(HERE, "vectors.json")

# ---------------------------------------------------------------------------
# Configuration: BNB Smart Chain addresses (TAP-10 Deployments; Specification §2)
# ---------------------------------------------------------------------------
CFG = {
    "chainId": 56,
    "identityRegistry": "0x8004a169fb4a3325136eb29fa0ceb6d2e539a432",
    "identityImplementations": ["0x7274e874ca62410a93bd8bf61c69d8045e399c02"],
    "reputationRegistry": "0x8004baa17c55a88189ae136b182e5fda19de9b63",
    "reputationImplementations": ["0x16e0fa7f7c56b9a767e34b192b51f921be31da34"],
    "factory": "0x68224f668083c29e9800be2a646d42d18cedf7e2",
    "opener": "0x021745de2f42a7839d96f2d3634d0294487d81f1",
    "siteRegistry": "0xd006ffdd5ae313b17729621a00999cd3c71ce5e6",
    "siteRegistryImplementations": ["0x1d279d138a4d803378a7d4557c056f1bed53c261"],
}
SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ZERO = P.ZERO_ADDR
Z32 = "0x" + "00" * 32


def A(n: int) -> str:
    """A synthetic address nobody holds."""
    return "0x" + keccak256(("tap-agent-passport synthetic %d" % n).encode())[12:].hex()


def H32(label: str) -> str:
    return "0x" + keccak256(label.encode()).hex()


# ABI encoders for eth_call answers --------------------------------------------------------------
def w(n: int) -> bytes:
    return n.to_bytes(32, "big")


def e_addr(a: str) -> str:
    return "0x" + (b"\x00" * 12 + bytes.fromhex(a[2:])).hex()


def e_uint(n: int) -> str:
    return "0x" + w(n).hex()


def e_bool(b: bool) -> str:
    return e_uint(1 if b else 0)


def _dyn(b: bytes) -> bytes:
    pad = (-len(b)) % 32
    return w(len(b)) + b + b"\x00" * pad


def e_bytes(b: bytes) -> str:
    return "0x" + (w(32) + _dyn(b)).hex()


def e_string(s: str) -> str:
    return e_bytes(s.encode())


def e_file_info(size: int, ctype: str, sha: str, updated: int, chunks: int) -> str:
    head = w(size) + w(5 * 32) + bytes.fromhex(sha[2:]) + w(updated) + w(chunks)
    return "0x" + (head + _dyn(ctype.encode())).hex()


def REVERT(msg: str = "") -> dict:
    return {"revert": "0x08c379a0" + (w(32) + _dyn(msg.encode())).hex() if msg else "0x"}


def slot_of(a: str) -> str:
    return "0x" + "00" * 12 + a[2:]


# ---------------------------------------------------------------------------
# The base world: one valid passport
# ---------------------------------------------------------------------------
PIN = 50_000_000
TS = 1_800_000_000
PROC = A(1)                    # processor contract, processor number 2
PROC_OTHER = [A(100), A(101)]  # processor numbers 0 and 1
TOKEN = 7
NAME = "7.2.tape"
HOLDER = A(10)
CONTAINER = A(20)
AGENT = 1001
GATEWAY = "gateway.example"
MANIFEST_SHA = H32("manifest bytes")

# Reviewer for §10: processor number 1, #9
R_PROC, R_TOKEN, R_NAME = PROC_OTHER[1], 9, "9.1.tape"
R_CONTAINER, R_HOLDER = A(30), A(40)
R2_PROC, R2_TOKEN, R2_NAME = PROC_OTHER[0], 3, "3.0.tape"
R2_CONTAINER, R2_HOLDER = A(31), A(41)


def reg_doc(agent_ids=(AGENT,), **over) -> dict:
    doc = {
        "type": P.REG_TYPE,
        "name": "digits-agent (example)",
        "description": "Example registration file of a synthetic test vector.",
        "image": "https://7-2.%s/avatar.png" % GATEWAY,
        "services": [
            {"name": "tape", "endpoint": "tape://" + NAME, "version": "1"},
            {"name": "web", "endpoint": "https://7-2.%s/" % GATEWAY},
            {"name": "MCP", "endpoint": "https://mcp.example.invalid/mcp", "version": "2025-11-25"},
        ],
        "x402Support": False,
        "active": True,
        "registrations": [{"agentId": a, "agentRegistry": "eip155:56:" + CFG["identityRegistry"]} for a in agent_ids],
        "supportedTrust": ["reputation"],
        "tap": {"v": 1, "chainId": 56, "processor": PROC, "tokenId": str(TOKEN), "container": CONTAINER,
                "manifest": {"path": "/.well-known/tapeapi.json", "sha256": MANIFEST_SHA}},
    }
    for k, v in over.items():
        doc[k] = v
    return doc


def file_answers(container: str, key: str, data: bytes, sha=None, size=None, chunks=1) -> dict:
    sha = sha if sha is not None else "0x" + hashlib.sha256(data).hexdigest()
    size = len(data) if size is None else size
    s = CFG["siteRegistry"]
    return {"%s.fileInfo(%s,%s)" % (s, container, key): e_file_info(size, "application/json", sha, TS - 500, chunks),
            "%s.read(%s,%s)" % (s, container, key): e_bytes(data)}


def agent_answers(agent_id: int, owner: str, wallet: str, key: bytes, uri: str) -> dict:
    r = CFG["identityRegistry"]
    return {"%s.ownerOf(%d)" % (r, agent_id): e_addr(owner),
            "%s.getMetadata(%d,tap.passport)" % (r, agent_id): e_bytes(key),
            "%s.getAgentWallet(%d)" % (r, agent_id): e_addr(wallet),
            "%s.tokenURI(%d)" % (r, agent_id): e_string(uri),
            "logs.Transfer.identity(%d)" % agent_id: [{"block": 49_000_000, "from": ZERO, "to": owner}]}


CANON_URI = "https://7-2.%s/.well-known/agent-registration.json" % GATEWAY


def base_answers(doc=None) -> dict:
    f, o, s = CFG["factory"], CFG["opener"], CFG["siteRegistry"]
    ans = {
        "eth_chainId": "0x38",
        "block": {"hash": H32("synthetic block %d" % PIN), "timestamp": TS},
        "implSlot:" + CFG["identityRegistry"]: slot_of(CFG["identityImplementations"][0]),
        "implSlot:" + s: slot_of(CFG["siteRegistryImplementations"][0]),
        "%s.isCPU(%s)" % (f, PROC): e_bool(True),
        "%s.ownerOf(%d)" % (PROC, TOKEN): e_addr(HOLDER),
        "%s.accountOf(%s,%d)" % (o, PROC, TOKEN): e_addr(CONTAINER),
        "%s.isOpened(%s,%d)" % (o, PROC, TOKEN): e_bool(True),
        "%s.cpuAt(0)" % f: e_addr(PROC_OTHER[0]),
        "%s.cpuAt(1)" % f: e_addr(PROC_OTHER[1]),
        "%s.cpuAt(2)" % f: e_addr(PROC),
        "%s.cpuAt(3)" % f: REVERT(),
        "%s.fileInfo(%s,%s)" % (s, CONTAINER, P.MANIFEST_KEY): e_file_info(900, "application/json", MANIFEST_SHA, TS - 600, 1),
        "logs.OperatorSet(%s)" % CONTAINER: [],
        "logs.Transfer.circuit(%s,%d)" % (PROC, TOKEN): [{"block": 48_000_000, "from": ZERO, "to": HOLDER}],
    }
    ans.update(agent_answers(AGENT, HOLDER, HOLDER, P.encode_passport_key(56, PROC, TOKEN), CANON_URI))
    data = json.dumps(doc if doc is not None else reg_doc(), indent=1, ensure_ascii=False).encode()
    ans.update(file_answers(CONTAINER, P.REG_KEY, data))
    return ans


def snapshot(answers: dict, inp: dict, ops=("binance-dataseed", "publicnode"), op_over=None,
             heads=None, source="synthetic", pin=PIN) -> dict:
    op_over = op_over or {}
    heads = heads or {}
    return {
        "format": P.SNAPSHOT_FORMAT, "source": source, "config": copy.deepcopy(CFG), "input": inp,
        "pinnedBlock": pin, "answers": answers,
        "operators": {op: {"head": heads.get(op, pin + 3), "answers": op_over.get(op, {})} for op in ops},
    }


BY_AGENT = {"agentId": str(AGENT)}
BY_CIRCUIT = {"circuit": {"processor": PROC, "tokenId": str(TOKEN)}}


def with_doc(doc) -> dict:
    return base_answers(doc)


def raw_file(data: bytes, **kw) -> dict:
    ans = base_answers()
    ans.update(file_answers(CONTAINER, P.REG_KEY, data, **kw))
    return ans


# ---------------------------------------------------------------------------
# Resolution cases
# ---------------------------------------------------------------------------
def resolution_cases() -> list:
    C = []

    def add(cid, rules, desc, snap, state, reasons=None, warnings=None, display=None, agent=None):
        exp = {"state": state, "reasons": reasons if reasons is not None else ([] if state == "CONFIRMED" else [state])}
        if warnings is not None:
            exp["warnings"] = warnings
        if display is not None:
            exp["display"] = display
        if agent is not None:
            exp["agentId"] = agent
        C.append({"id": cid, "rules": rules, "description": desc, "snapshot": snap, "expected": exp})

    ok_base = "TapeOut passport %s (container %s) for agent %d, confirmed at block %d" % (NAME, CONTAINER, AGENT, PIN)
    ok_display = ok_base + "; identity registered at block 49000000"
    add("confirmed-by-agent", ["P-1", "P-2", "P-3", "P-4", "P-5", "P-6", "P-7", "P-8", "P-9", "P-10", "D-1"],
        "A valid passport resolved from (registry, agentId).",
        snapshot(base_answers(), BY_AGENT), "CONFIRMED", warnings=[], display=ok_display)
    add("confirmed-by-circuit", ["P-10", "R-2"], "The same passport resolved from the circuit; the holder's file names the identity.",
        snapshot(base_answers(), BY_CIRCUIT), "CONFIRMED", warnings=[], agent=str(AGENT))

    a = base_answers(); a["%s.ownerOf(%d)" % (PROC, TOKEN)] = e_addr(A(11))
    add("circuit-changed-hands", ["P-1", "D-2"], "The circuit was sold; the identity stayed with the seller.",
        snapshot(a, BY_AGENT), "BROKEN", ["holder-mismatch"], display="not a passport: holder-mismatch")

    a = base_answers(); a.update(agent_answers(AGENT, A(12), ZERO, P.encode_passport_key(56, PROC, TOKEN), CANON_URI))
    add("identity-changed-hands", ["P-1"], "The identity was sold (its agentWallet cleared); the circuit stayed.",
        snapshot(a, BY_AGENT), "BROKEN", ["holder-mismatch"])

    a = base_answers(); a.update(agent_answers(AGENT, HOLDER, ZERO, P.encode_passport_key(56, PROC, TOKEN), CANON_URI))
    a["logs.Transfer.identity(%d)" % AGENT] = [{"block": 49_000_000, "from": ZERO, "to": A(12)},
                                              {"block": 49_600_000, "from": A(12), "to": HOLDER}]
    add("transferred-in-wallet-unset", ["P-9", "D-4"], "The holder received the identity by transfer; the registry cleared agentWallet.",
        snapshot(a, BY_AGENT), "wallet-unset",
        display="not confirmed: the agent wallet is unset (the identity changed hands); the holder can set it again")

    a = copy.deepcopy(a); a["%s.getAgentWallet(%d)" % (CFG["identityRegistry"], AGENT)] = e_addr(HOLDER)
    add("transferred-in-wallet-reset", ["P-9", "E-1", "E-2", "D-1"],
        "After the holder set agentWallet again: confirmed, and the holder epoch starts at the transfer.",
        snapshot(a, BY_AGENT), "CONFIRMED", warnings=["holder-changed"],
        display=ok_display + "; holder changed at block 49600000: earlier reputation does not belong to the current holder")

    a = base_answers(); a["%s.getAgentWallet(%d)" % (CFG["identityRegistry"], AGENT)] = e_addr(A(13))
    add("stale-agent-wallet", ["P-9", "S-1", "D-5"], "agentWallet points to another address.",
        snapshot(a, BY_AGENT), "stale-agent-wallet", display="not confirmed: the agent wallet differs from the holder")

    # Gift identity (critique-2 B1): an attacker registers 2002 pointing at the victim's circuit and transfers it in.
    gift = 2002
    a = base_answers(); a.update(agent_answers(gift, HOLDER, ZERO, P.encode_passport_key(56, PROC, TOKEN),
                                               "https://attacker.example/agent.json"))
    a["logs.Transfer.identity(%d)" % gift] = [{"block": 49_700_000, "from": ZERO, "to": A(66)},
                                             {"block": 49_700_010, "from": A(66), "to": HOLDER}]
    add("gift-identity-not-confirmed", ["P-10", "P-9", "T-gift"],
        "A third party registered an identity naming the victim's circuit and transferred it to the victim; the holder's file does not list it.",
        snapshot(a, {"agentId": str(gift)}), "BROKEN", ["not-listed"])
    add("gift-identity-no-dos", ["P-10", "T-gift"],
        "The same world: the holder's own identity stays CONFIRMED; the gifted one cannot make it AMBIGUOUS.",
        snapshot(a, BY_AGENT), "CONFIRMED", warnings=[])
    add("gift-identity-circuit-input", ["P-10", "T-gift"],
        "The same world resolved from the circuit: only the identity the holder lists is found.",
        snapshot(a, BY_CIRCUIT), "CONFIRMED", warnings=[], agent=str(AGENT))

    # Gift circuit (review-3 B-1): a stranger mints circuit #8, writes into its site a verbatim copy of the victim's
    # registration file (which lists the victim's identity and states circuit #7), and transfers #8 to the victim.
    # Resolved from #8, the file leads to the identity, whose key names #7: P-11 makes this BROKEN.
    gift_tok, gift_cont = 8, A(777)
    ag = base_answers()
    ag["%s.ownerOf(%d)" % (PROC, gift_tok)] = e_addr(HOLDER)
    ag["%s.accountOf(%s,%d)" % (CFG["opener"], PROC, gift_tok)] = e_addr(gift_cont)
    ag["%s.isOpened(%s,%d)" % (CFG["opener"], PROC, gift_tok)] = e_bool(True)
    ag.update(file_answers(gift_cont, P.REG_KEY, P.dec_bytes(P.unhex(ag["%s.read(%s,%s)" % (CFG["siteRegistry"], CONTAINER, P.REG_KEY)]))))
    ag["logs.OperatorSet(%s)" % gift_cont] = [{"operator": A(66), "setBy": A(66), "until": TS + 86400, "block": 49_900_000}]
    ag["logs.Transfer.circuit(%s,%d)" % (PROC, gift_tok)] = [{"block": 49_900_000, "from": ZERO, "to": A(66)},
                                                          {"block": 49_900_010, "from": A(66), "to": HOLDER}]
    add("gift-circuit-input", ["P-11", "T-gift-circuit"],
        "A stranger copied the holder's registration file into circuit #8 and gave #8 to the holder; resolved from #8, the key names #7.",
        snapshot(ag, {"circuit": {"processor": PROC, "tokenId": str(gift_tok)}}), "BROKEN", ["key-circuit-mismatch"],
        display="not a passport: key-circuit-mismatch")
    add("gift-circuit-by-identity", ["P-11", "T-gift-circuit"],
        "The same world resolved from the identity: the holder's own passport (#7) stays CONFIRMED.",
        snapshot(ag, BY_AGENT), "CONFIRMED", warnings=[], display=ok_display)

    # Measured on a BSC fork (block 129352831): after the gift, agentWallet is zero and the attacker's URI and
    # tap.passport bytes stay. If the victim chooses to adopt the gift, it lists it and self-signs setAgentWallet.
    d = reg_doc(agent_ids=(gift,))
    a2 = with_doc(d); a2.update({k: v for k, v in a.items() if "(%d" % gift in k})
    add("gift-adopted-wallet-unset", ["P-9", "T-gift"],
        "The victim lists the gifted identity in its own file but has not self-signed setAgentWallet yet.",
        snapshot(a2, {"agentId": str(gift)}), "wallet-unset")
    a3 = copy.deepcopy(a2); a3["%s.getAgentWallet(%d)" % (CFG["identityRegistry"], gift)] = e_addr(HOLDER)
    add("gift-adopted-recovered", ["P-9", "E-2", "T-gift"],
        "After the victim self-signs setAgentWallet (ECDSA branch, deadline within about 300 s) the adopted identity is confirmed; the holder epoch starts at the gift.",
        snapshot(a3, {"agentId": str(gift)}), "CONFIRMED", warnings=["agent-uri-not-canonical", "holder-changed"])

    # Double registration by the holder.
    second = 2003
    a = with_doc(reg_doc(agent_ids=(AGENT, second)))
    a.update(agent_answers(second, HOLDER, HOLDER, P.encode_passport_key(56, PROC, TOKEN), CANON_URI))
    add("double-registration-both-listed", ["P-10", "D-3"], "The holder lists two identities of this registry in its file.",
        snapshot(a, BY_AGENT), "AMBIGUOUS", ["several-listed"],
        display="ambiguous: the holder's site lists several agent identities for this registry")
    add("double-registration-circuit-input", ["P-10"], "The same file, resolved from the circuit.",
        snapshot(a, BY_CIRCUIT), "AMBIGUOUS", ["several-listed"])
    a = base_answers()
    a.update(agent_answers(second, HOLDER, HOLDER, P.encode_passport_key(56, PROC, TOKEN), CANON_URI))
    add("double-registration-one-listed", ["P-10"], "The holder registered a second identity but lists only the first.",
        snapshot(a, {"agentId": str(second)}), "BROKEN", ["not-listed"])

    d = reg_doc(); d["registrations"] = [{"agentId": AGENT, "agentRegistry": "eip155:8453:" + CFG["identityRegistry"]}]
    add("listed-under-other-chain", ["P-3", "P-10"], "The file lists the agent under the same registry address on another chain.",
        snapshot(with_doc(d), BY_AGENT), "BROKEN", ["not-listed"])
    d = reg_doc(); d["registrations"] = [{"agentId": str(AGENT), "agentRegistry": "eip155:56:0x8004A169FB4a3325136EB29fA0ceB6D2e539a432"}]
    add("listed-as-string-checksummed", ["P-10"], "agentId as a decimal string and a checksummed registry address are accepted.",
        snapshot(with_doc(d), BY_AGENT), "CONFIRMED", warnings=[])

    a = base_answers(); a["%s.getMetadata(%d,tap.passport)" % (CFG["identityRegistry"], AGENT)] = e_bytes(P.encode_passport_key(8453, PROC, TOKEN))
    add("key-chain-mismatch", ["P-3"], "tap.passport names chain 8453 while the nodes are on chain 56.",
        snapshot(a, BY_AGENT), "BROKEN", ["chain-mismatch"])
    d = reg_doc(); d["tap"]["chainId"] = 8453
    add("file-chain-mismatch", ["P-3", "P-7"], "The file's tap.chainId differs from the chain.",
        snapshot(with_doc(d), BY_AGENT), "BROKEN", ["file-chain-mismatch"])

    # Node and pinning failures: never BROKEN.
    key = "%s.ownerOf(%d)" % (CFG["identityRegistry"], AGENT)
    add("node-disagreement-owner", ["P-6", "D-6"], "Two operators disagree on ownerOf(agentId).",
        snapshot(base_answers(), BY_AGENT, op_over={"publicnode": {key: e_addr(A(99))}}), "UNAVAILABLE", ["node-disagreement"],
        display="could not verify: node-disagreement")
    fkey = "%s.read(%s,%s)" % (CFG["siteRegistry"], CONTAINER, P.REG_KEY)
    add("node-disagreement-file", ["P-6"], "Two operators return different registration-file bytes: unavailable, not broken.",
        snapshot(base_answers(), BY_AGENT, op_over={"publicnode": {fkey: e_bytes(b"{}")}}), "UNAVAILABLE", ["node-disagreement"])
    add("single-operator", ["P-6"], "Only one operator is configured; strict agreement needs two.",
        snapshot(base_answers(), BY_AGENT, ops=("binance-dataseed",)), "UNAVAILABLE", ["unavailable"])
    wkey = "%s.getAgentWallet(%d)" % (CFG["identityRegistry"], AGENT)
    add("missing-answer", ["P-6"], "One of two operators gave no answer for getAgentWallet.",
        snapshot(base_answers(), BY_AGENT, op_over={"publicnode": {wkey: None}}), "UNAVAILABLE", ["unavailable"])
    three = snapshot(base_answers(), BY_AGENT, ops=("binance-dataseed", "publicnode", "third"), op_over={"third": {wkey: None}})
    add("three-operators-one-silent", ["P-6"], "Three operators configured, one silent: three answers are required.",
        three, "UNAVAILABLE", ["unavailable"])
    a = base_answers(); a["eth_chainId"] = "0x61"
    add("wrong-chain", ["P-6"], "The nodes report chain 97.", snapshot(a, BY_AGENT), "UNAVAILABLE", ["wrong-chain"])
    add("stale-block", ["P-6"], "The pinned block lags the highest head by 401 blocks.",
        snapshot(base_answers(), BY_AGENT, heads={"publicnode": PIN + 401}), "UNAVAILABLE", ["stale-block"])
    a = base_answers(); a["implSlot:" + CFG["identityRegistry"]] = slot_of(A(77))
    add("registry-changed", ["P-6", "S-4"], "The identity registry proxy points to an implementation not listed in §2.",
        snapshot(a, BY_AGENT), "UNAVAILABLE", ["registry-changed"])
    a = base_answers(); a["implSlot:" + CFG["siteRegistry"]] = slot_of(A(78))
    add("store-changed", ["P-6"], "The site store implementation is not accepted (TAP-10 §6.1).",
        snapshot(a, BY_AGENT), "UNAVAILABLE", ["store-changed"])

    # Chain facts.
    mk = "%s.getMetadata(%d,tap.passport)" % (CFG["identityRegistry"], AGENT)
    a = base_answers(); a[mk] = e_bytes(b"")
    add("no-passport-key", ["P-2"], "The identity has no tap.passport metadata.", snapshot(a, BY_AGENT), "BROKEN", ["no-passport-key"])
    a = base_answers(); a[mk] = e_bytes(P.encode_passport_key(56, PROC, TOKEN)[:95])
    add("key-95-bytes", ["P-2"], "tap.passport of 95 bytes.", snapshot(a, BY_AGENT), "BROKEN", ["bad-passport-key"])
    k = bytearray(P.encode_passport_key(56, PROC, TOKEN)); k[40] = 1
    a = base_answers(); a[mk] = e_bytes(bytes(k))
    add("key-dirty-address", ["P-2"], "The address word of tap.passport has non-zero high bytes.", snapshot(a, BY_AGENT), "BROKEN", ["bad-passport-key"])
    a = base_answers(); a["%s.isCPU(%s)" % (CFG["factory"], PROC)] = e_bool(False)
    add("not-tapeout", ["P-4"], "The processor named by the key is not a TapeOut processor.", snapshot(a, BY_AGENT), "BROKEN", ["not-tapeout"])
    a = base_answers(); a["%s.ownerOf(%d)" % (PROC, TOKEN)] = REVERT("ERC721NonexistentToken")
    add("no-such-token", ["P-4"], "The circuit does not exist.", snapshot(a, BY_AGENT), "BROKEN", ["no-such-token"])
    a = base_answers(); a["%s.isOpened(%s,%d)" % (CFG["opener"], PROC, TOKEN)] = e_bool(False)
    add("not-opened", ["P-5"], "The container is not opened.", snapshot(a, BY_AGENT), "BROKEN", ["not-opened"])
    a = base_answers(); a[key] = REVERT("ERC721NonexistentToken")
    add("no-such-agent", ["P-1"], "The agentId does not exist.", snapshot(a, BY_AGENT), "BROKEN", ["no-such-agent"])

    # Files.
    s = CFG["siteRegistry"]
    a = base_answers(); a["%s.fileInfo(%s,%s)" % (s, CONTAINER, P.REG_KEY)] = e_file_info(0, "", Z32, 0, 0)
    add("registration-file-missing", ["P-7", "A-onboarding"],
        "Registered with tap.passport but the file is not written yet (the state between the last two onboarding transactions).",
        snapshot(a, BY_AGENT), "BROKEN", ["registration-file-missing"])
    good = json.dumps(reg_doc(), indent=1).encode()
    add("registration-file-incomplete", ["P-7"], "The file's SHA-256 does not match fileInfo.",
        snapshot(raw_file(good, sha=H32("other")), BY_AGENT), "BROKEN", ["registration-file-incomplete"])
    add("registration-file-no-hash", ["P-7"], "fileInfo declares no hash.",
        snapshot(raw_file(good, sha=Z32), BY_AGENT), "BROKEN", ["registration-file-no-hash"])
    add("registration-file-too-large", ["P-7"], "fileInfo declares 65,537 bytes; the file is not read.",
        snapshot(raw_file(good, size=65537), BY_AGENT), "BROKEN", ["registration-file-too-large"])
    add("registration-file-not-json", ["P-7"], "The file is not JSON.",
        snapshot(raw_file(b"<html>not json</html>"), BY_AGENT), "BROKEN", ["registration-file-invalid"])
    dup = good.replace(b'"active": true', b'"active": true, "active": false', 1)
    add("registration-file-repeated-member", ["P-7"], "A member name is repeated.",
        snapshot(raw_file(dup), BY_AGENT), "BROKEN", ["registration-file-invalid"])
    add("registration-file-bom", ["P-7"], "The file starts with a byte order mark.",
        snapshot(raw_file(b"\xef\xbb\xbf" + good), BY_AGENT), "BROKEN", ["registration-file-invalid"])
    proto = good.replace(b'"active": true', b'"active": true, "__proto__": {}', 1)
    add("registration-file-proto", ["P-7"], "A member is named __proto__.",
        snapshot(raw_file(proto), BY_AGENT), "BROKEN", ["registration-file-invalid"])
    big = good.replace(b'"active": true', b'"active": true, "n": 9007199254740993', 1)
    add("registration-file-no-canonical-form", ["P-7"], "An integer above 2^53 - 1 leaves the file without a canonical form.",
        snapshot(raw_file(big), BY_AGENT), "BROKEN", ["registration-file-invalid"])
    add("registration-file-wrong-type", ["P-7"], "The file's type is not the ERC-8004 registration type.",
        snapshot(with_doc(reg_doc(type="https://example.invalid/agent")), BY_AGENT), "BROKEN", ["registration-file-invalid"])
    d = reg_doc(); d["tap"]["container"] = A(21)
    add("file-container-mismatch", ["P-7", "R-1"], "The file names another container.", snapshot(with_doc(d), BY_AGENT), "BROKEN", ["file-chain-mismatch"])
    d = reg_doc(); d["tap"]["tokenId"] = "8"
    add("file-token-mismatch", ["P-7"], "The file names another #ID.", snapshot(with_doc(d), BY_AGENT), "BROKEN", ["file-chain-mismatch"])
    d = reg_doc(); d["services"] = d["services"][1:]
    add("tape-service-missing", ["P-7"], "services[] has no tape entry.", snapshot(with_doc(d), BY_AGENT), "BROKEN", ["tape-service-missing"])
    d = reg_doc(); d["services"][0]["endpoint"] = "tape://7.1.tape"
    add("tape-service-wrong-name", ["P-7"], "The tape entry names another circuit.", snapshot(with_doc(d), BY_AGENT), "BROKEN", ["tape-service-missing"])
    for cid, nm in (("forbidden-plain", "reward"), ("forbidden-fullwidth", "ｒｅｗａｒｄ"),
                    ("forbidden-zero-width", "re​ward"), ("forbidden-cyrillic", "rеward"),
                    ("forbidden-camel", "airDrop"), ("forbidden-chinese", "空投"), ("forbidden-segment", "tier")):
        d = reg_doc(); d["tap"][nm] = 1
        add(cid, ["P-7"], "A member named %r inside tap." % nm, snapshot(with_doc(d), BY_AGENT), "BROKEN", ["forbidden-name"])
    d = reg_doc(); d["tap"]["manifest"]["path"] = "/tapeapi.json"
    add("tap-manifest-path", ["P-7"], "tap.manifest.path is not /.well-known/tapeapi.json.", snapshot(with_doc(d), BY_AGENT), "BROKEN", ["registration-file-invalid"])
    d = reg_doc(); d["tap"]["tokenId"] = "07"
    add("tap-token-leading-zero", ["P-7"], "tap.tokenId has a leading zero.", snapshot(with_doc(d), BY_AGENT), "BROKEN", ["registration-file-invalid"])
    d = reg_doc(); d["tap"]["endpoints"] = {"note": "unknown members are ignored"}; d["extra"] = {"price": 1}
    add("unknown-members-ignored", ["P-7"], "Unknown members (an ordinary name inside tap; any name outside tap) are ignored.",
        snapshot(with_doc(d), BY_AGENT), "CONFIRMED", warnings=[])

    # Operators.
    ok = "logs.OperatorSet(%s)" % CONTAINER
    a = base_answers(); a[ok] = [{"operator": A(50), "setBy": A(11), "until": TS + 86400, "block": 47_000_000}]
    add("stale-operator", ["P-8", "T-operator"], "An operator set by an earlier holder is still active.",
        snapshot(a, BY_AGENT), "BROKEN", ["stale-operator"])
    a = base_answers(); a[ok] = [{"operator": A(50), "setBy": HOLDER, "until": TS + 86400, "block": 49_100_000}]
    add("operator-by-holder", ["P-8"], "The only active operator was set by the current holder.", snapshot(a, BY_AGENT), "CONFIRMED", warnings=[])
    a = base_answers(); a[ok] = [{"operator": A(50), "setBy": A(11), "until": TS - 1, "block": 47_000_000}]
    add("operator-expired", ["P-8"], "An earlier holder's operator has expired.", snapshot(a, BY_AGENT), "CONFIRMED", warnings=[])
    a = base_answers(); a[ok] = [{"operator": A(50), "setBy": A(11), "until": TS, "block": 47_000_000}]
    add("operator-until-equals-block-time", ["P-8"], "An earlier holder's operator whose until equals the pinned block's timestamp is still active.",
        snapshot(a, BY_AGENT), "BROKEN", ["stale-operator"])
    a = base_answers(); a[ok] = [{"operator": A(50), "setBy": A(11), "until": TS + 86400, "block": 47_000_000},
                                 {"operator": A(50), "setBy": HOLDER, "until": 0, "block": 49_100_000}]
    add("operator-cleared", ["P-8"], "The current holder later set the same operator's ttl to zero.", snapshot(a, BY_AGENT), "CONFIRMED", warnings=[])
    a = base_answers(); a[ok] = {"unavailable": True}
    add("operators-not-checked", ["P-8", "D-1"], "The OperatorSet logs could not be obtained.", snapshot(a, BY_AGENT), "CONFIRMED",
        warnings=["operators-not-checked"], display=ok_base + "; site operators not checked; identity registered at block 49000000")

    # Warnings.
    a = base_answers(); a["%s.tokenURI(%d)" % (CFG["identityRegistry"], AGENT)] = e_string("https://%s/7.2.tape/agent.json" % GATEWAY)
    add("agent-uri-path-form", ["R-3"], "agentURI does not use the TAP-10 §3.3 host label form.", snapshot(a, BY_AGENT), "CONFIRMED",
        warnings=["agent-uri-not-canonical"])
    a = base_answers(); a["%s.fileInfo(%s,%s)" % (s, CONTAINER, P.MANIFEST_KEY)] = e_file_info(900, "application/json", H32("newer"), TS, 1)
    add("manifest-hash-differs", ["R-4"], "tap.manifest.sha256 differs from the manifest now on chain.", snapshot(a, BY_AGENT), "CONFIRMED",
        warnings=["manifest-hash-differs"])
    a = base_answers(); a["logs.Transfer.circuit(%s,%d)" % (PROC, TOKEN)] = {"unavailable": True}
    add("transfer-history-unavailable", ["E-1", "D-1"], "Transfer logs could not be obtained: the holder epoch is unknown.",
        snapshot(a, BY_AGENT), "CONFIRMED", warnings=["transfer-history-unavailable"],
        display=ok_base + "; holder history not checked")

    # Circuit input without a listed identity.
    d = reg_doc(agent_ids=())
    add("circuit-none-listed", ["P-10"], "Resolved from the circuit: the holder's file lists no identity of this registry.",
        snapshot(with_doc(d), BY_CIRCUIT), "BROKEN", ["not-listed"])
    return C


# ---------------------------------------------------------------------------
# Real reads (BNB Smart Chain, two operators at one pinned block)
# ---------------------------------------------------------------------------
REAL = {
    "block": 129353737,
    "blockHash": "0xc8c2af8680fe6d23f826e1089e00a605b8b52605df7ab746a787f463592cf0f9",
    "timestamp": 1792772831,
    "heads": {"binance-dataseed": 129353739, "publicnode": 129353740},
    "endpoints": {"binance-dataseed": "https://bsc-dataseed.binance.org", "publicnode": "https://bsc-rpc.publicnode.com"},
    "answers": {
        "eth_chainId": "0x38",
        "identity.ownerOf(1)": "0x00000000000000000000000089e9e1ab11dd1b138b1dce6d6a4a0926aafd5029",
        "identity.getMetadata(1,tap.passport)": "0x00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000",
        "processor.ownerOf(4246)": "0x000000000000000000000000571d447f4f24688ec35ccf07f1d6993655f6af15",
        "opener.accountOf(P,4246)": "0x00000000000000000000000086ddaef00401e3f10418398d67d7189fc458ea95",
        "opener.isOpened(P,4246)": "0x0000000000000000000000000000000000000000000000000000000000000001",
        "factory.isCPU(P)": "0x0000000000000000000000000000000000000000000000000000000000000001",
        "factory.cpuAt(0)": "0x00000000000000000000000050a994e71615474b55559ff4f500928fbc339dd9",
        "siteRegistry.fileInfo(C,agent-registration)": "0x" + "00" * 32 + "00" * 31 + "a0" + "00" * 96 + "00" * 32,
        "implSlot:identity": "0x0000000000000000000000007274e874ca62410a93bd8bf61c69d8045e399c02",
        "implSlot:siteRegistry": "0x0000000000000000000000001d279d138a4d803378a7d4557c056f1bed53c261",
    },
}


def real_cases() -> list:
    r = REAL["answers"]
    ident, s, f, o = CFG["identityRegistry"], CFG["siteRegistry"], CFG["factory"], CFG["opener"]
    proc, cont = "0x50a994e71615474b55559ff4f500928fbc339dd9", "0x86ddaef00401e3f10418398d67d7189fc458ea95"
    common = {
        "eth_chainId": r["eth_chainId"],
        "block": {"hash": REAL["blockHash"], "timestamp": REAL["timestamp"]},
        "implSlot:" + ident: r["implSlot:identity"],
        "implSlot:" + s: r["implSlot:siteRegistry"],
    }
    a1 = dict(common)
    a1["%s.ownerOf(1)" % ident] = r["identity.ownerOf(1)"]
    a1["%s.getMetadata(1,tap.passport)" % ident] = r["identity.getMetadata(1,tap.passport)"]
    a2 = dict(common)
    a2["%s.isCPU(%s)" % (f, proc)] = r["factory.isCPU(P)"]
    a2["%s.ownerOf(4246)" % proc] = r["processor.ownerOf(4246)"]
    a2["%s.accountOf(%s,4246)" % (o, proc)] = r["opener.accountOf(P,4246)"]
    a2["%s.isOpened(%s,4246)" % (o, proc)] = r["opener.isOpened(P,4246)"]
    a2["%s.cpuAt(0)" % f] = r["factory.cpuAt(0)"]
    a2["%s.fileInfo(%s,%s)" % (s, cont, P.REG_KEY)] = r["siteRegistry.fileInfo(C,agent-registration)"]
    out = []
    for cid, ans, inp, reason, desc in (
            ("real-agent-1-not-a-passport", a1, {"agentId": "1"}, "no-passport-key",
             "ERC-8004 agent #1 on BNB Smart Chain has no tap.passport metadata."),
            ("real-circuit-4246-no-file", a2, {"circuit": {"processor": proc, "tokenId": "4246"}}, "registration-file-missing",
             "Circuit #4246@0 (container 0x86DD...eA95) is opened but has no /.well-known/agent-registration.json.")):
        snap = snapshot(ans, inp, heads=REAL["heads"], source="bsc-mainnet-read", pin=REAL["block"])
        snap["readAt"] = {"block": REAL["block"], "blockHash": REAL["blockHash"], "timestamp": REAL["timestamp"],
                          "utc": "2026-10-23T16:27:11Z", "endpoints": REAL["endpoints"], "agree": True}
        out.append({"id": cid, "rules": ["P-2"] if reason == "no-passport-key" else ["P-7"], "description": desc,
                    "snapshot": snap, "expected": {"state": "BROKEN", "reasons": [reason]}})
    return out


# ---------------------------------------------------------------------------
# §10 feedback cases
# ---------------------------------------------------------------------------
def make_record(reviewer_c: str, score: int, issued: int, subject_label: str, kind=1, reviewee=CONTAINER) -> dict:
    return {"review": {"reviewer": P.endpoint_id(56, reviewer_c), "reviewee": P.endpoint_id(56, reviewee),
                       "kind": kind, "score": score if kind == 1 else 0,
                       "subject": H32(subject_label) if kind == 1 else Z32,
                       "evidenceHash": H32("evidence " + subject_label) if kind == 1 else Z32,
                       "textHash": Z32, "issued": issued},
            "sig": "0x" + "11" * 65}


def reviewer_answers(proc, tok, cont, holder) -> dict:
    return {"%s.accountOf(%s,%d)" % (CFG["opener"], proc, tok): e_addr(cont), "%s.ownerOf(%d)" % (proc, tok): e_addr(holder)}


def fb_entry(client, index, block, record, level=1, name=R_NAME, data=None, **over) -> dict:
    data = data if data is not None else P.canonical_bytes(record)
    rh = P.review_hash(record["review"])
    e = {"client": client, "index": index, "block": block, "value": record["review"]["score"], "valueDecimals": 0,
         "tag1": "tap-review", "tag2": "level-%d" % level, "endpoint": "",
         "feedbackURI": "https://%s.%s/%s" % (name[:-5].replace(".", "-"), GATEWAY, P.review_file_key(rh)),
         "feedbackHash": "0x" + keccak256(data).hex(), "revoked": False}
    e.update(over)
    return e


def feedback_world(entries, files, verdicts, extra=None, base=None, clients=None, cap=None) -> dict:
    a = base if base is not None else base_answers()
    a.update(reviewer_answers(R_PROC, R_TOKEN, R_CONTAINER, R_HOLDER))
    a.update(reviewer_answers(R2_PROC, R2_TOKEN, R2_CONTAINER, R2_HOLDER))
    for cont, rec, data in files:
        a.update(file_answers(cont, P.review_file_key(P.review_hash(rec["review"])), data))
    a["logs.NewFeedback(%d)" % AGENT] = entries
    a.setdefault("implSlot:" + CFG["reputationRegistry"], slot_of(CFG["reputationImplementations"][0]))
    if extra:
        a.update(extra)
    snap = snapshot(a, BY_AGENT)
    snap["review54"] = verdicts
    snap["summary"] = {"clientAddresses": clients if clients is not None else [R_HOLDER, R2_HOLDER]}
    if cap is not None:
        snap["summary"]["maxEntries"] = cap
    return snap


def feedback_cases() -> list:
    C = []
    rec = make_record(R_CONTAINER, 4, TS - 10_000, "call 1")
    rh = P.review_hash(rec["review"])
    data = P.canonical_bytes(rec)
    V = {rh: {"counted": True, "level": 1}}
    files = [(R_CONTAINER, rec, data)]

    def add(cid, rules, desc, snap, counted, excluded, clients, summary1=None, state="CONFIRMED", outside=0):
        exp = {"state": state, "counted": counted, "excluded": excluded, "getSummaryClientAddresses": clients,
               "outsideClientSet": outside,
               "earlierHolders": sum(1 for x in excluded if x["reason"] == "earlier-holder")}
        if summary1 is not None:
            exp["level-1"] = summary1
        C.append({"id": cid, "rules": rules, "description": desc, "snapshot": snap, "expected": exp})

    one = {"reviewers": 1, "holders": 1, "scores": {"1": 0, "2": 0, "3": 0, "4": 1, "5": 0}}
    none = {"reviewers": 0, "holders": 0, "scores": {"1": 0, "2": 0, "3": 0, "4": 0, "5": 0}}
    t1 = "%s#1" % R_HOLDER
    add("feedback-counted", ["F-1", "F-2", "F-3", "F-4", "F-5", "F-6", "F-7", "F-9", "F-10"],
        "One level-1 review written as ERC-8004 feedback; counted.",
        feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec)], files, V), [t1], [], [R_HOLDER], one)
    add("feedback-other-tag", ["F-1"], "Feedback under another tag1 is not part of this summary.",
        feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec, tag1="starred")], files, V), [], [], None, none)
    add("feedback-bad-tag2", ["F-2"], "tag2 is not level-1 or level-2.",
        feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec, tag2="level-0")], files, V), [],
        [{"feedback": t1, "reason": "bad-tag2"}], None)
    add("feedback-hash-mismatch", ["F-3"], "feedbackHash is not keccak256 of the file's bytes.",
        feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec, feedbackHash=H32("x"))], files, V), [],
        [{"feedback": t1, "reason": "hash-mismatch"}], None)
    add("feedback-collection-uri", ["F-3"], "feedbackURI points at the whole tapeapi-reviews.json file, not a one-record file.",
        feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec,
                                 feedbackURI="https://9-1.%s/.well-known/tapeapi-reviews.json#%s" % (GATEWAY, rh))], files, V), [],
        [{"feedback": t1, "reason": "bad-uri"}], None)
    pretty = json.dumps(rec, indent=2).encode()
    add("feedback-not-canonical", ["F-3"], "The one-record file is not in canonical form (its hash matches the pretty bytes).",
        feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec, data=pretty)], [(R_CONTAINER, rec, pretty)], V), [],
        [{"feedback": t1, "reason": "not-canonical"}], None)
    rec_x = make_record(R_CONTAINER, 4, TS - 10_000, "call x", reviewee=A(22))
    add("feedback-wrong-reviewee", ["F-4"], "The record reviews another container.",
        feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec_x)], [(R_CONTAINER, rec_x, P.canonical_bytes(rec_x))],
                       {P.review_hash(rec_x["review"]): {"counted": True, "level": 1}}), [],
        [{"feedback": t1, "reason": "wrong-reviewee"}], None)
    add("feedback-not-counted-54", ["F-5"], "The #54 verifier did not count the record (for example related-parties or level 0).",
        feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec)], files, {rh: {"counted": False, "level": 0}}), [],
        [{"feedback": t1, "reason": "not-counted"}], None)
    add("feedback-level-mismatch", ["F-5"], "tag2 says level-2 but the record verifies at level 1.",
        feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec, tag2="level-2")], files, V), [],
        [{"feedback": t1, "reason": "level-mismatch"}], None)
    add("feedback-value-mismatch", ["F-10"], "value differs from the record's score.",
        feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec, value=5)], files, V), [],
        [{"feedback": t1, "reason": "value-mismatch"}], None)
    add("feedback-client-not-holder", ["F-6"], "The reviewer's circuit changed hands; the feedback's client no longer holds it.",
        feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec)], files, V,
                       extra={"%s.ownerOf(%d)" % (R_PROC, R_TOKEN): e_addr(A(42))}), [],
        [{"feedback": t1, "reason": "client-not-reviewer-holder"}], None)
    add("feedback-revoked", ["F-8"], "Revoked feedback is not counted.",
        feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec, revoked=True)], files, V), [],
        [{"feedback": t1, "reason": "revoked"}], None)
    rec2 = make_record(R_CONTAINER, 2, TS - 5_000, "call 2")
    rh2 = P.review_hash(rec2["review"])
    add("feedback-latest-per-reviewer", ["F-9"], "Two reviews by one reviewer container: only the later one counts.",
        feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec), fb_entry(R_HOLDER, 2, 49_800_000, rec2)],
                       files + [(R_CONTAINER, rec2, P.canonical_bytes(rec2))],
                       {rh: {"counted": True, "level": 1}, rh2: {"counted": True, "level": 1}}),
        ["%s#2" % R_HOLDER], [], [R_HOLDER],
        {"reviewers": 1, "holders": 1, "scores": {"1": 0, "2": 1, "3": 0, "4": 0, "5": 0}})
    rec3 = make_record(R2_CONTAINER, 5, TS - 7_000, "call 3")
    rh3 = P.review_hash(rec3["review"])
    add("feedback-two-reviewers", ["F-9", "F-10"], "Two reviewer containers with different holders.",
        feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec), fb_entry(R2_HOLDER, 1, 49_510_000, rec3, name=R2_NAME)],
                       files + [(R2_CONTAINER, rec3, P.canonical_bytes(rec3))],
                       {rh: {"counted": True, "level": 1}, rh3: {"counted": True, "level": 1}}),
        sorted([t1, "%s#1" % R2_HOLDER]), [], sorted([R_HOLDER, R2_HOLDER]),
        {"reviewers": 2, "holders": 2, "scores": {"1": 0, "2": 0, "3": 0, "4": 1, "5": 1}})
    # Holder epoch: the identity was bought at block 49,600,000; earlier feedback is the previous holder's.
    a = base_answers()
    a["logs.Transfer.identity(%d)" % AGENT] = [{"block": 49_000_000, "from": ZERO, "to": A(12)},
                                              {"block": 49_600_000, "from": A(12), "to": HOLDER}]
    add("feedback-earlier-holder", ["F-7", "E-2"], "Feedback given before the current holder acquired the identity is not counted for it.",
        feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec)], files, V, base=a), [],
        [{"feedback": t1, "reason": "earlier-holder"}], None)
    a = base_answers(); a["logs.Transfer.circuit(%s,%d)" % (PROC, TOKEN)] = {"unavailable": True}
    add("feedback-epoch-unknown", ["F-7"], "Without transfer history no feedback is attributed to the current holder.",
        feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec)], files, V, base=a), [],
        [{"feedback": t1, "reason": "epoch-unknown"}], None)
    # F-0: feedback from addresses outside the named client set is counted, never fetched (spam).
    spam = [fb_entry(A(66 + i), 1, 49_700_000 + i, rec, feedbackURI="https://spam%d.example/x.json" % i) for i in range(3)]
    add("feedback-outside-client-set", ["F-0"],
        "Three entries from addresses outside the named set are not fetched; the named reviewer's feedback counts.",
        feedback_world(spam + [fb_entry(R_HOLDER, 1, 49_500_000, rec)], files, V), [t1], [], [R_HOLDER], one, outside=3)
    C.append({"id": "feedback-no-client-set", "rules": ["F-0"],
              "description": "No client address set was named: no summary.",
              "snapshot": feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec)], files, V, clients=[]),
              "expected": {"state": "CONFIRMED", "computed": False, "why": "no-client-set"}})
    C.append({"id": "feedback-truncated", "rules": ["F-0"],
              "description": "The tool examines at most one entry and there are two: summary-truncated, no partial numbers.",
              "snapshot": feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec), fb_entry(R_HOLDER, 2, 49_800_000, rec2)],
                                         files + [(R_CONTAINER, rec2, P.canonical_bytes(rec2))],
                                         {rh: {"counted": True, "level": 1}, rh2: {"counted": True, "level": 1}}, cap=1),
              "expected": {"state": "CONFIRMED", "computed": False, "why": "summary-truncated"}})
    a = base_answers(); a["implSlot:" + CFG["reputationRegistry"]] = slot_of(A(79))
    C.append({"id": "feedback-registry-changed", "rules": ["S-4", "F-4"],
              "description": "The reputation registry points to an implementation not listed in §2: no summary.",
              "snapshot": feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec)], files, V, base=a),
              "expected": {"state": "CONFIRMED", "computed": False, "why": "registry-changed"}})
    a = base_answers(); a["%s.getAgentWallet(%d)" % (CFG["identityRegistry"], AGENT)] = e_addr(ZERO)
    C.append({"id": "feedback-passport-not-confirmed", "rules": ["F-4"],
              "description": "No summary is computed for an identity that is not a CONFIRMED passport.",
              "snapshot": feedback_world([fb_entry(R_HOLDER, 1, 49_500_000, rec)], files, V, base=a),
              "expected": {"state": "wallet-unset", "computed": False, "why": "passport not confirmed"}})
    return C


def feedback_param_cases() -> list:
    rec = make_record(R_CONTAINER, 4, TS - 10_000, "call 1")
    p = P.feedback_params(rec, AGENT, R_NAME, GATEWAY, 1)
    return [{"id": "give-feedback-args", "rules": ["W-4"], "record": rec, "agentId": AGENT, "reviewerName": R_NAME,
             "gatewayDomain": GATEWAY, "level": 1, "reviewHash": P.review_hash(rec["review"]), "expected": p}]


# ---------------------------------------------------------------------------
# Small sections
# ---------------------------------------------------------------------------
def key_cases() -> list:
    good = P.encode_passport_key(56, PROC, TOKEN)
    out = [{"id": "key-valid", "rules": ["P-2"], "chainId": 56, "processor": PROC, "tokenId": str(TOKEN), "bytes": "0x" + good.hex(),
            "expected": {"ok": True, "chainId": 56, "processor": PROC, "tokenId": TOKEN}}]
    k = bytearray(good); k[40] = 0xff
    bad = [("key-empty", b"", "no-passport-key"), ("key-95", good[:95], "bad-passport-key"), ("key-97", good + b"\x00", "bad-passport-key"),
           ("key-dirty-high-bytes", bytes(k), "bad-passport-key"),
           ("key-token-zero", P.encode_passport_key(56, PROC, 0) if False else good[:64] + w(0), "bad-passport-key"),
           ("key-token-above-1e18", good[:64] + w(10 ** 18 + 1), "bad-passport-key"),
           ("key-chain-zero", w(0) + good[32:], "bad-passport-key"),
           ("key-zero-processor", good[:32] + w(0) + good[64:], "bad-passport-key")]
    for cid, b, reason in bad:
        out.append({"id": cid, "rules": ["P-2"], "bytes": "0x" + b.hex(), "expected": {"ok": False, "reason": reason}})
    out.append({"id": "key-base-chain", "rules": ["P-2", "P-3"], "bytes": "0x" + P.encode_passport_key(8453, PROC, TOKEN).hex(),
                "expected": {"ok": True, "chainId": 8453, "processor": PROC, "tokenId": TOKEN}})
    return out


def name_cases() -> list:
    names = [("reward", True), ("Rewards", True), ("air_drop", True), ("airDrop", True), ("ｒｅｗａｒｄ", True),
             ("re​ward", True), ("rеward", True), ("pay_out", True), ("收益", True), ("tier", True), ("rank", True),
             ("verified", True), ("endpoint", False), ("frontier", False), ("container", False), ("processor", False),
             ("manifest", False), ("tokenId", False), ("sha256", False), ("mistake", False)]
    return [{"id": "name-%d" % i, "rules": ["P-7"], "name": n, "expected": {"forbidden": f}} for i, (n, f) in enumerate(names)]


def canonical_cases() -> list:
    vals = [({"b": 1, "a": [True, None, "x"]}, '{"a":[true,null,"x"],"b":1}'),
            ({"€": 1, "é": 2, "z": 3}, '{"z":3,"é":2,"€":1}'),
            ({"n": 1e21, "m": 1.5, "k": 1e-7}, '{"k":1e-7,"m":1.5,"n":1e+21}'),
            ({"s": "line\nbreak\u0001"}, '{"s":"line\\nbreak\\u0001"}')]
    return [{"id": "canon-%d" % i, "rules": ["R-5"], "value": v, "expected": e} for i, (v, e) in enumerate(vals)]


def call_cases() -> list:
    cfg = dict(CFG, knownProcessors=[PROC])
    ident, rep, site = CFG["identityRegistry"], CFG["reputationRegistry"], CFG["siteRegistry"]
    cases = [
        ("call-register", ident, "0x8ea42286", False, True),
        ("call-put-file", site, "0xfab2ed82", False, True),
        ("call-give-feedback", rep, "0x3c036a7e", False, True),
        ("call-approve", "0x5ce033b2bfca3af30b3e8c8457deaf776a8b695a", "0x095ea7b3", False, False),
        ("call-set-approval-for-all", PROC, "0xa22cb465", False, False),
        ("call-transfer", "0x55d398326f99059ff775485246999027b3197955", "0xa9059cbb", False, False),
        ("call-transfer-from-identity", ident, "0x23b872dd", False, False),
        ("call-safe-transfer-from-circuit", PROC, "0x42842e0e", False, False),
        ("call-safe-transfer-from-data", PROC, "0xb88d4fde", False, False),
        ("call-container-execute", CONTAINER, "0x51945447", False, False),
        ("call-unknown-target", A(90), "0x12345678", False, False),
        ("call-from-counterparty-text", ident, "0x0af28bd3", True, False),
    ]
    out = []
    for cid, to, sel, txt, allowed in cases:
        out.append({"id": cid, "rules": ["W-3"], "to": to, "data": sel + "00" * 4, "fromCounterpartyText": txt,
                    "config": cfg, "expected": {"allowed": allowed}})
    return out


def delegation_cases() -> list:
    now = TS
    cs = [("deleg-7-days-default", now + 604_800, True, True, True),
          ("deleg-30-days-default", now + 2_592_000, True, True, True),
          ("deleg-366-days-default", now + 31_622_400, True, True, False),
          ("deleg-366-days-holder-choice", now + 31_622_400, False, True, True),
          ("deleg-367-days", now + 31_622_401, False, True, False),
          ("deleg-foreign-signer", now + 3600, True, False, False)]
    return [{"id": cid, "rules": ["W-1", "W-2"], "now": now, "expires": e, "isDefault": d, "signerGeneratedHere": g,
             "expected": {"ok": ok}} for cid, e, d, g, ok in cs]


SELECTORS = [
    ("register(string,(string,bytes)[])", "identity", True), ("register(string)", "identity", True), ("register()", "identity", True),
    ("setAgentURI(uint256,string)", "identity", True), ("setMetadata(uint256,string,bytes)", "identity", True),
    ("getMetadata(uint256,string)", "identity", True), ("getAgentWallet(uint256)", "identity", True),
    ("setAgentWallet(uint256,address,uint256,bytes)", "identity", True), ("unsetAgentWallet(uint256)", "identity", True),
    ("ownerOf(uint256)", "identity", True), ("tokenURI(uint256)", "identity", True),
    ("giveFeedback(uint256,int128,uint8,string,string,string,string,bytes32)", "reputation", True),
    ("revokeFeedback(uint256,uint64)", "reputation", True), ("getSummary(uint256,address[],string,string)", "reputation", True),
    ("putFile(address,string,string,bytes32,bytes)", "siteRegistry", True), ("appendChunk(address,string,uint256,bytes)", "siteRegistry", True),
    ("setOperator(address,address,uint256)", "siteRegistry", True), ("fileInfo(address,string)", "siteRegistry", True),
    ("read(address,string)", "siteRegistry", True), ("isCPU(address)", "factory", True), ("cpuAt(uint256)", "factory", True),
]
TOPICS = [("Transfer(address,address,uint256)", "ERC-721", False),
          ("OperatorSet(address,address,address,uint40)", "siteRegistry", True),
          ("AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)", "identity (EIP-712 type hash)", True)]


def interface_section() -> dict:
    sels = [{"signature": s, "selector": P.selector(s), "contract": c, "foundInDeployedBytecode": f} for s, c, f in SELECTORS]
    tops = [{"text": t, "keccak256": "0x" + keccak256(t.encode()).hex(), "where": c, "foundInDeployedBytecode": f} for t, c, f in TOPICS]
    return {"selectors": sels, "hashes": tops,
            "bytecodeCheck": {"identityImplementation": "0x7274e874ca62410a93bd8bf61c69d8045e399c02",
                              "reputationImplementation": "0x16e0fa7f7c56b9a767e34b192b51f921be31da34",
                              "siteRegistryImplementation": "0x1d279d138a4d803378a7d4557c056f1bed53c261",
                              "factoryImplementation": "0xa68ccf4931d98ad0a4be15ee40542edc0dec6422",
                              "blocks": {"identity-reputation": 129353333, "siteRegistry-factory": 129355254},
                              "method": "eth_getCode of the implementation; a selector is found when PUSH4 <selector> (or PUSH3 for a leading zero byte) occurs; a hash when its 32 bytes occur"}}


# ---------------------------------------------------------------------------
# Assembly
# ---------------------------------------------------------------------------
def check_case_resolution(c) -> None:
    res = P.resolve(c["snapshot"])
    exp = c["expected"]
    got = {"state": res["state"], "reasons": res["reasons"]}
    for k in ("warnings", "display", "agentId"):
        if k in exp:
            got[k] = res[k]
    if got != exp:
        raise SystemExit("case %s: expected %s, got %s" % (c["id"], exp, got))


def check_case_feedback(c) -> None:
    res = P.resolve(c["snapshot"])
    rep = P.summarise_feedback(c["snapshot"], res)
    exp = c["expected"]
    if not rep["computed"]:
        got = {"state": res["state"], "computed": False, "why": rep["why"]}
    else:
        got = {"state": res["state"], "counted": rep["counted"], "excluded": rep["excluded"],
               "getSummaryClientAddresses": rep["getSummaryClientAddresses"],
               "outsideClientSet": rep["outsideClientSet"], "earlierHolders": rep["earlierHolders"]}
        if "level-1" in exp:
            got["level-1"] = rep["summary"]["level-1"]
    if got != exp:
        raise SystemExit("case %s: expected %s, got %s" % (c["id"], exp, got))


def build() -> dict:
    res_cases = resolution_cases() + real_cases()
    fb = feedback_cases()
    for c in res_cases:
        check_case_resolution(c)
    for c in fb:
        check_case_feedback(c)
    keys = key_cases()
    for c in keys:
        try:
            d = P.decode_passport_key(bytes.fromhex(c["bytes"][2:]))
            got = {"ok": True, "chainId": d["chainId"], "processor": d["processor"], "tokenId": d["tokenId"]}
        except P.Broken as e:
            got = {"ok": False, "reason": e.reason}
        assert got == c["expected"], (c["id"], got)
    names = name_cases()
    for c in names:
        assert P.forbidden_name(c["name"]) == c["expected"]["forbidden"], c
    canon = canonical_cases()
    for c in canon:
        assert P.canonical_json(c["value"]) == c["expected"], (c, P.canonical_json(c["value"]))
    calls = call_cases()
    for c in calls:
        assert P.check_runtime_call(c["config"], c["to"], c["data"], c["fromCounterpartyText"])["allowed"] == c["expected"]["allowed"], c["id"]
    dels = delegation_cases()
    for c in dels:
        assert P.check_delegation_proposal(c["now"], c["expires"], c["isDefault"], c["signerGeneratedHere"])["ok"] == c["expected"]["ok"], c["id"]
    fparams = feedback_param_cases()
    total = len(res_cases) + len(fb) + len(keys) + len(names) + len(canon) + len(calls) + len(dels) + len(fparams)
    return {
        "format": FORMAT,
        "note": ("Synthetic chain state unless a case says source bsc-mainnet-read. Synthetic addresses are "
                 "keccak256('tap-agent-passport synthetic <n>')[12:] and belong to nobody. No transaction was sent."),
        "counts": {"resolution": len(res_cases), "feedback": len(fb), "passportKey": len(keys), "forbiddenNames": len(names),
                   "canonicalJson": len(canon), "runtimeCalls": len(calls), "delegationProposals": len(dels),
                   "feedbackParams": len(fparams), "total": total},
        "constants": {"reviewTypehash": P.REVIEW_TYPEHASH, "reviewType": P.REVIEW_TYPE, "registrationType": P.REG_TYPE,
                      "registrationKey": P.REG_KEY, "reviewDirKey": P.REVIEW_DIR_KEY, "tag1": P.REVIEW_TAG1,
                      "passportKeyName": P.PASSPORT_KEY,
                      "confusables": {"U+%04X" % ord(k): v for k, v in sorted(P._CONFUSABLE.items(), key=lambda kv: ord(kv[0]))}},
        "interfaces": interface_section(),
        "passportKey": keys,
        "forbiddenNames": names,
        "canonicalJson": canon,
        "resolution": res_cases,
        "feedback": fb,
        "feedbackParams": fparams,
        "runtimeCalls": calls,
        "delegationProposals": dels,
    }


def render(v: dict) -> bytes:
    return (json.dumps(v, indent=1, ensure_ascii=False, sort_keys=False) + "\n").encode("utf-8")


def main(argv) -> int:
    data = render(build())
    if "--check" in argv:
        with open(OUT, "rb") as f:
            same = f.read() == data
        print("vectors.json is %s" % ("up to date" if same else "OUT OF DATE"))
        return 0 if same else 1
    with open(OUT, "wb") as f:
        f.write(data)
    print("wrote vectors.json, %d bytes, sha256 %s" % (len(data), hashlib.sha256(data).hexdigest()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
