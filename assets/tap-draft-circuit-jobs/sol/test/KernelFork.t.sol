// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base, Vm} from "./utils/Base.sol";
import {MockGame} from "./utils/MockGame.sol";
import {ProbeHook} from "./utils/ProbeHook.sol";
import {TapCircuitEvaluator} from "../src/TapCircuitEvaluator.sol";
import {IAgenticCommerce, ITapCircuitJob} from "../src/Interfaces.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// Tests against the deployed ERC-8183 kernel of BNB Smart Chain, on a local fork (FORK_URL, default
/// http://127.0.0.1:8545, an `anvil --fork-url <archive endpoint of chain 56>`). The game is MockGame, a
/// stand-in; the kernel, its proxy, its implementation and its payment token are the deployed ones.
contract KernelForkTest is Base {
    address constant KERNEL = 0xEa4DAa3100A767e86FDed867729ae7446476EBA6;
    address constant PINNED_IMPL = 0xe8d47866E2CC3dCAa50F0aD980355695b2F1D533;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 constant TOKEN_BALANCE_SLOT = 51; // balance mapping slot of the payment token (Annex B.1)

    // anvil's well-known test accounts 0-3 (no key is used: calls are pranked on the local fork)
    address constant CLIENT = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant PROVIDER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant STRANGER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant INPUTS = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;

    bytes4 constant HOOK_CALL_FAILED = 0xa9e35b2f;
    bytes4 constant WRONG_STATUS = 0x8e78f0cb;
    bytes4 constant KERNEL_BUDGET_MISMATCH = 0x99b0fc87;

    uint64 constant MAX_SETTLE = 1_368_992; // the vectors' arbitrary bound
    uint64 constant WINDOW = 108_000;
    uint64 constant MARGIN = 21_600;
    uint64 constant MIN_WINDOW = 21_600;
    uint256 constant BUDGET = 5e18;
    uint256 constant LEAD = 1_900_800; // 22 days, as in Annex A
    bytes32 constant NL = keccak256("netlistHash2");
    bytes32 constant IR = keccak256("inputRoot");

    IAgenticCommerce kernel = IAgenticCommerce(KERNEL);
    IERC20 token;
    MockGame game;
    TapCircuitEvaluator ev;
    string desc;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_URL", string("http://127.0.0.1:8545")));
        assertEq(block.chainid, 56, "not a fork of chain 56");
        assertEq(address(uint160(uint256(vm.load(KERNEL, IMPL_SLOT)))), PINNED_IMPL, "kernel implementation moved");
        token = IERC20(kernel.paymentToken());
        game = new MockGame(MAX_SETTLE, address(0), WINDOW);
        ev = new TapCircuitEvaluator(KERNEL, address(game), MARGIN, MIN_WINDOW);
        vm.store(address(token), keccak256(abi.encode(CLIENT, TOKEN_BALANCE_SLOT)), bytes32(uint256(1e24)));
        assertEq(token.balanceOf(CLIENT), 1e24, "token balance slot");
        // the Specification 3.4 description, about 260 bytes
        desc = string.concat(
            '{"tapCircuitJob":1,"evaluatorType":"tap_circuit","specHash":"0x',
            "5f7ecc2cc26519461dfbcd2aa5e39f029b15d0331ac19150cd387860cd33764d",
            '","game":{"chainId":56,"address":"0x00000000000000000000000000000000000000d1"},"netlistHash2":"0x',
            "1111111111111111111111111111111111111111111111111111111111111111",
            '","T":92,"K":8}'
        );
    }

    // ------------------------------------------------------------------ helpers

    function _create(address evaluator, address hook, uint256 lead, string memory d) internal returns (uint256 id) {
        vm.prank(CLIENT);
        id = kernel.createJob(PROVIDER, evaluator, block.timestamp + lead, d, hook);
    }

    function _create() internal returns (uint256) {
        return _create(address(ev), address(ev), LEAD, desc);
    }

    function _spec(uint256 id) internal view returns (ITapCircuitJob.JobSpec memory s) {
        s = ITapCircuitJob.JobSpec(address(game), NL, IR, 92, 8, BUDGET, uint64(kernel.getJob(id).expiredAt), address(0));
    }

    function _bind(uint256 id) internal {
        ITapCircuitJob.JobSpec memory s = _spec(id);
        vm.prank(CLIENT);
        ev.bindJob(id, s);
    }

    function _setBudgetFund(uint256 id) internal {
        vm.prank(CLIENT);
        kernel.setBudget(id, BUDGET, "");
        vm.prank(CLIENT);
        token.approve(KERNEL, BUDGET);
        vm.prank(CLIENT);
        kernel.fund(id, BUDGET, "");
    }

    function _claim(uint64 T) internal returns (uint256 cid) {
        vm.prank(PROVIDER);
        cid = game.claim(NL, T, 8, IR);
    }

    function _submit(uint256 id, uint256 cid) internal {
        vm.prank(PROVIDER);
        kernel.submit(id, bytes32(cid), "");
    }

    /// created, bound, funded, claimed and submitted; returns the claim id
    function _submitted(uint256 id) internal returns (uint256 cid) {
        _bind(id);
        _setBudgetFund(id);
        cid = _claim(92);
        vm.warp(block.timestamp + 300);
        _submit(id, cid);
    }

    function _status(uint256 id) internal view returns (uint256) {
        return kernel.getJob(id).status;
    }

    // ------------------------------------------------------------------ pinned kernel (J-10)

    function test_pinnedKernelConstants() public view {
        assertEq(kernel.HOOK_GAS_LIMIT(), 1_000_000, "HOOK_GAS_LIMIT");
        assertEq(kernel.MAX_EXPIRY_DURATION(), 31_536_000, "MAX_EXPIRY_DURATION");
        assertEq(ev.kernel(), KERNEL, "kernel()");
        assertEq(ev.game(), address(game), "game()");
        assertEq(ev.margin(), MARGIN, "margin()");
        assertEq(ev.minRemainingWindow(), MIN_WINDOW, "minRemainingWindow()");
    }

    // ------------------------------------------------------------------ M-1 and the full flows

    function test_M1_evaluatorIsHook_createJob() public {
        uint256 id = _create();
        IAgenticCommerce.Job memory j = kernel.getJob(id);
        assertEq(j.evaluator, address(ev), "evaluator");
        assertEq(j.hook, address(ev), "hook");
        assertEq(j.status, 0, "Open");
    }

    function test_flow_accepted_completes_and_pays_provider() public {
        uint256 id = _create();
        _bind(id);
        assertEq(ev.specHashOf(id), keccak256(abi.encode(_spec(id))), "specHash");
        _setBudgetFund(id);
        assertEq(_status(id), 1, "Funded");
        uint256 cid = _claim(92);
        vm.warp(block.timestamp + 300);
        _submit(id, cid);
        assertEq(_status(id), 2, "Submitted");
        (uint256 boundId, bool bound) = ev.claimIdOf(id);
        assertTrue(bound && boundId == cid, "claim bound");
        (uint8 d,) = ev.check(id);
        assertEq(d, 0, "pending while open");
        vm.expectRevert(ITapCircuitJob.NotDecided.selector);
        ev.settle(id);

        vm.warp(block.timestamp + WINDOW + 1); // past windowEnd; MockGame.accept moves it to accepted
        uint256 before = token.balanceOf(PROVIDER);
        uint256 fee = kernel.platformFeeBP();
        vm.prank(STRANGER);
        ev.settle(id);
        assertEq(_status(id), 3, "Completed");
        assertEq(token.balanceOf(PROVIDER) - before, BUDGET - BUDGET * fee / 10_000, "provider paid");
        (d,) = ev.check(id);
        assertEq(d, 1, "check after completion");
        vm.expectRevert(ITapCircuitJob.AlreadySettled.selector);
        ev.settle(id);
    }

    function test_flow_rejected_refunds_client() public {
        uint256 id = _create();
        uint256 cid = _submitted(id);
        uint256 before = token.balanceOf(CLIENT);
        game.setStatus(cid, 2); // stand-in for a challenger winning a dispute
        (uint8 d, bytes32 reason) = ev.check(id);
        assertEq(d, 2, "reject");
        assertEq(reason, keccak256(abi.encode(address(game), cid, uint8(2))), "reason");
        ev.settle(id);
        assertEq(_status(id), 4, "Rejected");
        assertEq(token.balanceOf(CLIENT) - before, BUDGET, "client refunded");
    }

    // ------------------------------------------------------------------ J-1 binding on the real kernel

    function test_J1_bind_errors_on_kernel_jobs() public {
        uint256 id = _create();
        ITapCircuitJob.JobSpec memory s = _spec(id);

        vm.prank(STRANGER);
        vm.expectRevert(ITapCircuitJob.NotClient.selector);
        ev.bindJob(id, s);

        s.game = STRANGER;
        vm.prank(CLIENT);
        vm.expectRevert(ITapCircuitJob.BadGame.selector);
        ev.bindJob(id, s);
        s.game = address(game);

        s.inputProvider = INPUTS;
        vm.prank(CLIENT);
        vm.expectRevert(ITapCircuitJob.BadInputProvider.selector);
        ev.bindJob(id, s);
        s.inputProvider = address(0);

        s.T = 0;
        vm.prank(CLIENT);
        vm.expectRevert(ITapCircuitJob.BadSpec.selector);
        ev.bindJob(id, s);
        s.T = 92;

        s.expiredAt += 1;
        vm.prank(CLIENT);
        vm.expectRevert(ITapCircuitJob.ExpiryMismatch.selector);
        ev.bindJob(id, s);
        s.expiredAt -= 1;

        vm.prank(CLIENT);
        ev.bindJob(id, s);
        vm.prank(CLIENT);
        vm.expectRevert(ITapCircuitJob.AlreadyBound.selector);
        ev.bindJob(id, s);

        // the evaluator mounted as hook only (another account as evaluator)
        uint256 id2 = _create(STRANGER, address(ev), LEAD, desc);
        ITapCircuitJob.JobSpec memory s2 = _spec(id2);
        vm.prank(CLIENT);
        vm.expectRevert(ITapCircuitJob.NotEvaluator.selector);
        ev.bindJob(id2, s2);

        // a job the client rejected while Open
        uint256 id3 = _create();
        vm.prank(CLIENT);
        kernel.reject(id3, bytes32(0), "");
        ITapCircuitJob.JobSpec memory s3 = _spec(id3);
        vm.prank(CLIENT);
        vm.expectRevert(ITapCircuitJob.NotOpen.selector);
        ev.bindJob(id3, s3);
    }

    function test_J1_case_b_input_provider_is_provider() public {
        MockGame gb = new MockGame(MAX_SETTLE, PROVIDER, WINDOW);
        TapCircuitEvaluator eb = new TapCircuitEvaluator(KERNEL, address(gb), MARGIN, MIN_WINDOW);
        uint256 id = _create(address(eb), address(eb), LEAD, desc);
        ITapCircuitJob.JobSpec memory s =
            ITapCircuitJob.JobSpec(address(gb), NL, IR, 92, 8, BUDGET, uint64(kernel.getJob(id).expiredAt), PROVIDER);
        vm.prank(CLIENT);
        vm.expectRevert(ITapCircuitJob.BadInputProvider.selector);
        eb.bindJob(id, s);
    }

    function test_J2_bind_at_exact_required_expiry_and_one_second_short() public {
        uint256 lead = MAX_SETTLE + MARGIN;
        uint256 id = _create(address(ev), address(ev), lead, desc);
        uint256 id2 = _create(address(ev), address(ev), lead - 1, desc);
        _bind(id); // exactly required: ok
        ITapCircuitJob.JobSpec memory s2 = _spec(id2);
        vm.prank(CLIENT);
        vm.expectRevert(abi.encodeWithSelector(ITapCircuitJob.ExpiryTooSoon.selector, block.timestamp + lead));
        ev.bindJob(id2, s2);
    }

    // ------------------------------------------------------------------ 3.3 fund

    function test_fund_unbound_job_is_refused_by_hook() public {
        uint256 id = _create();
        vm.prank(CLIENT);
        kernel.setBudget(id, BUDGET, "");
        vm.prank(CLIENT);
        token.approve(KERNEL, BUDGET);
        vm.prank(CLIENT);
        try kernel.fund(id, BUDGET, "") {
            fail("unbound fund passed");
        } catch (bytes memory r) {
            // the kernel re-raises the hook's revert data (it raises HookCallFailed only for an empty revert)
            assertRevertData(r, abi.encodeWithSelector(ITapCircuitJob.NotBound.selector), "hook NotBound bubbled");
        }
        assertEq(_status(id), 0, "still Open");
    }

    function test_M2_provider_changes_price_after_bind() public {
        uint256 id = _create();
        _bind(id);
        vm.prank(CLIENT);
        kernel.setBudget(id, BUDGET, "");
        vm.prank(PROVIDER);
        kernel.setBudget(id, 7e18, ""); // M-2: the provider may change the price until fund
        vm.prank(CLIENT);
        token.approve(KERNEL, 7e18);
        // a client that funds job.budget blindly: the kernel passes, the hook refuses. The evaluator's
        // BudgetMismatch() and the kernel's BudgetMismatch() have the same selector, so the revert data alone
        // does not say which contract refused (the trace does).
        vm.prank(CLIENT);
        try kernel.fund(id, 7e18, "") {
            fail("changed price funded");
        } catch (bytes memory r) {
            assertRevertData(r, abi.encodeWithSelector(ITapCircuitJob.BudgetMismatch.selector), "hook BudgetMismatch");
        }
        // a client that funds spec.budget: the kernel refuses before the hook
        vm.prank(CLIENT);
        try kernel.fund(id, BUDGET, "") {
            fail("stale expectedBudget funded");
        } catch (bytes memory r) {
            assertTrue(sel4(r) == KERNEL_BUDGET_MISMATCH, "expected kernel BudgetMismatch");
        }
        assertEq(_status(id), 0, "still Open");
    }

    // ------------------------------------------------------------------ 5 submit (J-3, J-5, J-2 at submit)

    function _expectSubmitRefused(uint256 id, uint256 cid, bytes memory want, string memory what) internal {
        vm.prank(PROVIDER);
        try kernel.submit(id, bytes32(cid), "") {
            fail(what);
        } catch (bytes memory r) {
            assertRevertData(r, want, what); // the evaluator's error, re-raised by the kernel
        }
        assertEq(_status(id), 1, "still Funded");
    }

    function test_J5_submit_refusals() public {
        uint256 id = _create();
        _bind(id);
        _setBudgetFund(id);
        _expectSubmitRefused(id, 999, abi.encodeWithSelector(ITapCircuitJob.BadDeliverable.selector), "no such claim");
        uint256 cT = _claim(93);
        _expectSubmitRefused(id, cT, abi.encodeWithSelector(ITapCircuitJob.ClaimMismatch.selector), "T differs");
        vm.prank(STRANGER);
        uint256 copied = game.claim(NL, 92, 8, IR);
        _expectSubmitRefused(id, copied, abi.encodeWithSelector(ITapCircuitJob.ClaimMismatch.selector), "claimant");
        uint256 cid = _claim(92);
        game.setStatus(cid, 3);
        _expectSubmitRefused(id, cid, abi.encodeWithSelector(ITapCircuitJob.ClaimNotOpen.selector), "accepted");
        game.setStatus(cid, 1);
        game.setEightValues(true);
        _expectSubmitRefused(id, cid, abi.encodeWithSelector(ITapCircuitJob.BadGame.selector), "eight-value view");
        game.setEightValues(false);
        _submit(id, cid);
        assertEq(_status(id), 2, "Submitted");
    }

    function test_J3_window_boundary_at_submit() public {
        uint256 id = _create();
        _bind(id);
        _setBudgetFund(id);
        uint256 cid = _claim(92);
        uint256 windowEnd = block.timestamp + WINDOW;
        vm.warp(windowEnd - MIN_WINDOW + 1);
        _expectSubmitRefused(id, cid,
            abi.encodeWithSelector(ITapCircuitJob.WindowTooShort.selector, windowEnd + 1), "window one second short");
        vm.warp(windowEnd - MIN_WINDOW);
        _submit(id, cid);
        assertEq(_status(id), 2, "Submitted at the exact boundary");
    }

    function test_J2_expiry_rechecked_at_submit() public {
        uint256 id = _create(address(ev), address(ev), MAX_SETTLE + MARGIN, desc); // exactly enough at binding
        _bind(id);
        _setBudgetFund(id);
        uint256 cid = _claim(92);
        uint256 t = block.timestamp + 1;
        vm.warp(t);
        _expectSubmitRefused(id, cid, abi.encodeWithSelector(ITapCircuitJob.ExpiryTooSoon.selector, t + MAX_SETTLE + MARGIN),
            "expiry one second short at submit");
    }

    // ------------------------------------------------------------------ 6 settle, the expiry race, accept()

    function test_M4_expiry_race_refund_wins_then_settle_refused() public {
        uint256 id = _create();
        uint256 cid = _submitted(id);
        uint256 exp = kernel.getJob(id).expiredAt;
        vm.warp(exp); // claimRefund is callable from the block whose timestamp equals expiredAt
        vm.prank(STRANGER);
        kernel.claimRefund(id);
        assertEq(_status(id), 5, "Expired");
        game.setStatus(cid, 3);
        vm.expectRevert(ITapCircuitJob.NotSubmitted.selector);
        ev.settle(id);
    }

    function test_M4_settle_after_expiry_is_best_effort() public {
        uint256 id = _create();
        _submitted(id);
        vm.warp(kernel.getJob(id).expiredAt + 1);
        ev.settle(id); // accept() moves the claim to accepted; nobody refunded first
        assertEq(_status(id), 3, "Completed after expiredAt");
    }

    function test_abandoned_claim_is_pending_until_refund() public {
        uint256 id = _create();
        uint256 cid = _submitted(id);
        game.setStatus(cid, 4);
        (uint8 d,) = ev.check(id);
        assertEq(d, 0, "abandoned is pending");
        vm.expectRevert(ITapCircuitJob.NotDecided.selector);
        ev.settle(id);
        vm.warp(kernel.getJob(id).expiredAt);
        kernel.claimRefund(id);
        assertEq(_status(id), 5, "Expired");
    }

    function test_settle_survives_accept_that_burns_gas_or_reverts() public {
        uint256 id = _create();
        uint256 cid = _submitted(id);
        game.setStatus(cid, 3);
        game.setAcceptMode(MockGame.AcceptMode.BurnGas);
        uint256 g = gasleft();
        ev.settle{gas: 1_000_000}(id);
        g -= gasleft();
        assertEq(_status(id), 3, "Completed despite gas-burning accept");
        assertTrue(g < 1_000_000, "settle within 1M gas");

        uint256 id2 = _create();
        uint256 cid2 = _submitted(id2);
        game.setStatus(cid2, 2);
        game.setAcceptMode(MockGame.AcceptMode.Revert);
        ev.settle(id2);
        assertEq(_status(id2), 4, "Rejected despite reverting accept");
    }

    // ------------------------------------------------------------------ J-8, J-10 hook entries

    function test_J10_entries_not_from_kernel_revert() public {
        vm.expectRevert(ITapCircuitJob.NotKernel.selector);
        ev.beforeAction(1, 0xd2e13f50, "");
        vm.expectRevert(ITapCircuitJob.NotKernel.selector);
        ev.afterAction(1, 0x9e63798d, "");
        vm.expectRevert(ITapCircuitJob.NotKernel.selector);
        ev.afterAction(1, 0x41528812, "");
    }

    function test_J8_client_reject_in_open_is_not_blocked() public {
        uint256 id = _create();
        _bind(id);
        vm.prank(CLIENT);
        kernel.reject(id, bytes32(0), "");
        assertEq(_status(id), 4, "client rejected while Open");
    }

    // ------------------------------------------------------------------ J-7 gas

    /// Gas of each live hook entry as the kernel calls it, read with the probe-free method: the evaluator is
    /// called directly by the kernel address with the job in the state the kernel shows at that entry. For the
    /// in-situ numbers see `forge test --gas-report` (README).
    function test_J7_gas_of_hook_entries() public {
        uint256 id = _create();
        _bind(id);
        vm.prank(CLIENT);
        kernel.setBudget(id, BUDGET, "");
        _coolAll();
        vm.prank(KERNEL);
        uint256 g = gasleft();
        ev.beforeAction(id, 0xd2e13f50, "");
        g -= gasleft();
        log("beforeAction(fund)", g);
        assertTrue(g < 300_000, "J-7 fund");

        vm.prank(CLIENT);
        token.approve(KERNEL, BUDGET);
        vm.prank(CLIENT);
        kernel.fund(id, BUDGET, "");
        uint256 cid = _claim(92);
        _coolAll();
        vm.prank(PROVIDER);
        g = gasleft();
        kernel.submit(id, bytes32(cid), "");
        g -= gasleft();
        log("kernel.submit incl. afterAction(submit)", g);

        vm.warp(block.timestamp + WINDOW + 1);
        _coolAll();
        g = gasleft();
        ev.settle(id);
        g -= gasleft();
        log("settle incl. accept, kernel.complete, afterAction(complete)", g);
    }

    /// The description is the client's, and `getJob` returns it: the kernel reads it from storage inside every
    /// hook entry that calls `getJob`. For a few lengths, whether the evaluator's beforeAction(fund) and
    /// afterAction(submit) still fit in HOOK_GAS_LIMIT, with the kernel's storage cold as in a fresh transaction
    /// (vm.cool). A hook that runs out of gas makes the kernel raise HookCallFailed (empty revert data).
    function test_J7_description_length_vs_hook_gas() public {
        uint256[3] memory sizes = [uint256(12_288), 13_312, 14_336];
        bool[3] memory fundOk = [true, true, false];
        bool[3] memory submitOk = [true, false, false];
        for (uint256 i; i < sizes.length; i++) {
            (bool f, bool sub) = _passes(sizes[i]);
            log(f ? "fund passes, description bytes" : "fund OUT OF GAS, description bytes", sizes[i]);
            if (f) log(sub ? "submit passes, description bytes" : "submit OUT OF GAS, description bytes", sizes[i]);
            assertTrue(f == fundOk[i] && sub == submitOk[i], "description length thresholds moved");
        }
    }

    function _passes(uint256 size) internal returns (bool fundOk, bool submitOk) {
        bytes memory b = new bytes(size);
        for (uint256 k; k < b.length; k++) b[k] = "a";
        uint256 id = _create(address(ev), address(ev), LEAD, string(b));
        _bind(id);
        vm.prank(CLIENT);
        kernel.setBudget(id, BUDGET, "");
        vm.prank(CLIENT);
        token.approve(KERNEL, BUDGET);
        _coolAll();
        vm.prank(CLIENT);
        try kernel.fund(id, BUDGET, "") {}
        catch (bytes memory r) {
            assertRevertData(r, abi.encodeWithSelector(HOOK_CALL_FAILED), "fund out of gas");
            return (false, false);
        }
        uint256 cid = _claim(92);
        _coolAll();
        vm.prank(PROVIDER);
        try kernel.submit(id, bytes32(cid), "") {
            return (true, true);
        } catch (bytes memory r) {
            assertRevertData(r, abi.encodeWithSelector(HOOK_CALL_FAILED), "submit out of gas");
            return (true, false);
        }
    }

    /// storage of the kernel, its token, the game and the evaluator cold again, as at the start of a transaction
    function _coolAll() internal {
        vm.cool(KERNEL);
        vm.cool(PINNED_IMPL);
        vm.cool(address(token));
        vm.cool(address(game));
        vm.cool(address(ev));
    }

    // ------------------------------------------------------------------ Pre-3 (table P) and M-3 ordering

    function _probeJob(ProbeHook p) internal returns (uint256 id) {
        id = _create(address(p), address(p), LEAD, "probe");
        vm.prank(CLIENT);
        kernel.setBudget(id, BUDGET, "");
        vm.prank(CLIENT);
        token.approve(KERNEL, BUDGET);
    }

    /// Pre-3 item 1: an afterAction that reverts for fund, submit, complete or reject.
    function test_Pre3_afterAction_revert_fails_the_action() public {
        _pre3(false, abi.encodeWithSignature("Error(string)", "probe: afterAction refused"));
        _pre3(true, abi.encodeWithSelector(HOOK_CALL_FAILED));
    }

    function _pre3(bool empty, bytes memory want) internal {
        ProbeHook p = new ProbeHook();
        p.setRevertEmpty(empty);
        bytes4[4] memory sels = [bytes4(0xd2e13f50), 0x9e63798d, 0xd75bbdf3, 0x41dd26f5];
        for (uint256 i; i < 4; i++) {
            uint256 id = _probeJob(p);
            if (i > 0) {
                vm.prank(CLIENT);
                kernel.fund(id, BUDGET, "");
            }
            if (i > 1) {
                vm.prank(PROVIDER);
                kernel.submit(id, bytes32(uint256(1)), "");
            }
            uint256 statusBefore = _status(id);
            p.setRevertAfter(sels[i], true);
            bool ok;
            bytes memory r;
            if (i == 0) {
                vm.prank(CLIENT);
                (ok, r) = KERNEL.call(abi.encodeCall(IAgenticCommerce.fund, (id, BUDGET, "")));
            } else if (i == 1) {
                vm.prank(PROVIDER);
                (ok, r) = KERNEL.call(abi.encodeCall(IAgenticCommerce.submit, (id, bytes32(uint256(1)), "")));
            } else {
                bytes memory c = i == 2
                    ? abi.encodeCall(IAgenticCommerce.complete, (id, bytes32(0), ""))
                    : abi.encodeCall(IAgenticCommerce.reject, (id, bytes32(0), ""));
                (ok, r) = address(p).call(abi.encodeCall(ProbeHook.exec, (KERNEL, c)));
            }
            p.setRevertAfter(sels[i], false);
            assertTrue(!ok, "action passed despite reverting afterAction");
            assertRevertData(r, want, "revert data of the failed action");
            assertEq(_status(id), statusBefore, "state unchanged");
        }
    }

    /// Pre-3 item 2: a contract evaluator's reject while Funded.
    function test_Pre3_contract_evaluator_reject_in_funded() public {
        ProbeHook p = new ProbeHook();
        uint256 id = _probeJob(p);
        uint256 before = token.balanceOf(CLIENT);
        vm.prank(CLIENT);
        kernel.fund(id, BUDGET, "");
        assertEq(_status(id), 1, "Funded");
        p.exec(KERNEL, abi.encodeCall(IAgenticCommerce.reject, (id, bytes32(0), "")));
        assertEq(_status(id), 4, "Rejected from Funded by a contract evaluator");
        assertEq(token.balanceOf(CLIENT), before, "client refunded");
    }

    /// M-3 re-measured, and the order the evaluator relies on: the kernel writes the new status (and the
    /// deliverable) before afterAction, and beforeAction(fund) sees the job still Open with the budget set.
    function test_M3_entry_order_and_gas_at_entry() public {
        ProbeHook p = new ProbeHook();
        uint256 id = _probeJob(p);
        vm.recordLogs();
        vm.prank(CLIENT);
        kernel.fund(id, BUDGET, "");
        vm.prank(PROVIDER);
        kernel.submit(id, bytes32(uint256(7)), "");
        p.exec(KERNEL, abi.encodeCall(IAgenticCommerce.complete, (id, bytes32(0), "")));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Entry(uint8,bytes4,address,uint256,uint8,uint256)");
        // expected (phase, selector, status) sequence
        uint8[6] memory phase = [0, 1, 0, 1, 0, 1];
        bytes4[6] memory sel = [bytes4(0xd2e13f50), 0xd2e13f50, 0x9e63798d, 0x9e63798d, 0xd75bbdf3, 0xd75bbdf3];
        uint8[6] memory st = [0, 1, 1, 2, 2, 3];
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(p) || logs[i].topics[0] != topic) continue;
            (uint8 ph, bytes4 s, address sender, uint256 g, uint8 status, uint256 budget) =
                abi.decode(logs[i].data, (uint8, bytes4, address, uint256, uint8, uint256));
            assertEq(ph, phase[n], "phase");
            assertTrue(s == sel[n], "selector");
            assertEq(sender, KERNEL, "msg.sender is the kernel");
            assertEq(status, st[n], "job status at entry");
            assertEq(budget, BUDGET, "budget at entry");
            assertTrue(g > 990_000 && g <= 1_000_000, "gasleft at entry");
            log(ph == 0 ? "gasleft at beforeAction entry" : "gasleft at afterAction entry", g);
            n++;
        }
        assertEq(n, 6, "six entries");
        assertEq(kernel.getJob(id).deliverable, bytes32(uint256(7)), "deliverable");
    }
}
