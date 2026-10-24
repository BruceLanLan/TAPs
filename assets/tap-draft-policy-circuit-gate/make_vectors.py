"""Write vectors.json for the TAP draft "Policy Circuit Gate" (deterministic).

MIT licence. `python3 make_vectors.py` writes vectors.json; `--check` compares instead and exits 1 on a difference.
All private keys are public test keys: keccak256("tap-policy-gate test key <n>"). Never use them.
No chain was read and no transaction was sent; every value here is synthetic.
"""
from __future__ import annotations

import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # sibling modules, also under python3 -I

import credits
import examples as ex
import policy_gate as pg

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "vectors.json")
VENDORED = ("tapnft.py", "tap02_reference.py", "credits.py", "canon.py")

CHAIN = 56
A = lambda b: "0x" + (b * 20)  # noqa: E731
ASSET_U, ASSET_V, ASSET_X = A("aa"), A("bb"), A("cc")
P1, P2, P3, PX = A("11"), A("22"), A("33"), A("44")
TABLES = {"amountUnit": "1000000000000000", "assets": {ASSET_U: 1, ASSET_V: 2}, "counterparties": {P1: 1, P2: 2, P3: 3}}
UNIT = 10 ** 15


def key(n: int) -> int:
    return int.from_bytes(credits.keccak256(f"tap-policy-gate test key {n}".encode()), "big")


KEYS = {n: key(n) for n in (1, 2, 3)}
ADDR = {n: credits.address_of_key(k) for n, k in KEYS.items()}
HOLDER, OTHER, CONSUMER = ADDR[1], ADDR[2], ADDR[3]

# times (UTC): Saturday 2026-10-24 12:00:00 = 1792843200 ; Monday 2026-10-26 10:00:00 = 1793008800
SAT_NOON = 1792843200
MON_10 = 1793008800
DAY = 86400


def req(amount, asset=ASSET_U, cp=P1, kind=1, ts=MON_10) -> dict:
    return {"amount": str(amount), "asset": asset, "counterparty": cp, "kind": kind, "ts": ts}


def outcome(fn):
    try:
        return {"result": fn()}
    except pg.Invalid as e:
        return {"error": e.code}


def hx(b: bytes) -> str:
    return "0x" + b.hex()


