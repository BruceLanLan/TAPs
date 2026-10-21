// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RefBIP322 as BIP322} from "../baseline/RefBIP322.sol";
import {RefBIP340 as BIP340} from "../baseline/RefBIP340.sol";

/// Lab-only copy of the BASELINE holder (lab commit 834787a) with gasleft() checkpoints between the
/// steps of isValidSignature and execute. The logic is the baseline's, inlined step by step; the
/// checkpoints write into a memory array allocated first, so memory growth matches the real flow
/// up to that one small array. Used by GasProfile.t.sol to fill docs/GAS-PROFILE.md.
contract ProfiledHolder {
    bytes32 internal immutable outputKey;
    bytes20 internal immutable keyHash;
    uint256 public nonce;

    event Called(uint256 indexed nonce, address indexed target, uint256 value, bytes32 dataHash);

    constructor(bytes memory spk) {
        bytes32 w;
        assembly ("memory-safe") {
            w := mload(add(spk, 0x22))
        }
        if (spk.length == 34) outputKey = w;
        else keyHash = bytes20(w);
    }

    receive() external payable {}

    struct Marks {
        uint256[40] g;
        uint256 n;
    }

    function mark(Marks memory m) internal view {
        m.g[m.n++] = gasleft();
    }

    // ------------------------------------------------------------------ isValidSignature

    /// Returns the gas at each checkpoint (the first entry is taken on entry, after ABI decoding).
    function profileIsValid(bytes32 digest, bytes calldata sig) external view returns (uint256[40] memory, uint256) {
        Marks memory m;
        mark(m); // 0 entry
        bytes memory pre = _prefix();
        mark(m); // 1 prefix
        bytes memory hd = _hex(abi.encodePacked(digest));
        mark(m); // 2 hex(digest)
        bytes memory message = abi.encodePacked(pre, " signs 0x", hd);
        mark(m); // 3 concat
        if (outputKey != 0) _profileP2TR(m, message, sig);
        else _profileP2WPKH(m, message, sig);
        return (m.g, m.n);
    }

    function _profileP2TR(Marks memory m, bytes memory message, bytes memory witness) internal view {
        // witness copied to memory by the caller of verifyP2TR (calldata -> memory)
        mark(m); // 4 witness copied
        uint8 hashType = witness.length == 66 ? 0 : 1;
        uint256 r;
        uint256 s;
        assembly ("memory-safe") {
            r := mload(add(witness, 0x22))
            s := mload(add(witness, 0x42))
        }
        bytes memory spk = abi.encodePacked(uint8(0x51), uint8(0x20), outputKey);
        mark(m); // 5 witness checks + spk
        bytes32 mh = BIP322.messageHash(message);
        mark(m); // 6 messageHash (tagged sha256)
        bytes32 txid = BIP322.toSpendTxid(mh, spk);
        mark(m); // 7 to_spend serialisation + sha256d
        bytes32 sighash = BIP322.taprootSighash(txid, spk, hashType);
        mark(m); // 8 BIP-341 sighash (5 inner sha256 + tagged sha256)
        // BIP-340, inlined
        uint256 pxi = uint256(outputKey);
        uint256 e = uint256(
            sha256(abi.encodePacked(BIP340.TAG_CHALLENGE, BIP340.TAG_CHALLENGE, bytes32(r), outputKey, abi.encodePacked(sighash)))
        ) % BIP340.N;
        mark(m); // 9 challenge (tagged sha256)
        uint256 ss = BIP340.N - mulmod(e, pxi, BIP340.N);
        uint256 hh = mulmod(s, pxi, BIP340.N);
        hh = hh == 0 ? 0 : BIP340.N - hh;
        address q = ecrecover(bytes32(hh), 27, outputKey, bytes32(ss));
        mark(m); // 10 ecrecover
        (bool ok, uint256 ry) = BIP340.liftXEven(r);
        mark(m); // 11 lift_x(r) via modexp
        bool good = ok && q == address(uint160(uint256(keccak256(abi.encode(r, ry)))));
        mark(m); // 12 keccak + compare
        require(good, "profile: bad sig");
    }

    function _profileP2WPKH(Marks memory m, bytes memory message, bytes memory witness) internal view {
        mark(m); // 4 witness copied
        uint256 sigLen = uint8(witness[1]);
        (bool ok, uint256 r, uint256 at) = _derInt(witness, 4, 1 + sigLen);
        uint256 s;
        (ok, s, at) = _derInt(witness, at, 1 + sigLen);
        require(ok && at == 1 + sigLen && r != 0 && r < BIP340.N && s != 0 && s <= BIP340.N / 2, "der");
        mark(m); // 5 DER parsing
        uint256 k = 2 + sigLen;
        bytes memory pub = new bytes(33);
        for (uint256 i = 0; i < 33; i++) pub[i] = witness[k + 1 + i];
        mark(m); // 6 copy key byte by byte
        require(ripemd160(abi.encodePacked(sha256(pub))) == keyHash, "kh");
        mark(m); // 7 hash160
        uint8 prefix = uint8(pub[0]);
        uint256 x;
        assembly ("memory-safe") {
            x := mload(add(pub, 0x21))
        }
        (bool lifted, uint256 y) = BIP340.liftXEven(x);
        if (prefix == 0x03) y = BIP340.P - y;
        require(lifted, "lift");
        address expected = address(uint160(uint256(keccak256(abi.encode(x, y)))));
        mark(m); // 8 lift_x(key) via modexp + keccak
        bytes32 mh = BIP322.messageHash(message);
        mark(m); // 9 messageHash
        bytes32 txid = BIP322.toSpendTxid(mh, abi.encodePacked(uint8(0x00), uint8(0x14), keyHash));
        mark(m); // 10 to_spend + sha256d
        bytes32 sighash = BIP322.segwitV0Sighash(txid, keyHash);
        mark(m); // 11 BIP-143 sighash (3 x sha256d + sha256d)
        bool good = ecrecover(sighash, 27, bytes32(r), bytes32(s)) == expected;
        mark(m); // 12 ecrecover v=27
        if (!good) good = ecrecover(sighash, 28, bytes32(r), bytes32(s)) == expected;
        mark(m); // 13 ecrecover v=28 (when needed)
        require(good, "profile: bad sig");
    }

    function _derInt(bytes memory w, uint256 at, uint256 end) private pure returns (bool ok, uint256 v, uint256 next) {
        if (at + 2 > end || w[at] != 0x02) return (false, 0, 0);
        uint256 l = uint8(w[at + 1]);
        uint256 start = at + 2;
        if (l == 0 || l > 33 || start + l > end) return (false, 0, 0);
        uint8 first = uint8(w[start]);
        if (first & 0x80 != 0) return (false, 0, 0);
        if (first == 0) {
            if (l == 1 || uint8(w[start + 1]) & 0x80 == 0) return (false, 0, 0);
            start += 1;
            l -= 1;
        }
        if (l > 32) return (false, 0, 0);
        for (uint256 i = 0; i < l; i++) v = (v << 8) | uint8(w[start + i]);
        return (true, v, start + l);
    }

    // ------------------------------------------------------------------ execute

    function profileExecute(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 callGas,
        uint256 callTip,
        uint64 deadline,
        bytes calldata sig
    ) external returns (uint256[40] memory, uint256) {
        Marks memory m;
        mark(m); // 0 entry
        require(block.timestamp <= deadline, "expired");
        uint256 n = nonce;
        mark(m); // 1 deadline + SLOAD nonce (cold)
        bytes memory pre = _prefix();
        mark(m); // 2 prefix
        bytes memory t = _hex(abi.encodePacked(target));
        mark(m); // 3 hex(target)
        bytes memory dv = _dec(value);
        mark(m); // 4 dec(value)
        bytes32 dh = keccak256(data);
        mark(m); // 5 keccak(data)
        bytes memory dhh = _hex(abi.encodePacked(dh));
        mark(m); // 6 hex(dataHash)
        bytes memory d1 = _dec(callGas);
        bytes memory d2 = _dec(callTip);
        bytes memory d3 = _dec(n);
        bytes memory d4 = _dec(deadline);
        mark(m); // 7 dec(gas, tip, nonce, deadline)
        bytes memory message = abi.encodePacked(
            pre, " calls 0x", t, " with value ", dv, " and data 0x", dhh, ", gas ", d1, ", tip ", d2, ", nonce ", d3,
            ", valid until ", d4
        );
        mark(m); // 8 concat
        if (outputKey != 0) _profileP2TR(m, message, sig); // 9..17
        else _profileP2WPKH(m, message, sig);
        if (data.length != 0 && target.code.length == 0) revert("nocode");
        mark(m); // code check (cold EXTCODESIZE)
        nonce = n + 1;
        mark(m); // SSTORE nonce
        uint256 floor = callGas * 64 / 63;
        if (floor < callGas + 2500) floor = callGas + 2500;
        uint256 overhead = value == 0 ? 3100 : 37100;
        require(gasleft() >= floor + overhead, "gas");
        mark(m); // floor check
        (bool ok, bytes memory ret) = target.call{gas: callGas, value: value}(data);
        require(ok, "call");
        ret;
        mark(m); // CALL (incl. callee)
        if (callTip != 0) {
            (bool paid,) = msg.sender.call{value: callTip}("");
            require(paid, "tip");
        }
        mark(m); // tip
        emit Called(n, target, value, keccak256(data));
        mark(m); // event
        return (m.g, m.n);
    }

    // ------------------------------------------------------------------ baseline formatting, verbatim

    function _prefix() internal view returns (bytes memory) {
        return abi.encodePacked(
            "TapeOut Bitcoin-keyed holder 0x", _hex(abi.encodePacked(address(this))), " on chain ", _dec(block.chainid)
        );
    }

    function _hex(bytes memory b) internal pure returns (bytes memory out) {
        bytes16 digits = "0123456789abcdef";
        out = new bytes(2 * b.length);
        for (uint256 i = 0; i < b.length; i++) {
            out[2 * i] = digits[uint8(b[i]) >> 4];
            out[2 * i + 1] = digits[uint8(b[i]) & 0x0f];
        }
    }

    function _dec(uint256 v) internal pure returns (bytes memory out) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t != 0; t /= 10) len++;
        out = new bytes(len);
        // forge-lint: disable-next-line(unsafe-typecast)
        for (; v != 0; v /= 10) out[--len] = bytes1(uint8(48 + v % 10));
    }
}
