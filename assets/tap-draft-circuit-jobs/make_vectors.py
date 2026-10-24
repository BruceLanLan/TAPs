"""Write vectors.json for the TAP draft "Circuit Jobs: Settling Agent Jobs by a Dispute Game" (deterministic).

MIT licence. `python3 make_vectors.py` writes vectors.json; `--check` compares instead.
All data is synthetic; no chain was read and no transaction was sent. The kernel constants (HOOK_GAS_LIMIT,
MAX_EXPIRY_DURATION) and the deployed kernel addresses are copied from the draft's Specification 1.2.
"""
from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import circuit_jobs as cj  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "vectors.json")

NOW = 1_800_000_000  # a fixed block.timestamp for every case
KERNEL_56 = "0xea4daa3100a767e86fded867729ae7446476eba6"
KERNEL_97 = "0xa206c0517b6371c6638cd9e4a42cc9f02a33b0de"
EVALUATOR = "0x00000000000000000000000000000000000000e1"
GAME = "0x00000000000000000000000000000000000000d1"
OTHER_GAME = "0x00000000000000000000000000000000000000d2"
CLIENT = "0x00000000000000000000000000000000000000c1"
PROVIDER = "0x00000000000000000000000000000000000000b1"
INPUT_PROVIDER = "0x00000000000000000000000000000000000000a1"
STRANGER = "0x00000000000000000000000000000000000000f1"
ROUTER = "0x00000000000000000000000000000000000000f2"

MAX_SETTLEMENT = 1_368_992  # an arbitrary input chosen for these vectors (about 15.85 days); never recomputed here
MARGIN = 21_600
MIN_WINDOW = 21_600
NETLIST = "0x" + "11" * 32
INPUT_ROOT = "0x" + "22" * 32
CHECKPOINT_ROOT = "0x" + "33" * 32

EV = {"address": EVALUATOR, "kernel": KERNEL_56, "game": GAME, "inputProvider": cj.ZERO_ADDRESS,
      "margin": MARGIN, "minRemainingWindow": MIN_WINDOW, "maxSettlementSeconds": MAX_SETTLEMENT}
EV_B = dict(EV, inputProvider=INPUT_PROVIDER)  # an evaluator bound to a case-(b) game


def spec(**kw):
    s = {"game": GAME, "netlistHash2": NETLIST, "inputRoot": INPUT_ROOT, "T": 92, "K": 8,
         "budget": 5_000_000, "expiredAt": NOW + MAX_SETTLEMENT + MARGIN + 86_400, "inputProvider": cj.ZERO_ADDRESS}
    s.update(kw)
    return s


def job(**kw):
    j = {"client": CLIENT, "provider": PROVIDER, "evaluator": EVALUATOR, "hook": EVALUATOR, "status": cj.JOB_OPEN,
         "budget": 0, "expiredAt": NOW + MAX_SETTLEMENT + MARGIN + 86_400, "deliverable": cj.ZERO32}
    j.update(kw)
    return j


def claim(**kw):
    c = {"claimant": PROVIDER, "netlistHash2": NETLIST, "T": 92, "K": 8, "inputRoot": INPUT_ROOT,
         "checkpointRoot": CHECKPOINT_ROOT, "leaves": 13, "status": cj.CLAIM_OPEN, "windowEnd": NOW + 108_000}
    c.update(kw)
    return c


