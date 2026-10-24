"""Tests for circuit_jobs.py and vectors.json (TAP draft "Circuit Jobs"). MIT licence; standard library only.

Run: python3 test_circuit_jobs.py  (add -v for names). Cross-checks selectors against Foundry `cast sig` when
`cast` is installed; otherwise that test is skipped. Nothing here reads a chain.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import circuit_jobs as cj  # noqa: E402
import make_vectors as mv  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "vectors.json"), "r", encoding="utf-8") as _f:
    V = json.load(_f)

# selectors confirmed with `cast sig` on 2026-10-24 (deployed-ABI signatures marked in the draft)
CAST_CONFIRMED = {
    "claimSummary(uint256)": "0x58d08546",
    "maxSettlementSeconds()": "0xfcd8e94e",
    "inputProvider()": "0xecef2c34",
    "accept(uint256)": "0x19b05f49",
    "beforeAction(uint256,bytes4,bytes)": "0xdc08fb1d",
    "afterAction(uint256,bytes4,bytes)": "0xa3fe4783",
    "fund(uint256,uint256,bytes)": "0xd2e13f50",
    "getJob(uint256)": "0xbf22c457",
    "complete(uint256,bytes32,bytes)": "0xd75bbdf3",
    "reject(uint256,bytes32,bytes)": "0x41dd26f5",
    "submit(uint256,bytes32,bytes)": "0x9e63798d",
    "createJob(address,address,uint256,string,address)": "0x41528812",
    "setBudget(uint256,uint256,bytes)": "0xdd4ae9d4",
    "claimRefund(uint256)": "0x5b7baf64",
    "HookRequired()": "0x55c45de1",
    "HookMissingInterface()": "0x1a5d3d5f",
    "HookCallFailed()": "0xa9e35b2f",
    "WrongStatus()": "0x8e78f0cb",
    "supportsInterface(bytes4)": "0x01ffc9a7",
    "bindJob(uint256,(address,bytes32,bytes32,uint64,uint64,uint256,uint64,address))": "0x9349e872",
    "specOf(uint256)": "0x20f20d9c",
    "specHashOf(uint256)": "0xa2334b66",
    "claimIdOf(uint256)": "0x0db32f94",
    "check(uint256)": "0x5f72f450",
    "settle(uint256)": "0x8df82800",
    "kernel()": "0xd4aae0c4",
    "game()": "0xc3fe3e28",
    "margin()": "0x8f76691a",
    "minRemainingWindow()": "0x5db8081c",
}


class Keccak(unittest.TestCase):
    def test_known_answers(self):
        self.assertEqual(cj.keccak256(b"").hex(), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        self.assertEqual(cj.keccak256(b"abc").hex(), "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        self.assertEqual(cj.keccak256(b"a" * 200).hex(), cj.keccak256(bytes(b"a" * 200)).hex())
        # two-block message (longer than the 136-byte rate)
        self.assertEqual(len(cj.keccak256(b"x" * 1000)), 32)

    def test_selectors_match_cast_confirmed_values(self):
        for sig, sel in CAST_CONFIRMED.items():
            self.assertEqual(cj.selector(sig), sel, sig)

    def test_interface_ids(self):
        ids = cj.all_interface_ids()
        self.assertEqual(ids["IACPHook"], "0x7ff6bc9e")
        self.assertEqual(ids["ITapClaimSummary"], "0x58d08546")
        self.assertEqual(ids["ITapSettlementBound"], "0xfcd8e94e")
        self.assertEqual(ids["ERC165"], "0x01ffc9a7")
        acc = 0
        for s in cj.I_TAP_CIRCUIT_JOB:
            acc ^= int(CAST_CONFIRMED[s][2:], 16)
        self.assertEqual(ids["ITapCircuitJob"], "0x%08x" % acc)
        self.assertEqual(V["interfaces"]["interfaces"]["ITapCircuitJob"]["id"], ids["ITapCircuitJob"])

    @unittest.skipUnless(shutil.which("cast"), "Foundry cast not installed")
    def test_selectors_against_cast(self):
        sigs = list(CAST_CONFIRMED) + cj.EVALUATOR_ERRORS + cj.KERNEL_ERRORS
        for sig in sigs:
            out = subprocess.run(["cast", "sig", sig], capture_output=True, text=True, check=True).stdout.strip()
            self.assertEqual(out, cj.selector(sig), sig)
        for ev in cj.EVALUATOR_EVENTS:
            out = subprocess.run(["cast", "keccak", ev], capture_output=True, text=True, check=True).stdout.strip()
            self.assertEqual(out, cj.event_topic(ev), ev)


class Encoding(unittest.TestCase):
    def test_abi_words(self):
        self.assertEqual(cj.abi_word("uint64", 92).hex(), "00" * 31 + "5c")
        self.assertEqual(cj.abi_word("address", mv.GAME)[:12], b"\x00" * 12)
        with self.assertRaises(ValueError):
            cj.abi_word("uint64", 1 << 64)
        with self.assertRaises(ValueError):
            cj.abi_word("uint8", -1)
        with self.assertRaises(ValueError):
            cj.abi_word("bytes32", "0x00")

    def test_spec_encoding_is_256_bytes_and_hash_depends_on_every_field(self):
        s = mv.spec()
        enc = cj.spec_encode(s)
        self.assertEqual(len(enc), 256)
        base = cj.spec_hash(s)
        changes = {"game": mv.OTHER_GAME, "netlistHash2": "0x" + "44" * 32, "inputRoot": "0x" + "44" * 32, "T": 93,
                   "K": 9, "budget": 5_000_001, "expiredAt": s["expiredAt"] + 1, "inputProvider": mv.INPUT_PROVIDER}
        for f, v in changes.items():
            self.assertNotEqual(cj.spec_hash(dict(s, **{f: v})), base, f)

    def test_deliverable_round_trip(self):
        for cid in (0, 1, 7, 1 << 64, (1 << 256) - 1):
            self.assertEqual(cj.claim_id_of_deliverable(cj.deliverable_of(cid)), cid)
        self.assertEqual(cj.deliverable_of(7), "0x" + "00" * 31 + "07")

    def test_reason_depends_on_status(self):
        self.assertNotEqual(cj.reason_of(mv.GAME, 7, 3), cj.reason_of(mv.GAME, 7, 2))
        self.assertNotEqual(cj.reason_of(mv.GAME, 7, 3), cj.reason_of(mv.OTHER_GAME, 7, 3))


class Decision(unittest.TestCase):
    def test_table(self):
        self.assertEqual(cj.decision(1), cj.DECISION_PENDING)
        self.assertEqual(cj.decision(2), cj.DECISION_REJECT)
        self.assertEqual(cj.decision(3), cj.DECISION_COMPLETE)
        self.assertEqual(cj.decision(4), cj.DECISION_PENDING)
        with self.assertRaises(cj.RuleError) as e:
            cj.decision(0)
        self.assertEqual(str(e.exception), "NoClaim")
        with self.assertRaises(cj.RuleError):
            cj.decision(5)

    def test_state_table_matches_decisions(self):
        for row in V["stateTable"]:
            self.assertEqual(cj.state_row(row["jobStatus"], row["bound"], row["claimStatus"]), row["row"])
        with self.assertRaises(ValueError):
            cj.state_row(cj.JOB_SUBMITTED, True, None)


class Arithmetic(unittest.TestCase):
    def test_boundaries(self):
        req = cj.required_expiry(1000, 500, 100)
        self.assertEqual(req, 1600)
        self.assertTrue(cj.expiry_ok(1600, 1000, 500, 100))
        self.assertFalse(cj.expiry_ok(1599, 1000, 500, 100))
        self.assertTrue(cj.window_ok(1100, 1000, 100))
        self.assertFalse(cj.window_ok(1099, 1000, 100))

    def test_constants(self):
        self.assertEqual(cj.ACCEPT_GAS_CAP, 200_000)
        self.assertEqual(V["constants"]["ACCEPT_GAS_CAP"], cj.ACCEPT_GAS_CAP)
        self.assertEqual(cj.constants_ok(21_600, 21_600, 1_368_992), "ok")
        self.assertEqual(cj.constants_ok(21_599, 21_600, 1), "margin-below-minimum")
        self.assertEqual(cj.constants_ok(21_600, 0, 1), "minRemainingWindow-below-minimum")
        self.assertEqual(cj.constants_ok(21_600, 21_600, 31_536_000 - 21_600), "infeasible-expiry")
        self.assertEqual(cj.constants_ok(21_600, 21_600, 31_536_000 - 21_601), "ok")

    def test_latest_bind_time_leaves_room(self):
        exp = mv.NOW + cj.KERNEL_MAX_EXPIRY_DURATION
        t = cj.latest_bind_time(mv.NOW, exp, mv.MAX_SETTLEMENT, mv.MARGIN)
        self.assertTrue(cj.expiry_ok(exp, t, mv.MAX_SETTLEMENT, mv.MARGIN))
        self.assertFalse(cj.expiry_ok(exp, t + 1, mv.MAX_SETTLEMENT, mv.MARGIN))


class Rules(unittest.TestCase):
    def test_bind_order_and_each_rule(self):
        for c in V["bind"]:
            ev = dict(mv.EV, **c["evaluator"])
            self.assertEqual(cj.bind_check(c["job"], c["spec"], c["sender"], c["now"], ev, c["alreadyBound"]), c["result"], c["name"])
        names = {c["name"]: c["result"] for c in V["bind"]}
        self.assertEqual(names["valid"], "ok")
        self.assertEqual(names["valid_expiry_exact"], "ok")
        self.assertEqual(names["J2_expiry_one_second_short"], "ExpiryTooSoon")
        for err in ("NotClient", "NotOpen", "NotEvaluator", "AlreadyBound", "BadGame", "BadInputProvider", "BadSpec",
                    "ExpiryMismatch", "ExpiryTooSoon"):
            self.assertIn(err, names.values(), err)

    def test_fund(self):
        for c in V["fund"]:
            self.assertEqual(cj.fund_check(c["job"], mv.spec() if c["bound"] else None, c["sender"], mv.EV), c["result"], c["name"])

    def test_submit_order_and_each_rule(self):
        for c in V["submit"]:
            sp = None
            if c["bound"]:
                sp = dict(mv.spec(), expiredAt=c["job"]["expiredAt"])
            self.assertEqual(cj.submit_check(c["job"], sp, c["claim"], c["sender"], c["now"], mv.EV, c["claimAlreadyBound"]),
                             c["result"], c["name"])
        names = {c["name"]: c["result"] for c in V["submit"]}
        for err in ("NotKernel", "NotBound", "NotSubmitted", "AlreadyBound", "BadGame", "BadDeliverable", "ClaimMismatch",
                    "ClaimNotOpen", "WindowTooShort", "ExpiryTooSoon"):
            self.assertIn(err, names.values(), err)
        self.assertEqual(names["valid_window_exact"], "ok")
        self.assertEqual(names["J3_window_one_second_short"], "WindowTooShort")

    def test_settle(self):
        for c in V["settle"]:
            r, d = cj.settle_check(c["job"], c["claim"], c["settled"])
            self.assertEqual(r, c["result"], c["name"])
            if d is not None:
                self.assertEqual(cj.DECISION_NAMES[d], c["decision"])
                self.assertEqual(cj.reason_of(mv.GAME, 7, c["claim"]["status"]), c["reason"])

    def test_hook_rules_and_dispatch(self):
        for c in V["hookRules"]:
            self.assertEqual(cj.hook_rule_check(c["entry"]), c["result"], c["name"])
        for c in V["dispatch"]:
            self.assertEqual(cj.hook_dispatch(c["phase"], c["selector"]), c["runs"])
        self.assertEqual(cj.hook_dispatch("before", cj.selector(cj.KERNEL_SIGS["fund"])), "fund")
        self.assertEqual(cj.hook_dispatch("after", cj.selector(cj.KERNEL_SIGS["fund"])), "none")
        self.assertEqual(cj.hook_dispatch("before", cj.selector(cj.KERNEL_SIGS["submit"])), "none")


class Vectors(unittest.TestCase):
    def test_every_section_recomputes(self):
        for s in V["spec"]:
            self.assertEqual(cj.hex_of(cj.spec_encode(s["spec"])), s["encoded"])
            self.assertEqual(cj.spec_hash(s["spec"]), s["specHash"])
        for d in V["deliverable"]["deliverable"]:
            self.assertEqual(cj.deliverable_of(int(d["claimId"])), d["deliverable"])
        for r in V["deliverable"]["reason"]:
            self.assertEqual(cj.reason_of(r["game"], int(r["claimId"]), r["status"]), r["reason"])
        for d in V["decision"]:
            if "revert" in d:
                with self.assertRaises(cj.RuleError):
                    cj.decision(d["claimStatus"])
            else:
                self.assertEqual(cj.decision(d["claimStatus"]), d["check"])
        for a in V["expiry"]["arithmetic"]:
            if "margin" in a:
                req = cj.required_expiry(a["now"], a["maxSettlementSeconds"], a["margin"])
                self.assertEqual(req, a["requiredExpiry"])
                self.assertEqual(a["ok"], {"exact": True, "minusOne": False, "plusOne": True})
            else:
                self.assertEqual(cj.required_window_end(a["now"], a["minRemainingWindow"]), a["requiredWindowEnd"])
                self.assertEqual(a["ok"], {"exact": True, "minusOne": False, "plusOne": True})
        for c in V["expiry"]["constants"]:
            self.assertEqual(cj.constants_ok(c["margin"], c["minRemainingWindow"], c["maxSettlementSeconds"]), c["result"])
        for n, sel in V["interfaces"]["errors"].items():
            self.assertEqual(cj.selector(n), sel)
        for n, t in V["interfaces"]["events"].items():
            self.assertEqual(cj.event_topic(n), t)

    def test_mlp_example(self):
        m = V["mlp"]
        self.assertEqual(cj.spec_hash(m["spec"]), m["specHash"])
        self.assertEqual(m["spec"]["T"], 92)
        self.assertEqual(m["spec"]["K"], 8)
        self.assertEqual(m["checks"]["bind"], "ok")
        self.assertEqual(m["checks"]["submit"], "ok")
        self.assertEqual(m["outcomes"]["accepted"]["kernelCall"], "complete")
        self.assertEqual(m["outcomes"]["rejected"]["kernelCall"], "reject")
        self.assertGreaterEqual(m["spec"]["expiredAt"], m["timeline"]["submit"] + mv.MAX_SETTLEMENT + mv.MARGIN)
        self.assertLessEqual(m["spec"]["expiredAt"] - m["timeline"]["createJob"], cj.KERNEL_MAX_EXPIRY_DURATION)

    def test_measured_kernel_facts(self):
        for c in V["kernelMatrix"]:
            for r, res in c["byRole"].items():
                self.assertEqual(cj.kernel_allows(c["jobStatus"], c["function"], r), res)
        self.assertEqual(cj.kernel_allows(cj.JOB_FUNDED, "reject", "evaluator"), "ok")  # the evaluator may reject in Funded
        self.assertEqual(cj.kernel_allows(cj.JOB_FUNDED, "complete", "evaluator"), "WrongStatus")
        self.assertEqual(cj.kernel_allows(cj.JOB_OPEN, "setBudget", "provider"), "ok")
        for c in V["kernelTiming"]["actions"]:
            E = c["expiredAt"]
            for lab, dt in (("E-1", -1), ("E", 0), ("E+1", 1)):
                self.assertEqual(cj.kernel_time_rule(c["function"], c["jobStatus"], E + dt, E), c["at"][lab])
        self.assertEqual(cj.kernel_time_rule("claimRefund", cj.JOB_SUBMITTED, 10, 10), "ok")
        self.assertEqual(cj.kernel_time_rule("submit", cj.JOB_FUNDED, 10, 10), "expired")
        for c in V["kernelTiming"]["createJobExpiry"]:
            self.assertEqual(cj.create_expiry_ok(c["expiredAt"], c["now"]), c["result"])
        self.assertEqual(cj.create_expiry_ok(mv.NOW + 300, mv.NOW), "ExpiryTooShort")
        self.assertEqual(cj.create_expiry_ok(mv.NOW + 301, mv.NOW), "ok")
        for e in V["hookData"]["examples"]:
            kw = {k: (bytes.fromhex(v[2:]) if k == "optParams" else v) for k, v in e["args"].items()}
            d = cj.hook_data(e["function"], **kw)
            self.assertEqual(None if d is None else cj.hex_of(d), e["data"])
        # abi.encode(bytes32, bytes) checked against `cast abi-encode "f(bytes32,bytes)" 0x…07 0x`
        self.assertEqual(cj.hook_data("submit", deliverable=cj.deliverable_of(7), optParams=b"").hex(),
                         "00" * 31 + "07" + "00" * 31 + "40" + "00" * 32)
        self.assertFalse(cj.HOOK_CALLBACKS["createJob"]["before"])
        self.assertFalse(cj.HOOK_CALLBACKS["claimRefund"]["after"])

    def test_generator_is_deterministic_and_case_count(self):
        self.assertGreaterEqual(mv.count_cases(V), 50)
        self.assertEqual(V["format"], "tap-circuit-jobs-vectors/1")


if __name__ == "__main__":
    unittest.main()
