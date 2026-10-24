"""Reference implementation for the TAP draft "Policy Circuit Gate".

MIT licence. Pure Python 3.9+, standard library only, plus the files copied unchanged next to it:
  tapnft.py, tap02_reference.py  (TAP-721 core draft: tapnet/1 files, TAP-02 evaluator)
  credits.py, canon.py           (Design Credits draft: keccak-256, secp256k1 sign / recover)
Their SHA-256 digests are recorded in vectors.json (`vendored`) and checked by the tests.

Contents, in the order of the Specification:
  §2  policy circuits: pin convention, validity check of a policy file, result interpretation
  §3  spend requests: tables, canonical encoding of a request into the 128-bit request word
  §4  evaluation: one request (combinational or stateful) and the replay of a trace
  §5  bindings: EIP-712 `PolicyBinding` / `PolicyBindingRevocation` in the TAP-11 domain, checks
  §6  the `tap.policy` metadata members (policy token and subject record)
Network access is not implemented: callers pass the policy file, the binding and the trace.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

import credits
import tap02_reference as tap02
import tapnft

keccak256 = credits.keccak256

# ---------------------------------------------------------------- §2 policy circuits

CONVENTION = "tap-policy/1"
N_IN = 128
N_OUT = 8
MAX_POLICY_BYTES = 49_152          # the file size an L1 TAP-721 contract's storeNetlist accepts (TAP-721 core §8.2)

# Request word layout (bit positions, TAP-02 §5 packing: bit i = bit i mod 8 of byte i div 8).
AMOUNT_LO, AMOUNT_BITS = 0, 32
OVERFLOW_BIT = 32
ASSET_LO, ASSET_BITS = 40, 8
COUNTERPARTY_LO, COUNTERPARTY_BITS = 48, 8
KIND_LO, KIND_BITS = 56, 3
DAY_LO, DAY_BITS = 64, 16
HOUR_LO, HOUR_BITS = 80, 5
WEEKDAY_LO, WEEKDAY_BITS = 85, 3
RESERVED_RANGES = ((33, 40), (59, 64), (88, 128))   # [lo, hi) ranges that MUST be zero

KINDS = {0: "other", 1: "pay", 2: "fund", 3: "call", 4: "transfer"}   # 5..7 reserved

REASONS = {
    0: "none",
    1: "amount-over-limit",
    2: "period-limit-reached",
    3: "counterparty-not-allowed",
    4: "asset-not-allowed",
    5: "outside-time-window",
    6: "amount-overflow",
    7: "kind-not-allowed",
}
REASON_POLICY_DEFINED_LO = 64       # 64..127 are policy-defined; 8..63 reserved


class Invalid(ValueError):
    """Raised for any input this TAP says MUST be rejected. `code` is the problem name of the TAP."""

    def __init__(self, code: str, detail: str = ""):
        super().__init__(code if not detail else f"{code}: {detail}")
        self.code = code


@dataclass(frozen=True)
class PolicyInfo:
    metrics: tapnft.Metrics
    stateful: bool
    size: int

    def as_json(self) -> dict:
        return {**self.metrics.as_json(), "gates": self.metrics.gates, "stateful": self.stateful, "bytes": self.size,
                "convention": CONVENTION}


def check_policy_file(data: bytes, declared_stateful: bool | None = None) -> PolicyInfo:
    """§2.2: a policy circuit is a valid tapnet/1 file of at most MAX_POLICY_BYTES with nIn 128 and nOut 8."""
    if len(data) > MAX_POLICY_BYTES:
        raise Invalid("policy-too-large", f"{len(data)} bytes")
    try:
        m = tapnft.check_file(data)
    except tapnft.Invalid as e:
        raise Invalid("policy-invalid-file", str(e)) from None
    if (m.n_in, m.n_out) != (N_IN, N_OUT):
        raise Invalid("policy-bad-pins", f"nIn {m.n_in}, nOut {m.n_out}")
    stateful = m.latch > 0
    if declared_stateful is not None and declared_stateful != stateful:
        raise Invalid("policy-stateful-mismatch", f"file has {m.latch} latches, declared stateful={declared_stateful}")
    return PolicyInfo(m, stateful, len(data))


def policy_hash(data: bytes) -> bytes:
    return tapnft.netlist_hash(data)


def interpret(outputs: bytes) -> dict:
    """§2.3: the 8 output bits. Exactly 0x01 allows; bit 0 clear denies with the reason; anything else is an
    invalid result, which a gate treats as a denial."""
    b = outputs[0] if outputs else 0
    allow, reason = b & 1, b >> 1
    if allow and reason == 0:
        return {"verdict": "allow", "reason": 0}
    if not allow:
        return {"verdict": "deny", "reason": reason, "reasonName": reason_name(reason)}
    return {"verdict": "deny", "reason": reason, "reasonName": reason_name(reason), "invalidResult": True}


def reason_name(r: int) -> str:
    if r in REASONS:
        return REASONS[r]
    if r >= REASON_POLICY_DEFINED_LO:
        return "policy-defined"
    return "reserved"


# ---------------------------------------------------------------- §3 requests and the request word

ADDR_RE = re.compile(r"0x[0-9a-f]{40}")
HEX32_RE = re.compile(r"0x[0-9a-f]{64}")
DEC_RE = re.compile(r"0|[1-9][0-9]*")
MAX_CLASS = 255


def _addr(v, where: str) -> str:
    if not isinstance(v, str) or not ADDR_RE.fullmatch(v):
        raise Invalid("request-malformed", f"{where}: expected 0x + 40 lowercase hex digits")
    return v


def _dec(v, where: str, code: str = "request-malformed") -> int:
    if isinstance(v, bool) or not isinstance(v, (int, str)):
        raise Invalid(code, f"{where}: expected a non-negative decimal integer or string")
    if isinstance(v, str):
        if not DEC_RE.fullmatch(v):
            raise Invalid(code, f"{where}: bad decimal string")
        v = int(v)
    if v < 0:
        raise Invalid(code, f"{where}: negative")
    return v


def check_tables(tables) -> dict:
    """§3.1: the tables of a binding. Returns them normalised (classes as ints, amountUnit as int)."""
    if not isinstance(tables, dict) or set(tables) != {"amountUnit", "assets", "counterparties"}:
        raise Invalid("tables-malformed", "members must be exactly amountUnit, assets, counterparties")
    unit = _dec(tables["amountUnit"], "amountUnit", "tables-malformed")
    if unit < 1 or unit >= 1 << 256:
        raise Invalid("tables-malformed", "amountUnit must be in [1, 2^256)")
    out = {"amountUnit": unit, "assets": {}, "counterparties": {}}
    for name in ("assets", "counterparties"):
        t = tables[name]
        if not isinstance(t, dict):
            raise Invalid("tables-malformed", f"{name} must be an object")
        for k, c in t.items():
            if not ADDR_RE.fullmatch(k):
                raise Invalid("tables-malformed", f"{name}: key {k!r} is not a lowercase address")
            if isinstance(c, bool) or not isinstance(c, int) or not 1 <= c <= MAX_CLASS:
                raise Invalid("tables-malformed", f"{name}[{k}]: class must be an integer in [1, 255]")
            out[name][k] = c
    return out


def tables_hash(tables) -> bytes:
    """keccak256(utf8(canonicalJSON(tables))) over the tables as written (TAP-11 §6)."""
    check_tables(tables)
    return keccak256(canonical_json(tables).encode("utf-8"))


def check_request(req) -> dict:
    """§3.2: the request object. Returns it normalised."""
    if not isinstance(req, dict) or set(req) != {"amount", "asset", "counterparty", "kind", "ts"}:
        raise Invalid("request-malformed", "members must be exactly amount, asset, counterparty, kind, ts")
    amount = _dec(req["amount"], "amount")
    if amount >= 1 << 256:
        raise Invalid("request-malformed", "amount must be below 2^256")
    kind = req["kind"]
    if isinstance(kind, bool) or not isinstance(kind, int) or not 0 <= kind < (1 << KIND_BITS):
        raise Invalid("request-malformed", "kind must be an integer in [0, 7]")
    ts = _dec(req["ts"], "ts")
    if ts >= 1 << 64:
        raise Invalid("request-malformed", "ts must be below 2^64")
    return {"amount": amount, "asset": _addr(req["asset"], "asset"),
            "counterparty": _addr(req["counterparty"], "counterparty"), "kind": kind, "ts": ts}


def fields_of(req, tables) -> dict:
    """§3.3: the fields of the request word, before packing."""
    r, t = check_request(req), check_tables(tables)
    units = -(-r["amount"] // t["amountUnit"])          # ceil
    overflow = units >= 1 << AMOUNT_BITS
    day = r["ts"] // 86400
    return {
        "amount": (1 << AMOUNT_BITS) - 1 if overflow else units,
        "overflow": 1 if overflow else 0,
        "asset": t["assets"].get(r["asset"], 0),
        "counterparty": t["counterparties"].get(r["counterparty"], 0),
        "kind": r["kind"],
        "day": day % (1 << DAY_BITS),
        "hour": (r["ts"] // 3600) % 24,
        "weekday": (day + 3) % 7,                          # 1970-01-01 was a Thursday; Monday is 0
    }


def word_of_fields(f: dict) -> int:
    w = f["amount"] << AMOUNT_LO
    w |= f["overflow"] << OVERFLOW_BIT
    w |= f["asset"] << ASSET_LO
    w |= f["counterparty"] << COUNTERPARTY_LO
    w |= f["kind"] << KIND_LO
    w |= f["day"] << DAY_LO
    w |= f["hour"] << HOUR_LO
    w |= f["weekday"] << WEEKDAY_LO
    return w


def encode_request(req, tables) -> bytes:
    """§3.3: the 16-byte request word, packed as TAP-02 §5 (bit i of the word is bit i mod 8 of byte i div 8)."""
    return word_of_fields(fields_of(req, tables)).to_bytes(N_IN // 8, "little")


def decode_word(word: bytes) -> dict:
    """The fields of a 16-byte word (for display and for checking that reserved bits are zero)."""
    if len(word) != N_IN // 8:
        raise Invalid("word-malformed", f"{len(word)} bytes")
    w = int.from_bytes(word, "little")
    bits = lambda lo, n: (w >> lo) & ((1 << n) - 1)  # noqa: E731
    f = {"amount": bits(AMOUNT_LO, AMOUNT_BITS), "overflow": bits(OVERFLOW_BIT, 1), "asset": bits(ASSET_LO, ASSET_BITS),
         "counterparty": bits(COUNTERPARTY_LO, COUNTERPARTY_BITS), "kind": bits(KIND_LO, KIND_BITS),
         "day": bits(DAY_LO, DAY_BITS), "hour": bits(HOUR_LO, HOUR_BITS), "weekday": bits(WEEKDAY_LO, WEEKDAY_BITS)}
    for lo, hi in RESERVED_RANGES:
        if bits(lo, hi - lo):
            raise Invalid("word-reserved-bits", f"bits {lo}..{hi - 1} are not zero")
    return f


# ---------------------------------------------------------------- §4 evaluation

@dataclass
class Policy:
    data: bytes
    info: PolicyInfo
    circuit: tap02.Circuit = field(repr=False)

    @classmethod
    def load(cls, data: bytes, declared_stateful: bool | None = None) -> "Policy":
        info = check_policy_file(data, declared_stateful)
        _, _, records = tapnft.decode_file(data)
        return cls(data, info, tap02.load(records, N_IN, N_OUT))

    @property
    def n_state(self) -> int:
        return self.circuit.n_state

    def zero_state(self) -> bytes:
        return bytes((self.n_state + 7) // 8)

    def step(self, state: bytes, word: bytes) -> tuple[bytes, bytes]:
        """One beat: (newState, outputs), inputs and state read leniently, outputs exactly ceil(n/8) bytes."""
        ns, outs = tap02.beat(self.circuit, tap02.unpack(state, self.n_state), tap02.unpack(word, N_IN))
        return tap02.pack(ns), tap02.pack(outs)

    def eval(self, word: bytes) -> bytes:
        """`evalFile` semantics: combinational only."""
        if self.info.stateful:
            raise Invalid("policy-stateful", "evalFile is not defined for a netlist with LATCH records")
        return self.step(b"", word)[1]


def evaluate(policy: Policy, req, tables, state: bytes | None = None) -> dict:
    """§4.1: one request against one policy. For a stateful policy `state` is the gatekeeper's state (zero at the
    start of a trace); the result carries `newState`."""
    word = encode_request(req, tables)
    if policy.info.stateful:
        st = policy.zero_state() if state is None else state
        ns, outs = policy.step(st, word)
        return {"word": "0x" + word.hex(), **interpret(outs), "outputs": "0x" + outs.hex(), "newState": "0x" + ns.hex()}
    outs = policy.eval(word)
    return {"word": "0x" + word.hex(), **interpret(outs), "outputs": "0x" + outs.hex()}


def replay(policy: Policy, tables, entries: list, not_before: int | None = None, expires: int | None = None,
           escrow_cumulative: bool = False) -> dict:
    """§4.2: replay a trace from the zero state. Each entry is {"request": {...}} or, when `escrow_cumulative`,
    {"request": {... without amount ...}, "cumulative": n}; the amount is then the increase over the last
    *allowed* cumulative (0 before any). Entries MUST have non-decreasing `ts`, inside [notBefore, expires] when
    given. An entry MAY carry the gatekeeper's recorded `verdict`; a disagreement is `trace-mismatch`.
    Returns per-entry results and the final state; raises Invalid on the first malformed entry."""
    state = policy.zero_state() if policy.info.stateful else b""
    last_ts, last_cum, out = -1, 0, []
    for i, e in enumerate(entries):
        if not isinstance(e, dict) or "request" not in e:
            raise Invalid("trace-malformed", f"entry {i}")
        req = dict(e["request"])
        if escrow_cumulative:
            if "amount" in req or "cumulative" not in e:
                raise Invalid("trace-malformed", f"entry {i}: escrow entries carry cumulative, not amount")
            cum = _dec(e["cumulative"], f"entry {i}: cumulative", "trace-malformed")
            if cum < last_cum:
                raise Invalid("trace-cumulative-decreases", f"entry {i}")
            req["amount"] = cum - last_cum
        r = check_request(req)
        if r["ts"] < last_ts:
            raise Invalid("trace-not-monotone", f"entry {i}: ts {r['ts']} < {last_ts}")
        if not_before is not None and r["ts"] < not_before:
            raise Invalid("trace-before-binding", f"entry {i}")
        if expires is not None and r["ts"] > expires:
            raise Invalid("trace-after-binding", f"entry {i}")
        res = evaluate(policy, req, tables, state if policy.info.stateful else None)
        if policy.info.stateful:
            state = bytes.fromhex(res["newState"][2:])
        if "verdict" in e and e["verdict"] != res["verdict"]:
            raise Invalid("trace-mismatch", f"entry {i}: recorded {e['verdict']}, computed {res['verdict']}")
        if escrow_cumulative:
            res["amount"] = str(req["amount"])
            if res["verdict"] == "allow":
                last_cum = cum
        last_ts = r["ts"]
        out.append(res)
    return {"results": out, "finalState": "0x" + state.hex() if policy.info.stateful else None,
            "allowed": sum(1 for r in out if r["verdict"] == "allow")}


# ---------------------------------------------------------------- §5 bindings (EIP-712, TAP-11 §4.1 domain)

HUB = "0xe61a9c7213a6aa616c246a2b569e555b417b25ee"
DOMAIN_NAME, DOMAIN_VERSION = "TapeAPI", "1"

BINDING_TYPE = ("PolicyBinding(bytes32 netlistHash,uint8 subjectKind,bytes32 subject,bytes32 tablesHash,"
                "uint64 notBefore,uint64 expires,uint64 issued)")
REVOCATION_TYPE = "PolicyBindingRevocation(bytes32[] bindingHashes,uint64 revokedBefore,uint64 issued)"
BINDING_FIELDS = (("netlistHash", "bytes32"), ("subjectKind", "uint8"), ("subject", "bytes32"),
                  ("tablesHash", "bytes32"), ("notBefore", "uint64"), ("expires", "uint64"), ("issued", "uint64"))
REVOCATION_FIELDS = (("bindingHashes", "bytes32[]"), ("revokedBefore", "uint64"), ("issued", "uint64"))
BINDING_TYPEHASH = keccak256(BINDING_TYPE.encode())
REVOCATION_TYPEHASH = keccak256(REVOCATION_TYPE.encode())
MAX_REVOKED_HASHES = 24

SUBJECT_MANDATE, SUBJECT_ESCROW_SESSION, SUBJECT_ACCOUNT, SUBJECT_LABEL = 1, 2, 3, 4
SUBJECT_KINDS = {SUBJECT_MANDATE: "mandate", SUBJECT_ESCROW_SESSION: "escrow-session",
                 SUBJECT_ACCOUNT: "account", SUBJECT_LABEL: "label"}


def domain_separator(chain_id: int) -> bytes:
    return keccak256(
        keccak256(b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
        + keccak256(DOMAIN_NAME.encode()) + keccak256(DOMAIN_VERSION.encode())
        + chain_id.to_bytes(32, "big") + bytes(12) + bytes.fromhex(HUB[2:]))


def _hex32(v, where: str, code: str) -> bytes:
    if not isinstance(v, str) or not HEX32_RE.fullmatch(v):
        raise Invalid(code, f"{where}: expected 0x + 64 lowercase hex digits")
    return bytes.fromhex(v[2:])


def _u(v, bits: int, where: str, code: str) -> int:
    n = _dec(v, where, code)
    if n >= 1 << bits:
        raise Invalid(code, f"{where}: above 2^{bits}")
    return n


def _enc(ft: str, v, where: str, code: str) -> bytes:
    if ft == "bytes32":
        return _hex32(v, where, code)
    if ft == "bytes32[]":
        if not isinstance(v, list):
            raise Invalid(code, f"{where}: expected an array")
        return keccak256(b"".join(_hex32(x, f"{where}[{i}]", code) for i, x in enumerate(v)))
    return _u(v, int(ft[4:]), where, code).to_bytes(32, "big")


def struct_hash(fields, typehash: bytes, m: dict, code: str) -> bytes:
    if not isinstance(m, dict) or set(m) != {n for n, _ in fields}:
        raise Invalid(code, f"members must be exactly {[n for n, _ in fields]}")
    return keccak256(typehash + b"".join(_enc(ft, m[n], n, code) for n, ft in fields))


def binding_hash(chain_id: int, b: dict) -> bytes:
    """The digest of a PolicyBinding; it is the binding's identity (`bindingHash`)."""
    return keccak256(b"\x19\x01" + domain_separator(chain_id) + struct_hash(BINDING_FIELDS, BINDING_TYPEHASH, b, "binding-malformed"))


