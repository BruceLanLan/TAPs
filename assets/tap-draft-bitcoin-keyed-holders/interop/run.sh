#!/usr/bin/env bash
# r8-interop: an UNMODIFIED TAP-11 client (github.com/BruceLanLan/tapeapi SDK) accepts a holder delegation signed by a
# Bitcoin key through the Bitcoin-keyed holder contract, on a LOCAL anvil fork of BNB Smart Chain. Nothing is broadcast.
#
#   bash run.sh            (writes run.log next to it)
#
# Needs: foundry v1.8.3 (anvil, cast), node >= 20, python3, the tap-bitcoin-keyed-holders repo (tools/, vectors/),
# and the tapeapi clone in ./tapeapi with its deps installed (git clone https://github.com/BruceLanLan/tapeapi && npm ci).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
FOUNDRY="${FOUNDRY:-$HOME/.foundry/versions/foundry-rs/foundry/v1.8.3}"
ANVIL="$FOUNDRY/anvil"; CAST="$FOUNDRY/cast"
REPO="${TAP_REPO:-$(cd "$HERE/.." && pwd)}"
export TAP_TOOLS="$REPO/tools" TAP_VECTORS="$REPO/vectors"
PORT="${PORT:-8545}"; R="http://127.0.0.1:$PORT"
FORK_URLS=(${FORK_URL:-https://bsc-mainnet.public.blastapi.io https://bsc-rpc.publicnode.com})

# BNB Smart Chain, chainId 56 (tapeapi sdk/src/chains.js, read on chain 2026-10-08)
PROXY=0x4e59b44847b379578588920cA78FbF26c0B4956C          # deterministic deployment proxy (TAP draft §4)
PROXY_CODEHASH=0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989
HUB=0xe61A9C7213a6Aa616C246a2B569e555B417b25ee
SR=0xd006ffdd5Ae313B17729621A00999cD3C71CE5e6             # SiteRegistry (site store, TAP-10 §7)
FACTORY=0x68224F668083c29e9800Be2a646d42d18cedF7e2
NAME=12.1013.tape                                           # the relay service: container opened, activated, has a manifest
KEY='.well-known/tapeapi.json'
CALLGAS=3000000   # gas the holder forwards to SiteRegistry.putFile (signed in the §5.2 message)
A0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266              # anvil account 0: relayer / deployer (pays gas, no authority)
DEADLINE=2000000000

c() { env -i PATH=/usr/bin:/bin HOME="$HOME" "$CAST" "$@"; }          # bare env: no local proxy variables
j() { python3 -c "import json,sys;d=json.load(open('out/setup.json'));print(eval('d'+sys.argv[1]))" "$1"; }
mine() { c rpc anvil_mine 0x5 -r "$R" >/dev/null; }                  # the TAP-10 pin is head-2: make state changes visible
say() { printf '\n### %s\n' "$*"; }
tx() { c send "$@" -r "$R" 2>&1 | grep -E '^(status|transactionHash|gasUsed)' | sed 's/  */ /g' | tr '\n' ' '; echo; }
resolve() { node resolve.mjs "$NAME" --rpc "$R" || true; node resolve.mjs "$NAME" --conform --rpc "$R" || true; }
expect() { # expect <ok|DELEGATION_INVALID> : the last two resolve lines (default + conform) must agree with it
  local want="$1" line; shift
  for line in "$@"; do
    case "$want" in
      ok) echo "$line" | grep -q '"ok":true' || { echo "UNEXPECTED: $line"; exit 1; } ;;
      *)  echo "$line" | grep -q "\"code\":\"$want\"" || { echo "UNEXPECTED: $line"; exit 1; } ;;
    esac
  done
  echo "  -> as expected ($want)"
}
check() { local a b; a=$(node resolve.mjs "$NAME" --rpc "$R" || true); b=$(node resolve.mjs "$NAME" --conform --rpc "$R" || true); echo "$a"; echo "$b"; expect "$1" "$a" "$b"; }

[ -d tapeapi/sdk/src ] || git clone --depth 50 https://github.com/BruceLanLan/tapeapi tapeapi
[ -d tapeapi/node_modules/@noble ] || (cd tapeapi && npm ci --ignore-scripts --no-audit --no-fund)
exec > >(tee run.log) 2>&1
echo "r8-interop run $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "tapeapi: $(git -C tapeapi log -1 --format='%h %s')"; node --version; "$ANVIL" --version | head -1

