// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {stdError} from "forge-std/StdError.sol";
import {BitcoinKeyedHolder} from "../../src/BitcoinKeyedHolder.sol";
import {BitcoinKeyedHolder as B} from "../../src/BitcoinKeyedHolder.sol";
import {AuditSigner as S} from "../AuditLib.sol";
import {BenchERC721} from "./BenchERC721.sol";
import {BatchLabCode} from "../batchlab/BatchLabCode.sol";

/// LEGACY. Batch messages of 610, 1,329 and 2,239 characters signed by the UniSat extension 1.7.22
/// (vectors/wallet-unisat-1.7.22-batch.json, made with interop/unisat-extension/steps/batch.mjs in the batch lab) are accepted.
/// Final lab: the wallet signed texts that name holders of the BATCH LAB's creation code. The recorded
/// addresses are checked against those frozen bytes (test/batchlab/BatchLabCode.sol); the MERGED code is
/// then installed at them, so the wallet's real signatures are checked by the merged verifier. Re-signing
/// for the merged contract's own addresses was done on 2026-10-10: WalletUnisatBatchTest, vectors/wallet-unisat-1.7.22-batch.json.
contract WalletUnisatBatchLegacyTest is Test {
    using stdJson for string;

    address constant TOKEN = address(0xc1);
    address constant RECIPIENT = address(0xb0);
    string json;

    function setUp() public {
        vm.etch(S.FACTORY, S.factoryCode());
        json = vm.readFile(string.concat(vm.projectRoot(), "/../vectors/legacy/wallet-unisat-1.7.22-batch-lab-fc8864b.json"));
    }

    /// The merged holder for `spk`, installed at `recorded` after checking that `recorded` is the
    /// CREATE2 address of the batch lab's bytes for `spk`.
    function holderAt(bytes memory spk, address recorded) internal returns (B) {
        bytes memory labInit = abi.encodePacked(BatchLabCode.creationCode(), abi.encode(spk));
        assertEq(computeCreate2Address(bytes32(0), keccak256(labInit), S.FACTORY), recorded, "batch lab address");
        vm.etch(recorded, abi.encodePacked(type(B).creationCode, abi.encode(spk)));
        (bool ok, bytes memory rt) = recorded.call("");
        require(ok, "constructor");
        vm.etch(recorded, rt);
        return B(payable(recorded));
    }

    function at(uint256 i, string memory rest) internal pure returns (string memory) {
        return string.concat(".results[", vm.toString(i), "]", rest);
    }

    function xfer(B h, uint256 id) internal pure returns (B.Call memory) {
        return B.Call(TOKEN, 0, abi.encodeCall(BenchERC721.safeTransferFrom, (address(h), RECIPIENT, id)), 100_000);
    }

    function test_unisat_batches() public {
        for (uint256 i = 0; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            bytes memory spk = json.readBytes(at(i, ".scriptPubKey"));
            vm.chainId(56);
            B h = holderAt(spk, json.readAddress(at(i, ".holder")));
            vm.etch(TOKEN, type(BenchERC721).runtimeCode);
            for (uint256 id = 1; id <= 8; id++) {
                BenchERC721(TOKEN).mint(address(h), id);
            }
            vm.deal(address(h), 1 ether);
            vm.warp(1_800_000_000);

            // 8 transfers, 1,329 characters
            B.Call[] memory cs = new B.Call[](8);
            for (uint256 j = 0; j < 8; j++) {
                cs[j] = xfer(h, j + 1);
            }
            bytes memory w8 = json.readBytes(at(i, ".cases.transfers_8.witness"));
            assertEq(
                string(h.batchMessage(cs, 0, 0, 2_000_000_000)), json.readString(at(i, ".cases.transfers_8.message"))
            );
            uint256 s2 = vm.snapshotState();
            h.executeBatch(cs, 0, 2_000_000_000, w8);
            assertEq(BenchERC721(TOKEN).ownerOf(8), RECIPIENT);
            assertEq(h.nonce(), 1);
            vm.revertToState(s2);

            // mixed, with a value transfer and a tip, 610 characters
            B.Call[] memory mx = new B.Call[](3);
            mx[0] = xfer(h, 1);
            mx[1] = B.Call(RECIPIENT, 1e15, "", 0);
            mx[2] = xfer(h, 2);
            bytes memory w3 = json.readBytes(at(i, ".cases.mixed_3.witness"));
            assertEq(
                string(h.batchMessage(mx, 1e16, 0, 2_000_000_000)), json.readString(at(i, ".cases.mixed_3.message"))
            );
            address relayer = makeAddr("relayer");
            vm.prank(relayer);
            h.executeBatch(mx, 1e16, 2_000_000_000, w3);
            assertEq(relayer.balance, 1e16);
            assertEq(BenchERC721(TOKEN).ownerOf(2), RECIPIENT);
            // a signature for another text is refused
            vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
            h.executeBatch(mx, 1e16, 2_000_000_000, w8);
            vm.revertToState(snap);
        }
    }

    /// The longest batch text (2,239 characters, every number at its maximum, nonce 2^256 - 1 forced into
    /// storage): the wallet's signature passes step 4, after which increasing the nonce overflows (a state
    /// no holder can reach). With a bad signature the same call stops at step 4 with BadSignature.
    function test_unisat_longest_text() public {
        for (uint256 i = 0; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            vm.chainId(type(uint64).max);
            B h = holderAt(json.readBytes(at(i, ".scriptPubKey")), json.readAddress(at(i, ".holder")));
            // nonce slot: 0 in the merged contract (gas lab O1 moved it from slot 1, where the batch lab had it)
            vm.store(address(h), bytes32(uint256(0)), bytes32(type(uint256).max));
            assertEq(h.nonce(), type(uint256).max);
            B.Call[] memory cs = new B.Call[](8);
            bytes memory x100 = new bytes(100);
            for (uint256 j = 0; j < 100; j++) {
                x100[j] = "x";
            }
            for (uint256 j = 0; j < 8; j++) {
                cs[j] = B.Call(address(type(uint160).max), type(uint256).max, x100, type(uint64).max);
            }
            bytes memory m = h.batchMessage(cs, type(uint256).max, type(uint256).max, type(uint64).max);
            assertEq(m.length, 2239);
            assertEq(string(m), json.readString(at(i, ".cases.longest.message")));
            bytes memory w = json.readBytes(at(i, ".cases.longest.witness"));
            vm.warp(1_800_000_000);
            vm.expectRevert(stdError.arithmeticError);
            h.executeBatch(cs, type(uint256).max, type(uint64).max, w);
            w[w.length - 40] ^= 0x01;
            vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
            h.executeBatch(cs, type(uint256).max, type(uint64).max, w);
            vm.revertToState(snap);
        }
    }
}
