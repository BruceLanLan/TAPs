// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {BitcoinKeyedHolder} from "../src/BitcoinKeyedHolder.sol";
import {AuditSigner as S} from "./AuditLib.sol";
import {TestToken, Reverter} from "./AuditExecute.t.sol";
import {TestToken as VecToken} from "./Holder.t.sol";
import {GeneratedVectors as V} from "./GeneratedVectors.sol";

// ----------------------------------------------------------------------------- helpers

/// A relayer that is a contract: it calls execute itself (so it is msg.sender), can refuse coin, and
/// can replay queued execute calldata from inside its receive(), i.e. while the holder pays the tip.
contract RelayerContract {
    BitcoinKeyedHolder public immutable hd;
    bool public immutable rejecting;
    bytes[] internal queue;
    uint256 public cursor;
    bool[] public oks;
    bytes[] public rets;
    uint256 public receiveCount;
    uint256 public sink;

    constructor(BitcoinKeyedHolder h, bool rejecting_) {
        hd = h;
        rejecting = rejecting_;
    }

    /// Relays `cd` and bubbles the holder's revert.
    function relay(bytes calldata cd) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = address(hd).call(cd);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// Relays `cd` with exactly `g` gas and reports the raw outcome.
    function relayWithGas(bytes calldata cd, uint256 g) external returns (bool ok, bytes memory ret) {
        (ok, ret) = address(hd).call{gas: g}(cd);
    }

    /// Queues calldata to send to the holder from inside receive().
    function arm(bytes calldata cd) external {
        queue.push(cd);
    }

    function outcomes() external view returns (uint256) {
        return oks.length;
    }

    receive() external payable {
        if (rejecting) revert("no coin please");
        receiveCount++;
        sink += 1; // a storage write, so a starved receive() fails
        while (cursor < queue.length) {
            uint256 i = cursor++;
            (bool ok, bytes memory r) = address(hd).call(queue[i]);
            oks.push(ok);
            rets.push(r);
        }
    }
}

/// A relayer whose receive() returns data of its own, to check that execute still returns the callee's.
contract NoisyRelayer {
    function relay(BitcoinKeyedHolder hd, bytes calldata cd) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = address(hd).call(cd);
        require(ok, "relay failed");
    }

    receive() external payable {
        assembly {
            mstore(0, 0xbadbadbadbad)
            return(0, 96)
        }
    }
}

/// A payable target that either accepts the call or reverts, for the fuzz test.
contract PayableSink {
    error Nope();

    uint256 public hits;

    function take(bool fail) external payable {
        if (fail) revert Nope();
        hits++;
    }
}

/// A target that records an effect and then burns nearly all of the gas it was given, returning
/// successfully: after it, the holder has only its own reserve left to pay the tip.
contract GasEater {
    uint256 public effect;

    function eat() external {
        effect = 1;
        while (gasleft() > 3000) {}
    }
}

// ----------------------------------------------------------------------------- tests

