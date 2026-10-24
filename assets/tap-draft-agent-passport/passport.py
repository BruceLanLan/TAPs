# passport.py: read-only reference verifier for TAP-draft-agent-passport.
# Python 3.9+, standard library only (plus the vendored keccak.py in this folder). MIT License.
#
# Input: a JSON snapshot of chain reads made at one pinned block by several node operators, together
# with the site files those reads return (format "tap-agent-passport-snapshot/1", README.md).
# Output: a state word (CONFIRMED, BROKEN, AMBIGUOUS, wallet-unset, stale-agent-wallet, UNAVAILABLE),
# the reasons, warnings, the holder epoch and, when asked, the reputation summary of §10.
#
# The verifier never talks to a node. It applies the rules of the Specification to the answers it is
# given, so that every implementation can be checked against the same snapshots (vectors.json).
from __future__ import annotations

import hashlib
import json
import math
import os
import re
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keccak import keccak256  # noqa: E402

SNAPSHOT_FORMAT = "tap-agent-passport-snapshot/1"
PASSPORT_KEY = "tap.passport"
REG_KEY = ".well-known/agent-registration.json"      # SiteRegistry key of /.well-known/agent-registration.json
MANIFEST_KEY = ".well-known/tapeapi.json"            # TAP-11 §2.2 step 3
REVIEW_DIR_KEY = ".well-known/tapeapi-reviews/"      # one file per review (§10)
REG_TYPE = "https://eips.ethereum.org/EIPS/eip-8004#registration-v1"
MAX_REG_BYTES = 65536
MAX_PIN_LAG = {56: 400}                               # TAP-10 §2.1; this version defines chain 56 only
MAX_TOKEN_ID = 10 ** 18                               # TAP-10 §3.1
ZERO_ADDR = "0x" + "00" * 20
HUB = "0xe61a9c7213a6aa616c246a2b569e555b417b25ee"    # TAP-11 §1
REVIEW_TYPE = ("Review(bytes32 reviewer,bytes32 reviewee,uint8 kind,uint8 score,bytes32 subject,"
               "bytes32 evidenceHash,bytes32 textHash,uint64 issued)")
REVIEW_TYPEHASH = "0xb9c66a727a6fba79714dcc4f0dfdbaf876840b1a35de576ed8fe3eef1f1b9a0b"   # #54 §2.1
EIP712_DOMAIN_TYPE = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
REVIEW_TAG1 = "tap-review"
REVIEW_TAG2 = {"level-1": 1, "level-2": 2}
DEFAULT_DELEGATION_MAX_S = 2_592_000      # §9 W-1: a proposed default expiry is at most 30 days ahead
RECOMMENDED_DELEGATION_S = 604_800        # §9 W-1: SHOULD be at most 7 days
TAP11_MAX_DELEGATION_S = 31_622_400       # TAP-11 §4.3 (366 days)

STATES = ("CONFIRMED", "BROKEN", "AMBIGUOUS", "wallet-unset", "stale-agent-wallet", "UNAVAILABLE")

# Reason codes and the rule each one reports (Specification §6.3).
REASONS = {
    "wrong-chain": "P-6", "stale-block": "P-6", "node-disagreement": "P-6", "unavailable": "P-6",
    "registry-changed": "P-6", "store-changed": "P-6",
    "no-such-agent": "P-1", "holder-mismatch": "P-1",
    "no-passport-key": "P-2", "bad-passport-key": "P-2",
    "chain-mismatch": "P-3",
    "not-tapeout": "P-4", "no-such-token": "P-4",
    "not-opened": "P-5",
    "registration-file-missing": "P-7", "registration-file-too-large": "P-7",
    "registration-file-incomplete": "P-7", "registration-file-no-hash": "P-7",
    "registration-file-invalid": "P-7", "forbidden-name": "P-7", "file-chain-mismatch": "P-7",
    "tape-service-missing": "P-7",
    "stale-operator": "P-8",
    "wallet-unset": "P-9", "stale-agent-wallet": "P-9",
    "not-listed": "P-10", "several-listed": "P-10",
    "key-circuit-mismatch": "P-11",
}
WARNINGS = ("operators-not-checked", "agent-uri-not-canonical", "manifest-hash-differs",
            "holder-changed", "transfer-history-unavailable")


class Unavailable(Exception):
    def __init__(self, reason: str, key: str = ""):
        super().__init__(reason)
        self.reason, self.key = reason, key


class Broken(Exception):
    def __init__(self, reason: str, detail: str = ""):
        super().__init__(reason)
        self.reason, self.detail = reason, detail


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def addr(a: str) -> str:
    if not isinstance(a, str) or not re.fullmatch(r"0x[0-9a-fA-F]{40}", a):
        raise ValueError("bad address %r" % (a,))
    return a.lower()


def hx(b: bytes) -> str:
    return "0x" + b.hex()


def unhex(s: str) -> bytes:
    if not isinstance(s, str) or not s.startswith("0x") or len(s) % 2:
        raise ValueError("bad hex %r" % (s,))
    return bytes.fromhex(s[2:])


def word(b: bytes, i: int) -> bytes:
    return b[32 * i: 32 * i + 32]


def dec_uint(b: bytes, i: int = 0) -> int:
    w = word(b, i)
    if len(w) != 32:
        raise ValueError("short return data")
    return int.from_bytes(w, "big")


def dec_address(b: bytes, i: int = 0) -> str:
    w = word(b, i)
    if len(w) != 32 or any(w[:12]):
        raise ValueError("not an address word")
    return hx(w[12:])


def dec_bool(b: bytes, i: int = 0) -> bool:
    v = dec_uint(b, i)
    if v not in (0, 1):
        raise ValueError("not a bool")
    return v == 1


