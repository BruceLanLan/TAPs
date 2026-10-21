// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BIP340} from "./BIP340.sol";

/// @title BIP-322 "simple" message signatures, verified on an EVM chain
/// @notice Builds the virtual to_spend and to_sign transactions of BIP-322 for one message and one
///         single-key scriptPubKey, computes the sighash and checks the witness:
///         - P2TR key path (0x5120 || output key): BIP-341 sighash with SIGHASH_DEFAULT (64-byte
///           signature) or SIGHASH_ALL (65 bytes), then BIP-340 against the output key.
///         - P2WPKH (0x0014 || key hash): BIP-143 sighash with SIGHASH_ALL, strict DER with low s,
///           compressed key whose hash160 is the key hash, then ECDSA through ecrecover.
///         Uses only the sha256, ripemd160, modexp and ecrecover precompiles. Never reverts on bad input.
library BIP322 {
    /// @dev sha256("BIP0322-signed-message")
    bytes32 internal constant TAG_MESSAGE = 0x746584a1872fa10041554effa038d6124942dd79b4e58a4cda184e13dbe62c49;
    /// @dev sha256("TapSighash")
    bytes32 internal constant TAG_SIGHASH = 0xf40a48df4b2a70c8b4924bf2654661ed3d95fd66a313eb87237597c628e4a031;
    uint256 internal constant N = BIP340.N;
    uint256 internal constant P = BIP340.P;
    // Hashes of the parts of to_sign that are the same for every message and key (checked against the
    // general functions below by the tests):
    /// @dev sha256 of the 8-byte amount 0 (BIP-341 sha_amounts)
    bytes32 internal constant SHA_AMOUNTS = 0xaf5570f5a1810b7af78caf4bc70a660f0df51e42baf91d4de5b2328de0e83dfc;
    /// @dev sha256 of the 4-byte sequence 0 (BIP-341 sha_sequences)
    bytes32 internal constant SHA_SEQUENCES = 0xdf3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119;
    /// @dev sha256 of the output: value 0, script OP_RETURN (BIP-341 sha_outputs)
    bytes32 internal constant SHA_OUTPUTS = 0xcd496407aff71ffb5742f4f51efeac926c9f84eb51c391b5f2049bd74d9b4a02;
    /// @dev sha256d of the 4-byte sequence 0 (BIP-143 hashSequence)
    bytes32 internal constant HASH_SEQUENCE = 0x8cb9012517c817fead650287d61bdd9c68803b6bf9c64133dcab3e65b5a50cb9;
    /// @dev sha256d of the output: value 0, script OP_RETURN (BIP-143 hashOutputs)
    bytes32 internal constant HASH_OUTPUTS = 0x0e8538c66c434675836e2198aceb9a0bb62f3778a505eba907d843d312712b6d;

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

    // ------------------------------------------------------------------ fixed-layout hashing
    //
    // The same serialisations as the general functions above, written with mstore into free memory
    // (not allocated: nothing else runs while it is in use), with the constant parts precomputed.

    /// @dev txid of to_spend for the P2TR output key `outputKey` (if nonzero) or the P2WPKH `keyHash`.
    function _toSpendTxid(bytes32 msgHash, bytes32 outputKey, bytes20 keyHash) private view returns (bytes32 txid) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, shl(216, 1)) // nVersion 0, 1 input
            mstore(add(m, 5), 0) // prevout hash 0
            mstore(add(m, 37), shl(224, 0xffffffff)) // prevout index 0xFFFFFFFF
            mstore(add(m, 41), shl(232, 0x220020)) // scriptSig: 34 bytes, OP_0 PUSH32
            mstore(add(m, 44), msgHash)
            mstore(add(m, 76), shl(216, 1)) // nSequence 0, 1 output, value 0
            let len := 116
            switch iszero(outputKey)
            case 0 {
                mstore(add(m, 89), shl(232, 0x225120)) // scriptPubKey: 34 bytes, OP_1 PUSH32
                mstore(add(m, 92), outputKey)
                mstore(add(m, 124), 0) // nLockTime 0
                len := 128
            }
            default {
                mstore(add(m, 89), shl(232, 0x160014)) // scriptPubKey: 22 bytes, OP_0 PUSH20
                mstore(add(m, 92), keyHash) // 20 bytes, then nLockTime 0
            }
            if iszero(staticcall(gas(), 2, m, len, 0x00, 0x20)) { revert(0, 0) }
            if iszero(staticcall(gas(), 2, 0x00, 0x20, 0x00, 0x20)) { revert(0, 0) }
            txid := mload(0x00)
        }
    }

    /// @dev taprootSighash(txid, 0x5120 || outputKey, hashType)
    function _taprootSighash(bytes32 txid, bytes32 outputKey, uint256 hashType) private view returns (bytes32 h) {
        assembly ("memory-safe") {
            mstore(0x00, txid)
            mstore(0x20, 0)
            if iszero(staticcall(gas(), 2, 0x00, 36, 0x00, 0x20)) { revert(0, 0) }
            let shaPrevouts := mload(0x00)
            mstore(0x00, shl(232, 0x225120))
            mstore(0x03, outputKey)
            if iszero(staticcall(gas(), 2, 0x00, 35, 0x00, 0x20)) { revert(0, 0) }
            let shaScriptPubKeys := mload(0x00)
            let m := mload(0x40)
            mstore(m, TAG_SIGHASH)
            mstore(add(m, 0x20), TAG_SIGHASH)
            mstore(add(m, 0x40), shl(240, hashType)) // epoch 0, hash_type, nVersion 0, nLockTime 0
            mstore(add(m, 74), shaPrevouts)
            mstore(add(m, 106), SHA_AMOUNTS)
            mstore(add(m, 138), shaScriptPubKeys)
            mstore(add(m, 170), SHA_SEQUENCES)
            mstore(add(m, 202), SHA_OUTPUTS)
            mstore(add(m, 234), 0) // spend_type 0, input index 0
            if iszero(staticcall(gas(), 2, m, 239, 0x00, 0x20)) { revert(0, 0) }
            h := mload(0x00)
        }
    }

    /// @dev segwitV0Sighash(txid, keyHash)
    function _segwitV0Sighash(bytes32 txid, bytes20 keyHash) private view returns (bytes32 h) {
        assembly ("memory-safe") {
            mstore(0x00, txid)
            mstore(0x20, 0)
            if iszero(staticcall(gas(), 2, 0x00, 36, 0x00, 0x20)) { revert(0, 0) }
            if iszero(staticcall(gas(), 2, 0x00, 0x20, 0x00, 0x20)) { revert(0, 0) }
            let hashPrevouts := mload(0x00)
            let m := mload(0x40)
            mstore(m, 0) // nVersion 0
            mstore(add(m, 4), hashPrevouts)
            mstore(add(m, 36), HASH_SEQUENCE)
            mstore(add(m, 68), txid)
            mstore(add(m, 100), shl(192, 0x000000001976a914)) // vout 0; scriptCode: 25 bytes, OP_DUP OP_HASH160 PUSH20
            mstore(add(m, 108), keyHash)
            mstore(add(m, 128), shl(240, 0x88ac)) // OP_EQUALVERIFY OP_CHECKSIG; amount 0, nSequence 0
            mstore(add(m, 142), HASH_OUTPUTS)
            mstore(add(m, 174), shl(192, 0x0000000001000000)) // nLockTime 0, SIGHASH_ALL little-endian
            if iszero(staticcall(gas(), 2, m, 182, 0x00, 0x20)) { revert(0, 0) }
            if iszero(staticcall(gas(), 2, 0x00, 0x20, 0x00, 0x20)) { revert(0, 0) }
            h := mload(0x00)
        }
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
    function verifyP2TR(bytes32 outputKey, bytes memory message, bytes calldata witness) internal view returns (bool) {
        return verifyP2TRHash(outputKey, messageHash(message), witness);
    }

    /// @notice verifyP2TR for a message given by its BIP-322 message hash. Reads the witness from calldata.
    function verifyP2TRHash(bytes32 outputKey, bytes32 msgHash, bytes calldata witness) internal view returns (bool) {
        bool shape;
        uint256 hashType;
        uint256 r;
        uint256 s;
        assembly ("memory-safe") {
            let o := witness.offset
            let head := shr(240, calldataload(o)) // witness[0], witness[1]
            switch witness.length
            case 66 { shape := eq(head, 0x0140) }
            case 67 {
                shape := and(eq(head, 0x0141), eq(byte(0, calldataload(add(o, 66))), 0x01))
                hashType := 1
            }
            r := calldataload(add(o, 2))
            s := calldataload(add(o, 34))
        }
        if (!shape) return false;
        bytes32 sighash = _taprootSighash(_toSpendTxid(msgHash, outputKey, 0), outputKey, hashType);
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

    /// @dev witness[i] of a calldata witness at offset `o` (zero past the end of calldata)
    function _byteAt(uint256 o, uint256 i) private pure returns (uint256 b) {
        assembly ("memory-safe") {
            b := byte(0, calldataload(add(o, i)))
        }
    }

    /// @dev One strict-DER INTEGER (BIP-66) of the calldata witness at `o`, starting at index `at` and
    ///      ending before index `end`: positive, minimal, at most 32 bytes of value.
    function _derInt(uint256 o, uint256 at, uint256 end) private pure returns (bool ok, uint256 v, uint256 next) {
        assembly ("memory-safe") {
            let start := add(at, 2)
            let l := byte(0, calldataload(add(o, add(at, 1))))
            // tag 0x02, a nonzero length of at most 33 that fits before `end`
            if and(
                and(iszero(gt(start, end)), eq(byte(0, calldataload(add(o, at))), 0x02)),
                and(and(gt(l, 0), lt(l, 34)), iszero(gt(add(start, l), end)))
            ) {
                let first := byte(0, calldataload(add(o, start)))
                if iszero(and(first, 0x80)) { // not negative
                    ok := 1
                    if iszero(first) {
                        // a leading zero is allowed only in front of a byte with its top bit set
                        if or(eq(l, 1), iszero(and(byte(0, calldataload(add(o, add(start, 1)))), 0x80))) { ok := 0 }
                        start := add(start, 1)
                        l := sub(l, 1)
                    }
                    if gt(l, 32) { ok := 0 }
                    if ok {
                        v := shr(shl(3, sub(32, l)), calldataload(add(o, start)))
                        next := add(start, l)
                    }
                }
            }
        }
    }

    /// @param keyHash hash160 of the compressed public key, which the bc1q address encodes
    /// @param witness the serialized witness stack: 0x02, len, DER || 0x01, 0x21, compressed key
    function verifyP2WPKH(bytes20 keyHash, bytes memory message, bytes calldata witness) internal view returns (bool) {
        return verifyP2WPKHHash(keyHash, messageHash(message), witness);
    }

    /// @notice verifyP2WPKH for a message given by its BIP-322 message hash. Reads the witness from calldata.
    function verifyP2WPKHHash(bytes20 keyHash, bytes32 msgHash, bytes calldata witness) internal view returns (bool) {
        uint256 o;
        assembly ("memory-safe") {
            o := witness.offset
        }
        uint256 len = witness.length;
        // unchecked: every sum below is of a calldata length and bytes (< 2^64), and sigLen - 3 is
        // taken after sigLen >= 9 is checked; y < P after a successful lift.
        unchecked {
            if (len < 2 || _byteAt(o, 0) != 0x02) return false;
            uint256 sigLen = _byteAt(o, 1); // DER plus the sighash byte
            if (sigLen < 9 || sigLen > 73 || 2 + sigLen + 34 != len) return false;
            if (_byteAt(o, 1 + sigLen) != 0x01) return false; // SIGHASH_ALL
            // DER: 0x30 total 0x02 r 0x02 s, exactly filling sigLen - 1 bytes
            uint256 derEnd = 1 + sigLen; // exclusive, index of the sighash byte
            if (_byteAt(o, 2) != 0x30 || _byteAt(o, 3) != sigLen - 3) return false;
            (bool ok, uint256 r, uint256 at) = _derInt(o, 4, derEnd);
            if (!ok) return false;
            uint256 s;
            (ok, s, at) = _derInt(o, at, derEnd);
            if (!ok || at != derEnd) return false;
            if (r == 0 || r >= N || s == 0 || s > N / 2) return false; // low s, as Bitcoin's standard rules require
            // the key: 0x21, then 33 bytes whose hash160 is the key hash
            uint256 k = 2 + sigLen;
            if (_byteAt(o, k) != 0x21) return false;
            uint256 prefix = _byteAt(o, k + 1);
            uint256 x;
            assembly ("memory-safe") {
                let m := mload(0x40)
                calldatacopy(m, add(o, add(k, 1)), 33)
                if iszero(staticcall(gas(), 2, m, 33, 0x00, 0x20)) { revert(0, 0) }
                if iszero(staticcall(gas(), 3, 0x00, 0x20, 0x00, 0x20)) { revert(0, 0) }
                ok := eq(shl(96, mload(0x00)), keyHash)
                x := calldataload(add(o, add(k, 2)))
            }
            if (!ok) return false;
            if (prefix != 0x02 && prefix != 0x03) return false;
            (bool lifted, uint256 y) = BIP340.liftXEven(x);
            if (!lifted) return false;
            if (prefix == 0x03) y = P - y;
            address expected = BIP340.pointAddress(x, y);
            bytes32 sighash = _segwitV0Sighash(_toSpendTxid(msgHash, 0, keyHash), keyHash);
            return BIP340.recover(sighash, 27, r, s) == expected || BIP340.recover(sighash, 28, r, s) == expected;
        }
    }
}
