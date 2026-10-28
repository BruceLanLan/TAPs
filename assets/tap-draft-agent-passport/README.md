# Assets: Agent Passports for Container Services

Reference implementation and vectors for `../../TAPs/TAP-draft-agent-passport.md`. Python 3.9+, standard library only;
an optional cross-check uses Foundry `cast` when installed. Code is MIT; everything else CC0.

| File | Content |
|---|---|
| `passport.py` | Read-only verifier. Input: a snapshot (below); output: state word, reasons, warnings, holder epoch, display text, and on request the §10 feedback summary. Also: `tap.passport` encoding (§4), registration-file checks (§5), the listing digest and its ECDSA or EIP-1271 acceptance (§5.5), canonical JSON (TAP-11 §6), forbidden names (§5.4), the #54 review hash, the §10.2 `giveFeedback` arguments, and the W-1 to W-3 checks. `python3 passport.py <snapshot.json>` prints the result |
| `make_vectors.py` | Writes `vectors.json` deterministically; `--check` compares with the file on disk. Every case has a hand-written expectation, and the generator stops if the verifier disagrees |
| `vectors.json` | 175 cases, SHA-256 `a03e690d7ec7e0d96435d0bd71768829e114b324d792bbc2150c527f2c856066` (resolution 97, feedback 22, passportKey 10, forbiddenNames 20, canonicalJson 4, runtimeCalls 12, delegationProposals 6, feedbackParams 1, listingSignatures 3) plus the `interfaces` table, the published test keys under `constants.testKeys` and, under `constants.confusables`, the confusable table of Specification §5.4 |
| `test_passport.py` | 23 tests (with subtests over every case): replays all vectors, recomputes selectors and hashes, checks that every machine-checkable rule has a vector, reproducibility, UNAVAILABLE never caused by a binding fact, that no state word changes when every log answer is removed, that no §10 summary is computed without a holder epoch, the listing digests and signatures, `secp256k1.py` against TAP-11's published delegation signature, display wording, and canonical-JSON edge cases; cross-checks with `cast` when present |
| `secp256k1.py` | Minimal secp256k1: `recover` (with the range checks of TAP-11 §4.4) for the verifier, and deterministic `sign` (RFC 6979, low `s`) used only to build the vectors with the published test keys. Not constant-time; never use it with a real key |
| `IERC8004PassportSubset.sol` | The ERC-8004 interface subset of Specification §2 item 4, with selectors |
| `keccak.py` | Keccak-256 (vendored, below) |

```bash
python3 make_vectors.py --check && python3 test_passport.py
```

## Snapshot format (`tap-agent-passport-snapshot/1`)

```
{ "format": "tap-agent-passport-snapshot/1",
  "source": "synthetic" | "bsc-mainnet-read",
  "config": { chainId, identityRegistry, identityImplementations[], reputationRegistry, reputationImplementations[],
              factory, opener, siteRegistry, siteRegistryImplementations[] },
  "input": { "agentId": "<decimal>" } | { "circuit": { "processor": "0x…", "tokenId": "<decimal>" } },
  "pinnedBlock": <number>,
  "answers": { <read key>: <answer>, … },                  // answers common to all operators
  "operators": { <name>: { "head": <number>, "answers": { <read key>: <answer or null>, … } } },
  "review54": { <review hash>: { "counted": bool, "level": 0|1|2 } },  // optional, results of a #54 verifier
  "summary": { "clientAddresses": ["0x…", …], "maxEntries": <n> }      // §10.3 F-0: the named client set (required
}                                                                       // for a summary) and an optional bound
```

An operator's answer for a key is its own entry if present (`null` = no answer), otherwise the common one. A read is
adopted only when every operator that answered agrees and at least max(2, min(3, operators)) answered. Read keys:
`eth_chainId`; `block` (`{hash, timestamp}`); `implSlot:<proxy>`; `code:<address>` for `eth_getCode` (answer: hex,
`"0x"` for none); `<contract>.<function>(<args>)` for `eth_call` (answer: ABI-encoded return data as hex, or
`{"revert": "0x…"}`), including `<owner>.isValidSignature(<digest>,<sig>)` for the EIP-1271 branch of §5.5;
`logs.OperatorSet(<container>)`,
`logs.Transfer.identity(<agentId>)`, `logs.Transfer.circuit(<processor>,<tokenId>)`, `logs.NewFeedback(<agentId>)`
(answer: a decoded list, or `{"unavailable": true}`). A missing `logs.*` read is treated as unobtainable, never as an
empty list, and never changes the state word (Specification §6.4); a missing `logs.OperatorSet` read means the
optional operator check was not attempted. The #54 verdicts are an input because verifying #54 records
(signatures, evidence) belongs to #54's own reference implementation.