def dec_dyn(b: bytes, head_index: int) -> bytes:
    off = dec_uint(b, head_index)
    n = int.from_bytes(b[off: off + 32], "big")
    data = b[off + 32: off + 32 + n]
    if len(data) != n:
        raise ValueError("short dynamic value")
    return data


def dec_bytes(b: bytes) -> bytes:
    return dec_dyn(b, 0)


def dec_string(b: bytes) -> str:
    return dec_dyn(b, 0).decode("utf-8")


def dec_file_info(b: bytes) -> dict:
    # (uint32 size, string contentType, bytes32 sha256Hash, uint40 updatedAt, uint256 chunkCount), TAP-10 App. A
    return {"size": dec_uint(b, 0), "contentType": dec_dyn(b, 1).decode("utf-8", "replace"),
            "sha256": hx(word(b, 2)), "updatedAt": dec_uint(b, 3), "chunkCount": dec_uint(b, 4)}


def endpoint_id(chain_id: int, container: str) -> str:
    # TAP-10 §12.1: uint32(0) ‖ uint64(chainId) ‖ container
    return hx(b"\x00" * 4 + chain_id.to_bytes(8, "big") + unhex(addr(container)))


def selector(sig: str) -> str:
    return hx(keccak256(sig.encode())[:4])


# ---------------------------------------------------------------------------
# §4: the tap.passport key
# ---------------------------------------------------------------------------

def encode_passport_key(chain_id: int, processor: str, token_id: int) -> bytes:
    return chain_id.to_bytes(32, "big") + b"\x00" * 12 + unhex(addr(processor)) + token_id.to_bytes(32, "big")


def decode_passport_key(value: bytes) -> dict:
    """§4: exactly 96 bytes, abi.encode(uint256 chainId, address processor, uint256 tokenId)."""
    if len(value) == 0:
        raise Broken("no-passport-key")
    if len(value) != 96:
        raise Broken("bad-passport-key", "length %d, not 96" % len(value))
    chain_id = int.from_bytes(value[0:32], "big")
    if any(value[32:44]):
        raise Broken("bad-passport-key", "address word has non-zero high bytes")
    processor = hx(value[44:64])
    token_id = int.from_bytes(value[64:96], "big")
    if chain_id == 0 or chain_id > 2 ** 53 - 1:
        raise Broken("bad-passport-key", "chainId out of range")
    if processor == ZERO_ADDR:
        raise Broken("bad-passport-key", "zero processor")
    if not 1 <= token_id <= MAX_TOKEN_ID:
        raise Broken("bad-passport-key", "tokenId out of range")
    return {"chainId": chain_id, "processor": processor, "tokenId": token_id}


# ---------------------------------------------------------------------------
# TAP-11 §6 canonical JSON (RFC 8785) and strict parsing
# ---------------------------------------------------------------------------

class NoCanonicalForm(ValueError):
    pass


_PROTO = {"__proto__", "constructor", "prototype"}


def _pairs(pairs):
    out = {}
    for k, v in pairs:
        if k in out:
            raise NoCanonicalForm("repeated member %r" % k)
        if k in _PROTO:
            raise NoCanonicalForm("member named %r" % k)
        out[k] = v
    return out


def _pint(s: str):
    if s in ("-0",):
        raise NoCanonicalForm("negative zero")
    v = int(s)
    if abs(v) > 2 ** 53 - 1:
        raise NoCanonicalForm("integer beyond 2^53-1")
    return v


def _pfloat(s: str):
    v = float(s)
    if math.isinf(v) or math.isnan(v):
        raise NoCanonicalForm("non-finite number")
    if v == 0 and math.copysign(1.0, v) < 0:
        raise NoCanonicalForm("negative zero")
    if v.is_integer() and abs(v) > 2 ** 53 - 1:
        raise NoCanonicalForm("integer beyond 2^53-1")
    return v


def _pconst(s: str):
    raise NoCanonicalForm("non-finite number %s" % s)


def strict_json(data: bytes):
    """UTF-8, no BOM, RFC 8259 JSON; raises NoCanonicalForm or ValueError."""
    if data.startswith(b"\xef\xbb\xbf"):
        raise ValueError("byte order mark")
    text = data.decode("utf-8")
    value = json.loads(text, object_pairs_hook=_pairs, parse_int=_pint, parse_float=_pfloat,
                       parse_constant=_pconst)
    _check_surrogates(value)
    return value


def _check_surrogates(v):
    if isinstance(v, str):
        if any(0xD800 <= ord(c) <= 0xDFFF for c in v):
            raise NoCanonicalForm("unpaired surrogate")
    elif isinstance(v, dict):
        for k, x in v.items():
            _check_surrogates(k)
            _check_surrogates(x)
    elif isinstance(v, list):
        for x in v:
            _check_surrogates(x)


def _es_number(v) -> str:
    """ECMAScript Number::toString of a finite number (RFC 8785 §3.2.2.3)."""
    if isinstance(v, bool):
        raise TypeError("bool")
    if isinstance(v, int):
        return str(v)
    if v == 0:
        return "0"
    sign = "-" if v < 0 else ""
    r = repr(abs(v))                      # shortest round-trip digits
    mant, e = (r.split("e") + ["0"])[:2]
    e = int(e)
    ip, fp = (mant.split(".") + [""])[:2]
    s = ip + fp
    s1 = s.lstrip("0")
    n = len(ip) + e - (len(s) - len(s1))  # value = 0.digits * 10^n
    digits = s1.rstrip("0")
    k = len(digits)
    if k <= n <= 21:
        return sign + digits + "0" * (n - k)
    if 0 < n <= 21:
        return sign + digits[:n] + "." + digits[n:]
    if -6 < n <= 0:
        return sign + "0." + "0" * (-n) + digits
    ee = n - 1
    es = ("+" if ee >= 0 else "-") + str(abs(ee))
    return sign + digits[0] + ("." + digits[1:] if k > 1 else "") + "e" + es