say "0. local anvil fork of BNB Smart Chain (latest block)"
ANVIL_PID=""
cleanup() { if [ -n "$ANVIL_PID" ]; then kill "$ANVIL_PID" 2>/dev/null || true; wait "$ANVIL_PID" 2>/dev/null || true; echo "anvil $ANVIL_PID stopped"; fi; }
trap cleanup EXIT
for u in "${FORK_URLS[@]}"; do
  env -i PATH=/usr/bin:/bin HOME="$HOME" "$ANVIL" --fork-url "$u" --port "$PORT" --chain-id 56 --no-rate-limit --silent > anvil.log 2>&1 &
  ANVIL_PID=$!
  for i in $(seq 1 30); do sleep 1; if c chain-id -r "$R" >/dev/null 2>&1; then break; fi; done
  if c chain-id -r "$R" >/dev/null 2>&1; then echo "fork-url: $u"; break; fi
  kill "$ANVIL_PID" 2>/dev/null || true; ANVIL_PID=""
done
[ -n "$ANVIL_PID" ] || { echo "no fork url worked"; exit 1; }
echo "chainId=$(c chain-id -r "$R") forkBlock=$(c block-number -r "$R")"
mkdir -p out

say "1. the circuit: $NAME as it is on chain (control)"
P=$(c call "$FACTORY" 'cpuAt(uint256)(address)' 1013 -r "$R"); OWNER=$(c call "$P" 'ownerOf(uint256)(address)' 12 -r "$R")
CONTAINER=$(c call "$HUB" 'accountOf(address,uint256)(address)' "$P" 12 -r "$R")
echo "circuits=$P tokenId=12 container=$CONTAINER holder(ownerOf)=$OWNER ownerCode=$(c code "$OWNER" -r "$R")"
c call "$SR" 'read(address,string)(bytes)' "$CONTAINER" "$KEY" -r "$R" | c --to-ascii > out/live-manifest.json
echo "live manifest: $(wc -c < out/live-manifest.json) bytes, signer $(python3 -c "import json;print(json.load(open('out/live-manifest.json'))['signer'])")"
check ok

say "2. test keys, holder addresses, TAP-11 §4.1 digest, BIP-322 signatures (python, tools/ read-only)"
python3 -B -I build.py setup out/live-manifest.json out
HOLD=$(j "['holders']['p2tr']['holder']"); HOLD_W=$(j "['holders']['p2wpkh']['holder']"); DIG=$(j "['digest']")
echo "p2tr holder (undeployed yet): code=$(c code "$HOLD" -r "$R") nonce=$(c nonce "$HOLD" -r "$R")"

say "3. the current holder writes the new manifest (delegation.sig = 66-byte BIP-322 witness by the P2TR test key)"
echo "   [local-only bypass: anvil_impersonateAccount of the real holder $OWNER; it still holds #12 at this point]"
c rpc anvil_impersonateAccount "$OWNER" -r "$R" >/dev/null; c rpc anvil_setBalance "$OWNER" 0x56BC75E2D63100000 -r "$R" >/dev/null
tx "$SR" 'putFile(address,string,string,bytes32,bytes)' "$CONTAINER" "$KEY" 'application/json' "$(j "['files']['manifest-good.json']['sha256']")" "$(j "['files']['manifest-good.json']['hex']")" --from "$OWNER" --unlocked
mine
echo "fileInfo: $(c call "$SR" 'fileInfo(address,string)(uint256,string,bytes32,uint256,uint256)' "$CONTAINER" "$KEY" -r "$R" | tr '\n' ' ')"
echo "control: holder is still the EOA $OWNER, so a 66-byte sig must fail (not ECDSA; its EIP-7702 code does not answer EIP-1271)"
check DELEGATION_INVALID

say "4. transfer circuit #12 into the Bitcoin-keyed holder address BEFORE it is deployed"
tx "$P" 'safeTransferFrom(address,address,uint256)' "$OWNER" "$HOLD" 12 --from "$OWNER" --unlocked
mine
echo "ownerOf(12)=$(c call "$P" 'ownerOf(uint256)(address)' 12 -r "$R") holderCode=$(c code "$HOLD" -r "$R")"
echo "NEGATIVE 2: holder has no code -> TAP-11 §4.4 item 2 requires code"
check DELEGATION_INVALID

