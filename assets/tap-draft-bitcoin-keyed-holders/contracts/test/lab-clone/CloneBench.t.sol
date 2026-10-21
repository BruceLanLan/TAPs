// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BitcoinKeyedHolder} from "../../src/BitcoinKeyedHolder.sol";
import {BaselineCode} from "../baseline/BaselineCode.sol";
import {BaselineVectors as V} from "../baseline/BaselineVectors.sol";
import {HolderImpl} from "./HolderImpl.sol";
import {CloneCode} from "./CloneCode.sol";

contract CloneToken {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && msg.sender == from, "not owner");
        ownerOf[id] = to;
    }
}

contract StipendSender {
    function send2300(address to) external payable returns (bool) {
        return payable(to).send(msg.value);
    }
}

/// Gas lab, measurement only: the clone design (shared implementation + 67/79-byte ERC-1167 clones
/// whose code ends with the scriptPubKey) against the main-line holder. Both are measured at the
/// baseline holder addresses with the baseline vectors, as in GasBench, and checked against the
/// baseline bytes on the same vectors.
contract CloneBenchTest is Test {
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes constant FACTORY_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    address impl;
    uint256 implDeployGas;

    function setUp() public {
        vm.etch(FACTORY, FACTORY_RUNTIME);
        vm.chainId(56);
        bytes memory cd = abi.encodePacked(bytes32(0), type(HolderImpl).creationCode);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = FACTORY.call(cd);
        implDeployGas = g - gasleft();
        require(ok && ret.length == 20, "impl");
        impl = address(bytes20(ret));
    }

    function viaFactory(bytes memory init) internal returns (bool ok, address at, uint256 used, bytes memory ret) {
        bytes memory cd = abi.encodePacked(bytes32(0), init);
        uint256 g = gasleft();
        (ok, ret) = FACTORY.call(cd);
        used = g - gasleft();
        if (ok) at = address(bytes20(ret));
    }

    /// The clone's runtime at `at` (as CREATE2 through the factory would leave it).
    function installClone(address at, bytes memory spk) internal {
        vm.etch(at, CloneCode.runtime(impl, spk));
    }

    function installMain(address at, bytes memory spk) internal {
        vm.etch(at, abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(spk)));
        (bool ok, bytes memory rt) = at.call("");
        require(ok, "ctor");
        vm.etch(at, rt);
    }

    function installBase(address at, bytes memory spk) internal {
        vm.etch(at, abi.encodePacked(BaselineCode.creationCode(), abi.encode(spk)));
        (bool ok, bytes memory rt) = at.call("");
        require(ok, "ctor");
        vm.etch(at, rt);
    }

    // ------------------------------------------------------------------ deployment

    function test_clone_deploy() public {
        emit log_named_uint("tx deploy shared implementation (once per chain)", implDeployGas);
        emit log_named_uint("implementation runtime bytes", impl.code.length);
        bytes[2] memory spks = [V.SPK_P2TR, V.SPK_P2WPKH];
        string[2] memory names = ["P2TR", "P2WPKH"];
        for (uint256 i = 0; i < 2; i++) {
            bytes memory init = CloneCode.creation(impl, spks[i]);
            assertEq(init.length, 68 + (i == 0 ? 132 : 100) + 45 + spks[i].length, "init layout");
            (bool ok, address at, uint256 used,) = viaFactory(init);
            assertTrue(ok, names[i]);
            assertEq(at.code, CloneCode.runtime(impl, spks[i]));
            assertEq(BitcoinKeyedHolder(payable(at)).scriptPubKey(), spks[i]);
            assertEq(BitcoinKeyedHolder(payable(at)).nonce(), 0);
            emit log_named_uint(string.concat("tx deploy clone ", names[i]), used);
            emit log_named_uint(string.concat("clone init code bytes ", names[i]), init.length);
            emit log_named_uint(string.concat("clone runtime bytes ", names[i]), at.code.length);
            (,, uint256 usedMain,) = viaFactory(abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(spks[i])));
            emit log_named_uint(string.concat("tx deploy main-line holder ", names[i]), usedMain);
        }
    }

    /// Unsupported scripts and value make the clone's creation revert, as the holder's constructor does.
    function test_clone_rejects_what_the_constructor_rejects() public {
        V.CtorCase[] memory cs = V.ctorCases();
        for (uint256 i = 0; i < cs.length; i++) {
            (bool okC,,, bytes memory retC) = viaFactory(CloneCode.creation(impl, cs[i].spk));
            (bool okM,,, bytes memory retM) =
                viaFactory(abi.encodePacked(type(BitcoinKeyedHolder).creationCode, abi.encode(cs[i].spk)));
            assertEq(okC, cs[i].accept, cs[i].name);
            assertEq(okM, cs[i].accept, cs[i].name);
            okC;
            retC;
            retM;
        }
        // the factory reverts without data in both cases, so check the selector by calling directly
        vm.expectRevert(HolderImpl.UnsupportedScript.selector);
        HolderImpl(payable(impl)).checkScript(hex"0020aaaa");
        (bool okV,) = FACTORY.call{value: 1}(abi.encodePacked(bytes32(uint256(1)), CloneCode.creation(impl, V.SPK_P2TR)));
        assertFalse(okV, "value");
    }

    // ------------------------------------------------------------------ calls, same address, same vectors

    function measureSign(uint256 k, bool clone) internal returns (uint256 txGas, uint256 staticGas, bytes4 res) {
        V.SignCase memory c = V.signCases()[k];
        vm.chainId(c.chainId);
        address at = c.holder == 0 ? V.HOLDER_P2TR : V.HOLDER_P2WPKH;
        bytes memory spk = c.holder == 0 ? V.SPK_P2TR : V.SPK_P2WPKH;
        if (clone) installClone(at, spk);
        else installMain(at, spk);
        bytes memory cd = abi.encodeCall(BitcoinKeyedHolder.isValidSignature, (c.digest, c.sig));
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = at.call(cd);
        txGas = g - gasleft();
        require(ok, "call");
        res = bytes4(ret);
        vm.cool(at);
        vm.cool(impl);
        g = gasleft();
        (ok,) = at.staticcall(cd);
        staticGas = g - gasleft();
    }

    function measureExec(uint256 k, bool clone) internal returns (uint256 used) {
        V.CallCase memory c = V.callCases()[k];
        vm.chainId(56);
        address at = c.holder == 0 ? V.HOLDER_P2TR : V.HOLDER_P2WPKH;
        bytes memory spk = c.holder == 0 ? V.SPK_P2TR : V.SPK_P2WPKH;
        if (clone) installClone(at, spk);
        else installMain(at, spk);
        vm.etch(c.target, type(CloneToken).runtimeCode);
        CloneToken(c.target).mint(at, 1);
        CloneToken(c.target).mint(at, 7);
        vm.deal(at, 1 ether);
        address relayer = makeAddr("relayer");
        vm.deal(relayer, 1 ether);
        vm.warp(c.deadline);
        bytes memory cd = abi.encodeCall(BitcoinKeyedHolder.execute, (c.target, c.value, c.data, c.gas, c.tip, c.deadline, c.sig));
        vm.prank(relayer);
        uint256 g = gasleft();
        (bool ok,) = at.call(cd);
        used = g - gasleft();
        assertTrue(ok, c.name);
        assertEq(BitcoinKeyedHolder(payable(at)).nonce(), 1);
        assertEq(relayer.balance, 1 ether + c.tip);
    }

    function test_clone_call_overhead() public {
        string[3] memory sn = ["isValidSignature P2TR", "isValidSignature P2WPKH", "isValidSignature P2TR SIGHASH_ALL"];
        for (uint256 k = 0; k < 3; k++) {
            uint256 snap = vm.snapshotState();
            (uint256 tm, uint256 sm, bytes4 rm) = measureSign(k, false);
            vm.revertToState(snap);
            (uint256 tc, uint256 sc, bytes4 rc) = measureSign(k, true);
            vm.revertToState(snap);
            assertEq(rm, bytes4(0x1626ba7e));
            assertEq(rc, rm);
            emit log_named_uint(string.concat("tx ", sn[k], " main-line"), tm);
            emit log_named_uint(string.concat("tx ", sn[k], " clone"), tc);
            emit log_named_uint(string.concat("static ", sn[k], " main-line"), sm);
            emit log_named_uint(string.concat("static ", sn[k], " clone"), sc);
        }
        string[3] memory en = ["execute ERC-721 transfer P2TR", "execute ERC-721 transfer P2WPKH", "execute ERC-721 transfer + tip P2WPKH"];
        uint256[3] memory ks = [uint256(0), 1, 3];
        for (uint256 i = 0; i < 3; i++) {
            uint256 snap = vm.snapshotState();
            uint256 m = measureExec(ks[i], false);
            vm.revertToState(snap);
            uint256 c = measureExec(ks[i], true);
            vm.revertToState(snap);
            emit log_named_uint(string.concat("tx ", en[i], " main-line"), m);
            emit log_named_uint(string.concat("tx ", en[i], " clone"), c);
        }
    }

    // ------------------------------------------------------------------ equivalence on the vectors

    /// Every baseline sign case at its baseline address: the clone answers as the baseline bytes do.
    function test_clone_matches_baseline_on_sign_vectors() public {
        V.SignCase[] memory cs = V.signCases();
        for (uint256 i = 0; i < cs.length; i++) {
            vm.chainId(cs[i].chainId);
            address at = cs[i].holder == 0 ? V.HOLDER_P2TR : cs[i].holder == 1 ? V.HOLDER_P2WPKH : V.HOLDER_P2TR_OTHER;
            bytes memory spk = cs[i].holder == 0 ? V.SPK_P2TR : cs[i].holder == 1 ? V.SPK_P2WPKH : V.SPK_P2TR_OTHER;
            bytes memory cd = abi.encodeCall(BitcoinKeyedHolder.isValidSignature, (cs[i].digest, cs[i].sig));
            uint256 snap = vm.snapshotState();
            installBase(at, spk);
            (bool okA, bytes memory a) = at.staticcall(cd);
            bytes memory ma = BitcoinKeyedHolder(payable(at)).signMessage(cs[i].digest);
            vm.revertToState(snap);
            installClone(at, spk);
            (bool okB, bytes memory b) = at.staticcall(cd);
            bytes memory mb = BitcoinKeyedHolder(payable(at)).signMessage(cs[i].digest);
            vm.revertToState(snap);
            assertTrue(okA && okB, cs[i].name);
            assertEq(a, b, cs[i].name);
            assertEq(ma, mb, cs[i].name);
            assertEq(bytes4(a) == 0x1626ba7e, cs[i].expect, cs[i].name);
        }
    }

    /// Calling the implementation directly gives no authority: it has no key.
    function test_implementation_alone_has_no_key() public {
        V.SignCase memory c = V.signCases()[1];
        assertEq(HolderImpl(payable(impl)).isValidSignature(c.digest, c.sig), bytes4(0xffffffff));
        assertEq(HolderImpl(payable(impl)).scriptPubKey(), hex"00140000000000000000000000000000000000000000");
    }

    /// A behavioural difference: a 2,300-gas stipend transfer (Solidity send/transfer) to a clone fails,
    /// because the proxy's DELEGATECALL to a cold implementation alone costs 2,600. The main-line
    /// holder's empty receive() accepts it.
    function test_clone_rejects_stipend_transfers() public {
        StipendSender s = new StipendSender();
        installMain(V.HOLDER_P2TR, V.SPK_P2TR);
        assertTrue(s.send2300{value: 1}(V.HOLDER_P2TR), "main-line accepts a 2,300-gas transfer");
        installClone(V.HOLDER_P2WPKH, V.SPK_P2WPKH);
        assertFalse(s.send2300{value: 1}(V.HOLDER_P2WPKH), "clone: out of gas in the DELEGATECALL");
    }
}
