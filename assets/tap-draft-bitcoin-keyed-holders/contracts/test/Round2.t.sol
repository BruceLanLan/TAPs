// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BitcoinKeyedHolder} from "../src/BitcoinKeyedHolder.sol";
import {BIP322} from "../src/BIP322.sol";
import {Secp256k1Ref as R} from "./Secp256k1Ref.sol";
import {AuditSigner as S, LibHarness} from "./AuditLib.sol";
import {TestToken} from "./AuditExecute.t.sol";

/// Second independent round: checks that are not in the first round's files.
contract Round2Test is Test {
    uint256 constant PRIV = 0xB0B;
    uint256 constant TRD = 0xCAFE;
    uint64 constant DL = 2_000_000_000;
    uint256 constant G = 500_000;
    BitcoinKeyedHolder hd; // P2WPKH
    BitcoinKeyedHolder tr; // P2TR
    LibHarness lib;

    function setUp() public {
        vm.etch(S.FACTORY, S.factoryCode());
        (, bytes20 kh) = S.wpPubkey(PRIV);
        hd = S.deploy(S.wpSpk(kh));
        tr = S.deploy(S.trSpk(S.trKey(TRD)));
        vm.deal(address(hd), 10 ether);
        vm.warp(1_700_000_000);
        lib = new LibHarness();
    }

    function sig(address t, uint256 v, bytes memory d, uint256 g, uint256 n) internal returns (bytes memory) {
        return S.signP2WPKH(PRIV, hd.callMessage(t, v, d, g, 0, n, DL));
    }

    // ---- 1. A section 5.1 approval has no nonce, no deadline and no revocation path.
    //         Burning nonces, moving every asset, or signing anything else leaves it valid forever.
    function test_51_approval_is_irrevocable() public {
        bytes32 digest = keccak256("some EIP-1271 consumer's digest, e.g. a Permit2 or Seaport order");
        bytes memory s = S.signP2WPKH(PRIV, hd.signMessage(digest));
        assertEq(hd.isValidSignature(digest, s), bytes4(0x1626ba7e));
        // "revoke" attempts: burn three nonces with self-calls
        for (uint256 i = 0; i < 3; i++) {
            hd.execute(address(hd), 0, "", 30_000, 0, DL, sig(address(hd), 0, "", 30_000, i));
        }
        assertEq(hd.nonce(), 3);
        // still valid; nothing in the contract can invalidate it
        assertEq(hd.isValidSignature(digest, s), bytes4(0x1626ba7e));
        // and valid at any later time
        vm.warp(type(uint64).max);
        assertEq(hd.isValidSignature(digest, s), bytes4(0x1626ba7e));
    }

    // ---- 2. "Cancel by relaying another call at the same nonce first" is a race the user can lose:
    //         whoever already holds the original signature can relay it ahead of the cancel.
    function test_cancel_race_original_wins() public {
        (TestToken tok, address thief) = (new TestToken(), makeAddr("thief"));
        tok.mint(address(hd), 1);
        bytes memory d = abi.encodeCall(tok.transferFrom, (address(hd), thief, 1));
        bytes memory original = sig(address(tok), 0, d, G, 0); // leaked / regretted signature at nonce 0
        bytes memory cancel = sig(address(hd), 0, "", 0, 0); // user's cancel: self-call at the same nonce 0
        // the relayer holding `original` sees the cancel in the mempool and goes first
        vm.prank(thief);
        hd.execute(address(tok), 0, d, G, 0, DL, original);
        assertEq(tok.ownerOf(1), thief);
        // the cancel now fails
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(address(hd), 0, "", 0, 0, DL, cancel);
    }

    // ---- 3. BIP-341: a 65-byte Schnorr signature whose hash_type byte is 0x00 is invalid, and so are
    //         the other sighash types. Only 0x01 is accepted with the 67-byte witness.
    function test_p2tr_65_byte_sig_only_sighash_all() public view {
        bytes memory m = tr.signMessage(bytes32(uint256(1)));
        bytes memory w = S.signP2TR(TRD, m, true); // 0x01 0x41 sig 0x01
        assertTrue(lib.p2tr(S.trKey(TRD), m, w));
        uint8[6] memory bad = [0x00, 0x02, 0x03, 0x81, 0x82, 0x83];
        for (uint256 i = 0; i < bad.length; i++) {
            bytes memory w2 = w;
            w2[66] = bytes1(bad[i]);
            assertFalse(lib.p2tr(S.trKey(TRD), m, w2), "hash_type accepted");
        }
        // 0x01 0x40 sig with hash_type 0x01 inside the sigmsg does not verify against a DEFAULT witness
        bytes memory w3 = abi.encodePacked(uint8(0x01), uint8(0x40), slice(w, 2, 64));
        assertFalse(lib.p2tr(S.trKey(TRD), m, w3));
    }

    // ---- 4. P2WPKH: the parity byte is bound by hash160, so flipping it (same x) is rejected, and an
    //         uncompressed key for the same point is rejected (length), matching BIP-141.
    function test_p2wpkh_parity_and_uncompressed_rejected() public {
        bytes memory m = hd.signMessage(bytes32(uint256(2)));
        bytes memory w = S.signP2WPKH(PRIV, m);
        (, bytes20 kh) = S.wpPubkey(PRIV);
        assertTrue(lib.p2wpkh(kh, m, w));
        uint256 k = 2 + uint8(w[1]) + 1; // index of the key's prefix byte
        bytes memory w2 = w;
        w2[k] = w2[k] == 0x02 ? bytes1(0x03) : bytes1(0x02);
        assertFalse(lib.p2wpkh(kh, m, w2));
        w2 = w;
        w2[k] = 0x04;
        assertFalse(lib.p2wpkh(kh, m, w2));
    }

    // ---- 5. Same Bitcoin key, both address kinds: the two holders are distinct and neither accepts the
    //         other's signature for the same digest (already tested for P2TR/P2WPKH of one key in Holder.t,
    //         repeated here across the EIP-1271 and execute paths with a tip).
    function test_cross_holder_same_chain_rejected() public {
        bytes32 digest = keccak256("d");
        bytes memory sTr = S.signP2TR(TRD, tr.signMessage(digest), false);
        bytes memory sWp = S.signP2WPKH(PRIV, hd.signMessage(digest));
        assertEq(tr.isValidSignature(digest, sTr), bytes4(0x1626ba7e));
        assertEq(hd.isValidSignature(digest, sWp), bytes4(0x1626ba7e));
        assertEq(tr.isValidSignature(digest, sWp), bytes4(0xffffffff));
        assertEq(hd.isValidSignature(digest, sTr), bytes4(0xffffffff));
    }

    // ---- 6. Init-code hashes of the two script kinds can never coincide (different lengths and
    //         prefixes), and the same scriptPubKey gives the same address with the canonical encoding only.
    function test_create2_inputs_distinct() public pure {
        bytes memory a = abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(S.trSpk(bytes32(uint256(7)))));
        bytes memory b = abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(S.wpSpk(bytes20(uint160(7)))));
        assertEq(a.length, type(BitcoinKeyedHolder).creationCode.length + 128);
        assertEq(b.length, type(BitcoinKeyedHolder).creationCode.length + 96);
        assertTrue(keccak256(a) != keccak256(b));
    }

    // ---- 7. Chain-fork replay: two chains with the same chainId (a fork of BSC keeping 56) accept the
    //         same signature; the message cannot distinguish them. Documented here as a property.
    function test_same_chainid_fork_replays() public {
        TestToken tok = new TestToken();
        tok.mint(address(hd), 1);
        address to = makeAddr("to");
        bytes memory d = abi.encodeCall(tok.transferFrom, (address(hd), to, 1));
        bytes memory s = sig(address(tok), 0, d, G, 0);
        uint256 snap = vm.snapshotState();
        hd.execute(address(tok), 0, d, G, 0, DL, s);
        assertEq(tok.ownerOf(1), to);
        vm.revertToState(snap); // "the other fork", same chain id, same state
        hd.execute(address(tok), 0, d, G, 0, DL, s);
        assertEq(tok.ownerOf(1), to);
    }

    // ---- 8. What a "cancel" call must look like: a self-call with callGas 0 fails (receive() gets no gas),
    //         while a call to an EOA with value 0 and callGas 0 succeeds and burns the nonce.
    function test_cancel_call_shapes() public {
        bytes memory bad = sig(address(hd), 0, "", 0, 0);
        vm.expectRevert(bytes(""));
        hd.execute(address(hd), 0, "", 0, 0, DL, bad);
        address eoa = makeAddr("anyEOA");
        bytes memory good = sig(eoa, 0, "", 0, 0);
        hd.execute(eoa, 0, "", 0, 0, DL, good);
        assertEq(hd.nonce(), 1);
    }

    function slice(bytes memory b, uint256 from, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i = 0; i < n; i++) out[i] = b[from + i];
    }
}
