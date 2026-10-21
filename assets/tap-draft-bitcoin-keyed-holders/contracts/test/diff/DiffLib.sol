// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {RefBIP322} from "../baseline/RefBIP322.sol";
import {RefBIP340} from "../baseline/RefBIP340.sol";
import {BIP322} from "../../src/BIP322.sol";
import {Secp256k1Ref as R} from "../Secp256k1Ref.sol";

/// Signing helpers for the differential tests. Both key types are signed through cheatcodes (vm.sign
/// for ECDSA, vm.createWallet for the points of BIP-340), so a fuzz run costs no Solidity EC math.
/// The sighashes come from the FROZEN baseline library (test/baseline/RefBIP322.sol).
library DSign {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant N = RefBIP340.N;
    bytes32 constant TAG_CHALLENGE = RefBIP340.TAG_CHALLENGE;

    function wpKey(uint256 priv) internal returns (bytes memory pub, bytes20 kh) {
        Vm.Wallet memory w = vm.createWallet(priv);
        pub = abi.encodePacked(uint8(w.publicKeyY & 1 == 1 ? 0x03 : 0x02), bytes32(w.publicKeyX));
        kh = ripemd160(abi.encodePacked(sha256(pub)));
    }

    function wpSpk(uint256 priv) internal returns (bytes memory) {
        (, bytes20 kh) = wpKey(priv);
        return abi.encodePacked(uint8(0x00), uint8(0x14), kh);
    }

    /// BIP-322 simple signature (P2WPKH, SIGHASH_ALL, strict DER, low s) of `m` by `priv`.
    function wpSign(uint256 priv, bytes memory m) internal returns (bytes memory) {
        (bytes memory pub, bytes20 kh) = wpKey(priv);
        bytes32 sh = RefBIP322.segwitV0Sighash(
            RefBIP322.toSpendTxid(RefBIP322.messageHash(m), abi.encodePacked(uint8(0x00), uint8(0x14), kh)), kh
        );
        (, bytes32 r, bytes32 s) = vm.sign(priv, sh);
        uint256 si = uint256(s);
        if (si > N / 2) si = N - si;
        bytes memory d = abi.encodePacked(R.der(uint256(r), si), uint8(0x01));
        return abi.encodePacked(uint8(0x02), uint8(d.length), d, uint8(0x21), pub);
    }

    /// (r, s) of a low-s ECDSA signature of `m`'s P2WPKH sighash, and the compressed key.
    function wpSignRS(uint256 priv, bytes memory m) internal returns (uint256 r, uint256 s, bytes memory pub) {
        bytes20 kh;
        (pub, kh) = wpKey(priv);
        bytes32 sh = RefBIP322.segwitV0Sighash(
            RefBIP322.toSpendTxid(RefBIP322.messageHash(m), abi.encodePacked(uint8(0x00), uint8(0x14), kh)), kh
        );
        (, bytes32 rr, bytes32 ss) = vm.sign(priv, sh);
        r = uint256(rr);
        s = uint256(ss);
        if (s > N / 2) s = N - s;
    }

    /// DER INTEGER of v in one of several encodings: 0 strict; 1 without the sign pad (negative when
    /// the top bit is set) or with a superfluous 0x00 otherwise; 2 with two leading zero bytes; 3 with
    /// all leading zero bytes stripped and none added.
    function derIntVariant(uint256 v, uint256 mode) internal pure returns (bytes memory) {
        bytes memory b = abi.encodePacked(v);
        uint256 i = 0;
        while (i < 31 && b[i] == 0) i++;
        bytes memory mag = new bytes(32 - i);
        for (uint256 j = 0; j < mag.length; j++) mag[j] = b[i + j];
        bool top = uint8(mag[0]) & 0x80 != 0;
        bytes memory body;
        if (mode == 0) body = top ? abi.encodePacked(uint8(0), mag) : mag;
        else if (mode == 1) body = top ? mag : abi.encodePacked(uint8(0), mag);
        else if (mode == 2) body = abi.encodePacked(uint16(0), mag);
        else body = mag;
        return abi.encodePacked(uint8(0x02), uint8(body.length), body);
    }

    /// A P2WPKH witness from (r, s, key) with chosen encodings of r and s.
    function wpWitness(uint256 r, uint256 s, bytes memory pub, uint256 rMode, uint256 sMode)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory ints = abi.encodePacked(derIntVariant(r, rMode), derIntVariant(s, sMode));
        bytes memory d = abi.encodePacked(uint8(0x30), uint8(ints.length), ints, uint8(0x01));
        return abi.encodePacked(uint8(0x02), uint8(d.length), d, uint8(0x21), pub);
    }

    /// The even-y secret and x-only key of `d` (used directly as the P2TR output key).
    function trKey(uint256 d) internal returns (uint256, bytes32) {
        Vm.Wallet memory w = vm.createWallet(d);
        if (w.publicKeyY & 1 == 1) d = N - d;
        return (d, bytes32(w.publicKeyX));
    }

    function trSpk(uint256 d) internal returns (bytes memory) {
        (, bytes32 px) = trKey(d);
        return abi.encodePacked(uint8(0x51), uint8(0x20), px);
    }

    /// BIP-322 simple signature (P2TR key path, BIP-340) of `m` by output-key secret `d`.
    function trSign(uint256 d, bytes memory m, bool sighashAll) internal returns (bytes memory) {
        (uint256 de, bytes32 px) = trKey(d);
        bytes memory spk = abi.encodePacked(uint8(0x51), uint8(0x20), px);
        bytes32 sh = RefBIP322.taprootSighash(RefBIP322.toSpendTxid(RefBIP322.messageHash(m), spk), spk, sighashAll ? 1 : 0);
        uint256 k = uint256(keccak256(abi.encode(de, sh, m))) % (N - 1) + 1;
        Vm.Wallet memory rw = vm.createWallet(k);
        if (rw.publicKeyY & 1 == 1) k = N - k;
        bytes32 rx = bytes32(rw.publicKeyX);
        uint256 e = uint256(sha256(abi.encodePacked(TAG_CHALLENGE, TAG_CHALLENGE, rx, px, sh))) % N;
        uint256 s = addmod(k, mulmod(e, de, N), N);
        if (sighashAll) return abi.encodePacked(uint8(0x01), uint8(0x41), rx, bytes32(s), uint8(0x01));
        return abi.encodePacked(uint8(0x01), uint8(0x40), rx, bytes32(s));
    }

    function bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + x % (hi - lo + 1);
    }

    /// A copy of `s` with one structural mutation chosen by `kind` (0 = unchanged).
    function mutate(bytes memory s, uint256 kind, uint256 pos, uint256 val) internal pure returns (bytes memory o) {
        kind %= 9;
        uint256 len = s.length;
        if (kind == 0 || (len == 0 && kind != 3 && kind != 6)) return s;
        pos = len == 0 ? 0 : pos % len;
        if (kind == 2) {
            o = new bytes(pos);
            for (uint256 i = 0; i < pos; i++) o[i] = s[i];
            return o;
        }
        if (kind == 3) return abi.encodePacked(s, uint8(val));
        if (kind == 5) {
            o = new bytes(len - 1);
            for (uint256 i = 0; i < len - 1; i++) o[i] = s[i < pos ? i : i + 1];
            return o;
        }
        if (kind == 6) {
            o = new bytes(len + 1);
            for (uint256 i = 0; i < len + 1; i++) o[i] = i < pos ? s[i] : (i == pos ? bytes1(uint8(val)) : s[i - 1]);
            return o;
        }
        o = abi.encodePacked(s);
        if (kind == 1) o[pos] = o[pos] ^ bytes1(uint8(1 << (val % 8)));
        else if (kind == 4) o[pos] = bytes1(uint8(val));
        else if (kind == 7) o[pos] = o[pos] ^ bytes1(uint8(val % 255 + 1));
        else o[1 % len] = bytes1(uint8(val)); // kind 8: the length byte of the first stack item
    }
}

/// Library-level harnesses: the frozen baseline library and the current one, same interface.
contract RefLib {
    function v(bytes calldata spk, bytes calldata m, bytes calldata w) external view returns (bool) {
        if (spk.length == 34) return RefBIP322.verifyP2TR(bytes32(spk[2:34]), m, w);
        return RefBIP322.verifyP2WPKH(bytes20(spk[2:22]), m, w);
    }
}

contract OptLib {
    function v(bytes calldata spk, bytes calldata m, bytes calldata w) external view returns (bool) {
        if (spk.length == 34) return BIP322.verifyP2TR(bytes32(spk[2:34]), m, w);
        return BIP322.verifyP2WPKH(bytes20(spk[2:22]), m, w);
    }
}
