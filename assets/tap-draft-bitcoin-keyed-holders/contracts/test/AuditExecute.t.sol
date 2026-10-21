// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BitcoinKeyedHolder} from "../src/BitcoinKeyedHolder.sol";
import {Secp256k1Ref as R} from "./Secp256k1Ref.sol";
import {AuditSigner as S} from "./AuditLib.sol";

// ----------------------------------------------------------------------------- targets

contract Reenterer {
    BitcoinKeyedHolder public hd;
    bytes public sig;
    uint256 public callGas;
    uint64 public deadline;
    bool public innerOk;
    bytes public innerErr;
    uint256 public nonceSeen;

    function arm(BitcoinKeyedHolder h, bytes calldata s, uint256 g, uint64 d) external {
        hd = h;
        sig = s;
        callGas = g;
        deadline = d;
    }

    function poke() external {
        nonceSeen = hd.nonce();
        try hd.execute(address(this), 0, abi.encodeWithSignature("noop()"), callGas, 0, deadline, sig) {
            innerOk = true;
        } catch (bytes memory e) {
            innerErr = e;
        }
    }

    function noop() external {}
}

contract Reverter {
    error Custom(uint256 a, bytes b);

    function custom() external pure {
        revert Custom(7, "seven");
    }

    function str() external pure {
        revert("plain string");
    }

    function empty() external pure {
        revert();
    }

    function echo(bytes calldata b) external pure returns (bytes memory) {
        return b;
    }
}

contract GasBurner {
    uint256 public x;

    function burn() external {
        while (true) x++;
    }
}

/// A target that tolerates a failing sub-call: the kind of callee for which the relayer's gas choice
/// would change the outcome without making the outer call fail.
contract TryCatcher {
    GasBurner public sub = new GasBurner();
    bool public subOk;
    uint256 public sink;

    function work() external {
        // a sub-call that needs ~1M gas; with less it fails and we carry on
        try this.needsGas() {
            subOk = true;
        } catch {
            subOk = false;
        }
    }

    function needsGas() external {
        // e.g. a callee that checks it has enough gas for a later step, or a sub-call that OOGs
        require(gasleft() > 1_000_000, "need more gas");
        sink += 1;
    }
}

/// Records the gas it was given, so the amount the holder forwards can be measured.
contract GasProbe {
    uint256 public seen;

    function probe() external payable {
        seen = gasleft();
    }

    receive() external payable {
        seen = gasleft();
    }
}

/// Minimal ERC-6551-like account: owner is the holder of a token; execute gated on owner; 1271 forwarded.
contract Container {
    address public token;
    uint256 public id;

    constructor(address t, uint256 i) {
        token = t;
        id = i;
    }

    function owner() public view returns (address) {
        return TestToken(token).ownerOf(id);
    }

    function execute(address to, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        require(msg.sender == owner(), "not owner");
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        require(ok, "call failed");
        return ret;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        return BitcoinKeyedHolder(payable(owner())).isValidSignature(hash, sig);
    }

    receive() external payable {}
}

contract TestToken {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 i) external {
        ownerOf[i] = to;
    }

    function transferFrom(address from, address to, uint256 i) external {
        require(ownerOf[i] == from && msg.sender == from, "not owner");
        ownerOf[i] = to;
    }
}

// ----------------------------------------------------------------------------- tests

