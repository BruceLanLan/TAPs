// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Gas lab, measurement only. Creation code of a clone holder for `impl` and `spk`:
///
///   header (68 bytes) || checkScript(spk) calldata || runtime
///   runtime = ERC-1167 proxy for impl (45 bytes) || spk (22 or 34 bytes, never executed)
///
/// The header rejects value, STATICCALLs impl.checkScript(spk) and bubbles its revert (so an
/// unsupported script reverts with UnsupportedScript() as the holder's constructor does), then
/// returns the runtime. Deployed through the deterministic deployment proxy, the clone's address
/// depends only on impl and spk.
library CloneCode {
    bytes4 internal constant CHECK_SCRIPT = bytes4(keccak256("checkScript(bytes)"));

    function runtime(address impl, bytes memory spk) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3", spk);
    }

    function creation(address impl, bytes memory spk) internal pure returns (bytes memory) {
        bytes memory cd = abi.encodeWithSelector(CHECK_SCRIPT, spk);
        bytes memory rt = runtime(impl, spk);
        uint256 h = 68; // header length
        return abi.encodePacked(
            hex"34156008575f5ffd5b", // 00: CALLVALUE ISZERO PUSH1 0x08 JUMPI PUSH0 PUSH0 REVERT; 08: JUMPDEST
            hex"5f5f61", uint16(cd.length), // 09: PUSH0 PUSH0 PUSH2 cdLen          [cdLen 0 0]
            hex"8061", uint16(h), // 0e: DUP1 PUSH2 cdOff                         [cdOff cdLen cdLen 0 0]
            hex"5f39", // 12: PUSH0 CODECOPY(0, cdOff, cdLen)                       [cdLen 0 0]
            hex"5f73", impl, // 14: PUSH0 PUSH20 impl                               [impl 0 cdLen 0 0]
            hex"5afa", // 2a: GAS STATICCALL                                        [ok]
            hex"61", uint16(0x37), hex"57", // 2c: PUSH2 0x0037 JUMPI
            hex"3d5f5f3e3d5ffd", // 30: RETURNDATACOPY(0, 0, rds) REVERT(0, rds)
            hex"5b61", uint16(rt.length), // 37: JUMPDEST PUSH2 rtLen               [rtLen]
            hex"8061", uint16(h + cd.length), // 3b: DUP1 PUSH2 rtOff               [rtOff rtLen rtLen]
            hex"5f39", // 3f: PUSH0 CODECOPY(0, rtOff, rtLen)                       [rtLen]
            hex"5ff3", // 41: PUSH0 RETURN(0, rtLen)
            hex"00", // 43: padding to 68 bytes (never reached)
            cd,
            rt
        );
    }
}