/// The signed relay tip of execute: who gets paid, how much, when, and that every failure is atomic.
contract AuditTipTest is Test {
    uint256 constant PRIV = 0xB0B;
    uint64 constant DL = 2_000_000_000;
    uint256 constant G = 500_000;
    uint256 constant TIP = 0.01 ether;
    BitcoinKeyedHolder hd;
    address relayer;
    address eoa;

    event Called(uint256 indexed nonce, address indexed target, uint256 value, bytes32 dataHash);

    function setUp() public {
        vm.etch(S.FACTORY, S.factoryCode());
        (, bytes20 kh) = S.wpPubkey(PRIV);
        hd = S.deploy(S.wpSpk(kh));
        vm.deal(address(hd), 10 ether);
        vm.warp(1_700_000_000);
        relayer = makeAddr("relayer");
        eoa = makeAddr("eoa");
    }

    function sig(address t, uint256 v, bytes memory d, uint256 g, uint256 tip, uint256 n, uint64 dl)
        internal
        returns (bytes memory)
    {
        return S.signP2WPKH(PRIV, hd.callMessage(t, v, d, g, tip, n, dl));
    }

    function cd(address t, uint256 v, bytes memory d, uint256 g, uint256 tip, bytes memory s)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(hd.execute, (t, v, d, g, tip, DL, s));
    }

    /// execute from `from` (an EOA, via prank) with exactly `outerGas`; the raw outcome.
    function relayAs(address from, bytes memory calldata_, uint256 outerGas)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(from);
        (ok, ret) = address(hd).call{gas: outerGas}(calldata_);
    }

    function is4(bytes memory ret, bytes4 sel) internal pure returns (bool) {
        return ret.length == 4 && bytes4(ret) == sel;
    }

    function tokenTo(address to, uint256 id) internal returns (TestToken tok, bytes memory data) {
        tok = new TestToken();
        tok.mint(address(hd), id);
        data = abi.encodeCall(tok.transferFrom, (address(hd), to, id));
    }

    // ---- (a) the tip goes to the relaying EOA; the holder pays value + tip

    function test_tip_paid_to_relayer_eoa() public {
        bytes memory s = sig(eoa, 1 ether, "", G, TIP, 0, DL);
        vm.expectEmit(true, true, true, true, address(hd));
        emit Called(0, eoa, 1 ether, keccak256(""));
        vm.prank(relayer);
        hd.execute(eoa, 1 ether, "", G, TIP, DL, s);
        assertEq(relayer.balance, TIP, "relayer got exactly the tip");
        assertEq(eoa.balance, 1 ether, "target got the value");
        assertEq(address(hd).balance, 10 ether - 1 ether - TIP, "holder paid value + tip");
        assertEq(hd.nonce(), 1);
        // a front-runner copying the same signature gets nothing
        address other = makeAddr("other");
        vm.prank(other);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(eoa, 1 ether, "", G, TIP, DL, s);
        assertEq(other.balance, 0);
    }

    /// The pre-signed vector with a nonzero tip (made by tools/make_vectors.py): the Python renderer
    /// and the contract agree on the message, and the relayer is paid exactly the signed 0.01 coin.
    function test_vector_with_tip() public {
        V.CallCase memory c = V.callCases()[3];
        assertEq(c.tip, 0.01 ether);
        vm.chainId(56); // the chain of every call vector
        BitcoinKeyedHolder h = S.deploy(V.SPK_P2WPKH);
        assertEq(address(h), V.HOLDER_P2WPKH);
        vm.etch(c.target, type(VecToken).runtimeCode);
        VecToken(c.target).mint(address(h), 7);
        assertEq(h.callMessage(c.target, c.value, c.data, c.gas, c.tip, c.nonce, c.deadline), c.message);
        vm.deal(address(h), 1 ether);
        vm.warp(c.deadline);
        vm.prank(relayer);
        h.execute(c.target, c.value, c.data, c.gas, c.tip, c.deadline, c.sig);
        assertEq(VecToken(c.target).ownerOf(7), address(0xb0));
        assertEq(relayer.balance, c.tip);
        assertEq(address(h).balance, 1 ether - c.tip);
        assertEq(h.nonce(), 1);
    }

    // ---- (b) a tip of 0 pays nothing: not even a zero-value call

    function test_tip_zero_pays_nothing() public {
        // a relayer contract that rejects coin still relays a tip-0 call: no payment call is made
        RelayerContract rej = new RelayerContract(hd, true);
        bytes memory s = sig(eoa, 1 ether, "", G, 0, 0, DL);
        rej.relay(cd(eoa, 1 ether, "", G, 0, s));
        assertEq(hd.nonce(), 1);
        assertEq(address(rej).balance, 0);
        assertEq(address(hd).balance, 9 ether, "holder paid the value only");
        // and a relayer contract that accepts coin is never called back
        RelayerContract acc = new RelayerContract(hd, false);
        s = sig(eoa, 0, "", G, 0, 1, DL);
        acc.relay(cd(eoa, 0, "", G, 0, s));
        assertEq(acc.receiveCount(), 0, "receive() never ran");
        assertEq(address(acc).balance, 0);
        assertEq(hd.nonce(), 2);
    }

    // ---- (c) balance below value + tip: the whole call reverts and the signature survives

    function test_tip_unaffordable_undoes_the_call() public {
        (TestToken tok, bytes memory data) = tokenTo(eoa, 1);
        vm.deal(address(hd), TIP / 2);
        bytes memory s = sig(address(tok), 0, data, G, TIP, 0, DL);
        vm.prank(relayer);
        vm.expectRevert(BitcoinKeyedHolder.TipFailed.selector);
        hd.execute(address(tok), 0, data, G, TIP, DL, s);
        assertEq(hd.nonce(), 0, "nonce unchanged");
        assertEq(tok.ownerOf(1), address(hd), "token transfer undone");
        assertEq(address(hd).balance, TIP / 2);
        assertEq(relayer.balance, 0);
        // once someone tops the holder up, the very same signature goes through
        vm.deal(address(hd), TIP);
        vm.prank(relayer);
        hd.execute(address(tok), 0, data, G, TIP, DL, s);
        assertEq(tok.ownerOf(1), eoa);
        assertEq(relayer.balance, TIP);
        assertEq(address(hd).balance, 0);
        assertEq(hd.nonce(), 1);
    }

    // ---- (d) a relayer that rejects coin gets TipFailed and nothing changes

    function test_rejecting_relayer_tip_failed() public {
        RelayerContract rej = new RelayerContract(hd, true);
        (TestToken tok, bytes memory data) = tokenTo(eoa, 1);
        bytes memory s = sig(address(tok), 0, data, G, TIP, 0, DL);
        vm.expectRevert(BitcoinKeyedHolder.TipFailed.selector);
        rej.relay(cd(address(tok), 0, data, G, TIP, s));
        assertEq(hd.nonce(), 0);
        assertEq(tok.ownerOf(1), address(hd));
        assertEq(address(hd).balance, 10 ether);
        // an EOA can still relay the same signature
        vm.prank(relayer);
        hd.execute(address(tok), 0, data, G, TIP, DL, s);
        assertEq(relayer.balance, TIP);
    }

    // ---- (e) a relayer re-entering from receive(): the next nonce works, the first signature does not

    function test_reentrant_relayer() public {
        RelayerContract rc = new RelayerContract(hd, false);
        (TestToken tok, bytes memory data) = tokenTo(eoa, 1);
        bytes memory s0 = sig(address(tok), 0, data, G, TIP, 0, DL);
        uint256 innerGas = 50_000;
        uint256 tip1 = TIP / 4;
        bytes memory s1 = sig(eoa, 0.5 ether, "", innerGas, tip1, 1, DL);
        // inside the tip: first replay the spent signature, then use the next one (which tips again)
        rc.arm(cd(address(tok), 0, data, G, TIP, s0));
        rc.arm(cd(eoa, 0.5 ether, "", innerGas, tip1, s1));
        // the re-entered call's event comes first: Called is emitted after the tip is paid
        vm.expectEmit(true, true, true, true, address(hd));
        emit Called(1, eoa, 0.5 ether, keccak256(""));
        vm.expectEmit(true, true, true, true, address(hd));
        emit Called(0, address(tok), 0, keccak256(data));
        rc.relay(cd(address(tok), 0, data, G, TIP, s0));
        assertEq(rc.outcomes(), 2);
        assertFalse(rc.oks(0), "first signature cannot be reused");
        assertTrue(is4(rc.rets(0), BitcoinKeyedHolder.BadSignature.selector));
        assertTrue(rc.oks(1), "nonce+1 signature works inside the tip");
        assertEq(hd.nonce(), 2);
        assertEq(tok.ownerOf(1), eoa);
        assertEq(eoa.balance, 0.5 ether);
        assertEq(address(rc).balance, TIP + tip1, "both signed tips, nothing more");
        assertEq(rc.receiveCount(), 2);
        assertEq(address(hd).balance, 10 ether - 0.5 ether - TIP - tip1);
    }

    /// A relayer that tries to replay the spent signature from inside the tip: the holder refuses it
    /// (BadSignature) and the outer call completes with one tip.
    function test_reentrant_relayer_replay_only() public {
        RelayerContract rc = new RelayerContract(hd, false);
        (TestToken tok, bytes memory data) = tokenTo(eoa, 1);
        bytes memory s0 = sig(address(tok), 0, data, G, TIP, 0, DL);
        rc.arm(cd(address(tok), 0, data, G, TIP, s0));
        rc.relay(cd(address(tok), 0, data, G, TIP, s0));
        // receive() swallows the inner failure: one tip, nonce 1
        assertEq(rc.outcomes(), 1);
        assertTrue(is4(rc.rets(0), BitcoinKeyedHolder.BadSignature.selector));
        assertEq(hd.nonce(), 1);
        assertEq(address(rc).balance, TIP);
    }

    // ---- (f) the tip is signed

    function test_tip_change_invalidates_signature() public {
        bytes memory s = sig(eoa, 0, "", G, TIP, 0, DL);
        vm.startPrank(relayer);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(eoa, 0, "", G, TIP + 1, DL, s);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(eoa, 0, "", G, TIP - 1, DL, s);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(eoa, 0, "", G, 0, DL, s);
        // a tip-0 signature cannot be given a tip either
        bytes memory s0 = sig(eoa, 0, "", G, 0, 0, DL);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(eoa, 0, "", G, 1, DL, s0);
        hd.execute(eoa, 0, "", G, TIP, DL, s);
        vm.stopPrank();
        assertEq(relayer.balance, TIP);
    }

    function testFuzz_tip_change_invalidates_signature(uint256 tip, uint256 tip2) public {
        vm.assume(tip != tip2);
        bytes memory s = sig(eoa, 0, "", G, tip, 0, DL);
        vm.prank(relayer);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(eoa, 0, "", G, tip2, DL, s);
        assertEq(hd.nonce(), 0);
    }

    /// The P2TR path pays and binds the tip the same way.
    function test_tip_p2tr() public {
        uint256 d = 0x7E57;
        BitcoinKeyedHolder tr = S.deploy(S.trSpk(S.trKey(d)));
        vm.deal(address(tr), 1 ether);
        bytes memory w = S.signP2TR(d, tr.callMessage(eoa, 0.1 ether, "", G, TIP, 0, DL), true);
        vm.startPrank(relayer);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        tr.execute(eoa, 0.1 ether, "", G, TIP + 1, DL, w);
        tr.execute(eoa, 0.1 ether, "", G, TIP, DL, w);
        vm.stopPrank();
        assertEq(relayer.balance, TIP);
        assertEq(address(tr).balance, 1 ether - 0.1 ether - TIP);
    }

    // ---- (g) value and tip both come from the balance: the exact boundary

    function test_value_plus_tip_exact_balance() public {
        uint256 value = 1 ether;
        bytes memory s = sig(eoa, value, "", G, TIP, 0, DL);
        // one wei short: the value goes out, then the tip cannot be paid, and the value comes back
        vm.deal(address(hd), value + TIP - 1);
        vm.prank(relayer);
        vm.expectRevert(BitcoinKeyedHolder.TipFailed.selector);
        hd.execute(eoa, value, "", G, TIP, DL, s);
        assertEq(eoa.balance, 0);
        assertEq(address(hd).balance, value + TIP - 1);
        assertEq(hd.nonce(), 0);
        // short by more than the tip: the value transfer itself fails (empty revert, not TipFailed)
        vm.deal(address(hd), value - 1);
        vm.prank(relayer);
        vm.expectRevert(bytes(""));
        hd.execute(eoa, value, "", G, TIP, DL, s);
        // exactly value + tip: succeeds and empties the holder
        vm.deal(address(hd), value + TIP);
        vm.prank(relayer);
        hd.execute(eoa, value, "", G, TIP, DL, s);
        assertEq(address(hd).balance, 0);
        assertEq(eoa.balance, value);
        assertEq(relayer.balance, TIP);
    }

    // ---- (h) fuzz: the holder pays exactly value + tip on success and nothing otherwise

    function testFuzz_tip_accounting(uint256 balance, uint256 value, uint256 tip, bool fail) public {
        balance = bound(balance, 0, 100 ether);
        value = bound(value, 0, 100 ether);
        tip = bound(tip, 0, 100 ether);
        PayableSink t = new PayableSink();
        vm.deal(address(hd), balance);
        bytes memory data = abi.encodeCall(t.take, (fail));
        bytes memory s = sig(address(t), value, data, G, tip, 0, DL);
        uint256 rBefore = relayer.balance;
        (bool ok, bytes memory ret) = relayAs(relayer, cd(address(t), value, data, G, tip, s), 5_000_000);
        bool expectOk = !fail && value <= balance && tip <= balance - value;
        assertEq(ok, expectOk, "succeeds exactly when the call succeeds and value + tip fit");
        if (ok) {
            assertEq(balance - address(hd).balance, value + tip, "holder paid value + tip");
            assertEq(relayer.balance - rBefore, tip, "relayer got exactly the signed tip");
            assertEq(address(t).balance, value);
            assertEq(t.hits(), 1);
            assertEq(hd.nonce(), 1);
        } else {
            assertEq(address(hd).balance, balance, "holder untouched");
            assertEq(relayer.balance, rBefore, "no tip without a successful call");
            assertEq(address(t).balance, 0);
            assertEq(t.hits(), 0);
            assertEq(hd.nonce(), 0, "signature still unspent");
            if (value > balance) assertEq(ret.length, 0, "value transfer failed");
            else if (fail) assertTrue(is4(ret, PayableSink.Nope.selector), "callee's reason");
            else assertTrue(is4(ret, BitcoinKeyedHolder.TipFailed.selector), "TipFailed");
        }
    }

    /// With a tip, execute still returns the callee's return data, not the tip recipient's.
    function testFuzz_return_data_with_tip(bytes memory payload) public {
        Reverter r = new Reverter();
        NoisyRelayer nr = new NoisyRelayer();
        bytes memory data = abi.encodeWithSignature("echo(bytes)", payload);
        bytes memory s = sig(address(r), 0, data, 2_000_000, TIP, 0, DL);
        bytes memory ret = abi.decode(nr.relay(hd, cd(address(r), 0, data, 2_000_000, TIP, s)), (bytes));
        assertEq(abi.decode(ret, (bytes)), payload);
        assertEq(address(nr).balance, TIP);
    }

    // ---- (i) msg.sender, not tx.origin

    function test_tip_to_msg_sender_not_tx_origin() public {
        RelayerContract fwd = new RelayerContract(hd, false);
        address origin = makeAddr("origin");
        bytes memory s = sig(eoa, 0, "", G, TIP, 0, DL);
        vm.prank(origin, origin);
        fwd.relay(cd(eoa, 0, "", G, TIP, s));
        assertEq(address(fwd).balance, TIP, "the forwarding contract is paid");
        assertEq(origin.balance, 0, "tx.origin is not");
        assertEq(hd.nonce(), 1);
    }

    // ---- self-calls: a nested execute through the holder tips the holder itself

    function test_self_call_tip_goes_to_holder() public {
        uint256 innerGas = 60_000;
        uint256 innerTip = 0.5 ether;
        bytes memory inner = cd(eoa, 1 ether, "", innerGas, innerTip, sig(eoa, 1 ether, "", innerGas, innerTip, 1, DL));
        bytes memory s0 = sig(address(hd), 0, inner, G, TIP, 0, DL);
        vm.prank(relayer);
        hd.execute(address(hd), 0, inner, G, TIP, DL, s0);
        assertEq(hd.nonce(), 2);
        assertEq(eoa.balance, 1 ether);
        assertEq(relayer.balance, TIP, "outer relayer gets the outer tip only");
        assertEq(address(hd).balance, 10 ether - 1 ether - TIP, "the inner tip went to the holder itself");
        // an inner tip the holder cannot pay to itself fails the whole thing
        vm.deal(address(hd), 1 ether + TIP);
        uint256 big = 5 ether;
        inner = cd(eoa, 1 ether, "", innerGas, big, sig(eoa, 1 ether, "", innerGas, big, 3, DL));
        s0 = sig(address(hd), 0, inner, G, TIP, 2, DL);
        vm.prank(relayer);
        vm.expectRevert(BitcoinKeyedHolder.TipFailed.selector);
        hd.execute(address(hd), 0, inner, G, TIP, DL, s0);
        assertEq(hd.nonce(), 2);
    }

    // ---- nothing is paid when execute stops before the call or the call fails

    function test_no_tip_on_early_or_inner_failure() public {
        vm.startPrank(relayer);
        // Expired
        bytes memory s = sig(eoa, 0, "", G, TIP, 0, 1);
        vm.expectRevert(BitcoinKeyedHolder.Expired.selector);
        hd.execute(eoa, 0, "", G, TIP, 1, s);
        // NoCode
        address nothing = makeAddr("nothing");
        s = sig(nothing, 0, hex"01", G, TIP, 0, DL);
        vm.expectRevert(BitcoinKeyedHolder.NoCode.selector);
        hd.execute(nothing, 0, hex"01", G, TIP, DL, s);
        vm.stopPrank();
        // InsufficientGas
        s = sig(eoa, 0, "", 1_000_000, TIP, 0, DL);
        (bool ok, bytes memory ret) = relayAs(relayer, cd(eoa, 0, "", 1_000_000, TIP, s), 600_000);
        assertFalse(ok);
        assertTrue(is4(ret, BitcoinKeyedHolder.InsufficientGas.selector));
        // inner revert
        PayableSink t = new PayableSink();
        bytes memory data = abi.encodeCall(t.take, (true));
        s = sig(address(t), 0, data, G, TIP, 0, DL);
        vm.prank(relayer);
        vm.expectRevert(PayableSink.Nope.selector);
        hd.execute(address(t), 0, data, G, TIP, DL, s);
        assertEq(relayer.balance, 0);
        assertEq(address(hd).balance, 10 ether);
        assertEq(hd.nonce(), 0);
    }

    // ---- gas griefing: too little gas for the tip after the call succeeded

    /// Sweeps the relayer's gas through the window around the least gas that succeeds, with a callee
    /// that uses all of callGas and returns. At every point the outcome is either complete (effect,
    /// nonce 1, tip paid) or nothing at all: a relayer cannot keep the call's effect while the tip
    /// fails. Near the floor the revert is a bare out-of-gas (EOA relayer) or TipFailed (a relayer
    /// whose receive() needs gas), after InsufficientGas has already passed: the gas check reserves
    /// nothing for the tip, so an underfunded relayer is not rejected up front.
    function test_gas_griefing_is_atomic_eoa() public {
        sweep(false);
    }

    function test_gas_griefing_is_atomic_contract_relayer() public {
        sweep(true);
    }

    struct Tally {
        uint256 insufficient;
        uint256 oog;
        uint256 tipFailed;
        uint256 success;
        uint256 maxInsufficientGas;
        uint256 lateOog; // bare reverts above every InsufficientGas point: the call ran, the tip did not fit
        uint256 lateTipFailed;
    }

    uint8 constant OK = 0;
    uint8 constant IG = 1;
    uint8 constant TF = 2;
    uint8 constant OOG = 3;

    // the sweep's fixed inputs, kept in storage to stay within the stack
    GasEater sweepTarget;
    bytes sweepCall;
    RelayerContract sweepRelayer;
    bool sweepViaContract;

    function sweep(bool contractRelayer) internal {
        GasEater t = new GasEater();
        bytes memory data = abi.encodeCall(t.eat, ());
        uint256 callGas = 200_000;
        sweepTarget = t;
        sweepCall = cd(address(t), 0, data, callGas, TIP, sig(address(t), 0, data, callGas, TIP, 0, DL));
        sweepRelayer = new RelayerContract(hd, false);
        sweepViaContract = contractRelayer;

        // least outer gas that succeeds
        uint256 lo = callGas;
        uint256 hi = 5_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,) = attempt(mid);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
        emit log_named_uint(contractRelayer ? "contract relayer: least gas" : "EOA relayer: least gas", lo);

        // coarse steps far below the boundary, every gas value in the last 1,000 (the test gas limit caps the total)
        uint256[] memory gs = new uint256[](2_000);
        uint8[] memory kinds = new uint8[](2_000);
        uint256 m;
        Tally memory k;
        for (uint256 g = lo - 120_000; g < lo + 20; g += (g < lo - 1_000 ? 151 : 1)) {
            uint8 kind = probe(g);
            if (kind == OK) assertGe(g, lo);
            else assertLt(g, lo);
            if (kind == OK) k.success++;
            if (kind == IG) {
                k.insufficient++;
                k.maxInsufficientGas = g;
            }
            if (kind == TF) k.tipFailed++;
            if (kind == OOG) k.oog++;
            gs[m] = g;
            kinds[m++] = kind;
        }
        for (uint256 i = 0; i < m; i++) {
            if (gs[i] <= k.maxInsufficientGas) continue;
            if (kinds[i] == OOG) k.lateOog++;
            if (kinds[i] == TF) k.lateTipFailed++;
        }
        emit log_named_uint("InsufficientGas", k.insufficient);
        emit log_named_uint("out of gas", k.oog);
        emit log_named_uint("TipFailed", k.tipFailed);
        emit log_named_uint("success", k.success);
        emit log_named_uint("window above InsufficientGas: out of gas", k.lateOog);
        emit log_named_uint("window above InsufficientGas: TipFailed", k.lateTipFailed);
        emit log_named_uint("window width (gas)", lo - k.maxInsufficientGas - 1);
        assertGt(k.success, 0);
        assertGt(k.insufficient, 0);
        // the window exists: InsufficientGas passed, the call ran, and the tip step reverted everything
        assertGt(k.lateOog + k.lateTipFailed, 0, "underfunded tip is caught only after the call");
    }

    /// One relay with exactly `g` gas, checked for all-or-nothing, then rolled back.
    function probe(uint256 g) internal returns (uint8 kind) {
        address payee = sweepViaContract ? address(sweepRelayer) : relayer;
        uint256 snap = vm.snapshotState();
        uint256 pBefore = payee.balance;
        (bool ok, bytes memory ret) = attempt(g);
        if (ok) {
            kind = OK;
            assertEq(sweepTarget.effect(), 1);
            assertEq(hd.nonce(), 1);
            assertEq(payee.balance - pBefore, TIP);
            assertEq(address(hd).balance, 10 ether - TIP);
        } else {
            assertEq(sweepTarget.effect(), 0, "no effect without the tip");
            assertEq(hd.nonce(), 0, "nonce untouched");
            assertEq(payee.balance, pBefore);
            assertEq(address(hd).balance, 10 ether);
            if (is4(ret, BitcoinKeyedHolder.InsufficientGas.selector)) {
                kind = IG;
            } else if (is4(ret, BitcoinKeyedHolder.TipFailed.selector)) {
                kind = TF;
            } else {
                assertEq(ret.length, 0, "only InsufficientGas, TipFailed or out of gas");
                kind = OOG;
            }
        }
        vm.revertToState(snap);
    }

    function attempt(uint256 g) internal returns (bool ok, bytes memory ret) {
        if (sweepViaContract) return sweepRelayer.relayWithGas(sweepCall, g);
        return relayAs(relayer, sweepCall, g);
    }
}
