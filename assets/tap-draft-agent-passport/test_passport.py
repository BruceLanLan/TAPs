# test_passport.py: checks vectors.json against the reference verifier. MIT License.
#   python3 test_passport.py
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import make_vectors as M  # noqa: E402
import passport as P  # noqa: E402
from keccak import keccak256  # noqa: E402

with open(os.path.join(HERE, "vectors.json"), encoding="utf-8") as _f:
    V = json.load(_f)

# Rules a machine can check from a snapshot or a proposed action; each must have a vector.
MACHINE_RULES = {"P-1", "P-2", "P-3", "P-4", "P-5", "P-6", "P-7", "P-8", "P-9", "P-10", "P-11",
                 "R-1", "R-2", "R-3", "R-4", "R-5", "E-1", "E-2",
                 "F-0", "F-1", "F-2", "F-3", "F-4", "F-5", "F-6", "F-7", "F-8", "F-9", "F-10",
                 "W-1", "W-2", "W-3", "W-4", "D-1", "D-2", "D-3", "D-4", "D-5", "D-6"}


class Crypto(unittest.TestCase):
    def test_keccak_known(self):
        self.assertEqual(keccak256(b"").hex(), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        self.assertEqual(keccak256(b"abc").hex(), "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        self.assertEqual(keccak256(b"a" * 200).hex(), keccak256(b"a" * 200).hex())

    def test_review_typehash(self):
        self.assertEqual("0x" + keccak256(P.REVIEW_TYPE.encode()).hex(), P.REVIEW_TYPEHASH)

    @unittest.skipUnless(shutil.which("cast"), "Foundry cast not installed")
    def test_against_cast(self):
        for s in V["interfaces"]["selectors"][:6]:
            out = subprocess.run(["cast", "sig", s["signature"]], capture_output=True, text=True).stdout.strip()
            self.assertEqual(out, s["selector"])
        out = subprocess.run(["cast", "keccak", "tap"], capture_output=True, text=True).stdout.strip()
        self.assertEqual(out, "0x" + keccak256(b"tap").hex())


class Interfaces(unittest.TestCase):
    def test_selectors(self):
        for s in V["interfaces"]["selectors"]:
            self.assertEqual(P.selector(s["signature"]), s["selector"], s["signature"])
        for h in V["interfaces"]["hashes"]:
            self.assertEqual("0x" + keccak256(h["text"].encode()).hex(), h["keccak256"])

    def test_vendored_subset(self):
        with open(os.path.join(HERE, "IERC8004PassportSubset.sol"), encoding="utf-8") as f:
            src = f.read()
        table = {s["selector"]: s["signature"] for s in V["interfaces"]["selectors"]}
        claimed = re.findall(r"/// (0x[0-9a-f]{8})(?![0-9a-f])", src)
        self.assertGreaterEqual(len(claimed), 11)
        for sel in claimed:
            self.assertIn(sel, table, sel)


class Vectors(unittest.TestCase):
    def test_reproducible(self):
        with open(os.path.join(HERE, "vectors.json"), "rb") as f:
            self.assertEqual(f.read(), M.render(M.build()))

    def test_counts(self):
        c = V["counts"]
        self.assertEqual(c["total"], sum(v for k, v in c.items() if k != "total"))
        self.assertGreaterEqual(c["total"], 60)

    def test_resolution(self):
        for c in V["resolution"]:
            with self.subTest(c["id"]):
                res = P.resolve(c["snapshot"])
                self.assertEqual(res["state"], c["expected"]["state"])
                self.assertEqual(res["reasons"], c["expected"]["reasons"])
                for k in ("warnings", "display", "agentId"):
                    if k in c["expected"]:
                        self.assertEqual(res[k], c["expected"][k])
                self.assertIn(res["state"], P.STATES)
                for r in res["reasons"]:
                    self.assertIn(r, P.REASONS)
                for wn in res["warnings"]:
                    self.assertIn(wn, P.WARNINGS)
                low = res["display"].lower()
                for bad in P.DISPLAY_FORBIDDEN:
                    self.assertNotIn(bad, low)

    def test_unavailable_never_broken(self):
        for c in V["resolution"]:
            if c["expected"]["state"] == "UNAVAILABLE":
                self.assertTrue(all(P.REASONS[r] == "P-6" for r in c["expected"]["reasons"]))

    def test_sources(self):
        for c in V["resolution"] + V["feedback"]:
            src = c["snapshot"]["source"]
            self.assertIn(src, ("synthetic", "bsc-mainnet-read"))
            if src == "bsc-mainnet-read":
                self.assertEqual(c["snapshot"]["readAt"]["block"], 129353737)
                self.assertTrue(c["snapshot"]["readAt"]["agree"])

    def test_feedback(self):
        for c in V["feedback"]:
            with self.subTest(c["id"]):
                res = P.resolve(c["snapshot"])
                rep = P.summarise_feedback(c["snapshot"], res)
                self.assertEqual(res["state"], c["expected"]["state"])
                if c["expected"].get("computed") is False:
                    self.assertFalse(rep["computed"])
                    self.assertEqual(rep["why"], c["expected"]["why"])
                    continue
                self.assertEqual(rep["counted"], c["expected"]["counted"])
                self.assertEqual(rep["excluded"], c["expected"]["excluded"])
                self.assertEqual(rep["getSummaryClientAddresses"], c["expected"]["getSummaryClientAddresses"])
                self.assertEqual(rep["outsideClientSet"], c["expected"]["outsideClientSet"])
                self.assertEqual(rep["earlierHolders"], c["expected"]["earlierHolders"])
                named = {P.addr(x) for x in c["snapshot"]["summary"]["clientAddresses"]}
                self.assertTrue(set(rep["getSummaryClientAddresses"] or []) <= named)
                if "level-1" in c["expected"]:
                    self.assertEqual(rep["summary"]["level-1"], c["expected"]["level-1"])

    def test_feedback_params(self):
        for c in V["feedbackParams"]:
            p = P.feedback_params(c["record"], c["agentId"], c["reviewerName"], c["gatewayDomain"], c["level"])
            self.assertEqual(p, c["expected"])
            self.assertEqual(p["feedbackHash"], "0x" + keccak256(p["fileBytes"].encode()).hex())
            self.assertTrue(p["feedbackURI"].endswith("/" + P.review_file_key(c["reviewHash"])))

    def test_small_sections(self):
        for c in V["passportKey"]:
            try:
                d = P.decode_passport_key(bytes.fromhex(c["bytes"][2:]))
                got = {"ok": True, "chainId": d["chainId"], "processor": d["processor"], "tokenId": d["tokenId"]}
            except P.Broken as e:
                got = {"ok": False, "reason": e.reason}
            self.assertEqual(got, c["expected"], c["id"])
        for c in V["forbiddenNames"]:
            self.assertEqual(P.forbidden_name(c["name"]), c["expected"]["forbidden"], c["name"])
        for c in V["canonicalJson"]:
            self.assertEqual(P.canonical_json(c["value"]), c["expected"])
        for c in V["runtimeCalls"]:
            self.assertEqual(P.check_runtime_call(c["config"], c["to"], c["data"], c["fromCounterpartyText"])["allowed"],
                             c["expected"]["allowed"], c["id"])
        for c in V["delegationProposals"]:
            self.assertEqual(P.check_delegation_proposal(c["now"], c["expires"], c["isDefault"], c["signerGeneratedHere"])["ok"],
                             c["expected"]["ok"], c["id"])

    def test_confusable_table(self):
        # §5.4: the table in the vectors is the one the verifier applies, and nothing else is mapped.
        want = {chr(int(k[2:], 16)): v for k, v in V["constants"]["confusables"].items()}
        self.assertEqual(P._CONFUSABLE, want)
        self.assertFalse(P.forbidden_name("\u1d18oints"))    # U+1D18 small capital P is outside the table

    def test_rule_coverage(self):
        seen = set()
        for sec in ("resolution", "feedback", "feedbackParams", "passportKey", "forbiddenNames", "canonicalJson",
                    "runtimeCalls", "delegationProposals"):
            for c in V[sec]:
                seen.update(c["rules"])
        self.assertEqual(MACHINE_RULES - seen, set())

    def test_key_roundtrip(self):
        b = P.encode_passport_key(56, M.PROC, 7)
        self.assertEqual(len(b), 96)
        self.assertEqual(P.decode_passport_key(b)["tokenId"], 7)


class Robustness(unittest.TestCase):
    def test_canonical_rejects(self):
        for bad in (b'{"a":1,"a":2}', b'{"__proto__":1}', b'{"n":-0}', b'{"n":9007199254740992}', b'{"n":NaN}',
                    b'{"s":"\\ud800"}', b'{"n":1e400}'):
            with self.assertRaises((P.NoCanonicalForm, ValueError)):
                P.canonical_json(P.strict_json(bad))

    def test_number_forms(self):
        for v, s in ((1.5, "1.5"), (1e21, "1e+21"), (1e-7, "1e-7"), (100.0, "100"), (-2.5e-5, "-0.000025"), (5e-324, "5e-324")):
            self.assertEqual(P._es_number(v), s)


if __name__ == "__main__":
    unittest.main(verbosity=1)