## Real reads

Two resolution cases (`source: bsc-mainnet-read`) use answers read from BNB Smart Chain at block **129353737**
(hash `0xc8c2af8680fe6d23f826e1089e00a605b8b52605df7ab746a787f463592cf0f9`, timestamp 1792772831 =
2026-10-23T16:27:11Z) from two operators, `https://bsc-dataseed.binance.org` and `https://bsc-rpc.publicnode.com`,
whose answers were identical. These are the endpoints used at the time of writing; naming them is not an
endorsement of their operators and no guarantee that they will keep serving these reads. Other read-only facts cited
by the specification:

| Fact | Block | How |
|---|---|---|
| Implementation slots of the three ERC-8004 proxies; implementation code hashes; container `supportsInterface(0x1626ba7e)` = false; beacon owner = Safe, threshold 3, 5 owners | 129353469 | two operators above, identical |
| Selectors of identity and reputation implementations found in bytecode; `AgentWalletSet` type hash in bytecode; `eip712Domain()`; `getVersion()` = "2.0.0" on all three registries; `getSummary(1, [], "", "")` reverts `clientAddresses required` | 129353333 | `bsc-dataseed.binance.org` |
| Site store selectors (`putFile`, `appendChunk`, `setOperator`, `fileInfo`, `read`) and the `OperatorSet` topic in implementation `0x1d279D…c261`; factory `isCPU`, `cpuAt` | 129355254 | `bsc-dataseed.binance.org` |
| Registration with metadata, transfer clearing `agentWallet` and keeping URI and metadata, reserved key, gift identity, self-signed `setAgentWallet` (+240 s accepted, +400 s rejected) | fork of 129352831 | local anvil fork, throwaway keys |

Everything else in `vectors.json` is synthetic. Synthetic addresses are `keccak256("tap-agent-passport synthetic <n>")[12:]`
and belong to nobody. The holders that sign listings use published test keys (`constants.testKeys`): the holder is
`0x` followed by 64 digits `1` (address `0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A`, the test holder of TAP-11's
vectors), the former holder 64 digits `2`, and the owner behind the synthetic contract holder 64 digits `3`. Anyone can
sign with these keys; never use them for anything else. No transaction was sent to any public chain.

## Log queries on keyless public nodes (Specification §6.4)

Informative, measured on 2026-10-28 with `eth_getLogs` from one machine; the endpoints are those tried at the time of
writing, not an endorsement and not a guarantee, and limits change without notice. Spot checks repeated later the
same day are given where they differ.

| Endpoint | Result |
|---|---|
| `bsc-rpc.publicnode.com` | Ranges of at most 5,000 blocks and 20,000 results; first run: only about the last 8,000 to 9,000 blocks, older ranges HTTP 403. Spot check: a 2-block range 200,000 blocks back served; 2,000,000 or more blocks back refused (HTTP 403, "archive requests require a personal token") |
| `1rpc.io/bnb` | At most 50 blocks per query |
| `bsc-dataseed.binance.org` (BNB Chain) | "limit exceeded" at 1,000 blocks (spot check: also at 999 blocks on `bsc-dataseed1.bnbchain.org`) |
| `bsc.drpc.org` | HTTP 400 or 429 in the first run; a 10-block recent range served in the spot check |
| `bsc-mainnet.public.blastapi.io` | HTTP 429 on `eth_getLogs`; historical `eth_call` works |
| `bsc.meowrpc.com` | `eth_getLogs` not supported |
| Ankr public endpoint | Needs an API key |

No endpoint served `eth_getLogs` from the first block. A holder epoch or an operator scan from the mint at 5,000 blocks per
query would take tens of thousands of queries per token on the endpoint that allowed the widest range, and strict
agreement needs the same answers from at least two operators.

## Included copy

