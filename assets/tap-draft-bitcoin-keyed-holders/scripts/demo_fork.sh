#!/bin/sh
# End-to-end demonstration on a LOCAL anvil fork. Nothing is sent to a public network.
#   1. deploy the holder of a TEST Bitcoin key through the deterministic deployment proxy
#   2. move a real token into it by impersonating its current owner (anvil only)
#   3. check a TAP-11 delegation digest signed by the Bitcoin key through EIP-1271
#   4. move the token back out with a Bitcoin-signed execute(), relayed by another account
#   5. move it in again, then out with one Bitcoin-signed executeBatch() of two calls (token + coin)
# Usage: sh scripts/demo_fork.sh <bsc|xlayer|base> [p2tr|p2wpkh]
# Needs Foundry (anvil, cast) on PATH or FOUNDRY_BIN, and a built contracts/ (forge build).
set -eu
CHAIN=${1:?bsc or xlayer}; KIND=${2:-p2tr}
BIN=${FOUNDRY_BIN:-$(dirname "$(command -v anvil 2>/dev/null || echo ~/.foundry/bin/anvil)")}
ANVIL=$BIN/anvil; CAST=$BIN/cast
ROOT=$(cd "$(dirname "$0")/.." && pwd); CLI="python3 $ROOT/tools/cli.py"
PORT=${PORT:-8547}; RPC=http://127.0.0.1:$PORT
case $CHAIN in
  bsc)    FORK=${FORK_URL:-https://bsc-mainnet.public.blastapi.io}; NFT=0x1f5cb4aeae1807bf60c3b9c0d8adbcc14e91f12c; ID=920 ;;
  xlayer) FORK=${FORK_URL:-https://xlayerrpc.okx.com};              NFT=0x9cfc959cd42B2e1d39a0d850c528210E818AE520; ID=3 ;;
  base)   FORK=${FORK_URL:-https://mainnet.base.org};       NFT=0x839bdd6fa7a66416a609a735e11de5411b98574e; ID=1 ;;
  *) echo "chain must be bsc, xlayer or base"; exit 2 ;;
esac
FACTORY=0x4e59b44847b379578588920cA78FbF26c0B4956C
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil default account 0
RELAYER_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a   # anvil default account 2

"$ANVIL" --fork-url "$FORK" --port "$PORT" --silent &
APID=$!
trap 'kill $APID 2>/dev/null || true' EXIT
i=0; until "$CAST" chain-id -r "$RPC" >/dev/null 2>&1; do i=$((i+1)); [ $i -gt 60 ] && { echo "anvil did not start"; exit 1; }; sleep 1; done
rpc() { curl -s -m 30 -H 'content-type: application/json' --data "$1" "$RPC" >/dev/null; }
CID=$("$CAST" chain-id -r "$RPC")
echo "== fork of chain $CID at block $("$CAST" block-number -r "$RPC") ($FORK)"
echo "proxy code: $(( ($(printf %s "$("$CAST" code -r "$RPC" $FACTORY)" | wc -c) - 2) / 2 )) bytes"

ADDR=$($CLI test-address "$KIND")
HOLDER=$($CLI address "$ADDR" | sed -n 's/^holder: *//p')
DEPLOY=$($CLI address "$ADDR" | tail -1)
echo "== 1. test Bitcoin address $ADDR -> holder $HOLDER"
"$CAST" send -q -r "$RPC" --private-key $DEPLOYER_KEY $FACTORY "$DEPLOY" >/dev/null
echo "deployed, runtime $(( ($(printf %s "$("$CAST" code -r "$RPC" "$HOLDER")" | wc -c) - 2) / 2 )) bytes, scriptPubKey $("$CAST" call -r "$RPC" "$HOLDER" 'scriptPubKey()(bytes)')"

OWNER=$("$CAST" call -r "$RPC" $NFT "ownerOf(uint256)(address)" $ID)
echo "== 2. token $NFT #$ID ($("$CAST" call -r "$RPC" $NFT 'symbol()(string)')), owner $OWNER"
rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"anvil_impersonateAccount\",\"params\":[\"$OWNER\"]}"
rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"anvil_setBalance\",\"params\":[\"$OWNER\",\"0x8AC7230489E80000\"]}"
"$CAST" send -q -r "$RPC" --unlocked --from "$OWNER" $NFT "safeTransferFrom(address,address,uint256)" "$OWNER" "$HOLDER" $ID >/dev/null
echo "ownerOf now: $("$CAST" call -r "$RPC" $NFT "ownerOf(uint256)(address)" $ID)"

