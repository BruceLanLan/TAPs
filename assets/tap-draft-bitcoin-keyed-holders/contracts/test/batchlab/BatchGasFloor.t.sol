// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BitcoinKeyedHolder as B} from "../../src/BitcoinKeyedHolder.sol";
import {DSign} from "../diff/DiffLib.sol";
import {BatchLabCode} from "./BatchLabCode.sol";

contract BatchFloorProbe {
    mapping(uint256 => uint256) public seen;

    /// Records the gas it receives; with `burn`, then uses up all but about 5,000 of it, so that the gas left
    /// for later calls of a batch is what the per-call check sees, not what the up-front check saw.
    function probe(uint256 i, bool burn, bytes calldata) external payable {
        seen[i] = gasleft();
        if (burn) {
            while (gasleft() > 5_000) {}
        }
    }
}

/// The gas-floor guarantee of executeBatch (TAP §6.4: each callee receives at least its callGas), as a
/// property: a relayer that supplies the least outer gas with which the batch succeeds must give every
/// callee exactly what a generous relayer gives it. The batch lab's candidate copied each call's data to
/// memory after the per-call check (the flaw that the gas lab's O5 fixed in execute); the merged contract
/// copies every call's data before any check. Measured for both, by size of data; fuzzed for the merged one.
contract BatchGasFloorTest is Test {
    address constant X = 0x5eeD00000000000000000000000000000000B0B1;
    uint64 constant DL = 2_000_000_000;
    BatchFloorProbe p;

    function setUp() public {
        p = new BatchFloorProbe();
        vm.warp(1_800_000_000);
        vm.chainId(56);
    }

    function install(bool lab, bytes memory spk) internal {
        bytes memory cc = lab ? BatchLabCode.creationCode() : type(B).creationCode;
        vm.etch(X, abi.encodePacked(cc, abi.encode(spk)));
        (bool ok, bytes memory rt) = X.call("");
        require(ok, "install");
        vm.etch(X, rt);
    }

    function calls(uint256 k, uint256 callGas, uint256 value, uint256 dataLen, bool burn)
        internal
        view
        returns (B.Call[] memory cs)
    {
        cs = new B.Call[](k);
        for (uint256 i = 0; i < k; i++) {
            cs[i] = B.Call(address(p), value, abi.encodeCall(BatchFloorProbe.probe, (i, burn, new bytes(dataLen))), callGas);
        }
    }

    /// For each call: (gas its callee sees with 30M outer gas, gas it sees with the least outer gas that
    /// succeeds); and that least outer gas.
    function measure(bool lab, uint256 priv, uint256 k, uint256 callGas, uint256 value, uint256 dataLen, bool burn)
        internal
        returns (uint256[] memory generous, uint256[] memory minimal, uint256 lo)
    {
        bytes memory spk = DSign.wpSpk(priv);
        install(lab, spk);
        vm.deal(X, 10 ether);
        B.Call[] memory cs = calls(k, callGas, value, dataLen, burn);
        bytes memory sig = DSign.wpSign(priv, B(payable(X)).batchMessage(cs, 0, 0, DL));
        bytes memory cd = abi.encodeCall(B.executeBatch, (cs, 0, DL, sig));
        generous = new uint256[](k);
        minimal = new uint256[](k);
        uint256 snap = vm.snapshotState();
        (bool ok,) = X.call{gas: 30_000_000}(cd);
        require(ok, "generous relay failed");
        for (uint256 i = 0; i < k; i++) {
            generous[i] = p.seen(i);
        }
        vm.revertToState(snap);
        uint256 hi = 30_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            snap = vm.snapshotState();
            (ok,) = X.call{gas: mid}(cd);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
        snap = vm.snapshotState();
        (ok,) = X.call{gas: lo}(cd);
        require(ok, "minimal relay failed");
        for (uint256 i = 0; i < k; i++) {
            minimal[i] = p.seen(i);
        }
        vm.revertToState(snap);
    }

    function shortfall(uint256[] memory g, uint256[] memory m) internal pure returns (uint256 worst) {
        for (uint256 i = 0; i < g.length; i++) {
            if (g[i] - m[i] > worst) worst = g[i] - m[i];
        }
    }

    /// Merged contract: at the minimum outer gas every callee sees exactly what it sees with 30M.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_batch_floor_minimal_relayer_forwards_callGas(
        uint256 priv,
        uint256 k,
        uint256 callGas,
        bool withValue,
        uint256 dataLen,
        bool burn
    ) public {
        priv = bound(priv, 1, 1e70);
        k = bound(k, 1, 4);
        callGas = bound(callGas, 30_000, 1_000_000);
        dataLen = bound(dataLen, 0, 24_000);
        (uint256[] memory g, uint256[] memory m,) = measure(false, priv, k, callGas, withValue ? 1 : 0, dataLen, burn);
        assertEq(shortfall(g, m), 0, "a minimal relayer forwards less than a generous one");
    }

    /// Batch lab vs merged: the largest shortfall of a callee's gas at the minimum outer gas, by size of
    /// each call's data (callGas 1,000,000, value 0): one call; and four calls whose callees use up their
    /// gas. The merged contract must show none.
    function test_batch_floor_shortfall_by_data_size() public {
        uint256[6] memory sizes = [uint256(0), 1_000, 4_000, 8_000, 16_000, 24_000];
        for (uint256 shape = 0; shape < 2; shape++) {
            uint256 k = shape == 0 ? 1 : 4;
            for (uint256 lab = 0; lab < 2; lab++) {
                for (uint256 i = 0; i < sizes.length; i++) {
                    uint256 snap = vm.snapshotState();
                    (uint256[] memory g, uint256[] memory m, uint256 lo) =
                        measure(lab == 0, 0xB0B, k, 1_000_000, 0, sizes[i], shape == 1);
                    vm.revertToState(snap);
                    uint256 sf = shortfall(g, m);
                    emit log_named_string(
                        "case", string.concat(lab == 0 ? "batch lab, " : "merged, ", shape == 0 ? "1 call" : "4 burning calls")
                    );
                    emit log_named_uint("  data bytes per call", sizes[i]);
                    emit log_named_uint("  min outer gas", lo);
                    emit log_named_uint("  worst callee shortfall at the minimum", sf);
                    if (lab == 1) assertEq(sf, 0, "merged contract: shortfall");
                }
            }
        }
    }
}
