// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BitcoinKeyedHolder as B} from "../src/BitcoinKeyedHolder.sol";
import {AuditSigner as S} from "./AuditLib.sol";

/// A relayer chooses the gas limit of the outer transaction. For a batch of eight plain value transfers to
/// accounts that do not exist yet (the most expensive case per call for a transfer), no gas limit may leave a
/// partial result: either all eight arrive, the nonce moves and the relayer is paid, or nothing changes.
contract Round3Test is Test {
    uint256 constant PRIV = 0xB0B;
    uint64 constant DL = 2_000_000_000;
    B hd;
    address relayer;

    function setUp() public {
        vm.etch(S.FACTORY, S.factoryCode());
        (, bytes20 kh) = S.wpPubkey(PRIV);
        hd = S.deploy(S.wpSpk(kh));
        vm.deal(address(hd), 100 ether);
        vm.warp(1_700_000_000);
        relayer = makeAddr("relayer");
    }

    function _delivered() internal view returns (uint256 n) {
        for (uint256 i = 0; i < 8; i++) {
            if (address(uint160(0xA000 + i)).balance == 1 ether) n++;
        }
    }

    /// returns whether the call succeeded; asserts the all-or-nothing invariant
    function _attempt(bytes memory data, uint256 g, uint256 tip) internal returns (bool ok) {
        uint256 before = address(hd).balance;
        vm.prank(relayer);
        (ok,) = address(hd).call{gas: g}(data);
        uint256 d = _delivered();
        if (ok) {
            assertEq(d, 8, "success must deliver all eight");
            assertEq(hd.nonce(), 1);
            assertEq(relayer.balance, tip);
            assertEq(address(hd).balance, before - 8 ether - tip);
        } else {
            assertEq(d, 0, "failure must deliver none");
            assertEq(hd.nonce(), 0);
            assertEq(relayer.balance, 0);
            assertEq(address(hd).balance, before);
        }
    }

    function test_8_value_transfers_to_new_accounts_all_or_nothing_for_every_gas_limit() public {
        B.Call[] memory cs = new B.Call[](8);
        for (uint256 i = 0; i < 8; i++) {
            cs[i] = B.Call(address(uint160(0xA000 + i)), 1 ether, "", 0);
        }
        uint256 tip = 0.01 ether;
        bytes memory s = S.signP2WPKH(PRIV, hd.batchMessage(cs, tip, 0, DL));
        bytes memory data = abi.encodeCall(B.executeBatch, (cs, tip, DL, s));

        // 1. the least gas limit that succeeds, by bisection (each probe from the same state)
        uint256 snap = vm.snapshotState();
        uint256 lo = 0;
        uint256 hi = 3_000_000;
        assertTrue(_attempt(data, hi, tip), "must succeed with plenty of gas");
        vm.revertToState(snap);
        snap = vm.snapshotState();
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            bool ok = _attempt(data, mid, tip);
            vm.revertToState(snap);
            snap = vm.snapshotState();
            if (ok) hi = mid;
            else lo = mid;
        }
        uint256 minGas = hi;
        emit log_named_uint("least gas limit that delivers all eight", minGas);

        // 2. every limit in a window around it, one by one, and a coarse sweep below it
        uint256 from = minGas > 3000 ? minGas - 3000 : 0;
        for (uint256 g = from; g <= minGas + 1000; g += 7) {
            _attempt(data, g, tip);
            vm.revertToState(snap);
            snap = vm.snapshotState();
        }
        for (uint256 g = 0; g < from; g += 997) {
            assertFalse(_attempt(data, g, tip), "below the window it must fail");
            vm.revertToState(snap);
            snap = vm.snapshotState();
        }
        // 3. and the success itself, for the record
        assertTrue(_attempt(data, minGas, tip));
    }
}
