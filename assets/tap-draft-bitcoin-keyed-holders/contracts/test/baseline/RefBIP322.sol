// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Frozen copy of src/BIP322.sol at the baseline (lab commit 834787a), used as the reference in differential tests.

import {RefBIP340 as BIP340} from "./RefBIP340.sol";

/// @title BIP-322 "simple" message signatures, verified on an EVM chain
/// @notice Builds the virtual to_spend and to_sign transactions of BIP-322 for one message and one
///         single-key scriptPubKey, computes the sighash and checks the witness:
///         - P2TR key path (0x5120 || output key): BIP-341 sighash with SIGHASH_DEFAULT (64-byte
///           signature) or SIGHASH_ALL (65 bytes), then BIP-340 against the output key.
///         - P2WPKH (0x0014 || key hash): BIP-143 sighash with SIGHASH_ALL, strict DER with low s,
///           compressed key whose hash160 is the key hash, then ECDSA through ecrecover.
///         Uses only the sha256, ripemd160, modexp and ecrecover precompiles. Never reverts on bad input.
library RefBIP322 {
    /// @dev sha256("BIP0322-signed-message")
    bytes32 internal constant TAG_MESSAGE = 0x746584a1872fa10041554effa038d6124942dd79b4e58a4cda184e13dbe62c49;
    /// @dev sha256("TapSighash")
    bytes32 internal constant TAG_SIGHASH = 0xf40a48df4b2a70c8b4924bf2654661ed3d95fd66a313eb87237597c628e4a031;
    uint256 internal constant N = BIP340.N;
    uint256 internal constant P = BIP340.P;

    function messageHash(bytes memory message) internal view returns (bytes32) {
        return sha256(abi.encodePacked(TAG_MESSAGE, TAG_MESSAGE, message));
    }

    /// @dev txid of to_spend (it has no witness): sha256d of its serialization, internal byte order.
    function toSpendTxid(bytes32 msgHash, bytes memory spk) internal view returns (bytes32) {
        bytes memory tx_ = abi.encodePacked(
            bytes4(0), // nVersion 0
            uint8(1), // one input
            bytes32(0), bytes4(0xffffffff), // prevout 000…000:0xFFFFFFFF
            uint8(34), uint8(0x00), uint8(0x20), msgHash, // scriptSig OP_0 PUSH32 message_hash
            bytes4(0), // nSequence 0
            uint8(1), // one output
            bytes8(0), // nValue 0
            uint8(spk.length), spk, // scriptPubKey = message_challenge
            bytes4(0) // nLockTime 0
        );
        return sha256(abi.encodePacked(sha256(tx_)));
    }

    // ------------------------------------------------------------------ P2TR key path

    /// @dev BIP-341 signature message hash for to_sign (one input spending to_spend:0, one OP_RETURN output).
    function taprootSighash(bytes32 txid, bytes memory spk, uint8 hashType) internal view returns (bytes32) {
        bytes memory sigMsg = abi.encodePacked(
            uint8(0), // epoch
            hashType,
            bytes4(0), // nVersion
            bytes4(0), // nLockTime
            sha256(abi.encodePacked(txid, bytes4(0))), // sha_prevouts
            sha256(abi.encodePacked(bytes8(0))), // sha_amounts
            sha256(abi.encodePacked(uint8(spk.length), spk)), // sha_scriptpubkeys
            sha256(abi.encodePacked(bytes4(0))), // sha_sequences
            sha256(abi.encodePacked(bytes8(0), uint8(1), uint8(0x6a))), // sha_outputs: value 0, OP_RETURN
            uint8(0), // spend_type: key path, no annex
            bytes4(0) // input index
        );
        return sha256(abi.encodePacked(TAG_SIGHASH, TAG_SIGHASH, sigMsg));
    }

    /// @param outputKey the 32-byte x-only output key that the bc1p address encodes
    /// @param witness the serialized witness stack: 0x01 0x40 sig64, or 0x01 0x41 sig64 0x01
    function verifyP2TR(bytes32 outputKey, bytes memory message, bytes memory witness) internal view returns (bool) {
        uint256 len = witness.length;
        uint8 hashType;
        if (len == 66 && witness[0] == 0x01 && witness[1] == 0x40) {
            hashType = 0x00;
        } else if (len == 67 && witness[0] == 0x01 && witness[1] == 0x41 && witness[66] == 0x01) {
            hashType = 0x01;
        } else {
            return false;
        }
        uint256 r;
        uint256 s;
        assembly ("memory-safe") {
            r := mload(add(witness, 0x22))
            s := mload(add(witness, 0x42))
        }
        bytes memory spk = abi.encodePacked(uint8(0x51), uint8(0x20), outputKey);
        bytes32 sighash = taprootSighash(toSpendTxid(messageHash(message), spk), spk, hashType);
        return BIP340.verify(outputKey, sighash, r, s);
    }

    // ------------------------------------------------------------------ P2WPKH

    /// @dev BIP-143 sighash with SIGHASH_ALL for to_sign spending a P2WPKH to_spend output.
    function segwitV0Sighash(bytes32 txid, bytes20 keyHash) internal view returns (bytes32) {
        bytes memory preimage = abi.encodePacked(
            bytes4(0), // nVersion
            sha256(abi.encodePacked(sha256(abi.encodePacked(txid, bytes4(0))))), // hashPrevouts
            sha256(abi.encodePacked(sha256(abi.encodePacked(bytes4(0))))), // hashSequence
            txid, bytes4(0), // outpoint
            uint8(0x19), uint8(0x76), uint8(0xa9), uint8(0x14), keyHash, uint8(0x88), uint8(0xac), // scriptCode
            bytes8(0), // amount
            bytes4(0), // nSequence
            sha256(abi.encodePacked(sha256(abi.encodePacked(bytes8(0), uint8(1), uint8(0x6a))))), // hashOutputs
            bytes4(0), // nLockTime
            bytes4(0x01000000) // SIGHASH_ALL, little-endian
        );
        return sha256(abi.encodePacked(sha256(preimage)));
    }

    /// @dev One strict-DER INTEGER (BIP-66): positive, minimal, at most 32 bytes of value.
    function _derInt(bytes memory w, uint256 at, uint256 end) private pure returns (bool ok, uint256 v, uint256 next) {
        if (at + 2 > end || w[at] != 0x02) return (false, 0, 0);
        uint256 l = uint8(w[at + 1]);
        uint256 start = at + 2;
        if (l == 0 || l > 33 || start + l > end) return (false, 0, 0);
        uint8 first = uint8(w[start]);
        if (first & 0x80 != 0) return (false, 0, 0); // negative
        if (first == 0) {
            if (l == 1 || uint8(w[start + 1]) & 0x80 == 0) return (false, 0, 0); // not minimal
            start += 1;
            l -= 1;
        }
        if (l > 32) return (false, 0, 0);
        for (uint256 i = 0; i < l; i++) v = (v << 8) | uint8(w[start + i]);
        return (true, v, start + l);
    }

    /// @param keyHash hash160 of the compressed public key, which the bc1q address encodes
    /// @param witness the serialized witness stack: 0x02, len, DER || 0x01, 0x21, compressed key
    function verifyP2WPKH(bytes20 keyHash, bytes memory message, bytes memory witness) internal view returns (bool) {
        uint256 len = witness.length;
        if (len < 2 || witness[0] != 0x02) return false;
        uint256 sigLen = uint8(witness[1]); // DER plus the sighash byte
        if (sigLen < 9 || sigLen > 73 || 2 + sigLen + 34 != len) return false;
        if (witness[1 + sigLen] != 0x01) return false; // SIGHASH_ALL
        // DER: 0x30 total 0x02 r 0x02 s, exactly filling sigLen - 1 bytes
        uint256 derEnd = 1 + sigLen; // exclusive, index of the sighash byte
        if (witness[2] != 0x30 || uint8(witness[3]) != sigLen - 3) return false;
        (bool ok, uint256 r, uint256 at) = _derInt(witness, 4, derEnd);
        if (!ok) return false;
        uint256 s;
        (ok, s, at) = _derInt(witness, at, derEnd);
        if (!ok || at != derEnd) return false;
        if (r == 0 || r >= N || s == 0 || s > N / 2) return false; // low s, as Bitcoin's standard rules require
        // the key
        uint256 k = 2 + sigLen;
        if (witness[k] != 0x21) return false;
        bytes memory pub = new bytes(33);
        for (uint256 i = 0; i < 33; i++) pub[i] = witness[k + 1 + i];
        if (ripemd160(abi.encodePacked(sha256(pub))) != keyHash) return false;
        uint8 prefix = uint8(pub[0]);
        if (prefix != 0x02 && prefix != 0x03) return false;
        uint256 x;
        assembly ("memory-safe") {
            x := mload(add(pub, 0x21))
        }
        (bool lifted, uint256 y) = BIP340.liftXEven(x);
        if (!lifted) return false;
        if (prefix == 0x03) y = P - y;
        address expected = address(uint160(uint256(keccak256(abi.encode(x, y)))));
        bytes32 sighash = segwitV0Sighash(
            toSpendTxid(messageHash(message), abi.encodePacked(uint8(0x00), uint8(0x14), keyHash)), keyHash
        );
        return ecrecover(sighash, 27, bytes32(r), bytes32(s)) == expected
            || ecrecover(sighash, 28, bytes32(r), bytes32(s)) == expected;
    }
}
