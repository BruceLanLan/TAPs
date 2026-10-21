// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title BIP-340 Schnorr verification on secp256k1 through the ecrecover precompile
/// @notice Verifies a signature (r, s) over a 32-byte message for an x-only public key exactly as
///         BIP-340 specifies, except that keys with x >= n and challenges e = 0 are rejected
///         (each with probability about 2^-128 or less for honest keys and signatures).
///
/// Derivation. ecrecover(h, v, rr, ss) returns the address of Q = rr^-1 * (ss * R' - h * G), where
/// R' is the point with x = rr and parity v (27: even y). With rr = px, v = 27 (BIP-340 lifts the
/// key to even y), ss = (-e * px) mod n and h = (-s * px) mod n:
///     Q = px^-1 * (-e * px * P + s * px * G) = s * G - e * P,
/// which BIP-340 requires to be the even-y point with x = r. The library lifts r to its even-y
/// point and compares the two Ethereum addresses, so the comparison is on 160-bit hashes of the
/// points, the same strength as an Ethereum signature.
library BIP340 {
    uint256 internal constant P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    /// @dev (p + 1) / 4, the square-root exponent, since p = 3 mod 4
    uint256 internal constant SQRT_EXP = 0x3FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFBFFFFF0C;
    /// @dev sha256("BIP0340/challenge")
    bytes32 internal constant TAG_CHALLENGE = 0x7bb52d7a9fef58323eb1bf7a407db382d2f3f2d81bb1224f49fe518f6d48d37c;

    /// @dev The even-y point with x-coordinate x, through the modexp precompile.
    function liftXEven(uint256 x) internal view returns (bool ok, uint256 y) {
        if (x >= P) return (false, 0);
        uint256 c = addmod(mulmod(mulmod(x, x, P), x, P), 7, P);
        bool success;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 32)
            mstore(add(m, 0x20), 32)
            mstore(add(m, 0x40), 32)
            mstore(add(m, 0x60), c)
            mstore(add(m, 0x80), SQRT_EXP)
            mstore(add(m, 0xa0), P)
            success := staticcall(gas(), 0x05, m, 0xc0, m, 0x20)
            y := mload(m)
        }
        if (!success || mulmod(y, y, P) != c) return (false, 0); // not on the curve
        if (y & 1 == 1) {
            unchecked {
                y = P - y; // y < P: mulmod(y, y, P) == c was checked with y as returned by modexp mod P
            }
        }
        return (true, y);
    }

    /// @notice BIP-340 verification of (r, s) over the 32-byte message m. Never reverts.
    function verify(bytes32 px, bytes32 m, uint256 r, uint256 s) internal view returns (bool) {
        if (r >= P || s >= N) return false;
        uint256 pxi = uint256(px);
        if (pxi == 0 || pxi >= N) return false; // ecrecover takes px as its r argument, which must be below n
        uint256 e;
        assembly ("memory-safe") {
            let f := mload(0x40)
            mstore(f, TAG_CHALLENGE)
            mstore(add(f, 0x20), TAG_CHALLENGE)
            mstore(add(f, 0x40), r)
            mstore(add(f, 0x60), px)
            mstore(add(f, 0x80), m)
            if iszero(staticcall(gas(), 2, f, 0xa0, 0x00, 0x20)) { revert(0, 0) }
            e := mod(mload(0x00), N)
        }
        return _verifyChallenge(pxi, e, r, s);
    }

    /// @notice As verify, for a message of any length (the BIP-340 vectors include 0, 17 and 100 bytes).
    function verifyMsg(bytes32 px, bytes memory m, uint256 r, uint256 s) internal view returns (bool) {
        if (r >= P || s >= N) return false;
        uint256 pxi = uint256(px);
        if (pxi == 0 || pxi >= N) return false; // ecrecover takes px as its r argument, which must be below n
        uint256 e = uint256(sha256(abi.encodePacked(TAG_CHALLENGE, TAG_CHALLENGE, bytes32(r), px, m))) % N;
        return _verifyChallenge(pxi, e, r, s);
    }

    /// @dev The rest of verification once the challenge e is known (px and the ranges are checked).
    function _verifyChallenge(uint256 pxi, uint256 e, uint256 r, uint256 s) private view returns (bool) {
        if (e == 0) return false;
        uint256 ss;
        uint256 hh = mulmod(s, pxi, N);
        unchecked {
            ss = N - mulmod(e, pxi, N); // (-e * px) mod n, nonzero; mulmod(.., N) < N
            hh = hh == 0 ? 0 : N - hh; // (-s * px) mod n
        }
        address q = recover(bytes32(hh), 27, pxi, ss);
        if (q == address(0)) return false; // px is not on the curve
        (bool ok, uint256 ry) = liftXEven(r);
        if (!ok) return false;
        return q == pointAddress(r, ry);
    }

    /// @dev ecrecover(h, v, r, s), address(0) when the precompile returns nothing.
    function recover(bytes32 h, uint256 v, uint256 r, uint256 s) internal view returns (address a) {
        assembly ("memory-safe") {
            let f := mload(0x40)
            mstore(f, h)
            mstore(add(f, 0x20), v)
            mstore(add(f, 0x40), r)
            mstore(add(f, 0x60), s)
            mstore(0x00, 0)
            if iszero(staticcall(gas(), 1, f, 0x80, 0x00, 0x20)) { revert(0, 0) }
            a := mload(0x00)
        }
    }

    /// @dev The Ethereum address of the point (x, y): keccak256(x || y)[12:].
    function pointAddress(uint256 x, uint256 y) internal pure returns (address a) {
        assembly ("memory-safe") {
            mstore(0x00, x)
            mstore(0x20, y)
            a := and(keccak256(0x00, 0x40), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