def revocation_hash(chain_id: int, r: dict) -> bytes:
    return keccak256(b"\x19\x01" + domain_separator(chain_id) + struct_hash(REVOCATION_FIELDS, REVOCATION_TYPEHASH, r, "revocation-malformed"))


def subject_mandate(mandate_hash: str) -> str:
    return mandate_hash


def subject_escrow_session(escrow: str, consumer: str, provider: str, key: str) -> str:
    parts = b"".join(bytes.fromhex(_addr(a, "subject")[2:]) for a in (escrow, consumer, provider, key))
    return "0x" + keccak256(parts).hex()


def subject_account(account: str) -> str:
    return "0x" + "00" * 12 + _addr(account, "subject")[2:]


def subject_label(label: str) -> str:
    return "0x" + keccak256(label.encode("utf-8")).hex()


def check_binding_form(b: dict) -> None:
    """§5.2 static rules."""
    struct_hash(BINDING_FIELDS, BINDING_TYPEHASH, b, "binding-malformed")
    kind = _u(b["subjectKind"], 8, "subjectKind", "binding-malformed")
    if kind not in SUBJECT_KINDS:
        raise Invalid("binding-unknown-subject-kind", str(kind))
    if kind == SUBJECT_ACCOUNT and not b["subject"].startswith("0x" + "00" * 12):
        raise Invalid("binding-malformed", "an account subject is left-padded with 12 zero bytes")
    if int(b["netlistHash"], 16) == 0 or int(b["subject"], 16) == 0:
        raise Invalid("binding-malformed", "netlistHash and subject are non-zero")
    nb, ex, iss = (_u(b[k], 64, k, "binding-malformed") for k in ("notBefore", "expires", "issued"))
    if ex <= nb:
        raise Invalid("binding-window-empty", f"expires {ex} <= notBefore {nb}")
    if iss > ex:
        raise Invalid("binding-issued-after-expiry")


