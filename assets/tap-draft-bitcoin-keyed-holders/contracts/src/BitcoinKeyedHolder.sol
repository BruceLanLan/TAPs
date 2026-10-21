// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BIP322} from "./BIP322.sol";
import {BIP340} from "./BIP340.sol";

/// @title BitcoinKeyedHolder
/// @notice An account with no owner and no upgrade path, controlled by one Bitcoin address
///         (P2TR or P2WPKH). It can hold tokens such as TapeOut circuits, answers EIP-1271 with a
///         BIP-322 "simple" signature, and makes calls that the Bitcoin key signs, one at a time
///         (`execute`) or as an all-or-nothing batch of up to 8 (`executeBatch`). Anyone may
///         relay; nobody else has any authority over it.
contract BitcoinKeyedHolder {
    struct Call {
        address target;
        uint256 value;
        bytes data;
        uint256 callGas;
    }

    bytes4 internal constant EIP1271_MAGIC = 0x1626ba7e;
    bytes4 internal constant EIP1271_FAIL = 0xffffffff;

    /// @notice The largest number of calls in one batch.
    uint256 public constant MAX_CALLS = 8;
    /// @notice `callGas` of a batched call must be below this.
    uint256 public constant MAX_CALL_GAS = 1 << 64;
    /// @dev BatchCallFailed carries at most this many bytes of the failed call's revert data.
    uint256 internal constant REVERT_DATA_CAP = 256;

    bytes32 internal immutable outputKey; // P2TR, else zero
    bytes20 internal immutable keyHash; // P2WPKH, else zero
    /// @notice The number of successful `execute` and `executeBatch` calls so far; the next one must
    ///         sign this value.
    uint256 public nonce;

    event Called(uint256 indexed nonce, address indexed target, uint256 value, bytes32 dataHash);

    error UnsupportedScript();
    error Expired();
    error BadSignature();
    error NoCode();
    error InsufficientGas();
    error TipFailed();
    error BadBatch();
    error BatchCallFailed(uint256 index, bytes returnData);

    constructor(bytes memory scriptPubKey_) {
        if (scriptPubKey_.length == 34 && scriptPubKey_[0] == 0x51 && scriptPubKey_[1] == 0x20) {
            bytes32 k;
            assembly ("memory-safe") {
                k := mload(add(scriptPubKey_, 0x22))
            }
            // the output key must be usable for BIP-340 here: nonzero, below n, and on the curve
            (bool onCurve,) = BIP340.liftXEven(uint256(k));
            if (uint256(k) == 0 || uint256(k) >= BIP340.N || !onCurve) revert UnsupportedScript();
            outputKey = k;
        } else if (scriptPubKey_.length == 22 && scriptPubKey_[0] == 0x00 && scriptPubKey_[1] == 0x14) {
            bytes32 w;
            assembly ("memory-safe") {
                w := mload(add(scriptPubKey_, 0x22))
            }
            keyHash = bytes20(w);
        } else {
            revert UnsupportedScript();
        }
    }

    /// @notice The scriptPubKey of the controlling Bitcoin address: 0x5120 || output key (P2TR)
    ///         or 0x0014 || key hash (P2WPKH). Rebuilt from the immutables, so nothing is stored.
    function scriptPubKey() external view returns (bytes memory) {
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

    /// @notice The message the Bitcoin key signs to make the calls of `calls`, in order. Reverts with
    ///         BadBatch() unless there are 1 to MAX_CALLS calls.
    function batchMessage(Call[] calldata calls, uint256 callTip, uint256 callNonce, uint64 deadline)
        external
        view
        returns (bytes memory)
    {
        uint256 k = calls.length;
        if (k == 0 || k > MAX_CALLS) revert BadBatch();
        bytes32[] memory hashes = new bytes32[](k);
        for (uint256 i = 0; i < k; ++i) {
            hashes[i] = _keccakCalldata(calls[i].data);
        }
        return _batchMessage(calls, hashes, callTip, callNonce, deadline);
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

    /// @notice Makes the calls of `calls` in order as this account, each with its `callGas` as the
    ///         call's gas argument, then pays `callTip` once to `msg.sender`. Uses one nonce. All or
    ///         nothing: if call i (from 0) fails, everything reverts with BatchCallFailed(i, the first
    ///         REVERT_DATA_CAP bytes of its revert data), and with TipFailed() if the tip cannot be paid.
    ///         Returns nothing and never copies a callee's return data: a caller that needs the
    ///         results simulates the batch with eth_call (the callees' results are in the trace).
    function executeBatch(Call[] calldata calls, uint256 callTip, uint64 deadline, bytes calldata sig) external {
        if (block.timestamp > deadline) revert Expired();
        uint256 k = calls.length;
        if (k == 0 || k > MAX_CALLS) revert BadBatch();
        // Copy every call's data to memory now, before any gas check (as execute does): the copies and
        // the memory they take grow with the data, and must not come out of the gas reserved for a callee.
        bytes[] memory inputs = new bytes[](k);
        bytes32[] memory hashes = new bytes32[](k);
        uint256 total;
        for (uint256 i = 0; i < k; ++i) {
            Call calldata c = calls[i];
            uint256 g = c.callGas;
            if (g >= MAX_CALL_GAS) revert BadBatch();
            total += _need(g, c.value);
            bytes memory input = c.data;
            inputs[i] = input;
            hashes[i] = keccak256(input);
        }
        uint256 n = nonce;
        if (!_verify(_batchMessage(calls, hashes, callTip, n, deadline), sig)) revert BadSignature();
        nonce = n + 1;
        // Fail early when the relayer cannot cover every signed callGas; the check before each call
        // below is what guarantees each callee its callGas.
        if (gasleft() < total) revert InsufficientGas();
        for (uint256 i = 0; i < k; ++i) {
            Call calldata c = calls[i];
            address target = c.target;
            uint256 value = c.value;
            uint256 g = c.callGas;
            bytes memory input = inputs[i];
            // checked here, not up front, so that an earlier call may create the target of a later one
            if (input.length != 0 && target.code.length == 0) revert NoCode();
            if (gasleft() < _need(g, value)) revert InsufficientGas();
            bool ok;
            assembly ("memory-safe") {
                // no output area: on success the return data is never copied
                ok := call(g, target, value, add(input, 0x20), mload(input), 0, 0)
            }
            if (!ok) _revertBatchCallFailed(i);
        }
        if (callTip != 0) {
            bool paid;
            assembly ("memory-safe") {
                paid := call(gas(), caller(), callTip, 0, 0, 0, 0)
            }
            if (!paid) revert TipFailed();
        }
        for (uint256 i = 0; i < k; ++i) {
            emit Called(n, calls[i].target, calls[i].value, hashes[i]);
        }
    }

    /// @dev Reverts with BatchCallFailed(index, the first REVERT_DATA_CAP bytes of the failed call's revert
    ///      data), ABI-encoded at the free memory pointer: at most 100 + 256 + 32 bytes of memory, whatever
    ///      the size of the callee's revert data.
    function _revertBatchCallFailed(uint256 index) private pure {
        assembly ("memory-safe") {
            let len := returndatasize()
            if gt(len, 256) { len := 256 } // REVERT_DATA_CAP
            let p := mload(0x40)
            mstore(p, shl(224, 0x651ab1b3)) // BatchCallFailed(uint256,bytes)
            mstore(add(p, 0x04), index)
            mstore(add(p, 0x24), 0x40)
            mstore(add(p, 0x44), len)
            mstore(add(add(p, 0x64), len), 0) // zero padding (memory past the pointer may be dirty)
            returndatacopy(add(p, 0x64), 0, len)
            revert(p, add(0x64, and(add(len, 31), not(31))))
        }
    }

    /// @dev The gas that must be left before a batched call so that the callee receives `callGas`: the
    ///      rule of execute (TAP §6.3 step 5). callGas < 2^64, so nothing overflows.
    function _need(uint256 callGas, uint256 value) private pure returns (uint256 need) {
        unchecked {
            need = callGas * 64 / 63;
            if (need < callGas + 2500) need = callGas + 2500;
            need += value == 0 ? 3100 : 37100;
        }
    }

    function _verify(bytes memory message, bytes calldata sig) internal view returns (bool) {
        bytes32 h = _messageHash(message);
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

    /// @dev The batch message: prefix " makes " K " calls:", then for each call
    ///      " (" i ") 0x" target " with value " value " and data 0x" dataHash ", gas " callGas ";",
    ///      then " tip " callTip ", nonce " callNonce ", valid until " deadline. `hashes[i]` is
    ///      keccak256(calls[i].data), computed by the caller: nothing may allocate memory while the
    ///      message is being written.
    function _batchMessage(
        Call[] calldata calls,
        bytes32[] memory hashes,
        uint256 callTip,
        uint256 callNonce,
        uint64 deadline
    ) internal view returns (bytes memory m) {
        uint256 k = calls.length;
        (uint256 start, uint256 o) = _prefixAt();
        assembly ("memory-safe") {
            mstore(o, " makes ")
            o := add(o, 7)
        }
        o = _decAt(o, k);
        assembly ("memory-safe") {
            mstore(o, " calls:")
            o := add(o, 7)
        }
        for (uint256 i = 0; i < k; ++i) {
            Call calldata c = calls[i];
            assembly ("memory-safe") {
                mstore(o, " (")
                o := add(o, 2)
            }
            o = _decAt(o, i + 1);
            assembly ("memory-safe") {
                mstore(o, ") 0x")
                o := add(o, 4)
            }
            o = _hexAt(o, uint160(c.target), 20);
            assembly ("memory-safe") {
                mstore(o, " with value ")
                o := add(o, 12)
            }
            o = _decAt(o, c.value);
            assembly ("memory-safe") {
                mstore(o, " and data 0x")
                o := add(o, 12)
            }
            o = _hexAt(o, uint256(hashes[i]), 32);
            assembly ("memory-safe") {
                mstore(o, ", gas ")
                o := add(o, 6)
            }
            o = _decAt(o, c.callGas);
            assembly ("memory-safe") {
                mstore(o, ";")
                o := add(o, 1)
            }
        }
        assembly ("memory-safe") {
            mstore(o, " tip ")
            o := add(o, 5)
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
