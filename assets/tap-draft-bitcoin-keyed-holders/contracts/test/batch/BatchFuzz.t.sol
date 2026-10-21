// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BitcoinKeyedHolder as B} from "../../src/BitcoinKeyedHolder.sol";
import {GeneratedBatchVectors as BV} from "./GeneratedBatchVectors.sol";

/// Injectivity of the batch message (§5.3): the text parses back to exactly the batch that produced it,
/// equals an independent rendering, is printable ASCII, and two different batches never give the same text.
contract BatchFuzzTest is Test {
    B hd;

    struct Batch {
        uint256 chain;
        B.Call[] calls;
        uint256 tip;
        uint256 nonce;
        uint64 deadline;
    }

    struct Parsed {
        address holder;
        uint256 chain;
        address[] targets;
        uint256[] values;
        bytes32[] dataHashes;
        uint256[] gases;
        uint256 tip;
        uint256 nonce;
        uint256 deadline;
    }

    struct Seeds {
        uint8 n;
        address[8] targets;
        uint256[8] values;
        uint256[8] gases;
        bytes32[8] data;
        uint8[8] dataLen;
        uint256 tip;
        uint256 nonce;
        uint64 deadline;
        uint64 chain;
        uint8 small; // bit mask: shrink numbers so that digit-boundary shifts are likely
    }

    function setUp() public {
        hd = new B(BV.SPK_P2TR);
    }

    // ------------------------------------------------------------------ building

    function shrink(uint256 v, uint8 small, uint8 bit) internal pure returns (uint256) {
        return (small >> bit) & 1 == 1 ? v % 1000 : v;
    }

    function build(Seeds memory s) internal pure returns (Batch memory b) {
        uint256 n = 1 + uint256(s.n) % 8;
        b.calls = new B.Call[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes memory d = new bytes(uint256(s.dataLen[i]) % 40);
            for (uint256 j = 0; j < d.length; j++) {
                d[j] = s.data[i][j % 32];
            }
            b.calls[i] = B.Call(s.targets[i], shrink(s.values[i], s.small, 0), d, shrink(s.gases[i], s.small, 1));
        }
        b.chain = s.chain == 0 ? 1 : s.chain;
        b.tip = shrink(s.tip, s.small, 2);
        b.nonce = shrink(s.nonce, s.small, 3);
        b.deadline = s.deadline;
    }

    function render(Batch memory b) internal returns (bytes memory) {
        vm.chainId(b.chain);
        return hd.batchMessage(b.calls, b.tip, b.nonce, b.deadline);
    }

    function sameBatch(Batch memory a, Batch memory b) internal pure returns (bool) {
        if (a.chain != b.chain || a.tip != b.tip || a.nonce != b.nonce || a.deadline != b.deadline) return false;
        if (a.calls.length != b.calls.length) return false;
        for (uint256 i = 0; i < a.calls.length; i++) {
            B.Call memory x = a.calls[i];
            B.Call memory y = b.calls[i];
            if (x.target != y.target || x.value != y.value || x.callGas != y.callGas) return false;
            if (keccak256(x.data) != keccak256(y.data)) return false;
        }
        return true;
    }

    // ------------------------------------------------------------------ an independent parser

    function expectLit(bytes memory m, uint256 i, string memory lit) internal pure returns (uint256) {
        bytes memory l = bytes(lit);
        require(i + l.length <= m.length, "short");
        for (uint256 j = 0; j < l.length; j++) {
            require(m[i + j] == l[j], "literal");
        }
        return i + l.length;
    }

    function readHex(bytes memory m, uint256 i, uint256 digits) internal pure returns (uint256 v, uint256 next) {
        require(i + digits <= m.length, "short hex");
        for (uint256 j = 0; j < digits; j++) {
            uint8 c = uint8(m[i + j]);
            uint8 d;
            if (c >= 0x30 && c <= 0x39) d = c - 0x30;
            else if (c >= 0x61 && c <= 0x66) d = c - 0x61 + 10;
            else revert("hex digit");
            v = v * 16 + d;
        }
        next = i + digits;
    }

    function readDec(bytes memory m, uint256 i) internal pure returns (uint256 v, uint256 next) {
        uint256 start = i;
        while (i < m.length && m[i] >= 0x30 && m[i] <= 0x39) {
            v = v * 10 + (uint8(m[i]) - 0x30);
            i++;
        }
        require(i > start, "no digits");
        require(m[start] != "0" || i == start + 1, "leading zero");
        next = i;
    }

    function parse(bytes memory m) internal pure returns (Parsed memory p) {
        uint256 i = expectLit(m, 0, "TapeOut Bitcoin-keyed holder 0x");
        uint256 v;
        (v, i) = readHex(m, i, 40);
        p.holder = address(uint160(v));
        i = expectLit(m, i, " on chain ");
        (p.chain, i) = readDec(m, i);
        i = expectLit(m, i, " makes ");
        uint256 k;
        (k, i) = readDec(m, i);
        require(k >= 1 && k <= 8, "k");
        i = expectLit(m, i, " calls:");
        p.targets = new address[](k);
        p.values = new uint256[](k);
        p.dataHashes = new bytes32[](k);
        p.gases = new uint256[](k);
        for (uint256 c = 0; c < k; c++) {
            i = expectLit(m, i, " (");
            uint256 idx;
            (idx, i) = readDec(m, i);
            require(idx == c + 1, "index");
            i = expectLit(m, i, ") 0x");
            (v, i) = readHex(m, i, 40);
            p.targets[c] = address(uint160(v));
            i = expectLit(m, i, " with value ");
            (p.values[c], i) = readDec(m, i);
            i = expectLit(m, i, " and data 0x");
            (v, i) = readHex(m, i, 64);
            p.dataHashes[c] = bytes32(v);
            i = expectLit(m, i, ", gas ");
            (p.gases[c], i) = readDec(m, i);
            i = expectLit(m, i, ";");
        }
        i = expectLit(m, i, " tip ");
        (p.tip, i) = readDec(m, i);
        i = expectLit(m, i, ", nonce ");
        (p.nonce, i) = readDec(m, i);
        i = expectLit(m, i, ", valid until ");
        (p.deadline, i) = readDec(m, i);
        require(i == m.length, "trailing bytes");
    }

    // ------------------------------------------------------------------ an independent renderer

    function hexOf(bytes memory b) internal pure returns (string memory) {
        bytes memory s = bytes(vm.toString(b)); // 0x-prefixed lowercase
        bytes memory out = new bytes(s.length - 2);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = s[i + 2];
        }
        return string(out);
    }

    function renderSpec(Batch memory b) internal view returns (string memory s) {
        s = string.concat(
            "TapeOut Bitcoin-keyed holder 0x",
            hexOf(abi.encodePacked(address(hd))),
            " on chain ",
            vm.toString(b.chain),
            " makes ",
            vm.toString(b.calls.length),
            " calls:"
        );
        for (uint256 i = 0; i < b.calls.length; i++) {
            s = string.concat(
                s,
                " (",
                vm.toString(i + 1),
                ") 0x",
                hexOf(abi.encodePacked(b.calls[i].target)),
                " with value ",
                vm.toString(b.calls[i].value),
                " and data 0x",
                hexOf(abi.encodePacked(keccak256(b.calls[i].data))),
                ", gas ",
                vm.toString(b.calls[i].callGas),
                ";"
            );
        }
        s = string.concat(
            s,
            " tip ",
            vm.toString(b.tip),
            ", nonce ",
            vm.toString(b.nonce),
            ", valid until ",
            vm.toString(uint256(b.deadline))
        );
    }

    // ------------------------------------------------------------------ properties

    /// The text parses back to the batch, matches an independent rendering and is printable ASCII.
    /// Parsing back without ambiguity means the encoding is injective.
    /// forge-config: default.fuzz.runs = 100000
    function testFuzz_batch_text_parses_back(Seeds memory s) public {
        Batch memory b = build(s);
        bytes memory m = render(b);
        assertEq(string(m), renderSpec(b));
        Parsed memory p = parse(m);
        assertEq(p.holder, address(hd));
        assertEq(p.chain, b.chain);
        assertEq(p.targets.length, b.calls.length);
        for (uint256 i = 0; i < b.calls.length; i++) {
            assertEq(p.targets[i], b.calls[i].target);
            assertEq(p.values[i], b.calls[i].value);
            assertEq(p.dataHashes[i], keccak256(b.calls[i].data));
            assertEq(p.gases[i], b.calls[i].callGas);
        }
        assertEq(p.tip, b.tip);
        assertEq(p.nonce, b.nonce);
        assertEq(p.deadline, b.deadline);
        for (uint256 i = 0; i < m.length; i++) {
            assertTrue(uint8(m[i]) >= 0x20 && uint8(m[i]) < 0x7f, "printable ASCII");
        }
        // and never collides with the other two message kinds (they continue " signs 0x" / " calls 0x")
        assertEq(m[81 + bytes(vm.toString(b.chain)).length + 1], bytes1("m"));
    }

    /// Distinct batches give distinct texts, and equal batches equal texts: one field of one call (or the
    /// tip, nonce, deadline, chain or the number of calls) changed, or two calls swapped.
    /// forge-config: default.fuzz.runs = 100000
    function testFuzz_mutation_changes_text(Seeds memory s, uint8 what, uint8 at, uint8 at2, uint256 nv) public {
        Batch memory a = build(s);
        Batch memory b = build(s);
        uint256 n = a.calls.length;
        uint256 i = uint256(at) % n;
        uint256 j = uint256(at2) % n;
        uint256 w = uint256(what) % 11;
        if ((what >> 7) & 1 == 1) nv %= 1000; // small replacement values too
        if (w == 0) {
            b.calls[i].target = address(uint160(nv));
        } else if (w == 1) {
            b.calls[i].value = nv;
        } else if (w == 2) {
            b.calls[i].data = abi.encodePacked(b.calls[i].data, bytes1(uint8(nv)));
        } else if (w == 3) {
            b.calls[i].callGas = nv;
        } else if (w == 4) {
            (b.calls[i], b.calls[j]) = (b.calls[j], b.calls[i]);
        } else if (w == 5) {
            b.tip = nv;
        } else if (w == 6) {
            b.nonce = nv;
        } else if (w == 7) {
            b.deadline = uint64(nv);
        } else if (w == 8) {
            b.chain = nv % (1 << 64) == 0 ? 1 : nv % (1 << 64);
        } else if (w == 9 && n > 1) {
            B.Call[] memory shorter = new B.Call[](n - 1);
            for (uint256 x = 0; x < n - 1; x++) {
                shorter[x] = b.calls[x];
            }
            b.calls = shorter;
        } else if (w == 10 && n < 8) {
            B.Call[] memory longer = new B.Call[](n + 1);
            for (uint256 x = 0; x < n; x++) {
                longer[x] = b.calls[x];
            }
            longer[n] = b.calls[i];
            b.calls = longer;
        }
        bool same = sameBatch(a, b);
        bool sameText = keccak256(render(a)) == keccak256(render(b));
        assertEq(same, sameText);
    }

    /// Two independently drawn batches: equal texts exactly when the batches are equal.
    /// forge-config: default.fuzz.runs = 100000
    function testFuzz_independent_batches(Seeds memory s1, Seeds memory s2) public {
        Batch memory a = build(s1);
        Batch memory b = build(s2);
        assertEq(sameBatch(a, b), keccak256(render(a)) == keccak256(render(b)));
    }
}
