// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BitcoinKeyedHolder} from "../../src/BitcoinKeyedHolder.sol";

/// MEASUREMENT PROTOTYPE ONLY (docs/BATCH-REPORT.md §4); not proposed. The TAP holder plus a packed
/// encoding of `execute`, reached through fallback(). The signed text is the unchanged §5.2 message; only
/// the calldata differs:
///
///   tag (4) | target (20) | value uint96 (12) | callGas uint32 (4) | callTip uint96 (12)
///   | deadline uint32 (4, absolute Unix seconds) | data length uint16 (2) | data | sig (the rest)
///
/// 58 bytes of fixed fields instead of 4 + 7 x 32 + two length words and padding.
contract HolderCompactLab is BitcoinKeyedHolder {
    bytes4 public constant TAG = bytes4(keccak256("executeCompact()"));

    constructor(bytes memory spk) BitcoinKeyedHolder(spk) {}

    fallback(bytes calldata) external returns (bytes memory ret) {
        if (msg.data.length < 58 || bytes4(msg.data[0:4]) != TAG) revert();
        address target = address(bytes20(msg.data[4:24]));
        uint256 value = uint96(bytes12(msg.data[24:36]));
        uint256 callGas = uint32(bytes4(msg.data[36:40]));
        uint256 callTip = uint96(bytes12(msg.data[40:52]));
        uint64 deadline = uint32(bytes4(msg.data[52:56]));
        uint256 dataEnd = 58 + uint16(bytes2(msg.data[56:58]));
        if (msg.data.length < dataEnd) revert();
        bytes calldata data = msg.data[58:dataEnd];
        bytes calldata sig = msg.data[dataEnd:];
        ret = _exec(target, value, data, callGas, callTip, deadline, sig);
    }

    /// The body of `execute` as the batch lab had it (before the optimised base's copy-before-gas-check fix).
    function _exec(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 callGas,
        uint256 callTip,
        uint64 deadline,
        bytes calldata sig
    ) internal returns (bytes memory ret) {
        if (block.timestamp > deadline) revert Expired();
        uint256 n = nonce;
        bytes32 dataHash = keccak256(data);
        if (!_verify(_callMessage(target, value, dataHash, callGas, callTip, n, deadline), sig)) revert BadSignature();
        if (data.length != 0 && target.code.length == 0) revert NoCode();
        nonce = n + 1;
        uint256 floor = callGas * 64 / 63;
        if (floor < callGas + 2500) floor = callGas + 2500;
        uint256 overhead = value == 0 ? 3100 : 37100;
        if (gasleft() < floor + overhead) revert InsufficientGas();
        bool ok;
        (ok, ret) = target.call{gas: callGas, value: value}(data);
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
}
