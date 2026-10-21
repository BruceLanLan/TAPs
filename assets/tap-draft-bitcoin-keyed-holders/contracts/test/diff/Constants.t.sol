// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BIP322} from "../../src/BIP322.sol";
import {BIP340} from "../../src/BIP340.sol";

/// The precomputed hashes of the optimised libraries are the hashes of what they stand for.
contract ConstantsTest is Test {
    function test_bip322_constants() public pure {
        assertEq(BIP322.TAG_MESSAGE, sha256("BIP0322-signed-message"));
        assertEq(BIP322.TAG_SIGHASH, sha256("TapSighash"));
        assertEq(BIP322.SHA_AMOUNTS, sha256(abi.encodePacked(bytes8(0))));
        assertEq(BIP322.SHA_SEQUENCES, sha256(abi.encodePacked(bytes4(0))));
        assertEq(BIP322.SHA_OUTPUTS, sha256(abi.encodePacked(bytes8(0), uint8(1), uint8(0x6a))));
        assertEq(BIP322.HASH_SEQUENCE, sha256(abi.encodePacked(sha256(abi.encodePacked(bytes4(0))))));
        assertEq(
            BIP322.HASH_OUTPUTS, sha256(abi.encodePacked(sha256(abi.encodePacked(bytes8(0), uint8(1), uint8(0x6a)))))
        );
    }

    function test_bip340_constants() public pure {
        assertEq(BIP340.TAG_CHALLENGE, sha256("BIP0340/challenge"));
        assertEq(BIP340.SQRT_EXP, (BIP340.P + 1) / 4);
    }
}