def check_binding(chain_id: int, b: dict, sig: str | None, tables, *, now: int, policy_file: bytes | None = None,
                  expected_signer: str | None = None, declared_stateful: bool | None = None,
                  revocations: list | None = None) -> dict:
    """§5.3: check a binding. Returns {"bindingHash", "signer", "subjectKind", "status", "problems", "binderChecked",
    "fileChecked", "displayOnly", "enforceable"}; `enforceable` is always False for a `label`; otherwise None when the
    binder was not checked; otherwise False when there is a problem or the policy file was not checked (fail closed,
    §7); otherwise "conditional" for kinds 1 and 2 (fixed in this version, §0.1) and True for kind 3. `expected_signer` is
    the binder the subject kind names (§5.1), read by the caller (for kind 3, the holder of the circuit whose container
    is the subject account); without it the signature is only recovered. A kind-3 binding recovered to the subject
    account itself is `binding-self-signed` whatever `expected_signer` says. EIP-1271 binders (§5.3 item 2) are not
    implemented here. Problems are reported in the order of §5.3; a form problem stops the check (raises Invalid)."""
    check_binding_form(b)
    h = binding_hash(chain_id, b)
    problems, signer = [], None
    if sig is not None:
        try:
            signer = credits.recover(h, bytes.fromhex(sig[2:]) if isinstance(sig, str) else sig)
        except credits.SigError as e:
            problems.append("signature-" + e.code)
        else:
            if int(b["subjectKind"]) == SUBJECT_ACCOUNT and signer == "0x" + b["subject"][26:]:
                problems.append("binding-self-signed")   # §5.1: the subject account never binds itself
            if expected_signer is not None and signer != expected_signer.lower():
                problems.append("not-signed-by-binder")
    else:
        problems.append("binding-unsigned")
    try:
        th = tables_hash(tables)
    except Invalid as e:
        problems.append(e.code)
    else:
        if th.hex() != b["tablesHash"][2:]:
            problems.append("tables-hash-mismatch")
    if policy_file is not None:
        try:
            check_policy_file(policy_file, declared_stateful)
        except Invalid as e:
            problems.append(e.code)
        if policy_hash(policy_file).hex() != b["netlistHash"][2:]:
            problems.append("policy-hash-mismatch")
    nb, ex = int(b["notBefore"]), int(b["expires"])
    if now < nb:
        problems.append("binding-not-yet")
    elif now > ex:
        problems.append("binding-expired")
    if revocations and signer is not None:
        for r in revocations:
            if r.get("signer", "").lower() == signer and revocation_covers(r["revocation"], "0x" + h.hex(), int(b["issued"])):
                problems.append("binding-revoked")
                break
    kind = int(b["subjectKind"])
    binder_checked = expected_signer is not None
    file_checked = policy_file is not None
    if kind == SUBJECT_LABEL:
        enforceable = False                      # §5.1: a label binding is display only, whoever signed it
    elif not binder_checked:
        enforceable = None                       # §5.3: a verifier that did not check the binder reports no enforcement
    elif problems or not file_checked:
        enforceable = False                      # a problem, or no checked file (§5.3, §7): fail closed
    elif kind in (SUBJECT_MANDATE, SUBJECT_ESCROW_SESSION):
        enforceable = "conditional"              # §0.1: fixed for kinds 1 and 2 in this version of the TAP
    else:
        enforceable = True
    return {"bindingHash": "0x" + h.hex(), "signer": signer, "subjectKind": SUBJECT_KINDS[kind],
            "status": "ok" if not problems else "problems", "problems": problems,
            "binderChecked": binder_checked, "fileChecked": file_checked, "displayOnly": kind == SUBJECT_LABEL,
            "enforceable": enforceable}


