// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BIP322} from "../src/BIP322.sol";
import {BitcoinKeyedHolder} from "../src/BitcoinKeyedHolder.sol";
import {Secp256k1Ref as R} from "./Secp256k1Ref.sol";
import {GeneratedVectors as V} from "./GeneratedVectors.sol";
import {LibHarness, AuditSigner as S} from "./AuditLib.sol";

/// Audit tests for BIP322.sol and isValidSignature: random-key round trips for both address kinds,
/// DER/witness parser robustness (never reverts), mutation rejection, EIP-1271 edge cases.
contract Audit322Test is Test {
    uint256 constant N = R.N;
    LibHarness h;

    function setUp() public {
        vm.etch(S.FACTORY, S.factoryCode());
        h = new LibHarness();
    }

    // ----------------------------------------------------------------- P2WPKH round trips (random keys)

    function testFuzz_p2wpkh_roundtrip(uint256 priv, bytes memory m) public {
        priv = bound(priv, 1, N - 1);
        (, bytes20 kh) = S.wpPubkey(priv);
        bytes memory w = S.signP2WPKH(priv, m);
        assertTrue(h.p2wpkh(kh, m, w), "valid");
        assertFalse(h.p2wpkh(kh, abi.encodePacked(m, "x"), w), "other message");
        // another key hash
        assertFalse(h.p2wpkh(bytes20(uint160(kh) ^ 1), m, w), "other key hash");
    }

    /// Any single-byte change to a valid P2WPKH witness is rejected and never reverts.
    function testFuzz_p2wpkh_byteflip_rejected(uint256 priv, bytes memory m, uint256 idx, uint8 x) public {
        priv = bound(priv, 1, N - 1);
        vm.assume(x != 0);
        (, bytes20 kh) = S.wpPubkey(priv);
        bytes memory w = S.signP2WPKH(priv, m);
        idx = idx % w.length;
        w[idx] = bytes1(uint8(w[idx]) ^ x);
        assertFalse(h.p2wpkh(kh, m, w), "flip accepted");
    }

    /// High s (s' = n - s) and the same r: rejected (low-s rule), as are s = 0 and s = n.
    function testFuzz_p2wpkh_high_s_rejected(uint256 priv, bytes memory m) public {
        priv = bound(priv, 1, N - 1);
        (uint256 r, uint256 s, bytes memory pub) = S.signP2WPKHRaw(priv, m);
        bytes20 kh = R.hash160(pub);
        assertTrue(h.p2wpkh(kh, m, wrap(R.der(r, s), pub)), "low s ok");
        assertFalse(h.p2wpkh(kh, m, wrap(R.der(r, N - s), pub)), "high s");
        assertFalse(h.p2wpkh(kh, m, wrap(R.der(r, 0), pub)), "s=0");
        assertFalse(h.p2wpkh(kh, m, wrap(R.der(0, s), pub)), "r=0");
        assertFalse(h.p2wpkh(kh, m, wrap(R.der(r, N), pub)), "s=n");
    }

    /// Non-strict DER encodings of a valid signature: all rejected, none revert.
    function testFuzz_p2wpkh_nonstrict_der_rejected(uint256 priv, bytes memory m) public {
        priv = bound(priv, 1, N - 1);
        (uint256 r, uint256 s, bytes memory pub) = S.signP2WPKHRaw(priv, m);
        bytes20 kh = R.hash160(pub);
        bytes memory ri = R.derInt(r);
        bytes memory si = R.derInt(s);
        // 1. extra leading zero on r (non-minimal)
        bytes memory ri2 = abi.encodePacked(uint8(0x02), uint8(ri.length - 1), uint8(0x00), slice(ri, 2, ri.length));
        assertFalse(h.p2wpkh(kh, m, wrap(seq(ri2, si), pub)), "leading zero r");
        // 2. extra leading zero on s
        bytes memory si2 = abi.encodePacked(uint8(0x02), uint8(si.length - 1), uint8(0x00), slice(si, 2, si.length));
        assertFalse(h.p2wpkh(kh, m, wrap(seq(ri, si2), pub)), "leading zero s");
        // 3. trailing garbage after s inside the sequence (length claims it)
        assertFalse(h.p2wpkh(kh, m, wrap(seq(ri, abi.encodePacked(si, uint8(0))), pub)), "trailing byte");
        // 4. sequence length off by one
        bytes memory d = R.der(r, s);
        d[1] = bytes1(uint8(d[1]) + 1);
        assertFalse(
            h.p2wpkh(kh, m, abi.encodePacked(uint8(0x02), uint8(d.length + 1), d, uint8(0x01), uint8(0x21), pub)),
            "seq len"
        );
        // 5. integer tag 0x03 instead of 0x02
        bytes memory ri3 = ri;
        ri3[0] = 0x03;
        assertFalse(h.p2wpkh(kh, m, wrap(seq(ri3, si), pub)), "int tag");
        // 6. hash type SIGHASH_NONE / ANYONECANPAY / 0x00 / 0x81
        bytes memory good = R.der(r, s);
        assertFalse(h.p2wpkh(kh, m, wrapHt(good, pub, 0x02)), "ht none");
        assertFalse(h.p2wpkh(kh, m, wrapHt(good, pub, 0x03)), "ht single");
        assertFalse(h.p2wpkh(kh, m, wrapHt(good, pub, 0x81)), "ht all|acp");
        assertFalse(h.p2wpkh(kh, m, wrapHt(good, pub, 0x00)), "ht 0");
        // 7. uncompressed key (0x04 || x || y), key length 0x41
        R.Pt memory pt = R.liftX(uint256(bytes32(slice(pub, 1, 33))));
        if (uint8(pub[0]) == 0x03) pt.y = R.P - pt.y;
        bytes memory unc = abi.encodePacked(uint8(0x04), bytes32(pt.x), bytes32(pt.y));
        bytes memory dd = abi.encodePacked(good, uint8(0x01));
        assertFalse(
            h.p2wpkh(kh, m, abi.encodePacked(uint8(0x02), uint8(dd.length), dd, uint8(0x41), unc)), "uncompressed"
        );
        // 8. wrong parity prefix on the key (hash160 differs, and the point differs)
        bytes memory pub2 = pub;
        pub2[0] = bytes1(uint8(pub[0]) ^ 0x01);
        assertFalse(h.p2wpkh(kh, m, wrap(good, pub2)), "parity flipped");
        assertFalse(h.p2wpkh(R.hash160(pub2), m, wrap(good, pub2)), "parity flipped, matching hash");
        // 9. witness count 1 or 3
        bytes memory w = wrap(good, pub);
        w[0] = 0x01;
        assertFalse(h.p2wpkh(kh, m, w), "count 1");
        w[0] = 0x03;
        assertFalse(h.p2wpkh(kh, m, w), "count 3");
    }

    /// The DER integer length boundary: 33 bytes only with a 0x00 pad before a high-bit byte; 34 never.
    function test_p2wpkh_der_33_34_byte_ints() public {
        uint256 priv = 0xabc;
        (uint256 r, uint256 s, bytes memory pub) = S.signP2WPKHRaw(priv, "m");
        bytes20 kh = R.hash160(pub);
        bytes memory good = R.der(r, s);
        assertTrue(h.p2wpkh(kh, "m", wrap(good, pub)));
        // force a 33-byte r with pad where r's top bit is clear: non-minimal, rejected
        bytes memory ri = R.derInt(r);
        if (ri.length == 34) {
            // r already 0x00-padded (top bit set): 33 bytes, accepted (covered by `good`). Make it 34.
            bytes memory ri34 = abi.encodePacked(uint8(0x02), uint8(34), uint8(0), slice(ri, 2, ri.length));
            assertFalse(h.p2wpkh(kh, "m", wrap(seq(ri34, R.derInt(s)), pub)), "34");
        } else {
            bytes memory ri33 = abi.encodePacked(uint8(0x02), uint8(ri.length - 1), uint8(0), slice(ri, 2, ri.length));
            assertFalse(h.p2wpkh(kh, "m", wrap(seq(ri33, R.derInt(s)), pub)), "33 non-minimal");
        }
        // r with l = 33, first byte nonzero and top bit clear (value >= 2^256 would be): parser bound
        bytes memory big = abi.encodePacked(uint8(0x02), uint8(33), uint8(0x01), bytes32(r));
        assertFalse(h.p2wpkh(kh, "m", wrap(seq(big, R.derInt(s)), pub)), "33 nonzero lead");
    }

    /// Random bytes of any length in the P2WPKH witness slot: never reverts.
    function testFuzz_p2wpkh_random_never_reverts(bytes20 kh, bytes memory m, bytes memory w) public view {
        h.p2wpkh(kh, m, w);
    }

    /// Random bytes shaped like a witness (right length, right framing bytes) with random DER guts:
    /// stress the parser's bounds. Never reverts.
    function testFuzz_p2wpkh_shaped_never_reverts(
        bytes20 kh,
        bytes memory m,
        uint8 sigLen,
        bytes memory guts,
        bytes32 pubx,
        uint8 pubp
    ) public view {
        sigLen = uint8(bound(sigLen, 0, 80));
        bytes memory sig = new bytes(sigLen);
        for (uint256 i = 0; i < sigLen; i++) {
            sig[i] = guts.length > 0 ? guts[i % guts.length] : bytes1(0);
        }
        if (sigLen > 0) sig[sigLen - 1] = 0x01;
        if (sigLen > 1) sig[0] = 0x30;
        if (sigLen > 3) sig[1] = bytes1(sigLen - 3);
        if (sigLen > 4) sig[2] = 0x02;
        bytes memory w = abi.encodePacked(uint8(0x02), sigLen, sig, uint8(0x21), pubp, pubx);
        bool ok = h.p2wpkh(kh, m, w);
        assertFalse(ok, "random guts accepted");
    }

    // ----------------------------------------------------------------- P2TR round trips (random keys)

    function testFuzz_p2tr_roundtrip(uint256 d, bytes memory m, bool all) public view {
        d = bound(d, 1, N - 1);
        bytes32 px = S.trKey(d);
        vm.assume(uint256(px) < N);
        bytes memory w = S.signP2TR(d, m, all);
        assertTrue(h.p2tr(px, m, w), "valid");
        assertFalse(h.p2tr(px, abi.encodePacked(m, "x"), w), "other message");
        assertFalse(h.p2tr(bytes32(uint256(px) ^ 1), m, w), "other key");
        // the same 64 bytes presented in the other sighash form are a signature over a different sighash
        bytes memory other = all
            ? abi.encodePacked(uint8(0x01), uint8(0x40), slice(w, 2, 66))
            : abi.encodePacked(uint8(0x01), uint8(0x41), slice(w, 2, 66), uint8(0x01));
        assertFalse(h.p2tr(px, m, other), "cross form");
    }

    function testFuzz_p2tr_byteflip_rejected(uint256 d, bytes memory m, bool all, uint256 idx, uint8 x) public view {
        d = bound(d, 1, N - 1);
        vm.assume(x != 0);
        bytes32 px = S.trKey(d);
        vm.assume(uint256(px) < N);
        bytes memory w = S.signP2TR(d, m, all);
        idx = idx % w.length;
        w[idx] = bytes1(uint8(w[idx]) ^ x);
        assertFalse(h.p2tr(px, m, w), "flip accepted");
    }

    function testFuzz_p2tr_random_never_reverts(bytes32 px, bytes memory m, bytes memory w) public view {
        h.p2tr(px, m, w);
    }

    // ----------------------------------------------------------------- sighash constructions vs the Python mirror

    /// Byte-for-byte check of to_spend / to_sign sighashes against values computed by tools/btc.py
    /// (run offline, see the audit report), for one message and both script kinds.
    function test_sighash_known_values() public view {
        bytes memory m =
            "TapeOut Bitcoin-keyed holder 0xd72a87dd57f18f6b28b808ac3ae24969bc83ede0 on chain 56 signs 0x0339922221de50d86bd688aac3ac33ebbb042a711752c4bb1985c61eacc4ffb3";
        bytes32 px = bytes32(slice(V.SPK_P2TR, 2, 34));
        bytes20 kh = bytes20(slice(V.SPK_P2WPKH, 2, 22));
        assertEq(h.trSighash(px, m, 0), PY_TR_SIGHASH_DEFAULT);
        assertEq(h.trSighash(px, m, 1), PY_TR_SIGHASH_ALL);
        assertEq(h.wpSighash(kh, m), PY_WP_SIGHASH);
    }

    // filled in from python (see report); placeholders are replaced before the run
    bytes32 constant PY_TR_SIGHASH_DEFAULT = 0x4caefa26b3b53d578dfcf3e0c00ba7b546906fc40e268523109ab31f8c561e46;
    bytes32 constant PY_TR_SIGHASH_ALL = 0x0907ab98efdcd5591c99c574528db35ca9ca08bf457971b2114f6b5491096ee9;
    bytes32 constant PY_WP_SIGHASH = 0xfb136acb01f9383bd935c5c22b297a5c7204a8ed51fc3eb4d529f853c7a66f75;

    // ----------------------------------------------------------------- EIP-1271 on deployed holders

    function testFuzz_1271_random_sig_never_reverts(bytes32 digest, bytes memory sig, bool wp) public {
        BitcoinKeyedHolder hd = S.deploy(wp ? V.SPK_P2WPKH : V.SPK_P2TR);
        bytes4 got = hd.isValidSignature(digest, sig);
        assertEq(got, bytes4(0xffffffff));
    }

    function test_1271_huge_sig() public {
        BitcoinKeyedHolder hd = S.deploy(V.SPK_P2WPKH);
        bytes memory sig = new bytes(20000);
        sig[0] = 0x02;
        sig[1] = 0x48;
        assertEq(hd.isValidSignature(bytes32(0), sig), bytes4(0xffffffff));
        assertEq(hd.isValidSignature(bytes32(0), ""), bytes4(0xffffffff));
        BitcoinKeyedHolder tr = S.deploy(V.SPK_P2TR);
        assertEq(tr.isValidSignature(bytes32(0), sig), bytes4(0xffffffff));
    }

    /// The vector cases that are expected to validate.
    function validCases() internal pure returns (V.SignCase[] memory out) {
        V.SignCase[] memory cs = V.signCases();
        uint256 k;
        for (uint256 i = 0; i < cs.length; i++) {
            if (cs[i].expect) k++;
        }
        out = new V.SignCase[](k);
        k = 0;
        for (uint256 i = 0; i < cs.length; i++) {
            if (cs[i].expect) out[k++] = cs[i];
        }
    }

    /// A valid signature for digest A never validates digest B (vectors + random B).
    function testFuzz_1271_sig_bound_to_digest(bytes32 other, uint8 which) public {
        V.SignCase[] memory cs = validCases();
        V.SignCase memory c = cs[bound(which, 0, cs.length - 1)];
        vm.assume(other != c.digest);
        vm.chainId(c.chainId);
        BitcoinKeyedHolder hd = S.deploy(c.holder == 1 ? V.SPK_P2WPKH : V.SPK_P2TR);
        assertEq(hd.isValidSignature(c.digest, c.sig), bytes4(0x1626ba7e), "sanity");
        assertEq(hd.isValidSignature(other, c.sig), bytes4(0xffffffff), "other digest");
    }

    /// Mutated vector signatures (any byte, any xor) return 0xffffffff without reverting.
    function testFuzz_1271_mutated_vector(uint8 which, uint256 idx, uint8 x) public {
        vm.assume(x != 0);
        V.SignCase[] memory cs = validCases();
        V.SignCase memory c = cs[bound(which, 0, cs.length - 1)];
        vm.chainId(c.chainId);
        BitcoinKeyedHolder hd = S.deploy(c.holder == 1 ? V.SPK_P2WPKH : V.SPK_P2TR);
        bytes memory sig = c.sig;
        idx = idx % sig.length;
        sig[idx] = bytes1(uint8(sig[idx]) ^ x);
        assertEq(hd.isValidSignature(c.digest, sig), bytes4(0xffffffff));
    }

    /// The return value is ABI-encoded as one 32-byte word (bytes4 left-aligned), as EIP-1271 callers expect.
    function test_1271_return_encoding() public {
        BitcoinKeyedHolder hd = S.deploy(V.SPK_P2TR);
        (bool ok, bytes memory ret) = address(hd).staticcall(abi.encodeWithSelector(0x1626ba7e, bytes32(0), bytes("")));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(bytes4(ret), bytes4(0xffffffff));
        assertEq(uint256(bytes32(ret)) & type(uint224).max, 0, "padding");
    }

    // ----------------------------------------------------------------- helpers

    function wrap(bytes memory der_, bytes memory pub) internal pure returns (bytes memory) {
        return wrapHt(der_, pub, 0x01);
    }

    function wrapHt(bytes memory der_, bytes memory pub, uint8 ht) internal pure returns (bytes memory) {
        bytes memory d = abi.encodePacked(der_, ht);
        return abi.encodePacked(uint8(0x02), uint8(d.length), d, uint8(0x21), pub);
    }

    function seq(bytes memory a, bytes memory b) internal pure returns (bytes memory) {
        bytes memory body = abi.encodePacked(a, b);
        return abi.encodePacked(uint8(0x30), uint8(body.length), body);
    }

    function slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i = from; i < to; i++) {
            out[i - from] = b[i];
        }
    }
}
