// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProfiledHolder} from "./ProfiledHolder.sol";
import {BaselineVectors as V} from "../baseline/BaselineVectors.sol";

contract ProfileToken {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && msg.sender == from, "not owner");
        ownerOf[id] = to;
    }
}

/// Per-step gas of the BASELINE holder (lab only). The instrumented copy is placed at the baseline
/// holder's own address so that the baseline vectors' signatures verify.
/// Run: forge test --match-contract GasProfile -vv
contract GasProfile is Test {
    function deployTo(address at, bytes memory spk) internal returns (ProfiledHolder) {
        vm.etch(at, abi.encodePacked(type(ProfiledHolder).creationCode, abi.encode(spk)));
        (bool ok, bytes memory rt) = at.call("");
        require(ok, "ctor");
        vm.etch(at, rt);
        return ProfiledHolder(payable(at));
    }

    function show(string[] memory labels, uint256[40] memory g, uint256 n) internal {
        require(labels.length == n - 1, "labels");
        uint256 sum;
        for (uint256 i = 1; i < n; i++) {
            emit log_named_uint(labels[i - 1], g[i - 1] - g[i]);
            sum += g[i - 1] - g[i];
        }
        emit log_named_uint("= sum of steps", sum);
    }

    function trLabels() internal pure returns (string[] memory l) {
        l = new string[](12);
        l[0] = "prefix: hex(holder) + dec(chainid) + encodePacked";
        l[1] = "hex(digest) (Solidity loop)";
        l[2] = "message concat (encodePacked)";
        l[3] = "witness calldata->memory copy (in the real code: at the call)";
        l[4] = "witness checks + spk encodePacked";
        l[5] = "BIP-322 messageHash: tagged sha256 of message";
        l[6] = "to_spend serialisation + sha256d";
        l[7] = "BIP-341 sighash: 5 inner sha256 + tagged sha256";
        l[8] = "BIP-340 challenge: tagged sha256 + mod n";
        l[9] = "BIP-340 ecrecover (3,000 + call)";
        l[10] = "BIP-340 lift_x(r) via modexp (1,349 + call)";
        l[11] = "keccak(R) + address compare";
    }

    function wpLabels() internal pure returns (string[] memory l) {
        l = new string[](13);
        l[0] = "prefix: hex(holder) + dec(chainid) + encodePacked";
        l[1] = "hex(digest) (Solidity loop)";
        l[2] = "message concat (encodePacked)";
        l[3] = "witness calldata->memory copy (in the real code: at the call)";
        l[4] = "DER parsing (byte loops, bounds checks)";
        l[5] = "copy 33-byte key byte by byte";
        l[6] = "hash160 of key (sha256 + ripemd160)";
        l[7] = "lift_x(key) via modexp + keccak(Q)";
        l[8] = "BIP-322 messageHash: tagged sha256 of message";
        l[9] = "to_spend serialisation + sha256d";
        l[10] = "BIP-143 sighash: 3 x sha256d + sha256d of preimage";
        l[11] = "ecrecover v=27";
        l[12] = "ecrecover v=28 (0 if v=27 matched)";
    }

    function profileSign(uint256 k) internal {
        V.SignCase memory c = V.signCases()[k];
        vm.chainId(c.chainId);
        bool tr = c.holder == 0;
        ProfiledHolder p = deployTo(tr ? V.HOLDER_P2TR : V.HOLDER_P2WPKH, tr ? V.SPK_P2TR : V.SPK_P2WPKH);
        (uint256[40] memory g, uint256 n) = p.profileIsValid(c.digest, c.sig);
        show(tr ? trLabels() : wpLabels(), g, n);
    }

    function test_profile_isValidSignature_p2tr() public {
        profileSign(0);
    }

    function test_profile_isValidSignature_p2wpkh() public {
        profileSign(1);
    }

    function profileExec(uint256 k) internal {
        V.CallCase memory c = V.callCases()[k];
        vm.chainId(56);
        bool tr = c.holder == 0;
        ProfiledHolder p = deployTo(tr ? V.HOLDER_P2TR : V.HOLDER_P2WPKH, tr ? V.SPK_P2TR : V.SPK_P2WPKH);
        vm.etch(c.target, type(ProfileToken).runtimeCode);
        ProfileToken(c.target).mint(address(p), 1);
        ProfileToken(c.target).mint(address(p), 7);
        vm.deal(address(p), 1 ether);
        address relayer = makeAddr("relayer");
        vm.deal(relayer, 1 ether);
        vm.warp(c.deadline);
        vm.prank(relayer);
        (uint256[40] memory g, uint256 n) = p.profileExecute(c.target, c.value, c.data, c.gas, c.tip, c.deadline, c.sig);
        string[] memory v = tr ? trLabels() : wpLabels();
        string[] memory l = new string[](n - 1);
        l[0] = "deadline check + SLOAD nonce (cold)";
        l[1] = "prefix: hex(holder) + dec(chainid) + encodePacked";
        l[2] = "hex(target)";
        l[3] = "dec(value)";
        l[4] = "keccak256(data)";
        l[5] = "hex(dataHash)";
        l[6] = "dec(callGas, callTip, nonce, deadline)";
        l[7] = "message concat (encodePacked, 14 parts)";
        uint256 j = 8;
        for (uint256 i = 3; i < v.length; i++) l[j++] = v[i];
        l[j++] = "NoCode check (cold EXTCODESIZE of target)";
        l[j++] = "SSTORE nonce 0->1 (cold, 22,100)";
        l[j++] = "gas floor check";
        l[j++] = "CALL target (cold) incl. callee execution";
        l[j++] = "tip transfer";
        l[j++] = "emit Called (keccak(data) again + LOG3)";
        show(l, g, n);
    }

    function test_profile_execute_erc721_p2tr() public {
        profileExec(0);
    }

    function test_profile_execute_erc721_p2wpkh() public {
        profileExec(1);
    }

    function test_profile_execute_tip_p2wpkh() public {
        profileExec(3);
    }
}
