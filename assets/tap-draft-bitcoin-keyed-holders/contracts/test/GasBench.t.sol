// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BitcoinKeyedHolder} from "../src/BitcoinKeyedHolder.sol";
import {GeneratedVectors as G} from "./GeneratedVectors.sol";
import {BaselineVectors as V} from "./baseline/BaselineVectors.sol";

/// ERC-721-shaped token for the benchmark: one owner mapping, `safeTransferFrom(from, to, id)`.
contract BenchToken {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && msg.sender == from, "not owner");
        ownerOf[id] = to;
    }
}

/// Gas benchmark of the standard cases (lab only).
/// - "tx" numbers: one CALL from this test contract. forge runs with `isolate = true` (the default of
///   forge 1.8), which executes every top-level CALL from a test as its own transaction: it charges the
///   21,000 base cost and the EIP-2028 calldata cost and starts from a fresh access list. So a "tx"
///   number is the gasUsed of a real transaction (shanghai rules, no EIP-7623 floor).
/// - "static" numbers: a STATICCALL from this contract to a cold holder, as an EIP-1271 verifier
///   contract pays (not isolated: no 21,000 and no calldata cost, includes the 2,600 cold access).
/// - Signature and execute cases use the BASELINE vectors (lab commit 834787a) with the current code
///   installed at the baseline holder addresses (constructor run there, runtime etched), so every
///   version is measured on the same calldata and the same signatures. (With regenerated vectors the
///   holder address changes, and with it the DER length and whether ecrecover needs v=27 or v=28.)
/// - Deploy cases go through the deterministic deployment proxy with the current creation code.
/// Run: forge test --match-contract GasBench -vv
contract GasBench is Test {
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes constant FACTORY_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    function setUp() public {
        vm.etch(FACTORY, FACTORY_RUNTIME);
        vm.chainId(56);
    }

    function init(bytes memory spk) internal pure returns (bytes memory) {
        return abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(spk));
    }

    function deployMeasured(bytes memory spk) internal returns (BitcoinKeyedHolder hd, uint256 used) {
        bytes memory cd = abi.encodePacked(bytes32(0), init(spk));
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = FACTORY.call(cd);
        used = g - gasleft();
        require(ok && ret.length == 20, "factory");
        hd = BitcoinKeyedHolder(payable(address(bytes20(ret))));
    }

    function test_bench_sizes() public {
        bytes memory cc = type(BitcoinKeyedHolder).creationCode;
        emit log_named_uint("creation code bytes", cc.length);
        emit log_named_bytes32("creation code keccak", keccak256(cc));
        (BitcoinKeyedHolder tr,) = deployMeasured(G.SPK_P2TR);
        emit log_named_uint("runtime bytes", address(tr).code.length);
    }

    /// Runs the current creation code at `at` (the baseline holder address for `spk`).
    function installAt(address at, bytes memory spk) internal returns (BitcoinKeyedHolder) {
        vm.etch(at, init(spk));
        (bool ok, bytes memory rt) = at.call("");
        require(ok, "constructor");
        vm.etch(at, rt);
        return BitcoinKeyedHolder(payable(at));
    }

    function test_bench_deploy_p2tr() public {
        (BitcoinKeyedHolder hd, uint256 used) = deployMeasured(G.SPK_P2TR);
        assertEq(address(hd), G.HOLDER_P2TR);
        emit log_named_uint("tx deploy P2TR", used);
    }

    function test_bench_deploy_p2wpkh() public {
        (BitcoinKeyedHolder hd, uint256 used) = deployMeasured(G.SPK_P2WPKH);
        assertEq(address(hd), G.HOLDER_P2WPKH);
        emit log_named_uint("tx deploy P2WPKH", used);
    }

    function isValid(uint256 k, string memory label) internal {
        V.SignCase memory c = V.signCases()[k];
        vm.chainId(c.chainId);
        BitcoinKeyedHolder hd =
            c.holder == 0 ? installAt(V.HOLDER_P2TR, V.SPK_P2TR) : installAt(V.HOLDER_P2WPKH, V.SPK_P2WPKH);
        bytes memory cd = abi.encodeCall(hd.isValidSignature, (c.digest, c.sig));
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = address(hd).call(cd);
        uint256 used = g - gasleft();
        assertTrue(ok && bytes4(ret) == 0x1626ba7e, label);
        emit log_named_uint(string.concat("tx ", label), used);
        vm.cool(address(hd));
        g = gasleft();
        (ok, ret) = address(hd).staticcall(cd);
        used = g - gasleft();
        assertTrue(ok && bytes4(ret) == 0x1626ba7e, label);
        emit log_named_uint(string.concat("static ", label), used);
    }

    function test_bench_isValidSignature_p2tr() public {
        isValid(0, "isValidSignature P2TR");
    }

    function test_bench_isValidSignature_p2wpkh() public {
        isValid(1, "isValidSignature P2WPKH"); // this signature needs ecrecover with v = 28 (two calls)
    }

    function test_bench_isValidSignature_p2tr_sighash_all() public {
        isValid(2, "isValidSignature P2TR SIGHASH_ALL");
    }

    function exec(uint256 k, string memory label) internal {
        V.CallCase memory c = V.callCases()[k];
        vm.chainId(56);
        BitcoinKeyedHolder hd =
            c.holder == 0 ? installAt(V.HOLDER_P2TR, V.SPK_P2TR) : installAt(V.HOLDER_P2WPKH, V.SPK_P2WPKH);
        vm.etch(c.target, type(BenchToken).runtimeCode);
        BenchToken(c.target).mint(address(hd), 1);
        BenchToken(c.target).mint(address(hd), 7);
        vm.deal(address(hd), 1 ether);
        address relayer = makeAddr("relayer");
        vm.deal(relayer, 1 ether);
        vm.warp(c.deadline);
        bytes memory cd = abi.encodeCall(hd.execute, (c.target, c.value, c.data, c.gas, c.tip, c.deadline, c.sig));
        vm.prank(relayer);
        uint256 g = gasleft();
        (bool ok,) = address(hd).call(cd);
        uint256 used = g - gasleft();
        assertTrue(ok, label);
        assertEq(hd.nonce(), 1);
        assertEq(relayer.balance, 1 ether + c.tip);
        emit log_named_uint(string.concat("tx ", label), used);
    }

    function test_bench_execute_erc721_p2tr() public {
        exec(0, "execute ERC-721 transfer P2TR");
    }

    function test_bench_execute_erc721_p2wpkh() public {
        exec(1, "execute ERC-721 transfer P2WPKH");
    }

    function test_bench_execute_erc721_tip_p2wpkh() public {
        exec(3, "execute ERC-721 transfer + tip P2WPKH");
    }
}