def _es_string(s: str) -> str:
    out = ['"']
    for c in s:
        o = ord(c)
        if c == '"':
            out.append('\\"')
        elif c == "\\":
            out.append("\\\\")
        elif c == "\b":
            out.append("\\b")
        elif c == "\f":
            out.append("\\f")
        elif c == "\n":
            out.append("\\n")
        elif c == "\r":
            out.append("\\r")
        elif c == "\t":
            out.append("\\t")
        elif o < 0x20:
            out.append("\\u%04x" % o)
        else:
            out.append(c)
    out.append('"')
    return "".join(out)


def canonical_json(v) -> str:
    if v is None:
        return "null"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, (int, float)):
        return _es_number(v)
    if isinstance(v, str):
        return _es_string(v)
    if isinstance(v, list):
        return "[" + ",".join(canonical_json(x) for x in v) + "]"
    if isinstance(v, dict):
        keys = sorted(v.keys(), key=lambda k: k.encode("utf-16-be"))
        return "{" + ",".join(_es_string(k) + ":" + canonical_json(v[k]) for k in keys) + "}"
    raise TypeError("not a JSON value")


def canonical_bytes(v) -> bytes:
    return canonical_json(v).encode("utf-8")


# ---------------------------------------------------------------------------
# §5.4: forbidden member names inside the `tap` member
# ---------------------------------------------------------------------------

# Default_Ignorable_Code_Point (Unicode 15.1.0, DerivedCoreProperties.txt); it contains Bidi_Control.
_DEFAULT_IGNORABLE = [
    (0x00AD, 0x00AD), (0x034F, 0x034F), (0x061C, 0x061C), (0x115F, 0x1160), (0x17B4, 0x17B5),
    (0x180B, 0x180F), (0x200B, 0x200F), (0x202A, 0x202E), (0x2060, 0x206F), (0x3164, 0x3164),
    (0xFE00, 0xFE0F), (0xFEFF, 0xFEFF), (0xFFA0, 0xFFA0), (0xFFF0, 0xFFF8), (0x1BCA0, 0x1BCA3),
    (0x1D173, 0x1D17A), (0xE0000, 0xE0FFF),
]
# The confusable table of §5.4: Cyrillic and Greek letters that imitate Latin ones, chosen with reference to
# UTS #39 (Unicode 15.1.0). This table, not UTS #39 in full, decides `forbidden-name`; it is also written to
# vectors.json ("confusables") so that the specification, the vectors and this code cannot drift apart.
_CONFUSABLE = {
    "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "і": "i", "ј": "j",
    "ѕ": "s", "ԁ": "d", "ԛ": "q", "ԝ": "w", "һ": "h", "ӏ": "l", "к": "k", "м": "m", "т": "t",
    "в": "b", "н": "h", "ο": "o", "α": "a", "ρ": "p", "ε": "e", "ι": "i", "κ": "k", "ν": "v",
    "τ": "t", "υ": "u", "χ": "x", "β": "b",
}
FORBIDDEN_WORDS = (
    "price", "worth", "yield", "interest", "dividend", "revenue", "profit", "income", "share",
    "allocation", "allotment", "airdrop", "reward", "payout", "payment", "weight", "multiplier",
    "bonus", "boost", "score", "rating", "eligibility", "entitlement", "claimable", "vesting",
    "staking", "verified", "certified", "official",
    "空投", "奖励", "分配", "收益", "资格", "分红", "认证",
)
FORBIDDEN_SEGMENTS = ("point", "points", "rank", "tier", "stake", "apy", "apr", "bounty", "value")


def _ignorable(cp: int) -> bool:
    return any(a <= cp <= b for a, b in _DEFAULT_IGNORABLE)


def normalise_name(name: str) -> tuple:
    s = unicodedata.normalize("NFKC", name)
    s = "".join(c for c in s if not _ignorable(ord(c)) and unicodedata.category(c) not in ("Cc", "Mn", "Me"))
    s = "".join(_CONFUSABLE.get(c, _CONFUSABLE.get(c.lower(), c)) for c in s)
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", s)
    segs = [x.casefold() for x in re.split(r"[^0-9A-Za-zÀ-￿]+", s) if x]
    segs = [x for seg in segs for x in re.split(r"[^\w]+", seg) if x]
    return "".join(segs), segs


def forbidden_name(name: str) -> bool:
    joined, segs = normalise_name(name)
    if any(w in joined for w in FORBIDDEN_WORDS):
        return True
    words = set(FORBIDDEN_SEGMENTS)
    return joined in words or any(s in words for s in segs)


def _walk_names(v, path=""):
    if isinstance(v, dict):
        for k, x in v.items():
            yield path + "/" + k, k
            yield from _walk_names(x, path + "/" + k)
    elif isinstance(v, list):
        for i, x in enumerate(v):
            yield from _walk_names(x, "%s/%d" % (path, i))


# ---------------------------------------------------------------------------
# §5: the registration file
# ---------------------------------------------------------------------------

