// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BIP340} from "../src/BIP340.sol";
import {Secp256k1Ref as R} from "./Secp256k1Ref.sol";
import {GeneratedVectors as V} from "./GeneratedVectors.sol";

/// Audit tests for BIP340.sol: differential fuzz against a pure-Solidity reference and hand-built
/// edge cases (px >= n, px off-curve, r >= p, s = 0, r off-curve, odd-y R, wrong recovery parity).
contract Audit340Test is Test {
    uint256 constant P = R.P;
    uint256 constant N = R.N;

    // --------------------------------------------------------------- the reference itself is checked first

    function test_ref_matches_upstream_vectors() public view {
        V.Bip340Case[] memory cs = V.bip340Cases();
        for (uint256 i = 0; i < cs.length; i++) {
            bool got = false;
            if (cs[i].sig.length == 64) {
                bytes memory sig = cs[i].sig;
                uint256 r;
                uint256 s;
                assembly {
                    r := mload(add(sig, 0x20))
                    s := mload(add(sig, 0x40))
                }
                got = R.verify(cs[i].px, cs[i].message, r, s);
            }
            assertEq(got, cs[i].expect, vm.toString(cs[i].index));
        }
    }

    function test_ref_sign_verify_roundtrip() public view {
        (bytes32 px, uint256 r, uint256 s) = R.sign(12345, "hello", bytes32(uint256(1)), true);
        assertTrue(R.verify(px, "hello", r, s));
        assertTrue(BIP340.verifyMsg(px, "hello", r, s));
    }

    // --------------------------------------------------------------- differential fuzz

    /// Valid signatures from random keys over random messages: the ecrecover construction accepts all.
    function testFuzz_valid_sig_accepted(uint256 d, bytes memory m, bytes32 aux) public view {
        d = bound(d, 1, N - 1);
        (bytes32 px, uint256 r, uint256 s) = R.sign(d, m, aux, true);
        assertTrue(R.verify(px, m, r, s), "ref");
        // The lib rejects px >= n (documented); such keys occur with probability 2^-128.
        if (uint256(px) >= N) return;
        assertTrue(BIP340.verifyMsg(px, m, r, s), "lib");
    }

    /// One-bit changes to any of (r, s, m, px) must be rejected by both.
    function testFuzz_mutated_sig_rejected(uint256 d, bytes memory m, bytes32 aux, uint8 which, uint8 bit) public view {
        d = bound(d, 1, N - 1);
        vm.assume(m.length > 0);
        (bytes32 px, uint256 r, uint256 s) = R.sign(d, m, aux, true);
        which = which % 4;
        if (which == 0) r ^= (uint256(1) << bit);
        else if (which == 1) s ^= (uint256(1) << bit);
        else if (which == 2) px = bytes32(uint256(px) ^ (uint256(1) << bit));
        else m[0] = bytes1(uint8(m[0]) ^ uint8(1 << (bit % 8)));
        bool ref = R.verify(px, m, r, s);
        bool lib = BIP340.verifyMsg(px, m, r, s);
        if (uint256(px) >= N) {
            assertFalse(lib, "lib rejects px >= n");
        } else {
            assertEq(lib, ref, "differential");
        }
        assertFalse(lib, "mutation accepted");
    }

    /// Random (px, m, r, s): lib == ref except in the documented px >= n range.
    function testFuzz_random_inputs_agree(bytes32 px, bytes memory m, uint256 r, uint256 s) public view {
        bool ref = R.verify(px, m, r, s);
        bool lib = BIP340.verifyMsg(px, m, r, s);
        if (uint256(px) >= N) assertFalse(lib);
        else assertEq(lib, ref);
    }

    /// Odd-y R (the signer skipped the k negation): BIP-340 requires rejection; the lib must agree.
    function testFuzz_odd_y_R_rejected(uint256 d, bytes memory m, bytes32 aux) public view {
        d = bound(d, 1, N - 1);
        (bytes32 px, uint256 r, uint256 s) = R.sign(d, m, aux, false);
        assertFalse(R.verify(px, m, r, s), "ref must reject odd R");
        assertFalse(BIP340.verifyMsg(px, m, r, s), "lib must reject odd R");
        // and the same (r, s) with the even-y lift is not valid either: s*G - e*P has odd y
    }

    /// Signature over m is never valid for a different m'.
    function testFuzz_sig_bound_to_message(uint256 d, bytes memory m, bytes memory m2, bytes32 aux) public view {
        d = bound(d, 1, N - 1);
        vm.assume(keccak256(m) != keccak256(m2));
        (bytes32 px, uint256 r, uint256 s) = R.sign(d, m, aux, true);
        assertFalse(BIP340.verifyMsg(px, m2, r, s));
    }

    /// Signature by key d is never valid for a different key.
    function testFuzz_sig_bound_to_key(uint256 d, uint256 d2, bytes memory m, bytes32 aux) public view {
        d = bound(d, 1, N - 1);
        d2 = bound(d2, 1, N - 1);
        vm.assume(d != d2 && d != N - d2);
        (, uint256 r, uint256 s) = R.sign(d, m, aux, true);
        R.Pt memory pk2 = R.mulG(d2);
        assertFalse(BIP340.verifyMsg(bytes32(pk2.x), m, r, s));
    }

    // --------------------------------------------------------------- edge cases

    function test_edge_s_zero_and_bounds() public view {
        (bytes32 px, uint256 r, uint256 s) = R.sign(777, "m", 0, true);
        assertTrue(BIP340.verifyMsg(px, "m", r, s));
        assertFalse(BIP340.verifyMsg(px, "m", r, 0), "s=0");
        assertFalse(BIP340.verifyMsg(px, "m", r, N), "s=n");
        assertFalse(BIP340.verifyMsg(px, "m", r, type(uint256).max), "s=max");
        assertFalse(BIP340.verifyMsg(px, "m", type(uint256).max, s), "r=max (>= p)");
        assertFalse(BIP340.verifyMsg(px, "m", P, s), "r=p");
        assertFalse(BIP340.verifyMsg(px, "m", 0, s), "r=0 (not on curve)");
        assertFalse(BIP340.verifyMsg(bytes32(0), "m", r, s), "px=0");
        assertFalse(BIP340.verifyMsg(bytes32(N), "m", r, s), "px=n");
        assertFalse(BIP340.verifyMsg(bytes32(P), "m", r, s), "px=p");
        assertFalse(BIP340.verifyMsg(bytes32(type(uint256).max), "m", r, s), "px=max");
    }

    /// px below n but not an x-coordinate on the curve: ecrecover returns 0, lib returns false, no revert.
    function testFuzz_px_off_curve(uint256 px, uint256 r, uint256 s) public view {
        px = bound(px, 1, N - 1);
        R.Pt memory lifted = R.liftX(px);
        vm.assume(lifted.inf);
        assertFalse(BIP340.verifyMsg(bytes32(px), "m", r, s));
    }

    /// r not on the curve (fuzzed): rejected, never reverts.
    function testFuzz_r_off_curve(uint256 r) public view {
        r = bound(r, 0, P - 1);
        R.Pt memory lifted = R.liftX(r);
        vm.assume(lifted.inf);
        (bytes32 px,, uint256 s) = R.sign(999, "m", 0, true);
        assertFalse(BIP340.verifyMsg(px, "m", r, s));
    }

    /// The construction relies on v = 27 meaning "even y" in ecrecover. With 28 a valid signature fails.
    function test_parity_assumption() public view {
        (bytes32 px, uint256 r, uint256 s) = R.sign(4242, "parity", 0, true);
        uint256 pxi = uint256(px);
        uint256 e =
            uint256(sha256(abi.encodePacked(BIP340.TAG_CHALLENGE, BIP340.TAG_CHALLENGE, bytes32(r), px, "parity"))) % N;
        uint256 ss = N - mulmod(e, pxi, N);
        uint256 hh = mulmod(s, pxi, N);
        hh = hh == 0 ? 0 : N - hh;
        R.Pt memory Rp = R.liftX(r);
        address want = address(uint160(uint256(keccak256(abi.encode(Rp.x, Rp.y)))));
        assertEq(ecrecover(bytes32(hh), 27, px, bytes32(ss)), want, "v=27 recovers R");
        assertTrue(ecrecover(bytes32(hh), 28, px, bytes32(ss)) != want, "v=28 must not");
        // and ecrecover indeed recovers s*G - e*P
        R.Pt memory q = R.add(R.mulG(s), R.mul(R.liftX(pxi), N - e));
        assertEq(address(uint160(uint256(keccak256(abi.encode(q.x, q.y))))), want);
    }

    /// Never reverts for any input (pure robustness, cheap).
    function testFuzz_never_reverts(bytes32 px, bytes memory m, uint256 r, uint256 s) public view {
        BIP340.verifyMsg(px, m, r, s);
        BIP340.liftXEven(r);
    }
}
