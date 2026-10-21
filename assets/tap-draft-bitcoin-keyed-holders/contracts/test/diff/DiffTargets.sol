// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Call targets for the differential execute fuzz. Each exposes `state()`, a word that summarises
/// its storage, so that the two runs can be compared on effects as well as on return data.

contract DToken {
    mapping(uint256 => address) public ownerOf;
    uint256 public moves;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && msg.sender == from, "not owner");
        ownerOf[id] = to;
        moves++;
    }

    function state() external view returns (bytes32) {
        return keccak256(abi.encode(ownerOf[1], ownerOf[2], moves));
    }
}

contract DReverter {
    function boom(bytes calldata payload) external pure {
        assembly {
            calldatacopy(0, payload.offset, payload.length)
            revert(0, payload.length)
        }
    }

    function state() external pure returns (bytes32) {
        return 0;
    }
}

contract DReturner {
    uint256 public hits;
    uint256 public lastValue;

    function ret(bytes calldata payload) external payable returns (bytes memory) {
        hits++;
        lastValue = msg.value;
        assembly {
            calldatacopy(0, payload.offset, payload.length)
            return(0, payload.length)
        }
    }

    function state() external view returns (bytes32) {
        return keccak256(abi.encode(hits, lastValue));
    }
}

/// Records the gas it receives. With generous outer gas both runs must see the same number.
contract DProbe {
    uint256 public seen;
    uint256 public calls;

    function probe() external payable {
        seen = gasleft();
        calls++;
    }

    function state() external view returns (bytes32) {
        return keccak256(abi.encode(seen, calls));
    }
}

/// A relayer contract: relays with a chosen gas and accepts or rejects the tip.
contract DRelayer {
    bool public rejecting;
    uint256 public received;

    constructor(bool r) {
        rejecting = r;
    }

    function relay(address hd, bytes calldata cd, uint256 g) external returns (bool ok, bytes memory ret) {
        (ok, ret) = hd.call{gas: g}(cd);
    }

    receive() external payable {
        if (rejecting) revert("no coin");
        received += msg.value;
    }
}