def check_tap_member(tap) -> None:
    """§5.3 schema of the `tap` member; raises Broken('registration-file-invalid'|'forbidden-name')."""
    if not isinstance(tap, dict):
        raise Broken("registration-file-invalid", "tap is not an object")
    for p, k in _walk_names(tap, "/tap"):
        if forbidden_name(k):
            raise Broken("forbidden-name", p)
    req = ("v", "chainId", "processor", "tokenId", "container")
    for k in req:
        if k not in tap:
            raise Broken("registration-file-invalid", "tap.%s missing" % k)
    if tap["v"] != 1 or isinstance(tap["v"], bool):
        raise Broken("registration-file-invalid", "tap.v is not 1")
    c = tap["chainId"]
    if not isinstance(c, int) or isinstance(c, bool) or not 1 <= c <= 2 ** 53 - 1:
        raise Broken("registration-file-invalid", "tap.chainId")
    for k in ("processor", "container"):
        if not isinstance(tap[k], str) or not re.fullmatch(r"0x[0-9a-fA-F]{40}", tap[k]):
            raise Broken("registration-file-invalid", "tap.%s" % k)
    t = tap["tokenId"]
    if not isinstance(t, str) or not re.fullmatch(r"[1-9][0-9]{0,18}", t) or int(t) > MAX_TOKEN_ID:
        raise Broken("registration-file-invalid", "tap.tokenId")
    if "manifest" in tap:
        m = tap["manifest"]
        if (not isinstance(m, dict) or m.get("path") != "/" + MANIFEST_KEY
                or not isinstance(m.get("sha256"), str) or not re.fullmatch(r"0x[0-9a-f]{64}", m["sha256"])):
            raise Broken("registration-file-invalid", "tap.manifest")


def parse_registration_file(data: bytes) -> dict:
    try:
        doc = strict_json(data)
        canonical_json(doc)
    except NoCanonicalForm as e:
        raise Broken("registration-file-invalid", "no canonical form: %s" % e)
    except (ValueError, UnicodeDecodeError) as e:
        raise Broken("registration-file-invalid", "not JSON: %s" % e)
    if not isinstance(doc, dict):
        raise Broken("registration-file-invalid", "top level is not an object")
    if doc.get("type") != REG_TYPE:
        raise Broken("registration-file-invalid", "type")
    if not isinstance(doc.get("registrations"), list) or not isinstance(doc.get("services"), list):
        raise Broken("registration-file-invalid", "registrations or services is not an array")
    check_tap_member(doc.get("tap"))
    return doc


def caip10(chain_id: int, a: str) -> str:
    return "eip155:%d:%s" % (chain_id, addr(a))


def listed_agent_ids(doc: dict, chain_id: int, registry: str) -> list:
    """P-10: agentIds the file lists for this registry (agentRegistry compared with the address case-insensitive)."""
    out = []
    want = caip10(chain_id, registry)
    for r in doc["registrations"]:
        if not isinstance(r, dict):
            continue
        ar = r.get("agentRegistry")
        if not isinstance(ar, str):
            continue
        m = re.fullmatch(r"eip155:([1-9][0-9]*):(0x[0-9a-fA-F]{40})", ar)
        if not m or "eip155:%s:%s" % (m.group(1), m.group(2).lower()) != want:
            continue
        aid = r.get("agentId")
        if isinstance(aid, bool):
            continue
        if isinstance(aid, int) and aid >= 0:
            out.append(aid)
        elif isinstance(aid, str) and re.fullmatch(r"0|[1-9][0-9]*", aid):
            out.append(int(aid))
    return out


def on_chain_name(token_id: int, processor_number: int) -> str:
    return "%d.%d.tape" % (token_id, processor_number)        # BNB Smart Chain form, TAP-10 §3.1


def gateway_label(token_id: int, processor_number: int) -> str:
    return "%d-%d" % (token_id, processor_number)             # TAP-10 §3.3


# ---------------------------------------------------------------------------
# §6.1: adopting reads under strict agreement at one pinned block
# ---------------------------------------------------------------------------

class Reads:
    def __init__(self, snap: dict):
        self.snap = snap
        self.ops = snap.get("operators") or {}
        self.need = max(2, min(3, len(self.ops)))
        self.used = []

    def get(self, key: str):
        answers = []
        common = self.snap.get("answers", {})
        for name in sorted(self.ops):
            own = self.ops[name].get("answers", {})
            a = own[key] if key in own else common.get(key)
            if a is not None:
                answers.append(a)
        self.used.append(key)
        for x in answers[1:]:
            if x != answers[0]:
                raise Unavailable("node-disagreement", key)
        if len(answers) < self.need:
            raise Unavailable("unavailable", key)
        return answers[0]

    def call(self, key: str):
        """An eth_call answer: returns bytes, or ('revert', data)."""
        a = self.get(key)
        if isinstance(a, dict) and "revert" in a:
            return ("revert", a["revert"])
        return unhex(a)


def _is_revert(x) -> bool:
    return isinstance(x, tuple) and x and x[0] == "revert"


# ---------------------------------------------------------------------------
# §6: resolution
# ---------------------------------------------------------------------------

def _fixed_reads(rd: Reads, cfg: dict) -> dict:
    chain = cfg["chainId"]
    cid = rd.get("eth_chainId")
    if int(cid, 16) != chain:
        raise Unavailable("wrong-chain", "eth_chainId")
    heads = [op.get("head") for op in rd.ops.values() if isinstance(op.get("head"), int)]
    pinned = rd.snap["pinnedBlock"]
    if not heads or max(heads) - pinned > MAX_PIN_LAG.get(chain, 400) or pinned > max(heads):
        raise Unavailable("stale-block", "pinnedBlock")
    block = rd.get("block")
    impl = "0x" + rd.get("implSlot:" + addr(cfg["identityRegistry"]))[-40:]
    if impl.lower() not in [addr(x) for x in cfg["identityImplementations"]]:
        raise Unavailable("registry-changed", "implSlot:" + addr(cfg["identityRegistry"]))
    simpl = "0x" + rd.get("implSlot:" + addr(cfg["siteRegistry"]))[-40:]
    if simpl.lower() not in [addr(x) for x in cfg["siteRegistryImplementations"]]:
        raise Unavailable("store-changed", "implSlot:" + addr(cfg["siteRegistry"]))
    return {"pinnedBlock": pinned, "blockHash": block["hash"], "timestamp": block["timestamp"]}


