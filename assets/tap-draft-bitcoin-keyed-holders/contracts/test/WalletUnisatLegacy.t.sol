// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BitcoinKeyedHolder} from "../src/BitcoinKeyedHolder.sol";
import {BaselineCode} from "./baseline/BaselineCode.sol";

contract LegacyWalletToken {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && msg.sender == from, "not owner");
        ownerOf[id] = to;
    }
}

/// LEGACY: signatures that a real wallet (UniSat extension 1.7.22, 2026-10-09) produced for the holder addresses of
/// the earlier draft's creation code (vectors/legacy/wallet-unisat-1.7.22-draft-834787a.json). Kept because they
/// show that real wallet output for the pre-merge addresses verifies on the merged verifier. The vectors for the
/// current addresses are vectors/wallet-unisat-1.7.22.json (WalletUnisatTest).
contract WalletUnisatLegacyTest is Test {
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes constant FACTORY_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    function setUp() public {
        vm.etch(FACTORY, FACTORY_RUNTIME);
    }

    function deploy(bytes memory spk) internal returns (BitcoinKeyedHolder) {
        bytes memory init = abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(spk));
        (bool ok, bytes memory ret) = FACTORY.call(abi.encodePacked(bytes32(0), init));
        require(ok && ret.length == 20, "factory");
        return BitcoinKeyedHolder(payable(address(bytes20(ret))));
    }

    /// Gas lab: the wallet signed messages that name the holder of the BASELINE creation code (lab
    /// commit 834787a, the bytes the wallet run of 2026-10-09 used). Check that address against the
    /// baseline bytes, then run the CURRENT code at it, so the wallet's real signatures are checked
    /// against the current verifier. Re-signing with the wallet for new addresses needs the extension.
    function holderAt(bytes memory spk, address recorded) internal returns (BitcoinKeyedHolder) {
        bytes memory baseInit = abi.encodePacked(BaselineCode.creationCode(), abi.encode(spk));
        assertEq(computeCreate2Address(bytes32(0), keccak256(baseInit), FACTORY), recorded, "baseline address");
        if (keccak256(type(BitcoinKeyedHolder).creationCode) == BaselineCode.KECCAK) return deploy(spk);
        vm.etch(recorded, abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(spk)));
        (bool ok, bytes memory rt) = recorded.call("");
        require(ok, "constructor");
        vm.etch(recorded, rt);
        return BitcoinKeyedHolder(payable(recorded));
    }

    function check(uint256 i) internal {
        string memory j = vm.readFile("../vectors/legacy/wallet-unisat-1.7.22-draft-834787a.json");
        string memory p = string.concat(".cases[", vm.toString(i), "]");
        vm.chainId(uint64(vm.parseJsonUint(j, string.concat(p, ".chainId"))));
        BitcoinKeyedHolder hd =
            holderAt(vm.parseJsonBytes(j, string.concat(p, ".scriptPubKey")), vm.parseJsonAddress(j, string.concat(p, ".holder")));

        // the wallet's text for the §5.1 message equals ours, and the wallet's signature is accepted
        bytes32 digest = vm.parseJsonBytes32(j, string.concat(p, ".signDigest"));
        assertEq(hd.signMessage(digest), bytes(vm.parseJsonString(j, string.concat(p, ".signMessage"))));
        bytes memory w1 = vm.parseJsonBytes(j, string.concat(p, ".signWitness"));
        assertEq(hd.isValidSignature(digest, w1), bytes4(0x1626ba7e));
        assertEq(hd.isValidSignature(bytes32(uint256(digest) ^ 1), w1), bytes4(0xffffffff));

        // a call signed by the wallet moves a token
        address target = vm.parseJsonAddress(j, string.concat(p, ".exec.target"));
        uint256 id = vm.parseJsonUint(j, string.concat(p, ".exec.tokenId"));
        address recipient = vm.parseJsonAddress(j, string.concat(p, ".exec.recipient"));
        bytes memory data = vm.parseJsonBytes(j, string.concat(p, ".exec.data"));
        uint256 callGas = vm.parseJsonUint(j, string.concat(p, ".exec.callGas"));
        uint64 deadline = uint64(vm.parseJsonUint(j, string.concat(p, ".exec.deadline")));
        bytes memory w2 = vm.parseJsonBytes(j, string.concat(p, ".exec.witness"));
        assertEq(
            hd.callMessage(target, 0, data, callGas, 0, 0, deadline),
            bytes(vm.parseJsonString(j, string.concat(p, ".exec.message")))
        );
        vm.etch(target, type(LegacyWalletToken).runtimeCode);
        LegacyWalletToken(target).mint(address(hd), id);
        vm.warp(deadline);
        hd.execute(target, 0, data, callGas, 0, deadline, w2);
        assertEq(LegacyWalletToken(target).ownerOf(id), recipient);
        // the same signature cannot be used twice
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(target, 0, data, callGas, 0, deadline, w2);
    }

    function test_unisat_p2tr() public {
        check(0);
    }

    function test_unisat_p2wpkh() public {
        check(1);
    }
}
