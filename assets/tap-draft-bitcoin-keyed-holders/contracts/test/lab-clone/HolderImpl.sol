// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BIP322} from "../../src/BIP322.sol";
import {BIP340} from "../../src/BIP340.sol";

/// @title HolderImpl (gas lab, measurement only; NOT the TAP design)
/// @notice The shared implementation of a clone-based variant: every holder is a 45-byte ERC-1167
///         proxy followed by its scriptPubKey (22 or 34 bytes) and DELEGATECALLs here. The logic is
///         that of src/BitcoinKeyedHolder.sol at the time of the experiment; the output key or key
///         hash is read from the calling clone's code instead of from immutables.
contract HolderImpl {
    bytes4 internal constant EIP1271_MAGIC = 0x1626ba7e;
    bytes4 internal constant EIP1271_FAIL = 0xffffffff;

    /// @dev this contract's own address: called directly (not through a clone) it has no key
    address private immutable SELF = address(this);
    /// @notice The number of calls made so far; the next call must sign this value.
    uint256 public nonce;

    event Called(uint256 indexed nonce, address indexed target, uint256 value, bytes32 dataHash);

    error UnsupportedScript();
    error Expired();
    error BadSignature();
    error NoCode();
    error InsufficientGas();
    error TipFailed();

    /// @notice The constructor check of the holder, for a clone's creation code to STATICCALL:
    ///         reverts with UnsupportedScript() unless `spk` is a usable P2TR or P2WPKH scriptPubKey.
    function checkScript(bytes calldata spk) external view {
        if (spk.length == 34 && spk[0] == 0x51 && spk[1] == 0x20) {
            uint256 k = uint256(bytes32(spk[2:34]));
            (bool onCurve,) = BIP340.liftXEven(k);
            if (k == 0 || k >= BIP340.N || !onCurve) revert UnsupportedScript();
        } else if (!(spk.length == 22 && spk[0] == 0x00 && spk[1] == 0x14)) {
            revert UnsupportedScript();
        }
    }

    /// @dev The calling clone's key: its code is the 45-byte proxy, then the scriptPubKey.
    function _key() internal view returns (bytes32 outputKey, bytes20 keyHash) {
        if (address(this) == SELF) return (0, 0);
        assembly ("memory-safe") {
            extcodecopy(address(), 0x00, 45, 34)
            switch byte(0, mload(0x00))
            case 0x51 { outputKey := mload(0x02) }
            default { keyHash := and(mload(0x02), not(0xffffffffffffffffffffffff)) }
        }
    }

    /// @notice The scriptPubKey of the controlling Bitcoin address, read from the clone's code.
    function scriptPubKey() external view returns (bytes memory) {
        (bytes32 outputKey, bytes20 keyHash) = _key();
        if (outputKey != 0) return abi.encodePacked(uint8(0x51), uint8(0x20), outputKey);
        return abi.encodePacked(uint8(0x00), uint8(0x14), keyHash);
    }

    receive() external payable {}

    // ------------------------------------------------------------------ messages

    /// @notice The message the Bitcoin key signs to approve `digest` for EIP-1271.
    function signMessage(bytes32 digest) external view returns (bytes memory) {
        return _signMessage(digest);
    }

    /// @notice The message the Bitcoin key signs to make one call.
    function callMessage(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 callGas,
        uint256 callTip,
        uint256 callNonce,
        uint64 deadline
    ) external view returns (bytes memory) {
        return _callMessage(target, value, _keccakCalldata(data), callGas, callTip, callNonce, deadline);
    }

    // ------------------------------------------------------------------ authority

    /// @notice EIP-1271. `sig` is the BIP-322 "simple" signature: the serialized witness stack.
    function isValidSignature(bytes32 digest, bytes calldata sig) external view returns (bytes4) {
        return _verify(_signMessage(digest), sig) ? EIP1271_MAGIC : EIP1271_FAIL;
    }

    /// @notice Makes one call as this account, with `callGas` as the call's gas argument, and pays the
    ///         signed `callTip` of native coin to `msg.sender` (not `tx.origin`). Reverts, with
    ///         the callee's reason, if the call fails, and with TipFailed() if the tip cannot be paid.
    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 callGas,
        uint256 callTip,
        uint64 deadline,
        bytes calldata sig
    ) external returns (bytes memory ret) {
        if (block.timestamp > deadline) revert Expired();
        uint256 n = nonce;
        // Copy the call data to memory now, before the gas check below: the copy and the memory it
        // takes grow with data.length, and must not come out of the gas reserved for the callee.
        bytes memory input = data;
        bytes32 dataHash = keccak256(input);
        if (!_verify(_callMessage(target, value, dataHash, callGas, callTip, n, deadline), sig)) {
            revert BadSignature();
        }
        if (data.length != 0 && target.code.length == 0) revert NoCode();
        nonce = n + 1;
        // The relayer must supply enough gas for the callee to receive callGas: EIP-150 keeps 1/64 back,
        // and the CALL itself may cost a cold account access (2,600), a value transfer (9,000) and a new
        // account (25,000) before the callee starts.
        uint256 floor = callGas * 64 / 63;
        if (floor < callGas + 2500) floor = callGas + 2500;
        uint256 overhead = value == 0 ? 3100 : 37100;
        if (gasleft() < floor + overhead) revert InsufficientGas();
        bool ok;
        (ok, ret) = target.call{gas: callGas, value: value}(input);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        if (callTip != 0) {
            (bool paid,) = msg.sender.call{value: callTip}("");
            if (!paid) revert TipFailed();
        }
        emit Called(n, target, value, dataHash);
    }

    function _verify(bytes memory message, bytes calldata sig) internal view returns (bool) {
        bytes32 h = _messageHash(message);
        (bytes32 outputKey, bytes20 keyHash) = _key();
        if (outputKey != 0) return BIP322.verifyP2TRHash(outputKey, h, sig);
        return BIP322.verifyP2WPKHHash(keyHash, h, sig);
    }

    /// @dev BIP-322 message hash, sha256(tag || tag || message), of a message made by _signMessage or
    ///      _callMessage: the tags go into the two words in front of its data (its length word and the
    ///      spare word the builders leave), so the message is not copied. The length is restored.
    function _messageHash(bytes memory message) private view returns (bytes32 h) {
        assembly ("memory-safe") {
            let len := mload(message)
            // sha256("BIP0322-signed-message"), BIP322.TAG_MESSAGE
            mstore(sub(message, 0x20), 0x746584a1872fa10041554effa038d6124942dd79b4e58a4cda184e13dbe62c49)
            mstore(message, 0x746584a1872fa10041554effa038d6124942dd79b4e58a4cda184e13dbe62c49)
            if iszero(staticcall(gas(), 2, sub(message, 0x20), add(len, 0x40), 0x00, 0x20)) { revert(0, 0) }
            h := mload(0x00)
            mstore(message, len)
        }
    }

    // ------------------------------------------------------------------ receiving tokens

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x150b7a02 || id == 0x4e2312e0 || id == 0x1626ba7e;
    }

    // ------------------------------------------------------------------ formatting
    //
    // A message is written left to right into one buffer at the free memory pointer, leaving 64 bytes
    // in front of it (for its length word, or for a tag prefix). Each writer takes the write position and
    // returns the new one. Writers may leave garbage after the position they return; the next writer
    // overwrites it, and the message length excludes it.

    /// @dev "TapeOut Bitcoin-keyed holder 0x<this> on chain <chain id> signs 0x<digest>"
    function _signMessage(bytes32 digest) internal view returns (bytes memory m) {
        (uint256 start, uint256 o) = _prefixAt();
        assembly ("memory-safe") {
            mstore(o, " signs 0x")
            o := add(o, 9)
        }
        o = _hexAt(o, uint256(digest), 32);
        m = _allocate(start, o);
    }

    /// @dev The call message of TAP §5.2, from the hash of the call data.
    function _callMessage(
        address target,
        uint256 value,
        bytes32 dataHash,
        uint256 callGas,
        uint256 callTip,
        uint256 callNonce,
        uint64 deadline
    ) internal view returns (bytes memory m) {
        (uint256 start, uint256 o) = _prefixAt();
        assembly ("memory-safe") {
            mstore(o, " calls 0x")
            o := add(o, 9)
        }
        o = _hexAt(o, uint160(target), 20);
        assembly ("memory-safe") {
            mstore(o, " with value ")
            o := add(o, 12)
        }
        o = _decAt(o, value);
        assembly ("memory-safe") {
            mstore(o, " and data 0x")
            o := add(o, 12)
        }
        o = _hexAt(o, uint256(dataHash), 32);
        assembly ("memory-safe") {
            mstore(o, ", gas ")
            o := add(o, 6)
        }
        o = _decAt(o, callGas);
        assembly ("memory-safe") {
            mstore(o, ", tip ")
            o := add(o, 6)
        }
        o = _decAt(o, callTip);
        assembly ("memory-safe") {
            mstore(o, ", nonce ")
            o := add(o, 8)
        }
        o = _decAt(o, callNonce);
        assembly ("memory-safe") {
            mstore(o, ", valid until ")
            o := add(o, 14)
        }
        o = _decAt(o, deadline);
        m = _allocate(start, o);
    }

    /// @dev Starts a message at the free memory pointer + 64 with
    ///      "TapeOut Bitcoin-keyed holder 0x<this> on chain <chain id>".
    function _prefixAt() private view returns (uint256 start, uint256 o) {
        assembly ("memory-safe") {
            start := add(mload(0x40), 0x40)
            mstore(start, "TapeOut Bitcoin-keyed holder 0x")
            o := add(start, 31)
        }
        o = _hexAt(o, uint160(address(this)), 20);
        assembly ("memory-safe") {
            mstore(o, " on chain ")
            o := add(o, 10)
        }
        o = _decAt(o, block.chainid);
    }

    /// @dev The message [start, end) as `bytes memory` (its length goes into the word in front of
    ///      it), with the free memory pointer moved past it.
    function _allocate(uint256 start, uint256 end) private pure returns (bytes memory m) {
        assembly ("memory-safe") {
            m := sub(start, 0x20)
            mstore(m, sub(end, start))
            mstore(0x40, and(add(end, 31), not(31)))
        }
    }

    function _keccakCalldata(bytes calldata data) private pure returns (bytes32 h) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            calldatacopy(m, data.offset, data.length)
            h := keccak256(m, data.length)
        }
    }

    /// @dev Writes the low `n` bytes of `v` as 2n lowercase hex digits at `o`; returns o + 2n.
    function _hexAt(uint256 o, uint256 v, uint256 n) internal pure returns (uint256 end) {
        assembly ("memory-safe") {
            end := add(o, shl(1, n))
            mstore(0x0f, 0x30313233343536373839616263646566) // digit i is the last byte of mload(i)
            for { let p := end } gt(p, o) {} {
                p := sub(p, 2)
                mstore8(add(p, 1), mload(and(v, 15)))
                mstore8(p, mload(and(shr(4, v), 15)))
                v := shr(8, v)
            }
        }
    }

    /// @dev Writes `v` in decimal without leading zeros at `o`; returns the end. The digits are made
    ///      backwards in free memory 256 bytes ahead and then copied (at most 78 digits, three words).
    function _decAt(uint256 o, uint256 v) internal pure returns (uint256 end) {
        assembly ("memory-safe") {
            let t := add(o, 0x100)
            let q := t
            for {} 1 {} {
                q := sub(q, 1)
                mstore8(q, add(48, mod(v, 10)))
                v := div(v, 10)
                if iszero(v) { break }
            }
            mstore(o, mload(q))
            mstore(add(o, 0x20), mload(add(q, 0x20)))
            mstore(add(o, 0x40), mload(add(q, 0x40)))
            end := add(o, sub(t, q))
        }
    }

    /// @dev lowercase hex of `b`, no prefix
    function _hex(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(2 * b.length);
        uint256 o;
        assembly ("memory-safe") {
            o := add(out, 0x20)
        }
        for (uint256 i = 0; i < b.length; i++) {
            o = _hexAt(o, uint8(b[i]), 1);
        }
    }

    /// @dev decimal without leading zeros
    function _dec(uint256 v) internal pure returns (bytes memory out) {
        assembly ("memory-safe") {
            out := mload(0x40)
            mstore(0x40, add(out, 0x80))
        }
        uint256 o;
        assembly ("memory-safe") {
            o := add(out, 0x20)
        }
        uint256 end = _decAt(o, v);
        assembly ("memory-safe") {
            mstore(out, sub(end, o))
        }
    }
}