def _circuit(rd: Reads, cfg: dict, processor: str, token_id: int) -> dict:
    f, o = addr(cfg["factory"]), addr(cfg["opener"])
    r = rd.call("%s.isCPU(%s)" % (f, processor))
    if _is_revert(r) or not dec_bool(r):
        raise Broken("not-tapeout")
    r = rd.call("%s.ownerOf(%d)" % (processor, token_id))
    if _is_revert(r):
        raise Broken("no-such-token")
    holder = dec_address(r)
    container = dec_address(rd.call("%s.accountOf(%s,%d)" % (o, processor, token_id)))
    opened = dec_bool(rd.call("%s.isOpened(%s,%d)" % (o, processor, token_id)))
    if not opened:
        raise Broken("not-opened")
    i, number = 0, None
    while True:                               # TAP-10 §4.3 step 3: scan cpuAt(i) until found or revert
        r = rd.call("%s.cpuAt(%d)" % (f, i))
        if _is_revert(r):
            raise Broken("not-tapeout", "processor number not found")
        if dec_address(r) == processor:
            number = i
            break
        i += 1
    return {"holder": holder, "container": container, "processorNumber": number,
            "name": on_chain_name(token_id, number)}


def _read_file(rd: Reads, cfg: dict, container: str, key: str, missing: str, max_bytes: int):
    s = addr(cfg["siteRegistry"])
    info = dec_file_info(rd.call("%s.fileInfo(%s,%s)" % (s, container, key)))
    if info["chunkCount"] == 0:
        raise Broken(missing)
    if info["size"] > max_bytes:
        raise Broken(missing.replace("missing", "too-large"))
    data = dec_bytes(rd.call("%s.read(%s,%s)" % (s, container, key)))
    if len(data) != info["size"] or hx(hashlib.sha256(data).digest()) != info["sha256"]:
        if info["sha256"] == "0x" + "00" * 32:
            raise Broken(missing.replace("missing", "no-hash"))
        raise Broken(missing.replace("missing", "incomplete"))
    return data, info


def _operators(rd: Reads, cfg: dict, container: str, holder: str, ts: int, warnings: list) -> None:
    """P-8: every site operator active at the pinned block was set by the current holder."""
    recs = rd.get("logs.OperatorSet(%s)" % container)
    if isinstance(recs, dict) and recs.get("unavailable"):
        warnings.append("operators-not-checked")
        return
    latest = {}
    for r in recs:                            # in log order; a later record for the same operator replaces
        latest[addr(r["operator"])] = r
    for op, r in latest.items():
        if op == ZERO_ADDR or int(r["until"]) < ts:
            continue
        if addr(r["setBy"]) != holder:
            raise Broken("stale-operator", op)


def _epoch(rd: Reads, cfg: dict, agent_id: int, processor: str, token_id: int, holder: str, warnings: list):
    """§7: the holder epoch starts at the later of the last transfers of the two tokens."""
    ti = rd.get("logs.Transfer.identity(%d)" % agent_id)
    tc = rd.get("logs.Transfer.circuit(%s,%d)" % (processor, token_id))
    if (isinstance(ti, dict) and ti.get("unavailable")) or (isinstance(tc, dict) and tc.get("unavailable")):
        warnings.append("transfer-history-unavailable")
        return None
    last = []
    changed = False
    for lst in (ti, tc):
        if not lst or addr(lst[-1]["to"]) != holder:
            warnings.append("transfer-history-unavailable")
            return None
        t = lst[-1]
        last.append(int(t["block"]))
        if addr(t["from"]) != ZERO_ADDR:
            changed = True
    mint = int(ti[0]["block"]) if addr(ti[0]["from"]) == ZERO_ADDR else None
    if mint is None:                          # the identity's history must start at its registration (E-1)
        warnings.append("transfer-history-unavailable")
        return None
    ep = {"startBlock": max(last), "changed": changed, "identityRegisteredBlock": mint}
    if changed:
        warnings.append("holder-changed")
    return ep


def resolve(snap: dict) -> dict:
    if snap.get("format") != SNAPSHOT_FORMAT:
        raise ValueError("unknown snapshot format")
    cfg = snap["config"]
    chain = cfg["chainId"]
    registry = addr(cfg["identityRegistry"])
    rd = Reads(snap)
    res = {"state": None, "reasons": [], "warnings": [], "agentId": None, "holder": None,
           "processor": None, "tokenId": None, "container": None, "name": None,
           "pinnedBlock": snap.get("pinnedBlock"), "blockHash": None, "holderEpoch": None}
    warnings = res["warnings"]
    try:
        fixed = _fixed_reads(rd, cfg)
        res["blockHash"] = fixed["blockHash"]
        inp = snap["input"]
        if "circuit" in inp:
            # Input by circuit: chain first, then the holder's file names the identity (§6.2 step 2).
            processor = addr(inp["circuit"]["processor"])
            token_id = int(inp["circuit"]["tokenId"])
            c = _circuit(rd, cfg, processor, token_id)
            res.update(processor=processor, tokenId=str(token_id), holder=c["holder"],
                       container=c["container"], name=c["name"])
            data, _ = _read_file(rd, cfg, c["container"], REG_KEY, "registration-file-missing", MAX_REG_BYTES)
            doc = parse_registration_file(data)
            ids = listed_agent_ids(doc, chain, registry)
            if not ids:
                raise Broken("not-listed", "the holder's file lists no identity of this registry")
            if len(ids) > 1:
                res["agentId"] = [str(x) for x in ids]
                raise Broken("several-listed")
            agent_id = ids[0]
            input_circuit = (processor, token_id)
        else:
            agent_id = int(inp["agentId"])
            input_circuit = None
        res["agentId"] = str(agent_id)
        _by_agent(rd, cfg, agent_id, res, fixed, input_circuit)
    except Unavailable as e:
        res["state"] = "UNAVAILABLE"
        res["reasons"] = [e.reason]
        res["unavailableRead"] = e.key
    except Broken as e:
        res["state"] = "AMBIGUOUS" if e.reason == "several-listed" else (
            e.reason if e.reason in ("wallet-unset", "stale-agent-wallet") else "BROKEN")
        res["reasons"] = [e.reason]
        if e.detail:
            res["detail"] = e.detail
    res["display"] = display(res)
    return res


