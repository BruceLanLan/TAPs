// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BitcoinKeyedHolder as B} from "../../src/BitcoinKeyedHolder.sol";
import {AuditSigner as S} from "../AuditLib.sol";
import {GeneratedTextCorpus as TC} from "./GeneratedTextCorpus.sol";

/// Audit F-04: signatures of texts that Python wrote (tools/make_text_corpus.py), not the contract's own
/// views. Each signature must get past the signature check of isValidSignature, execute or executeBatch
/// (and an executable case must succeed), and the same signature with one signed number changed must give
/// BadSignature. Covers 1 to 8 calls and edge values: 0, 1, 9, 10, 2^64 - 1, 2^256 - 1, addresses with
/// leading zeros, chain IDs 1, 56 and 2^64 - 1, nonces up to 2^256 - 2. Only after that does the test also
/// compare the views' text with Python's, as a second check.
contract TextCorpusTest is Test {
    function setUp() public {
        vm.etch(S.FACTORY, S.factoryCode());
    }

    function holder(uint8 k) internal returns (B h) {
        bytes memory spk = k == 0 ? TC.SPK_P2TR : TC.SPK_P2WPKH;
        (bool ok, bytes memory ret) =
            S.FACTORY.call(abi.encodePacked(bytes32(0), type(B).creationCode, abi.encode(spk)));
        require(ok && ret.length == 20, "factory");
        h = B(payable(address(bytes20(ret))));
        assertEq(address(h), k == 0 ? TC.HOLDER_P2TR : TC.HOLDER_P2WPKH, "holder address");
        vm.deal(address(h), 10 ether);
    }

    function prepare(uint8 k, uint256 chainId, uint256 nonce_, uint64 deadline) internal returns (B h) {
        vm.chainId(chainId);
        h = holder(k);
        vm.store(address(h), bytes32(0), bytes32(nonce_)); // the nonce slot
        assertEq(h.nonce(), nonce_);
        vm.warp(deadline);
    }

    function sel(bytes memory r) internal pure returns (bytes4 s) {
        if (r.length >= 4) s = bytes4(r);
    }

    function test_corpus_size() public pure {
        assertEq(TC.CREATION_CODE_KECCAK, keccak256(type(B).creationCode));
        assertEq(TC.batchCount(), 48);
        assertEq(TC.callCount(), 24);
        assertEq(TC.signCount(), 8);
    }

    function test_corpus_batches() public {
        for (uint256 i = 0; i < TC.batchCount(); i++) {
            TC.BatchCase memory c = TC.batchCase(i);
            uint256 snap = vm.snapshotState();
            B h = prepare(c.holder, c.chainId, c.nonce, c.deadline);
            address relayer = makeAddr("relayer");
            vm.prank(relayer);
            (bool ok, bytes memory ret) =
                address(h).call{gas: 30_000_000}(abi.encodeCall(B.executeBatch, (c.calls, c.tip, c.deadline, c.sig)));
            assertTrue(sel(ret) != B.BadSignature.selector, string.concat("batch ", vm.toString(i), ": signature refused"));
            if (c.executable) {
                assertTrue(ok, string.concat("batch ", vm.toString(i), ": executable"));
                assertEq(h.nonce(), c.nonce + 1);
                assertEq(relayer.balance, c.tip);
            }
            vm.revertToState(snap);
            // one signed number changed: refused
            snap = vm.snapshotState();
            h = prepare(c.holder, c.chainId, c.nonce, c.deadline);
            B.Call[] memory cs = c.calls;
            uint256 j = i % cs.length;
            if (i % 3 == 0) cs[j].value ^= 1;
            else if (i % 3 == 1) cs[j].callGas = cs[j].callGas == 0 ? 1 : cs[j].callGas - 1;
            else cs[j].target = address(uint160(cs[j].target) ^ 1);
            vm.expectRevert(B.BadSignature.selector);
            h.executeBatch(cs, c.tip, c.deadline, c.sig);
            vm.revertToState(snap);
            // the views agree with Python (second check)
            snap = vm.snapshotState();
            h = prepare(c.holder, c.chainId, c.nonce, c.deadline);
            assertEq(h.batchMessage(TC.batchCase(i).calls, c.tip, c.nonce, c.deadline), c.message);
            vm.revertToState(snap);
        }
    }

    function test_corpus_calls() public {
        for (uint256 i = 0; i < TC.callCount(); i++) {
            TC.CallCase memory c = TC.callCase(i);
            B.Call memory x = c.call;
            uint256 snap = vm.snapshotState();
            B h = prepare(c.holder, c.chainId, c.nonce, c.deadline);
            (bool ok, bytes memory ret) = address(h).call{gas: 30_000_000}(
                abi.encodeCall(B.execute, (x.target, x.value, x.data, x.callGas, c.tip, c.deadline, c.sig))
            );
            assertTrue(sel(ret) != B.BadSignature.selector, string.concat("call ", vm.toString(i), ": signature refused"));
            if (c.executable) assertTrue(ok, string.concat("call ", vm.toString(i), ": executable"));
            vm.revertToState(snap);
            snap = vm.snapshotState();
            h = prepare(c.holder, c.chainId, c.nonce, c.deadline);
            vm.expectRevert(B.BadSignature.selector);
            h.execute(x.target, x.value, x.data, x.callGas, c.tip ^ 1, c.deadline, c.sig);
            assertEq(h.callMessage(x.target, x.value, x.data, x.callGas, c.tip, c.nonce, c.deadline), c.message);
            vm.revertToState(snap);
        }
    }

    function test_corpus_signs() public {
        for (uint256 i = 0; i < TC.signCount(); i++) {
            TC.SignCase memory c = TC.signCase(i);
            uint256 snap = vm.snapshotState();
            vm.chainId(c.chainId);
            B h = holder(c.holder);
            assertEq(h.isValidSignature(c.digest, c.sig), bytes4(0x1626ba7e));
            assertEq(h.isValidSignature(c.digest ^ bytes32(uint256(1)), c.sig), bytes4(0xffffffff));
            assertEq(h.signMessage(c.digest), c.message);
            vm.revertToState(snap);
        }
    }
}
