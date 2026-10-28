// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAgenticCommerce, IACPHook} from "../../src/Interfaces.sol";

/// @notice STAND-IN for the kernel, used only by the vector replay (VectorReplay.t.sol) so that the jobs of
///         vectors.json can be set field by field. It serves `getJob`, the two pinned constants, and
///         `complete`/`reject` (evaluator only, Submitted only, then afterAction on the hook). It holds no token
///         and models nothing else; the real kernel is exercised in KernelFork.t.sol.
contract StandInKernel {
    mapping(uint256 => IAgenticCommerce.Job) private jobs;

    function HOOK_GAS_LIMIT() external pure returns (uint256) {
        return 1_000_000;
    }

    function MAX_EXPIRY_DURATION() external pure returns (uint256) {
        return 31_536_000;
    }

    function setJob(uint256 id, IAgenticCommerce.Job calldata j) external {
        jobs[id] = j;
    }

    function getJob(uint256 id) external view returns (IAgenticCommerce.Job memory) {
        return jobs[id];
    }

    function complete(uint256 id, bytes32 reason, bytes calldata optParams) external {
        _end(id, 3, 0xd75bbdf3, reason, optParams);
    }

    function reject(uint256 id, bytes32 reason, bytes calldata optParams) external {
        _end(id, 4, 0x41dd26f5, reason, optParams);
    }

    function _end(uint256 id, uint8 status, bytes4 sel, bytes32 reason, bytes calldata optParams) private {
        IAgenticCommerce.Job storage j = jobs[id];
        require(msg.sender == j.evaluator && j.status == 2, "stand-in: WrongStatus");
        j.status = status;
        lastCall = sel;
        lastReason = reason;
        IACPHook(j.hook).afterAction(id, sel, abi.encode(reason, optParams));
    }

    bytes4 public lastCall;
    bytes32 public lastReason;
}
