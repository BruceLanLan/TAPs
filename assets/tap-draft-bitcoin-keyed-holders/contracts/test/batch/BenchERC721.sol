// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/// A plain ERC-721 with the storage writes and checks of a typical implementation (owner, balances,
/// approval clearing, Transfer event, receiver check), used for the batch tests and gas measurements.
/// Real TapeOut circuits do more work per transfer; only the differences between measurements are portable.
contract BenchERC721 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    event Transfer(address indexed from, address indexed to, uint256 indexed id);

    function mint(address to, uint256 id) external {
        require(ownerOf[id] == address(0), "minted");
        ownerOf[id] = to;
        balanceOf[to]++;
        emit Transfer(address(0), to, id);
    }

    function transferFrom(address from, address to, uint256 id) public {
        require(ownerOf[id] == from, "not owner");
        require(to != address(0), "zero");
        require(
            msg.sender == from || isApprovedForAll[from][msg.sender] || msg.sender == getApproved[id], "not allowed"
        );
        balanceOf[from]--;
        balanceOf[to]++;
        ownerOf[id] = to;
        delete getApproved[id];
        emit Transfer(from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        transferFrom(from, to, id);
        if (to.code.length != 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, id, "")
                    == IERC721Receiver.onERC721Received.selector,
                "receiver"
            );
        }
    }
}