echo "== 3. TAP-11 delegation signed by the Bitcoin key"
EXPIRES=$(( $("$CAST" block latest --field timestamp -r "$RPC") + 86400 ))
DIGEST=$($CLI tap11-digest "$CID" 0x00000000000000000000000000000000000c0b7a 0x000000000000000000000000000000000005197e $EXPIRES)
MSG=$($CLI sign-message "$ADDR" "$CID" "$DIGEST")
echo "message: $MSG"
SIG=$($CLI test-sign "$KIND" "$MSG")
echo "isValidSignature (right key):  $("$CAST" call -r "$RPC" "$HOLDER" 'isValidSignature(bytes32,bytes)(bytes4)' "$DIGEST" "$SIG")"
OTHER=$([ "$KIND" = p2tr ] && echo p2wpkh || echo p2tr)
BAD=$($CLI test-sign "$OTHER" "$MSG")
echo "isValidSignature (other key):  $("$CAST" call -r "$RPC" "$HOLDER" 'isValidSignature(bytes32,bytes)(bytes4)' "$DIGEST" "$BAD")"
echo "eth_estimateGas of the check:  $("$CAST" estimate -r "$RPC" "$HOLDER" 'isValidSignature(bytes32,bytes)' "$DIGEST" "$SIG")"

echo "== 4. move the token back with a Bitcoin-signed call, paying the relayer a signed tip"
# the user funds the holder with a little native coin (for example by withdrawing it from an exchange); the fork shortcut:
rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"anvil_setBalance\",\"params\":[\"$HOLDER\",\"0x16345785D8A0000\"]}"
DATA=$("$CAST" calldata "transferFrom(address,address,uint256)" "$HOLDER" "$OWNER" $ID)
DEADLINE=$(( $("$CAST" block latest --field timestamp -r "$RPC") + 3600 ))
NONCE=$("$CAST" call -r "$RPC" "$HOLDER" 'nonce()(uint256)')
CALLGAS=150000; TIP=1000000000000000   # 0.001 of the native coin, paid to the relayer out of the holder's balance
CMSG=$($CLI call-message "$ADDR" "$CID" $NFT 0 "$DATA" $CALLGAS $TIP "$NONCE" $DEADLINE)
echo "message: $CMSG"
CSIG=$($CLI test-sign "$KIND" "$CMSG")
CALLDATA=$($CLI execute-calldata $NFT 0 "$DATA" $CALLGAS $TIP $DEADLINE "$CSIG")
RELAYER=$("$CAST" wallet address --private-key $RELAYER_KEY)
# anvil's default accounts are public; on mainnet bots give them EIP-7702 delegation code that sweeps incoming coin.
# Clear that on the fork so the relayer's balance shows the tip.
rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"anvil_setCode\",\"params\":[\"$RELAYER\",\"0x\"]}"
BAL0=$("$CAST" balance -r "$RPC" "$RELAYER");
RCPT=$("$CAST" send -r "$RPC" --private-key $RELAYER_KEY "$HOLDER" "$CALLDATA" --json)
BAL1=$("$CAST" balance -r "$RPC" "$RELAYER")
GASCOST=$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);print(int(d['gasUsed'],16)*int(d['effectiveGasPrice'],16))" "$RCPT")
echo "  relayer balance before $BAL0, after $BAL1, gas cost $GASCOST, holder balance now $("$CAST" balance -r "$RPC" "$HOLDER")"
echo "relayer balance change + gas cost = $(python3 -c "import sys;print(int(sys.argv[1])-int(sys.argv[2])+int(sys.argv[3]))" "$BAL1" "$BAL0" "$GASCOST") (the signed tip is $TIP)"
echo "ownerOf now: $("$CAST" call -r "$RPC" $NFT "ownerOf(uint256)(address)" $ID)   holder nonce: $("$CAST" call -r "$RPC" "$HOLDER" 'nonce()(uint256)')"
if "$CAST" send -q -r "$RPC" --private-key $RELAYER_KEY "$HOLDER" "$CALLDATA" >/dev/null 2>&1; then
  echo "replay: ACCEPTED (unexpected)"; exit 1
