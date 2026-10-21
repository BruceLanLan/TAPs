// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {stdError} from "forge-std/StdError.sol";
import {BitcoinKeyedHolder as B} from "../../src/BitcoinKeyedHolder.sol";
import {AuditSigner as S} from "../AuditLib.sol";
import {BenchERC721} from "./BenchERC721.sol";

/// Batch messages of 1,329, 610 and 2,239 characters signed by the UniSat browser extension 1.7.22 on 2026-10-10, and
/// by Xverse 2.9.3, Leather 6.114.0 and OKX 4.18.1 on 2026-10-11 (vectors/wallet-<name>-<version>-batch.json), for
/// the holders of the CURRENT creation code (vectors/wallet-unisat-1.7.22-batch.json, built by
/// tools/make_wallet_vectors.py from interop/unisat-extension/results/unisat-1.7.22-merged-batch-*.json). Each holder
/// is deployed through the proxy at its CREATE2 address; the 8-transfer and the mixed batch move tokens and pay the
/// tip; the longest text passes the signature check (and then overflows a nonce forced to 2^256 - 1).
contract WalletUnisatBatchTest is Test {
    using stdJson for string;

    address constant TOKEN = address(0xc1);
    address constant RECIPIENT = address(0xb0);
    string json;

    function setUp() public {
        vm.etch(S.FACTORY, S.factoryCode());
    }

    function load(string memory file) internal {
        json = vm.readFile(string.concat(vm.projectRoot(), "/../vectors/", file));
    }

    function at(uint256 i, string memory rest) internal pure returns (string memory) {
        return string.concat(".results[", vm.toString(i), "]", rest);
    }

    function num(string memory path) internal view returns (uint256) {
        return vm.parseUint(json.readString(path));
    }

    function deploy(bytes memory spk) internal returns (B) {
        (bool ok, bytes memory ret) =
            S.FACTORY.call(abi.encodePacked(bytes32(0), type(B).creationCode, abi.encode(spk)));
        require(ok && ret.length == 20, "factory");
        return B(payable(address(bytes20(ret))));
    }

    /// The calls of case `key` of result `i`, read from the vectors.
    function calls(uint256 i, string memory key) internal view returns (B.Call[] memory cs) {
        string memory base = at(i, string.concat(".cases.", key, ".calls"));
        uint256 n;
        while (json.keyExists(string.concat(base, "[", vm.toString(n), "]"))) n++;
        cs = new B.Call[](n);
        for (uint256 j = 0; j < n; j++) {
            string memory c = string.concat(base, "[", vm.toString(j), "]");
            cs[j] = B.Call(
                json.readAddress(string.concat(c, ".target")),
                num(string.concat(c, ".value")),
                json.readBytes(string.concat(c, ".data")),
                num(string.concat(c, ".callGas"))
            );
        }
    }

    function holder(uint256 i) internal returns (B h) {
        h = deploy(json.readBytes(at(i, ".scriptPubKey")));
        assertEq(address(h), json.readAddress(at(i, ".holder")), "CREATE2 address of the current build");
    }

    function test_unisat_batches() public {
        load("wallet-unisat-1.7.22-batch.json");
        batches();
    }

    function test_xverse_batches() public {
        load("wallet-xverse-2.9.3-batch.json");
        batches();
    }

    function test_leather_batches() public {
        load("wallet-leather-6.114.0-batch.json");
        batches();
    }

    function test_okx_batches() public {
        load("wallet-okx-4.18.1-batch.json");
        batches();
    }

    function batches() internal {
        for (uint256 i = 0; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            vm.chainId(56);
            B h = holder(i);
            vm.etch(TOKEN, type(BenchERC721).runtimeCode);
            for (uint256 id = 1; id <= 8; id++) {
                BenchERC721(TOKEN).mint(address(h), id);
            }
            vm.deal(address(h), 1 ether);
            vm.warp(1_800_000_000);

            // 8 transfers, 1,329 characters
            B.Call[] memory cs = calls(i, "transfers_8");
            assertEq(cs.length, 8);
            bytes memory w8 = json.readBytes(at(i, ".cases.transfers_8.witness"));
            assertEq(string(h.batchMessage(cs, 0, 0, 2_000_000_000)), json.readString(at(i, ".cases.transfers_8.message")));
            uint256 s2 = vm.snapshotState();
            h.executeBatch(cs, 0, 2_000_000_000, w8);
            for (uint256 id = 1; id <= 8; id++) {
                assertEq(BenchERC721(TOKEN).ownerOf(id), RECIPIENT);
            }
            assertEq(h.nonce(), 1);
            vm.expectRevert(B.BadSignature.selector);
            h.executeBatch(cs, 0, 2_000_000_000, w8);
            vm.revertToState(s2);

            // a transfer, a coin transfer with callGas 0 and another transfer, with a tip: 610 characters
            B.Call[] memory mx = calls(i, "mixed_3");
            bytes memory w3 = json.readBytes(at(i, ".cases.mixed_3.witness"));
            assertEq(string(h.batchMessage(mx, 1e16, 0, 2_000_000_000)), json.readString(at(i, ".cases.mixed_3.message")));
            vm.expectRevert(B.BadSignature.selector);
            h.executeBatch(mx, 1e16, 2_000_000_000, w8);
            address relayer = makeAddr("relayer");
            vm.prank(relayer);
            h.executeBatch(mx, 1e16, 2_000_000_000, w3);
            assertEq(relayer.balance, 1e16);
            assertEq(RECIPIENT.balance, 1e15);
            assertEq(BenchERC721(TOKEN).ownerOf(1), RECIPIENT);
            assertEq(BenchERC721(TOKEN).ownerOf(2), RECIPIENT);
            vm.revertToState(snap);
        }
    }

    /// The longest batch text (2,239 characters, every number at its maximum, nonce 2^256 - 1 forced into the
    /// nonce slot 0): the wallet's signature passes the signature check, after which increasing the nonce
    /// overflows (a state no holder can reach). With one bit of the signature flipped it stops at BadSignature.
    function test_unisat_longest_text() public {
        load("wallet-unisat-1.7.22-batch.json");
        longest();
    }

    function test_xverse_longest_text() public {
        load("wallet-xverse-2.9.3-batch.json");
        longest();
    }

    function test_leather_longest_text() public {
        load("wallet-leather-6.114.0-batch.json");
        longest();
    }

    function test_okx_longest_text() public {
        load("wallet-okx-4.18.1-batch.json");
        longest();
    }

    function longest() internal {
        for (uint256 i = 0; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            vm.chainId(type(uint64).max);
            B h = holder(i);
            vm.store(address(h), bytes32(0), bytes32(type(uint256).max));
            B.Call[] memory cs = calls(i, "longest");
            bytes memory m = h.batchMessage(cs, type(uint256).max, type(uint256).max, type(uint64).max);
            assertEq(m.length, 2239);
            assertEq(string(m), json.readString(at(i, ".cases.longest.message")));
            bytes memory w = json.readBytes(at(i, ".cases.longest.witness"));
            vm.warp(1_800_000_000);
            vm.expectRevert(stdError.arithmeticError);
            h.executeBatch(cs, type(uint256).max, type(uint64).max, w);
            w[w.length - 40] ^= 0x01;
            vm.expectRevert(B.BadSignature.selector);
            h.executeBatch(cs, type(uint256).max, type(uint64).max, w);
            vm.revertToState(snap);
        }
    }
}
