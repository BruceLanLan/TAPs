# Assets: Circuit Jobs: Settling Agent Jobs by a Dispute Game

Reference functions and vectors for `../../TAPs/TAP-draft-circuit-jobs.md`. Python 3.9+, standard library only.
Nothing here reads a chain or sends a transaction; nothing is deployed.

| File | Content |
|---|---|
| `circuit_jobs.py` | a small keccak-256; `selector`, `event_topic`, `interface_id` and the identifiers of `ITapClaimSummary` (`0x58d08546`), `ITapSettlementBound` (`0xfcd8e94e`), `ITapInputProvider` (`0xecef2c34`), `IACPHook` (`0x7ff6bc9e`) and `ITapCircuitJob` (`0x0b2be2a6`); `abi_encode` for static types; the job spec (`spec_encode`, `spec_hash`), the deliverable (`deliverable_of`, the claim id as one word) and `reason_of`; the kernel job states (0 Open … 5 Expired) and claim states (0 none … 4 abandoned), `decision` (status 0 reverts), `state_row`; the J-2/J-3 arithmetic (`required_expiry`, `expiry_ok`, `required_window_end`, `window_ok`), the constructor conditions (`constants_ok`) and `latest_bind_time`; `bind_check`, `fund_check`, `submit_check`, `settle_check` returning the first broken check in the order of the draft; `hook_rule_check`, `hook_dispatch`; and the facts measured on a local fork of chain 56 at block 129,352,831: `HOOK_CALLBACKS` and `hook_data` (the kernel's hook `data` encodings), `kernel_allows` (authorisation matrix), `kernel_time_rule`, `create_expiry_ok`, `settlement_guaranteed` |
| `make_vectors.py` | writes `vectors.json` (deterministic; `--check` compares) |
| `test_circuit_jobs.py` | 22 tests: keccak known answers; every selector against values confirmed with Foundry `cast sig` and against `cast` itself when installed; `abi.encode(bytes32,bytes)` against `cast abi-encode`; `specHash` sensitivity to every field; J-2/J-3 boundaries; constructor conditions and `ACCEPT_GAS_CAP`; every vector section recomputed; the order of the `bindJob` and `afterAction(submit)` checks; the measured kernel matrix, time rules and hook encodings |

```bash
python3 make_vectors.py --check && python3 test_circuit_jobs.py
```

`vectors.json` SHA-256: `76a64e4d435260d93f1ede3c9a810be2895643db8becb0a0ad07316d4fa48662` (format `tap-circuit-jobs-vectors/1`, 194 cases).

`maxSettlementSeconds` in the vectors is an arbitrary input chosen for them (1,368,992 s, about 15.85 days); it is never recomputed here, because the draft depends on the semantics of that view and not on its formula. `constants.ACCEPT_GAS_CAP` (200,000) is the gas `settle` gives the optional `game.accept` (draft §6.2). All addresses are placeholders except the two kernel proxies (`0xEa4DAa31…EBA6` on 56, `0xa206c051…B0DE` on 97) and the two implementation addresses read from their EIP-1967 slots on 2026-10-24.

A Solidity reference is planned, not written (Reference Implementation of the draft). The procedure that produced the measured facts, and that is repeated before any deployment, is Annex B of the draft.
