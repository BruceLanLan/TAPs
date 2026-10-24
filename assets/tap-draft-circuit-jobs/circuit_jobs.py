"""Reference functions for the TAP draft "Circuit Jobs: Settling Agent Jobs by a Dispute Game".

MIT licence. Python 3.9+, standard library only. Pure functions: nothing here reads a chain or sends a
transaction. The module fixes the encodings and the decision rules the draft cites:

- a small keccak-256, function selectors and ERC-165 identifiers (Specification 1);
- the job spec, its ABI encoding and `specHash`, the deliverable and the `reason` value (Specification 3, 5);
- the kernel job states and the claim states, the state table and the decision function (Specification 4, 6);
- the expiry and window arithmetic of J-2 and J-3, and the feasibility rule of J-10;
- `bind_check` and `submit_check`, which return the first broken rule of `bindJob` and `afterAction(submit)`
  exactly in the order the draft lists them, and `hook_rule_check` for the rules J-7 to J-10 that a static
  review of a contract checks.

All numbers are integers; addresses and 32-byte values are `0x` + lowercase hexadecimal strings.
"""
from __future__ import annotations

from typing import Dict, List, Optional, Sequence, Tuple

# ---------------------------------------------------------------------------
# keccak-256 (FIPS 202 Keccak-f[1600], padding 0x01 ... 0x80)
# ---------------------------------------------------------------------------

_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M64 = (1 << 64) - 1


def _rol(v: int, n: int) -> int:
    return ((v << n) | (v >> (64 - n))) & _M64 if n else v