| File | Origin | SHA-256 |
|---|---|---|
| `keccak.py` | Lines 38–82 of `assets/tap-draft-design-credits/credits.py` (that file's SHA-256 `7204a16d0610695267f8c925f67935c67368d14feca98d5d55ec651e69122dab`), copied unchanged; only a header was added. The copied lines hash to `6502131244d17916e547c33e6e6ecd3e32bc5509d65956202af8d5dec6933566` in both files | `323f07502cb465cdb3ae3fe6c4013375d1b6902314a66f67cc8a98e8b006d292` |
| `IERC8004PassportSubset.sol` | Written for this TAP from the deployed interface (not a copy) | `705d54dd747ddf78ac2d15860262ac1f7b3d05fc75c1e449fe50a7206bbae135` |
| `secp256k1.py` | Written for this TAP (not a copy); checked against TAP-11's `assets/tap-11/delegation.json` | `2ea9be0cca9db626a991d9ab43898990f2ef83954fd50b23d75628d0427c1c55` |

## Confusable table (Specification §5.4)

The normative copy is `constants.confusables` in `vectors.json` (code point to Latin letter); this rendering is for
reading. Chosen with reference to UTS #39 `confusables.txt` of Unicode 15.1.0; a documented subset, not the full data.
Capitals are mapped through their lowercase form.

| Latin | Cyrillic | Greek |
|---|---|---|
| a | а U+0430 | α U+03B1 |
| b | в U+0432 | β U+03B2 |
| c | с U+0441 | |
| d | ԁ U+0501 | |
| e | е U+0435 | ε U+03B5 |
| h | һ U+04BB, н U+043D | |
| i | і U+0456 | ι U+03B9 |
| j | ј U+0458 | |
| k | к U+043A | κ U+03BA |
| l | ӏ U+04CF | |
| m | м U+043C | |
| o | о U+043E | ο U+03BF |
| p | р U+0440 | ρ U+03C1 |
| q | ԛ U+051B | |
| s | ѕ U+0455 | |
| t | т U+0442 | τ U+03C4 |
| u | | υ U+03C5 |
| v | | ν U+03BD |
| w | ԝ U+051D | |
| x | х U+0445 | χ U+03C7 |
| y | у U+0443 | |

## Threat model (Specification, Security Considerations)

| # | Threat | Outcome under this TAP | Rules |
|---|---|---|---|
| T1 | **Gift identity**: a stranger registers an identity naming a victim's circuit and transfers it to the victim (measured: no consent needed, `agentWallet` becomes zero, the stranger's URI and metadata stay) | BROKEN `not-listed`; if the victim lists and signs it, `wallet-unset` until the victim self-signs `setAgentWallet` | P-8, P-9, P-10 |
| T2 | Repeated gifts to force AMBIGUOUS (measured: unlimited) | No effect: only identities the holder lists count | P-10 |
| T3 | The circuit is sold; the old identity keeps acting as the passport | BROKEN `holder-mismatch` | P-1 |
| T4 | Both tokens are sold together (bought reputation) | BROKEN `listing-not-by-holder` until the buyer signs a listing, then `wallet-unset` until `setAgentWallet`; earlier reputation is not attributed (with the history tier), and no summary is shown without it | P-8, P-9, E-1, E-2, F-7 |
| T5 | A site operator set by the previous holder rewrites the registration file (for example to list a gifted identity) | It can break the passport (BROKEN or AMBIGUOUS) but not forge one: the copied listing does not verify for another identity (`listing-not-by-holder`); a tool with the history tier also warns `stale-operator` | P-8, §6.4 |
| T6 | A malicious onboarding contract writes files or leaves an operator | Cannot sign a listing; caught by re-reading every file before relying on the result | P-8, W-3, W-5 |
| T7 | Cross-chain or cross-contract replay of the key or the listing | BROKEN `chain-mismatch` or `not-listed` | P-3 |
| T8 | Lying or colluding nodes; registry upgrade under its owner | UNAVAILABLE | P-6, S-4 |
| T9 | Text read by a language model steers it into transfers, approvals or a long delegation to a stranger's key | Calls refused by the runtime; signers only from the tool's own session; short default expiry | W-1, W-2, W-3 |
| T10 | Replaying someone else's valid review | Excluded | F-3, F-6 |
| T11 | Flooding an identity with feedback to exhaust summary tools | Only named clients are fetched; a bounded tool reports `summary-truncated` | F-0 |
| T12 | Custodial holder frozen or lost; credentials bound to the custodial address | Not prevented (Security Considerations) | W-1 |
| T13 | **Gift circuit**: a stranger copies the holder's registration file into a circuit it controls and transfers that circuit to the holder | BROKEN `key-circuit-mismatch` when resolved by that circuit; the real passport is unaffected | P-11 |
| T14 | A writer of the site puts back an older registration file whose listing the current holder signed earlier for the same container | Not prevented: the older identity can resolve CONFIRMED and the current one `not-listed`; holders clear the key of identities they stop using (Security Considerations; open question 8) | P-8 |