def build() -> dict:
    policies = ex.build_all()
    files = {n: d for n, ((d, _), _) in policies.items()}
    v = {"format": "tap-draft-policy-circuit-gate/vectors/1", "generator": "make_vectors.py",
         "note": "Synthetic. Test keys only. No chain read, no transaction sent."}

    v["vendored"] = {}
    for name in VENDORED:
        with open(os.path.join(HERE, name), "rb") as fh:
            v["vendored"][name] = hashlib.sha256(fh.read()).hexdigest()

    # ---- constants (§2, §3, §5)
    v["constants"] = {
        "convention": pg.CONVENTION, "nIn": pg.N_IN, "nOut": pg.N_OUT, "maxPolicyBytes": pg.MAX_POLICY_BYTES,
        "wordLayout": {"amount": [pg.AMOUNT_LO, pg.AMOUNT_BITS], "overflow": [pg.OVERFLOW_BIT, 1],
                       "asset": [pg.ASSET_LO, pg.ASSET_BITS], "counterparty": [pg.COUNTERPARTY_LO, pg.COUNTERPARTY_BITS],
                       "kind": [pg.KIND_LO, pg.KIND_BITS], "day": [pg.DAY_LO, pg.DAY_BITS], "hour": [pg.HOUR_LO, pg.HOUR_BITS],
                       "weekday": [pg.WEEKDAY_LO, pg.WEEKDAY_BITS], "reservedZero": [list(r) for r in pg.RESERVED_RANGES]},
        "kinds": pg.KINDS, "reasons": pg.REASONS, "policyDefinedReasons": [pg.REASON_POLICY_DEFINED_LO, 127],
        "domain": {"name": pg.DOMAIN_NAME, "version": pg.DOMAIN_VERSION, "verifyingContract": pg.HUB},
        "domainSeparator": {str(c): hx(pg.domain_separator(c)) for c in (56, 97, 31337)},
        "bindingType": pg.BINDING_TYPE, "bindingTypehash": hx(pg.BINDING_TYPEHASH),
        "revocationType": pg.REVOCATION_TYPE, "revocationTypehash": hx(pg.REVOCATION_TYPEHASH),
        "subjectKinds": pg.SUBJECT_KINDS, "maxRevokedHashes": pg.MAX_REVOKED_HASHES,
    }

    # ---- policies (§2): the examples and rejected files
    v["policies"] = {}
    for name, ((data, _), params) in policies.items():
        info = pg.check_policy_file(data)
        v["policies"][name] = {"file": "policies/" + name + ".tapnet", "params": params, "sha256": hx(pg.policy_hash(data)),
                               **info.as_json(), "stateBytes": (info.metrics.latch + 7) // 8,
                               "hex": data.hex() if len(data) <= 2048 else None}

    def nand_chain(n_in, n_out, n):
        recs = bytearray()
        prev = 2 + n_in - 1 if n_in else 1
        for _ in range(n):
            recs += b"\x00" + prev.to_bytes(3, "big") + prev.to_bytes(3, "big")
            prev += 1
        return bytes(recs)

    big = pg.tapnft._encode_unchecked(nand_chain(128, 8, 7100), 128, 8)   # 49,716 bytes, valid tapnet/1 but too large
    bad_files = [
        ("wrong-nIn", pg.tapnft.encode_file(nand_chain(64, 8, 8), 64, 8), None),
        ("wrong-nOut", pg.tapnft.encode_file(nand_chain(128, 1, 8), 128, 1), None),
        ("too-large", big, None),
        ("ref-record", pg.tapnft._encode_unchecked(b"\x02" + bytes(20) + bytes(8) + b"\x00\x08", 128, 8), None),
        ("truncated-header", b"TAPNET\x01\x00", None),
        ("stateful-declared-combinational", files["daily-cap"], False),
        ("combinational-declared-stateful", files["allowlist"], True),
        ("ok-declared-stateful", files["daily-cap"], True),
    ]
    v["policyChecks"] = [{"name": n, "bytes": len(d), "sha256": hx(hashlib.sha256(d).digest()), "declaredStateful": s,
                          "hex": d.hex() if len(d) <= 256 else None,
                          **outcome(lambda d=d, s=s: pg.check_policy_file(d, s).as_json())} for n, d, s in bad_files]
    v["tooLargeGenerator"] = {"rule": "tapnet/1 header with nIn 128 and nOut 8, then 7100 NAND records, the k-th (k from 0) reading signal 129 + k twice", "bytes": len(big), "sha256": hx(hashlib.sha256(big).digest())}

    # ---- results (§2.3)
    v["results"] = [{"outputs": "0x%02x" % b, **pg.interpret(bytes([b]))} for b in (0x01, 0x00, 0x02, 0x0e, 0x0c, 0x03, 0x0f, 0x80, 0x81, 0xfe, 0xff)]

    # ---- encoding (§3)
    enc_cases = [
        ("one unit", req(UNIT)), ("zero", req(0)), ("rounds up", req(UNIT + 1)), ("just under two units", req(2 * UNIT - 1)),
        ("saturates", req((1 << 32) * UNIT)), ("last non-saturating", req(((1 << 32) - 1) * UNIT)),
        ("asset class 2", req(UNIT, asset=ASSET_V)), ("asset not listed", req(UNIT, asset=ASSET_X)),
        ("counterparty class 3", req(UNIT, cp=P3)), ("counterparty not listed", req(UNIT, cp=PX)),
        ("kind call", req(UNIT, kind=3)), ("kind 7", req(UNIT, kind=7)),
        ("epoch", req(UNIT, ts=0)), ("saturday noon", req(UNIT, ts=SAT_NOON)), ("monday 10:00", req(UNIT, ts=MON_10)),
        ("sunday 23:59:59", req(UNIT, ts=SAT_NOON + DAY + 43199)), ("day wraps at 2^16", req(UNIT, ts=65536 * DAY)),
        ("max ts", req(UNIT, ts=(1 << 64) - 1)),
    ]
    v["encoding"] = []
    for n, r in enc_cases:
        f = pg.fields_of(r, TABLES)
        w = pg.encode_request(r, TABLES)
        v["encoding"].append({"name": n, "request": r, "fields": f, "word": hx(w), "wordInt": str(int.from_bytes(w, "little"))})
    bad_reqs = [
        ("negative amount", {**req(UNIT), "amount": "-1"}), ("amount not decimal", {**req(UNIT), "amount": "0x10"}),
        ("amount with leading zero", {**req(UNIT), "amount": "01"}), ("amount 2^256", {**req(UNIT), "amount": str(1 << 256)}),
        ("asset checksummed", {**req(UNIT), "asset": "0x" + "AA" * 20}), ("kind 8", req(UNIT, kind=8)),
        ("kind bool", {**req(UNIT), "kind": True}), ("ts 2^64", {**req(UNIT), "ts": 1 << 64}),
        ("extra member", {**req(UNIT), "memo": "x"}), ("missing member", {k: val for k, val in req(UNIT).items() if k != "ts"}),
    ]
    v["encodingErrors"] = [{"name": n, "request": r, **outcome(lambda r=r: hx(pg.encode_request(r, TABLES)))} for n, r in bad_reqs]
    bad_tables = [
        ("unit zero", {**TABLES, "amountUnit": "0"}), ("class 0", {**TABLES, "assets": {ASSET_U: 0}}),
        ("class 256", {**TABLES, "counterparties": {P1: 256}}), ("checksummed key", {**TABLES, "assets": {"0x" + "AA" * 20: 1}}),
        ("extra member", {**TABLES, "kinds": {}}), ("unit as float", {**TABLES, "amountUnit": 1.5}),
    ]
    v["tablesErrors"] = [{"name": n, "tables": t, **outcome(lambda t=t: hx(pg.tables_hash(t)))} for n, t in bad_tables]
    v["tables"] = {"tables": TABLES, "canonicalJSON": pg.canonical_json(TABLES), "tablesHash": hx(pg.tables_hash(TABLES))}
    v["wordDecode"] = [{"word": w, **outcome(lambda w=w: pg.decode_word(bytes.fromhex(w[2:])))} for w in (
        v["encoding"][0]["word"], "0x" + "00" * 4 + "02" + "00" * 11, "0x" + "00" * 7 + "08" + "00" * 8, "0x" + "00" * 15 + "80", "0x" + "00" * 15)]

    # ---- evaluations (§4.1), one request each, combinational policies
    loaded = {n: pg.Policy.load(d) for n, d in files.items()}
    evals = []

    def ev(policy, name, r, state=None):
        res = pg.evaluate(loaded[policy], r, TABLES, state)
        evals.append({"policy": policy, "name": name, "request": r, **({"state": hx(state)} if state is not None else {}), **res})

    ev("allowlist", "allowed", req(1000 * UNIT, cp=P2))
    ev("allowlist", "one wei over the limit", req(1000 * UNIT + 1, cp=P2))
    ev("allowlist", "counterparty class 3", req(UNIT, cp=P3))
    ev("allowlist", "counterparty not listed", req(UNIT, cp=PX))
    ev("allowlist", "asset class 2", req(UNIT, asset=ASSET_V))
    ev("allowlist", "kind call", req(UNIT, kind=3))
    ev("allowlist", "overflow beats counterparty", req((1 << 40) * UNIT, cp=PX))
    ev("allowlist", "kind beats overflow", req((1 << 40) * UNIT, cp=PX, kind=0))
    ev("allowlist", "zero amount", req(0))
    ev("time-window", "monday 10:00 pay", req(UNIT, ts=MON_10))
    ev("time-window", "monday 10:00 call", req(UNIT, ts=MON_10, kind=3))
    ev("time-window", "monday 08:59:59", req(UNIT, ts=MON_10 - 3601))
    ev("time-window", "monday 09:00:00", req(UNIT, ts=MON_10 - 3600))
    ev("time-window", "monday 16:59:59", req(UNIT, ts=MON_10 + 7 * 3600 - 1))
    ev("time-window", "monday 17:00:00", req(UNIT, ts=MON_10 + 7 * 3600))
    ev("time-window", "saturday noon", req(UNIT, ts=SAT_NOON))
    ev("time-window", "friday 12:00", req(UNIT, ts=MON_10 + 4 * DAY + 7200))
    ev("time-window", "kind fund in window", req(UNIT, ts=MON_10, kind=2))
    ev("time-window", "huge amount is not this policy's concern", req((1 << 60) * UNIT, ts=MON_10))
    ev("deny-all", "anything", req(UNIT))
    ev("deny-all", "zero", req(0, kind=0))
    ev("per-asset-limits", "asset 1 at limit", req(1000 * UNIT))
    ev("per-asset-limits", "asset 1 over", req(1001 * UNIT))
    ev("per-asset-limits", "asset 2 at limit", req(50 * UNIT, asset=ASSET_V))
    ev("per-asset-limits", "asset 2 over", req(51 * UNIT, asset=ASSET_V))
    ev("per-asset-limits", "asset not listed", req(UNIT, asset=ASSET_X))
    ev("daily-cap", "first request from zero state", req(500 * UNIT))
    ev("daily-cap", "501 units from zero state", req(501 * UNIT))
    evals.append({"policy": "daily-cap", "name": "evalFile on a stateful policy", "request": req(UNIT),
                  **outcome(lambda: hx(loaded["daily-cap"].eval(pg.encode_request(req(UNIT), TABLES))))})
    v["evaluations"] = evals

    # ---- traces (§4.2)
    def trace(name, policy, entries, **kw):
        return {"name": name, "policy": policy, "entries": entries, **{k: val for k, val in kw.items() if val is not None},
                **outcome(lambda: pg.replay(loaded[policy], TABLES, entries, kw.get("notBefore"), kw.get("expires"), kw.get("escrowCumulative", False)))}

    d0 = MON_10
    traces = [
        trace("four of 500 fill the cap, fifth denied, next day resets", "daily-cap",
              [{"request": req(500 * UNIT, ts=d0 + i * 60)} for i in range(5)] + [{"request": req(500 * UNIT, ts=d0 + DAY)}]),
        trace("a denied request does not consume the cap", "daily-cap",
              [{"request": req(1500 * UNIT, ts=d0)}, {"request": req(501 * UNIT, ts=d0 + 1)}, {"request": req(500 * UNIT, ts=d0 + 2)},
               {"request": req(500 * UNIT, ts=d0 + 3)}, {"request": req(500 * UNIT, ts=d0 + 4)}, {"request": req(500 * UNIT, ts=d0 + 5)}]),
        trace("midnight boundary", "daily-cap",
              [{"request": req(500 * UNIT, ts=d0 + 13 * 3600 + 3599)}, {"request": req(500 * UNIT, ts=d0 + 14 * 3600)}]),
        trace("non-pay kinds never touch the state", "daily-cap",
              [{"request": req(500 * UNIT, kind=3, ts=d0)}, {"request": req(500 * UNIT, kind=2, ts=d0)}] + [{"request": req(500 * UNIT, ts=d0 + i)} for i in range(5)]),
        trace("recorded verdicts agree", "daily-cap",
              [{"request": req(500 * UNIT, ts=d0), "verdict": "allow"}, {"request": req(2000 * UNIT, ts=d0 + 1), "verdict": "deny"}]),
        trace("recorded verdict disagrees", "daily-cap",
              [{"request": req(500 * UNIT, ts=d0), "verdict": "deny"}]),
        trace("ts goes backwards", "daily-cap", [{"request": req(UNIT, ts=d0 + 10)}, {"request": req(UNIT, ts=d0 + 9)}]),
        trace("entry before the binding window", "daily-cap", [{"request": req(UNIT, ts=d0 - 1)}], notBefore=d0, expires=d0 + 7 * DAY),
        trace("entry after the binding window", "daily-cap", [{"request": req(UNIT, ts=d0 + 7 * DAY + 1)}], notBefore=d0, expires=d0 + 7 * DAY),
        trace("escrow cumulative vouchers: deltas", "daily-cap",
              [{"request": {k: val for k, val in req(0, ts=d0 + i).items() if k != "amount"}, "cumulative": str(c)}
               for i, c in enumerate([400 * UNIT, 900 * UNIT, 1500 * UNIT, 2400 * UNIT, 2000 * UNIT, 2400 * UNIT])][:4]
              + [{"request": {k: val for k, val in req(0, ts=d0 + 4).items() if k != "amount"}, "cumulative": str(1900 * UNIT)},
                 {"request": {k: val for k, val in req(0, ts=d0 + 5).items() if k != "amount"}, "cumulative": str(2000 * UNIT)}],
              escrowCumulative=True),
        trace("escrow cumulative decreases", "daily-cap",
              [{"request": {k: val for k, val in req(0, ts=d0).items() if k != "amount"}, "cumulative": str(500 * UNIT)},
               {"request": {k: val for k, val in req(0, ts=d0 + 1).items() if k != "amount"}, "cumulative": str(400 * UNIT)}],
              escrowCumulative=True),
        trace("escrow entry carries amount", "daily-cap", [{"request": req(UNIT, ts=d0), "cumulative": "1"}], escrowCumulative=True),
        trace("combinational trace has no state", "allowlist", [{"request": req(UNIT, cp=P2, ts=d0)}, {"request": req(UNIT, cp=PX, ts=d0)}]),
        trace("empty trace", "daily-cap", []),
        trace("day index wraps after 65536 days", "daily-cap",
              [{"request": req(500 * UNIT, ts=d0)}] * 4 + [{"request": req(500 * UNIT, ts=d0 + 65536 * DAY)}]),
    ]
    v["traces"] = traces

    # ---- bindings (§5)
    pol_hash = v["policies"]["daily-cap"]["sha256"]
    th = v["tables"]["tablesHash"]
    mandate_hash = "0x" + credits.keccak256(b"example mandate").hex()
    nb, exp_, iss = d0, d0 + 7 * DAY, d0 - 3600
    B = {"netlistHash": pol_hash, "subjectKind": 1, "subject": mandate_hash, "tablesHash": th, "notBefore": nb, "expires": exp_, "issued": iss}
    sig = pg.sign_binding(CHAIN, B, KEYS[1])
    escrow_subject = pg.subject_escrow_session(A("e5"), CONSUMER, P1, A("5e"))
    B2 = {**B, "subjectKind": 2, "subject": escrow_subject, "netlistHash": v["policies"]["allowlist"]["sha256"]}
    sig2 = pg.sign_binding(CHAIN, B2, KEYS[3])
    B3 = {**B, "subjectKind": 3, "subject": pg.subject_account(OTHER)}
    B4 = {**B, "subjectKind": 4, "subject": pg.subject_label("display only")}
    sig3 = pg.sign_binding(CHAIN, B3, KEYS[1])     # kind 3: the holder of the circuit whose container is the account
    v["subjects"] = {"mandate": mandate_hash, "escrowSession": {"escrow": A("e5"), "consumer": CONSUMER, "provider": P1, "key": A("5e"), "subject": escrow_subject},
                     "account": {"account": OTHER, "subject": B3["subject"]}, "label": {"label": "display only", "subject": B4["subject"]}}
    v["keys"] = {str(n): {"priv": hex(k), "address": ADDR[n]} for n, k in KEYS.items()}
    now = d0 + DAY

    def bc(name, b, s, tables=TABLES, **kw):
        return {"name": name, "chainId": CHAIN, "binding": b, "sig": s, **{k: val for k, val in kw.items() if k != "policy_file"},
                **outcome(lambda: pg.check_binding(CHAIN, b, s, tables, now=kw.get("now", now), policy_file=kw.get("policy_file"),
                                                   expected_signer=kw.get("expectedSigner"), declared_stateful=kw.get("declaredStateful"),
                                                   revocations=kw.get("revocations")))}

    rev = {"bindingHashes": [hx(pg.binding_hash(CHAIN, B))], "revokedBefore": 0, "issued": now}
    rev_sig = pg.sign_revocation(CHAIN, rev, KEYS[1])
    rev_time = {"bindingHashes": [], "revokedBefore": iss + 1, "issued": now}
    rev_other = {"bindingHashes": [hx(pg.binding_hash(CHAIN, B2))], "revokedBefore": 0, "issued": now}
    rev_at = {"bindingHashes": [], "revokedBefore": iss, "issued": now}          # §5.4: strict `issued < revokedBefore`
    rev_none = {"bindingHashes": [], "revokedBefore": 0, "issued": now}          # §5.4: 0 means no time cut-off
    bindings = [
        bc("mandate binding, holder signed, file matches", B, sig, expectedSigner=HOLDER, policy_file=files["daily-cap"], declaredStateful=True),
        bc("same binding without the expected signer", B, sig),
        bc("signed by another key", B, pg.sign_binding(CHAIN, B, KEYS[2]), expectedSigner=HOLDER),
        bc("unsigned", B, None, expectedSigner=HOLDER),
        bc("signature of another chain", B, pg.sign_binding(97, B, KEYS[1]), expectedSigner=HOLDER),
        bc("not yet", B, sig, expectedSigner=HOLDER, now=nb - 1),
        bc("at notBefore", B, sig, expectedSigner=HOLDER, now=nb),
        bc("at expires", B, sig, expectedSigner=HOLDER, now=exp_),
        bc("expired", B, sig, expectedSigner=HOLDER, now=exp_ + 1),
        bc("tables changed", B, sig, tables={**TABLES, "amountUnit": "1"}, expectedSigner=HOLDER),
        bc("tables malformed", B, sig, tables={**TABLES, "amountUnit": "0"}, expectedSigner=HOLDER),
        bc("policy file is another policy", B, sig, expectedSigner=HOLDER, policy_file=files["allowlist"]),
        bc("policy file declared combinational", B, sig, expectedSigner=HOLDER, policy_file=files["daily-cap"], declaredStateful=False),
        bc("policy file invalid", B, sig, expectedSigner=HOLDER, policy_file=bad_files[0][1]),
        bc("revoked by hash", B, sig, expectedSigner=HOLDER, revocations=[{"signer": HOLDER, "revocation": rev, "sig": rev_sig}]),
        bc("revoked by time", B, sig, expectedSigner=HOLDER, revocations=[{"signer": HOLDER, "revocation": rev_time}]),
        bc("revocation of another binding", B, sig, expectedSigner=HOLDER, revocations=[{"signer": HOLDER, "revocation": rev_other}]),
        bc("revokedBefore equal to issued does not cover", B, sig, expectedSigner=HOLDER, policy_file=files["daily-cap"], declaredStateful=True,
           revocations=[{"signer": HOLDER, "revocation": rev_at}]),
        bc("revokedBefore 0 and no hashes covers nothing", B, sig, expectedSigner=HOLDER, policy_file=files["daily-cap"], declaredStateful=True,
           revocations=[{"signer": HOLDER, "revocation": rev_none}]),
        bc("revocation by another signer is ignored", B, sig, expectedSigner=HOLDER, revocations=[{"signer": OTHER, "revocation": rev}]),
        bc("escrow-session binding by the consumer", B2, sig2, expectedSigner=CONSUMER, policy_file=files["allowlist"]),
        bc("escrow-session binding by the holder is not the consumer", B2, pg.sign_binding(CHAIN, B2, KEYS[1]), expectedSigner=CONSUMER),
        bc("mandate binding, holder signed, file not at hand", B, sig, expectedSigner=HOLDER),
        bc("account binding by the circuit holder, file at hand", B3, sig3, expectedSigner=HOLDER, policy_file=files["daily-cap"], declaredStateful=True),
        bc("account binding by the circuit holder, file not at hand", B3, sig3, expectedSigner=HOLDER),
        bc("account binding signed by the account itself", B3, pg.sign_binding(CHAIN, B3, KEYS[2]), expectedSigner=OTHER,
           policy_file=files["daily-cap"], declaredStateful=True),
        bc("account binding signed by the account itself, binder unknown", B3, pg.sign_binding(CHAIN, B3, KEYS[2])),
        bc("label binding is never enforceable", B4, pg.sign_binding(CHAIN, B4, KEYS[1])),
        bc("label binding with binder and file is still display only", B4, pg.sign_binding(CHAIN, B4, KEYS[1]), expectedSigner=HOLDER,
           policy_file=files["daily-cap"], declaredStateful=True),
        bc("window empty", {**B, "expires": nb}, sig),
        bc("issued after expires", {**B, "issued": exp_ + 1}, sig),
        bc("unknown subject kind", {**B, "subjectKind": 5}, sig),
        bc("account subject not padded", {**B, "subjectKind": 3, "subject": "0x" + "11" * 32}, sig),
        bc("zero netlist hash", {**B, "netlistHash": "0x" + "00" * 32}, sig),
        bc("uppercase hex", {**B, "subject": mandate_hash.upper().replace("0X", "0x")}, sig),
        bc("missing member", {k: val for k, val in B.items() if k != "issued"}, sig),
    ]
    v["bindings"] = bindings
    v["bindingHashes"] = {"mandate": hx(pg.binding_hash(CHAIN, B)), "mandateStructHash": hx(pg.struct_hash(pg.BINDING_FIELDS, pg.BINDING_TYPEHASH, B, "x")),
                          "mandateOnChain97": hx(pg.binding_hash(97, B)), "escrowSession": hx(pg.binding_hash(CHAIN, B2))}
    v["revocations"] = [
        {"name": "by hash", "revocation": rev, "sig": rev_sig, "signer": credits.recover(pg.revocation_hash(CHAIN, rev), bytes.fromhex(rev_sig[2:])),
         "hash": hx(pg.revocation_hash(CHAIN, rev)), "covers": pg.revocation_covers(rev, v["bindingHashes"]["mandate"], iss)},
        {"name": "by time", "revocation": rev_time, "hash": hx(pg.revocation_hash(CHAIN, rev_time)), "covers": pg.revocation_covers(rev_time, v["bindingHashes"]["mandate"], iss)},
        {"name": "revokedBefore equal to issued", "revocation": rev_at, "hash": hx(pg.revocation_hash(CHAIN, rev_at)), "covers": pg.revocation_covers(rev_at, v["bindingHashes"]["mandate"], iss)},
        {"name": "revokedBefore one above issued", "revocation": rev_time, "covers": pg.revocation_covers(rev_time, v["bindingHashes"]["mandate"], iss)},
        {"name": "revokedBefore 0 means none", "revocation": rev_none, "hash": hx(pg.revocation_hash(CHAIN, rev_none)), "covers": pg.revocation_covers(rev_none, v["bindingHashes"]["mandate"], iss)},
        {"name": "other binding", "revocation": rev_other, "hash": hx(pg.revocation_hash(CHAIN, rev_other)), "covers": pg.revocation_covers(rev_other, v["bindingHashes"]["mandate"], iss)},
        {"name": "too many hashes", "revocation": {**rev, "bindingHashes": [v["bindingHashes"]["mandate"]] * 25},
         **outcome(lambda: pg.revocation_covers({**rev, "bindingHashes": [v["bindingHashes"]["mandate"]] * 25}, v["bindingHashes"]["mandate"], iss))},
        {"name": "zero hash listed", "revocation": {**rev, "bindingHashes": ["0x" + "00" * 32]},
         **outcome(lambda: pg.revocation_covers({**rev, "bindingHashes": ["0x" + "00" * 32]}, v["bindingHashes"]["mandate"], iss))},
    ]

    # ---- metadata members (§6)
    tok_ok = {"netlist": {"format": "tapnet/1", "sha256": pol_hash, "bytes": v["policies"]["daily-cap"]["bytes"], "nIn": 128, "nOut": 8,
                          "nand": v["policies"]["daily-cap"]["nand"], "latch": v["policies"]["daily-cap"]["latch"], "uris": ["https://example.invalid/p.tapnet"]},
              "policy": {"convention": pg.CONVENTION, "stateful": True, "reasons": {"64": "example policy-defined reason"}}}
    tok_cases = [
        ("valid", tok_ok),
        ("missing", {"netlist": tok_ok["netlist"]}),
        ("other convention", {**tok_ok, "policy": {**tok_ok["policy"], "convention": "tap-policy/2"}}),
        ("convention case", {**tok_ok, "policy": {**tok_ok["policy"], "convention": "TAP-POLICY/1"}}),
        ("stateful not boolean", {**tok_ok, "policy": {**tok_ok["policy"], "stateful": 1}}),
        ("stateful contradicts latch", {**tok_ok, "policy": {**tok_ok["policy"], "stateful": False}}),
        ("pins contradict", {**tok_ok, "netlist": {**tok_ok["netlist"], "nIn": 64}}),
        ("reason code 8 is reserved", {**tok_ok, "policy": {**tok_ok["policy"], "reasons": {"8": "x"}}}),
        ("reason text empty", {**tok_ok, "policy": {**tok_ok["policy"], "reasons": {"64": ""}}}),
        ("extra member", {**tok_ok, "policy": {**tok_ok["policy"], "author": "x"}}),
    ]
    v["tokenMetadata"] = [{"name": n, "tap": t, **outcome(lambda t=t: pg.check_token_policy_member(t))} for n, t in tok_cases]
    sub_ok = {"chainId": CHAIN, "binding": B, "sig": sig, "tables": TABLES, "policy": {"chainId": CHAIN, "contract": A("c0"), "tokenId": 7}}
    sub_cases = [
        ("valid", sub_ok), ("without policy location", {k: val for k, val in sub_ok.items() if k != "policy"}),
        ("sig short", {**sub_ok, "sig": sig[:-2]}), ("tables malformed", {**sub_ok, "tables": {**TABLES, "amountUnit": "0"}}),
        ("binding malformed", {**sub_ok, "binding": {**B, "subjectKind": 9}}), ("policy location incomplete", {**sub_ok, "policy": {"chainId": CHAIN}}),
        ("extra member", {**sub_ok, "note": "x"}),
    ]
    v["subjectMetadata"] = [{"name": n, "member": m, **outcome(lambda m=m: "ok" if pg.check_subject_policy_member(m) else "ok")} for n, m in sub_cases]

    # ---- example `tap.policy` documents for the text
    v["example"] = {"tokenMetadataTap": tok_ok, "subjectRecordTapPolicy": sub_ok}

    # ---- case count
    sections = ("policyChecks", "results", "encoding", "encodingErrors", "tablesErrors", "wordDecode", "evaluations", "traces",
                "bindings", "revocations", "tokenMetadata", "subjectMetadata")
    v["caseCount"] = {s: len(v[s]) for s in sections}
    v["caseCount"]["total"] = sum(v["caseCount"].values())
    return v


def main() -> int:
    v = build()
    text = json.dumps(v, indent=1, ensure_ascii=False, sort_keys=False) + "\n"
    if "--check" in sys.argv:
        with open(OUT, encoding="utf-8") as f:
            old = f.read()
        if old != text:
            print("vectors.json differs from a fresh generation")
            return 1
        print("vectors.json is up to date;", v["caseCount"]["total"], "cases")
        return 0
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote", OUT, "with", v["caseCount"]["total"], "cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