def check_revocation_form(r: dict) -> None:
    struct_hash(REVOCATION_FIELDS, REVOCATION_TYPEHASH, r, "revocation-malformed")
    if len(r["bindingHashes"]) > MAX_REVOKED_HASHES:
        raise Invalid("revocation-too-many-hashes")
    if any(int(x, 16) == 0 for x in r["bindingHashes"]):
        raise Invalid("revocation-malformed", "zero hash")
    _u(r["revokedBefore"], 64, "revokedBefore", "revocation-malformed")
    _u(r["issued"], 64, "issued", "revocation-malformed")


def revocation_covers(r: dict, binding_hash_hex: str, issued: int) -> bool:
    """§5.4: a revocation covers a binding when its hash is listed or the binding was issued before `revokedBefore`."""
    check_revocation_form(r)
    return binding_hash_hex in r["bindingHashes"] or issued < int(r["revokedBefore"])


def sign_binding(chain_id: int, b: dict, priv: int) -> str:
    return "0x" + credits.sign(priv, binding_hash(chain_id, b)).hex()


def sign_revocation(chain_id: int, r: dict, priv: int) -> str:
    return "0x" + credits.sign(priv, revocation_hash(chain_id, r)).hex()


# ---------------------------------------------------------------- §6 metadata members

def check_token_policy_member(tap: dict) -> dict:
    """§6.1: `tap.policy` of a policy token's metadata: {"convention": "tap-policy/1", "stateful": bool,
    optional "reasons": {"64".."127": short text}}. Returns the member."""
    p = tap.get("policy") if isinstance(tap, dict) else None
    if not isinstance(p, dict):
        raise Invalid("policy-member-missing")
    if set(p) - {"convention", "stateful", "reasons"} or not {"convention", "stateful"} <= set(p):
        raise Invalid("policy-member-malformed", "members are convention, stateful and optionally reasons")
    if p["convention"] != CONVENTION:
        raise Invalid("policy-unknown-convention", repr(p["convention"]))
    if not isinstance(p["stateful"], bool):
        raise Invalid("policy-member-malformed", "stateful must be a boolean")
    if "reasons" in p:
        if not isinstance(p["reasons"], dict):
            raise Invalid("policy-member-malformed", "reasons must be an object")
        for k, v in p["reasons"].items():
            if not DEC_RE.fullmatch(k) or not REASON_POLICY_DEFINED_LO <= int(k) <= 127:
                raise Invalid("policy-member-malformed", f"reason code {k!r} is not in [64, 127]")
            if not isinstance(v, str) or not 1 <= len(v.encode()) <= 64:
                raise Invalid("policy-member-malformed", f"reason {k}: text of 1..64 bytes")
    n = tap.get("netlist")
    if isinstance(n, dict) and ("nIn" in n or "nOut" in n) and (n.get("nIn"), n.get("nOut")) != (N_IN, N_OUT):
        raise Invalid("policy-bad-pins", "tap.netlist pins")
    if isinstance(n, dict) and "latch" in n and (n["latch"] > 0) != p["stateful"]:
        raise Invalid("policy-stateful-mismatch", "tap.netlist.latch")
    return p


