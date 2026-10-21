// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {BitcoinKeyedHolder} from "../src/BitcoinKeyedHolder.sol";
import {BenchERC721} from "./batch/BenchERC721.sol";

/// Signatures that real wallets produced for the holders of the CURRENT creation code: the UniSat browser
/// extension 1.7.22 on 2026-10-10 (vectors/wallet-unisat-1.7.22.json, built by tools/make_wallet_vectors.py from
/// interop/unisat-extension/results/unisat-1.7.22-merged-*.json), and Xverse 2.9.3, Leather 6.114.0 and OKX 4.18.1
/// on 2026-10-11 (vectors/wallet-<name>-<version>.json, built by tools/make_wallet_matrix_vectors.py from
/// interop/wallet-matrix/results/). Each holder is deployed through the
/// deterministic deployment proxy at its CREATE2 address; the wallet's §5.1 signature passes isValidSignature,
/// its §5.2 signature moves a token through execute, and a second §5.2 signature (an empty call at nonce 1) goes
/// through as well.
contract WalletUnisatTest is Test {
    using stdJson for string;

    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes constant FACTORY_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    string json;

    function setUp() public {
        vm.etch(FACTORY, FACTORY_RUNTIME);
    }

    function load(string memory file) internal {
        json = vm.readFile(string.concat("../vectors/", file));
    }

    function p(uint256 i, string memory rest) internal pure returns (string memory) {
        return string.concat(".cases[", vm.toString(i), "]", rest);
    }

    function deploy(bytes memory spk) internal returns (BitcoinKeyedHolder) {
        bytes memory init = abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(spk));
        (bool ok, bytes memory ret) = FACTORY.call(abi.encodePacked(bytes32(0), init));
        require(ok && ret.length == 20, "factory");
        return BitcoinKeyedHolder(payable(address(bytes20(ret))));
    }

    function check(uint256 i) internal {
        vm.chainId(56);
        BitcoinKeyedHolder hd = deploy(json.readBytes(p(i, ".scriptPubKey")));
        assertEq(address(hd), json.readAddress(p(i, ".holder")), "CREATE2 address of the current build");

        // §5.1 through EIP-1271
        bytes32 digest = json.readBytes32(p(i, ".signDigest"));
        assertEq(hd.signMessage(digest), bytes(json.readString(p(i, ".signMessage"))));
        bytes memory w1 = json.readBytes(p(i, ".signWitness"));
        assertEq(hd.isValidSignature(digest, w1), bytes4(0x1626ba7e));
        assertEq(hd.isValidSignature(bytes32(uint256(digest) ^ 1), w1), bytes4(0xffffffff));
        bytes memory w1f = bytes.concat(w1);
        w1f[w1f.length - 2] ^= 0x01;
        assertEq(hd.isValidSignature(digest, w1f), bytes4(0xffffffff), "flipped byte");

        // §5.2: the wallet's signature moves an ERC-721 token out of the holder
        address target = json.readAddress(p(i, ".exec.target"));
        uint256 id = json.readUint(p(i, ".exec.tokenId"));
        address recipient = json.readAddress(p(i, ".exec.recipient"));
        bytes memory data = json.readBytes(p(i, ".exec.data"));
        uint256 callGas = json.readUint(p(i, ".exec.callGas"));
        uint64 deadline = uint64(json.readUint(p(i, ".exec.deadline")));
        bytes memory w2 = json.readBytes(p(i, ".exec.witness"));
        assertEq(hd.callMessage(target, 0, data, callGas, 0, 0, deadline), bytes(json.readString(p(i, ".exec.message"))));
        vm.etch(target, type(BenchERC721).runtimeCode);
        BenchERC721(target).mint(address(hd), id);
        uint64 dl2 = uint64(json.readUint(p(i, ".call.deadline")));
        vm.warp(deadline < dl2 ? deadline : dl2);
        hd.execute(target, 0, data, callGas, 0, deadline, w2);
        assertEq(BenchERC721(target).ownerOf(id), recipient);
        assertEq(hd.nonce(), 1);
        vm.expectRevert(BitcoinKeyedHolder.BadSignature.selector);
        hd.execute(target, 0, data, callGas, 0, deadline, w2);

        // §5.2 at nonce 1: an empty call to an address without code
        address t2 = json.readAddress(p(i, ".call.target"));
        bytes memory w3 = json.readBytes(p(i, ".call.witness"));
        assertEq(hd.callMessage(t2, 0, "", 0, 0, 1, dl2), bytes(json.readString(p(i, ".call.message"))));
        hd.execute(t2, 0, "", 0, 0, dl2, w3);
        assertEq(hd.nonce(), 2);
    }

    /// The holder of `spk`, deployed through the proxy unless it already is.
    function holderFor(bytes memory spk) internal returns (BitcoinKeyedHolder hd) {
        hd = BitcoinKeyedHolder(payable(computeCreate2Address(
            bytes32(0), keccak256(abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(spk))), FACTORY)));
        if (address(hd).code.length == 0) assertEq(address(deploy(spk)), address(hd));
    }

    /// Section 6.1 on raw wallet outputs (vectors.json walletRawOutputs): each §5.1 output, decoded from the base64
    /// string the wallet API gave (Xverse and Leather: JSON-RPC result.signature; OKX: the return value), passes
    /// isValidSignature on the holder; and OKX's default-type output, a 65-byte BIP-137 signature, is refused.
    function test_wallet_raw_outputs_and_bip137() public {
        string memory v = vm.readFile("../vectors/vectors.json");
        vm.chainId(56);
        bytes32 digest = bytes32(0xabababababababababababababababababababababababababababababababab);
        uint256 checked;
        for (uint256 i = 0; i < 12; i++) {
            string memory p_ = string.concat(".walletRawOutputs[", vm.toString(i), "]");
            if (bytes(v.readString(string.concat(p_, ".message"))).length != 156) continue; // the 4,000-character probes
            bytes memory spk = v.readBytes(string.concat(p_, ".scriptPubKey"));
            BitcoinKeyedHolder hd = holderFor(spk);
            assertEq(hd.signMessage(digest), bytes(v.readString(string.concat(p_, ".message"))));
            assertEq(hd.isValidSignature(digest, v.readBytes(string.concat(p_, ".expect"))), bytes4(0x1626ba7e));
            checked++;
        }
        assertEq(checked, 6);
        bytes memory bip137 = v.readBytes(".walletBip137Default.decoded");
        assertEq(bip137.length, 65);
        BitcoinKeyedHolder wp = holderFor(v.readBytes(".walletBip137Default.scriptPubKey"));
        assertEq(wp.signMessage(digest), bytes(v.readString(".walletBip137Default.message")));
        assertEq(wp.isValidSignature(digest, bip137), bytes4(0xffffffff));
    }

    function test_unisat_p2tr() public {
        load("wallet-unisat-1.7.22.json");
        check(0);
    }

    function test_unisat_p2wpkh() public {
        load("wallet-unisat-1.7.22.json");
        check(1);
    }

    // wallet matrix (2026-10-11): vectors/wallet-<name>-<version>.json, tools/make_wallet_matrix_vectors.py

    function test_xverse_p2tr() public {
        load("wallet-xverse-2.9.3.json");
        check(0);
    }

    function test_xverse_p2wpkh() public {
        load("wallet-xverse-2.9.3.json");
        check(1);
    }

    function test_leather_p2tr() public {
        load("wallet-leather-6.114.0.json");
        check(0);
    }

    function test_leather_p2wpkh() public {
        load("wallet-leather-6.114.0.json");
        check(1);
    }

    function test_okx_p2tr() public {
        load("wallet-okx-4.18.1.json");
        check(0);
    }

    function test_okx_p2wpkh() public {
        load("wallet-okx-4.18.1.json");
        check(1);
    }
}