## Onboarding with a custodial agent wallet (detail of Specification Appendix A)

Informative. Read from the public skill files named in Appendix A on 2026-10-23. Commands: `baw contract-call
preview|execute --binanceChainId 56 --from <wallet> --to <contract> --value <wei> --inputData <hex>` and
`baw sign-message preview|execute --binanceChainId 56 --signType EIP712 --message
'{"method":"eth_signTypedData_v4","params":[<wallet>,<typed data>]}'`.

**Steps for an agent that offers a service.** Fees are protocol fees read from the chain at the time; the figures below are readings of 2026-09-30, not re-read, and are not part of the specification.

| # | Step | Kind | Notes |
|---|---|---|---|
| 0 | Pair the CLI and enable Developer Mode in the app | One-time, in the app | Developer Mode has an expiry and its own daily limit |
| 1 | Mint a circuit on a processor with a zero mint price | Contract call | About 0.0001 BNB protocol fee |
| 2 | Tape out the circuit | Contract call | About 0.0002 BNB |
| 3 | Open the container | Contract call | About 0.012 BNB |
| 4 | Generate the TAP-11 signer locally; sign the delegation (W-1: 7 days by default) | EIP-712 signature | Only when offering a service |
| 5 | Write the manifest (`putFile`) | Contract call | Only when offering a service |
| 6 | `register(agentURI, [("tap.passport", abi.encode(56, processor, tokenId))])` | Contract call | `agentWallet` becomes the wallet; read `agentId` from the event |
| 7 | Sign the listing `PassportListing(agentId, identity registry, container, issued)` (§5.5) | EIP-712 signature | Values from the receipt and chain reads only (W-5); check that it recovers to the wallet |
| 8 | Write the registration file listing `agentId` with `tap.listing` (`putFile`), then resolve under §6 | Contract call, then reads | Re-read every written file before relying on the result |

Counts: **6 contract calls and 2 signatures** for an agent that offers a service, **5 calls and 1 signature** for an identity without a service. Both signatures are EIP-712 typed data, which the wallet signs with `--signType EIP712`; no `personal_sign` is needed. Each call and signature may or may not require a confirmation in the app, depending on the provider's risk policy, so the number of confirmations is between 0 and 8, plus the one-time pairing and Developer Mode. The listing and the registration file come after `register` because the `agentId` is not known before it.

**What the wallet provider must do: nothing.** Every step uses documented commands.

**What the author must do before calling this usable:** run the flow once on mainnet with his own wallet and a small amount, recording the risk results and confirmations; verify the source of every TapeOut contract the flow calls on the block explorer, since unverified contracts may be flagged; publish the onboarding tool at a fixed commit; decide whether to propose it to the provider's skill repository.

**Unknowns:** whether the provider's risk engine blocks or flags calls to the TapeOut contracts; how the app displays non-Permit typed data such as a delegation (likely as raw JSON); whether signatures count against Developer Mode's daily limit; the exact rule for assembling the 65-byte signature from the returned signature and recovery identifier (`v = 27 + recovery` is an inference, not documented); the authoritative list of supported chains (no test network is documented, so no end-to-end test-network demonstration is possible with this wallet).

**What must not be claimed:** a partnership, integration, endorsement or official support by Binance or BNB Chain; that the wallet is a smart-contract account or has session keys; that gas sponsorship applies to these transactions; that USDT or USDC on BNB Smart Chain support EIP-3009 (only U and USD1 do); that BEM supports EIP-3009 or EIP-2612; any daily-limit figure from press reports; that a passport is a verification, a credential or a source of income; "first" of anything.

## Example A2A agent card (Specification Appendix B)

Example (informative):

```json
{
  "name": "digits-agent",
  "description": "Classifies 8x8 digit images; every answer is signed.",
  "version": "0.1+3fa2c1d0",
  "supportedInterfaces": [{"url": "https://agent.example/a2a", "protocolBinding": "JSONRPC", "protocolVersion": "1.0"}],
  "capabilities": {"streaming": false, "pushNotifications": false},
  "defaultInputModes": ["application/json"],
  "defaultOutputModes": ["application/json"],
  "skills": [{"id": "classify-digits", "name": "classify-digits", "description": "One 8x8 image in, one digit out.", "tags": ["vision"]}]
}
```
