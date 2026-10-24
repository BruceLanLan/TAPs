"""Tests for the Policy Circuit Gate reference implementation. Standard library only.

    python3 test_policy_gate.py            # vectors, differential checks, round trips
Optional cross-check: with `eth_account` installed, EIP-712 signatures are also verified by it.
"""
from __future__ import annotations

import hashlib
import json
import os
import random
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # sibling modules, also under python3 -I

import credits
import examples as ex
import make_vectors as mv
import policy_gate as pg

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "vectors.json"), encoding="utf-8") as f:
    V = json.load(f)
T = mv.TABLES
POLICIES = {n: pg.Policy.load(d) for n, ((d, _), _) in ex.build_all().items()}
ORACLES = {n: o for n, ((_, o), _) in ex.build_all().items()}


class Vectors(unittest.TestCase):
    def test_regenerates_byte_for_byte(self):
        with open(os.path.join(HERE, "vectors.json"), encoding="utf-8") as fh:
            self.assertEqual(json.dumps(mv.build(), indent=1, ensure_ascii=False) + "\n", fh.read())

    def test_isolated_mode(self):
        """The scripts run under `python3 -I` from another directory (no script-dir or cwd on sys.path by default)."""
        import subprocess
        r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "make_vectors.py"), "--check"], cwd=os.sep,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_vendored_files_unchanged(self):
        for name, sha in V["vendored"].items():
            with open(os.path.join(HERE, name), "rb") as f:
                self.assertEqual(hashlib.sha256(f.read()).hexdigest(), sha, name)

    def test_policy_files_on_disk(self):
        for name, p in V["policies"].items():
            with open(os.path.join(HERE, p["file"]), "rb") as f:
                data = f.read()
            self.assertEqual("0x" + pg.policy_hash(data).hex(), p["sha256"], name)
            info = pg.check_policy_file(data, p["stateful"])
            self.assertEqual(info.as_json()["gates"], p["gates"])
            if p["hex"]:
                self.assertEqual(data.hex(), p["hex"])

    def test_case_count(self):
        self.assertGreaterEqual(V["caseCount"]["total"], 60)
        self.assertEqual(V["caseCount"]["total"], sum(n for k, n in V["caseCount"].items() if k != "total"))

    def test_too_large_generator(self):
        g = V["tooLargeGenerator"]
        recs = b"".join(b"\x00" + (129 + k).to_bytes(3, "big") * 2 for k in range(7100))
        data = b"TAPNET\x01\x00" + (128).to_bytes(4, "big") + (8).to_bytes(4, "big") + recs
        self.assertEqual(len(data), g["bytes"])
        self.assertEqual("0x" + hashlib.sha256(data).hexdigest(), g["sha256"])
        with self.assertRaises(pg.Invalid) as c:
            pg.check_policy_file(data)
        self.assertEqual(c.exception.code, "policy-too-large")


