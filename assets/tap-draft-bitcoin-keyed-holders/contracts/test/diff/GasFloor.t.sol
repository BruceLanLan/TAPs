// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BitcoinKeyedHolder} from "../../src/BitcoinKeyedHolder.sol";
import {BaselineCode} from "../baseline/BaselineCode.sol";
import {DSign} from "./DiffLib.sol";

contract FloorProbe {
    uint256 public seen;

    function probe(bytes calldata) external payable {
        seen = gasleft();
    }
}

/// The gas-floor guarantee of execute (TAP §6.3 step 5: "the callee therefore receives at least
/// callGas"), checked as a property: a relayer that supplies the least outer gas with which execute
/// succeeds must give the callee exactly what a generous relayer gives it. Fuzzed over callGas, value
/// and the size of `data`, for the current source; and measured for the baseline.
contract GasFloorTest is Test {
    uint256 constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    address constant X = 0x5eeD00000000000000000000000000000000B0B1;
    uint64 constant DL = 2_000_000_000;
    FloorProbe p;

    function setUp() public {
        p = new FloorProbe();
        vm.warp(1_800_000_000);
        vm.chainId(56);
    }

    function install(bool baseline, bytes memory spk) internal {
        bytes memory cc = baseline ? BaselineCode.creationCode() : type(BitcoinKeyedHolder).creationCode;
        vm.etch(X, abi.encodePacked(cc, abi.encode(spk)));
        (bool ok, bytes memory rt) = X.call("");
        require(ok, "install");
        vm.etch(X, rt);
    }

    function relay(bytes memory cd, uint256 g) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = X.call{gas: g}(cd);
    }

    /// (gas the callee sees with 30M outer gas, gas it sees with the least outer gas that succeeds)
    function measure(bool baseline, uint256 priv, uint256 callGas, uint256 value, uint256 dataLen)
        internal
        returns (uint256 generous, uint256 minimal, uint256 lo)
    {
        bytes memory spk = DSign.wpSpk(priv);
        install(baseline, spk);
        vm.deal(X, 10 ether);
        bytes memory data = abi.encodeCall(FloorProbe.probe, (new bytes(dataLen)));
        bytes memory m = BitcoinKeyedHolder(payable(X)).callMessage(address(p), value, data, callGas, 0, 0, DL);
        bytes memory sig = DSign.wpSign(priv, m);
        bytes memory cd = abi.encodeCall(BitcoinKeyedHolder.execute, (address(p), value, data, callGas, 0, DL, sig));
        uint256 snap = vm.snapshotState();
        (bool ok,) = relay(cd, 30_000_000);
        require(ok, "generous relay failed");
        generous = p.seen();
        vm.revertToState(snap);
        uint256 hi = 30_000_000;
        lo = 0;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            snap = vm.snapshotState();
            (ok,) = relay(cd, mid);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
        snap = vm.snapshotState();
        (ok,) = relay(cd, lo);
        require(ok, "minimal relay failed");
        minimal = p.seen();
        vm.revertToState(snap);
    }

    /// Current source: at the minimum outer gas the callee sees exactly what it sees with 30M.
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_floor_minimal_relayer_forwards_callGas(uint256 priv, uint256 callGas, bool withValue, uint256 dataLen)
        public
    {
        priv = DSign.bound(priv, 1, N - 1);
        callGas = DSign.bound(callGas, 30_000, 3_000_000); // the probe writes a fresh storage slot
        dataLen = DSign.bound(dataLen, 0, 24_000);
        (uint256 generous, uint256 minimal,) = measure(false, priv, callGas, withValue ? 1 : 0, dataLen);
        assertEq(minimal, generous, "a minimal relayer forwards less than a generous one");
    }

    /// Baseline vs current: the shortfall (generous - minimal) of the callee's gas, by size of data.
    function test_floor_shortfall_by_data_size() public {
        uint256[6] memory sizes = [uint256(0), 1_000, 4_000, 8_000, 16_000, 24_000];
        for (uint256 b = 0; b < 2; b++) {
            for (uint256 i = 0; i < sizes.length; i++) {
                uint256 snap = vm.snapshotState();
                (uint256 g, uint256 mn, uint256 lo) = measure(b == 0, 0xB0B, 1_000_000, 0, sizes[i]);
                vm.revertToState(snap);
                emit log_named_uint(string.concat(b == 0 ? "baseline" : "current", " data bytes"), sizes[i]);
                emit log_named_uint("  min outer gas", lo);
                emit log_named_uint("  callee shortfall at the minimum", g - mn);
            }
        }
    }
}
