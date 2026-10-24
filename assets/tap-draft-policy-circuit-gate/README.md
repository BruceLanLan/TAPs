# Assets: Policy Circuit Gate

Reference implementation and vectors for `../../TAPs/TAP-draft-policy-circuit-gate.md`. Python 3.9+, standard library
only; an optional cross-check of the EIP-712 signatures runs when `eth_account` is installed.

| File | Content |
|---|---|
| `policy_gate.py` | policy-file check (pins 128/8, size, stateful flag), result interpretation (fail closed), tables and request checks, the 128-bit request word, one-request evaluation and trace replay (combinational and stateful, escrow cumulative deltas), `PolicyBinding` / `PolicyBindingRevocation` (EIP-712, TAP-11 domain) with the ordered checks, revocation cover, the two `tap.policy` members, canonical JSON (integers only) |
| `examples.py` | a NAND/LATCH builder and five policies built programmatically, each with a Python oracle: `daily-cap` (stateful: 16-bit accumulator, 16-bit day, `seen` bit), `allowlist` (counterparty classes), `time-window` (UTC hours, weekdays), `deny-all`, `per-asset-limits`. `python3 examples.py` writes `policies/*.tapnet` |
| `policies/*.tapnet` | the five example policy files (`tapnet/1`) |
| `make_vectors.py` | writes `vectors.json` (deterministic; `--check` compares and exits 1 on a difference) |
| `vectors.json` | 163 cases (SHA-256 `6232d588ba3ebb8faae8498b2a2040f2d56f9dc2afe30980a585d3abd942c93e`): policy checks, result bytes, request encodings and errors, tables errors, word decoding, evaluations, traces, bindings, revocations, token and subject `tap.policy` members, plus constants (layout, typehashes, domain separators) |
| `test_policy_gate.py` | regenerates the vectors byte for byte (also under `python3 -I` from another directory), checks that no binding vector is enforceable without a checked file, for a label or when an account signed its own binding, checks the vendored files' SHA-256, differential tests of every example circuit against its oracle (4,000 random requests each, stateful sequences included), exhaustive time-window check, fail-closed result table, EIP-712 round trips and the `eth_account` cross-check, subject forms, canonical JSON |
| `tapnft.py`, `tap02_reference.py` | copied unchanged from `assets/tap-draft-netlist-bound-nft/` (TAP-721 core draft): `tapnet/1` files and the TAP-02 evaluator |
| `credits.py`, `canon.py` | copied unchanged from the Soulbound Credentials draft (originally the Design Credits draft): keccak-256, secp256k1 sign / recover. Only those are used; the EIP-712 encoding of this TAP is in `policy_gate.py` because its domain is TAP-11's |

Vendored file digests (SHA-256), also recorded in `vectors.json` under `vendored` and checked by the tests:

| File | SHA-256 |
|---|---|
| `tapnft.py` | `7730ae49750cefc17da00b9e800fb4f87655fed354a2251526768c9904d94527` |
| `tap02_reference.py` | `88c777b6b773ccb89a058f3b2d0bb52f255eb753578ea5fd4ee9bae14b1b7808` |
| `credits.py` | `7204a16d0610695267f8c925f67935c67368d14feca98d5d55ec651e69122dab` |
| `canon.py` | `c3571dd13a772320abe90842d917c599d65b5e528b73e0044e6cc78f8832fe68` |

The three scripts insert their own directory into `sys.path`, so every command below also works as `python3 -I <path>/<script>` from any directory.

```bash
python3 examples.py                 # (re)write policies/*.tapnet and print sizes and hashes
python3 make_vectors.py && python3 make_vectors.py --check
python3 test_policy_gate.py      # 20 tests
```

All private keys in `vectors.json` are public test keys, `keccak256("tap-policy-gate test key <n>")`. Never use them.
Every value is synthetic: no chain was read and no transaction was sent. There is no Solidity in this folder; the
on-chain call convention of the draft is specified against `ITapNetlistEval` of the TAP-721 core draft and has not
been implemented or measured here.