def interfaces():
    ids = cj.all_interface_ids()
    sel = {}
    for name, sigs in (("ITapClaimSummary", cj.I_TAP_CLAIM_SUMMARY), ("ITapSettlementBound", cj.I_TAP_SETTLEMENT_BOUND),
                       ("ITapInputProvider", cj.I_TAP_INPUT_PROVIDER), ("IACPHook", cj.I_ACP_HOOK),
                       ("ITapCircuitJob", cj.I_TAP_CIRCUIT_JOB)):
        sel[name] = {"id": ids[name], "selectors": {s: cj.selector(s) for s in sigs}}
    sel["game.accept"] = {cj.ACCEPT_SIG: cj.selector(cj.ACCEPT_SIG)}
    kernel = {k: {"signature": v, "selector": cj.selector(v)} for k, v in cj.KERNEL_SIGS.items()}
    return {
        "note": "a selector depends on argument types only: claimSummary(uint256) is 0x58d08546 with 8 and with 9 "
                "return values, and the single-function ERC-165 id of ITapClaimSummary is the same for both views; "
                "a caller tells them apart by the 288-byte return data (Specification 1.1)",
        "interfaces": sel,
        "kernel": {"chains": {"56": KERNEL_56, "97": KERNEL_97}, "functions": kernel,
                   "errors": {e: cj.selector(e) for e in cj.KERNEL_ERRORS},
                   "HOOK_GAS_LIMIT": cj.KERNEL_HOOK_GAS_LIMIT, "MAX_EXPIRY_DURATION": cj.KERNEL_MAX_EXPIRY_DURATION,
                   "MIN_EXPIRY_LEAD": cj.KERNEL_MIN_EXPIRY_LEAD, "forkBlock": cj.FORK_BLOCK,
                   "implementations": {"56": "0xe8d47866e2cc3dcaa50f0ad980355695b2f1d533", "97": "0x55c3826b39a0f671b2c3e5d0f1372cad0b911421"}},
        "events": {e: cj.event_topic(e) for e in cj.EVALUATOR_EVENTS},
        "errors": {e: cj.selector(e) for e in cj.EVALUATOR_ERRORS},
        "jobSpecTuple": cj.JOB_SPEC_TUPLE,
    }


def specs():
    out = []
    for name, s in (("mlp_case_a", spec()),
                    ("case_b_input_provider", spec(inputProvider=INPUT_PROVIDER, T=1024, K=16, budget=1)),
                    ("minimal", spec(T=1, K=1, budget=1, netlistHash2="0x" + "00" * 31 + "01", inputRoot=cj.ZERO32,
                                     expiredAt=NOW + MAX_SETTLEMENT + MARGIN)),
                    ("max_fields", spec(T=(1 << 64) - 1, K=(1 << 64) - 1, budget=(1 << 256) - 1,
                                        expiredAt=(1 << 64) - 1, netlistHash2="0x" + "ff" * 32, inputRoot="0x" + "ff" * 32))):
        enc = cj.spec_encode(s)
        out.append({"name": name, "spec": s, "encoded": cj.hex_of(enc), "encodedLength": len(enc), "specHash": cj.spec_hash(s)})
    return out


def deliverables():
    out = []
    for cid in (0, 1, 7, 255, 1 << 64, (1 << 256) - 1):
        d = cj.deliverable_of(cid)
        out.append({"claimId": str(cid), "deliverable": d, "decodes": str(cj.claim_id_of_deliverable(d))})
    reasons = []
    for cid, st in ((7, cj.CLAIM_ACCEPTED), (7, cj.CLAIM_REJECTED), (0, cj.CLAIM_ACCEPTED), (7, cj.CLAIM_OPEN)):
        reasons.append({"game": GAME, "claimId": str(cid), "status": st, "reason": cj.reason_of(GAME, cid, st)})
    return {"deliverable": out, "reason": reasons}


def decisions():
    out = []
    for st in range(0, 6):
        try:
            d = cj.decision(st)
            out.append({"claimStatus": st, "claimStatusName": cj.CLAIM_STATUS_NAMES[st], "check": d,
                        "decision": cj.DECISION_NAMES[d]})
        except cj.RuleError as e:
            out.append({"claimStatus": st, "claimStatusName": cj.CLAIM_STATUS_NAMES[st] if st < 5 else None,
                        "revert": str(e)})
    return out