def _keccak_f(a: list) -> list:
    for rc in _RC:
        c = [a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        a = [a[i] ^ d[i % 5] for i in range(25)]
        b = [0] * 25
        for x in range(5):
            for y in range(5):
                b[y + 5 * ((2 * x + 3 * y) % 5)] = _rol(a[x + 5 * y], _ROT[x][y])
        a = [b[i] ^ ((~b[(i % 5 + 1) % 5 + 5 * (i // 5)]) & b[(i % 5 + 2) % 5 + 5 * (i // 5)]) for i in range(25)]
        a[0] ^= rc
    return a


def keccak256(data: bytes) -> bytes:
    rate = 136
    msg = bytearray(data)
    msg.append(0x01)
    while len(msg) % rate:
        msg.append(0)
    msg[-1] |= 0x80
    st = [0] * 25
    for off in range(0, len(msg), rate):
        for i in range(rate // 8):
            st[i] ^= int.from_bytes(msg[off + 8 * i: off + 8 * i + 8], "little")
        st = _keccak_f(st)
    return b"".join(st[i].to_bytes(8, "little") for i in range(4))


# ---------------------------------------------------------------------------
# hex helpers, selectors, interface identifiers
# ---------------------------------------------------------------------------

def hex_of(b: bytes) -> str:
    return "0x" + b.hex()


def bytes_of(h: str, n: Optional[int] = None) -> bytes:
    if not isinstance(h, str) or not h.startswith("0x") or len(h) % 2:
        raise ValueError("hex string expected")
    b = bytes.fromhex(h[2:])
    if n is not None and len(b) != n:
        raise ValueError("expected %d bytes, got %d" % (n, len(b)))
    return b


def selector(signature: str) -> str:
    """The 4-byte function selector of a canonical signature such as `claimSummary(uint256)`."""
    return hex_of(keccak256(signature.encode("ascii"))[:4])


def event_topic(signature: str) -> str:
    return hex_of(keccak256(signature.encode("ascii")))


def interface_id(signatures: Sequence[str]) -> str:
    """ERC-165 identifier: the exclusive or of the selectors of every function of the interface."""
    acc = 0
    for s in signatures:
        acc ^= int(selector(s)[2:], 16)
    return "0x%08x" % acc


# The game views a usable game offers (Specification 1). Return types do not enter a selector, so
# `claimSummary(uint256)` has the same selector with 8 and with 9 return values.
CLAIM_SUMMARY_SIG = "claimSummary(uint256)"
MAX_SETTLEMENT_SIG = "maxSettlementSeconds()"
INPUT_PROVIDER_SIG = "inputProvider()"
ACCEPT_SIG = "accept(uint256)"

I_TAP_CLAIM_SUMMARY = [CLAIM_SUMMARY_SIG]
I_TAP_SETTLEMENT_BOUND = [MAX_SETTLEMENT_SIG]
I_TAP_INPUT_PROVIDER = [INPUT_PROVIDER_SIG]

# The hook interface of the deployed kernel (Specification 1.2).
I_ACP_HOOK = ["beforeAction(uint256,bytes4,bytes)", "afterAction(uint256,bytes4,bytes)"]

# Kernel functions the evaluator calls or whose selectors it dispatches on (deployed ABI).
KERNEL_SIGS = {
    "createJob": "createJob(address,address,uint256,string,address)",
    "setProvider": "setProvider(uint256,address,bytes)",
    "setBudget": "setBudget(uint256,uint256,bytes)",
    "fund": "fund(uint256,uint256,bytes)",
    "submit": "submit(uint256,bytes32,bytes)",
    "complete": "complete(uint256,bytes32,bytes)",
    "reject": "reject(uint256,bytes32,bytes)",
    "claimRefund": "claimRefund(uint256)",
    "getJob": "getJob(uint256)",
    "HOOK_GAS_LIMIT": "HOOK_GAS_LIMIT()",
    "MAX_EXPIRY_DURATION": "MAX_EXPIRY_DURATION()",
}
KERNEL_ERRORS = ["HookRequired()", "HookMissingInterface()", "HookCallFailed()", "WrongStatus()",
                 "BudgetMismatch()", "ExpiryTooShort()", "ExpiryTooLong()", "ZeroBudget()",
                 "ReentrancyGuardReentrantCall()", "EnforcedPause()"]

JOB_SPEC_TUPLE = "(address,bytes32,bytes32,uint64,uint64,uint256,uint64,address)"

# The evaluator's own interface (Specification 2). Its ERC-165 identifier is the exclusive or of these.
I_TAP_CIRCUIT_JOB = [
    "bindJob(uint256,%s)" % JOB_SPEC_TUPLE,
    "specOf(uint256)",
    "specHashOf(uint256)",
    "claimIdOf(uint256)",
    "check(uint256)",
    "settle(uint256)",
    "kernel()",
    "game()",
    "margin()",
    "minRemainingWindow()",
]
EVALUATOR_EVENTS = [
    "JobBound(uint256,bytes32,address)",
    "ClaimBound(uint256,uint256)",
    "JobSettled(uint256,uint8,bytes32)",
]
EVALUATOR_ERRORS = [
    "NotKernel()", "NotClient()", "NotOpen()", "NotEvaluator()", "AlreadyBound()", "NotBound()",
    "BadGame()", "BadInputProvider()", "BadSpec()", "ExpiryMismatch()", "ExpiryTooSoon(uint256)",
    "BudgetMismatch()", "NotSubmitted()", "BadDeliverable()", "ClaimMismatch()", "ClaimNotOpen()",
    "WindowTooShort(uint256)", "NoClaim()", "NotDecided()", "AlreadySettled()",
]


def all_interface_ids() -> Dict[str, str]:
    return {
        "ITapClaimSummary": interface_id(I_TAP_CLAIM_SUMMARY),
        "ITapSettlementBound": interface_id(I_TAP_SETTLEMENT_BOUND),
        "ITapInputProvider": interface_id(I_TAP_INPUT_PROVIDER),
        "IACPHook": interface_id(I_ACP_HOOK),
        "ITapCircuitJob": interface_id(I_TAP_CIRCUIT_JOB),
        "ERC165": interface_id(["supportsInterface(bytes4)"]),
    }


# ---------------------------------------------------------------------------
# ABI encoding of static types
# ---------------------------------------------------------------------------

_UINT_BITS = {"uint8": 8, "uint32": 32, "uint64": 64, "uint128": 128, "uint256": 256}


def abi_word(typ: str, value) -> bytes:
    if typ == "address":
        b = bytes_of(value, 20)
        return b"\x00" * 12 + b
    if typ == "bytes32":
        return bytes_of(value, 32)
    if typ == "bool":
        return (1 if value else 0).to_bytes(32, "big")
    if typ in _UINT_BITS:
        if not isinstance(value, int) or value < 0 or value >= 1 << _UINT_BITS[typ]:
            raise ValueError("%s out of range: %r" % (typ, value))
        return value.to_bytes(32, "big")
    raise ValueError("unsupported type " + typ)


def abi_encode(types: Sequence[str], values: Sequence) -> bytes:
    """`abi.encode` for static types only (every value takes one 32-byte word)."""
    if len(types) != len(values):
        raise ValueError("arity")
    return b"".join(abi_word(t, v) for t, v in zip(types, values))


# ---------------------------------------------------------------------------
# constants of the pinned kernel and of the evaluator
# ---------------------------------------------------------------------------

KERNEL_MAX_EXPIRY_DURATION = 31_536_000  # MAX_EXPIRY_DURATION() of the pinned implementation, seconds
KERNEL_HOOK_GAS_LIMIT = 1_000_000  # HOOK_GAS_LIMIT() of the pinned implementation
MIN_MARGIN = 21_600  # J-2: lower bound of the immutable MARGIN, seconds
MIN_MIN_REMAINING_WINDOW = 21_600  # J-3: lower bound of the immutable MIN_REMAINING_WINDOW, seconds
MAX_EXTERNAL_STATIC_CALLS = 3  # J-7: external static calls per hook entry
ACCEPT_GAS_CAP = 200_000  # §6.2: gas given to the optional game.accept(claimId) inside settle; its failure is ignored
REFERENCE_HOOK_GAS_TARGET = 300_000  # J-7: what the reference implementation targets per entry

# Job states of the kernel, in the order of its status enum (Open, Funded, Submitted, Completed, Rejected,
# Expired); the ordinal values were pinned by the fork measurement M-4 (Specification 0.1 and Annex B of the draft).
JOB_OPEN, JOB_FUNDED, JOB_SUBMITTED, JOB_COMPLETED, JOB_REJECTED, JOB_EXPIRED = range(6)
JOB_STATUS_NAMES = ["Open", "Funded", "Submitted", "Completed", "Rejected", "Expired"]
TERMINAL_JOB_STATES = (JOB_COMPLETED, JOB_REJECTED, JOB_EXPIRED)

# Claim states of `claimSummary` (Specification 1.1).
CLAIM_NONE, CLAIM_OPEN, CLAIM_REJECTED, CLAIM_ACCEPTED, CLAIM_ABANDONED = range(5)
CLAIM_STATUS_NAMES = ["none", "open", "rejected", "accepted", "abandoned"]

DECISION_PENDING, DECISION_COMPLETE, DECISION_REJECT = 0, 1, 2
DECISION_NAMES = ["pending", "complete", "reject"]

ZERO_ADDRESS = "0x" + "00" * 20
ZERO32 = "0x" + "00" * 32


class RuleError(ValueError):
    """Raised with the name of the evaluator error that the contract reverts with."""


# ---------------------------------------------------------------------------
# job spec, deliverable, reason (Specification 3 and 5)
# ---------------------------------------------------------------------------

SPEC_FIELDS = ["game", "netlistHash2", "inputRoot", "T", "K", "budget", "expiredAt", "inputProvider"]
SPEC_TYPES = ["address", "bytes32", "bytes32", "uint64", "uint64", "uint256", "uint64", "address"]


def spec_encode(spec: Dict) -> bytes:
    """`abi.encode` of the JobSpec tuple: 8 words, 256 bytes, in the field order of SPEC_FIELDS."""
    return abi_encode(SPEC_TYPES, [spec[f] for f in SPEC_FIELDS])


def spec_hash(spec: Dict) -> str:
    return hex_of(keccak256(spec_encode(spec)))


def deliverable_of(claim_id: int) -> str:
    """The deliverable of a submission: the claim id as a 32-byte big-endian word (Specification 5)."""
    return hex_of(abi_word("uint256", claim_id))


def claim_id_of_deliverable(deliverable: str) -> int:
    return int.from_bytes(bytes_of(deliverable, 32), "big")


def reason_of(game: str, claim_id: int, status: int) -> str:
    """`reason` passed to `complete` or `reject`: keccak256(abi.encode(game, claimId, status))."""
    return hex_of(keccak256(abi_encode(["address", "uint256", "uint8"], [game, claim_id, status])))


# ---------------------------------------------------------------------------
# decision and state table (Specification 4 and 6)
# ---------------------------------------------------------------------------

def decision(claim_status: int) -> int:
    """J-4: the decision is a function of the claim state alone. Status 0 (no claim) reverts."""
    if claim_status == CLAIM_NONE:
        raise RuleError("NoClaim")
    if claim_status == CLAIM_OPEN or claim_status == CLAIM_ABANDONED:
        return DECISION_PENDING
    if claim_status == CLAIM_ACCEPTED:
        return DECISION_COMPLETE
    if claim_status == CLAIM_REJECTED:
        return DECISION_REJECT
    raise RuleError("BadGame")  # a status outside 0..4 is not a claim state of Specification 1.1


def state_row(job_status: int, bound: bool, claim_status: Optional[int]) -> Dict:
    """One row of the state table: what the evaluator does for a kernel job in `job_status`.

    `bound`: `bindJob` succeeded. `claim_status`: the state of the bound claim, or None before `submit`.
    Returns the evaluator's reaction and the kernel action that ends the job.
    """
    if job_status == JOB_OPEN:
        return {"bindJob": "allowed" if not bound else "AlreadyBound", "fund": "allowed" if bound else "NotBound",
                "check": "NotBound" if not bound else "NoClaim", "settle": "NotBound" if not bound else "NoClaim",
                "endsBy": "kernel: client reject / expiry"}
    if job_status == JOB_FUNDED:
        return {"bindJob": "NotOpen", "submit": "checked by afterAction(submit)" if bound else "NotBound",
                "check": "NoClaim" if bound else "NotBound", "settle": "NoClaim" if bound else "NotBound",
                "endsBy": "kernel: claimRefund after expiredAt"}
    if job_status == JOB_SUBMITTED:
        if claim_status is None:
            raise ValueError("a Submitted job bound to this evaluator has a claim")
        d = decision(claim_status)
        row = {"bindJob": "NotOpen", "check": DECISION_NAMES[d]}
        if d == DECISION_PENDING:
            row["settle"] = "NotDecided"
            row["endsBy"] = "game decides, then settle; or kernel: claimRefund after expiredAt"
        elif d == DECISION_COMPLETE:
            row["settle"] = "kernel.complete -> Completed, budget to provider"
            row["endsBy"] = "settle"
        else:
            row["settle"] = "kernel.reject -> Rejected, budget to client"
            row["endsBy"] = "settle"
        return row
    if job_status in TERMINAL_JOB_STATES:
        # check is a function of the claim state alone (J-4), also after the job ended; settle reverts
        # AlreadySettled once it settled the job and NotSubmitted for a job the kernel expired (J-6).
        chk = "NoClaim" if claim_status is None else DECISION_NAMES[decision(claim_status)]
        return {"bindJob": "NotOpen", "check": chk,
                "settle": "AlreadySettled" if job_status != JOB_EXPIRED else "NotSubmitted",
                "endsBy": "terminal"}
    raise ValueError("unknown job status %r" % job_status)


# ---------------------------------------------------------------------------
# expiry and window arithmetic (J-2, J-3, J-10)
# ---------------------------------------------------------------------------

def required_expiry(now: int, max_settlement_seconds: int, margin: int) -> int:
    """J-2: the smallest `expiredAt` the evaluator accepts at time `now`."""
    return now + max_settlement_seconds + margin


def expiry_ok(expired_at: int, now: int, max_settlement_seconds: int, margin: int) -> bool:
    return expired_at >= required_expiry(now, max_settlement_seconds, margin)


def required_window_end(now: int, min_remaining_window: int) -> int:
    """J-3: the smallest `windowEnd` of a claim the evaluator accepts at submission time `now`."""
    return now + min_remaining_window


def window_ok(window_end: int, now: int, min_remaining_window: int) -> bool:
    return window_end >= required_window_end(now, min_remaining_window)


def constants_ok(margin: int, min_remaining_window: int, max_settlement_seconds: int,
                 max_expiry_duration: int = KERNEL_MAX_EXPIRY_DURATION) -> str:
    """Constructor rule: returns "ok" or the first broken condition on the immutables (J-2, J-3, J-10)."""
    if margin < MIN_MARGIN:
        return "margin-below-minimum"
    if min_remaining_window < MIN_MIN_REMAINING_WINDOW:
        return "minRemainingWindow-below-minimum"
    if max_settlement_seconds + margin >= max_expiry_duration:
        return "infeasible-expiry"  # no job could ever satisfy both the kernel's ExpiryTooLong and J-2
    return "ok"


def latest_bind_time(created_at: int, expired_at: int, max_settlement_seconds: int, margin: int) -> int:
    """The last `block.timestamp` at which J-2 still holds for a job created at `created_at`."""
    return expired_at - max_settlement_seconds - margin


# ---------------------------------------------------------------------------
# bindJob and afterAction(submit): first broken rule, in the order of the draft
# ---------------------------------------------------------------------------

def bind_check(job: Dict, spec: Dict, sender: str, now: int, ev: Dict, already_bound: bool = False) -> str:
    """Specification 3.2: the checks of `bindJob(jobId, spec)` in order; returns "ok" or the error name.

    `job`: the kernel's `getJob` (keys client, provider, evaluator, hook, status, budget, expiredAt).
    `ev`: the evaluator (keys address, kernel, game, inputProvider, margin, minRemainingWindow,
    maxSettlementSeconds).
    """
    if sender.lower() != job["client"].lower():
        return "NotClient"
    if job["status"] != JOB_OPEN:
        return "NotOpen"
    if job["evaluator"].lower() != ev["address"].lower() or job["hook"].lower() != ev["address"].lower():
        return "NotEvaluator"  # J-1
    if already_bound:
        return "AlreadyBound"
    if spec["game"].lower() != ev["game"].lower():
        return "BadGame"
    if spec["inputProvider"].lower() != ev["inputProvider"].lower():
        return "BadInputProvider"
    if spec["inputProvider"] != ZERO_ADDRESS and spec["inputProvider"].lower() == job["provider"].lower():
        return "BadInputProvider"  # case (b) with the provider as input provider: unchallengeable
    if spec["T"] < 1 or spec["K"] < 1 or spec["budget"] < 1 or spec["netlistHash2"] == ZERO32:
        return "BadSpec"
    if spec["expiredAt"] != job["expiredAt"]:
        return "ExpiryMismatch"
    if not expiry_ok(job["expiredAt"], now, ev["maxSettlementSeconds"], ev["margin"]):
        return "ExpiryTooSoon"  # J-2 at binding
    return "ok"


def fund_check(job: Dict, spec: Optional[Dict], sender: str, ev: Dict) -> str:
    """Specification 3.3: `beforeAction(fund)`; returns "ok" or the error name."""
    if sender.lower() != ev["kernel"].lower():
        return "NotKernel"  # J-10
    if spec is None:
        return "NotBound"
    if job["budget"] != spec["budget"]:
        return "BudgetMismatch"
    return "ok"


def submit_check(job: Dict, spec: Optional[Dict], claim: Optional[Dict], sender: str, now: int, ev: Dict,
                 claim_already_bound: bool = False) -> str:
    """Specification 5: the checks of `afterAction(submit)` in order; returns "ok" or the error name.

    `claim`: the game's `claimSummary(claimId)` for `claimId = uint256(job.deliverable)`, or None when the
    evaluator could not decode a claim (a `claimSummary` answer shorter than 288 bytes is `BadGame`).
    """
    if sender.lower() != ev["kernel"].lower():
        return "NotKernel"
    if spec is None:
        return "NotBound"
    if job["status"] != JOB_SUBMITTED:
        return "NotSubmitted"
    if claim_already_bound:
        return "AlreadyBound"
    if claim is None:
        return "BadGame"
    if claim["status"] == CLAIM_NONE:
        return "BadDeliverable"
    if claim["claimant"].lower() != job["provider"].lower():
        return "ClaimMismatch"
    for f in ("netlistHash2", "inputRoot", "T", "K"):
        if claim[f] != spec[f]:
            return "ClaimMismatch"
    if claim["status"] != CLAIM_OPEN:
        return "ClaimNotOpen"
    if not window_ok(claim["windowEnd"], now, ev["minRemainingWindow"]):
        return "WindowTooShort"  # J-3
    if not expiry_ok(job["expiredAt"], now, ev["maxSettlementSeconds"], ev["margin"]):
        return "ExpiryTooSoon"  # J-2 at submission
    return "ok"


def settle_check(job: Dict, claim: Optional[Dict], settled: bool) -> Tuple[str, Optional[int]]:
    """Specification 6: `settle(jobId)`; returns ("ok", decision) or (error name, None)."""
    if claim is None:
        return ("NoClaim", None)
    if settled:
        return ("AlreadySettled", None)
    d = decision(claim["status"])
    if d == DECISION_PENDING:
        return ("NotDecided", None)
    if job["status"] != JOB_SUBMITTED:
        return ("NotSubmitted", None)  # J-6: never reject or complete a job that is not Submitted
    return ("ok", d)


def hook_rule_check(entry: Dict) -> str:
    """Static rules on one hook entry (J-7, J-8, J-10): returns "ok" or the broken rule.

    `entry`: selector name, gasUsed, externalStaticCalls, callsOut (writes or calls after recording),
    changesState (for entries other than fund/submit/complete/reject), senderIsKernel.
    """
    if not entry.get("senderIsKernel", True):
        return "J-10: entry not from the pinned kernel must revert"
    if entry["gasUsed"] > KERNEL_HOOK_GAS_LIMIT:
        return "J-7: entry exceeds HOOK_GAS_LIMIT"
    if entry.get("externalStaticCalls", 0) > MAX_EXTERNAL_STATIC_CALLS:
        return "J-7: more than three external static calls"
    if entry["selector"] in ("complete", "reject") and entry.get("callsOut", False):
        return "J-8: afterAction(complete|reject) only records and emits"
    if entry["selector"] not in ("fund", "submit", "complete", "reject") and entry.get("changesState", False):
        return "J-8: other entries return without effect"
    return "ok"


def hook_dispatch(phase: str, kernel_selector: str) -> str:
    """Which check a hook entry runs (Specification 3.3, 5, 6): 'fund', 'submit', 'terminal' or 'none'."""
    sel = {KERNEL_SIGS[k]: k for k in KERNEL_SIGS}
    name = sel.get(kernel_selector, None)
    if name is None:
        for k, sig in KERNEL_SIGS.items():
            if selector(sig) == kernel_selector:
                name = k
    if phase == "before" and name == "fund":
        return "fund"
    if phase == "after" and name == "submit":
        return "submit"
    if phase == "after" and name in ("complete", "reject"):
        return "terminal"
    return "none"


# ---------------------------------------------------------------------------
# facts measured on a local fork of chain 56 at block 129,352,831 (Specification 0.1, table M)
# ---------------------------------------------------------------------------

FORK_BLOCK = 129_352_831
KERNEL_MIN_EXPIRY_LEAD = 300  # createJob: expiredAt > now + 300 (strict), measured
HOOK_ENTRY_GAS_MEASURED = {"beforeAction": 993_935, "afterAction": 998_845}  # gasleft() at entry, informative

# Which hook phases the kernel calls for each function, and how `data` is encoded (measured).
HOOK_CALLBACKS = {
    "createJob": {"before": False, "after": True, "data": "abi.encode(address client, address provider, address evaluator)"},
    "setProvider": {"before": True, "after": True, "data": "abi.encode(address provider, bytes optParams)"},
    "setBudget": {"before": True, "after": True, "data": "abi.encode(uint256 budget, bytes optParams)"},
    "fund": {"before": True, "after": True, "data": "optParams (raw bytes, no ABI wrapping, no expectedBudget)"},
    "submit": {"before": True, "after": True, "data": "abi.encode(bytes32 deliverable, bytes optParams)"},
    "complete": {"before": True, "after": True, "data": "abi.encode(bytes32 reason, bytes optParams)"},
    "reject": {"before": True, "after": True, "data": "abi.encode(bytes32 reason, bytes optParams)"},
    "claimRefund": {"before": False, "after": False, "data": None},
}


def abi_encode_static_then_bytes(static_types: Sequence[str], static_values: Sequence, tail: bytes) -> bytes:
    """`abi.encode(static..., bytes)`: the static words, the offset word, then length and right-padded bytes."""
    head = abi_encode(static_types, static_values)
    offset = (len(static_types) + 1) * 32
    padded = tail + b"\x00" * ((32 - len(tail) % 32) % 32)
    return head + offset.to_bytes(32, "big") + len(tail).to_bytes(32, "big") + padded


def hook_data(function: str, **kw) -> Optional[bytes]:
    """The `data` the kernel passes to its hook for `function` (measured encodings)."""
    if function == "createJob":
        return abi_encode(["address", "address", "address"], [kw["client"], kw["provider"], kw["evaluator"]])
    if function == "setProvider":
        return abi_encode_static_then_bytes(["address"], [kw["provider"]], kw.get("optParams", b""))
    if function == "setBudget":
        return abi_encode_static_then_bytes(["uint256"], [kw["budget"]], kw.get("optParams", b""))
    if function == "fund":
        return kw.get("optParams", b"")
    if function == "submit":
        return abi_encode_static_then_bytes(["bytes32"], [kw["deliverable"]], kw.get("optParams", b""))
    if function in ("complete", "reject"):
        return abi_encode_static_then_bytes(["bytes32"], [kw["reason"]], kw.get("optParams", b""))
    if function == "claimRefund":
        return None
    raise ValueError(function)


# Authorisation matrix of the kernel: (job status, function) -> set of roles whose call does not revert.
# Roles: client, provider, evaluator, anyone. Measured with eth_call and transactions; the time rules of
# `kernel_time_rule` apply in addition.
_MATRIX = {
    (JOB_OPEN, "setProvider"): {"client"},  # once, while the provider is unset; ProviderAlreadySet afterwards
    (JOB_OPEN, "setBudget"): {"client", "provider"},
    (JOB_OPEN, "fund"): {"client"},  # ZeroBudget when the budget is 0; ProviderNotSet when the provider is 0
    (JOB_OPEN, "reject"): {"client"},
    (JOB_FUNDED, "submit"): {"provider"},
    (JOB_FUNDED, "reject"): {"evaluator"},
    (JOB_FUNDED, "claimRefund"): {"anyone"},  # only at or after expiredAt
    (JOB_SUBMITTED, "complete"): {"evaluator"},
    (JOB_SUBMITTED, "reject"): {"evaluator"},
    (JOB_SUBMITTED, "claimRefund"): {"anyone"},  # only at or after expiredAt
}
KERNEL_FUNCTIONS = ["setProvider", "setBudget", "fund", "submit", "complete", "reject", "claimRefund"]
ROLES = ["client", "provider", "evaluator", "stranger"]


def kernel_allows(job_status: int, function: str, role: str) -> str:
    """'ok', 'WrongStatus' (the status does not admit the function) or 'Unauthorized' (the role does not)."""
    allowed = _MATRIX.get((job_status, function))
    if allowed is None:
        return "WrongStatus"
    if "anyone" in allowed or role in allowed:
        return "ok"
    return "Unauthorized"


def kernel_time_rule(function: str, job_status: int, ts: int, expired_at: int) -> str:
    """The time condition of the kernel (measured): 'ok' or the reason.

    submit: ts < expiredAt. claimRefund: ts >= expiredAt and status Funded or Submitted. complete and reject
    have no time condition: after expiredAt the evaluator's settle races anyone's claimRefund, first wins.
    """
    if function == "submit":
        return "ok" if ts < expired_at else "expired"
    if function == "claimRefund":
        if job_status not in (JOB_FUNDED, JOB_SUBMITTED):
            return "WrongStatus"
        return "ok" if ts >= expired_at else "WrongStatus"  # the kernel's revert name before expiry
    return "ok"


def create_expiry_ok(expired_at: int, now: int) -> str:
    """createJob's bounds on expiredAt (measured): now + 300 < expiredAt <= now + MAX_EXPIRY_DURATION."""
    if expired_at <= now + KERNEL_MIN_EXPIRY_LEAD:
        return "ExpiryTooShort"
    if expired_at > now + KERNEL_MAX_EXPIRY_DURATION:
        return "ExpiryTooLong"
    return "ok"


def settlement_guaranteed(ts: int, expired_at: int) -> bool:
    """Whether a settle at `ts` cannot be pre-empted by claimRefund: only strictly before expiredAt."""
    return ts < expired_at
