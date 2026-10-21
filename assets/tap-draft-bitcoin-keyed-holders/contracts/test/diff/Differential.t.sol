// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {BitcoinKeyedHolder} from "../../src/BitcoinKeyedHolder.sol";
import {BaselineCode} from "../baseline/BaselineCode.sol";
import {BaselineVectors as V} from "../baseline/BaselineVectors.sol";
import {DSign, RefLib, OptLib} from "./DiffLib.sol";
import {DToken, DReverter, DReturner, DProbe, DRelayer} from "./DiffTargets.sol";

/// Differential tests: the BASELINE creation code (the bytes pinned at lab commit 834787a) and the
/// CURRENT source run on the same inputs, at the same address, from the same state, and must give
/// the same results. Each side is installed by running its creation code at the address (constructor
/// storage writes land there) and then etching the runtime code it returns; between the two sides
/// the state is reverted to a snapshot. Gas used is the only thing allowed to differ; see
/// testFuzz_diff_execute for the exact rule when the outer gas is tight.
contract DifferentialTest is Test {
    uint256 constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    address constant X = 0x5eeD00000000000000000000000000000000B0B1; // holder address for random keys
    bytes4 constant INSUFFICIENT_GAS = 0x1c26714c;
    bytes4 constant TIP_FAILED = 0xd99123cb;
    uint256 constant T = 1_800_000_000;

    struct Out {
        bool ok;
        bytes ret;
        bytes32 logs;
        uint256 nonce;
        uint256 hBal;
        uint256 tBal;
        uint256 sBal;
        bytes32 tState;
        bytes32 extra;
    }

    RefLib refLib;
    OptLib optLib;
    DToken tok;
    DReverter rev;
    DReturner retr;
    DProbe probe;
    DRelayer relOk;
    DRelayer relNo;
    address eoaRelayer;
    address eoaTarget;

    function setUp() public {
        refLib = new RefLib();
        optLib = new OptLib();
        tok = new DToken();
        rev = new DReverter();
        retr = new DReturner();
        probe = new DProbe();
        relOk = new DRelayer(false);
        relNo = new DRelayer(true);
        eoaRelayer = makeAddr("diff relayer");
        eoaTarget = makeAddr("diff target");
        vm.deal(eoaRelayer, 1 ether);
        tok.mint(X, 1);
        tok.mint(address(0xdead), 2);
        vm.warp(T);
    }

    // ------------------------------------------------------------------ plumbing

    function baseCode() internal pure returns (bytes memory) {
        return BaselineCode.creationCode();
    }

    function optCode() internal pure returns (bytes memory) {
        return type(BitcoinKeyedHolder).creationCode;
    }

    /// Runs `cc` with constructor argument `spk` at `at` and installs the runtime code it returns.
    function deployAt(address at, bytes memory cc, bytes memory spk) internal returns (bool ok, bytes memory ret) {
        vm.etch(at, abi.encodePacked(cc, abi.encode(spk)));
        (ok, ret) = at.call("");
        vm.etch(at, ok ? ret : bytes(""));
    }

    function install(address at, bool baseline, bytes memory spk) internal {
        (bool ok,) = deployAt(at, baseline ? baseCode() : optCode(), spk);
        require(ok, "install");
    }

    function hashLogs(Vm.Log[] memory logs) internal pure returns (bytes32 h) {
        for (uint256 i = 0; i < logs.length; i++) {
            h = keccak256(abi.encode(h, logs[i].emitter, logs[i].topics, logs[i].data));
        }
    }

    function readNonce(address at) internal view returns (uint256) {
        (bool ok, bytes memory r) = at.staticcall(abi.encodeWithSignature("nonce()"));
        return ok && r.length == 32 ? abi.decode(r, (uint256)) : type(uint256).max;
    }

    function state(address t) internal view returns (bytes32) {
        if (t.code.length == 0) return bytes32(0);
        (bool ok, bytes memory r) = t.staticcall(abi.encodeWithSignature("state()"));
        return ok && r.length == 32 ? abi.decode(r, (bytes32)) : bytes32(0);
    }

    function assertSame(Out memory a, Out memory b, string memory label) internal pure {
        assertEq(a.ok, b.ok, string.concat(label, ": ok"));
        assertEq(a.ret, b.ret, string.concat(label, ": return/revert data"));
        assertEq(a.logs, b.logs, string.concat(label, ": logs"));
        assertEq(a.nonce, b.nonce, string.concat(label, ": nonce"));
        assertEq(a.hBal, b.hBal, string.concat(label, ": holder balance"));
        assertEq(a.tBal, b.tBal, string.concat(label, ": target balance"));
        assertEq(a.sBal, b.sBal, string.concat(label, ": sender balance"));
        assertEq(a.tState, b.tState, string.concat(label, ": target state"));
        assertEq(a.extra, b.extra, string.concat(label, ": extra"));
    }

    /// One call to the holder at `at` from this contract, with logs and the holder's state recorded.
    function callHolder(address at, bytes memory cd, uint256 value, uint256 gas_) internal returns (Out memory o) {
        vm.recordLogs();
        (o.ok, o.ret) = at.call{value: value, gas: gas_}(cd);
        o.logs = hashLogs(vm.getRecordedLogs());
        o.nonce = readNonce(at);
        o.hBal = at.balance;
    }

    function staticHolder(address at, bytes memory cd) internal view returns (Out memory o) {
        (o.ok, o.ret) = at.staticcall(cd);
        o.nonce = readNonce(at);
    }

    /// isValidSignature on both sides at `at` (deploying each side's code for `spk` first).
    function diffIsValid(address at, bytes memory spk, uint256 chainId, bytes32 digest, bytes memory sig, string memory label)
        internal
        returns (bool accepted)
    {
        vm.chainId(chainId);
        bytes memory cd = abi.encodeCall(BitcoinKeyedHolder.isValidSignature, (digest, sig));
        uint256 snap = vm.snapshotState();
        install(at, true, spk);
        Out memory a = staticHolder(at, cd);
        vm.revertToState(snap);
        install(at, false, spk);
        Out memory b = staticHolder(at, cd);
        vm.revertToState(snap);
        assertSame(a, b, label);
        assertTrue(a.ok, "isValidSignature must not revert");
        accepted = bytes4(a.ret) == 0x1626ba7e;
    }

    function signMessageAt(address at, bytes memory spk, uint256 chainId, bytes32 digest) internal returns (bytes memory m) {
        vm.chainId(chainId);
        uint256 snap = vm.snapshotState();
        install(at, true, spk);
        m = BitcoinKeyedHolder(payable(at)).signMessage(digest);
        vm.revertToState(snap);
    }

    // ------------------------------------------------------------------ vectors (old addresses)

    function vHolder(uint8 i) internal pure returns (address, bytes memory) {
        if (i == 0) return (V.HOLDER_P2TR, V.SPK_P2TR);
        if (i == 1) return (V.HOLDER_P2WPKH, V.SPK_P2WPKH);
        return (V.HOLDER_P2TR_OTHER, V.SPK_P2TR_OTHER);
    }

    /// Every sign case of the baseline vectors, at its baseline holder address: same verdict, and the
    /// verdict is the expected one.
    function test_diff_vector_sign_cases() public {
        V.SignCase[] memory cs = V.signCases();
        for (uint256 i = 0; i < cs.length; i++) {
            (address at, bytes memory spk) = vHolder(cs[i].holder);
            bool acc = diffIsValid(at, spk, cs[i].chainId, cs[i].digest, cs[i].sig, cs[i].name);
            assertEq(acc, cs[i].expect, cs[i].name);
            if (cs[i].expect) assertEq(signMessageAt(at, spk, cs[i].chainId, cs[i].digest), cs[i].message, cs[i].name);
        }
    }

    /// The independent-library (bip322-js) signatures of holder messages, at their baseline holders.
    function test_diff_vector_lib_cases() public {
        V.LibCase[] memory cs = V.libCases();
        for (uint256 i = 0; i < cs.length; i++) {
            assertTrue(refLib.v(cs[i].spk, cs[i].message, cs[i].witness));
            assertTrue(optLib.v(cs[i].spk, cs[i].message, cs[i].witness));
            if (cs[i].chainId == 0) continue;
            bytes memory init = abi.encodePacked(baseCode(), abi.encode(cs[i].spk));
            address at = vm.computeCreate2Address(bytes32(0), keccak256(init), 0x4e59b44847b379578588920cA78FbF26c0B4956C);
            assertTrue(diffIsValid(at, cs[i].spk, cs[i].chainId, cs[i].digest, cs[i].witness, vm.toString(i)));
        }
    }

    /// Upstream BIP-322 vectors and error cases, library level.
    function test_diff_vector_bip322_upstream() public view {
        V.Bip322Case[] memory cs = V.bip322Cases();
        for (uint256 i = 0; i < cs.length; i++) {
            assertTrue(refLib.v(cs[i].spk, cs[i].message, cs[i].witness));
            assertTrue(optLib.v(cs[i].spk, cs[i].message, cs[i].witness));
        }
        cs = V.bip322ErrorCases();
        for (uint256 i = 0; i < cs.length; i++) {
            assertFalse(refLib.v(cs[i].spk, cs[i].message, cs[i].witness));
            assertFalse(optLib.v(cs[i].spk, cs[i].message, cs[i].witness));
        }
    }

    /// Constructor cases of the vectors: same accept/reject and same revert data.
    function test_diff_vector_ctor_cases() public {
        V.CtorCase[] memory cs = V.ctorCases();
        for (uint256 i = 0; i < cs.length; i++) {
            diffCtor(cs[i].spk, cs[i].name);
        }
    }

    /// The call cases on both sides, each from a fresh state (the P2TR value transfer runs after the
    /// P2TR token transfer, as its nonce 1 requires). Every case must succeed, identically.
    function test_diff_vector_call_cases() public {
        runCallSeq(0, 2);
        runCallSeq(1, 99);
        runCallSeq(3, 99);
    }

    function runCallSeq(uint256 first, uint256 second) internal {
        Out[2] memory a = callSeqSide(true, first, second);
        Out[2] memory b = callSeqSide(false, first, second);
        assertSame(a[0], b[0], "call case");
        assertSame(a[1], b[1], "call case (second)");
    }

    function callSeqSide(bool baseline, uint256 first, uint256 second) internal returns (Out[2] memory outs) {
        V.CallCase[] memory cs = V.callCases();
        vm.chainId(56);
        uint256 snap = vm.snapshotState();
        install(V.HOLDER_P2TR, baseline, V.SPK_P2TR);
        install(V.HOLDER_P2WPKH, baseline, V.SPK_P2WPKH);
        vm.deal(V.HOLDER_P2TR, 2 ether);
        vm.deal(V.HOLDER_P2WPKH, 2 ether);
        uint256[2] memory seq = [first, second];
        for (uint256 j = 0; j < 2; j++) {
            if (seq[j] == 99) continue;
            V.CallCase memory c = cs[seq[j]];
            (address at,) = vHolder(c.holder);
            if (c.target.code.length == 0 && c.data.length != 0) {
                vm.etch(c.target, type(DToken).runtimeCode);
                DToken(c.target).mint(at, 1);
                DToken(c.target).mint(at, 7);
            }
            vm.warp(c.deadline);
            bytes memory cd =
                abi.encodeCall(BitcoinKeyedHolder.execute, (c.target, c.value, c.data, c.gas, c.tip, c.deadline, c.sig));
            vm.prank(eoaRelayer);
            outs[j] = callHolder(at, cd, 0, 10_000_000);
            assertTrue(outs[j].ok, c.name);
            outs[j].sBal = eoaRelayer.balance;
            outs[j].tBal = c.target.balance;
            outs[j].tState = state(c.target);
        }
        vm.revertToState(snap);
    }

    // ------------------------------------------------------------------ constructor

    function diffCtor(bytes memory spk, string memory label) internal {
        uint256 snap = vm.snapshotState();
        (bool okA, bytes memory rA) = deployAt(X, baseCode(), spk);
        Out memory a;
        if (okA) a = probeHolder(X);
        vm.revertToState(snap);
        (bool okB, bytes memory rB) = deployAt(X, optCode(), spk);
        Out memory b;
        if (okB) b = probeHolder(X);
        vm.revertToState(snap);
        assertEq(okA, okB, string.concat(label, ": constructor accepts"));
        if (!okA) assertEq(rA, rB, string.concat(label, ": constructor revert data"));
        assertSame(a, b, label);
    }

    /// Read-only facts about an installed holder.
    function probeHolder(address at) internal returns (Out memory o) {
        (o.ok, o.ret) = at.staticcall(abi.encodeWithSignature("scriptPubKey()"));
        o.nonce = readNonce(at);
        bytes4[6] memory ids = [bytes4(0x01ffc9a7), 0x150b7a02, 0x4e2312e0, 0x1626ba7e, 0xffffffff, 0x00000000];
        for (uint256 i = 0; i < ids.length; i++) {
            (bool ok, bytes memory r) = at.staticcall(abi.encodeWithSignature("supportsInterface(bytes4)", ids[i]));
            o.extra = keccak256(abi.encode(o.extra, ok, r));
        }
        (bool ok2, bytes memory r2) =
            at.staticcall(abi.encodeCall(BitcoinKeyedHolder.isValidSignature, (bytes32(0), hex"0140")));
        o.tState = keccak256(abi.encode(ok2, r2));
    }

    /// Random and near-valid scriptPubKeys: same accept/reject, same revert data, same getters.
    function testFuzz_diff_constructor(uint8 shape, bytes32 a, bytes memory raw, uint8 tweak) public {
        bytes memory spk;
        shape %= 6;
        if (shape == 0) spk = raw;
        else if (shape == 1) spk = abi.encodePacked(uint8(0x51), uint8(0x20), a);
        else if (shape == 2) spk = abi.encodePacked(uint8(0x00), uint8(0x14), bytes20(a));
        else if (shape == 3) spk = DSign.mutate(abi.encodePacked(uint8(0x51), uint8(0x20), a), tweak, uint8(a[0]), tweak);
        else if (shape == 4) spk = DSign.mutate(abi.encodePacked(uint8(0x00), uint8(0x14), bytes20(a)), tweak, uint8(a[1]), tweak);
        else spk = DSign.trSpk(DSign.bound(uint256(a), 1, N - 1)); // a real, usable key
        diffCtor(spk, "ctor");
    }

    // ------------------------------------------------------------------ isValidSignature

    /// Baseline vector signatures with one structural mutation (bit flip, truncation, extension, byte
    /// set, deletion, insertion, length byte), at the baseline holders.
    function testFuzz_diff_isValid_vector_mutated(uint256 k, uint256 kind, uint256 pos, uint256 val, bytes32 digestNoise)
        public
    {
        V.SignCase[] memory cs = V.signCases();
        V.SignCase memory c = cs[k % cs.length];
        (address at, bytes memory spk) = vHolder(c.holder);
        bytes memory sig = DSign.mutate(c.sig, kind, pos, val);
        bytes32 digest = uint256(digestNoise) % 8 == 0 ? digestNoise : c.digest;
        bool acc = diffIsValid(at, spk, c.chainId, digest, sig, c.name);
        if (keccak256(sig) == keccak256(c.sig) && digest == c.digest) assertEq(acc, c.expect, c.name);
    }

    /// Structured random witnesses that reach deep into both parsers.
    function testFuzz_diff_isValid_structured(uint8 shape, bytes32 a, bytes32 b, uint8 c, bytes memory raw, bool p2tr, uint256 kind)
        public
    {
        (address at, bytes memory spk) = vHolder(p2tr ? 0 : 1);
        bytes memory sig;
        shape %= 6;
        if (shape == 0) {
            sig = raw;
        } else if (shape == 1) {
            sig = abi.encodePacked(uint8(0x01), uint8(0x40), a, b);
        } else if (shape == 2) {
            sig = abi.encodePacked(uint8(0x01), uint8(0x41), a, b, c);
        } else {
            // P2WPKH-shaped: 0x02 len (0x30 L 0x02 lr r 0x02 ls s) 0x01 0x21 key
            uint256 lr = uint8(a[0]) % 35;
            uint256 ls = uint8(b[0]) % 35;
            bytes memory r = new bytes(lr);
            bytes memory s = new bytes(ls);
            for (uint256 i = 0; i < lr; i++) r[i] = a[(i + 1) % 32];
            for (uint256 i = 0; i < ls; i++) s[i] = b[(i + 1) % 32];
            if (shape == 4 && lr > 0) r[0] = 0x00; // leading zero, minimal or not
            if (shape == 5 && ls > 0) s[0] = bytes1(uint8(c) | 0x80); // negative
            bytes memory der = abi.encodePacked(uint8(0x30), uint8(4 + lr + ls), uint8(0x02), uint8(lr), r, uint8(0x02), uint8(ls), s);
            bytes memory key = c % 2 == 0 ? keyOfVectorP2WPKH() : abi.encodePacked(uint8(0x02 + c % 3), a);
            sig = abi.encodePacked(uint8(0x02), uint8(der.length + 1), der, uint8(0x01), uint8(0x21), key);
        }
        sig = DSign.mutate(sig, kind, uint256(a), uint256(b));
        diffIsValid(at, spk, 56, keccak256(abi.encode(a, b)), sig, "structured");
    }

    function keyOfVectorP2WPKH() internal pure returns (bytes memory key) {
        bytes memory s = V.signCases()[1].sig;
        key = new bytes(33);
        for (uint256 i = 0; i < 33; i++) key[i] = s[s.length - 33 + i];
    }

    /// Fresh P2WPKH keys, random digests and chains, real signatures (vm.sign), optionally mutated.
    function testFuzz_diff_isValid_p2wpkh_signed(uint256 priv, bytes32 digest, uint64 chainId, uint256 kind, uint256 pos, uint256 val)
        public
    {
        priv = DSign.bound(priv, 1, N - 1);
        bytes memory spk = DSign.wpSpk(priv);
        bytes memory m = signMessageAt(X, spk, chainId, digest);
        bytes memory sig = DSign.wpSign(priv, m);
        bytes memory mut = DSign.mutate(sig, kind, pos, val);
        bool acc = diffIsValid(X, spk, chainId, digest, mut, "p2wpkh signed");
        if (keccak256(mut) == keccak256(sig)) assertTrue(acc, "valid P2WPKH signature rejected");
    }

    /// Valid P2WPKH signatures re-encoded: non-strict DER (negative, non-minimal, double-zero or
    /// unpadded integers) and high s. Strict DER and low s are consensus-like rules of the TAP; both
    /// sides must reject every variant and accept only the strict low-s encoding.
    function testFuzz_diff_isValid_p2wpkh_encodings(uint256 priv, bytes32 digest, uint8 rMode, uint8 sMode, bool highS)
        public
    {
        priv = DSign.bound(priv, 1, N - 1);
        bytes memory spk = DSign.wpSpk(priv);
        bytes memory m = signMessageAt(X, spk, 56, digest);
        (uint256 r, uint256 s, bytes memory pub) = DSign.wpSignRS(priv, m);
        if (highS) s = N - s;
        bytes memory w = DSign.wpWitness(r, s, pub, rMode % 4, sMode % 4);
        bool acc = diffIsValid(X, spk, 56, digest, w, "p2wpkh encodings");
        if (!highS && rMode % 4 == 0 && sMode % 4 == 0) assertTrue(acc, "strict encoding rejected");
        if (highS || rMode % 4 == 1 || rMode % 4 == 2 || sMode % 4 == 1 || sMode % 4 == 2) assertFalse(acc, "lax encoding accepted");
    }

    /// Fresh P2TR keys, random digests and chains, real BIP-340 signatures, both sighash types,
    /// optionally mutated.
    function testFuzz_diff_isValid_p2tr_signed(uint256 d, bytes32 digest, uint64 chainId, bool all, uint256 kind, uint256 pos, uint256 val)
        public
    {
        d = DSign.bound(d, 1, N - 1);
        bytes memory spk = DSign.trSpk(d);
        (, bytes32 px) = DSign.trKey(d);
        vm.assume(uint256(px) < N); // the constructor rejects x >= n (probability ~2^-128)
        bytes memory m = signMessageAt(X, spk, chainId, digest);
        bytes memory sig = DSign.trSign(d, m, all);
        bytes memory mut = DSign.mutate(sig, kind, pos, val);
        bool acc = diffIsValid(X, spk, chainId, digest, mut, "p2tr signed");
        if (keccak256(mut) == keccak256(sig)) assertTrue(acc, "valid P2TR signature rejected");
    }

    /// Library level, arbitrary messages (any length, not only holder messages), both key types.
    function testFuzz_diff_library_random_messages(uint256 d, bytes memory m, bool p2tr, bool all, uint256 kind, uint256 pos, uint256 val)
        public
    {
        d = DSign.bound(d, 1, N - 1);
        bytes memory spk;
        bytes memory sig;
        if (p2tr) {
            spk = DSign.trSpk(d);
            sig = DSign.trSign(d, m, all);
        } else {
            spk = DSign.wpSpk(d);
            sig = DSign.wpSign(d, m);
        }
        bytes memory mut = DSign.mutate(sig, kind, pos, val);
        bool a = refLib.v(spk, m, mut);
        bool b = optLib.v(spk, m, mut);
        assertEq(a, b, "library verdicts differ");
        if (keccak256(mut) == keccak256(sig)) assertTrue(a, "valid signature rejected by the reference");
    }

    // ------------------------------------------------------------------ messages

    /// signMessage and callMessage, byte for byte, for random holder addresses, chains and parameters.
    function testFuzz_diff_messages(
        address at,
        uint64 chainId,
        bytes32 digest,
        address target,
        uint256 value,
        bytes memory data,
        uint256 callGas,
        uint256 tip,
        uint256 n,
        uint64 deadline,
        bool p2tr
    ) public {
        // a fresh address derived from the fuzzed one (the fuzzer likes addresses that already have code)
        at = address(uint160(uint256(keccak256(abi.encode(at)))));
        vm.assume(at.code.length == 0 && uint160(at) > 0x10000);
        bytes memory spk = p2tr ? V.SPK_P2TR : V.SPK_P2WPKH;
        vm.chainId(chainId);
        bytes memory c1 = abi.encodeCall(BitcoinKeyedHolder.signMessage, (digest));
        bytes memory c2 =
            abi.encodeCall(BitcoinKeyedHolder.callMessage, (target, value, data, callGas, tip, n, deadline));
        uint256 snap = vm.snapshotState();
        install(at, true, spk);
        Out memory a1 = staticHolder(at, c1);
        Out memory a2 = staticHolder(at, c2);
        vm.revertToState(snap);
        install(at, false, spk);
        Out memory b1 = staticHolder(at, c1);
        Out memory b2 = staticHolder(at, c2);
        vm.revertToState(snap);
        assertSame(a1, b1, "signMessage");
        assertSame(a2, b2, "callMessage");
        assertTrue(a1.ok && a2.ok);
    }

    // ------------------------------------------------------------------ raw calldata

    /// Final lab: the entry points that the merged contract adds (executeBatch, batchMessage, MAX_CALLS,
    /// MAX_CALL_GAS). The baseline has no such functions, so calldata that reaches them is new behaviour,
    /// tested by test/batch and test/batchlab, not something to compare with the baseline.
    function isNewEntry(bytes memory cd) internal pure returns (bool) {
        if (cd.length < 4) return false;
        bytes4 s = bytes4(cd);
        return s == 0xc7826280 || s == 0xba195d76 || s == 0xb9add4b7 || s == 0x2ed55b1f;
    }

    /// Random calldata to every entry point (and none), with and without value: same success, same
    /// return or revert data, same logs, same balance and nonce. Covers ABI decoding, the dispatcher,
    /// payable checks, receive() and the token hooks.
    function testFuzz_diff_raw_calldata(uint8 pick, bytes memory payload, bool withValue, bool p2tr, bytes4 rnd) public {
        bytes4[11] memory sels = [
            BitcoinKeyedHolder.isValidSignature.selector,
            BitcoinKeyedHolder.execute.selector,
            BitcoinKeyedHolder.signMessage.selector,
            BitcoinKeyedHolder.callMessage.selector,
            bytes4(keccak256("scriptPubKey()")),
            bytes4(keccak256("nonce()")),
            BitcoinKeyedHolder.supportsInterface.selector,
            BitcoinKeyedHolder.onERC721Received.selector,
            BitcoinKeyedHolder.onERC1155Received.selector,
            BitcoinKeyedHolder.onERC1155BatchReceived.selector,
            rnd
        ];
        pick %= 14;
        bytes memory cd;
        if (pick < 11) cd = abi.encodePacked(sels[pick], payload);
        else if (pick == 11) cd = "";
        else if (pick == 12) cd = abi.encodePacked(uint8(payload.length == 0 ? 0 : uint8(payload[0])));
        else cd = payload;
        (address at, bytes memory spk) = vHolder(p2tr ? 0 : 1);
        vm.chainId(56);
        vm.deal(address(this), 10 ether);
        uint256 v = withValue ? 1 : 0;
        uint256 snap = vm.snapshotState();
        install(at, true, spk);
        Out memory a = callHolder(at, cd, v, 5_000_000);
        vm.revertToState(snap);
        if (isNewEntry(cd)) {
            // final lab: the baseline refuses a function it does not have; the merged contract's is new
            assertFalse(a.ok, "baseline: unknown function");
            assertEq(a.ret.length, 0, "baseline: unknown function");
            return;
        }
        install(at, false, spk);
        Out memory b = callHolder(at, cd, v, 5_000_000);
        vm.revertToState(snap);
        assertSame(a, b, "raw calldata");
    }

    // ------------------------------------------------------------------ execute

    struct Ex {
        bool tr;
        uint256 priv;
        bytes spk;
        uint256 kind;
        address target;
        uint256 value;
        bytes data;
        uint256 callGas;
        uint256 tip;
        uint64 deadline;
        uint256 claimedNonce;
        uint256 relayer; // 0 EOA, 1 accepting contract, 2 rejecting contract
        uint256 outer;
        bool tight;
        bool twice;
        uint256 mutKind;
        uint256 mutPos;
        uint256 mutVal;
        uint256 bal;
    }

    function rnd(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    function pickAmount(uint256 seed, uint256 i, uint256 raw, uint256 bal) internal pure returns (uint256) {
        uint256 s = rnd(seed, i) % 8;
        if (s == 0) return 0;
        if (s == 1) return bal;
        if (s == 2) return bal + 1;
        if (s == 3) return raw;
        if (s == 4) return 1;
        return raw % (bal + 2);
    }

    function buildEx(uint256 seed, uint256 value, uint256 callGas, uint256 tip, bytes memory payload)
        internal
        returns (Ex memory e)
    {
        e.tr = rnd(seed, 0) % 2 == 0;
        e.priv = DSign.bound(rnd(seed, 1), 1, N - 1);
        e.spk = e.tr ? DSign.trSpk(e.priv) : DSign.wpSpk(e.priv);
        e.bal = rnd(seed, 2) % 4 == 0 ? 0 : rnd(seed, 3) % 3 ether;
        e.value = pickAmount(seed, 4, value, e.bal);
        e.tip = pickAmount(seed, 5, tip, e.bal);
        uint256 gs = rnd(seed, 6) % 10;
        if (gs == 0) e.callGas = 0;
        else if (gs == 1) e.callGas = 2300;
        else if (gs == 2) e.callGas = type(uint256).max;
        else if (gs == 3) e.callGas = type(uint256).max / 64;
        else if (gs == 4) e.callGas = callGas;
        else e.callGas = callGas % 2_000_000;
        uint256 ds = rnd(seed, 7) % 6;
        e.deadline = ds == 0 ? uint64(T - 1) : ds == 1 ? uint64(T) : ds == 2 ? uint64(T + 1) : uint64(rnd(seed, 8));
        e.claimedNonce = rnd(seed, 9) % 8 == 0 ? 1 : 0;
        e.relayer = rnd(seed, 10) % 3;
        e.tight = rnd(seed, 11) % 3 == 0;
        e.outer = e.tight ? 20_000 + rnd(seed, 12) % 600_000 : generous(e.callGas);
        e.twice = !e.tight && rnd(seed, 13) % 4 == 0;
        e.mutKind = rnd(seed, 14) % 4 == 0 ? rnd(seed, 15) : 0;
        e.mutPos = rnd(seed, 16);
        e.mutVal = rnd(seed, 17);
        e.kind = rnd(seed, 18) % 9;
        if (e.kind == 0) {
            e.target = eoaTarget;
            e.data = shortData(rnd(seed, 19), payload);
        } else if (e.kind == 1) {
            e.target = address(tok);
            e.data = abi.encodeCall(DToken.safeTransferFrom, (X, address(0xb0), 1 + rnd(seed, 20) % 2));
        } else if (e.kind == 2) {
            e.target = address(rev);
            e.data = abi.encodeCall(DReverter.boom, (payload));
        } else if (e.kind == 3) {
            e.target = address(retr);
            e.data = abi.encodeCall(DReturner.ret, (payload));
        } else if (e.kind == 4) {
            e.target = address(probe);
            e.data = abi.encodeCall(DProbe.probe, ());
        } else if (e.kind == 5) {
            e.target = address(0x04); // identity precompile: no code, so data means NoCode
            e.data = shortData(rnd(seed, 21), payload);
        } else if (e.kind == 6) {
            e.target = X; // the holder itself
            e.data = shortData(rnd(seed, 22), payload);
            // final lab: not one of the merged contract's new functions (isNewEntry), which the baseline lacks
            if (isNewEntry(e.data)) e.data = "";
        } else if (e.kind == 7) {
            e.target = address(relOk);
            e.data = "";
        } else {
            e.target = X; // nested: the holder executes its own next signed call
            e.data = ""; // filled in after signing (needs the inner signature)
            e.callGas = 1_000_000 + callGas % 1_000_000;
        }
    }

    /// Final lab: 15M is not generous when callGas is itself close to 15M (found at run 134,668 of 200,000:
    /// callGas 14,625,579, where the side that uses less gas before the gas check passes it and then runs
    /// out after the call, and the other side stops at the check). Such calls get 60M.
    function generous(uint256 callGas) internal pure returns (uint256) {
        return callGas >= 10_000_000 && callGas < 1 << 64 ? 60_000_000 : 15_000_000;
    }

    /// empty, one byte, two bytes, or the fuzzed payload
    function shortData(uint256 r, bytes memory payload) internal pure returns (bytes memory) {
        r %= 4;
        if (r == 0) return "";
        if (r == 1) return abi.encodePacked(uint8(payload.length));
        if (r == 2) return abi.encodePacked(uint16(payload.length));
        return payload;
    }

    function sign(Ex memory e, bytes memory m) internal returns (bytes memory) {
        return e.tr ? DSign.trSign(e.priv, m, e.priv % 2 == 0) : DSign.wpSign(e.priv, m);
    }

    function execCd(Ex memory e, bytes memory sig) internal pure returns (bytes memory) {
        return abi.encodeCall(BitcoinKeyedHolder.execute, (e.target, e.value, e.data, e.callGas, e.tip, e.deadline, sig));
    }

    /// Signs the call(s) of `e` against the baseline's own message text (one install, reverted).
    function prepare(Ex memory e, bytes memory payload) internal returns (bytes memory cd1, bytes memory cd2) {
        uint256 snap = vm.snapshotState();
        install(X, true, e.spk);
        BitcoinKeyedHolder h = BitcoinKeyedHolder(payable(X));
        if (e.kind == 8) {
            // inner call (nonce 1): the returner, no value, no tip
            bytes memory innerData = abi.encodeCall(DReturner.ret, (payload));
            bytes memory innerSig = sign(e, h.callMessage(address(retr), 0, innerData, 100_000, 0, 1, e.deadline));
            e.data = abi.encodeCall(
                BitcoinKeyedHolder.execute, (address(retr), 0, innerData, 100_000, 0, e.deadline, innerSig)
            );
        }
        bytes memory sig = sign(e, h.callMessage(e.target, e.value, e.data, e.callGas, e.tip, e.claimedNonce, e.deadline));
        cd1 = execCd(e, DSign.mutate(sig, e.mutKind, e.mutPos, e.mutVal));
        if (e.twice) {
            bytes memory sig2 =
                sign(e, h.callMessage(e.target, e.value, e.data, e.callGas, e.tip, e.claimedNonce + 1, e.deadline));
            cd2 = execCd(e, sig2);
        }
        vm.revertToState(snap);
    }

    function runSide(Ex memory e, bool baseline, bytes memory cd1, bytes memory cd2, uint256 outer)
        internal
        returns (Out memory o)
    {
        install(X, baseline, e.spk);
        vm.deal(X, e.bal);
        address sender = e.relayer == 0 ? eoaRelayer : e.relayer == 1 ? address(relOk) : address(relNo);
        o = relay(e, cd1, outer);
        if (e.twice) {
            Out memory o2 = relay(e, cd2, outer);
            o.ret = abi.encode(o.ret, o2.ok, o2.ret);
            o.logs = keccak256(abi.encode(o.logs, o2.logs));
            o.ok = o.ok && o2.ok;
        }
        o.nonce = readNonce(X);
        o.hBal = X.balance;
        o.tBal = e.target.balance;
        o.sBal = sender.balance;
        o.tState = state(e.target);
        o.extra = keccak256(abi.encode(state(address(retr)), state(address(tok)), state(address(probe))));
    }

    function relay(Ex memory e, bytes memory cd, uint256 outer) internal returns (Out memory o) {
        vm.recordLogs();
        if (e.relayer == 0) {
            vm.prank(eoaRelayer);
            (o.ok, o.ret) = X.call{gas: outer}(cd);
        } else {
            (o.ok, o.ret) = (e.relayer == 1 ? relOk : relNo).relay(X, cd, outer);
        }
        o.logs = hashLogs(vm.getRecordedLogs());
    }

    function gasLike(Out memory o) internal pure returns (bool) {
        if (o.ok) return false;
        if (o.ret.length == 0) return true;
        if (o.ret.length == 4 && (bytes4(o.ret) == INSUFFICIENT_GAS || bytes4(o.ret) == TIP_FAILED)) return true;
        return false;
    }

    /// Random signed calls: key type, target kind (EOA, token, reverter, returner, gas probe,
    /// precompile, the holder itself, a relayer contract, a nested execute), value, tip, callGas
    /// (including 0, 2,300 and overflowing values), deadline around block.timestamp, wrong nonce,
    /// mutated signatures, EOA or contract relayers that accept or reject the tip, and two calls in a
    /// row.
    /// Rule: with generous outer gas (15M) the two sides must agree on everything. With tight outer gas
    /// (20k to 620k) the optimised side may get further because it uses less gas, so: if the baseline
    /// succeeds, or fails for a reason other than gas, the optimised side must do exactly the same; if
    /// the baseline fails for gas (empty revert data, InsufficientGas or TipFailed) and the optimised
    /// side does not, the baseline rerun with 15M gas must do exactly what the optimised side did.
    /// Final lab: the counterexample that showed 15M outer gas is not generous for a callGas near 15M.
    function test_diff_execute_callGas_near_outer_gas() public {
        testFuzz_diff_execute(
            34665006661085, 67469581567724799780, 14625579, 2773357990655375676745943220764328989259124586391037324437844867, ""
        );
    }

    function testFuzz_diff_execute(uint256 seed, uint256 value, uint256 callGas, uint256 tip, bytes memory payload) public {
        vm.chainId(56);
        Ex memory e = buildEx(seed, value, callGas, tip, payload);
        if (e.tr) {
            (, bytes32 px) = DSign.trKey(e.priv);
            vm.assume(uint256(px) < N);
        }
        (bytes memory cd1, bytes memory cd2) = prepare(e, payload);
        uint256 snap = vm.snapshotState();
        Out memory a = runSide(e, true, cd1, cd2, e.outer);
        vm.revertToState(snap);
        Out memory b = runSide(e, false, cd1, cd2, e.outer);
        vm.revertToState(snap);
        if (!e.tight) {
            assertSame(a, b, "execute (generous gas)");
            return;
        }
        if (a.ok || !gasLike(a)) {
            // the baseline succeeded, or failed for a reason that has nothing to do with gas
            assertSame(a, b, "execute (tight gas)");
        } else if (!gasLike(b)) {
            // the baseline ran short of gas; the optimised side got further: it must do what the
            // baseline does with enough gas
            Out memory a2 = runSide(e, true, cd1, cd2, generous(e.callGas));
            vm.revertToState(snap);
            assertSame(a2, b, "execute (tight gas, baseline short of gas; rerun with generous gas)");
        }
    }
}