def state_table():
    rows = []
    cases = [(cj.JOB_OPEN, False, None), (cj.JOB_OPEN, True, None), (cj.JOB_FUNDED, False, None), (cj.JOB_FUNDED, True, None),
             (cj.JOB_SUBMITTED, True, cj.CLAIM_OPEN), (cj.JOB_SUBMITTED, True, cj.CLAIM_REJECTED),
             (cj.JOB_SUBMITTED, True, cj.CLAIM_ACCEPTED), (cj.JOB_SUBMITTED, True, cj.CLAIM_ABANDONED),
             (cj.JOB_COMPLETED, True, cj.CLAIM_ACCEPTED), (cj.JOB_REJECTED, True, cj.CLAIM_REJECTED),
             (cj.JOB_EXPIRED, True, cj.CLAIM_OPEN), (cj.JOB_EXPIRED, True, cj.CLAIM_ACCEPTED)]
    for js, bound, cs in cases:
        rows.append({"jobStatus": js, "jobStatusName": cj.JOB_STATUS_NAMES[js], "bound": bound,
                     "claimStatus": cs, "claimStatusName": None if cs is None else cj.CLAIM_STATUS_NAMES[cs],
                     "row": cj.state_row(js, bound, cs)})
    return rows


def binds():
    exact = NOW + MAX_SETTLEMENT + MARGIN
    cases = [
        ("valid", job(), spec(), CLIENT, EV, False),
        ("valid_case_b", job(), spec(inputProvider=INPUT_PROVIDER), CLIENT, EV_B, False),
        ("valid_expiry_exact", job(expiredAt=exact), spec(expiredAt=exact), CLIENT, EV, False),
        ("J1_not_client", job(), spec(), PROVIDER, EV, False),
        ("J1_not_client_stranger", job(), spec(), STRANGER, EV, False),
        ("J1_not_open_funded", job(status=cj.JOB_FUNDED, budget=5_000_000), spec(), CLIENT, EV, False),
        ("J1_not_open_submitted", job(status=cj.JOB_SUBMITTED), spec(), CLIENT, EV, False),
        ("J1_evaluator_differs", job(evaluator=STRANGER), spec(), CLIENT, EV, False),
        ("J1_hook_differs", job(hook=ROUTER), spec(), CLIENT, EV, False),
        ("J1_already_bound", job(), spec(), CLIENT, EV, True),
        ("J1_other_game", job(), spec(game=OTHER_GAME), CLIENT, EV, False),
        ("J1_input_provider_mismatch", job(), spec(inputProvider=INPUT_PROVIDER), CLIENT, EV, False),
        ("J1_input_provider_missing", job(), spec(), CLIENT, EV_B, False),
        ("J1_input_provider_is_provider", job(provider=INPUT_PROVIDER), spec(inputProvider=INPUT_PROVIDER), CLIENT, EV_B, False),
        ("J1_T_zero", job(), spec(T=0), CLIENT, EV, False),
        ("J1_K_zero", job(), spec(K=0), CLIENT, EV, False),
        ("J1_budget_zero", job(), spec(budget=0), CLIENT, EV, False),
        ("J1_netlist_zero", job(), spec(netlistHash2=cj.ZERO32), CLIENT, EV, False),
        ("J1_expiry_mismatch", job(), spec(expiredAt=exact), CLIENT, EV, False),
        ("J2_expiry_one_second_short", job(expiredAt=exact - 1), spec(expiredAt=exact - 1), CLIENT, EV, False),
        ("J2_expiry_far_short", job(expiredAt=NOW + 3600), spec(expiredAt=NOW + 3600), CLIENT, EV, False),
    ]
    out = []
    for name, j, s, sender, ev, bound in cases:
        out.append({"name": name, "now": NOW, "sender": sender, "job": j, "spec": s, "alreadyBound": bound,
                    "evaluator": {k: ev[k] for k in ("address", "game", "inputProvider", "margin", "maxSettlementSeconds")},
                    "requiredExpiry": cj.required_expiry(NOW, ev["maxSettlementSeconds"], ev["margin"]),
                    "result": cj.bind_check(j, s, sender, NOW, ev, bound)})
    return out


