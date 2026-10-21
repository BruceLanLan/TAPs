// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LibHarness} from "./AuditLib.sol";

/// Signatures from the test suite of Drongo, the library behind Sparrow Wallet's BIP-322 message signing
/// (drongo commits c0555c3 and f47d5de, `Bip322Test.java`, WIF key L3VFeEuj..., the one key behind all four).
/// Sparrow itself (a desktop GUI) was not run; this checks that the byte strings its library emits verify under
/// BIP322.sol. Of note: the P2TR witness is 65 bytes (explicit SIGHASH_ALL 0x01), unlike the 64-byte
/// SIGHASH_DEFAULT signatures of the other four wallets, and one P2WPKH signature has a 72-byte DER form.
contract SparrowDrongoTest is Test {
    LibHarness h;

    bytes20 constant WP = bytes20(hex"2b05d564e6a7a33c087f16e0f730d1440123799d"); // bc1q9vza2e8x573nczrlzms0wvx3gsqjx7vavgkx0l
    bytes32 constant TR = bytes32(hex"0b34f2cc6f60d54e3fdc2d1dd053fcc393bd2db9acc8de4a7c3cc28a83d4d8e9"); // bc1ppv609nr0vr25u07u95waq5lucwfm6tde4nydujnu8npg4q75mr5sxq8lt3

    bytes constant W_EMPTY =
        hex"024730440220336801010aaf657d79662cac98a990a43ac6f376af2c84f8f76401ccb9d0231602201693a4e683db4a91944ca5cb11527840366daf583a2c695fccf8e93483b52e34012102c7f12003196442943d8588e01aee840423cc54fc1521526a3b85c2b0cbd58872";
    bytes constant W_HELLO =
        hex"0247304402206517c8637a7bfc3a154edcba6196d64bbd5b73955cb7da7d1626bcdde466c364022022bf10d19fc0bb69b4596e306b362acaa835293cf693bb176f7324b531f5afec012102c7f12003196442943d8588e01aee840423cc54fc1521526a3b85c2b0cbd58872";
    bytes constant W_HELLO_72 =
        hex"02483045022100ecf2ca796ab7dde538a26bfb09a6c487a7b3fff33f397db6a20eb9af77c0ee8c022062e67e44c8070f49c3a37f5940a8850842daf7cca35e6af61a6c7c91f1e1a1a3012102c7f12003196442943d8588e01aee840423cc54fc1521526a3b85c2b0cbd58872";
    bytes constant W_TR =
        hex"0141ddebd3eb25012ffa82937d9f25f9644e047bb2f472ab6c5089bbb53588ada2884cb5bcc53911f32d8dcf9548733b694d120db6a4e485194559e8d8fe668d269f01";

    function setUp() public {
        h = new LibHarness();
    }

    function test_p2wpkh_empty_message() public view {
        assertTrue(h.p2wpkh(WP, "", W_EMPTY));
        assertFalse(h.p2wpkh(WP, "Hello World", W_EMPTY));
    }

    function test_p2wpkh_hello_world() public view {
        assertTrue(h.p2wpkh(WP, "Hello World", W_HELLO));
        assertFalse(h.p2wpkh(WP, "", W_HELLO), "the signature for Hello World does not verify the empty message");
    }

    function test_p2wpkh_hello_world_72_byte_der() public view {
        assertTrue(h.p2wpkh(WP, "Hello World", W_HELLO_72));
    }

    function test_p2tr_hello_world_explicit_sighash_all() public view {
        assertEq(W_TR.length, 67, "1 item count + 1 length + 65");
        assertEq(uint8(W_TR[W_TR.length - 1]), 0x01, "SIGHASH_ALL byte");
        assertTrue(h.p2tr(TR, "Hello World", W_TR));
        assertFalse(h.p2tr(TR, "", W_TR));
    }
}
