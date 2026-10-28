// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAgenticCommerce} from "../../src/Interfaces.sol";

/// @notice Test hook for measuring the kernel (Annex B style): reports IACPHook, records every entry
///         (phase, selector, msg.sender, gasleft, the job status the kernel shows at that moment), can be told
///         to revert in afterAction for chosen selectors (Pre-3 item 1), and can call the kernel as the job's
///         evaluator through `exec` (Pre-3 item 2).
contract ProbeHook {
    event Entry(uint8 phase, bytes4 selector, address sender, uint256 gasLeft, uint8 jobStatus, uint256 budget);

    address public immutable owner;
    mapping(bytes4 => bool) public revertAfter;
    bool public revertEmpty; // revert without data instead of with an Error(string)

    constructor() {
        owner = msg.sender;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x7ff6bc9e;
    }

    function setRevertAfter(bytes4 sel, bool v) external {
        revertAfter[sel] = v;
    }

    function setRevertEmpty(bool v) external {
        revertEmpty = v;
    }

    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata) external {
        uint256 g = gasleft();
        IAgenticCommerce.Job memory j = IAgenticCommerce(msg.sender).getJob(jobId);
        emit Entry(0, selector, msg.sender, g, j.status, j.budget);
    }

    function afterAction(uint256 jobId, bytes4 selector, bytes calldata) external {
        uint256 g = gasleft();
        if (revertAfter[selector]) {
            if (revertEmpty) {
                assembly {
                    revert(0, 0)
                }
            }
            revert("probe: afterAction refused");
        }
        IAgenticCommerce.Job memory j = IAgenticCommerce(msg.sender).getJob(jobId);
        emit Entry(1, selector, msg.sender, g, j.status, j.budget);
    }

    function exec(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == owner, "probe: owner");
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}
