// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {BitcoinKeyedHolder} from "../../src/BitcoinKeyedHolder.sol";
import {BitcoinKeyedHolder as B} from "../../src/BitcoinKeyedHolder.sol";
import {AuditSigner as S} from "../AuditLib.sol";
import {GeneratedBatchVectors as BV} from "./GeneratedBatchVectors.sol";
import {BenchERC721} from "./BenchERC721.sol";

// ----------------------------------------------------------------------------- targets

contract Probe {
    uint256[] public seen;

    function probe() external payable {
        seen.push(gasleft());
    }

    function count() external view returns (uint256) {
        return seen.length;
    }
}

contract Failer {
    error Custom(uint256 a);

    function fail() external pure {
        revert Custom(7);
    }

    function ok() external pure returns (uint256) {
        return 42;
    }
}

/// Returns or reverts with `n` bytes: the first word is a marker, the rest zeros (audit F-01, F-02).
contract DataBomb {
    function ret(uint256 n) external pure {
        assembly {
            mstore(0, 0xb0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0)
            return(0, n)
        }
    }

    function rev(uint256 n) external pure {
        assembly {
            mstore(0, 0xdeaddeaddeaddeaddeaddeaddeaddeaddeaddeaddeaddeaddeaddeaddeaddead)
            mstore(0x20, 0x0102030405060708091011121314151617181920212223242526272829303132)
            mstore(0x40, 0) // the rest of the revert data is zeros (it ends the call, so the pointer does not matter)
            revert(0, n)
        }
    }
}

