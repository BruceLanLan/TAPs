// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

// Interfaces of TAP-draft-circuit-jobs, copied from the draft (Specification 1.2, 1.3 and 2.1).

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// The hook interface of the kernel, ERC-165 identifier 0x7ff6bc9e.
interface IACPHook {
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external; // 0xdc08fb1d
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external; // 0xa3fe4783
}

/// The functions of the deployed kernel this TAP uses (Specification 1.2). `getJob` returns the job as one
/// tuple; its field order was read from the deployed kernel (`getJob` of a live job on chain 56).
interface IAgenticCommerce {
    struct Job {
        uint256 id;
        address client;
        address provider;
        address evaluator;
        string description;
        uint256 budget;
        uint256 expiredAt;
        uint8 status;
        address hook;
        uint256 submittedAt;
        bytes32 deliverable;
    }

    function createJob(address provider, address evaluator, uint256 expiredAt, string calldata description, address hook)
        external
        returns (uint256);
    function setProvider(uint256 jobId, address provider_, bytes calldata optParams) external;
    function setBudget(uint256 jobId, uint256 amount, bytes calldata optParams) external;
    function fund(uint256 jobId, uint256 expectedBudget, bytes calldata optParams) external;
    function submit(uint256 jobId, bytes32 deliverable, bytes calldata optParams) external;
    function complete(uint256 jobId, bytes32 reason, bytes calldata optParams) external;
    function reject(uint256 jobId, bytes32 reason, bytes calldata optParams) external;
    function claimRefund(uint256 jobId) external;
    function getJob(uint256 jobId) external view returns (Job memory);
    function HOOK_GAS_LIMIT() external view returns (uint256);
    function MAX_EXPIRY_DURATION() external view returns (uint256);
    function paymentToken() external view returns (address);
    function platformFeeBP() external view returns (uint256);
}

/// The state of one claim. ERC-165 identifier 0x58d08546 (the selector of claimSummary(uint256)).
interface ITapClaimSummary {
    /// status: 0 none, 1 open, 2 rejected, 3 accepted, 4 abandoned.
    /// windowEnd: the last timestamp at which a challenge is accepted (0 when status is 0).
    function claimSummary(uint256 claimId)
        external
        view
        returns (
            address claimant,
            bytes32 netlistHash2,
            uint64 T,
            uint64 K,
            bytes32 inputRoot,
            bytes32 checkpointRoot,
            uint32 leaves,
            uint8 status,
            uint64 windowEnd
        ); // 0x58d08546
}

/// The settlement bound of the game. ERC-165 identifier 0xfcd8e94e.
interface ITapSettlementBound {
    function maxSettlementSeconds() external view returns (uint64); // 0xfcd8e94e
}

/// The input provider of the game. ERC-165 identifier 0xecef2c34.
interface ITapInputProvider {
    function inputProvider() external view returns (address); // 0xecef2c34
}

/// ERC-165 identifier 0x0b2be2a6 (exclusive or of the ten function selectors below).
/// The contract also reports 0x7ff6bc9e (IACPHook) and 0x01ffc9a7 (ERC-165).
interface ITapCircuitJob {
    struct JobSpec {
        address game; // MUST equal game()
        bytes32 netlistHash2;
        bytes32 inputRoot;
        uint64 T; // beats, >= 1
        uint64 K; // checkpoint spacing, >= 1
        uint256 budget; // the kernel budget the client will fund, >= 1
        uint64 expiredAt; // MUST equal job.expiredAt
        address inputProvider; // MUST equal game().inputProvider(); zero for case (a)
    }

    function bindJob(uint256 jobId, JobSpec calldata spec) external; // 0x9349e872
    function specOf(uint256 jobId) external view returns (JobSpec memory); // 0x20f20d9c
    function specHashOf(uint256 jobId) external view returns (bytes32); // 0xa2334b66
    function claimIdOf(uint256 jobId) external view returns (uint256 claimId, bool bound); // 0x0db32f94
    function check(uint256 jobId) external view returns (uint8 decision, bytes32 reason); // 0x5f72f450
    function settle(uint256 jobId) external; // 0x8df82800

    function kernel() external view returns (address); // 0xd4aae0c4
    function game() external view returns (address); // 0xc3fe3e28
    function margin() external view returns (uint64); // 0x8f76691a
    function minRemainingWindow() external view returns (uint64); // 0x5db8081c

    event JobBound(uint256 indexed jobId, bytes32 indexed specHash, address indexed client);
    event ClaimBound(uint256 indexed jobId, uint256 indexed claimId);
    event JobSettled(uint256 indexed jobId, uint8 decision, bytes32 reason);

    error NotKernel();
    error NotClient();
    error NotOpen();
    error NotEvaluator();
    error AlreadyBound();
    error NotBound();
    error BadGame();
    error BadInputProvider();
    error BadSpec();
    error ExpiryMismatch();
    error ExpiryTooSoon(uint256 required);
    error BudgetMismatch();
    error NotSubmitted();
    error BadDeliverable();
    error ClaimMismatch();
    error ClaimNotOpen();
    error WindowTooShort(uint256 required);
    error NoClaim();
    error NotDecided();
    error AlreadySettled();
}