class Encoding(unittest.TestCase):
    def test_round_trip_and_reserved_zero(self):
        rnd = random.Random(7)
        for _ in range(2000):
            r = {"amount": str(rnd.randrange(0, 1 << rnd.choice([8, 32, 60, 100, 256]))), "asset": rnd.choice(list(T["assets"]) + [mv.ASSET_X]),
                 "counterparty": rnd.choice(list(T["counterparties"]) + [mv.PX]), "kind": rnd.randrange(8), "ts": rnd.randrange(0, 1 << 40)}
            f = pg.fields_of(r, T)
            w = pg.encode_request(r, T)
            self.assertEqual(len(w), 16)
            self.assertEqual(pg.decode_word(w), f)
            units = -(-int(r["amount"]) // mv.UNIT)
            self.assertEqual(f["overflow"], 1 if units >= 1 << 32 else 0)
            self.assertEqual(f["amount"], min(units, (1 << 32) - 1))

    def test_weekday_matches_calendar(self):
        import datetime as d
        for ts in (0, 86399, 86400, mv.SAT_NOON, mv.MON_10, 1700000000, 2000000000):
            f = pg.fields_of(mv.req(1, ts=ts), T)
            dt = d.datetime.fromtimestamp(ts, d.timezone.utc)
            self.assertEqual(f["weekday"], dt.weekday(), ts)
            self.assertEqual(f["hour"], dt.hour, ts)

    def test_tables_hash_is_canonical(self):
        a = {"counterparties": T["counterparties"], "assets": T["assets"], "amountUnit": T["amountUnit"]}
        self.assertEqual(pg.tables_hash(a), pg.tables_hash(T))
        self.assertEqual(pg.canonical_json(T), V["tables"]["canonicalJSON"])


class Differential(unittest.TestCase):
    """Every example circuit against its Python oracle, random requests, stateful sequences included."""

    def test_all_examples(self):
        rnd = random.Random(2026)
        assets = list(T["assets"]) + [mv.ASSET_X]
        cps = list(T["counterparties"]) + [mv.PX]
        for name, pol in POLICIES.items():
            st_b, st = None, None
            ts = 1_790_000_000
            for _ in range(4000):
                units = rnd.choice([0, 1, 49, 50, 51, 499, 500, 501, 999, 1000, 1001, 1999, 2000, 2001, rnd.randrange(0, 3000), rnd.randrange(0, 1 << 33)])
                amount = units * mv.UNIT - (rnd.randrange(mv.UNIT) if units else 0)
                ts += rnd.choice([0, 1, 60, 3600, 40000, 86400, 200000])
                r = {"amount": str(amount), "asset": rnd.choice(assets), "counterparty": rnd.choice(cps), "kind": rnd.choice([1, 1, 1, 3, 0, 2, 7]), "ts": ts}
                want = ORACLES[name](pg.fields_of(r, T), st)
                got = pg.evaluate(pol, r, T, st_b)
                self.assertEqual((got["verdict"], got["reason"]), (want[0], want[1]), (name, r, st))
                if pol.info.stateful:
                    st, st_b = want[2], bytes.fromhex(got["newState"][2:])

    def test_denied_request_leaves_daily_state(self):
        pol = POLICIES["daily-cap"]
        st = pol.zero_state()
        st = bytes.fromhex(pg.evaluate(pol, mv.req(300 * mv.UNIT), T, st)["newState"][2:])
        for r in (mv.req(600 * mv.UNIT), mv.req(1, kind=3), mv.req((1 << 40) * mv.UNIT), mv.req(1800 * mv.UNIT)):
            res = pg.evaluate(pol, r, T, st)
            self.assertEqual(res["verdict"], "deny")
            self.assertEqual(res["newState"], "0x" + st.hex())

    def test_exhaustive_time_window(self):
        pol = POLICIES["time-window"]
        for day in range(7):
            for hour in range(24):
                for kind in range(8):
                    ts = (4 + day) * 86400 + hour * 3600 + 17   # 1970-01-05 is a Monday
                    res = pg.evaluate(pol, mv.req(5, kind=kind, ts=ts), T)
                    exp = "allow" if kind in (1, 3) and day < 5 and 9 <= hour < 17 else "deny"
                    self.assertEqual(res["verdict"], exp, (day, hour, kind))

    def test_results_fail_closed(self):
        for b in range(256):
            r = pg.interpret(bytes([b]))
            self.assertEqual(r["verdict"] == "allow", b == 1)
            if b & 1 and b != 1:
                self.assertTrue(r.get("invalidResult"))
        self.assertEqual(pg.interpret(b"")["verdict"], "deny")


class Bindings(unittest.TestCase):
    def test_typehashes(self):
        self.assertEqual("0x" + credits.keccak256(pg.BINDING_TYPE.encode()).hex(), V["constants"]["bindingTypehash"])
        self.assertEqual("0x" + credits.keccak256(pg.REVOCATION_TYPE.encode()).hex(), V["constants"]["revocationTypehash"])

    def test_enforceable_requires_checked_file(self):
        """§5.3: no checked file, no enforcement; a label is display only; an account never binds itself."""
        for case in V["bindings"]:
            r = case.get("result")
            if not r:
                continue
            if r["enforceable"] in (True, "conditional"):
                self.assertTrue(r["fileChecked"] and r["binderChecked"] and not r["problems"], case["name"])
                self.assertNotEqual(r["subjectKind"], "label", case["name"])
            if r["subjectKind"] == "label":
                self.assertTrue(r["displayOnly"], case["name"])
            if r["subjectKind"] == "account" and r["signer"] == "0x" + case["binding"]["subject"][26:]:
                self.assertIn("binding-self-signed", r["problems"], case["name"])

    def test_sign_recover_round_trip(self):
        for case in V["bindings"]:
            if case["sig"] and "result" in case and case["result"]["signer"]:
                h = pg.binding_hash(case["chainId"], case["binding"])
                self.assertEqual(credits.recover(h, bytes.fromhex(case["sig"][2:])), case["result"]["signer"])

    def test_chain_separates(self):
        B = V["bindings"][0]["binding"]
        self.assertNotEqual(pg.binding_hash(56, B), pg.binding_hash(97, B))
        self.assertEqual("0x" + pg.binding_hash(97, B).hex(), V["bindingHashes"]["mandateOnChain97"])

    def test_eth_account_cross_check(self):
        try:
            from eth_account import Account
            from eth_account.messages import encode_typed_data
        except ImportError:
            self.skipTest("eth_account not installed")
        B = V["bindings"][0]["binding"]
        typed = {"types": {"EIP712Domain": [{"name": "name", "type": "string"}, {"name": "version", "type": "string"},
                                            {"name": "chainId", "type": "uint256"}, {"name": "verifyingContract", "type": "address"}],
                           "PolicyBinding": [{"name": n, "type": t} for n, t in pg.BINDING_FIELDS]},
                 "primaryType": "PolicyBinding",
                 "domain": {"name": pg.DOMAIN_NAME, "version": pg.DOMAIN_VERSION, "chainId": 56, "verifyingContract": pg.HUB},
                 "message": {**B, "netlistHash": bytes.fromhex(B["netlistHash"][2:]), "subject": bytes.fromhex(B["subject"][2:]),
                             "tablesHash": bytes.fromhex(B["tablesHash"][2:])}}
        msg = encode_typed_data(full_message=typed)
        signed = Account.sign_message(msg, private_key=mv.KEYS[1])
        self.assertEqual(signed.signature.hex().removeprefix("0x"), V["bindings"][0]["sig"][2:])
        self.assertEqual(signed.message_hash.hex().removeprefix("0x"), pg.binding_hash(56, B).hex())

    def test_subject_forms(self):
        s = V["subjects"]
        e = s["escrowSession"]
        self.assertEqual(pg.subject_escrow_session(e["escrow"], e["consumer"], e["provider"], e["key"]), e["subject"])
        self.assertEqual(pg.subject_account(s["account"]["account"]), s["account"]["subject"])
        self.assertEqual(pg.subject_label(s["label"]["label"]), s["label"]["subject"])


class CanonicalJSON(unittest.TestCase):
    def test_basics(self):
        self.assertEqual(pg.canonical_json({"b": 1, "a": [True, None, "x\n"]}), '{"a":[true,null,"x\\n"],"b":1}')
        self.assertEqual(pg.canonical_json({"é": 1, "z": 2}), '{"z":2,"é":1}')
        for bad in ({"__proto__": 1}, 1.5, float("nan"), 1 << 53, "\ud800"):
            with self.assertRaises(pg.Invalid):
                pg.canonical_json(bad)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]] + sys.argv[1:], verbosity=1)