/// Re-enters executeBatch (or execute) with calldata it was given, from inside a batched call or from
/// receive() when it is the relayer collecting the tip.
contract BatchReenterer {
    B public hd;
    bytes public cd;
    bool public tried;
    bool public innerOk;
    bytes public innerErr;
    uint256 public nonceSeen;

    function arm(B h, bytes calldata c) external {
        hd = h;
        cd = c;
    }

    function poke() external {
        _reenter();
    }

    function relay(bytes calldata c) external {
        (bool ok, bytes memory ret) = address(hd).call(c);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _reenter() internal {
        if (tried) return;
        tried = true;
        nonceSeen = hd.nonce();
        bytes memory ret;
        (innerOk, ret) = address(hd).call(cd);
        if (!innerOk) innerErr = ret;
    }

    receive() external payable {
        _reenter();
    }
}

contract BatchTest is Test {
    uint256 constant PRIV = 0xB0B;
    uint64 constant DL = 2_000_000_000;
    uint256 constant G = 200_000;
    B hd;
    BenchERC721 nft;
    Failer failer;

    event Called(uint256 indexed nonce, address indexed target, uint256 value, bytes32 dataHash);

    function deployB(bytes memory spk) internal returns (B) {
        bytes memory init = abi.encodePacked(type(B).creationCode, abi.encode(spk));
        (bool ok, bytes memory ret) = S.FACTORY.call(abi.encodePacked(bytes32(0), init));
        require(ok && ret.length == 20, "factory");
        return B(payable(address(bytes20(ret))));
    }

    function setUp() public {
        vm.etch(S.FACTORY, S.factoryCode());
        (, bytes20 kh) = S.wpPubkey(PRIV);
        hd = deployB(S.wpSpk(kh));
        vm.deal(address(hd), 10 ether);
        vm.warp(1_700_000_000);
        nft = new BenchERC721();
        for (uint256 i = 1; i <= 10; i++) {
            nft.mint(address(hd), i);
        }
        failer = new Failer();
    }

    // ------------------------------------------------------------------ helpers

    function xfer(uint256 id) internal view returns (B.Call memory) {
        return B.Call(address(nft), 0, abi.encodeCall(nft.safeTransferFrom, (address(hd), address(0xb0), id)), G);
    }

    function transfers(uint256 k) internal view returns (B.Call[] memory cs) {
        cs = new B.Call[](k);
        for (uint256 i = 0; i < k; i++) {
            cs[i] = xfer(i + 1);
        }
    }

    function one(B.Call memory c) internal pure returns (B.Call[] memory cs) {
        cs = new B.Call[](1);
        cs[0] = c;
    }

    function sign(B.Call[] memory cs, uint256 tip, uint256 n) internal returns (bytes memory) {
        return S.signP2WPKH(PRIV, hd.batchMessage(cs, tip, n, DL));
    }

    function cd(B.Call[] memory cs, uint256 tip, bytes memory s) internal pure returns (bytes memory) {
        return abi.encodeCall(B.executeBatch, (cs, tip, DL, s));
    }

    function relay(B.Call[] memory cs, uint256 tip, bytes memory s, uint256 outerGas)
        internal
        returns (bool ok, bytes memory ret)
    {
        (ok, ret) = address(hd).call{gas: outerGas}(cd(cs, tip, s));
    }

    function revertsWith(bool ok, bytes memory ret, bytes4 sel) internal pure returns (bool) {
        return !ok && ret.length >= 4 && bytes4(ret) == sel;
    }

    // ------------------------------------------------------------------ vectors (Python reference)

    function test_vectors_creation_code_and_addresses() public {
        assertEq(keccak256(type(B).creationCode), BV.CREATION_CODE_KECCAK);
        assertEq(address(deployB(BV.SPK_P2TR)), BV.HOLDER_P2TR);
        assertEq(address(deployB(BV.SPK_P2WPKH)), BV.HOLDER_P2WPKH);
        // final lab: one contract, so the batch vectors and the single-call vectors name the same holders
        assertEq(BV.CREATION_CODE_KECCAK, keccak256(type(BitcoinKeyedHolder).creationCode));
    }

    /// Every vector: the contract renders the Python text byte for byte, the Python calldata is the ABI
    /// encoding, the Python signature (P2TR or P2WPKH) is accepted, every call happens, the tip is paid
    /// once, one nonce is used, one Called per call; then replay, expiry and another chain are rejected.
    function test_vectors_execute() public {
        for (uint256 i = 0; i < BV.count(); i++) {
            uint256 snap = vm.snapshotState();
            BV.BatchCase memory c = BV.batchCase(i);
            vm.chainId(c.chainId);
            B h = deployB(c.holder == 0 ? BV.SPK_P2TR : BV.SPK_P2WPKH);
            vm.etch(BV.TOKEN, type(BenchERC721).runtimeCode);
            for (uint256 id = 1; id <= 8; id++) {
                BenchERC721(BV.TOKEN).mint(address(h), id);
            }
            vm.deal(address(h), 1 ether);
            assertEq(h.batchMessage(c.calls, c.tip, c.nonce, c.deadline), c.message, c.name);
            assertEq(abi.encodeCall(B.executeBatch, (c.calls, c.tip, c.deadline, c.sig)), c.calldata_, c.name);
            vm.warp(c.deadline);
            address relayer = makeAddr("relayer");
            uint256 before = relayer.balance;
            vm.recordLogs();
            vm.prank(relayer);
            (bool ok,) = address(h).call(c.calldata_);
            assertTrue(ok, c.name);
            assertEq(relayer.balance - before, c.tip, "tip once");
            assertEq(h.nonce(), 1);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 called;
            for (uint256 j = 0; j < logs.length; j++) {
                if (logs[j].emitter == address(h) && logs[j].topics[0] == Called.selector) {
                    assertEq(uint256(logs[j].topics[1]), 0, "same nonce");
                    assertEq(address(uint160(uint256(logs[j].topics[2]))), c.calls[called].target, "call order");
                    called++;
                }
            }
            assertEq(called, c.calls.length, "one Called per call");
            for (uint256 j = 0; j < c.calls.length; j++) {
                if (c.calls[j].target == BV.TOKEN) {
                    uint256 id = uint256(bytes32(_slice(c.calls[j].data, 68)));
                    assertEq(BenchERC721(BV.TOKEN).ownerOf(id), BV.RECIPIENT);
                }
            }
            // replay
            (ok,) = address(h).call(c.calldata_);
            assertFalse(ok);
            vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
            h.executeBatch(c.calls, c.tip, c.deadline, c.sig);
            vm.revertToState(snap);
            // expiry and another chain, from the initial state
            snap = vm.snapshotState();
            vm.chainId(c.chainId);
            h = deployB(c.holder == 0 ? BV.SPK_P2TR : BV.SPK_P2WPKH);
            vm.warp(uint256(c.deadline) + 1);
            vm.expectRevert(BitcoinKeyedHolder.Expired.selector);
            h.executeBatch(c.calls, c.tip, c.deadline, c.sig);
            vm.warp(c.deadline);
            vm.chainId(8453);
            vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
            h.executeBatch(c.calls, c.tip, c.deadline, c.sig);
            vm.revertToState(snap);
        }
    }

    /// The same messages signed by bip322-js 4.0.0 (tools/wallet-lib-check/sign-batch.mjs): every batch
    /// goes through with the library's signature, and a signature of one case is refused for another.
    function test_vectors_bip322js() public {
        assertEq(BV.libCount(), BV.count(), "run sign-batch.mjs, then make_batch_vectors.py");
        for (uint256 i = 0; i < BV.count(); i++) {
            uint256 snap = vm.snapshotState();
            BV.BatchCase memory c = BV.batchCase(i);
            vm.chainId(c.chainId);
            B h = deployB(c.holder == 0 ? BV.SPK_P2TR : BV.SPK_P2WPKH);
            vm.etch(BV.TOKEN, type(BenchERC721).runtimeCode);
            for (uint256 id = 1; id <= 8; id++) {
                BenchERC721(BV.TOKEN).mint(address(h), id);
            }
            vm.deal(address(h), 1 ether);
            vm.warp(c.deadline);
            BV.BatchCase memory other = BV.batchCase((i + 1) % BV.count());
            vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
            h.executeBatch(c.calls, c.tip, c.deadline, other.libSig);
            vm.prank(makeAddr("relayer"));
            h.executeBatch(c.calls, c.tip, c.deadline, c.libSig);
            assertEq(h.nonce(), 1, c.name);
            vm.revertToState(snap);
        }
    }

    function _slice(bytes memory b, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(b.length - from);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[from + i];
        }
    }

    /// The same text and signature on a holder at another address (same code and key, plain CREATE),
    /// and on the holder of another key, are rejected.
    function test_wrong_holder_rejected() public {
        BV.BatchCase memory c = BV.batchCase(1); // p2tr, 2 transfers
        vm.chainId(c.chainId);
        vm.warp(c.deadline);
        B twin = new B(BV.SPK_P2TR);
        assertTrue(address(twin) != BV.HOLDER_P2TR);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        twin.executeBatch(c.calls, c.tip, c.deadline, c.sig);
        B other = deployB(BV.SPK_P2WPKH);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        other.executeBatch(c.calls, c.tip, c.deadline, c.sig);
    }

    // ------------------------------------------------------------------ binding of the calls

    function test_reordering_changes_text_and_invalidates() public {
        B.Call[] memory cs = transfers(3);
        bytes memory s = sign(cs, 0, 0);
        B.Call[] memory sw = transfers(3);
        (sw[0], sw[2]) = (cs[2], cs[0]);
        assertTrue(keccak256(hd.batchMessage(cs, 0, 0, DL)) != keccak256(hd.batchMessage(sw, 0, 0, DL)));
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.executeBatch(sw, 0, DL, s);
        // dropping the last call or appending one also invalidates
        B.Call[] memory shorter = transfers(2);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.executeBatch(shorter, 0, DL, s);
        B.Call[] memory longer = transfers(4);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.executeBatch(longer, 0, DL, s);
        // the original order goes through
        hd.executeBatch(cs, 0, DL, s);
        assertEq(nft.ownerOf(3), address(0xb0));
    }

    /// A signature of a single-call message (§5.2) never authorises a batch and vice versa, and both
    /// kinds draw on the one nonce.
    function test_kinds_do_not_cross_and_share_the_nonce() public {
        B.Call memory c = xfer(1);
        bytes memory callSig = S.signP2WPKH(PRIV, hd.callMessage(c.target, 0, c.data, G, 0, 0, DL));
        bytes memory batchSig = sign(one(c), 0, 0);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.executeBatch(one(c), 0, DL, callSig);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(c.target, 0, c.data, G, 0, DL, batchSig);
        // batch at nonce 0 cancels the pending single call at nonce 0
        hd.executeBatch(one(c), 0, DL, batchSig);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(c.target, 0, c.data, G, 0, DL, callSig);
        // execute keeps working at the next nonce
        B.Call memory c2 = xfer(2);
        hd.execute(
            c2.target, 0, c2.data, G, 0, DL, S.signP2WPKH(PRIV, hd.callMessage(c2.target, 0, c2.data, G, 0, 1, DL))
        );
        assertEq(hd.nonce(), 2);
        assertEq(nft.ownerOf(2), address(0xb0));
    }

    function test_tip_and_deadline_bound() public {
        B.Call[] memory cs = transfers(2);
        bytes memory s = sign(cs, 1 ether, 0);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.executeBatch(cs, 2 ether, DL, s);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.executeBatch(cs, 1 ether, DL - 1, s);
    }

    // ------------------------------------------------------------------ failure semantics

    function test_failing_inner_call_reverts_everything() public {
        B.Call[] memory cs = new B.Call[](3);
        cs[0] = xfer(1);
        cs[1] = B.Call(address(failer), 0, abi.encodeCall(Failer.fail, ()), G);
        cs[2] = xfer(2);
        bytes memory s = sign(cs, 0.1 ether, 0);
        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(B.BatchCallFailed.selector, 1, abi.encodeWithSelector(Failer.Custom.selector, 7))
        );
        hd.executeBatch(cs, 0.1 ether, DL, s);
        assertEq(nft.ownerOf(1), address(hd), "first call undone");
        assertEq(hd.nonce(), 0, "nonce unused");
        assertEq(relayer.balance, 0, "no tip");
    }

    function test_value_shortfall_reverts_everything() public {
        B.Call[] memory cs = new B.Call[](2);
        cs[0] = B.Call(address(0xb1), 6 ether, "", 0);
        cs[1] = B.Call(address(0xb2), 6 ether, "", 0); // holder has 10
        bytes memory s = sign(cs, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(B.BatchCallFailed.selector, 1, ""));
        hd.executeBatch(cs, 0, DL, s);
        assertEq(address(0xb1).balance, 0);
    }

    function test_tip_unaffordable_reverts_everything() public {
        B.Call[] memory cs = new B.Call[](2);
        cs[0] = xfer(1);
        cs[1] = B.Call(address(0xb1), 9 ether, "", 0);
        bytes memory s = sign(cs, 2 ether, 0);
        vm.prank(makeAddr("relayer"));
        vm.expectRevert(BitcoinKeyedHolder.TipFailed.selector);
        hd.executeBatch(cs, 2 ether, DL, s);
        assertEq(nft.ownerOf(1), address(hd));
    }

    /// Final lab (audit F-01): executeBatch returns nothing, whatever the callees return.
    function test_no_return_data() public {
        B.Call[] memory cs = new B.Call[](2);
        cs[0] = B.Call(address(failer), 0, abi.encodeCall(Failer.ok, ()), G);
        cs[1] = xfer(1);
        (bool ok, bytes memory ret) = relay(cs, 0, sign(cs, 0, 0), 5_000_000);
        assertTrue(ok);
        assertEq(ret.length, 0);
        assertEq(nft.ownerOf(1), address(0xb0));
    }

    function bombs(DataBomb bomb, uint256 k, uint256 n, bool reverting, uint256 g) internal pure returns (B.Call[] memory cs) {
        cs = new B.Call[](k);
        for (uint256 i = 0; i < k; i++) {
            cs[i] = B.Call(address(bomb), 0, reverting ? abi.encodeCall(DataBomb.rev, (n)) : abi.encodeCall(DataBomb.ret, (n)), g);
        }
    }

    /// Audit F-01 regression: 8 callees returning 200,000 bytes each cost the holder nothing beyond what
    /// the callees themselves pay inside their callGas (the candidate before this fix used about 37M gas
    /// for this batch, against 186k with empty returns).
    function test_return_bomb_costs_the_holder_nothing() public {
        DataBomb bomb = new DataBomb();
        uint256[2] memory used;
        for (uint256 r = 0; r < 2; r++) {
            uint256 snap = vm.snapshotState();
            B.Call[] memory cs = bombs(bomb, 8, r == 0 ? 0 : 200_000, false, 400_000);
            bytes memory cd = abi.encodeCall(B.executeBatch, (cs, 0, DL, sign(cs, 0, 0)));
            uint256 g = gasleft();
            (bool ok, bytes memory ret) = address(hd).call{gas: 4_000_000}(cd);
            used[r] = g - gasleft();
            assertTrue(ok);
            assertEq(ret.length, 0);
            vm.revertToState(snap);
        }
        emit log_named_uint("executeBatch 8 calls returning 0 bytes, gas", used[0]);
        emit log_named_uint("executeBatch 8 calls returning 200,000 bytes, gas", used[1]);
        // each callee pays about 95,000 for its own 200,000 bytes of memory; the holder adds nothing
        assertLt(used[1] - used[0], 8 * 100_000);
    }

    /// Audit F-02 regression: a callee that reverts with 300,000 bytes still yields the typed error, with
    /// the first 256 bytes of its revert data, and a relayer that gives the signed callGas plus a small
    /// margin gets it (before the fix that relayer got an empty out-of-gas revert).
    function test_revert_bomb_truncated_to_256_bytes() public {
        DataBomb bomb = new DataBomb();
        uint256[6] memory sizes = [uint256(0), 31, 255, 256, 257, 300_000];
        for (uint256 j = 0; j < sizes.length; j++) {
            uint256 snap = vm.snapshotState();
            B.Call[] memory cs = new B.Call[](2);
            cs[0] = xfer(1);
            cs[1] = bombs(bomb, 1, sizes[j], true, 1_000_000)[0];
            (bool ok, bytes memory ret) = relay(cs, 0, sign(cs, 0, 0), 1_450_000); // the signed need plus about 225k
            assertFalse(ok);
            uint256 len = sizes[j] < 256 ? sizes[j] : 256;
            bytes memory first = new bytes(len);
            bytes memory full = abi.encodePacked(
                bytes32(0xdeaddeaddeaddeaddeaddeaddeaddeaddeaddeaddeaddeaddeaddeaddeaddead),
                bytes32(0x0102030405060708091011121314151617181920212223242526272829303132),
                new bytes(256)
            );
            for (uint256 x = 0; x < len; x++) {
                first[x] = full[x];
            }
            assertEq(ret, abi.encodeWithSelector(B.BatchCallFailed.selector, 1, first));
            assertEq(nft.ownerOf(1), address(hd), "first call undone");
            assertEq(hd.nonce(), 0);
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------ size and malformed input

    function test_max_batch_size() public {
        B.Call[] memory cs = transfers(8);
        hd.executeBatch(cs, 0, DL, sign(cs, 0, 0));
        assertEq(nft.ownerOf(8), address(0xb0));
        B.Call[] memory nine = transfers(9);
        vm.expectRevert(B.BadBatch.selector);
        hd.batchMessage(nine, 0, 1, DL);
        vm.expectRevert(B.BadBatch.selector);
        hd.executeBatch(nine, 0, DL, hex"00");
        B.Call[] memory none = new B.Call[](0);
        vm.expectRevert(B.BadBatch.selector);
        hd.batchMessage(none, 0, 1, DL);
        vm.expectRevert(B.BadBatch.selector);
        hd.executeBatch(none, 0, DL, hex"00");
    }

    function test_callGas_cap() public {
        B.Call[] memory cs = transfers(2);
        cs[1].callGas = 1 << 64;
        bytes memory s = sign(cs, 0, 0); // the text renders, but executeBatch refuses before checking it
        vm.expectRevert(B.BadBatch.selector);
        hd.executeBatch(cs, 0, DL, s);
        cs[1].callGas = type(uint256).max;
        vm.expectRevert(B.BadBatch.selector);
        hd.executeBatch(cs, 0, DL, s);
    }

    function test_no_code_target_with_data() public {
        B.Call[] memory cs = transfers(2);
        cs[1] = B.Call(address(0xdead), 0, hex"01", G);
        bytes memory s = sign(cs, 0, 0);
        vm.expectRevert(BitcoinKeyedHolder.NoCode.selector);
        hd.executeBatch(cs, 0, DL, s);
        assertEq(hd.nonce(), 0);
    }

    /// An earlier call may create the target of a later one (here through the deterministic deployment
    /// proxy); the code check is made just before each call.
    function test_earlier_call_creates_later_target() public {
        // init code of a contract whose runtime is: PUSH1 42 PUSH1 0 SSTORE STOP
        bytes memory runtime = hex"602a60005500";
        bytes memory init = abi.encodePacked(hex"65", runtime, hex"6000526006601af3");
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), S.FACTORY, bytes32(0), keccak256(init)))))
        );
        assertEq(predicted.code.length, 0);
        B.Call[] memory cs = new B.Call[](2);
        cs[0] = B.Call(S.FACTORY, 0, abi.encodePacked(bytes32(0), init), 200_000);
        cs[1] = B.Call(predicted, 0, hex"01", 50_000);
        hd.executeBatch(cs, 0, DL, sign(cs, 0, 0));
        assertEq(predicted.code, runtime);
        assertEq(uint256(vm.load(predicted, 0)), 42, "the later call ran in the created contract");
    }

    /// Random calldata after the selector never succeeds and never moves the nonce.
    /// forge-config: default.fuzz.runs = 20000
    function testFuzz_malformed_calldata(bytes calldata junk) public {
        (bool ok,) = address(hd).call(abi.encodePacked(B.executeBatch.selector, junk));
        assertFalse(ok);
        assertEq(hd.nonce(), 0);
    }

    /// Well-formed batches with a random signature are rejected without reverting in any other way.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_random_sig(uint8 k, bytes calldata s, uint256 tip) public {
        k = uint8(bound(k, 1, 8));
        B.Call[] memory cs = transfers(k);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.executeBatch(cs, tip, DL, s);
    }

    // ------------------------------------------------------------------ gas floor

    function probes(Probe p, uint256 k, uint256 g, uint256 value) internal pure returns (B.Call[] memory cs) {
        cs = new B.Call[](k);
        for (uint256 i = 0; i < k; i++) {
            cs[i] = B.Call(address(p), value, abi.encodeCall(Probe.probe, ()), g);
        }
    }

    function minOuterGas(B.Call[] memory cs, bytes memory s) internal returns (uint256 lo) {
        lo = 0;
        uint256 hi = 30_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = relay(cs, 0, s, mid);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
    }

    /// With the least gas that succeeds, every callee receives what a generous relayer gives it, and at
    /// least callGas minus its own dispatch; one gas less fails with InsufficientGas (or out of gas) and
    /// leaves nothing done.
    function test_every_callee_receives_callGas() public {
        for (uint256 v = 0; v < 2; v++) {
            uint256 snap0 = vm.snapshotState();
            Probe p = new Probe();
            uint256 callGas = 300_000;
            B.Call[] memory cs = probes(p, 4, callGas, v);
            bytes memory s = sign(cs, 0, 0);
            uint256 snap = vm.snapshotState();
            (bool ok,) = relay(cs, 0, s, 29_000_000);
            assertTrue(ok);
            uint256[4] memory generous;
            for (uint256 i = 0; i < 4; i++) {
                generous[i] = p.seen(i);
            }
            vm.revertToState(snap);
            uint256 lo = minOuterGas(cs, s);
            snap = vm.snapshotState();
            (bool ok2, bytes memory ret) = relay(cs, 0, s, lo - 1);
            assertFalse(ok2);
            assertTrue(ret.length == 0 || bytes4(ret) == BitcoinKeyedHolder.InsufficientGas.selector);
            assertEq(hd.nonce(), 0);
            assertEq(p.count(), 0, "nothing done");
            vm.revertToState(snap);
            (ok,) = relay(cs, 0, s, lo);
            assertTrue(ok);
            for (uint256 i = 0; i < 4; i++) {
                assertEq(p.seen(i), generous[i], "minimal relayer forwards what a generous one does");
                assertGt(p.seen(i), callGas - 500);
            }
            emit log_named_uint(
                v == 0 ? "min outer gas, 4 x 300k probes" : "min outer gas, 4 x 300k probes with value", lo
            );
            vm.revertToState(snap0);
        }
    }

    /// The up-front check: a relayer that cannot cover the sum of the signed call gas is refused before
    /// the first call, even though the first call alone would fit.
    function test_upfront_sum_check() public {
        Probe p = new Probe();
        B.Call[] memory cs = probes(p, 2, 1_000_000, 0);
        bytes memory s = sign(cs, 0, 0);
        (bool ok, bytes memory ret) = relay(cs, 0, s, 1_500_000);
        assertTrue(revertsWith(ok, ret, BitcoinKeyedHolder.InsufficientGas.selector));
        assertEq(p.count(), 0);
        assertEq(hd.nonce(), 0, "signature not spent");
        (ok,) = relay(cs, 0, s, 2_400_000);
        assertTrue(ok);
        assertEq(p.count(), 2);
    }

    // ------------------------------------------------------------------ tip and reentrancy

    function test_tip_paid_once_to_msg_sender() public {
        B.Call[] memory cs = transfers(5);
        bytes memory s = sign(cs, 0.01 ether, 0);
        address relayer = makeAddr("relayer");
        uint256 holderBefore = address(hd).balance;
        vm.prank(relayer, makeAddr("origin"));
        hd.executeBatch(cs, 0.01 ether, DL, s);
        assertEq(relayer.balance, 0.01 ether);
        assertEq(holderBefore - address(hd).balance, 0.01 ether);
    }

    /// A batched callee re-entering with the same signature is rejected (the nonce has moved), and the
    /// outer batch completes.
    function test_reentrancy_from_callee() public {
        BatchReenterer re = new BatchReenterer();
        B.Call[] memory cs = new B.Call[](2);
        cs[0] = B.Call(address(re), 0, abi.encodeCall(BatchReenterer.poke, ()), 1_000_000);
        cs[1] = xfer(1);
        bytes memory s = sign(cs, 0, 0);
        re.arm(hd, cd(cs, 0, s));
        hd.executeBatch(cs, 0, DL, s);
        assertTrue(re.tried());
        assertEq(re.nonceSeen(), 1, "nonce bumped before the first call");
        assertFalse(re.innerOk());
        assertEq(bytes4(re.innerErr()), BitcoinKeyedHolder.BadSignature.selector);
        assertEq(nft.ownerOf(1), address(0xb0));
        assertEq(hd.nonce(), 1);
    }

    /// A relayer contract re-entering from its receive() with the same signature is rejected; with the
    /// next nonce's signature it succeeds and its events come first (indexers order by nonce).
    function test_reentrancy_from_tip_recipient() public {
        BatchReenterer re = new BatchReenterer();
        B.Call[] memory cs = transfers(2);
        bytes memory s = sign(cs, 0.01 ether, 0);
        re.arm(hd, cd(cs, 0.01 ether, s));
        re.relay(cd(cs, 0.01 ether, s));
        assertTrue(re.tried());
        assertFalse(re.innerOk());
        assertEq(bytes4(re.innerErr()), BitcoinKeyedHolder.BadSignature.selector);
        assertEq(address(re).balance, 0.01 ether, "tip paid once");
        assertEq(hd.nonce(), 1);

        BatchReenterer re2 = new BatchReenterer();
        B.Call[] memory a = one(xfer(3));
        B.Call[] memory b = one(xfer(4));
        bytes memory sa = sign(a, 0.01 ether, 1);
        bytes memory sb = sign(b, 0, 2);
        re2.arm(hd, cd(b, 0, sb));
        vm.expectEmit(true, true, true, true, address(hd));
        emit Called(2, address(nft), 0, keccak256(b[0].data));
        vm.expectEmit(true, true, true, true, address(hd));
        emit Called(1, address(nft), 0, keccak256(a[0].data));
        re2.relay(cd(a, 0.01 ether, sa));
        assertTrue(re2.innerOk());
        assertEq(hd.nonce(), 3);
    }

    function test_executeBatch_not_payable() public {
        B.Call[] memory cs = transfers(1);
        bytes memory s = sign(cs, 0, 0);
        (bool ok, bytes memory ret) = address(hd).call{value: 1}(cd(cs, 0, s));
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    // ------------------------------------------------------------------ P2TR signed in Solidity

    function test_p2tr_batch_signed_here() public {
        uint256 d = 0xC0FFEE;
        bytes32 px = S.trKey(d);
        B t = deployB(S.trSpk(px));
        for (uint256 i = 11; i <= 14; i++) {
            nft.mint(address(t), i);
        }
        B.Call[] memory cs = new B.Call[](4);
        for (uint256 i = 0; i < 4; i++) {
            cs[i] =
                B.Call(address(nft), 0, abi.encodeCall(nft.safeTransferFrom, (address(t), address(0xb0), 11 + i)), G);
        }
        bytes memory m = t.batchMessage(cs, 0, 0, DL);
        t.executeBatch(cs, 0, DL, S.signP2TR(d, m, false));
        assertEq(nft.ownerOf(14), address(0xb0));
        assertEq(t.nonce(), 1);
    }

    // ------------------------------------------------------------------ gas (in-test, warm-ish; see docs for receipts)

    function test_gas_batch_vs_execute() public {
        for (uint256 k = 1; k <= 8; k *= 2) {
            uint256 snap = vm.snapshotState();
            B.Call[] memory cs = transfers(k);
            bytes memory s = sign(cs, 0, 0);
            uint256 g = gasleft();
            hd.executeBatch(cs, 0, DL, s);
            emit log_named_uint(string.concat("executeBatch P2WPKH, transfers: ", vm.toString(k)), g - gasleft());
            vm.revertToState(snap);
        }
    }
}
