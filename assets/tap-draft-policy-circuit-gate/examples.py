"""Example policy circuits for the TAP draft "Policy Circuit Gate", built programmatically.

MIT licence. Standard library only. Each example is a function returning (tapnet/1 file bytes, oracle), where the
oracle is a plain Python model of the same policy used by the tests for differential checks:
    oracle(fields: dict, state: dict | None) -> (verdict: "allow" | "deny", reason: int, new_state: dict | None)
`fields` are the request-word fields of policy_gate.fields_of (amount, overflow, asset, counterparty, kind, day,
hour, weekday). The builder writes NAND and LATCH records only (tapnet/1), nIn 128, nOut 8, with the eight output
gates last in the order allow, reason bit 0 .. reason bit 6.
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # sibling modules, also under python3 -I

import policy_gate as pg
import tapnft

IN = lambda i: 2 + i  # noqa: E731  signal index of request-word bit i


class Builder:
    """Signals: 0 = constant 0, 1 = constant 1, 2..129 = inputs, then one signal per element in order.
    Latches are declared first (reserve_latch) so that logic can read them; their `d` is set at the end."""

    def __init__(self):
        self.els = []            # ("N", a, b) or ("L", d or None)
        self.n_latch = 0

    def _sig(self) -> int:
        return 2 + pg.N_IN + len(self.els)

    def reserve_latch(self) -> int:
        assert all(e[0] == "L" for e in self.els), "latches are declared first"
        self.els.append(["L", None])
        self.n_latch += 1
        return self._sig() - 1

    def set_d(self, latch_sig: int, d: int) -> None:
        self.els[latch_sig - 2 - pg.N_IN][1] = d

    def nand(self, a: int, b: int) -> int:
        self.els.append(("N", a, b))
        return self._sig() - 1

    def not_(self, a: int) -> int:
        return self.nand(a, a)

    def and_(self, a: int, b: int) -> int:
        return self.not_(self.nand(a, b))

    def or_(self, a: int, b: int) -> int:
        return self.nand(self.not_(a), self.not_(b))

    def xor(self, a: int, b: int) -> int:
        g = self.nand(a, b)
        return self.nand(self.nand(a, g), self.nand(b, g))

    def mux(self, sel: int, a: int, b: int) -> int:
        """sel ? a : b"""
        return self.nand(self.nand(sel, a), self.nand(self.not_(sel), b))

    def and_many(self, xs: list) -> int:
        r = 1
        for x in xs:
            r = x if r == 1 else self.and_(r, x)
        return r

    def or_many(self, xs: list) -> int:
        r = 0
        for x in xs:
            r = x if r == 0 else self.or_(r, x)
        return r

    def eq_const(self, bits: list, k: int) -> int:
        return self.and_many([b if (k >> i) & 1 else self.not_(b) for i, b in enumerate(bits)])

    def gt_const(self, bits: list, k: int) -> int:
        """bits (LSB first) > k, as an unsigned integer."""
        gt = 0
        for i, b in enumerate(bits):
            gt = self.and_(b, gt) if (k >> i) & 1 else self.or_(b, gt)
        return gt

    def lt_const(self, bits: list, k: int) -> int:
        return self.not_(self.gt_const(bits, k - 1)) if k > 0 else 0

    def eq(self, xs: list, ys: list) -> int:
        return self.and_many([self.not_(self.xor(x, y)) for x, y in zip(xs, ys)])

    def add(self, xs: list, ys: list) -> tuple:
        """Ripple-carry sum of two equal-width vectors (LSB first). Returns (sum bits, carry out)."""
        c, out = 0, []
        for x, y in zip(xs, ys):
            t = self.xor(x, y)
            out.append(self.xor(t, c))
            c = self.or_(self.and_(x, y), self.and_(t, c))
        return out, c

    def priority(self, flags: list) -> tuple:
        """flags: [(signal, reason code)] in priority order. Returns (allow, [7 reason bits])."""
        seen, firsts = 0, []
        for f, code in flags:
            firsts.append((self.and_(f, self.not_(seen)) if seen != 0 else f, code))
            seen = self.or_(seen, f) if seen != 0 else f
        allow = self.not_(seen) if seen != 0 else 1
        bits = [self.or_many([f for f, code in firsts if (code >> j) & 1]) for j in range(7)]
        return allow, bits

    def finish(self, allow: int, reason_bits: list) -> bytes:
        assert len(reason_bits) == 7
        outs = [allow] + list(reason_bits)
        nots = [self.not_(x) for x in outs]
        for nx in nots:
            self.nand(nx, nx)                 # the eight output gates, last
        recs = bytearray()
        for e in self.els:
            if e[0] == "L":
                assert e[1] is not None, "latch without d"
                recs += b"\x01" + e[1].to_bytes(3, "big")
            else:
                recs += b"\x00" + e[1].to_bytes(3, "big") + e[2].to_bytes(3, "big")
        data = tapnft.encode_file(bytes(recs), pg.N_IN, pg.N_OUT)
        pg.check_policy_file(data)
        return data


def _bits(lo: int, n: int) -> list:
    return [IN(lo + i) for i in range(n)]


AMOUNT = _bits(pg.AMOUNT_LO, pg.AMOUNT_BITS)
OVERFLOW = IN(pg.OVERFLOW_BIT)
ASSET = _bits(pg.ASSET_LO, pg.ASSET_BITS)
COUNTERPARTY = _bits(pg.COUNTERPARTY_LO, pg.COUNTERPARTY_BITS)
KIND = _bits(pg.KIND_LO, pg.KIND_BITS)
DAY = _bits(pg.DAY_LO, pg.DAY_BITS)
HOUR = _bits(pg.HOUR_LO, pg.HOUR_BITS)
WEEKDAY = _bits(pg.WEEKDAY_LO, pg.WEEKDAY_BITS)


# ---------------------------------------------------------------- 1. daily cap (stateful)

def daily_cap(per_request: int, cap: int):
    """Allow `pay` requests of at most `per_request` units while the units allowed on the same UTC day stay at
    most `cap`. State: 16-bit accumulator, 16-bit day, 1 `seen` bit. per_request, cap < 2^16."""
    assert 0 < per_request < 1 << 16 and 0 < cap < 1 << 16
    b = Builder()
    acc = [b.reserve_latch() for _ in range(16)]
    day = [b.reserve_latch() for _ in range(16)]
    seen = b.reserve_latch()
    same_day = b.and_(b.eq(DAY, day), seen)
    base = [b.and_(a, same_day) for a in acc]
    s, carry = b.add(base, AMOUNT[:16])
    hi_nonzero = b.or_many(AMOUNT[16:])
    over_request = b.or_(hi_nonzero, b.gt_const(AMOUNT[:16], per_request))
    over_cap = b.or_(carry, b.gt_const(s, cap))
    allow, reason = b.priority([(b.not_(b.eq_const(KIND, 1)), 7), (OVERFLOW, 6), (over_request, 1), (over_cap, 2)])
    for i in range(16):
        b.set_d(acc[i], b.mux(allow, s[i], acc[i]))
        b.set_d(day[i], b.mux(allow, DAY[i], day[i]))
    b.set_d(seen, b.or_(seen, allow))
    data = b.finish(allow, reason)

    def oracle(f: dict, st: dict | None):
        st = st or {"acc": 0, "day": 0, "seen": 0}
        same = st["seen"] and st["day"] == f["day"]
        base = st["acc"] if same else 0
        total = base + (f["amount"] & 0xFFFF)
        if f["kind"] != 1:
            r = 7
        elif f["overflow"]:
            r = 6
        elif f["amount"] > per_request:
            r = 1
        elif total > cap:
            r = 2
        else:
            return "allow", 0, {"acc": total, "day": f["day"], "seen": 1}
        return "deny", r, dict(st)

    return data, oracle


# ---------------------------------------------------------------- 2. counterparty allow-list (combinational)

def allowlist(classes: set, asset_class: int, per_request: int):
    """Allow `pay` requests to counterparties of a class in `classes`, in the asset of class `asset_class`, of at
    most `per_request` units (32-bit compare)."""
    b = Builder()
    cp_ok = b.or_many([b.eq_const(COUNTERPARTY, c) for c in sorted(classes)])
    allow, reason = b.priority([
        (b.not_(b.eq_const(KIND, 1)), 7), (OVERFLOW, 6), (b.not_(cp_ok), 3),
        (b.not_(b.eq_const(ASSET, asset_class)), 4), (b.gt_const(AMOUNT, per_request), 1)])
    data = b.finish(allow, reason)

    def oracle(f: dict, st=None):
        if f["kind"] != 1:
            return "deny", 7, None
        if f["overflow"]:
            return "deny", 6, None
        if f["counterparty"] not in classes:
            return "deny", 3, None
        if f["asset"] != asset_class:
            return "deny", 4, None
        if f["amount"] > per_request:
            return "deny", 1, None
        return "allow", 0, None

    return data, oracle


# ---------------------------------------------------------------- 3. time-of-day window (combinational)

def time_window(start_hour: int, end_hour: int, weekdays_only: bool = True):
    """Allow `pay` and `call` requests with start_hour <= hour < end_hour (UTC), on Monday..Friday when
    weekdays_only. Amount is not limited by this policy."""
    assert 0 <= start_hour < end_hour <= 24
    b = Builder()
    kind_ok = b.or_(b.eq_const(KIND, 1), b.eq_const(KIND, 3))
    outside = b.or_(b.lt_const(HOUR, start_hour), b.not_(b.lt_const(HOUR, end_hour)))
    if weekdays_only:
        outside = b.or_(outside, b.not_(b.lt_const(WEEKDAY, 5)))
    allow, reason = b.priority([(b.not_(kind_ok), 7), (outside, 5)])
    data = b.finish(allow, reason)

    def oracle(f: dict, st=None):
        if f["kind"] not in (1, 3):
            return "deny", 7, None
        if not (start_hour <= f["hour"] < end_hour) or (weekdays_only and f["weekday"] >= 5):
            return "deny", 5, None
        return "allow", 0, None

    return data, oracle


# ---------------------------------------------------------------- 4. deny everything (the smallest policy)

def deny_all():
    b = Builder()
    allow, reason = b.priority([(1, 7)])
    data = b.finish(allow, reason)
    return data, (lambda f, st=None: ("deny", 7, None))


# ---------------------------------------------------------------- 5. per-asset limits (combinational)

def per_asset_limits(limits: dict):
    """Allow `pay` requests of at most limits[assetClass] units; assets not in `limits` are denied (reason 4)."""
    b = Builder()
    known = b.or_many([b.eq_const(ASSET, c) for c in sorted(limits)])
    over = b.or_many([b.and_(b.eq_const(ASSET, c), b.gt_const(AMOUNT, lim)) for c, lim in sorted(limits.items())])
    allow, reason = b.priority([(b.not_(b.eq_const(KIND, 1)), 7), (OVERFLOW, 6), (b.not_(known), 4), (over, 1)])
    data = b.finish(allow, reason)

    def oracle(f: dict, st=None):
        if f["kind"] != 1:
            return "deny", 7, None
        if f["overflow"]:
            return "deny", 6, None
        if f["asset"] not in limits:
            return "deny", 4, None
        if f["amount"] > limits[f["asset"]]:
            return "deny", 1, None
        return "allow", 0, None

    return data, oracle


EXAMPLES = {
    "daily-cap": (lambda: daily_cap(per_request=500, cap=2000), {"perRequest": 500, "cap": 2000, "stateful": True}),
    "allowlist": (lambda: allowlist({1, 2}, 1, 1000), {"classes": [1, 2], "assetClass": 1, "perRequest": 1000, "stateful": False}),
    "time-window": (lambda: time_window(9, 17, True), {"startHour": 9, "endHour": 17, "weekdaysOnly": True, "stateful": False}),
    "deny-all": (deny_all, {"stateful": False}),
    "per-asset-limits": (lambda: per_asset_limits({1: 1000, 2: 50}), {"limits": {"1": 1000, "2": 50}, "stateful": False}),
}


def build_all() -> dict:
    return {name: (fn(), params) for name, (fn, params) in EXAMPLES.items()}


if __name__ == "__main__":
    import os
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "policies")
    os.makedirs(here, exist_ok=True)
    for name, ((data, _), params) in build_all().items():
        info = pg.check_policy_file(data)
        with open(os.path.join(here, name + ".tapnet"), "wb") as f:
            f.write(data)
        print(f"{name:18s} {info.size:6d} bytes  nand {info.metrics.nand:5d}  latch {info.metrics.latch:3d}  "
              f"sha256 {pg.policy_hash(data).hex()}")