def _by_agent(rd: Reads, cfg: dict, agent_id: int, res: dict, fixed: dict, input_circuit=None) -> None:
    chain = cfg["chainId"]
    registry = addr(cfg["identityRegistry"])
    warnings = res["warnings"]
    # Chain before files (§6.2 step 3): identity, key, circuit, holder.
    r = rd.call("%s.ownerOf(%d)" % (registry, agent_id))
    if _is_revert(r):
        raise Broken("no-such-agent")
    owner = dec_address(r)
    meta = rd.call("%s.getMetadata(%d,%s)" % (registry, agent_id, PASSPORT_KEY))
    if _is_revert(meta):
        raise Broken("no-passport-key", "getMetadata reverted")
    key = decode_passport_key(dec_bytes(meta))                        # P-2
    if key["chainId"] != chain:                                      # P-3
        raise Broken("chain-mismatch", "tap.passport names chain %d" % key["chainId"])
    processor, token_id = key["processor"], key["tokenId"]
    if input_circuit is not None and (processor, token_id) != input_circuit:   # P-11
        raise Broken("key-circuit-mismatch", "the key names %s #%d, the input is %s #%d"
                     % (processor, token_id, input_circuit[0], input_circuit[1]))
    c = _circuit(rd, cfg, processor, token_id)                       # P-4, P-5
    res.update(processor=processor, tokenId=str(token_id), holder=c["holder"],
               container=c["container"], name=c["name"])
    if owner != c["holder"]:                                         # P-1
        raise Broken("holder-mismatch", "identity owner %s, circuit holder %s" % (owner, c["holder"]))
    wallet = dec_address(rd.call("%s.getAgentWallet(%d)" % (registry, agent_id)))
    uri_r = rd.call("%s.tokenURI(%d)" % (registry, agent_id))
    agent_uri = None if _is_revert(uri_r) else dec_string(uri_r)
    # Files (§6.2 step 4).
    data, _ = _read_file(rd, cfg, c["container"], REG_KEY, "registration-file-missing", MAX_REG_BYTES)
    doc = parse_registration_file(data)                              # P-7
    tap = doc["tap"]
    if (tap["chainId"] != chain or addr(tap["processor"]) != processor or int(tap["tokenId"]) != token_id
            or addr(tap["container"]) != c["container"]):
        raise Broken("file-chain-mismatch", "tap member differs from the chain")
    want = "tape://" + c["name"]
    if not any(isinstance(s, dict) and s.get("name") == "tape" and s.get("endpoint") == want
               for s in doc["services"]):
        raise Broken("tape-service-missing", want)
    _operators(rd, cfg, c["container"], c["holder"], fixed["timestamp"], warnings)   # P-8
    ids = listed_agent_ids(doc, chain, registry)                     # P-10
    if agent_id not in ids:
        raise Broken("not-listed", "the holder's file does not list agent %d" % agent_id)
    if len(ids) > 1:
        res["agentId"] = [str(x) for x in ids]
        raise Broken("several-listed")
    # Warnings that do not change the state.
    if agent_uri is None or not re.fullmatch(
            r"https://%s\.[A-Za-z0-9.-]+/\.well-known/agent-registration\.json"
            % re.escape(gateway_label(token_id, c["processorNumber"])), agent_uri):
        warnings.append("agent-uri-not-canonical")
    if "manifest" in tap:
        mi = dec_file_info(rd.call("%s.fileInfo(%s,%s)" % (addr(cfg["siteRegistry"]), c["container"], MANIFEST_KEY)))
        if mi["chunkCount"] == 0 or mi["sha256"] != tap["manifest"]["sha256"]:
            warnings.append("manifest-hash-differs")
    res["holderEpoch"] = _epoch(rd, cfg, agent_id, processor, token_id, c["holder"], warnings)
    if wallet == ZERO_ADDR:                                          # P-9
        raise Broken("wallet-unset")
    if wallet != c["holder"]:
        raise Broken("stale-agent-wallet", "agentWallet %s" % wallet)
    res["state"] = "CONFIRMED"
    res["agentWallet"] = wallet


# ---------------------------------------------------------------------------
# §12: display
# ---------------------------------------------------------------------------

DISPLAY_FORBIDDEN = ("verified agent", "certified", "official", "trusted", "✓", "✔", "✅")


def display(res: dict) -> str:
    s = res["state"]
    if s == "CONFIRMED":
        out = "TapeOut passport %s (container %s) for agent %s, confirmed at block %d" % (
            res["name"], res["container"], res["agentId"], res["pinnedBlock"])
        if "operators-not-checked" in res["warnings"]:
            out += "; site operators not checked"
        ep = res.get("holderEpoch")
        if ep is None:
            out += "; holder history not checked"
        else:
            out += "; identity registered at block %d" % ep["identityRegisteredBlock"]
        if ep is not None and ep["changed"]:
            out += "; holder changed at block %d: earlier reputation does not belong to the current holder" % ep["startBlock"]
        return out
    if s == "BROKEN":
        return "not a passport: %s" % res["reasons"][0]
    if s == "AMBIGUOUS":
        return "ambiguous: the holder's site lists several agent identities for this registry"
    if s == "wallet-unset":
        return "not confirmed: the agent wallet is unset (the identity changed hands); the holder can set it again"
    if s == "stale-agent-wallet":
        return "not confirmed: the agent wallet differs from the holder"
    return "could not verify: %s" % res["reasons"][0]


