// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// The few Foundry cheatcodes these tests use (no forge-std dependency).
interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function warp(uint256) external;
    function cool(address) external;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function store(address, bytes32, bytes32) external;
    function load(address, bytes32) external view returns (bytes32);
    function etch(address, bytes calldata) external;
    function deal(address, uint256) external;
    function createSelectFork(string calldata) external returns (uint256);
    function envOr(string calldata, string calldata) external view returns (string memory);
    function readFile(string calldata) external view returns (string memory);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function parseJsonAddress(string calldata, string calldata) external pure returns (address);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
    function parseJsonBytes(string calldata, string calldata) external pure returns (bytes memory);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function parseJsonBool(string calldata, string calldata) external pure returns (bool);
    function keyExistsJson(string calldata, string calldata) external view returns (bool);
    function toString(uint256) external pure returns (string memory);
    function toString(bytes calldata) external pure returns (string memory);
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

abstract contract Base {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant CONSOLE = 0x000000000000000000636F6e736F6c652e6c6f67;

    /// console.log(string,uint256) without forge-std (shown with -vv)
    function log(string memory s, uint256 v) internal view {
        (bool ok,) = CONSOLE.staticcall(abi.encodeWithSignature("log(string,uint256)", s, v));
        ok;
    }

    function fail(string memory m) internal pure {
        revert(m);
    }

    function assertTrue(bool c, string memory m) internal pure {
        if (!c) revert(m);
    }

    function assertEq(uint256 a, uint256 b, string memory m) internal pure {
        if (a != b) revert(string.concat(m, ": ", _u(a), " != ", _u(b)));
    }

    function assertEq(address a, address b, string memory m) internal pure {
        if (a != b) revert(string.concat(m, ": address mismatch"));
    }

    function assertEq(bytes32 a, bytes32 b, string memory m) internal pure {
        if (a != b) revert(string.concat(m, ": bytes32 mismatch"));
    }

    function assertEq(string memory a, string memory b, string memory m) internal pure {
        if (keccak256(bytes(a)) != keccak256(bytes(b))) revert(string.concat(m, ": '", a, "' != '", b, "'"));
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 n;
        for (uint256 t = v; t != 0; t /= 10) n++;
        bytes memory b = new bytes(n);
        for (; v != 0; v /= 10) b[--n] = bytes1(uint8(48 + v % 10));
        return string(b);
    }

    function assertRevertData(bytes memory got, bytes memory want, string memory m) internal pure {
        if (keccak256(got) != keccak256(want)) {
            revert(string.concat(m, ": got ", vm.toString(got), " want ", vm.toString(want)));
        }
    }

    /// The first four bytes of revert data (zero when shorter).
    function sel4(bytes memory r) internal pure returns (bytes4 s) {
        if (r.length >= 4) s = bytes4(r);
    }

    function word(bytes memory r, uint256 i) internal pure returns (uint256 v) {
        assembly {
            v := mload(add(add(r, 36), mul(i, 32)))
        }
    }
}