def check_subject_policy_member(m: dict) -> dict:
    """§6.2: `tap.policy` of a subject record: {"chainId", "binding": PolicyBinding JSON, "sig", "tables",
    "policy": {"chainId", "contract", "tokenId"} (optional: where the policy token is)}. Form only; the binding
    itself is checked with check_binding."""
    if not isinstance(m, dict) or not {"chainId", "binding", "sig", "tables"} <= set(m) \
            or set(m) - {"chainId", "binding", "sig", "tables", "policy"}:
        raise Invalid("policy-member-malformed", "members are chainId, binding, sig, tables and optionally policy")
    _u(m["chainId"], 64, "chainId", "policy-member-malformed")
    check_binding_form(m["binding"])
    if not isinstance(m["sig"], str) or not re.fullmatch(r"0x[0-9a-f]{130}", m["sig"]):
        raise Invalid("policy-member-malformed", "sig is 0x + 130 lowercase hex digits")
    check_tables(m["tables"])
    if "policy" in m:
        p = m["policy"]
        if not isinstance(p, dict) or set(p) != {"chainId", "contract", "tokenId"}:
            raise Invalid("policy-member-malformed", "policy has chainId, contract, tokenId")
        _u(p["chainId"], 64, "policy.chainId", "policy-member-malformed")
        _addr(p["contract"], "policy.contract")
        _u(p["tokenId"], 256, "policy.tokenId", "policy-member-malformed")
    return m


