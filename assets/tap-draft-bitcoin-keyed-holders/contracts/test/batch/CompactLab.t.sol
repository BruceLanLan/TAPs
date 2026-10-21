// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BitcoinKeyedHolder} from "../../src/BitcoinKeyedHolder.sol";
import {HolderCompactLab} from "./CompactLab.sol";
import {AuditSigner as S} from "../AuditLib.sol";
import {BenchERC721} from "./BenchERC721.sol";

/// The measurement prototype behaves like execute for the same signature (it is not proposed).
contract CompactLabTest is Test {
    uint256 constant PRIV = 0xB0B;
    uint64 constant DL = 2_000_000_000;

    function test_packed_equals_execute() public {
        (, bytes20 kh) = S.wpPubkey(PRIV);
        HolderCompactLab hd = new HolderCompactLab(S.wpSpk(kh));
        BenchERC721 nft = new BenchERC721();
        nft.mint(address(hd), 1);
        nft.mint(address(hd), 2);
        bytes memory d1 = abi.encodeCall(nft.safeTransferFrom, (address(hd), address(0xb0), 1));
        bytes memory s1 = S.signP2WPKH(PRIV, hd.callMessage(address(nft), 0, d1, 100_000, 0, 0, DL));
        bytes memory packed = abi.encodePacked(
            hd.TAG(), address(nft), uint96(0), uint32(100_000), uint96(0), uint32(DL), uint16(d1.length), d1, s1
        );
        assertEq(packed.length, 58 + d1.length + s1.length);
        (bool ok,) = address(hd).call(packed);
        assertTrue(ok);
        assertEq(nft.ownerOf(1), address(0xb0));
        (ok,) = address(hd).call(packed); // replay
        assertFalse(ok);
        bytes memory d2 = abi.encodeCall(nft.safeTransferFrom, (address(hd), address(0xb0), 2));
        bytes memory s2 = S.signP2WPKH(PRIV, hd.callMessage(address(nft), 0, d2, 100_000, 0, 1, DL));
        hd.execute(address(nft), 0, d2, 100_000, 0, DL, s2);
        assertEq(hd.nonce(), 2);
        (ok,) = address(hd).call(hex"00112233");
        assertFalse(ok);
    }
}