def funds():
    s = spec()
    cases = [
        ("valid", job(budget=5_000_000), s, KERNEL_56),
        ("J10_not_kernel", job(budget=5_000_000), s, CLIENT),
        ("J1_not_bound", job(budget=5_000_000), None, KERNEL_56),
        ("budget_changed_after_bind", job(budget=4_999_999), s, KERNEL_56),
        ("budget_zero", job(budget=0), s, KERNEL_56),
    ]
    return [{"name": n, "sender": snd, "job": j, "bound": sp is not None, "result": cj.fund_check(j, sp, snd, EV)}
            for n, j, sp, snd in cases]


def submits():
    s = spec()
    sub = job(status=cj.JOB_SUBMITTED, budget=5_000_000, deliverable=cj.deliverable_of(7))
    exact_w = NOW + MIN_WINDOW
    cases = [
        ("valid", sub, s, claim(), KERNEL_56, EV, False),
        ("valid_window_exact", sub, s, claim(windowEnd=exact_w), KERNEL_56, EV, False),
        ("J10_not_kernel", sub, s, claim(), PROVIDER, EV, False),
        ("J1_not_bound", sub, None, claim(), KERNEL_56, EV, False),
        ("not_submitted_funded", job(status=cj.JOB_FUNDED, budget=5_000_000), s, claim(), KERNEL_56, EV, False),
        ("claim_already_bound", sub, s, claim(), KERNEL_56, EV, True),
        ("J5_short_return_data", sub, s, None, KERNEL_56, EV, False),
        ("J5_no_such_claim", sub, s, claim(status=cj.CLAIM_NONE), KERNEL_56, EV, False),
        ("J5_claimant_not_provider", sub, s, claim(claimant=STRANGER), KERNEL_56, EV, False),
        ("J5_netlist_differs", sub, s, claim(netlistHash2="0x" + "44" * 32), KERNEL_56, EV, False),
        ("J5_input_root_differs", sub, s, claim(inputRoot="0x" + "44" * 32), KERNEL_56, EV, False),
        ("J5_T_differs", sub, s, claim(T=93), KERNEL_56, EV, False),
        ("J5_K_differs", sub, s, claim(K=4), KERNEL_56, EV, False),
        ("J5_claim_accepted_already", sub, s, claim(status=cj.CLAIM_ACCEPTED), KERNEL_56, EV, False),
        ("J5_claim_rejected_already", sub, s, claim(status=cj.CLAIM_REJECTED), KERNEL_56, EV, False),
        ("J5_claim_abandoned", sub, s, claim(status=cj.CLAIM_ABANDONED), KERNEL_56, EV, False),
        ("J3_window_one_second_short", sub, s, claim(windowEnd=exact_w - 1), KERNEL_56, EV, False),
        ("J3_window_ended", sub, s, claim(windowEnd=NOW - 1), KERNEL_56, EV, False),
        ("J2_expiry_short_at_submit", dict(sub, expiredAt=NOW + MAX_SETTLEMENT + MARGIN - 1),
         dict(s, expiredAt=NOW + MAX_SETTLEMENT + MARGIN - 1), claim(), KERNEL_56, EV, False),
    ]
    out = []
    for name, j, sp, c, snd, ev, cb in cases:
        out.append({"name": name, "now": NOW, "sender": snd, "job": j, "bound": sp is not None,
                    "claimId": str(cj.claim_id_of_deliverable(j["deliverable"])), "claim": c,
                    "claimAlreadyBound": cb, "requiredWindowEnd": cj.required_window_end(NOW, ev["minRemainingWindow"]),
                    "requiredExpiry": cj.required_expiry(NOW, ev["maxSettlementSeconds"], ev["margin"]),
                    "result": cj.submit_check(j, sp, c, snd, NOW, ev, cb)})
    return out