# ---------------------------------------------------------------- canonical JSON (TAP-11 §6, integers only)

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
    """RFC 8785 for the value kinds this TAP signs: null, booleans, integers up to 2^53 - 1, strings, arrays,
    objects. Non-integer numbers do not occur in bindings or tables and are rejected here."""
    if v is None:
        return "null"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, int):
        if abs(v) > (1 << 53) - 1:
            raise Invalid("canonical-json", "integer above 2^53 - 1")
        return str(v)
    if isinstance(v, float):
        if v != v or v in (float("inf"), float("-inf")) or not v.is_integer():
            raise Invalid("canonical-json", "non-integer number")
        return canonical_json(int(v))
    if isinstance(v, str):
        for ch in v:
            if 0xD800 <= ord(ch) <= 0xDFFF:
                raise Invalid("canonical-json", "unpaired surrogate")
        return _es_string(v)
    if isinstance(v, list):
        return "[" + ",".join(canonical_json(x) for x in v) + "]"
    if isinstance(v, dict):
        for k in v:
            if k in ("__proto__", "constructor", "prototype"):
                raise Invalid("canonical-json", f"forbidden member name {k}")
        keys = sorted(v.keys(), key=lambda k: k.encode("utf-16-be"))
        return "{" + ",".join(_es_string(k) + ":" + canonical_json(v[k]) for k in keys) + "}"
    raise Invalid("canonical-json", "not a JSON value")
