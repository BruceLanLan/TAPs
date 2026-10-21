// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BitcoinKeyedHolder} from "../src/BitcoinKeyedHolder.sol";
import {GeneratedVectors as V} from "./GeneratedVectors.sol";
import {HolderExposed} from "./AuditLib.sol";

/// Audit tests for the §5 message formats: formatting correctness, injectivity, no collision
/// between the two message kinds, uniqueness across holder and chain.
contract AuditMessagesTest is Test {
    HolderExposed hd;

    function setUp() public {
        hd = new HolderExposed(V.SPK_P2TR);
    }

    function lower(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] >= 0x41 && b[i] <= 0x5a) b[i] = bytes1(uint8(b[i]) + 32);
        }
        return string(b);
    }

    function hex40(address a) internal pure returns (string memory) {
        // vm.toString(bytes) gives 0x-prefixed lowercase hex
        bytes memory s = bytes(vm.toString(abi.encodePacked(a)));
        bytes memory out = new bytes(40);
        for (uint256 i = 0; i < 40; i++) {
            out[i] = s[i + 2];
        }
        return string(out);
    }

    function hex64(bytes32 b) internal pure returns (string memory) {
        bytes memory s = bytes(vm.toString(abi.encodePacked(b)));
        bytes memory out = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            out[i] = s[i + 2];
        }
        return string(out);
    }

    // --------------------------------------------------------------- formatting helpers

    function testFuzz_dec_matches_reference(uint256 v) public view {
        assertEq(string(hd.dec(v)), vm.toString(v));
    }

    function test_dec_extremes() public view {
        assertEq(string(hd.dec(0)), "0");
        assertEq(string(hd.dec(type(uint64).max)), "18446744073709551615");
        assertEq(
            string(hd.dec(type(uint256).max)),
            "115792089237316195423570985008687907853269984665640564039457584007913129639935"
        );
    }

    function testFuzz_hex_matches_reference(bytes memory b) public view {
        bytes memory got = hd.hex_(b);
        bytes memory want = bytes(vm.toString(b));
        assertEq(got.length, 2 * b.length);
        for (uint256 i = 0; i < got.length; i++) {
            assertEq(got[i], want[i + 2]);
        }
    }

    // --------------------------------------------------------------- the two message kinds, against an
    // independent rendering of §5 using forge's string tools

    function testFuzz_signMessage_matches_spec(bytes32 digest, uint64 chain) public {
        vm.assume(chain != 0);
        vm.chainId(chain);
        string memory want = string.concat(
            "TapeOut Bitcoin-keyed holder 0x",
            hex40(address(hd)),
            " on chain ",
            vm.toString(uint256(chain)),
            " signs 0x",
            hex64(digest)
        );
        assertEq(string(hd.signMessage(digest)), want);
    }

    function testFuzz_callMessage_matches_spec(
        address target,
        uint256 value,
        bytes memory data,
        uint256 callGas,
        uint256 callTip,
        uint256 n,
        uint64 deadline,
        uint64 chain
    ) public {
        vm.assume(chain != 0);
        vm.chainId(chain);
        string memory want = string.concat(
            "TapeOut Bitcoin-keyed holder 0x",
            hex40(address(hd)),
            " on chain ",
            vm.toString(uint256(chain)),
            " calls 0x",
            hex40(target),
            " with value ",
            vm.toString(value),
            " and data 0x",
            hex64(keccak256(data)),
            ", gas ",
            vm.toString(callGas),
            ", tip ",
            vm.toString(callTip),
            ", nonce ",
            vm.toString(n),
            ", valid until ",
            vm.toString(uint256(deadline))
        );
        assertEq(string(hd.callMessage(target, value, data, callGas, callTip, n, deadline)), want);
    }

    /// The gas amount is part of the signed message, rendered in decimal between the data hash and
    /// the tip; a gas of zero is rendered as "0", not omitted.
    function test_callMessage_contains_gas() public view {
        address t = address(0xBEEF);
        bytes memory m = hd.callMessage(t, 0, "", 123_456, 0, 7, 99);
        bytes memory tail =
            abi.encodePacked(" and data 0x", hex64(keccak256("")), ", gas 123456, tip 0, nonce 7, valid until 99");
        assertEq(string(suffix(m, tail.length)), string(tail));
        m = hd.callMessage(t, 0, "", 0, 0, 7, 99);
        tail = abi.encodePacked(" and data 0x", hex64(keccak256("")), ", gas 0, tip 0, nonce 7, valid until 99");
        assertEq(string(suffix(m, tail.length)), string(tail));
    }

    /// The tip is rendered in decimal wei between the gas and the nonce; a tip of zero is rendered as
    /// "tip 0", not omitted, so a no-tip message is never the same string as the old tipless format.
    function test_callMessage_contains_tip() public view {
        address t = address(0xBEEF);
        bytes memory m = hd.callMessage(t, 0, "", 21_000, 1_000_000_000_000_000, 7, 99);
        bytes memory tail = abi.encodePacked(
            " and data 0x", hex64(keccak256("")), ", gas 21000, tip 1000000000000000, nonce 7, valid until 99"
        );
        assertEq(string(suffix(m, tail.length)), string(tail));
        m = hd.callMessage(t, 0, "", 21_000, type(uint256).max, 7, 99);
        tail = abi.encodePacked(
            ", tip 115792089237316195423570985008687907853269984665640564039457584007913129639935, nonce 7, valid until 99"
        );
        assertEq(string(suffix(m, tail.length)), string(tail));
    }

    function suffix(bytes memory b, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = b[b.length - n + i];
        }
    }

    // --------------------------------------------------------------- injectivity

    function testFuzz_callMessage_injective(
        address t1,
        uint256 v1,
        bytes memory d1,
        uint256 g1,
        uint256 p1,
        uint256 n1,
        uint64 dl1,
        address t2,
        uint256 v2,
        bytes memory d2,
        uint256 g2,
        uint256 p2,
        uint256 n2,
        uint64 dl2
    ) public view {
        bool same = t1 == t2 && v1 == v2 && keccak256(d1) == keccak256(d2) && g1 == g2 && p1 == p2 && n1 == n2
            && dl1 == dl2;
        bytes32 m1 = keccak256(hd.callMessage(t1, v1, d1, g1, p1, n1, dl1));
        bytes32 m2 = keccak256(hd.callMessage(t2, v2, d2, g2, p2, n2, dl2));
        assertEq(m1 == m2, same);
    }

    /// Changing only the gas changes the message (so it invalidates the signature over it).
    function testFuzz_callMessage_gas_is_bound(
        address t,
        uint256 v,
        bytes memory d,
        uint256 g1,
        uint256 g2,
        uint256 p,
        uint256 n,
        uint64 dl
    ) public view {
        vm.assume(g1 != g2);
        assertTrue(keccak256(hd.callMessage(t, v, d, g1, p, n, dl)) != keccak256(hd.callMessage(t, v, d, g2, p, n, dl)));
    }

    /// Changing only the tip changes the message (so it invalidates the signature over it).
    function testFuzz_callMessage_tip_is_bound(
        address t,
        uint256 v,
        bytes memory d,
        uint256 g,
        uint256 p1,
        uint256 p2,
        uint256 n,
        uint64 dl
    ) public view {
        vm.assume(p1 != p2);
        assertTrue(keccak256(hd.callMessage(t, v, d, g, p1, n, dl)) != keccak256(hd.callMessage(t, v, d, g, p2, n, dl)));
    }

    /// Gas and tip are adjacent decimal fields: swapping them (or moving digits between them) gives a
    /// different message, because each is introduced by its own literal.
    function testFuzz_callMessage_gas_tip_not_swappable(
        address t,
        uint256 v,
        bytes memory d,
        uint256 g,
        uint256 p,
        uint256 n,
        uint64 dl
    ) public view {
        vm.assume(g != p);
        assertTrue(keccak256(hd.callMessage(t, v, d, g, p, n, dl)) != keccak256(hd.callMessage(t, v, d, p, g, n, dl)));
    }

    function testFuzz_signMessage_injective(bytes32 a, bytes32 b) public view {
        assertEq(keccak256(hd.signMessage(a)) == keccak256(hd.signMessage(b)), a == b);
    }

    /// A §5.1 message can never equal a §5.2 message: the literal after the prefix differs.
    function testFuzz_kinds_never_collide(
        bytes32 digest,
        address t,
        uint256 v,
        bytes memory d,
        uint256 g,
        uint256 p,
        uint256 n,
        uint64 dl
    ) public view {
        bytes memory s = hd.signMessage(digest);
        bytes memory c = hd.callMessage(t, v, d, g, p, n, dl);
        assertTrue(keccak256(s) != keccak256(c));
        // the sign message is always exactly prefix + 9 + 64 bytes; the call message is longer
        assertTrue(c.length > s.length);
    }

    /// Messages differ across chains and across holders for the same payload.
    function testFuzz_unique_per_chain_and_holder(bytes32 digest, uint64 c1, uint64 c2) public {
        vm.assume(c1 != 0 && c2 != 0 && c1 != c2);
        HolderExposed other = new HolderExposed(V.SPK_P2TR);
        vm.chainId(c1);
        bytes memory a = hd.signMessage(digest);
        bytes memory b = other.signMessage(digest);
        vm.chainId(c2);
        bytes memory a2 = hd.signMessage(digest);
        assertTrue(keccak256(a) != keccak256(b), "holder");
        assertTrue(keccak256(a) != keccak256(a2), "chain");
    }

    /// Chain-id prefix ambiguity: "on chain 5" + " signs" vs "on chain 56": distinct because the
    /// field after the chain id starts with a space, never a digit. Checked by parsing back.
    function testFuzz_message_parses_uniquely(bytes32 digest, uint64 chain) public {
        vm.assume(chain != 0);
        vm.chainId(chain);
        bytes memory m = hd.signMessage(digest);
        // the prefix literal is 31 bytes, address hex 40, " on chain " 10 => chain id digits start at 81
        uint256 i = 81;
        uint256 parsed;
        while (i < m.length && m[i] >= 0x30 && m[i] <= 0x39) {
            parsed = parsed * 10 + (uint8(m[i]) - 48);
            i++;
        }
        assertEq(parsed, chain);
        assertEq(m[i], bytes1(" "));
        assertEq(m.length, i + 9 + 64);
    }

    /// Message bytes are 7-bit ASCII only.
    function testFuzz_ascii(
        bytes32 digest,
        address t,
        uint256 v,
        bytes memory d,
        uint256 g,
        uint256 p,
        uint256 n,
        uint64 dl
    ) public view {
        bytes memory m = abi.encodePacked(hd.signMessage(digest), hd.callMessage(t, v, d, g, p, n, dl));
        for (uint256 i = 0; i < m.length; i++) {
            assertTrue(uint8(m[i]) >= 0x20 && uint8(m[i]) < 0x7f);
        }
    }
}
