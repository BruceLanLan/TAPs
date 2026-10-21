// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BitcoinKeyedHolder as B} from "../../src/BitcoinKeyedHolder.sol";
import {DSign} from "../diff/DiffLib.sol";
import {BatchFuzzBase} from "./BatchFuzzBase.sol";

/// Differential: a batch of one call against execute of the same call, on the same holder, from the same
/// state, each with its own signature (the §5.3 text for the batch, the §5.2 text for execute; the same
/// mutation is applied to both, or to neither when it would leave one of them unchanged). The two must have the same effects. The rule, exactly:
///   - success on one side iff success on the other, with the same logs (the one Called event and the
///     callee's), nonce, holder, relayer and target balances and target states; execute returns the
///     callee's return data R, executeBatch returns nothing;
///   - on failure nothing changes on either side, and the revert data is either the same holder error
///     (Expired, BadSignature, NoCode, InsufficientGas, TipFailed) or, when the callee failed with R,
///     execute reverts with R and executeBatch with BatchCallFailed(0, the first 256 bytes of R);
///   - callGas >= 2^64: executeBatch reverts with BadBatch (after Expired), execute fails as well;
///   - with tight outer gas (20k to 620k, one run in three) a side that failed for gas (empty revert data,
///     InsufficientGas, TipFailed or BatchCallFailed(0, "")) is rerun with 15M gas before comparing; the two
///     sides use different amounts of gas, so where exactly each runs short is not compared.
/// Run with --fuzz-runs 200000 for the record.
contract BatchVsExecuteTest is BatchFuzzBase {
    uint256 constant GENEROUS = 15_000_000;

    function sides(Bx memory b) internal returns (bytes memory cdA, bytes memory cdB) {
        uint256 snap = vm.snapshotState();
        install(b.spk);
        B.Call memory c = b.calls[0];
        bytes memory mA =
            B(payable(X)).callMessage(c.target, c.value, c.data, c.callGas, b.tip, b.claimedNonce, b.deadline);
        bytes memory oA = signWith(b.tr, b.priv, mA);
        bytes memory oB = signBatch(b, b.claimedNonce);
        bytes memory sA = DSign.mutate(oA, b.mutKind, b.mutPos, b.mutVal);
        bytes memory sB = DSign.mutate(oB, b.mutKind, b.mutPos, b.mutVal);
        // The two signatures differ, so the same mutation can leave one of them unchanged (for example,
        // setting a byte to the value it already has). Then neither side is mutated.
        if ((keccak256(sA) == keccak256(oA)) != (keccak256(sB) == keccak256(oB))) (sA, sB) = (oA, oB);
        cdA = abi.encodeCall(B.execute, (c.target, c.value, c.data, c.callGas, b.tip, b.deadline, sA));
        cdB = batchCd(b, sB);
        vm.revertToState(snap);
    }

    function run(Bx memory b, bytes memory cd, uint256 outer) internal returns (Obs memory o) {
        uint256 snap = vm.snapshotState();
        install(b.spk);
        vm.deal(X, b.bal);
        o = observe(b.relayer, cd, outer);
        vm.revertToState(snap);
    }

    function gasLike(Obs memory o, bool batch) internal pure returns (bool) {
        if (o.ok) return false;
        if (o.ret.length == 0) return true;
        if (o.ret.length == 4 && (bytes4(o.ret) == INSUFFICIENT_GAS || bytes4(o.ret) == TIP_FAILED)) return true;
        return batch && keccak256(o.ret) == keccak256(abi.encodeWithSelector(B.BatchCallFailed.selector, 0, ""));
    }

    function compare(Obs memory a, Obs memory b, bool cappedGas, string memory label) internal pure {
        assertEq(a.logs, b.logs, string.concat(label, ": logs"));
        assertEq(a.nonce, b.nonce, string.concat(label, ": nonce"));
        assertEq(a.hBal, b.hBal, string.concat(label, ": holder balance"));
        assertEq(a.sBal, b.sBal, string.concat(label, ": sender balance"));
        assertEq(a.world, b.world, string.concat(label, ": targets"));
        if (cappedGas) {
            assertFalse(a.ok, string.concat(label, ": execute with callGas >= 2^64"));
            assertFalse(b.ok, string.concat(label, ": executeBatch with callGas >= 2^64"));
            assertTrue(
                bytes4(b.ret) == B.BadBatch.selector || bytes4(b.ret) == B.Expired.selector,
                string.concat(label, ": BadBatch")
            );
            return;
        }
        assertEq(a.ok, b.ok, string.concat(label, ": ok"));
        if (a.ok) {
            abi.decode(a.ret, (bytes)); // execute returns the callee's return data
            assertEq(b.ret.length, 0, string.concat(label, ": executeBatch returns nothing"));
            return;
        }
        bool sameError = a.ret.length == 4 && keccak256(a.ret) == keccak256(b.ret);
        bool wrapped =
            keccak256(b.ret) == keccak256(abi.encodeWithSelector(B.BatchCallFailed.selector, 0, first256(a.ret)));
        assertTrue(sameError || wrapped, string.concat(label, ": revert data"));
    }

    function testFuzz_batch_of_one_vs_execute(uint256 seed, bytes memory payload) public {
        Bx memory b = buildBatch(seed, payload, 1);
        bool tight = rnd(seed, 60) % 3 == 0;
        uint256 outer = tight ? 20_000 + rnd(seed, 61) % 600_000 : GENEROUS;
        (bytes memory cdA, bytes memory cdB) = sides(b);
        Obs memory a = run(b, cdA, outer);
        Obs memory bb = run(b, cdB, outer);
        if (tight) {
            if (gasLike(a, false)) a = run(b, cdA, GENEROUS);
            if (gasLike(bb, true)) bb = run(b, cdB, GENEROUS);
        }
        compare(a, bb, b.calls[0].callGas >= (1 << 64), tight ? "batch of one vs execute (tight)" : "batch of one vs execute");
    }
}
