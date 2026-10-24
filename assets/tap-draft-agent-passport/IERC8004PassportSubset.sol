// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

/// Subset of the ERC-8004 registries that TAP-draft-agent-passport reads and writes, written from the
/// interface of the BNB Smart Chain deployment. Every selector below was found in the deployed
/// implementation bytecode (identity 0x7274e874ca62410a93bd8bf61c69d8045e399c02 and reputation
/// 0x16e0fa7f7c56b9a767e34b192b51f921be31da34, read at block 129353333). Nothing else of the registries
/// is used by the TAP. ERC-8004 is a Draft; this file pins the deployed behaviour, not the EIP text.

/// Identity registry proxy 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432 (chain 56).
interface IERC8004IdentityPassportSubset {
    struct MetadataEntry {
        string metadataKey;
        bytes metadataValue;
    }

    /// 0x6352211e
    function ownerOf(uint256 agentId) external view returns (address);
    /// 0xc87b56dd; the agentURI
    function tokenURI(uint256 agentId) external view returns (string memory);
    /// 0x00339509; the owner at registration, zero after a transfer until set again
    function getAgentWallet(uint256 agentId) external view returns (address);
    /// 0xcb4799f2
    function getMetadata(uint256 agentId, string calldata metadataKey) external view returns (bytes memory);
    /// 0x8ea42286; mints to msg.sender, writes the URI and the metadata in one transaction
    function register(string calldata agentURI, MetadataEntry[] calldata metadata) external returns (uint256 agentId);
    /// 0x0af28bd3
    function setAgentURI(uint256 agentId, string calldata newURI) external;
    /// 0x466648da; the key "agentWallet" is reserved and reverts
    function setMetadata(uint256 agentId, string calldata metadataKey, bytes calldata metadataValue) external;
    /// 0x2d1ef5ae; EIP-712 domain ("ERC8004IdentityRegistry", "1", 56, registry),
    /// AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline), owner = current holder,
    /// deadline at most about 300 s after the block time (measured: +240 s accepted, +400 s rejected)
    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature) external;

    /// ERC-721 Transfer(address indexed from, address indexed to, uint256 indexed tokenId)
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
}

/// Reputation registry proxy 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63 (chain 56).
interface IERC8004ReputationPassportSubset {
    /// 0x3c036a7e; the submitter must not be the agent's owner or an approved operator
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;
    /// 0x4ab3ca99
    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external;
    /// 0x81bbba58; reverts "clientAddresses required" when clientAddresses is empty
    function getSummary(uint256 agentId, address[] calldata clientAddresses, string calldata tag1, string calldata tag2)
        external
        view
        returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals);
}
