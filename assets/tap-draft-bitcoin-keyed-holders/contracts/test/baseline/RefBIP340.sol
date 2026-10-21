// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Frozen copy of src/BIP340.sol at the baseline (lab commit 834787a), used as the reference in differential tests.

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
library RefBIP340 {
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
        if (y & 1 == 1) y = P - y;
        return (true, y);
    }

    /// @notice BIP-340 verification of (r, s) over the 32-byte message m. Never reverts.
    function verify(bytes32 px, bytes32 m, uint256 r, uint256 s) internal view returns (bool) {
        return verifyMsg(px, abi.encodePacked(m), r, s);
    }

    /// @notice As verify, for a message of any length (the BIP-340 vectors include 0, 17 and 100 bytes).
    function verifyMsg(bytes32 px, bytes memory m, uint256 r, uint256 s) internal view returns (bool) {
        if (r >= P || s >= N) return false;
        uint256 pxi = uint256(px);
        if (pxi == 0 || pxi >= N) return false; // ecrecover takes px as its r argument, which must be below n
        uint256 e = uint256(sha256(abi.encodePacked(TAG_CHALLENGE, TAG_CHALLENGE, bytes32(r), px, m))) % N;
        if (e == 0) return false;
        uint256 ss = N - mulmod(e, pxi, N); // (-e * px) mod n, nonzero
        uint256 hh = mulmod(s, pxi, N);
        hh = hh == 0 ? 0 : N - hh; // (-s * px) mod n
        address q = ecrecover(bytes32(hh), 27, px, bytes32(ss));
        if (q == address(0)) return false; // px is not on the curve
        (bool ok, uint256 ry) = liftXEven(r);
        if (!ok) return false;
        return q == address(uint160(uint256(keccak256(abi.encode(r, ry)))));
    }
}