say "5. deploy the P2TR holder through the deterministic deployment proxy"
GOT=$(c keccak "$(c code "$PROXY" -r "$R")"); echo "proxy $PROXY present on the fork, codehash $GOT (expected $PROXY_CODEHASH)"; [ "$GOT" = "$PROXY_CODEHASH" ]
INIT=$(j "['holders']['p2tr']['initCode']")
echo "creation code keccak $(j "['creationCodeKeccak']"), init code keccak $(j "['holders']['p2tr']['initCodeKeccak']"), salt 0"
PRED=$(c call "$PROXY" "0x$(printf '%064d' 0)${INIT#0x}" --from "$A0" -r "$R"); echo "proxy eth_call returns $PRED"
tx "$PROXY" "0x$(printf '%064d' 0)${INIT#0x}" --from "$A0" --unlocked
mine
echo "holder code bytes: $(( ($(c code "$HOLD" -r "$R" | wc -c) - 3) / 2 )) runtime keccak: $(c keccak "$(c code "$HOLD" -r "$R")")"
echo "scriptPubKey()=$(c call "$HOLD" 'scriptPubKey()(bytes)' -r "$R") nonce()=$(c call "$HOLD" 'nonce()(uint256)' -r "$R")"
echo "isValidSignature(digest, sigGood)=$(c call "$HOLD" 'isValidSignature(bytes32,bytes)(bytes4)' "$DIG" "$(j "['sigGood']")" -r "$R")  isValidSignature(digest, sigWrongKey)=$(c call "$HOLD" 'isValidSignature(bytes32,bytes)(bytes4)' "$DIG" "$(j "['sigWrongKey']")" -r "$R")"
echo "POSITIVE: unmodified tapeapi client, delegation signed by the Bitcoin key"
check ok

say "6. NEGATIVE 1: the same message signed by ANOTHER Bitcoin key; written by the holder itself via execute() (§5.2 call message)"
DATA=$(c calldata 'putFile(address,string,string,bytes32,bytes)' "$CONTAINER" "$KEY" 'application/json' "$(j "['files']['manifest-wrongkey.json']['sha256']")" "$(j "['files']['manifest-wrongkey.json']['hex']")")
N=$(c call "$HOLD" 'nonce()(uint256)' -r "$R"); S=$(python3 -B -I build.py sign-call p2tr "$SR" 0 "$DATA" "$CALLGAS" 0 "$N" "$DEADLINE")
echo "call message: $(echo "$S" | python3 -c 'import json,sys;print(json.load(sys.stdin)["message"])')"
tx "$HOLD" 'execute(address,uint256,bytes,uint256,uint256,uint64,bytes)' "$SR" 0 "$DATA" "$CALLGAS" 0 "$DEADLINE" "$(echo "$S" | python3 -c 'import json,sys;print(json.load(sys.stdin)["sig"])')" --from "$A0" --unlocked
mine
echo "manifest signer now $(c call "$SR" 'read(address,string)(bytes)' "$CONTAINER" "$KEY" -r "$R" | c --to-ascii | python3 -c 'import json,sys;m=json.load(sys.stdin);print(m["signer"], m["delegation"]["sig"][:20]+"...")')"
check DELEGATION_INVALID

say "7. the holder puts the good manifest back via execute() (nonce 1) -> resolved again"
DATA=$(c calldata 'putFile(address,string,string,bytes32,bytes)' "$CONTAINER" "$KEY" 'application/json' "$(j "['files']['manifest-good.json']['sha256']")" "$(j "['files']['manifest-good.json']['hex']")")
N=$(c call "$HOLD" 'nonce()(uint256)' -r "$R"); S=$(python3 -B -I build.py sign-call p2tr "$SR" 0 "$DATA" "$CALLGAS" 0 "$N" "$DEADLINE")
tx "$HOLD" 'execute(address,uint256,bytes,uint256,uint256,uint64,bytes)' "$SR" 0 "$DATA" "$CALLGAS" 0 "$DEADLINE" "$(echo "$S" | python3 -c 'import json,sys;print(json.load(sys.stdin)["sig"])')" --from "$A0" --unlocked
mine
echo "replay of the same execute() must fail:"; c send "$HOLD" 'execute(address,uint256,bytes,uint256,uint256,uint64,bytes)' "$SR" 0 "$DATA" "$CALLGAS" 0 "$DEADLINE" "$(echo "$S" | python3 -c 'import json,sys;print(json.load(sys.stdin)["sig"])')" --from "$A0" --unlocked -r "$R" 2>&1 | grep -oE 'custom error 0x[0-9a-f]{8}.*' | head -1 || true
check ok

say "8. P2WPKH holder: deploy through the proxy and check isValidSignature on the same TAP-11 digest"
INIT=$(j "['holders']['p2wpkh']['initCode']")
tx "$PROXY" "0x$(printf '%064d' 0)${INIT#0x}" --from "$A0" --unlocked
echo "holder $HOLD_W code bytes: $(( ($(c code "$HOLD_W" -r "$R" | wc -c) - 3) / 2 )) scriptPubKey()=$(c call "$HOLD_W" 'scriptPubKey()(bytes)' -r "$R")"
echo "isValidSignature(digest, sigP2WPKH)=$(c call "$HOLD_W" 'isValidSignature(bytes32,bytes)(bytes4)' "$DIG" "$(j "['sigP2WPKH']")" -r "$R")  with the P2TR sig=$(c call "$HOLD_W" 'isValidSignature(bytes32,bytes)(bytes4)' "$DIG" "$(j "['sigGood']")" -r "$R")"

say "done: all expectations held"