else
  echo "replay of the same signed call: rejected"
fi

echo "== 5. one signature, two calls (executeBatch): move the token out again and send coin, all or nothing"
"$CAST" send -q -r "$RPC" --unlocked --from "$OWNER" $NFT "safeTransferFrom(address,address,uint256)" "$OWNER" "$HOLDER" $ID >/dev/null
echo "token back in the holder: ownerOf $("$CAST" call -r "$RPC" $NFT "ownerOf(uint256)(address)" $ID)"
NONCE=$("$CAST" call -r "$RPC" "$HOLDER" 'nonce()(uint256)')
COIN=200000000000000   # 0.0002 of the native coin to anvil default account 3, callGas 0 (a plain transfer)
PAYEE=0x90F79bf6EB2c4f870365E785982E1f101E93b906
rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"anvil_setCode\",\"params\":[\"$PAYEE\",\"0x\"]}"
C1="$NFT,0,$DATA,$CALLGAS"; C2="$PAYEE,$COIN,0x,0"
BMSG=$($CLI batch-message "$ADDR" "$CID" $TIP "$NONCE" $DEADLINE "$C1" "$C2")
echo "message: $BMSG"
ONCHAIN=$("$CAST" call -r "$RPC" "$HOLDER" 'batchMessage((address,uint256,bytes,uint256)[],uint256,uint256,uint64)(bytes)' \
  "[($NFT,0,$DATA,$CALLGAS),($PAYEE,$COIN,0x,0)]" $TIP "$NONCE" $DEADLINE)
[ "$ONCHAIN" = "0x$(printf %s "$BMSG" | xxd -p | tr -d '\n')" ] && echo "the holder's batchMessage(...) equals the text" || { echo "batchMessage differs"; exit 1; }
BSIG=$($CLI test-sign "$KIND" "$BMSG")
BCALLDATA=$($CLI execute-batch-calldata $TIP $DEADLINE "$BSIG" "$C1" "$C2")
OB0=$("$CAST" balance -r "$RPC" "$PAYEE"); BAL0=$("$CAST" balance -r "$RPC" "$RELAYER")
RCPT=$("$CAST" send -r "$RPC" --private-key $RELAYER_KEY "$HOLDER" "$BCALLDATA" --json)
BAL1=$("$CAST" balance -r "$RPC" "$RELAYER"); OB1=$("$CAST" balance -r "$RPC" "$PAYEE")
GASCOST=$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);print(int(d['gasUsed'],16)*int(d['effectiveGasPrice'],16))" "$RCPT")
echo "gasUsed $(python3 -c "import json,sys;print(int(json.loads(sys.argv[1])['gasUsed'],16))" "$RCPT"), Called events: $(python3 -c "import json,sys;print(sum(1 for l in json.loads(sys.argv[1])['logs'] if l['topics'][0]=='0x9fe7115c2392aead0d86cee85b52169b9fa5e170aa1bebd3f05c04e35df6575d'))" "$RCPT")"
echo "relayer balance change + gas cost = $(python3 -c "import sys;print(int(sys.argv[1])-int(sys.argv[2])+int(sys.argv[3]))" "$BAL1" "$BAL0" "$GASCOST") (the signed tip is $TIP)"
echo "payee received $(python3 -c "import sys;print(int(sys.argv[1])-int(sys.argv[2]))" "$OB1" "$OB0") (signed value $COIN)"
echo "ownerOf now: $("$CAST" call -r "$RPC" $NFT "ownerOf(uint256)(address)" $ID)   holder nonce: $("$CAST" call -r "$RPC" "$HOLDER" 'nonce()(uint256)')"
if "$CAST" send -q -r "$RPC" --private-key $RELAYER_KEY "$HOLDER" "$BCALLDATA" >/dev/null 2>&1; then
  echo "replay: ACCEPTED (unexpected)"; exit 1
else
  echo "replay of the same signed batch: rejected"
fi
echo "== done"
