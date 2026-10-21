// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Pure-Solidity secp256k1 reference for the audit: affine arithmetic, modular inverse through
///      modexp, BIP-340 sign and verify written straight from the BIP text (no ecrecover tricks).
///      Slow and only for tests.
library Secp256k1Ref {
    uint256 internal constant P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    uint256 internal constant GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
    bytes32 internal constant TAG_CHALLENGE = 0x7bb52d7a9fef58323eb1bf7a407db382d2f3f2d81bb1224f49fe518f6d48d37c;

    struct Pt {
        uint256 x;
        uint256 y;
        bool inf;
    }

    function modexp(uint256 b, uint256 e, uint256 m) internal view returns (uint256 r) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, 32)
            mstore(add(p, 0x20), 32)
            mstore(add(p, 0x40), 32)
            mstore(add(p, 0x60), b)
            mstore(add(p, 0x80), e)
            mstore(add(p, 0xa0), m)
            if iszero(staticcall(gas(), 0x05, p, 0xc0, p, 0x20)) { revert(0, 0) }
            r := mload(p)
        }
    }

    function inv(uint256 a) internal view returns (uint256) {
        require(a != 0, "inv0");
        return modexp(a, P - 2, P);
    }

    function onCurve(uint256 x, uint256 y) internal pure returns (bool) {
        if (x >= P || y >= P) return false;
        return mulmod(y, y, P) == addmod(mulmod(mulmod(x, x, P), x, P), 7, P);
    }

    function dbl(Pt memory a) internal view returns (Pt memory r) {
        if (a.inf || a.y == 0) return Pt(0, 0, true);
        uint256 l = mulmod(mulmod(3, mulmod(a.x, a.x, P), P), inv(mulmod(2, a.y, P)), P);
        r.x = addmod(mulmod(l, l, P), P - mulmod(2, a.x, P), P);
        r.y = addmod(mulmod(l, addmod(a.x, P - r.x, P), P), P - a.y, P);
    }

    function add(Pt memory a, Pt memory b) internal view returns (Pt memory r) {
        if (a.inf) return b;
        if (b.inf) return a;
        if (a.x == b.x) {
            if (a.y == b.y) return dbl(a);
            return Pt(0, 0, true);
        }
        uint256 l = mulmod(addmod(b.y, P - a.y, P), inv(addmod(b.x, P - a.x, P)), P);
        r.x = addmod(addmod(mulmod(l, l, P), P - a.x, P), P - b.x, P);
        r.y = addmod(mulmod(l, addmod(a.x, P - r.x, P), P), P - a.y, P);
    }

    function mul(Pt memory a, uint256 k) internal view returns (Pt memory r) {
        r = Pt(0, 0, true);
        Pt memory q = a;
        while (k != 0) {
            if (k & 1 == 1) r = add(r, q);
            q = dbl(q);
            k >>= 1;
        }
    }

    function G() internal pure returns (Pt memory) {
        return Pt(GX, GY, false);
    }

    function mulG(uint256 k) internal view returns (Pt memory) {
        return mul(G(), k);
    }

    /// @dev BIP-340 lift_x: the even-y point with x-coordinate x, or inf when none (x >= p or non-residue).
    function liftX(uint256 x) internal view returns (Pt memory r) {
        if (x >= P) return Pt(0, 0, true);
        uint256 c = addmod(mulmod(mulmod(x, x, P), x, P), 7, P);
        uint256 y = modexp(c, (P + 1) / 4, P);
        if (mulmod(y, y, P) != c) return Pt(0, 0, true);
        if (y & 1 == 1) y = P - y;
        return Pt(x, y, false);
    }

    function tagged(string memory tag, bytes memory data) internal pure returns (bytes32) {
        bytes32 t = sha256(bytes(tag));
        return sha256(abi.encodePacked(t, t, data));
    }

    /// @dev BIP-340 Verify(pk, m, sig) exactly as the BIP's reference code.
    function verify(bytes32 px, bytes memory m, uint256 r, uint256 s) internal view returns (bool) {
        Pt memory pk = liftX(uint256(px));
        if (pk.inf) return false;
        if (r >= P) return false;
        if (s >= N) return false;
        uint256 e = uint256(tagged("BIP0340/challenge", abi.encodePacked(bytes32(r), px, m))) % N;
        // R = s*G - e*P
        Pt memory sG = mulG(s);
        Pt memory eP = mul(pk, e);
        Pt memory negEP = eP.inf ? eP : Pt(eP.x, eP.y == 0 ? 0 : P - eP.y, false);
        Pt memory R = add(sG, negEP);
        if (R.inf) return false;
        if (R.y & 1 == 1) return false;
        return R.x == r;
    }

    /// @dev BIP-340 Sign with nonce k derived from (d, m, aux) by keccak (any nonzero k works for a test).
    ///      `negateK` true follows the BIP (make R even); false produces the odd-y-R negative case.
    function sign(uint256 d, bytes memory m, bytes32 aux, bool negateK)
        internal
        view
        returns (bytes32 px, uint256 r, uint256 s)
    {
        require(d != 0 && d < N, "d");
        Pt memory pk = mulG(d);
        if (pk.y & 1 == 1) d = N - d; // secret for the even-y key
        px = bytes32(pk.x);
        uint256 k = uint256(keccak256(abi.encodePacked(d, m, aux))) % N;
        if (k == 0) k = 1;
        Pt memory R = mulG(k);
        if (negateK && R.y & 1 == 1) k = N - k;
        if (!negateK && R.y & 1 == 0) {
            // we want an odd-y R for the negative test
            k = N - k;
        }
        R = mulG(k);
        r = R.x;
        uint256 e = uint256(tagged("BIP0340/challenge", abi.encodePacked(bytes32(r), px, m))) % N;
        s = addmod(k, mulmod(e, d, N), N);
    }

    function compressed(Pt memory p) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(p.y & 1 == 1 ? 0x03 : 0x02), bytes32(p.x));
    }

    function hash160(bytes memory b) internal pure returns (bytes20) {
        return ripemd160(abi.encodePacked(sha256(b)));
    }

    /// @dev strict DER of (r, s)
    function derInt(uint256 v) internal pure returns (bytes memory out) {
        // minimal big-endian
        uint256 len = 0;
        for (uint256 t = v; t != 0; t >>= 8) {
            len++;
        }
        if (len == 0) len = 1;
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[len - 1 - i] = bytes1(uint8(v >> (8 * i)));
        }
        if (uint8(out[0]) & 0x80 != 0) out = abi.encodePacked(uint8(0), out);
        return abi.encodePacked(uint8(0x02), uint8(out.length), out);
    }

    function der(uint256 r, uint256 s) internal pure returns (bytes memory) {
        bytes memory body = abi.encodePacked(derInt(r), derInt(s));
        return abi.encodePacked(uint8(0x30), uint8(body.length), body);
    }
}
