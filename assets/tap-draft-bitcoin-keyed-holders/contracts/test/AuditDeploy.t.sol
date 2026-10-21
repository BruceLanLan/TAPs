// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BitcoinKeyedHolder} from "../src/BitcoinKeyedHolder.sol";
import {BIP340} from "../src/BIP340.sol";
import {Secp256k1Ref as R} from "./Secp256k1Ref.sol";
import {GeneratedVectors as V} from "./GeneratedVectors.sol";
import {HolderExposed, AuditSigner as S} from "./AuditLib.sol";

/// Audit tests for the constructor, the deterministic deployment and ERC-165.
contract AuditDeployTest is Test {
    function setUp() public {
        vm.etch(S.FACTORY, S.factoryCode());
    }

    function tryDeploy(bytes memory spk) internal returns (bool ok, bytes memory ret) {
        bytes memory init = abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(spk));
        (ok, ret) = S.FACTORY.call(abi.encodePacked(bytes32(0), init));
    }

    /// A P2TR output key the constructor accepts: nonzero, below n, and an x-coordinate on the curve
    /// (checked here with the independent reference lift_x).
    function keyValid(bytes32 k) internal view returns (bool) {
        return uint256(k) != 0 && uint256(k) < R.N && !R.liftX(uint256(k)).inf;
    }

    /// Direct construction, so the revert selector is visible (the factory's failure path is opaque).
    function construct(bytes memory spk) internal returns (bool ok, bytes4 sel) {
        bytes memory init = abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(spk));
        address a;
        bytes memory err;
        assembly ("memory-safe") {
            a := create(0, add(init, 0x20), mload(init))
            if iszero(a) {
                err := mload(0x40)
                let sz := returndatasize()
                mstore(err, sz)
                returndatacopy(add(err, 0x20), 0, sz)
                mstore(0x40, add(add(err, 0x20), and(add(sz, 31), not(31))))
            }
        }
        ok = a != address(0);
        if (!ok && err.length >= 4) sel = bytes4(err);
    }

    /// Only the two exact shapes deploy, and a P2TR shape only with a usable output key.
    function testFuzz_constructor_shape(bytes memory spk) public {
        (bool ok,) = tryDeploy(spk);
        bool p2tr = spk.length == 34 && spk[0] == 0x51 && spk[1] == 0x20;
        bool p2wpkh = spk.length == 22 && spk[0] == 0x00 && spk[1] == 0x14;
        bool want = p2wpkh;
        if (p2tr) {
            bytes32 k;
            assembly ("memory-safe") {
                k := mload(add(spk, 0x22))
            }
            want = keyValid(k);
        }
        assertEq(ok, want);
    }

    function testFuzz_constructor_shape_near_miss(bytes32 k, uint8 v, uint8 l) public {
        // 34 bytes with any version/push bytes: only 0x51 0x20 passes, and then only a usable key
        bytes memory spk = abi.encodePacked(v, l, k);
        (bool ok,) = tryDeploy(spk);
        assertEq(ok, v == 0x51 && l == 0x20 && keyValid(k));
        // 22 bytes: only 0x00 0x14 (any key hash)
        spk = abi.encodePacked(v, l, bytes20(k));
        (ok,) = tryDeploy(spk);
        assertEq(ok, v == 0x00 && l == 0x14);
    }

    // ---- I-1, fixed: the constructor only accepts P2TR output keys the verifier can ever accept

    /// A P2TR scriptPubKey whose output key is 32 zero bytes is rejected (it used to be routed to the
    /// P2WPKH verifier with keyHash = 0).
    function test_zero_output_key_reverts() public {
        (bool ok, bytes4 sel) = construct(abi.encodePacked(uint8(0x51), uint8(0x20), bytes32(0)));
        assertFalse(ok);
        assertEq(sel, BitcoinKeyedHolder.UnsupportedScript.selector);
    }

    /// An output key that is not an x-coordinate on the curve is rejected: no black-hole holders.
    function testFuzz_off_curve_output_key_reverts(uint256 x) public {
        x = bound(x, 1, R.P - 1);
        R.Pt memory lifted = R.liftX(x);
        vm.assume(lifted.inf);
        (bool ok, bytes4 sel) = construct(S.trSpk(bytes32(x)));
        assertFalse(ok);
        assertEq(sel, BitcoinKeyedHolder.UnsupportedScript.selector);
    }

    /// An on-curve output key with x in [n, p) is a valid BIP-340 key that BIP340.verifyMsg rejects
    /// (ecrecover takes px as its r argument; documented deviation, probability 2^-128 for a real
    /// wallet). The constructor now rejects it too instead of deploying a holder that can never sign.
    function test_key_in_n_p_range_rejected_by_constructor() public {
        uint256 x = R.N;
        while (R.liftX(x).inf) x++;
        assertTrue(x < R.P);
        (bool ok, bytes4 sel) = construct(S.trSpk(bytes32(x)));
        assertFalse(ok);
        assertEq(sel, BitcoinKeyedHolder.UnsupportedScript.selector);
        // and x = n itself, and x >= p, are rejected whatever the curve says
        (ok, sel) = construct(S.trSpk(bytes32(R.N)));
        assertFalse(ok);
        assertEq(sel, BitcoinKeyedHolder.UnsupportedScript.selector);
        (ok, sel) = construct(S.trSpk(bytes32(type(uint256).max)));
        assertFalse(ok);
        assertEq(sel, BitcoinKeyedHolder.UnsupportedScript.selector);
        // whatever the signature, the verifier's first check rejects px >= n
        assertFalse(BIP340.verifyMsg(bytes32(x), "m", 1, 1));
    }

    /// Random 32-byte output keys deploy iff they are on the curve and below n (about half of them).
    function testFuzz_output_key_deploys_iff_usable(bytes32 k) public {
        (bool ok, bytes4 sel) = construct(S.trSpk(k));
        assertEq(ok, keyValid(k));
        if (!ok) assertEq(sel, BitcoinKeyedHolder.UnsupportedScript.selector);
    }

    /// Keys of real wallets (x of d*G for random d) deploy and route to the P2TR verifier; the
    /// P2WPKH shape routes the other way.
    function testFuzz_real_key_deploys(uint256 d) public {
        d = bound(d, 1, R.N - 1);
        bytes32 px = S.trKey(d);
        vm.assume(uint256(px) < R.N);
        HolderExposed h = new HolderExposed(S.trSpk(px));
        assertTrue(h.routesToP2TR());
        assertEq(h.scriptPubKey(), S.trSpk(px));
        HolderExposed w = new HolderExposed(S.wpSpk(bytes20(px)));
        assertFalse(w.routesToP2TR());
        assertEq(w.keyHashValue(), bytes20(px));
    }

    /// Deployment with value fails: the constructor is not payable and the proxy forwards callvalue.
    function test_deploy_with_value_reverts() public {
        bytes memory init = abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(V.SPK_P2TR));
        vm.deal(address(this), 1 ether);
        (bool ok,) = S.FACTORY.call{value: 1}(abi.encodePacked(bytes32(0), init));
        assertFalse(ok);
    }

    /// The same holder cannot be deployed twice (CREATE2 collision), and no other init code reaches
    /// the canonical address. Address is independent of chain id and deployer.
    function test_address_binding() public {
        vm.chainId(1);
        vm.prank(makeAddr("deployerA"));
        BitcoinKeyedHolder a = S.deploy(V.SPK_P2TR);
        assertEq(address(a), V.HOLDER_P2TR);
        (bool ok,) = tryDeploy(V.SPK_P2TR);
        assertFalse(ok, "redeploy");
        // other salt -> other address, not the canonical one
        bytes memory init = abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(V.SPK_P2TR));
        (bool ok2, bytes memory ret) = S.FACTORY.call(abi.encodePacked(bytes32(uint256(1)), init));
        assertTrue(ok2);
        assertTrue(address(bytes20(ret)) != V.HOLDER_P2TR);
        // the address formula of §4
        bytes32 want = keccak256(abi.encodePacked(bytes1(0xff), S.FACTORY, bytes32(0), keccak256(init)));
        assertEq(address(uint160(uint256(want))), V.HOLDER_P2TR);
    }

    function test_supports_interface() public {
        BitcoinKeyedHolder h = S.deploy(V.SPK_P2TR);
        assertTrue(h.supportsInterface(0x01ffc9a7));
        assertTrue(h.supportsInterface(0x150b7a02));
        assertTrue(h.supportsInterface(0x4e2312e0));
        assertTrue(h.supportsInterface(0x1626ba7e));
        assertFalse(h.supportsInterface(0xffffffff));
        assertFalse(h.supportsInterface(0x80ac58cd)); // not an ERC-721 itself
        // ERC-1155 receiver id is the xor of the two hook selectors
        assertEq(bytes4(0xf23a6e61) ^ bytes4(0xbc197c81), bytes4(0x4e2312e0));
    }

    /// Holder has no selfdestruct / delegatecall / callcode opcodes in its runtime code.
    function test_no_dangerous_opcodes() public {
        BitcoinKeyedHolder h = S.deploy(V.SPK_P2TR);
        bytes memory code = address(h).code;
        // crude scan: opcodes inside PUSH data can false-positive, so only assert on a clean scan
        // after skipping PUSH immediates.
        uint256 i = 0;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            assertTrue(op != 0xff, "SELFDESTRUCT");
            assertTrue(op != 0xf4, "DELEGATECALL");
            assertTrue(op != 0xf2, "CALLCODE");
            assertTrue(op != 0xf0 && op != 0xf5, "CREATE");
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            i++;
        }
    }
}
