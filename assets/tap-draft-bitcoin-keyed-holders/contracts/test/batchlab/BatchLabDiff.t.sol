// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BitcoinKeyedHolder as B} from "../../src/BitcoinKeyedHolder.sol";
import {DSign} from "../diff/DiffLib.sol";
import {BatchFuzzBase} from "../batch/BatchFuzzBase.sol";
import {BatchLabCode} from "./BatchLabCode.sol";

/// Differential: the merged contract's batch path against the batch lab's candidate (frozen creation code,
/// holder-batch-lab fc8864b), at the same address, from the same state, on the same signed input. This is
/// the evidence that the port kept the batch semantics of BATCH-SPEC (text, failure semantics, nonce, tip,
/// events, errors). Intended differences: where gas runs short (the merged contract copies all call data
/// before its gas checks; see test/batchlab/BatchGasFloor.t.sol); executeBatch returns nothing (the lab
/// returned every callee's return data, audit F-01); BatchCallFailed carries only the first 256 bytes of
/// the revert data (audit F-02). So:
///   - with generous gas (15M) everything must be the same: success, logs, nonce, balances and targets,
///     and the revert data once the lab's BatchCallFailed data is cut to 256 bytes; on success the merged
///     contract returns no data;
///   - with tight gas (one run in three) a side that failed for gas (empty revert data, InsufficientGas,
///     TipFailed, BatchCallFailed(i, "")) is rerun with 15M before comparing.
/// Batches have 0 to 9 calls (0 and 9 must give BadBatch on both sides).
/// Run with --fuzz-runs 200000 for the record.
contract BatchLabDiffTest is BatchFuzzBase {
    uint256 constant GENEROUS = 15_000_000;

    function installSide(bool lab, bytes memory spk) internal {
        installCode(lab ? BatchLabCode.creationCode() : type(B).creationCode, spk);
    }

    function run(bool lab, Bx memory b, bytes memory cd, uint256 outer) internal returns (Obs memory o) {
        uint256 snap = vm.snapshotState();
        installSide(lab, b.spk);
        vm.deal(X, b.bal);
        o = observe(b.relayer, cd, outer);
        vm.revertToState(snap);
    }

    function gasLike(Obs memory o) internal pure returns (bool) {
        if (o.ok) return false;
        if (o.ret.length == 0) return true;
        bytes4 s = bytes4(o.ret);
        if (o.ret.length == 4 && (s == INSUFFICIENT_GAS || s == TIP_FAILED)) return true;
        // BatchCallFailed(index, "") : selector, index, offset 0x40, length 0
        return s == B.BatchCallFailed.selector && o.ret.length == 4 + 96;
    }

    function testFuzz_lab_executeBatch(uint256 seed, bytes memory payload) public {
        Bx memory b = buildBatch(seed, payload, 8);
        uint256 kk = rnd(seed, 70) % 25;
        if (kk == 0) b.calls = new B.Call[](0);
        if (kk == 1) {
            B.Call[] memory nine = new B.Call[](9);
            for (uint256 i = 0; i < 9; i++) {
                nine[i] = randomCall(seed, i, b.bal, payload);
            }
            b.calls = nine;
        }
        bytes memory s;
        {
            uint256 snap = vm.snapshotState();
            installSide(false, b.spk);
            if (b.calls.length >= 1 && b.calls.length <= 8) {
                bytes memory m = B(payable(X)).batchMessage(b.calls, b.tip, b.claimedNonce, b.deadline);
                installSide(true, b.spk);
                assertEq(B(payable(X)).batchMessage(b.calls, b.tip, b.claimedNonce, b.deadline), m, "text");
                s = DSign.mutate(signWith(b.tr, b.priv, m), b.mutKind, b.mutPos, b.mutVal);
            } else {
                s = hex"01";
            }
            vm.revertToState(snap);
        }
        bytes memory cd = batchCd(b, s);
        bool tight = rnd(seed, 71) % 3 == 0;
        uint256 outer = tight ? 20_000 + rnd(seed, 72) % 900_000 : GENEROUS;
        Obs memory lab = run(true, b, cd, outer);
        Obs memory cur = run(false, b, cd, outer);
        if (tight) {
            if (gasLike(lab)) lab = run(true, b, cd, GENEROUS);
            if (gasLike(cur)) cur = run(false, b, cd, GENEROUS);
        }
        if (lab.ok) {
            assertEq(cur.ret.length, 0, "merged: no return data");
            lab.ret = cur.ret;
        } else if (lab.ret.length >= 4 && bytes4(lab.ret) == B.BatchCallFailed.selector) {
            (uint256 index, bytes memory data) = abi.decode(tail4(lab.ret), (uint256, bytes));
            lab.ret = abi.encodeWithSelector(B.BatchCallFailed.selector, index, first256(data));
        }
        assertSameObs(lab, cur, tight ? "batch lab vs merged (tight)" : "batch lab vs merged");
    }

    /// batchMessage byte for byte, over every field at random (values, gas, tip and nonce up to 2^256 - 1,
    /// any chain ID below 2^64, data of 0 to 99 bytes), 1 to 8 calls; and BadBatch for 0 or 9 calls.
    function testFuzz_lab_batchMessage(uint256 seed, uint64 chainId, uint256 tip, uint256 nonce_, uint64 deadline)
        public
    {
        vm.chainId(chainId == 0 ? 1 : chainId);
        uint256 k = rnd(seed, 0) % 10;
        B.Call[] memory cs = new B.Call[](k);
        for (uint256 i = 0; i < k; i++) {
            uint256 r = rnd(seed, 10 + i);
            bytes memory d = new bytes(r % 100);
            for (uint256 j = 0; j < d.length; j++) {
                d[j] = bytes1(uint8(rnd(r, j)));
            }
            uint256 small = rnd(seed, 30 + i);
            cs[i] = B.Call(
                address(uint160(rnd(seed, 40 + i))),
                small % 3 == 0 ? small % 1000 : rnd(seed, 50 + i),
                d,
                small % 5 == 0 ? small % 100 : rnd(seed, 60 + i)
            );
        }
        if (rnd(seed, 1) % 2 == 0) tip %= 1e18;
        if (rnd(seed, 2) % 2 == 0) nonce_ %= 1000;
        bytes memory spk = DSign.wpSpk(1 + seed % 1000);
        installSide(true, spk);
        (bool okL, bytes memory mL) = X.staticcall(abi.encodeCall(B.batchMessage, (cs, tip, nonce_, deadline)));
        installSide(false, spk);
        (bool okC, bytes memory mC) = X.staticcall(abi.encodeCall(B.batchMessage, (cs, tip, nonce_, deadline)));
        assertEq(okL, okC, "ok");
        assertEq(mL, mC, "text");
        assertEq(okC, k >= 1 && k <= 8);
    }
}