def settles():
    sub = job(status=cj.JOB_SUBMITTED, budget=5_000_000, deliverable=cj.deliverable_of(7))
    cases = [
        ("no_claim", sub, None, False),
        ("already_settled", dict(sub, status=cj.JOB_COMPLETED), claim(status=cj.CLAIM_ACCEPTED), True),
        ("J6_pending_open", sub, claim(), False),
        ("J6_pending_abandoned", sub, claim(status=cj.CLAIM_ABANDONED), False),
        ("J6_expired_job_accepted_claim", dict(sub, status=cj.JOB_EXPIRED), claim(status=cj.CLAIM_ACCEPTED), False),
        ("J6_expired_job_rejected_claim", dict(sub, status=cj.JOB_EXPIRED), claim(status=cj.CLAIM_REJECTED), False),
        ("complete", sub, claim(status=cj.CLAIM_ACCEPTED), False),
        ("reject", sub, claim(status=cj.CLAIM_REJECTED), False),
    ]
    out = []
    for name, j, c, settled in cases:
        r, d = cj.settle_check(j, c, settled)
        row = {"name": name, "job": j, "claim": c, "settled": settled, "result": r}
        if d is not None:
            row["decision"] = cj.DECISION_NAMES[d]
            row["kernelCall"] = "complete" if d == cj.DECISION_COMPLETE else "reject"
            row["reason"] = cj.reason_of(GAME, 7, c["status"])
        out.append(row)
    return out


def hook_rules():
    cases = [
        ("fund_ok", {"selector": "fund", "gasUsed": 60_000, "externalStaticCalls": 1}),
        ("submit_ok_three_calls", {"selector": "submit", "gasUsed": 120_000, "externalStaticCalls": 3}),
        ("J7_gas_over_limit", {"selector": "submit", "gasUsed": 1_000_001, "externalStaticCalls": 3}),
        ("J7_gas_at_limit", {"selector": "submit", "gasUsed": 1_000_000, "externalStaticCalls": 3}),
        ("J7_four_static_calls", {"selector": "submit", "gasUsed": 120_000, "externalStaticCalls": 4}),
        ("J8_complete_calls_out", {"selector": "complete", "gasUsed": 30_000, "externalStaticCalls": 0, "callsOut": True}),
        ("J8_reject_calls_out", {"selector": "reject", "gasUsed": 30_000, "externalStaticCalls": 0, "callsOut": True}),
        ("J8_complete_records_only", {"selector": "complete", "gasUsed": 30_000, "externalStaticCalls": 0, "callsOut": False}),
        ("J8_setBudget_changes_state", {"selector": "setBudget", "gasUsed": 25_000, "externalStaticCalls": 0, "changesState": True}),
        ("J8_setBudget_no_effect", {"selector": "setBudget", "gasUsed": 25_000, "externalStaticCalls": 0, "changesState": False}),
        ("J10_not_from_kernel", {"selector": "fund", "gasUsed": 60_000, "externalStaticCalls": 1, "senderIsKernel": False}),
    ]
    return [{"name": n, "entry": e, "result": cj.hook_rule_check(e)} for n, e in cases]


def dispatch():
    out = []
    for phase in ("before", "after"):
        for k in ("createJob", "setProvider", "setBudget", "fund", "submit", "complete", "reject"):
            sel = cj.selector(cj.KERNEL_SIGS[k])
            out.append({"phase": phase, "kernelFunction": k, "selector": sel, "runs": cj.hook_dispatch(phase, sel)})
    out.append({"phase": "after", "kernelFunction": "unknown", "selector": "0xdeadbeef", "runs": cj.hook_dispatch("after", "0xdeadbeef")})
    return out


