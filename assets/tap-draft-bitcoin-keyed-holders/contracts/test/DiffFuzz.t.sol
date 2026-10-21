// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {LibHarness} from "./AuditLib.sol";

/// Differential test against an independent BIP-322 verifier (bip322-js 4.0.0): `vectors/diff-fuzz-corpus.json` holds
/// valid signatures for public test keys and their mutations (bit flips, truncation, trailing bytes, sighash types,
/// high s, non-minimal and BER DER, key variants, item counts, other keys), each with bip322-js's own verdict
/// (made by `tools/wallet-lib-check/diff-fuzz.mjs`). The library is more lenient in places (it ignores trailing
/// bytes, for example); the property that matters is one-sided:
///   (1) every case that the library rejects, BIP322.sol rejects too (no signature that an independent verifier
///       refuses is ever accepted), and
///   (2) every unmodified signature from the library, for every message, is accepted.
/// Cases the library accepts and BIP322.sol refuses are counted and printed by tag: they are the strictness the
/// specification asks for (section 6.1), not a failure.
contract DiffFuzzTest is Test {
    LibHarness h;

    function setUp() public {
        h = new LibHarness();
    }

    string[] internal names;
    uint256[] internal strict;
    uint256[] internal agree;

    function _count(uint256[] storage arr, string memory t) internal {
        for (uint256 j = 0; j < names.length; j++) {
            if (keccak256(bytes(names[j])) == keccak256(bytes(t))) {
                arr[j]++;
                return;
            }
        }
        names.push(t);
        strict.push(0);
        agree.push(0);
        arr[names.length - 1]++;
    }

    function test_differential_against_bip322_js() public {
        string memory json = vm.readFile("../vectors/diff-fuzz-corpus.json");
        bytes20 wp = bytes20(vm.parseJsonBytes(json, ".keys.p2wpkh"));
        bytes32 tr = bytes32(vm.parseJsonBytes32(json, ".keys.p2tr"));
        uint256[] memory kind = vm.parseJsonUintArray(json, ".kind");
        uint256[] memory lib = vm.parseJsonUintArray(json, ".lib");
        bytes[] memory msg = vm.parseJsonBytesArray(json, ".msg");
        bytes[] memory wit = vm.parseJsonBytesArray(json, ".wit");
        string[] memory tag = vm.parseJsonStringArray(json, ".tag");
        uint256 n = kind.length;
        assertEq(lib.length, n);
        assertGt(n, 4000, "corpus is not the full one");

        uint256 libAcceptContractReject;
        uint256 bothAccept;
        uint256 bothReject;
        uint256 validCases;
        for (uint256 i = 0; i < n; i++) {
            bool c;
            if (kind[i] == 0) {
                try h.p2wpkh(wp, msg[i], wit[i]) returns (bool r) {
                    c = r;
                } catch {
                    c = false;
                }
            } else {
                try h.p2tr(tr, msg[i], wit[i]) returns (bool r) {
                    c = r;
                } catch {
                    c = false;
                }
            }
            if (c) {
                // (1): the contract's library accepts only what the independent verifier accepts
                assertEq(lib[i], 1, string.concat("accepted but bip322-js rejects: ", tag[i], " #", vm.toString(i)));
                bothAccept++;
                _count(agree, tag[i]);
            } else if (lib[i] == 1) {
                libAcceptContractReject++;
                _count(strict, tag[i]);
                // (2): an unmodified signature must never be refused
                assertTrue(keccak256(bytes(tag[i])) != keccak256("valid"), string.concat("valid signature refused #", vm.toString(i)));
            } else {
                bothReject++;
            }
            if (keccak256(bytes(tag[i])) == keccak256("valid")) validCases++;
        }
        console2.log("cases", n);
        console2.log("valid signatures accepted", validCases);
        console2.log("both accept", bothAccept);
        console2.log("both reject", bothReject);
        console2.log("library accepts, BIP322.sol rejects (strictness)", libAcceptContractReject);
        for (uint256 j = 0; j < names.length; j++) {
            console2.log(string.concat(names[j], " | both accept ", vm.toString(agree[j]), " | only the library accepts ", vm.toString(strict[j])));
        }
    }
}