# ---------------------------------------------------------------------------
# §10: reviews as ERC-8004 feedback (conditional on #54 at a fixed commit)
# ---------------------------------------------------------------------------

def _b32(s) -> bytes:
    if not isinstance(s, str) or not re.fullmatch(r"0x[0-9a-f]{64}", s):
        raise ValueError("bytes32")
    return unhex(s)


def review_hash(review: dict) -> str:
    """#54 §2.1: EIP-712 digest in the TAP-11 §4.1 domain with chainId taken from `reviewer`."""
    reviewer = _b32(review["reviewer"])
    chain_id = int.from_bytes(reviewer[4:12], "big")
    for k in ("kind", "score", "issued"):
        if not isinstance(review[k], int) or isinstance(review[k], bool):
            raise ValueError(k)
    dom = keccak256(keccak256(EIP712_DOMAIN_TYPE.encode()) + keccak256(b"TapeAPI") + keccak256(b"1")
                    + chain_id.to_bytes(32, "big") + b"\x00" * 12 + unhex(HUB))
    sh = keccak256(unhex(REVIEW_TYPEHASH) + reviewer + _b32(review["reviewee"])
                   + review["kind"].to_bytes(32, "big") + review["score"].to_bytes(32, "big")
                   + _b32(review["subject"]) + _b32(review["evidenceHash"]) + _b32(review["textHash"])
                   + review["issued"].to_bytes(32, "big"))
    return hx(keccak256(b"\x19\x01" + dom + sh))


def review_file_key(rhash: str) -> str:
    return REVIEW_DIR_KEY + rhash + ".json"


def feedback_params(record: dict, agent_id: int, reviewer_name: str, gateway_domain: str, level: int) -> dict:
    """§10.2 W: the giveFeedback arguments for one #54 record."""
    data = canonical_bytes(record)
    rh = review_hash(record["review"])
    label = reviewer_name[:-len(".tape")].replace(".", "-")
    return {"agentId": agent_id, "value": record["review"]["score"], "valueDecimals": 0,
            "tag1": REVIEW_TAG1, "tag2": "level-%d" % level, "endpoint": "",
            "feedbackURI": "https://%s.%s/%s" % (label, gateway_domain, review_file_key(rh)),
            "feedbackHash": hx(keccak256(data)), "fileKey": review_file_key(rh), "fileBytes": data.decode()}


def summarise_feedback(snap: dict, res: dict) -> dict:
    """§10.3 F-0..F-10 over the feedback list of the snapshot. Only for a CONFIRMED passport (F-4)."""
    if res["state"] != "CONFIRMED":
        return {"computed": False, "why": "passport not confirmed"}
    cfg = snap["config"]
    rd = Reads(snap)
    chain = cfg["chainId"]
    agent_id = int(res["agentId"])
    me = endpoint_id(chain, res["container"])
    epoch = res.get("holderEpoch")
    verdicts = snap.get("review54", {})
    # F-0: a summary is computed over an explicit set of client addresses, named by whoever asks for it;
    # feedback from other addresses is never fetched or resolved, only counted.
    req = snap.get("summary") or {}
    named = {addr(x) for x in req.get("clientAddresses", [])}
    if not named:
        return {"computed": False, "why": "no-client-set"}
    cap = req.get("maxEntries")
    try:
        impl = "0x" + rd.get("implSlot:" + addr(cfg["reputationRegistry"]))[-40:]
        if impl.lower() not in [addr(x) for x in cfg["reputationImplementations"]]:
            return {"computed": False, "why": "registry-changed"}
        items = rd.get("logs.NewFeedback(%d)" % agent_id)
    except Unavailable as e:
        return {"computed": False, "why": e.reason}
    excluded, candidates = [], []
    outside, examined = 0, 0
    uri_re = re.compile(r"(?:https://([0-9-]+)\.[A-Za-z0-9.-]+|tape://([0-9.]+\.tape))/(\.well-known/tapeapi-reviews/(0x[0-9a-f]{64})\.json)")
    for fb in items:
        tag = "%s#%s" % (fb["client"], fb["index"])
        if fb["tag1"] != REVIEW_TAG1:                                  # F-1
            continue
        if addr(fb["client"]) not in named:                            # F-0: not fetched, only counted
            outside += 1
            continue
        examined += 1
        if cap is not None and examined > cap:                         # F-0: stopping early
            return {"computed": False, "why": "summary-truncated"}
        def out(reason):
            excluded.append({"feedback": tag, "reason": reason})
        if fb.get("revoked"):
            out("revoked"); continue                                   # F-8
        if fb["tag2"] not in REVIEW_TAG2:                              # F-2
            out("bad-tag2"); continue
        m = uri_re.fullmatch(fb["feedbackURI"])
        if not m:                                                      # F-3
            out("bad-uri"); continue
        label, name, key, fh = m.group(1), m.group(2), m.group(3), m.group(4)
        try:
            # The URI host names the reviewer's circuit; resolve it on chain (TAP-10 §4.2).
            nm = re.fullmatch(r"([1-9][0-9]*)[-.](0|[1-9][0-9]*)(?:\.tape)?", label or name)
            if not nm:
                out("bad-uri"); continue
            r_tid, r_num = int(nm.group(1)), int(nm.group(2))
            r = rd.call("%s.cpuAt(%d)" % (addr(cfg["factory"]), r_num))
            if _is_revert(r):
                out("bad-uri"); continue
            r_proc = dec_address(r)
            container = dec_address(rd.call("%s.accountOf(%s,%d)" % (addr(cfg["opener"]), r_proc, r_tid)))
            r = rd.call("%s.ownerOf(%d)" % (r_proc, r_tid))
            if _is_revert(r):
                out("bad-uri"); continue
            r_holder = dec_address(r)
            s = addr(cfg["siteRegistry"])
            info = dec_file_info(rd.call("%s.fileInfo(%s,%s)" % (s, container, key)))
            if info["chunkCount"] == 0:
                out("file-missing"); continue
            data = dec_bytes(rd.call("%s.read(%s,%s)" % (s, container, key)))
            if len(data) != info["size"] or hx(hashlib.sha256(data).digest()) != info["sha256"]:
                out("file-incomplete"); continue
            if hx(keccak256(data)) != fb["feedbackHash"]:
                out("hash-mismatch"); continue
            try:
                rec = strict_json(data)
            except (ValueError, NoCanonicalForm):
                out("not-canonical"); continue
            if canonical_bytes(rec) != data:
                out("not-canonical"); continue
            rv = rec.get("review") if isinstance(rec, dict) else None
            if not isinstance(rv, dict):
                out("not-a-review"); continue
            rh = review_hash(rv)
            if rh != fh:
                out("review-hash-mismatch"); continue
            if rv["reviewer"] != endpoint_id(chain, container):
                out("uri-not-reviewer"); continue
            if rv["reviewee"] != me:                                   # F-4
                out("wrong-reviewee"); continue
            if rv["kind"] != 1:
                out("withdrawal"); continue
            if fb["value"] != rv["score"] or fb["valueDecimals"] != 0:
                out("value-mismatch"); continue
            v = verdicts.get(rh)
            if not v or not v.get("counted"):                          # F-5
                out("not-counted"); continue
            if v.get("level") != REVIEW_TAG2[fb["tag2"]]:
                out("level-mismatch"); continue
            if addr(fb["client"]) != r_holder:                         # F-6
                out("client-not-reviewer-holder"); continue
            if epoch is None:
                out("epoch-unknown"); continue
            if int(fb["block"]) < epoch["startBlock"]:                  # F-7
                out("earlier-holder"); continue
            candidates.append({"reviewer": container, "holder": r_holder, "level": v["level"],
                               "score": rv["score"], "issued": rv["issued"], "reviewHash": rh, "feedback": tag})
        except Unavailable as e:
            out("unavailable:" + e.reason)
    best = {}
    for c in candidates:                                               # F-9: one per reviewer container
        k = c["reviewer"]
        if k not in best or (c["issued"], c["reviewHash"]) > (best[k]["issued"], best[k]["reviewHash"]):
            best[k] = c
    summary = {}
    for lvl in (1, 2):
        sel = [c for c in best.values() if c["level"] == lvl]
        summary["level-%d" % lvl] = {
            "reviewers": len({c["reviewer"] for c in sel}),
            "holders": len({c["holder"] for c in sel}),
            "scores": {str(s): sum(1 for c in sel if c["score"] == s) for s in range(1, 6)},
        }
    clients = sorted({c["holder"] for c in best.values()})
    return {"computed": True, "counted": sorted(c["feedback"] for c in best.values()),
            "excluded": excluded, "summary": summary, "outsideClientSet": outside,
            "earlierHolders": sum(1 for x in excluded if x["reason"] == "earlier-holder"),
            "getSummaryClientAddresses": clients if clients else None}