def expiry():
    out = {"arithmetic": [], "constants": [], "feasibility": []}
    for ms, m in ((MAX_SETTLEMENT, MARGIN), (302_464, MARGIN), (0, MARGIN), (MAX_SETTLEMENT, 86_400)):
        req = cj.required_expiry(NOW, ms, m)
        out["arithmetic"].append({"now": NOW, "maxSettlementSeconds": ms, "margin": m, "requiredExpiry": req,
                                  "ok": {"exact": cj.expiry_ok(req, NOW, ms, m), "minusOne": cj.expiry_ok(req - 1, NOW, ms, m),
                                         "plusOne": cj.expiry_ok(req + 1, NOW, ms, m)}})
    for w in (MIN_WINDOW, 108_000):
        req = cj.required_window_end(NOW, w)
        out["arithmetic"].append({"now": NOW, "minRemainingWindow": w, "requiredWindowEnd": req,
                                  "ok": {"exact": cj.window_ok(req, NOW, w), "minusOne": cj.window_ok(req - 1, NOW, w),
                                         "plusOne": cj.window_ok(req + 1, NOW, w)}})
    for name, m, w, ms in (("default", MARGIN, MIN_WINDOW, MAX_SETTLEMENT),
                           ("margin_below_minimum", MARGIN - 1, MIN_WINDOW, MAX_SETTLEMENT),
                           ("window_below_minimum", MARGIN, MIN_WINDOW - 1, MAX_SETTLEMENT),
                           ("infeasible_equal", MARGIN, MIN_WINDOW, cj.KERNEL_MAX_EXPIRY_DURATION - MARGIN),
                           ("feasible_by_one", MARGIN, MIN_WINDOW, cj.KERNEL_MAX_EXPIRY_DURATION - MARGIN - 1),
                           ("large_set_infeasible", MARGIN, MIN_WINDOW, 103_295_104)):
        out["constants"].append({"name": name, "margin": m, "minRemainingWindow": w, "maxSettlementSeconds": ms,
                                 "MAX_EXPIRY_DURATION": cj.KERNEL_MAX_EXPIRY_DURATION,
                                 "result": cj.constants_ok(m, w, ms)})
    # a job created at NOW with the kernel's longest expiry: how long the client has to bind and the provider to submit
    for ms in (MAX_SETTLEMENT, 302_464):
        exp = NOW + cj.KERNEL_MAX_EXPIRY_DURATION
        out["feasibility"].append({"createdAt": NOW, "expiredAt": exp, "maxSettlementSeconds": ms, "margin": MARGIN,
                                   "latestBindOrSubmitTime": cj.latest_bind_time(NOW, exp, ms, MARGIN),
                                   "secondsAvailable": cj.latest_bind_time(NOW, exp, ms, MARGIN) - NOW})
    return out


def mlp():
    s = spec()
    created = NOW
    expired = created + 1_900_800  # 22 days: covers maxSettlementSeconds (15.85 days) + margin (6 h) with room to submit
    s["expiredAt"] = expired
    j = job(expiredAt=expired)
    bind_at = created + 600
    fund_at = created + 1200
    claim_at = created + 3600
    window_end = claim_at + 108_000  # an example challenge window (30 hours), an input
    submit_at = claim_at + 300
    accepted_at = window_end + 1
    cid = 7
    return {
        "note": "the verifiable-inference demo of TAP-draft-large-netlists (pull request #74, draft under review): "
                "demo/inference of its reference repository BruceLanLan/tap-large-netlists at commit "
                "18e0c7bfb4c1fba7fe0bae3a6fa86d2863b1c3b3 (not yet in the commit #74 names): 64-16-10 MLP, tapnet/2 of "
                "88,854 bytes, T = 92, K = 8, 13 checkpoint leaves; disputes cost 2.6 to 6.7 million gas for all parties, "
                "the costliest move 4,961,813 gas (scenario G). Times are inputs chosen for the example "
                "(maxSettlementSeconds 1,368,992; challengeWindow 108,000).",
        "spec": s, "specHash": cj.spec_hash(s), "claimId": str(cid), "deliverable": cj.deliverable_of(cid),
        "timeline": {"createJob": created, "bindJob": bind_at, "fund": fund_at, "game.claim": claim_at,
                     "windowEnd": window_end, "submit": submit_at, "earliestAccept": accepted_at},
        "checks": {
            "bind": cj.bind_check(j, s, CLIENT, bind_at, EV),
            "bindRequiredExpiry": cj.required_expiry(bind_at, MAX_SETTLEMENT, MARGIN),
            "fund": cj.fund_check(dict(j, budget=s["budget"]), s, KERNEL_56, EV),
            "submit": cj.submit_check(dict(j, status=cj.JOB_SUBMITTED, budget=s["budget"], deliverable=cj.deliverable_of(cid)),
                                      s, claim(windowEnd=window_end), KERNEL_56, submit_at, EV),
            "submitRequiredWindowEnd": cj.required_window_end(submit_at, MIN_WINDOW),
            "submitRequiredExpiry": cj.required_expiry(submit_at, MAX_SETTLEMENT, MARGIN),
        },
        "outcomes": {
            "accepted": {"claimStatus": cj.CLAIM_ACCEPTED, "check": cj.decision(cj.CLAIM_ACCEPTED),
                         "kernelCall": "complete", "reason": cj.reason_of(GAME, cid, cj.CLAIM_ACCEPTED)},
            "rejected": {"claimStatus": cj.CLAIM_REJECTED, "check": cj.decision(cj.CLAIM_REJECTED),
                         "kernelCall": "reject", "reason": cj.reason_of(GAME, cid, cj.CLAIM_REJECTED)},
            "open": {"claimStatus": cj.CLAIM_OPEN, "check": cj.decision(cj.CLAIM_OPEN), "settle": "NotDecided"},
        },
        "gas": {"disputeAllPartiesMin": 2_627_766, "disputeAllPartiesMax": 6_731_163, "costliestMove": 4_961_813,
                "noDisputeAllParties": 362_959},
    }