contract AuditExecuteTest is Test {
    uint256 constant PRIV = 0xB0B;
    BitcoinKeyedHolder hd;
    uint64 constant DL = 2_000_000_000;
    /// A comfortable gas amount for the ordinary calls in this file.
    uint256 constant G = 500_000;

    event Called(uint256 indexed nonce, address indexed target, uint256 value, bytes32 dataHash);

    function setUp() public {
        vm.etch(S.FACTORY, S.factoryCode());
        (, bytes20 kh) = S.wpPubkey(PRIV);
        hd = S.deploy(S.wpSpk(kh));
        vm.deal(address(hd), 10 ether);
        vm.warp(1_700_000_000);
    }

    function sig(address t, uint256 v, bytes memory d, uint256 g, uint256 n, uint64 dl)
        internal
        returns (bytes memory)
    {
        return S.signP2WPKH(PRIV, hd.callMessage(t, v, d, g, 0, n, dl));
    }

    /// Calls execute with exactly `outerGas`, returning the raw outcome.
    function relay(address t, uint256 v, bytes memory d, uint256 g, bytes memory s, uint256 outerGas)
        internal
        returns (bool ok, bytes memory ret)
    {
        (ok, ret) = address(hd).call{gas: outerGas}(abi.encodeCall(hd.execute, (t, v, d, g, 0, DL, s)));
    }

    function isInsufficientGas(bool ok, bytes memory ret) internal pure returns (bool) {
        return !ok && ret.length == 4 && bytes4(ret) == BitcoinKeyedHolder.InsufficientGas.selector;
    }

    /// The least outer gas with which execute neither reverts InsufficientGas nor runs out of gas
    /// before the check. Deterministic: the gas spent before the check does not depend on the input.
    function minOuterGas(address t, uint256 v, bytes memory d, uint256 g, bytes memory s)
        internal
        returns (uint256 lo)
    {
        lo = g;
        uint256 hi = 30_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = relay(t, v, d, g, s, mid);
            vm.revertToState(snap);
            if (isInsufficientGas(ok, ret) || (!ok && ret.length == 0)) lo = mid + 1;
            else hi = mid;
        }
    }

    // ---- reentrancy: nonce is consumed before the call, so re-entering with the same signature fails

    function test_reentrancy_same_sig_rejected() public {
        Reenterer re = new Reenterer();
        bytes memory data = abi.encodeWithSignature("poke()");
        bytes memory s = sig(address(re), 0, data, G, 0, DL);
        re.arm(hd, s, G, DL);
        hd.execute(address(re), 0, data, G, 0, DL, s);
        assertEq(re.nonceSeen(), 1, "nonce already bumped during the call");
        assertFalse(re.innerOk());
        assertEq(bytes4(re.innerErr()), BitcoinKeyedHolder.BadSignature.selector);
        assertEq(hd.nonce(), 1);
    }

    function test_reentrancy_next_sig_allowed_in_order() public {
        Reenterer re = new Reenterer();
        bytes memory data = abi.encodeWithSignature("poke()");
        uint256 innerGas = 50_000;
        bytes memory s0 = sig(address(re), 0, data, G, 0, DL);
        bytes memory s1 = sig(address(re), 0, abi.encodeWithSignature("noop()"), innerGas, 1, DL);
        re.arm(hd, s1, innerGas, DL);
        vm.expectEmit(true, true, true, true, address(hd));
        emit Called(1, address(re), 0, keccak256(abi.encodeWithSignature("noop()")));
        vm.expectEmit(true, true, true, true, address(hd));
        emit Called(0, address(re), 0, keccak256(data));
        hd.execute(address(re), 0, data, G, 0, DL, s0);
        assertTrue(re.innerOk());
        assertEq(hd.nonce(), 2);
    }

    // ---- revert bubbling and return data

    function test_revert_bubbles_custom_error() public {
        Reverter r = new Reverter();
        bytes memory data = abi.encodeWithSignature("custom()");
        bytes memory s = sig(address(r), 0, data, G, 0, DL);
        vm.expectRevert(abi.encodeWithSelector(Reverter.Custom.selector, 7, bytes("seven")));
        hd.execute(address(r), 0, data, G, 0, DL, s);
        assertEq(hd.nonce(), 0, "nonce untouched after revert");
        // string
        data = abi.encodeWithSignature("str()");
        s = sig(address(r), 0, data, G, 0, DL);
        vm.expectRevert(bytes("plain string"));
        hd.execute(address(r), 0, data, G, 0, DL, s);
        // empty
        data = abi.encodeWithSignature("empty()");
        s = sig(address(r), 0, data, G, 0, DL);
        vm.expectRevert(bytes(""));
        hd.execute(address(r), 0, data, G, 0, DL, s);
    }

    function testFuzz_return_data_forwarded(bytes memory payload) public {
        Reverter r = new Reverter();
        bytes memory data = abi.encodeWithSignature("echo(bytes)", payload);
        bytes memory s = sig(address(r), 0, data, 2_000_000, 0, DL);
        bytes memory ret = hd.execute(address(r), 0, data, 2_000_000, 0, DL, s);
        assertEq(abi.decode(ret, (bytes)), payload);
    }

    // ---- gas: inner OOG makes the whole tx revert; nonce intact; signature usable later

    function test_inner_oog_is_atomic() public {
        GasBurner g = new GasBurner();
        bytes memory data = abi.encodeWithSignature("burn()");
        bytes memory s = sig(address(g), 0, data, 200_000, 0, DL);
        (bool ok, bytes memory ret) = relay(address(g), 0, data, 200_000, s, 1_000_000);
        assertFalse(ok);
        assertEq(ret.length, 0, "the callee's out-of-gas, not the gas check");
        assertEq(hd.nonce(), 0);
        assertEq(g.x(), 0);
    }

    // ---- L-1, fixed: the gas amount is signed and the relayer must fund it

    /// The signer fixes callGas in the message. An underfunded relayer gets InsufficientGas and the
    /// signature stays unspent; a funded one produces the full effect. The relayer can no longer
    /// make the target's tolerated sub-step silently fail.
    function test_relayer_cannot_underfund_the_call() public {
        TryCatcher t = new TryCatcher();
        bytes memory data = abi.encodeWithSignature("work()");
        uint256 callGas = 1_200_000;
        bytes memory s = sig(address(t), 0, data, callGas, 0, DL);
        // stingy relayer: the holder refuses before touching the target; nothing is spent
        (bool ok, bytes memory ret) = relay(address(t), 0, data, callGas, s, 400_000);
        assertTrue(isInsufficientGas(ok, ret), "InsufficientGas");
        assertFalse(t.subOk());
        assertEq(t.sink(), 0);
        assertEq(hd.nonce(), 0, "signature not spent");
        // funded relayer: the same signature now produces the full effect
        (ok,) = relay(address(t), 0, data, callGas, s, 2_000_000);
        assertTrue(ok);
        assertTrue(t.subOk(), "with the signed gas the inner work happens");
        assertEq(t.sink(), 1);
        assertEq(hd.nonce(), 1);
    }

    /// At the exact funding boundary (value 0): one gas less is InsufficientGas, and at the minimum
    /// the callee receives exactly callGas, the same as with a generous relayer.
    function test_callee_receives_exactly_callGas() public {
        GasProbe p = new GasProbe();
        bytes memory data = abi.encodeWithSignature("probe()");
        uint256 callGas = 1_000_000;
        bytes memory s = sig(address(p), 0, data, callGas, 0, DL);
        uint256 snap = vm.snapshotState();
        (bool ok,) = relay(address(p), 0, data, callGas, s, 30_000_000);
        assertTrue(ok);
        uint256 generous = p.seen();
        vm.revertToState(snap);
        uint256 lo = minOuterGas(address(p), 0, data, callGas, s);
        snap = vm.snapshotState();
        (bool ok2, bytes memory ret) = relay(address(p), 0, data, callGas, s, lo - 1);
        assertTrue(isInsufficientGas(ok2, ret), "one gas short");
        assertEq(hd.nonce(), 0);
        vm.revertToState(snap);
        (ok,) = relay(address(p), 0, data, callGas, s, lo);
        assertTrue(ok);
        assertEq(p.seen(), generous, "minimal relayer forwards the same gas as a generous one");
        assertGt(generous, callGas - 500, "the probe sees callGas minus its own dispatch");
        assertLe(generous, callGas);
        assertEq(hd.nonce(), 1);
    }

    /// The same measurement with value > 0. The floor includes the CALL's value-transfer surcharge
    /// (9,000), a cold access (2,600) and a new account (25,000), so a minimally funded relayer still
    /// forwards the full callGas. (Before that overhead was added this test failed by 8.5k to 11k gas.)
    /// These minimal-relayer measurements use tip 0; the floor reserves nothing for the tip, see
    /// AuditTip.t.sol for what happens when the tip does not fit.
    function test_callee_receives_exactly_callGas_with_value() public {
        GasProbe p = new GasProbe();
        uint256 callGas = 1_000_000;
        for (uint256 i = 0; i < 2; i++) {
            bytes memory data = i == 0 ? abi.encodeWithSignature("probe()") : bytes("");
            bytes memory s = sig(address(p), 1 ether, data, callGas, 0, DL);
            uint256 snap = vm.snapshotState();
            (bool ok,) = relay(address(p), 1 ether, data, callGas, s, 30_000_000);
            assertTrue(ok);
            uint256 generous = p.seen();
            vm.revertToState(snap);
            uint256 lo = minOuterGas(address(p), 1 ether, data, callGas, s);
            snap = vm.snapshotState();
            (ok,) = relay(address(p), 1 ether, data, callGas, s, lo);
            assertTrue(ok);
            uint256 minimal = p.seen();
            vm.revertToState(snap);
            emit log_named_uint(i == 0 ? "with data: generous" : "no data: generous", generous);
            emit log_named_uint(i == 0 ? "with data: minimal" : "no data: minimal", minimal);
            // the 2300 stipend is added on top of callGas when value > 0, so this bar is unambiguous
            assertGe(minimal, callGas, "callee must receive at least callGas");
            assertEq(minimal, generous, "minimal relayer forwards the same gas as a generous one");
        }
    }

    /// callGas = 0: a plain value transfer to an EOA still works (the 2300 stipend carries it), while
    /// a call with data to a contract has no gas to run and reverts, leaving the nonce untouched.
    function test_callGas_zero() public {
        address eoa = makeAddr("eoa");
        bytes memory s = sig(eoa, 1 ether, "", 0, 0, DL);
        hd.execute(eoa, 1 ether, "", 0, 0, DL, s);
        assertEq(eoa.balance, 1 ether);
        assertEq(hd.nonce(), 1);
        GasProbe p = new GasProbe();
        bytes memory data = abi.encodeWithSignature("probe()");
        s = sig(address(p), 0, data, 0, 1, DL);
        vm.expectRevert(bytes(""));
        hd.execute(address(p), 0, data, 0, 0, DL, s);
        assertEq(hd.nonce(), 1);
        assertEq(p.seen(), 0);
        // a receive() with value and callGas 0 runs on the stipend alone: an SSTORE does not fit
        s = sig(address(p), 1 ether, "", 0, 1, DL);
        vm.expectRevert(bytes(""));
        hd.execute(address(p), 1 ether, "", 0, 0, DL, s);
        assertEq(hd.nonce(), 1);
    }

    /// callGas is part of the message: a relayer cannot raise or lower it.
    function testFuzz_callGas_is_part_of_message(uint256 g, uint256 g2) public {
        address eoa = makeAddr("eoa");
        vm.assume(g != g2);
        bytes memory s = sig(eoa, 0, "", g, 0, DL);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(eoa, 0, "", g2, 0, DL, s);
        assertEq(hd.nonce(), 0);
    }

    function test_callGas_off_by_one_rejected() public {
        address eoa = makeAddr("eoa");
        bytes memory s = sig(eoa, 0, "", G, 0, DL);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(eoa, 0, "", G + 1, 0, DL, s);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(eoa, 0, "", G - 1, 0, DL, s);
        hd.execute(eoa, 0, "", G, 0, DL, s);
        assertEq(hd.nonce(), 1);
    }

    /// A huge callGas is signable but never fundable: InsufficientGas up to the point where the
    /// floor arithmetic overflows (callGas > 2^256 / 64), after which it is a checked-arithmetic
    /// panic. Either way nothing is spent.
    function test_callGas_huge_is_insufficient() public {
        address eoa = makeAddr("eoa");
        uint256 g = type(uint256).max / 64;
        bytes memory s = sig(eoa, 0, "", g, 0, DL);
        vm.expectRevert(BitcoinKeyedHolder.InsufficientGas.selector);
        hd.execute(eoa, 0, "", g, 0, DL, s);
        assertEq(hd.nonce(), 0);
        s = sig(eoa, 0, "", type(uint256).max, 0, DL);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        hd.execute(eoa, 0, "", type(uint256).max, 0, DL, s);
        assertEq(hd.nonce(), 0);
    }

    // ---- value, deadline, self-calls, no-code targets

    function test_value_forwarded_and_insufficient_balance_reverts() public {
        address eoa = makeAddr("eoa");
        bytes memory s = sig(eoa, 1 ether, "", G, 0, DL);
        hd.execute(eoa, 1 ether, "", G, 0, DL, s);
        assertEq(eoa.balance, 1 ether);
        assertEq(address(hd).balance, 9 ether);
        s = sig(eoa, 100 ether, "", G, 1, DL);
        vm.expectRevert(bytes(""));
        hd.execute(eoa, 100 ether, "", G, 0, DL, s);
        assertEq(hd.nonce(), 1);
    }

    function test_deadline_boundaries() public {
        address eoa = makeAddr("eoa");
        uint64 dl = uint64(block.timestamp);
        bytes memory s = sig(eoa, 0, "", G, 0, dl);
        hd.execute(eoa, 0, "", G, 0, dl, s); // timestamp == deadline passes
        s = sig(eoa, 0, "", G, 1, dl);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(BitcoinKeyedHolder.Expired.selector);
        hd.execute(eoa, 0, "", G, 0, dl, s);
        // max deadline never expires
        vm.warp(type(uint64).max);
        s = sig(eoa, 0, "", G, 1, type(uint64).max);
        hd.execute(eoa, 0, "", G, 0, type(uint64).max, s);
    }

    function test_deadline_is_part_of_message() public {
        address eoa = makeAddr("eoa");
        bytes memory s = sig(eoa, 0, "", G, 0, DL);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(eoa, 0, "", G, 0, DL + 1, s); // a relayer cannot extend the deadline
    }

    function test_call_to_self_changes_nothing_but_nonce() public {
        bytes memory s = sig(address(hd), 1 ether, "", G, 0, DL);
        hd.execute(address(hd), 1 ether, "", G, 0, DL, s);
        assertEq(address(hd).balance, 10 ether);
        assertEq(hd.nonce(), 1);
        // a call to self with unknown selector reverts (no fallback)
        s = sig(address(hd), 0, hex"deadbeef", G, 1, DL);
        vm.expectRevert(bytes(""));
        hd.execute(address(hd), 0, hex"deadbeef", G, 0, DL, s);
    }

    function test_nested_execute_through_self() public {
        address eoa = makeAddr("eoa");
        uint256 innerGas = 50_000;
        bytes memory inner =
            abi.encodeCall(hd.execute, (eoa, 1 ether, "", innerGas, 0, DL, sig(eoa, 1 ether, "", innerGas, 1, DL)));
        bytes memory s0 = sig(address(hd), 0, inner, G, 0, DL);
        hd.execute(address(hd), 0, inner, G, 0, DL, s0);
        assertEq(eoa.balance, 1 ether);
        assertEq(hd.nonce(), 2);
    }

    // ---- L-2, fixed: a call with data to an address without code is refused

    /// A call with data to a no-code target reverts NoCode() and spends nothing; the same target
    /// takes a plain value transfer; and once code is there the very same signature goes through.
    function test_no_code_target_with_data_reverts() public {
        address nothing = makeAddr("not-deployed-yet");
        bytes memory data = abi.encodeWithSignature("transferFrom(address,address,uint256)", hd, nothing, 1);
        bytes memory s = sig(nothing, 0, data, G, 0, DL);
        vm.expectRevert(BitcoinKeyedHolder.NoCode.selector);
        hd.execute(nothing, 0, data, G, 0, DL, s);
        assertEq(hd.nonce(), 0, "signature not spent");
        // a plain value transfer (empty data) to the same EOA still works
        bytes memory sv = sig(nothing, 1 ether, "", G, 0, DL);
        uint256 snap = vm.snapshotState();
        hd.execute(nothing, 1 ether, "", G, 0, DL, sv);
        assertEq(nothing.balance, 1 ether);
        assertEq(hd.nonce(), 1);
        vm.revertToState(snap);
        // the chain was simply not ready: with code at the address the original signature is good
        vm.etch(nothing, type(TestToken).runtimeCode);
        TestToken(nothing).mint(address(hd), 1);
        hd.execute(nothing, 0, data, G, 0, DL, s);
        assertEq(TestToken(nothing).ownerOf(1), nothing);
        assertEq(hd.nonce(), 1);
    }

    /// The signature is checked before the code check: a bad signature for a no-code target is
    /// reported as such, so NoCode never leaks anything about an unauthorised request.
    function test_no_code_check_after_signature() public {
        address nothing = makeAddr("not-deployed-yet");
        bytes memory s = sig(nothing, 0, hex"01", G, 0, DL);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(nothing, 0, hex"02", G, 0, DL, s);
        vm.expectRevert(BitcoinKeyedHolder.NoCode.selector);
        hd.execute(nothing, 0, hex"01", G, 0, DL, s);
    }

    /// Empty data to a precompile address is a plain transfer and goes through; data to a precompile
    /// is refused as NoCode, since precompiles have no code (a consequence of the L-2 fix: the holder
    /// cannot call precompiles directly, only through a contract).
    function test_precompile_target() public {
        address ecrec = address(1);
        bytes memory s = sig(ecrec, 0, "", G, 0, DL);
        hd.execute(ecrec, 0, "", G, 0, DL, s);
        s = sig(ecrec, 0, hex"00", G, 1, DL);
        vm.expectRevert(BitcoinKeyedHolder.NoCode.selector);
        hd.execute(ecrec, 0, hex"00", G, 0, DL, s);
        assertEq(hd.nonce(), 1);
    }

    function test_execute_not_payable() public {
        address eoa = makeAddr("eoa");
        bytes memory s = sig(eoa, 0, "", G, 0, DL);
        (bool ok,) = address(hd).call{value: 1}(abi.encodeCall(hd.execute, (eoa, 0, "", G, 0, DL, s)));
        assertFalse(ok);
    }

    function test_cancel_by_burning_nonce() public {
        address eoa = makeAddr("eoa");
        bytes memory dangerous = sig(eoa, 5 ether, "", G, 0, DL);
        bytes memory cancel = sig(address(hd), 0, "", G, 0, DL);
        hd.execute(address(hd), 0, "", G, 0, DL, cancel);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(eoa, 5 ether, "", G, 0, DL, dangerous);
    }

    function test_front_run_same_sig_second_fails() public {
        address eoa = makeAddr("eoa");
        bytes memory s = sig(eoa, 0, "", G, 0, DL);
        vm.prank(makeAddr("relayerA"));
        hd.execute(eoa, 0, "", G, 0, DL, s);
        vm.prank(makeAddr("relayerB"));
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(eoa, 0, "", G, 0, DL, s);
    }

    // ---- ERC-6551 style container

    function test_container_interaction() public {
        TestToken tok = new TestToken();
        tok.mint(address(hd), 1);
        Container c = new Container(address(tok), 1);
        vm.deal(address(c), 1 ether);
        address eoa = makeAddr("eoa");
        // the holder, as owner of token 1, makes the container pay eoa
        bytes memory data = abi.encodeCall(c.execute, (eoa, 1 ether, ""));
        bytes memory s = sig(address(c), 0, data, G, 0, DL);
        hd.execute(address(c), 0, data, G, 0, DL, s);
        assertEq(eoa.balance, 1 ether);
        // the container's 1271 is answered by the holder's 1271
        bytes32 digest = keccak256("delegation");
        bytes memory ds = S.signP2WPKH(PRIV, hd.signMessage(digest));
        assertEq(c.isValidSignature(digest, ds), bytes4(0x1626ba7e));
        assertEq(c.isValidSignature(keccak256("other"), ds), bytes4(0xffffffff));
        // a §5.1 signature is not a call authorisation and a call signature is not a §5.1 signature
        assertEq(hd.isValidSignature(digest, s), bytes4(0xffffffff));
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(address(c), 0, data, G, 0, DL, ds);
        // nobody else can drive the container
        vm.prank(makeAddr("mallory"));
        vm.expectRevert(bytes("not owner"));
        c.execute(eoa, 0, "");
    }

    // ---- the P2TR path drives execute the same way

    function test_execute_p2tr_key() public {
        uint256 d = 0x7E57;
        bytes32 px = S.trKey(d);
        BitcoinKeyedHolder tr = S.deploy(S.trSpk(px));
        vm.deal(address(tr), 1 ether);
        address eoa = makeAddr("eoa");
        bytes memory w = S.signP2TR(d, tr.callMessage(eoa, 1 ether, "", G, 0, 0, DL), false);
        tr.execute(eoa, 1 ether, "", G, 0, DL, w);
        assertEq(eoa.balance, 1 ether);
        bytes memory w2 = S.signP2TR(d, tr.callMessage(eoa, 0, "", G, 0, 1, DL), true);
        tr.execute(eoa, 0, "", G, 0, DL, w2);
        assertEq(tr.nonce(), 2);
        // and the gas is bound on this path too
        bytes memory w3 = S.signP2TR(d, tr.callMessage(eoa, 0, "", G, 0, 2, DL), false);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        tr.execute(eoa, 0, "", G + 1, 0, DL, w3);
    }

    // ---- receiving

    function test_receive_and_hooks() public {
        (bool ok,) = address(hd).call{value: 1}("");
        assertTrue(ok);
        (ok,) = address(hd).call{value: 1}(hex"01");
        assertFalse(ok, "no fallback: data + value reverts");
        assertEq(hd.onERC721Received(address(0), address(0), 0, ""), bytes4(0x150b7a02));
        assertEq(hd.onERC1155Received(address(0), address(0), 0, 0, ""), bytes4(0xf23a6e61));
        uint256[] memory e;
        assertEq(hd.onERC1155BatchReceived(address(0), address(0), e, e, ""), bytes4(0xbc197c81));
    }
}
