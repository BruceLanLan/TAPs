// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {BitcoinKeyedHolder as B} from "../../src/BitcoinKeyedHolder.sol";
import {DSign} from "../diff/DiffLib.sol";
import {BatchFuzzBase} from "./BatchFuzzBase.sol";

/// Properties of executeBatch over random signed batches (1 to 8 calls of mixed kinds, random value, tip,
/// callGas, deadline, nonce, signature mutations and relayers), each signed with a real key:
///   - all or nothing: a failed batch changes nothing (nonce, holder, relayer and every target);
///   - a failure is one of the specified errors, and BatchCallFailed names a call of the batch;
///   - an intact signature at the current nonce, before the deadline, with every callGas below 2^64, never
///     fails with BadSignature; a mutated signature or another nonce never succeeds;
///   - a successful batch uses exactly one nonce, pays the tip exactly once to msg.sender, spends exactly
///     the values it names plus the tip, emits one Called per call in order with that nonce, returns no
///     data, and cannot be replayed;
///   - order matters: the same signature with two different calls swapped, with the last call dropped, or
///     with a call appended, is refused.
/// Run with --fuzz-runs 200000 for the record (docs/FINAL-GAS.md, docs/INTEGRATION-NOTES.md).
contract BatchInvariantsTest is BatchFuzzBase {
    uint256 constant OUTER = 15_000_000;

    function sel(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length >= 4) s = bytes4(ret);
    }

    function capped(Bx memory b) internal pure returns (bool) {
        for (uint256 i = 0; i < b.calls.length; i++) {
            if (b.calls[i].callGas >= (1 << 64)) return true;
        }
        return false;
    }

    function knownFailure(bytes memory ret, uint256 k) internal pure returns (bool) {
        bytes4 s = sel(ret);
        if (ret.length == 4) {
            return s == B.Expired.selector || s == B.BadBatch.selector || s == B.BadSignature.selector
                || s == B.NoCode.selector || s == B.InsufficientGas.selector || s == B.TipFailed.selector;
        }
        if (s != B.BatchCallFailed.selector || ret.length < 4 + 64) return false;
        (uint256 index, bytes memory data) = abi.decode(_tail(ret), (uint256, bytes));
        return index < k && data.length <= 256;
    }

    function _tail(bytes memory ret) internal pure returns (bytes memory t) {
        t = new bytes(ret.length - 4);
        for (uint256 i = 0; i < t.length; i++) {
            t[i] = ret[i + 4];
        }
    }

    /// Refused with the same signature: a reordered, shortened or lengthened batch.
    function assertRefused(Bx memory b, B.Call[] memory other, bytes memory s, string memory label) internal {
        uint256 snap = vm.snapshotState();
        B.Call[] memory orig = b.calls;
        b.calls = other;
        (bool ok, bytes memory ret) = relayRaw(b.relayer, batchCd(b, s), OUTER);
        b.calls = orig;
        vm.revertToState(snap);
        assertFalse(ok, label);
        bytes4 r = sel(ret);
        assertTrue(r == B.BadSignature.selector || r == B.Expired.selector || r == B.BadBatch.selector, label);
        if (b.deadline >= T && !capped(b) && other.length >= 1 && other.length <= 8) {
            assertEq(r, B.BadSignature.selector, label);
        }
    }

    function testFuzz_batch_invariants(uint256 seed, bytes memory payload) public {
        Bx memory b = buildBatch(seed, payload, 8);
        uint256 k = b.calls.length;
        install(b.spk);
        vm.deal(X, b.bal);
        bytes memory sig = signBatch(b, b.claimedNonce);
        bytes memory s = DSign.mutate(sig, b.mutKind, b.mutPos, b.mutVal);
        bool intact = keccak256(s) == keccak256(sig) && b.claimedNonce == 0;

        // order matters (checked from the initial state)
        if (k >= 2) {
            uint256 i = rnd(seed, 50) % k;
            uint256 j = (i + 1 + rnd(seed, 51) % (k - 1)) % k;
            if (keccak256(abi.encode(b.calls[i])) != keccak256(abi.encode(b.calls[j]))) {
                B.Call[] memory sw = new B.Call[](k);
                for (uint256 x = 0; x < k; x++) {
                    sw[x] = b.calls[x];
                }
                (sw[i], sw[j]) = (sw[j], sw[i]);
                assertRefused(b, sw, s, "swapped");
            }
            B.Call[] memory shorter = new B.Call[](k - 1);
            for (uint256 x = 0; x < k - 1; x++) {
                shorter[x] = b.calls[x];
            }
            assertRefused(b, shorter, s, "dropped");
        }
        if (k < 8) {
            B.Call[] memory longer = new B.Call[](k + 1);
            for (uint256 x = 0; x < k; x++) {
                longer[x] = b.calls[x];
            }
            longer[k] = b.calls[0];
            assertRefused(b, longer, s, "appended");
        }

        address from = sender(b.relayer);
        uint256 sBal0 = from.balance;
        bytes32 w0 = world();
        bytes memory cd = batchCd(b, s);
        vm.recordLogs();
        (bool ok, bytes memory ret) = relayRaw(b.relayer, cd, OUTER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        if (!ok) {
            assertEq(readNonce(), 0, "nonce unused");
            assertEq(X.balance, b.bal, "holder balance unchanged");
            assertEq(from.balance, sBal0, "no tip");
            assertEq(world(), w0, "targets unchanged");
            assertTrue(knownFailure(ret, k), "specified error");
            if (intact && b.deadline >= T && !capped(b)) {
                assertTrue(sel(ret) != B.BadSignature.selector, "intact signature refused");
            }
            return;
        }

        assertTrue(intact, "a mutated signature or another nonce succeeded");
        assertTrue(b.deadline >= T && !capped(b));
        assertEq(readNonce(), 1, "one nonce");
        uint256 spent = b.tip;
        uint256 toSender; // a contract relayer can also be a target of the batch
        for (uint256 i = 0; i < k; i++) {
            if (b.calls[i].target != X) spent += b.calls[i].value;
            if (b.calls[i].target == from) toSender += b.calls[i].value;
        }
        assertEq(from.balance - sBal0, b.tip + toSender, "tip once, to msg.sender");
        assertEq(b.bal - X.balance, spent, "spent exactly the values and the tip");
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != X) continue;
            assertEq(logs[i].topics[0], B.Called.selector);
            assertLt(n, k, "too many Called");
            assertEq(uint256(logs[i].topics[1]), 0, "same nonce");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), b.calls[n].target, "order");
            (uint256 v, bytes32 h) = abi.decode(logs[i].data, (uint256, bytes32));
            assertEq(v, b.calls[n].value);
            assertEq(h, keccak256(b.calls[n].data));
            n++;
        }
        assertEq(n, k, "one Called per call");
        assertEq(ret.length, 0, "executeBatch returns nothing");
        (bool again, bytes memory r2) = relayRaw(b.relayer, cd, OUTER);
        assertFalse(again, "replay");
        assertEq(sel(r2), B.BadSignature.selector, "replay");
    }
}