def kernel_matrix():
    out = []
    for st in (cj.JOB_OPEN, cj.JOB_FUNDED, cj.JOB_SUBMITTED, cj.JOB_COMPLETED):
        for fn in cj.KERNEL_FUNCTIONS:
            out.append({"jobStatus": st, "jobStatusName": cj.JOB_STATUS_NAMES[st], "function": fn,
                        "byRole": {r: cj.kernel_allows(st, fn, r) for r in cj.ROLES}})
    return out


def kernel_timing():
    E = NOW + 1_000_000
    out = []
    for st, fn in ((cj.JOB_FUNDED, "claimRefund"), (cj.JOB_FUNDED, "submit"), (cj.JOB_FUNDED, "reject"),
                   (cj.JOB_SUBMITTED, "claimRefund"), (cj.JOB_SUBMITTED, "complete"), (cj.JOB_SUBMITTED, "reject"),
                   (cj.JOB_OPEN, "claimRefund")):
        out.append({"jobStatus": st, "jobStatusName": cj.JOB_STATUS_NAMES[st], "function": fn, "expiredAt": E,
                    "at": {"E-1": cj.kernel_time_rule(fn, st, E - 1, E), "E": cj.kernel_time_rule(fn, st, E, E),
                           "E+1": cj.kernel_time_rule(fn, st, E + 1, E)},
                    "settlementGuaranteed": {"E-1": cj.settlement_guaranteed(E - 1, E), "E": cj.settlement_guaranteed(E, E)}})
    create = []
    for d in (299, 300, 301, cj.KERNEL_MAX_EXPIRY_DURATION, cj.KERNEL_MAX_EXPIRY_DURATION + 1):
        create.append({"now": NOW, "expiredAt": NOW + d, "lead": d, "result": cj.create_expiry_ok(NOW + d, NOW)})
    return {"note": "measured on a local fork of chain 56 at block %d: claimRefund needs ts >= expiredAt and Funded or "
                    "Submitted; submit needs ts < expiredAt; complete and reject have no time rule, so after expiredAt "
                    "settle races claimRefund" % cj.FORK_BLOCK, "actions": out, "createJobExpiry": create}