# ---------------------------------------------------------------------------
# §9: tools that request signatures or build calls
# ---------------------------------------------------------------------------

FORBIDDEN_SELECTORS = {
    "0x095ea7b3": "approve(address,uint256)",
    "0xa22cb465": "setApprovalForAll(address,bool)",
    "0xa9059cbb": "transfer(address,uint256)",
    "0x23b872dd": "transferFrom(address,address,uint256)",
    "0x42842e0e": "safeTransferFrom(address,address,uint256)",
    "0xb88d4fde": "safeTransferFrom(address,address,uint256,bytes)",
    "0x51945447": "execute(address,uint256,bytes,uint8)",
}


def check_runtime_call(cfg: dict, to: str, data: str, from_counterparty_text: bool = False) -> dict:
    """W-3: what a runtime driven by untrusted text may construct."""
    sel = data[:10].lower()
    if from_counterparty_text:
        return {"allowed": False, "why": "calldata derived from counterparty text"}
    if sel in FORBIDDEN_SELECTORS:
        return {"allowed": False, "why": "forbidden selector " + FORBIDDEN_SELECTORS[sel]}
    targets = {addr(cfg[k]) for k in ("identityRegistry", "reputationRegistry", "siteRegistry", "factory", "opener")}
    targets |= {addr(x) for x in cfg.get("knownProcessors", [])}
    if addr(to) not in targets:
        return {"allowed": False, "why": "target not listed"}
    return {"allowed": True, "why": ""}


def check_delegation_proposal(now: int, expires: int, is_default: bool, signer_generated_here: bool) -> dict:
    """W-1, W-2 on a TAP-11 delegation a tool is about to ask the holder to sign."""
    if not signer_generated_here:
        return {"ok": False, "why": "signer not generated by this tool in this session"}
    if not now < expires <= now + TAP11_MAX_DELEGATION_S:
        return {"ok": False, "why": "outside TAP-11 §4.3"}
    if is_default and expires - now > DEFAULT_DELEGATION_MAX_S:
        return {"ok": False, "why": "default expiry more than 30 days ahead"}
    if is_default and expires - now > RECOMMENDED_DELEGATION_S:
        return {"ok": True, "why": "default above the recommended 7 days"}
    return {"ok": True, "why": ""}


def main(argv):
    if len(argv) != 2:
        print("usage: python3 passport.py <snapshot.json>", file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as f:
        snap = json.load(f)
    res = resolve(snap)
    if snap.get("review54") is not None or snap.get("withReputation"):
        res["reputation"] = summarise_feedback(snap, res)
    print(json.dumps(res, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
