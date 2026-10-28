// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./utils/Base.sol";
import {MockGame} from "./utils/MockGame.sol";
import {StandInKernel} from "./utils/StandInKernel.sol";
import {TapCircuitEvaluator} from "../src/TapCircuitEvaluator.sol";
import {IAgenticCommerce, ITapCircuitJob, IACPHook, IERC165} from "../src/Interfaces.sol";

/// Replays ../vectors.json (written by make_vectors.py, checked by test_circuit_jobs.py) against the Solidity
/// evaluator: every case of the sections spec, deliverable.reason, decision, bind, fund, submit, settle and
/// expiry.constants, and the identifiers, error selectors and event topics of `interfaces`.
///
/// No fork: the vectors use placeholder addresses (evaluator 0x…e1, game 0x…d1), so the evaluator and the
/// MockGame are etched there and the kernel proxy address carries StandInKernel, a STAND-IN that only serves
/// the job fields the vectors set. The deployed kernel is exercised in KernelFork.t.sol.
contract VectorReplayTest is Base {
    address constant KERNEL = 0xEa4DAa3100A767e86FDed867729ae7446476EBA6;
    address constant EV = address(0xe1);
    address constant GAME = address(0xd1);
    bytes4 constant FUND = 0xd2e13f50;
    bytes4 constant SUBMIT = 0x9e63798d;
    bytes4 constant COMPLETE = 0xd75bbdf3;

    string json;
    StandInKernel k = StandInKernel(KERNEL);
    TapCircuitEvaluator ev = TapCircuitEvaluator(EV);
    MockGame g = MockGame(GAME);

    function setUp() public {
        json = vm.readFile("../vectors.json");
        assertEq(vm.parseJsonString(json, ".format"), "tap-circuit-jobs-vectors/1", "format");
        vm.etch(KERNEL, address(new StandInKernel()).code);
        _configure(uint64(vm.parseJsonUint(json, ".constants.maxSettlementSeconds")), address(0), 21_600, 21_600);
    }

    // ------------------------------------------------------------------ setup helpers

    /// Etch a MockGame with these constants at 0x…d1 and an evaluator built for it at 0x…e1. Storage at both
    /// addresses is kept, so every case uses its own job id.
    function _configure(uint64 maxSettle, address inputProvider, uint64 margin, uint64 minWindow) internal {
        vm.etch(GAME, address(new MockGame(maxSettle, inputProvider, 0)).code);
        g.setAcceptMode(MockGame.AcceptMode.Missing); // vectors decide from the status as given
        g.setEightValues(false);
        vm.etch(EV, address(new TapCircuitEvaluator(KERNEL, GAME, margin, minWindow)).code);
    }

    function _job(uint256 id, string memory p) internal {
        IAgenticCommerce.Job memory j;
        j.id = id;
        j.client = vm.parseJsonAddress(json, string.concat(p, ".client"));
        j.provider = vm.parseJsonAddress(json, string.concat(p, ".provider"));
        j.evaluator = vm.parseJsonAddress(json, string.concat(p, ".evaluator"));
        j.hook = vm.parseJsonAddress(json, string.concat(p, ".hook"));
        j.status = uint8(vm.parseJsonUint(json, string.concat(p, ".status")));
        j.budget = vm.parseJsonUint(json, string.concat(p, ".budget"));
        j.expiredAt = vm.parseJsonUint(json, string.concat(p, ".expiredAt"));
        j.deliverable = vm.parseJsonBytes32(json, string.concat(p, ".deliverable"));
        k.setJob(id, j);
    }

    function _spec(string memory p) internal view returns (ITapCircuitJob.JobSpec memory s) {
        s.game = vm.parseJsonAddress(json, string.concat(p, ".game"));
        s.netlistHash2 = vm.parseJsonBytes32(json, string.concat(p, ".netlistHash2"));
        s.inputRoot = vm.parseJsonBytes32(json, string.concat(p, ".inputRoot"));
        s.T = uint64(vm.parseJsonUint(json, string.concat(p, ".T")));
        s.K = uint64(vm.parseJsonUint(json, string.concat(p, ".K")));
        s.budget = vm.parseJsonUint(json, string.concat(p, ".budget"));
        s.expiredAt = uint64(vm.parseJsonUint(json, string.concat(p, ".expiredAt")));
        s.inputProvider = vm.parseJsonAddress(json, string.concat(p, ".inputProvider"));
    }

    function _claim(uint256 claimId, string memory p) internal {
        MockGame.Claim memory c;
        c.claimant = vm.parseJsonAddress(json, string.concat(p, ".claimant"));
        c.netlistHash2 = vm.parseJsonBytes32(json, string.concat(p, ".netlistHash2"));
        c.T = uint64(vm.parseJsonUint(json, string.concat(p, ".T")));
        c.K = uint64(vm.parseJsonUint(json, string.concat(p, ".K")));
        c.inputRoot = vm.parseJsonBytes32(json, string.concat(p, ".inputRoot"));
        c.checkpointRoot = vm.parseJsonBytes32(json, string.concat(p, ".checkpointRoot"));
        c.leaves = uint32(vm.parseJsonUint(json, string.concat(p, ".leaves")));
        c.status = uint8(vm.parseJsonUint(json, string.concat(p, ".status")));
        c.windowEnd = uint64(vm.parseJsonUint(json, string.concat(p, ".windowEnd")));
        g.setClaim(claimId, c);
    }

    function _count(string memory section) internal view returns (uint256 n) {
        while (vm.keyExistsJson(json, string.concat(section, "[", vm.toString(n), "].name"))) n++;
    }

    function _at(string memory section, uint256 i) internal pure returns (string memory) {
        return string.concat(section, "[", vm.toString(i), "]");
    }

    function _errorSelector(string memory name) internal pure returns (bytes4) {
        bool arg = keccak256(bytes(name)) == keccak256("ExpiryTooSoon") || keccak256(bytes(name)) == keccak256("WindowTooShort");
        return bytes4(keccak256(bytes(string.concat(name, arg ? "(uint256)" : "()"))));
    }

    /// Compare an outcome with the vector's `result`: "ok" or an error name (with `required` for the two
    /// errors that carry it).
    function _expect(string memory p, bool ok, bytes memory r, uint256 required) internal view {
        string memory want = vm.parseJsonString(json, string.concat(p, ".result"));
        string memory name = vm.parseJsonString(json, string.concat(p, ".name"));
        if (keccak256(bytes(want)) == keccak256("ok")) {
            if (!ok) revert(string.concat(name, ": expected ok, reverted"));
            return;
        }
        if (ok) revert(string.concat(name, ": expected ", want, ", passed"));
        if (sel4(r) != _errorSelector(want)) revert(string.concat(name, ": expected ", want));
        if (required != 0) assertEq(word(r, 0), required, string.concat(name, ": required"));
    }

    /// Bind job `id` to spec[0] (the worked example) with the job valid and Open at constants.now.
    function _preBind(uint256 id) internal returns (ITapCircuitJob.JobSpec memory s) {
        s = _spec(".spec[0].spec");
        _job(id, ".fund[0].job"); // a valid job of the worked example
        IAgenticCommerce.Job memory j = k.getJob(id);
        j.status = 0;
        k.setJob(id, j);
        vm.warp(vm.parseJsonUint(json, ".constants.now"));
        vm.prank(j.client);
        ev.bindJob(id, s);
    }

    /// Bind claim 7 of submit[0] (valid) to job `id` through afterAction(submit).
    function _preClaim(uint256 id) internal {
        _job(id, ".submit[0].job");
        _claim(7, ".submit[0].claim");
        vm.warp(vm.parseJsonUint(json, ".submit[0].now"));
        vm.prank(KERNEL);
        ev.afterAction(id, SUBMIT, "");
    }

    // ------------------------------------------------------------------ identifiers

    function test_interfaces_ids_errors_events() public view {
        assertTrue(type(ITapCircuitJob).interfaceId == bytes4(vm.parseJsonBytes(json, ".interfaces.interfaces.ITapCircuitJob.id")), "ITapCircuitJob id");
        assertTrue(type(IACPHook).interfaceId == 0x7ff6bc9e, "IACPHook id");
        assertTrue(ev.supportsInterface(0x01ffc9a7) && ev.supportsInterface(0x7ff6bc9e) && ev.supportsInterface(0x0b2be2a6), "reports");
        assertTrue(!ev.supportsInterface(0x58d08546) && !ev.supportsInterface(0xffffffff), "must not report");
        bytes4[20] memory sels = [
            ITapCircuitJob.NotKernel.selector, ITapCircuitJob.NotClient.selector, ITapCircuitJob.NotOpen.selector,
            ITapCircuitJob.NotEvaluator.selector, ITapCircuitJob.AlreadyBound.selector, ITapCircuitJob.NotBound.selector,
            ITapCircuitJob.BadGame.selector, ITapCircuitJob.BadInputProvider.selector, ITapCircuitJob.BadSpec.selector,
            ITapCircuitJob.ExpiryMismatch.selector, ITapCircuitJob.ExpiryTooSoon.selector,
            ITapCircuitJob.BudgetMismatch.selector, ITapCircuitJob.NotSubmitted.selector,
            ITapCircuitJob.BadDeliverable.selector, ITapCircuitJob.ClaimMismatch.selector,
            ITapCircuitJob.ClaimNotOpen.selector, ITapCircuitJob.WindowTooShort.selector, ITapCircuitJob.NoClaim.selector,
            ITapCircuitJob.NotDecided.selector, ITapCircuitJob.AlreadySettled.selector
        ];
        string[20] memory names = [
            "NotKernel()", "NotClient()", "NotOpen()", "NotEvaluator()", "AlreadyBound()", "NotBound()", "BadGame()",
            "BadInputProvider()", "BadSpec()", "ExpiryMismatch()", "ExpiryTooSoon(uint256)", "BudgetMismatch()",
            "NotSubmitted()", "BadDeliverable()", "ClaimMismatch()", "ClaimNotOpen()", "WindowTooShort(uint256)",
            "NoClaim()", "NotDecided()", "AlreadySettled()"
        ];
        for (uint256 i; i < 20; i++) {
            bytes memory v = vm.parseJsonBytes(json, string.concat(".interfaces.errors['", names[i], "']"));
            assertTrue(sels[i] == bytes4(v), names[i]);
        }
        assertEq(ITapCircuitJob.JobBound.selector, vm.parseJsonBytes32(json, ".interfaces.events['JobBound(uint256,bytes32,address)']"), "JobBound");
        assertEq(ITapCircuitJob.ClaimBound.selector, vm.parseJsonBytes32(json, ".interfaces.events['ClaimBound(uint256,uint256)']"), "ClaimBound");
        assertEq(ITapCircuitJob.JobSettled.selector, vm.parseJsonBytes32(json, ".interfaces.events['JobSettled(uint256,uint8,bytes32)']"), "JobSettled");
    }

    // ------------------------------------------------------------------ spec, reason, decision

    function test_spec_encoding_and_hash() public view {
        uint256 n = _count(".spec");
        assertEq(n, 4, "spec cases");
        for (uint256 i; i < n; i++) {
            string memory p = _at(".spec", i);
            ITapCircuitJob.JobSpec memory s = _spec(string.concat(p, ".spec"));
            bytes memory enc = abi.encode(s);
            assertEq(enc.length, 256, "256 bytes");
            assertEq(keccak256(enc), vm.parseJsonBytes32(json, string.concat(p, ".specHash")), vm.parseJsonString(json, string.concat(p, ".name")));
        }
    }

    function test_reason_values() public view {
        for (uint256 i; vm.keyExistsJson(json, string.concat(".deliverable.reason[", vm.toString(i), "].reason")); i++) {
            string memory p = string.concat(".deliverable.reason[", vm.toString(i), "]");
            bytes32 want = vm.parseJsonBytes32(json, string.concat(p, ".reason"));
            bytes32 got = keccak256(abi.encode(vm.parseJsonAddress(json, string.concat(p, ".game")),
                vm.parseJsonUint(json, string.concat(p, ".claimId")), uint8(vm.parseJsonUint(json, string.concat(p, ".status")))));
            assertEq(got, want, "reason");
        }
    }

    function test_decision_by_claim_status() public {
        uint256 id = 9000;
        _preBind(id);
        _preClaim(id);
        for (uint256 i; vm.keyExistsJson(json, string.concat(".decision[", vm.toString(i), "].claimStatus")); i++) {
            string memory p = string.concat(".decision[", vm.toString(i), "]");
            uint8 st = uint8(vm.parseJsonUint(json, string.concat(p, ".claimStatus")));
            g.setStatus(7, st);
            try ev.check(id) returns (uint8 d, bytes32 reason) {
                assertEq(d, vm.parseJsonUint(json, string.concat(p, ".check")), "check");
                assertEq(reason, keccak256(abi.encode(GAME, uint256(7), st)), "reason");
            } catch (bytes memory r) {
                assertTrue(sel4(r) == _errorSelector(vm.parseJsonString(json, string.concat(p, ".revert"))), "decision revert");
            }
        }
    }

    // ------------------------------------------------------------------ bind, fund, submit, settle

    function test_bind_vectors() public {
        uint256 n = _count(".bind");
        assertEq(n, 21, "bind cases");
        for (uint256 i; i < n; i++) {
            string memory p = _at(".bind", i);
            uint256 id = 1000 + i;
            _configure(uint64(vm.parseJsonUint(json, string.concat(p, ".evaluator.maxSettlementSeconds"))),
                vm.parseJsonAddress(json, string.concat(p, ".evaluator.inputProvider")),
                uint64(vm.parseJsonUint(json, string.concat(p, ".evaluator.margin"))), 21_600);
            _job(id, string.concat(p, ".job"));
            ITapCircuitJob.JobSpec memory s = _spec(string.concat(p, ".spec"));
            vm.warp(vm.parseJsonUint(json, string.concat(p, ".now")));
            if (vm.parseJsonBool(json, string.concat(p, ".alreadyBound"))) {
                vm.prank(k.getJob(id).client);
                ev.bindJob(id, s);
            }
            vm.prank(vm.parseJsonAddress(json, string.concat(p, ".sender")));
            (bool ok, bytes memory r) = EV.call(abi.encodeCall(ITapCircuitJob.bindJob, (id, s)));
            _expect(p, ok, r, vm.parseJsonUint(json, string.concat(p, ".requiredExpiry")) * _isErr(p, "ExpiryTooSoon"));
            if (ok) assertEq(ev.specHashOf(id), keccak256(abi.encode(s)), "specHash stored");
        }
    }

    function test_fund_vectors() public {
        uint256 n = _count(".fund");
        assertEq(n, 5, "fund cases");
        for (uint256 i; i < n; i++) {
            string memory p = _at(".fund", i);
            uint256 id = 2000 + i;
            if (vm.parseJsonBool(json, string.concat(p, ".bound"))) _preBind(id);
            _job(id, string.concat(p, ".job"));
            vm.prank(vm.parseJsonAddress(json, string.concat(p, ".sender")));
            (bool ok, bytes memory r) = EV.call(abi.encodeCall(IACPHook.beforeAction, (id, FUND, "")));
            _expect(p, ok, r, 0);
        }
    }

    function test_submit_vectors() public {
        uint256 n = _count(".submit");
        assertEq(n, 19, "submit cases");
        for (uint256 i; i < n; i++) {
            string memory p = _at(".submit", i);
            uint256 id = 3000 + i;
            if (vm.parseJsonBool(json, string.concat(p, ".bound"))) _preBind(id);
            if (vm.parseJsonBool(json, string.concat(p, ".claimAlreadyBound"))) _preClaim(id);
            _job(id, string.concat(p, ".job"));
            uint256 claimId = vm.parseJsonUint(json, string.concat(p, ".claimId"));
            bool short = !vm.keyExistsJson(json, string.concat(p, ".claim.status"));
            if (!short) _claim(claimId, string.concat(p, ".claim"));
            g.setEightValues(short);
            vm.warp(vm.parseJsonUint(json, string.concat(p, ".now")));
            vm.prank(vm.parseJsonAddress(json, string.concat(p, ".sender")));
            (bool ok, bytes memory r) = EV.call(abi.encodeCall(IACPHook.afterAction, (id, SUBMIT, "")));
            g.setEightValues(false);
            uint256 req = vm.parseJsonUint(json, string.concat(p, ".requiredExpiry")) * _isErr(p, "ExpiryTooSoon")
                + vm.parseJsonUint(json, string.concat(p, ".requiredWindowEnd")) * _isErr(p, "WindowTooShort");
            _expect(p, ok, r, req);
            if (ok) {
                (uint256 cid, bool bound) = ev.claimIdOf(id);
                assertTrue(bound && cid == claimId, "claim recorded");
            }
        }
    }

    function test_settle_vectors() public {
        uint256 n = _count(".settle");
        assertEq(n, 8, "settle cases");
        for (uint256 i; i < n; i++) {
            string memory p = _at(".settle", i);
            uint256 id = 4000 + i;
            _preBind(id);
            bool hasClaim = vm.keyExistsJson(json, string.concat(p, ".claim.status"));
            if (hasClaim) _preClaim(id);
            if (vm.parseJsonBool(json, string.concat(p, ".settled"))) {
                vm.prank(KERNEL);
                ev.afterAction(id, COMPLETE, abi.encode(bytes32(0), bytes("")));
            }
            _job(id, string.concat(p, ".job"));
            if (hasClaim) _claim(7, string.concat(p, ".claim"));
            (bool ok, bytes memory r) = EV.call(abi.encodeCall(ITapCircuitJob.settle, (id)));
            _expect(p, ok, r, 0);
            if (ok) {
                string memory call = vm.parseJsonString(json, string.concat(p, ".kernelCall"));
                assertTrue(k.lastCall() == (keccak256(bytes(call)) == keccak256("complete") ? bytes4(0xd75bbdf3) : bytes4(0x41dd26f5)), "kernel call");
                assertEq(k.lastReason(), vm.parseJsonBytes32(json, string.concat(p, ".reason")), "reason");
                assertEq(k.getJob(id).status, keccak256(bytes(call)) == keccak256("complete") ? 3 : 4, "terminal status");
            }
        }
    }

    function _isErr(string memory p, string memory name) internal view returns (uint256) {
        return keccak256(bytes(vm.parseJsonString(json, string.concat(p, ".result")))) == keccak256(bytes(name)) ? 1 : 0;
    }

    // ------------------------------------------------------------------ constructor conditions (2.3 items 4, 5)

    function test_constructor_conditions() public {
        for (uint256 i; vm.keyExistsJson(json, string.concat(".expiry.constants[", vm.toString(i), "].name")); i++) {
            string memory p = string.concat(".expiry.constants[", vm.toString(i), "]");
            MockGame gm = new MockGame(uint64(vm.parseJsonUint(json, string.concat(p, ".maxSettlementSeconds"))), address(0), 0);
            string memory want = vm.parseJsonString(json, string.concat(p, ".result"));
            try new TapCircuitEvaluator(KERNEL, address(gm), uint64(vm.parseJsonUint(json, string.concat(p, ".margin"))),
                uint64(vm.parseJsonUint(json, string.concat(p, ".minRemainingWindow")))) {
                assertEq(want, "ok", vm.parseJsonString(json, string.concat(p, ".name")));
            } catch (bytes memory r) {
                uint8 item = keccak256(bytes(want)) == keccak256("infeasible-expiry") ? 5 : 4;
                assertEq(keccak256(r), keccak256(abi.encodeWithSelector(TapCircuitEvaluator.BadConstruction.selector, item)),
                    vm.parseJsonString(json, string.concat(p, ".name")));
            }
        }
        // items 1 to 3
        vm.expectRevert(abi.encodeWithSelector(TapCircuitEvaluator.BadConstruction.selector, uint8(1)));
        new TapCircuitEvaluator(address(0x1234), GAME, 21_600, 21_600);
        vm.expectRevert(abi.encodeWithSelector(TapCircuitEvaluator.BadConstruction.selector, uint8(3)));
        new TapCircuitEvaluator(KERNEL, KERNEL, 21_600, 21_600); // not a game
    }
}
