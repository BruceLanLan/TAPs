// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BIP340} from "../src/BIP340.sol";
import {BIP322} from "../src/BIP322.sol";
import {BitcoinKeyedHolder} from "../src/BitcoinKeyedHolder.sol";
import {GeneratedVectors as V} from "./GeneratedVectors.sol";

contract Harness {
    function v340(bytes32 px, bytes calldata m, bytes calldata sig) external view returns (bool) {
        if (sig.length != 64) return false;
        return BIP340.verifyMsg(px, m, uint256(bytes32(sig[0:32])), uint256(bytes32(sig[32:64])));
    }

    function v322(bytes calldata spk, bytes calldata m, bytes calldata w) external view returns (bool) {
        if (spk[0] == 0x51) return BIP322.verifyP2TR(bytes32(spk[2:34]), m, w);
        return BIP322.verifyP2WPKH(bytes20(spk[2:22]), m, w);
    }
}

/// A minimal ERC-721 for the call cases.
contract TestToken {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && msg.sender == from, "not owner");
        ownerOf[id] = to;
    }
}

contract HolderTest is Test {
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes constant FACTORY_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    Harness h;

    function setUp() public {
        vm.etch(FACTORY, FACTORY_RUNTIME);
        h = new Harness();
    }

    function deploy(bytes memory spk) internal returns (BitcoinKeyedHolder) {
        bytes memory init = abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(spk));
        (bool ok, bytes memory ret) = FACTORY.call(abi.encodePacked(bytes32(0), init));
        require(ok && ret.length == 20, "factory");
        return BitcoinKeyedHolder(payable(address(bytes20(ret))));
    }

    function holderOf(uint8 i) internal returns (BitcoinKeyedHolder) {
        if (i == 0) return deploy(V.SPK_P2TR);
        if (i == 1) return deploy(V.SPK_P2WPKH);
        return deploy(V.SPK_P2TR_OTHER);
    }

    function test_creation_code_is_pinned() public pure {
        assertEq(keccak256(type(BitcoinKeyedHolder).creationCode), V.CREATION_CODE_KECCAK);
    }

    function test_addresses_are_deterministic() public {
        assertEq(address(deploy(V.SPK_P2TR)), V.HOLDER_P2TR);
        assertEq(address(deploy(V.SPK_P2WPKH)), V.HOLDER_P2WPKH);
        assertEq(address(deploy(V.SPK_P2TR_OTHER)), V.HOLDER_P2TR_OTHER);
        assertEq(BitcoinKeyedHolder(payable(V.HOLDER_P2TR)).scriptPubKey(), V.SPK_P2TR);
    }

    function test_unsupported_scripts_revert() public {
        bytes memory init = abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(hex"0020aaaa"));
        (bool ok,) = FACTORY.call(abi.encodePacked(bytes32(0), init));
        assertFalse(ok);
    }

    function test_sign_cases() public {
        BitcoinKeyedHolder[3] memory hs = [holderOf(0), holderOf(1), holderOf(2)];
        V.SignCase[] memory cs = V.signCases();
        for (uint256 i = 0; i < cs.length; i++) {
            vm.chainId(cs[i].chainId);
            BitcoinKeyedHolder hd = hs[cs[i].holder];
            if (cs[i].expect) assertEq(hd.signMessage(cs[i].digest), cs[i].message, cs[i].name);
            bytes4 got = hd.isValidSignature(cs[i].digest, cs[i].sig);
            assertEq(got == 0x1626ba7e, cs[i].expect, cs[i].name);
            if (!cs[i].expect) assertEq(got, bytes4(0xffffffff), cs[i].name);
        }
    }

    /// Same Bitcoin key, same code, different address (deployed with plain CREATE): the holder address
    /// in the message is what keeps a signature for one holder from being valid for another.
    function test_same_key_other_address_rejected() public {
        V.SignCase memory c = V.signCases()[0]; // p2tr-56, valid for the canonical holder
        vm.chainId(c.chainId);
        assertEq(holderOf(0).isValidSignature(c.digest, c.sig), bytes4(0x1626ba7e));
        BitcoinKeyedHolder twin = new BitcoinKeyedHolder(V.SPK_P2TR);
        assertTrue(address(twin) != V.HOLDER_P2TR);
        assertEq(twin.isValidSignature(c.digest, c.sig), bytes4(0xffffffff));
    }

    function runCall(uint256 k) internal {
        V.CallCase memory c = V.callCases()[k];
        vm.chainId(56);
        BitcoinKeyedHolder hd = holderOf(c.holder);
        vm.etch(c.target, type(TestToken).runtimeCode);
        TestToken(c.target).mint(address(hd), 1);
        assertEq(hd.callMessage(c.target, c.value, c.data, c.gas, c.tip, c.nonce, c.deadline), c.message);
        vm.warp(c.deadline);
        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        hd.execute(c.target, 0, c.data, c.gas, c.tip, c.deadline, c.sig);
        assertEq(TestToken(c.target).ownerOf(1), address(0xb0));
        assertEq(hd.nonce(), 1);
        // the same signature cannot be replayed: the nonce moved on
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(c.target, 0, c.data, c.gas, c.tip, c.deadline, c.sig);
        // and expires
        vm.warp(uint256(c.deadline) + 1);
        vm.expectRevert(BitcoinKeyedHolder.Expired.selector);
        hd.execute(c.target, 0, c.data, c.gas, c.tip, c.deadline, c.sig);
    }

    /// After the token transfer (nonce 0), a plain value transfer to an address without code, with callGas 0.
    function test_call_value_transfer() public {
        runCall(0);
        V.CallCase memory c = V.callCases()[2];
        BitcoinKeyedHolder hd = BitcoinKeyedHolder(payable(V.HOLDER_P2TR)); // deployed by runCall(0)
        vm.deal(address(hd), 2 ether);
        assertEq(hd.callMessage(c.target, c.value, c.data, c.gas, c.tip, c.nonce, c.deadline), c.message);
        vm.warp(c.deadline);
        uint256 before = c.target.balance;
        hd.execute(c.target, c.value, c.data, c.gas, c.tip, c.deadline, c.sig);
        assertEq(c.target.balance - before, c.value);
        assertEq(hd.nonce(), 2);
    }

    function test_constructor_cases() public {
        V.CtorCase[] memory cs = V.ctorCases();
        for (uint256 i = 0; i < cs.length; i++) {
            bytes memory init = abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(cs[i].spk));
            (bool ok,) = FACTORY.call(abi.encodePacked(bytes32(0), init));
            assertEq(ok, cs[i].accept, cs[i].name);
        }
    }

    /// Signatures made by an independent BIP-322 library (bip322-js) for the holders' own messages.
    function test_independent_library_signatures() public {
        V.LibCase[] memory cs = V.libCases();
        assertGt(cs.length, 0);
        for (uint256 i = 0; i < cs.length; i++) {
            assertTrue(h.v322(cs[i].spk, cs[i].message, cs[i].witness), vm.toString(i));
            if (cs[i].chainId != 0) {
                // a "signs" message: the deployed holder rebuilds the same text and accepts the same signature
                vm.chainId(cs[i].chainId);
                bytes memory init = abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(cs[i].spk));
                address at = computeCreate2Address(bytes32(0), keccak256(init), FACTORY);
                if (at.code.length == 0) {
                    (bool ok,) = FACTORY.call(abi.encodePacked(bytes32(0), init));
                    assertTrue(ok);
                }
                BitcoinKeyedHolder hd = BitcoinKeyedHolder(payable(at));
                assertEq(hd.signMessage(cs[i].digest), cs[i].message, vm.toString(i));
                assertEq(hd.isValidSignature(cs[i].digest, cs[i].witness), bytes4(0x1626ba7e), vm.toString(i));
            }
        }
    }

    function test_bip322_upstream_errors() public view {
        V.Bip322Case[] memory cs = V.bip322ErrorCases();
        for (uint256 i = 0; i < cs.length; i++) {
            assertFalse(h.v322(cs[i].spk, cs[i].message, cs[i].witness), vm.toString(i));
        }
    }

    function test_call_p2tr() public {
        runCall(0);
    }

    function test_call_p2wpkh() public {
        runCall(1);
    }

    function test_call_other_chain_rejected() public {
        V.CallCase memory c = V.callCases()[0];
        vm.chainId(8453);
        BitcoinKeyedHolder hd = holderOf(c.holder);
        vm.etch(c.target, type(TestToken).runtimeCode);
        TestToken(c.target).mint(address(hd), 1);
        vm.warp(c.deadline);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(c.target, 0, c.data, c.gas, c.tip, c.deadline, c.sig);
    }

    function test_bip340_upstream() public view {
        V.Bip340Case[] memory cs = V.bip340Cases();
        for (uint256 i = 0; i < cs.length; i++) {
            assertEq(h.v340(cs[i].px, cs[i].message, cs[i].sig), cs[i].expect, vm.toString(cs[i].index));
        }
    }

    function test_bip322_upstream() public view {
        V.Bip322Case[] memory cs = V.bip322Cases();
        for (uint256 i = 0; i < cs.length; i++) {
            assertTrue(h.v322(cs[i].spk, cs[i].message, cs[i].witness), vm.toString(i));
            bytes memory other = abi.encodePacked(cs[i].message, "!");
            assertFalse(h.v322(cs[i].spk, other, cs[i].witness), vm.toString(i));
        }
    }

    function test_gas() public {
        V.SignCase[] memory cs = V.signCases();
        BitcoinKeyedHolder tr = holderOf(0);
        BitcoinKeyedHolder wp = holderOf(1);
        vm.chainId(56);
        uint256 g = gasleft();
        tr.isValidSignature(cs[0].digest, cs[0].sig);
        emit log_named_uint("isValidSignature P2TR (SIGHASH_DEFAULT)", g - gasleft());
        g = gasleft();
        wp.isValidSignature(cs[1].digest, cs[1].sig);
        emit log_named_uint("isValidSignature P2WPKH", g - gasleft());
        g = gasleft();
        tr.isValidSignature(cs[2].digest, cs[2].sig);
        emit log_named_uint("isValidSignature P2TR (SIGHASH_ALL)", g - gasleft());
    }
}
