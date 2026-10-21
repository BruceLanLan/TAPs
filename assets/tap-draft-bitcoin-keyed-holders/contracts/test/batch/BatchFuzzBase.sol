// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {BitcoinKeyedHolder as B} from "../../src/BitcoinKeyedHolder.sol";
import {DSign} from "../diff/DiffLib.sol";
import {DToken, DReverter, DReturner, DProbe, DRelayer} from "../diff/DiffTargets.sol";

/// Shared plumbing for the batch fuzz tests (BatchInvariants, BatchVsExecute, BatchLabDiff): random signed
/// batches over a fixed set of targets, signed with real keys through cheatcodes (DSign), relayed by an EOA
/// or by a contract that accepts or rejects the tip, and an observation of everything a batch can change.
abstract contract BatchFuzzBase is Test {
    uint256 constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    address constant X = 0x5eeD00000000000000000000000000000000B0B1; // holder address for random keys
    uint256 constant T = 1_800_000_000;
    bytes4 constant INSUFFICIENT_GAS = 0x1c26714c;
    bytes4 constant TIP_FAILED = 0xd99123cb;

    DToken tok;
    DReverter rev;
    DReturner retr;
    DProbe probe;
    DRelayer relOk;
    DRelayer relNo;
    address eoaRelayer;
    address eoaTarget;

    /// Everything a relayed transaction can change, as seen from outside.
    struct Obs {
        bool ok;
        bytes ret;
        bytes32 logs;
        uint256 nonce;
        uint256 hBal;
        uint256 sBal;
        bytes32 world; // balances of every target, states of every stateful target
    }

    /// One random batch and how it is relayed.
    struct Bx {
        bool tr;
        uint256 priv;
        bytes spk;
        B.Call[] calls;
        uint256 tip;
        uint64 deadline;
        uint256 claimedNonce;
        uint256 relayer; // 0 EOA, 1 accepting contract, 2 rejecting contract
        uint256 mutKind;
        uint256 mutPos;
        uint256 mutVal;
        uint256 bal;
    }

    function setUp() public virtual {
        tok = new DToken();
        rev = new DReverter();
        retr = new DReturner();
        probe = new DProbe();
        relOk = new DRelayer(false);
        relNo = new DRelayer(true);
        eoaRelayer = makeAddr("batch relayer");
        eoaTarget = makeAddr("batch target");
        vm.deal(eoaRelayer, 1 ether);
        tok.mint(X, 1);
        tok.mint(X, 2);
        vm.warp(T);
        vm.chainId(56);
    }

    // ------------------------------------------------------------------ installing code at X

    function installCode(bytes memory creationCode, bytes memory spk) internal {
        vm.etch(X, abi.encodePacked(creationCode, abi.encode(spk)));
        (bool ok, bytes memory rt) = X.call("");
        require(ok, "install");
        vm.etch(X, rt);
    }

    function install(bytes memory spk) internal {
        installCode(type(B).creationCode, spk);
    }

    // ------------------------------------------------------------------ random batches

    function rnd(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    function shortData(uint256 r, bytes memory payload) internal pure returns (bytes memory) {
        r %= 4;
        if (r == 0) return "";
        if (r == 1) return abi.encodePacked(uint8(payload.length));
        if (r == 2) return abi.encodePacked(uint16(payload.length));
        return payload;
    }

    /// A key: P2TR or P2WPKH (a P2TR key whose x is not below n, probability 2^-128, falls back to P2WPKH).
    function pickKey(Bx memory b, uint256 seed) internal {
        b.priv = DSign.bound(rnd(seed, 1), 1, N - 1);
        b.tr = rnd(seed, 0) % 2 == 0;
        if (b.tr) {
            (, bytes32 px) = DSign.trKey(b.priv);
            if (uint256(px) >= N) b.tr = false;
        }
        b.spk = b.tr ? DSign.trSpk(b.priv) : DSign.wpSpk(b.priv);
    }

    /// Call i of a random batch. Kinds: EOA, token transfer (fails once the token has moved), reverter,
    /// returner, gas probe, precompile (no code: data means NoCode), the holder itself, a contract that
    /// accepts coin. Values are mostly 0, sometimes small or the whole balance; callGas includes 0, 2,300
    /// and, rarely, values at or above 2^64.
    function randomCall(uint256 seed, uint256 i, uint256 bal, bytes memory payload) internal view returns (B.Call memory c) {
        uint256 r = rnd(seed, 100 + i);
        uint256 kind = r % 8;
        uint256 vs = rnd(seed, 200 + i) % 8;
        c.value = vs < 5 ? 0 : vs == 5 ? 1 : vs == 6 ? bal / 3 : bal + 1;
        uint256 gs = rnd(seed, 300 + i) % 40;
        uint256 gRaw = rnd(seed, 400 + i);
        c.callGas = gs == 0 ? 0 : gs == 1 ? 2300 : gs == 2 ? (1 << 64) : gs == 3 ? type(uint256).max : 30_000 + gRaw % 400_000;
        if (kind == 0) {
            c.target = eoaTarget;
            c.data = shortData(r >> 8, payload);
        } else if (kind == 1) {
            c.target = address(tok);
            c.data = abi.encodeCall(DToken.safeTransferFrom, (X, address(0xb0), 1 + (r >> 8) % 2));
        } else if (kind == 2) {
            c.target = address(rev);
            c.data = abi.encodeCall(DReverter.boom, (payload));
            c.value = 0;
        } else if (kind == 3) {
            c.target = address(retr);
            c.data = abi.encodeCall(DReturner.ret, (payload));
        } else if (kind == 4) {
            c.target = address(probe);
            c.data = abi.encodeCall(DProbe.probe, ());
        } else if (kind == 5) {
            c.target = address(0x04);
            c.data = shortData(r >> 8, payload);
        } else if (kind == 6) {
            // the holder itself, with no data (receive) or one or two bytes (no such function): a call of a
            // holder function with a bounded callGas would compare how much gas the two codes use
            c.target = X;
            c.data = shortData((r >> 8) % 3, payload);
        } else {
            c.target = address(relOk);
            c.data = "";
        }
    }

    function buildBatch(uint256 seed, bytes memory payload, uint256 maxCalls) internal returns (Bx memory b) {
        pickKey(b, seed);
        b.bal = rnd(seed, 2) % 4 == 0 ? 0 : rnd(seed, 3) % 3 ether;
        uint256 k = 1 + rnd(seed, 4) % maxCalls;
        b.calls = new B.Call[](k);
        for (uint256 i = 0; i < k; i++) {
            b.calls[i] = randomCall(seed, i, b.bal, payload);
        }
        uint256 ts = rnd(seed, 5) % 6;
        b.tip = ts < 3 ? 0 : ts == 3 ? 1 : ts == 4 ? b.bal / 4 : b.bal + 1;
        uint256 ds = rnd(seed, 6) % 8;
        b.deadline = ds == 0 ? uint64(T - 1) : ds == 1 ? uint64(T) : uint64(T + 1 + rnd(seed, 7) % 1e9);
        b.claimedNonce = rnd(seed, 8) % 10 == 0 ? 1 : 0;
        b.relayer = rnd(seed, 9) % 3;
        b.mutKind = rnd(seed, 10) % 5 == 0 ? rnd(seed, 11) : 0;
        b.mutPos = rnd(seed, 12);
        b.mutVal = rnd(seed, 13);
    }

    function signWith(bool tr, uint256 priv, bytes memory m) internal returns (bytes memory) {
        return tr ? DSign.trSign(priv, m, priv % 2 == 0) : DSign.wpSign(priv, m);
    }

    /// The batch's signature over the text rendered by the code installed at X (state is left as is).
    function signBatch(Bx memory b, uint256 nonce_) internal returns (bytes memory) {
        bytes memory m = B(payable(X)).batchMessage(b.calls, b.tip, nonce_, b.deadline);
        return signWith(b.tr, b.priv, m);
    }

    function batchCd(Bx memory b, bytes memory sig) internal pure returns (bytes memory) {
        return abi.encodeCall(B.executeBatch, (b.calls, b.tip, b.deadline, sig));
    }

    // ------------------------------------------------------------------ relaying and observing

    function sender(uint256 relayer) internal view returns (address) {
        return relayer == 0 ? eoaRelayer : relayer == 1 ? address(relOk) : address(relNo);
    }

    function hashLogs(Vm.Log[] memory logs) internal pure returns (bytes32 h) {
        for (uint256 i = 0; i < logs.length; i++) {
            h = keccak256(abi.encode(h, logs[i].emitter, logs[i].topics, logs[i].data));
        }
    }

    function readNonce() internal view returns (uint256) {
        (bool ok, bytes memory r) = X.staticcall(abi.encodeWithSignature("nonce()"));
        return ok && r.length == 32 ? abi.decode(r, (uint256)) : type(uint256).max;
    }

    function world() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                tok.state(),
                retr.state(),
                probe.state(),
                relOk.received(),
                eoaTarget.balance,
                address(retr).balance,
                address(probe).balance,
                address(relOk).balance,
                address(0x04).balance,
                address(0xb0).balance
            )
        );
    }

    function relayRaw(uint256 relayer, bytes memory cd, uint256 outer) internal returns (bool ok, bytes memory ret) {
        if (relayer == 0) {
            vm.prank(eoaRelayer);
            (ok, ret) = X.call{gas: outer}(cd);
        } else {
            (ok, ret) = (relayer == 1 ? relOk : relNo).relay(X, cd, outer);
        }
    }

    function observe(uint256 relayer, bytes memory cd, uint256 outer) internal returns (Obs memory o) {
        vm.recordLogs();
        (o.ok, o.ret) = relayRaw(relayer, cd, outer);
        o.logs = hashLogs(vm.getRecordedLogs());
        o.nonce = readNonce();
        o.hBal = X.balance;
        o.sBal = sender(relayer).balance;
        o.world = world();
    }

    function first256(bytes memory d) internal pure returns (bytes memory out) {
        out = new bytes(d.length < 256 ? d.length : 256);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = d[i];
        }
    }

    function tail4(bytes memory ret) internal pure returns (bytes memory t) {
        t = new bytes(ret.length - 4);
        for (uint256 i = 0; i < t.length; i++) {
            t[i] = ret[i + 4];
        }
    }

    function assertSameObs(Obs memory a, Obs memory b, string memory label) internal pure {
        assertEq(a.ok, b.ok, string.concat(label, ": ok"));
        assertEq(a.ret, b.ret, string.concat(label, ": return/revert data"));
        assertEq(a.logs, b.logs, string.concat(label, ": logs"));
        assertEq(a.nonce, b.nonce, string.concat(label, ": nonce"));
        assertEq(a.hBal, b.hBal, string.concat(label, ": holder balance"));
        assertEq(a.sBal, b.sBal, string.concat(label, ": sender balance"));
        assertEq(a.world, b.world, string.concat(label, ": targets"));
    }
}
