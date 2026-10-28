// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title MockGame
/// @notice STAND-IN for a verifiable-execution game of TAP-draft-large-netlists (pull request #74). It offers
///         the three views of Specification 1.3 and nothing of the real game: claims are created and decided
///         by direct calls (`claim`, `setStatus`), nothing is verified, no bond is held. Tests only.
contract MockGame {
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

    enum AcceptMode {
        Accept, // accept(id) sets an open claim whose window has passed to accepted
        Revert, // accept reverts
        BurnGas, // accept consumes all gas it is given
        Missing // accept is "not implemented" (reverts with empty data)
    }

    uint64 public immutable maxSettlementSeconds;
    address public immutable inputProvider;
    uint64 public immutable challengeWindow;

    mapping(uint256 => Claim) private claims;
    uint256 public nextClaimId = 1;
    bool public eightValues; // answer claimSummary with the eight-value view of an earlier design (256 bytes)
    AcceptMode public acceptMode;
    uint256 public acceptCalls;

    constructor(uint64 maxSettlementSeconds_, address inputProvider_, uint64 challengeWindow_) {
        maxSettlementSeconds = maxSettlementSeconds_;
        inputProvider = inputProvider_;
        challengeWindow = challengeWindow_;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x58d08546;
    }

    /// A claim by msg.sender, open, window ending `challengeWindow` seconds from now.
    function claim(bytes32 netlistHash2, uint64 T, uint64 K, bytes32 inputRoot) external returns (uint256 id) {
        id = nextClaimId++;
        claims[id] = Claim(msg.sender, netlistHash2, T, K, inputRoot, keccak256("checkpointRoot"), 13, 1,
            uint64(block.timestamp) + challengeWindow);
    }

    function setClaim(uint256 id, Claim calldata c) external {
        claims[id] = c;
    }

    function setStatus(uint256 id, uint8 status) external {
        claims[id].status = status;
    }

    function setEightValues(bool v) external {
        eightValues = v;
    }

    function setAcceptMode(AcceptMode m) external {
        acceptMode = m;
    }

    function claimSummary(uint256 id)
        external
        view
        returns (address, bytes32, uint64, uint64, bytes32, bytes32, uint32, uint8, uint64)
    {
        Claim memory c = claims[id];
        if (eightValues) {
            bytes memory r = abi.encode(c.claimant, c.netlistHash2, c.T, c.K, c.inputRoot, c.checkpointRoot,
                c.leaves, c.status);
            assembly {
                return(add(r, 32), mload(r))
            }
        }
        return (c.claimant, c.netlistHash2, c.T, c.K, c.inputRoot, c.checkpointRoot, c.leaves, c.status, c.windowEnd);
    }

    function accept(uint256 id) external {
        if (acceptMode == AcceptMode.Revert) revert("accept: refused");
        if (acceptMode == AcceptMode.Missing) {
            assembly {
                revert(0, 0)
            }
        }
        if (acceptMode == AcceptMode.BurnGas) {
            while (true) {}
        }
        acceptCalls++;
        Claim storage c = claims[id];
        if (c.status == 1 && block.timestamp > c.windowEnd) c.status = 3;
    }
}