def hook_data():
    out = {"callbacks": cj.HOOK_CALLBACKS, "measuredEntryGas": cj.HOOK_ENTRY_GAS_MEASURED, "examples": []}
    ex = [("createJob", {"client": CLIENT, "provider": PROVIDER, "evaluator": EVALUATOR}),
          ("setProvider", {"provider": PROVIDER, "optParams": b""}),
          ("setBudget", {"budget": 5_000_000, "optParams": b""}),
          ("fund", {"optParams": b""}), ("fund", {"optParams": bytes.fromhex("ccdd")}),
          ("submit", {"deliverable": cj.deliverable_of(7), "optParams": b""}),
          ("submit", {"deliverable": cj.deliverable_of(7), "optParams": bytes.fromhex("0102")}),
          ("complete", {"reason": cj.reason_of(GAME, 7, cj.CLAIM_ACCEPTED), "optParams": b""}),
          ("reject", {"reason": cj.reason_of(GAME, 7, cj.CLAIM_REJECTED), "optParams": b""}),
          ("claimRefund", {})]
    for fn, kw in ex:
        d = cj.hook_data(fn, **kw)
        args = {k: (cj.hex_of(v) if isinstance(v, bytes) else v) for k, v in kw.items()}
        out["examples"].append({"function": fn, "selector": cj.selector(cj.KERNEL_SIGS[fn]), "args": args,
                                "data": None if d is None else cj.hex_of(d), "dataLength": None if d is None else len(d)})
    return out


def main() -> None:
    vec = {
        "format": "tap-circuit-jobs-vectors/1",
        "note": "Synthetic vectors for TAP-draft-circuit-jobs. Addresses are placeholders except the two kernel proxies. "
                "maxSettlementSeconds is an arbitrary input chosen for the vectors, never recomputed here.",
        "constants": {"now": NOW, "margin": MARGIN, "minRemainingWindow": MIN_WINDOW, "maxSettlementSeconds": MAX_SETTLEMENT,
                      "MIN_MARGIN": cj.MIN_MARGIN, "MIN_MIN_REMAINING_WINDOW": cj.MIN_MIN_REMAINING_WINDOW,
                      "MAX_EXTERNAL_STATIC_CALLS": cj.MAX_EXTERNAL_STATIC_CALLS,
                      "ACCEPT_GAS_CAP": cj.ACCEPT_GAS_CAP,
                      "jobStatus": {n: i for i, n in enumerate(cj.JOB_STATUS_NAMES)},
                      "claimStatus": {n: i for i, n in enumerate(cj.CLAIM_STATUS_NAMES)},
                      "decision": {n: i for i, n in enumerate(cj.DECISION_NAMES)}},
        "interfaces": interfaces(),
        "spec": specs(),
        "deliverable": deliverables(),
        "decision": decisions(),
        "stateTable": state_table(),
        "bind": binds(),
        "fund": funds(),
        "submit": submits(),
        "settle": settles(),
        "hookRules": hook_rules(),
        "dispatch": dispatch(),
        "expiry": expiry(),
        "kernelMatrix": kernel_matrix(),
        "kernelTiming": kernel_timing(),
        "hookData": hook_data(),
        "mlp": mlp(),
    }
    text = json.dumps(vec, indent=1, ensure_ascii=False) + "\n"
    if "--check" in sys.argv:
        with open(OUT, "r", encoding="utf-8") as f:
            old = f.read()
        if old != text:
            print("vectors.json differs from the generator's output")
            sys.exit(1)
        print("vectors.json matches")
        return
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    n = count_cases(vec)
    print("wrote %s (%d cases)" % (OUT, n))


def count_cases(vec) -> int:
    n = 0
    for k in ("spec", "decision", "stateTable", "bind", "fund", "submit", "settle", "hookRules", "dispatch"):
        n += len(vec[k])
    n += len(vec["deliverable"]["deliverable"]) + len(vec["deliverable"]["reason"])
    n += sum(len(vec["expiry"][k]) for k in vec["expiry"])
    n += len(vec["mlp"]["outcomes"])
    n += len(vec["kernelMatrix"]) + len(vec["kernelTiming"]["actions"]) + len(vec["kernelTiming"]["createJobExpiry"])
    n += len(vec["hookData"]["examples"])
    for v in vec["interfaces"]["interfaces"].values():
        n += len(v.get("selectors", v))
    return n


if __name__ == "__main__":
    main()
