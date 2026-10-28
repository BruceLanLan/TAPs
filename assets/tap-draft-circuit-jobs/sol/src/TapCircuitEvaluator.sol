// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165, IACPHook, IAgenticCommerce, ITapCircuitJob} from "./Interfaces.sol";

/// @title TapCircuitEvaluator
/// @notice Reference evaluator-and-hook of TAP-draft-circuit-jobs. Evaluator and hook of every job it serves,
///         no owner, no custody, no discretion: it completes a job when the game reports the job's claim
///         accepted and rejects it when the game reports the claim rejected (rules J-1 to J-10).
/// @dev Reference code for a draft. Not audited, not deployed, and not a conformance claim (Specification 0.1).
contract TapCircuitEvaluator is ITapCircuitJob, IACPHook, IERC165 {
    // kernel selectors (Specification 1.2)
    bytes4 private constant FUND = 0xd2e13f50;
    bytes4 private constant SUBMIT = 0x9e63798d;
    bytes4 private constant COMPLETE = 0xd75bbdf3;
    bytes4 private constant REJECT = 0x41dd26f5;
    // game selectors (Specification 1.3)
    bytes4 private constant CLAIM_SUMMARY = 0x58d08546;
    bytes4 private constant ACCEPT = 0x19b05f49;

    uint8 private constant JOB_OPEN = 0;
    uint8 private constant JOB_SUBMITTED = 2;
    uint8 private constant CLAIM_NONE = 0;
    uint8 private constant CLAIM_OPEN = 1;
    uint8 private constant CLAIM_REJECTED = 2;
    uint8 private constant CLAIM_ACCEPTED = 3;
    uint8 private constant CLAIM_ABANDONED = 4;

    uint256 private constant PINNED_HOOK_GAS_LIMIT = 1_000_000;
    uint256 private constant PINNED_MAX_EXPIRY_DURATION = 31_536_000;
    uint64 private constant MIN_MARGIN = 21_600;
    uint64 private constant MIN_MIN_REMAINING_WINDOW = 21_600;
    uint256 private constant ACCEPT_GAS_CAP = 200_000;
    uint256 private constant CLAIM_SUMMARY_SIZE = 288;

    /// @notice A constructor condition of Specification 2.3 failed; `item` is its number there.
    error BadConstruction(uint8 item);

    struct Claim {
        address claimant;
        bytes32 netlistHash2;
        uint64 T;
        uint64 K;
        bytes32 inputRoot;
        bytes32 checkpointRoot;
        uint32 leaves;
        uint8 status;
        uint64 windowEnd;
    }

    struct Record {
        JobSpec spec;
        bytes32 specHash; // non-zero once bound
        uint256 claimId;
        bool claimBound;
        bool settled;
    }

    address public immutable kernel;
    address public immutable game;
    uint64 private immutable MARGIN;
    uint64 private immutable MIN_REMAINING_WINDOW;
    /// cached under Specification 2.2: constant for the life of the game (Specification 1.3 item 1)
    uint64 private immutable maxSettlementSeconds;
    address private immutable inputProvider;

    mapping(uint256 => Record) private records;
    /// re-entry guard of settle, in transient storage (EIP-1153): not state between transactions (8.1)
    bool private transient settling;

    constructor(address kernel_, address game_, uint64 margin_, uint64 minRemainingWindow_) {
        // 2.3 item 1
        if (kernel_.code.length == 0 || game_.code.length == 0) revert BadConstruction(1);
        // 2.3 item 2 (J-10)
        if (
            _readWord(kernel_, abi.encodeWithSelector(IAgenticCommerce.HOOK_GAS_LIMIT.selector), 2) != PINNED_HOOK_GAS_LIMIT
                || _readWord(kernel_, abi.encodeWithSelector(IAgenticCommerce.MAX_EXPIRY_DURATION.selector), 2)
                    != PINNED_MAX_EXPIRY_DURATION
        ) revert BadConstruction(2);
        // 2.3 item 3 (J-1)
        if (_readWord(game_, abi.encodeWithSelector(IERC165.supportsInterface.selector, CLAIM_SUMMARY), 3) != 1) {
            revert BadConstruction(3);
        }
        uint256 bound = _readWord(game_, abi.encodeWithSelector(bytes4(0xfcd8e94e)), 3);
        uint256 ip = _readWord(game_, abi.encodeWithSelector(bytes4(0xecef2c34)), 3);
        if (bound > type(uint64).max || ip > type(uint160).max) revert BadConstruction(3);
        // 2.3 item 4 (J-2, J-3)
        if (margin_ < MIN_MARGIN || minRemainingWindow_ < MIN_MIN_REMAINING_WINDOW) revert BadConstruction(4);
        // 2.3 item 5 (J-10)
        if (bound + margin_ >= PINNED_MAX_EXPIRY_DURATION) revert BadConstruction(5);

        kernel = kernel_;
        game = game_;
        MARGIN = margin_;
        MIN_REMAINING_WINDOW = minRemainingWindow_;
        maxSettlementSeconds = uint64(bound);
        inputProvider = address(uint160(ip));
    }

    // ------------------------------------------------------------------ ERC-165

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC165).interfaceId || id == type(IACPHook).interfaceId
            || id == type(ITapCircuitJob).interfaceId;
    }

    // ------------------------------------------------------------------ views

    function margin() external view returns (uint64) {
        return MARGIN;
    }

    function minRemainingWindow() external view returns (uint64) {
        return MIN_REMAINING_WINDOW;
    }

    function specOf(uint256 jobId) external view returns (JobSpec memory) {
        return records[jobId].spec;
    }

    function specHashOf(uint256 jobId) external view returns (bytes32) {
        return records[jobId].specHash;
    }

    function claimIdOf(uint256 jobId) external view returns (uint256 claimId, bool bound) {
        Record storage r = records[jobId];
        return (r.claimId, r.claimBound);
    }

    // ------------------------------------------------------------------ binding (Specification 3.2, J-1, J-2)

    function bindJob(uint256 jobId, JobSpec calldata spec) external {
        IAgenticCommerce.Job memory job = IAgenticCommerce(kernel).getJob(jobId);
        Record storage r = records[jobId];
        if (msg.sender != job.client) revert NotClient(); // 1
        if (job.status != JOB_OPEN) revert NotOpen(); // 2
        if (job.evaluator != address(this) || job.hook != address(this)) revert NotEvaluator(); // 3
        if (r.specHash != bytes32(0)) revert AlreadyBound(); // 4
        if (spec.game != game) revert BadGame(); // 5
        if (spec.inputProvider != inputProvider) revert BadInputProvider(); // 6
        if (spec.inputProvider != address(0) && spec.inputProvider == job.provider) revert BadInputProvider(); // 7
        if (spec.T < 1 || spec.K < 1 || spec.budget < 1 || spec.netlistHash2 == bytes32(0)) revert BadSpec(); // 8
        if (uint256(spec.expiredAt) != job.expiredAt) revert ExpiryMismatch(); // 9
        uint256 required = block.timestamp + maxSettlementSeconds + MARGIN;
        if (job.expiredAt < required) revert ExpiryTooSoon(required); // 10

        bytes32 h = keccak256(abi.encode(spec));
        r.spec = spec;
        r.specHash = h;
        emit JobBound(jobId, h, job.client);
    }

    // ------------------------------------------------------------------ hook entries (Specification 3.3, 5, 6.3, 7)

    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata) external view {
        if (msg.sender != kernel) revert NotKernel();
        if (selector != FUND) return; // no-effect entry (Specification 7 item 3)
        Record storage r = records[jobId];
        if (r.specHash == bytes32(0)) revert NotBound();
        if (IAgenticCommerce(kernel).getJob(jobId).budget != r.spec.budget) revert BudgetMismatch();
    }

    function afterAction(uint256 jobId, bytes4 selector, bytes calldata) external {
        if (msg.sender != kernel) revert NotKernel();
        if (selector == SUBMIT) {
            _onSubmit(jobId);
        } else if (selector == COMPLETE || selector == REJECT) {
            // J-8: record only; no call to any contract. JobSettled is emitted by settle (Specification 6.2).
            records[jobId].settled = true;
        }
        // every other (phase, selector): return without effect
    }

    function _onSubmit(uint256 jobId) private {
        Record storage r = records[jobId];
        if (r.specHash == bytes32(0)) revert NotBound(); // 2
        IAgenticCommerce.Job memory job = IAgenticCommerce(kernel).getJob(jobId);
        if (job.status != JOB_SUBMITTED) revert NotSubmitted(); // 3
        if (r.claimBound) revert AlreadyBound(); // 4
        uint256 claimId = uint256(job.deliverable);
        Claim memory c = _claim(claimId); // 5: BadGame on short return data
        if (c.status == CLAIM_NONE) revert BadDeliverable(); // 6
        if (c.claimant != job.provider) revert ClaimMismatch(); // 7
        JobSpec storage s = r.spec;
        if (c.netlistHash2 != s.netlistHash2 || c.inputRoot != s.inputRoot || c.T != s.T || c.K != s.K) {
            revert ClaimMismatch(); // 8
        }
        if (c.status != CLAIM_OPEN) revert ClaimNotOpen(); // 9
        uint256 requiredWindowEnd = block.timestamp + MIN_REMAINING_WINDOW;
        if (c.windowEnd < requiredWindowEnd) revert WindowTooShort(requiredWindowEnd); // 10 (J-3)
        uint256 requiredExpiry = block.timestamp + maxSettlementSeconds + MARGIN;
        if (job.expiredAt < requiredExpiry) revert ExpiryTooSoon(requiredExpiry); // 11 (J-2)

        r.claimId = claimId;
        r.claimBound = true;
        emit ClaimBound(jobId, claimId);
    }

    // ------------------------------------------------------------------ decision and settlement (Specification 6)

    function check(uint256 jobId) public view returns (uint8 decision, bytes32 reason) {
        Record storage r = records[jobId];
        if (r.specHash == bytes32(0)) revert NotBound();
        if (!r.claimBound) revert NoClaim();
        return _decide(r.claimId);
    }

    function settle(uint256 jobId) external {
        Record storage r = records[jobId];
        if (r.specHash == bytes32(0)) revert NotBound();
        if (!r.claimBound) revert NoClaim();
        if (r.settled) revert AlreadySettled();
        if (settling) revert AlreadySettled(); // a game's accept() re-entering settle is refused (and ignored)
        settling = true;

        uint256 claimId = r.claimId;
        _tryAccept(claimId);
        (uint8 decision, bytes32 reason) = _decide(claimId);
        if (decision == 0) revert NotDecided();
        // J-6: only a Submitted job. A job already refunded by claimRefund is Expired and is refused here.
        if (IAgenticCommerce(kernel).getJob(jobId).status != JOB_SUBMITTED) revert NotSubmitted();

        if (decision == 1) IAgenticCommerce(kernel).complete(jobId, reason, "");
        else IAgenticCommerce(kernel).reject(jobId, reason, "");
        // afterAction(complete|reject) has recorded `settled` inside the kernel call; record it again in case
        // a later kernel stops calling the hook for terminal actions.
        r.settled = true;
        settling = false;
        emit JobSettled(jobId, decision, reason);
    }

    function _decide(uint256 claimId) private view returns (uint8 decision, bytes32 reason) {
        Claim memory c = _claim(claimId);
        if (c.status == CLAIM_NONE) revert NoClaim();
        if (c.status == CLAIM_OPEN || c.status == CLAIM_ABANDONED) decision = 0;
        else if (c.status == CLAIM_ACCEPTED) decision = 1;
        else if (c.status == CLAIM_REJECTED) decision = 2;
        else revert BadGame();
        reason = keccak256(abi.encode(game, claimId, c.status));
    }

    // ------------------------------------------------------------------ game reads

    /// claimSummary by a low-level static call: an answer shorter than 288 bytes (for example the eight-value
    /// view of an earlier design, same selector) is BadGame (Specification 1.3 item 3).
    function _claim(uint256 claimId) private view returns (Claim memory c) {
        (bool ok, bytes memory ret) = game.staticcall(abi.encodeWithSelector(CLAIM_SUMMARY, claimId));
        if (!ok || ret.length < CLAIM_SUMMARY_SIZE) revert BadGame();
        // A word that does not fit its type makes the decoder revert; such a game is broken either way.
        c = abi.decode(ret, (Claim));
    }

    /// Optional permissionless accept (Specification 6.2): at most ACCEPT_GAS_CAP gas, failure ignored, no
    /// return data copied (a game cannot starve settle by gas or by a large return).
    function _tryAccept(uint256 claimId) private {
        address g = game;
        bytes4 sel = ACCEPT;
        uint256 cap = ACCEPT_GAS_CAP;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, sel)
            mstore(add(p, 4), claimId)
            pop(call(cap, g, 0, p, 36, 0, 0))
        }
    }

    function _readWord(address target, bytes memory callData, uint8 item) private view returns (uint256 v) {
        (bool ok, bytes memory ret) = target.staticcall(callData);
        if (!ok || ret.length != 32) revert BadConstruction(item);
        v = abi.decode(ret, (uint256));
    }
}
