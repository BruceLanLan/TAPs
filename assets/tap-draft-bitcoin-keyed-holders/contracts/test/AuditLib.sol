// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {BIP322} from "../src/BIP322.sol";
import {BIP340} from "../src/BIP340.sol";
import {BitcoinKeyedHolder} from "../src/BitcoinKeyedHolder.sol";
import {Secp256k1Ref as R} from "./Secp256k1Ref.sol";

/// Exposes the libraries' internals for tests.
contract LibHarness {
    function p2tr(bytes32 k, bytes calldata m, bytes calldata w) external view returns (bool) {
        return BIP322.verifyP2TR(k, m, w);
    }

    function p2wpkh(bytes20 kh, bytes calldata m, bytes calldata w) external view returns (bool) {
        return BIP322.verifyP2WPKH(kh, m, w);
    }

    function trSighash(bytes32 outputKey, bytes calldata m, uint8 ht) external view returns (bytes32) {
        bytes memory spk = abi.encodePacked(uint8(0x51), uint8(0x20), outputKey);
        return BIP322.taprootSighash(BIP322.toSpendTxid(BIP322.messageHash(m), spk), spk, ht);
    }

    function wpSighash(bytes20 kh, bytes calldata m) external view returns (bytes32) {
        return BIP322.segwitV0Sighash(
            BIP322.toSpendTxid(BIP322.messageHash(m), abi.encodePacked(uint8(0x00), uint8(0x14), kh)), kh
        );
    }
}

/// Subclass that exposes formatting helpers and the immutables' routing.
contract HolderExposed is BitcoinKeyedHolder {
    constructor(bytes memory spk) BitcoinKeyedHolder(spk) {}

    function dec(uint256 v) external pure returns (bytes memory) {
        return _dec(v);
    }

    function hex_(bytes memory b) external pure returns (bytes memory) {
        return _hex(b);
    }

    function routesToP2TR() external view returns (bool) {
        return outputKey != 0;
    }

    function keyHashValue() external view returns (bytes20) {
        return keyHash;
    }
}

/// Signing helpers for the audit: produce BIP-322 simple signatures for arbitrary messages with
/// random keys, through vm.sign (ECDSA, P2WPKH) and the pure-Solidity BIP-340 signer (P2TR).
library AuditSigner {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant N = R.N;

    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function factoryCode() internal pure returns (bytes memory) {
        return hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    }

    function deploy(bytes memory spk) internal returns (BitcoinKeyedHolder) {
        bytes memory init = abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(spk));
        (bool ok, bytes memory ret) = FACTORY.call(abi.encodePacked(bytes32(0), init));
        require(ok && ret.length == 20, "factory");
        return BitcoinKeyedHolder(payable(address(bytes20(ret))));
    }

    // ---- P2WPKH

    function wpPubkey(uint256 priv) internal returns (bytes memory pub, bytes20 kh) {
        Vm.Wallet memory w = vm.createWallet(priv);
        pub = abi.encodePacked(uint8(w.publicKeyY & 1 == 1 ? 0x03 : 0x02), bytes32(w.publicKeyX));
        kh = R.hash160(pub);
    }

    function wpSpk(bytes20 kh) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x00), uint8(0x14), kh);
    }

    function wpSighash(bytes20 kh, bytes memory m) internal view returns (bytes32) {
        return BIP322.segwitV0Sighash(BIP322.toSpendTxid(BIP322.messageHash(m), wpSpk(kh)), kh);
    }

    /// Simple signature of `m` by the P2WPKH address of `priv` (low s, strict DER).
    function signP2WPKH(uint256 priv, bytes memory m) internal returns (bytes memory witness) {
        (bytes memory pub, bytes20 kh) = wpPubkey(priv);
        (, bytes32 r, bytes32 s) = vm.sign(priv, wpSighash(kh, m));
        uint256 si = uint256(s);
        if (si > N / 2) si = N - si;
        bytes memory d = abi.encodePacked(R.der(uint256(r), si), uint8(0x01));
        witness = abi.encodePacked(uint8(0x02), uint8(d.length), d, uint8(0x21), pub);
    }

    /// Raw (r, s) too, for building malformed encodings.
    function signP2WPKHRaw(uint256 priv, bytes memory m) internal returns (uint256 r, uint256 s, bytes memory pub) {
        bytes20 kh;
        (pub, kh) = wpPubkey(priv);
        (, bytes32 rr, bytes32 ss) = vm.sign(priv, wpSighash(kh, m));
        r = uint256(rr);
        s = uint256(ss);
        if (s > N / 2) s = N - s;
    }

    // ---- P2TR

    function trKey(uint256 d) internal view returns (bytes32 px) {
        R.Pt memory pk = R.mulG(d);
        return bytes32(pk.x);
    }

    function trSpk(bytes32 px) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x51), uint8(0x20), px);
    }

    function trSighash(bytes32 px, bytes memory m, uint8 ht) internal view returns (bytes32) {
        bytes memory spk = trSpk(px);
        return BIP322.taprootSighash(BIP322.toSpendTxid(BIP322.messageHash(m), spk), spk, ht);
    }

    /// Simple signature of `m` by the P2TR address with output key d*G (d is the tweaked secret).
    function signP2TR(uint256 d, bytes memory m, bool sighashAll) internal view returns (bytes memory witness) {
        bytes32 px = trKey(d);
        bytes32 sh = trSighash(px, m, sighashAll ? 1 : 0);
        (bytes32 px2, uint256 r, uint256 s) = R.sign(d, abi.encodePacked(sh), keccak256(m), true);
        require(px2 == px, "px");
        if (sighashAll) return abi.encodePacked(uint8(0x01), uint8(0x41), bytes32(r), bytes32(s), uint8(0x01));
        return abi.encodePacked(uint8(0x01), uint8(0x40), bytes32(r), bytes32(s));
    }
}
