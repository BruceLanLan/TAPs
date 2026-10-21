#!/bin/bash
# demo_mining.sh — can a Bitcoin-keyed holder hold a TapeOut mining rig and collect its BEM, using only
# Bitcoin signatures? Reruns the whole experiment from scratch on LOCAL anvil forks and asserts outcomes.
#
#   * BSC (56) fork:  direct path (rig in holder, claim, BEM out, rig out, signed relayer tip) and the
#                     RigVault path (deposit with to = holder by the owner; and a self-deposit by the holder).
#   * X Layer (196) fork: the RIG voucher held by the same holder address (in, payee, redeem dry run, out).
#
# Nothing is broadcast to a public network: public RPCs are only used as anvil's read-only fork source.
# State changes happen on 127.0.0.1 only. Keys: anvil's default test accounts and the repo's public TEST
# Bitcoin key (tools/cli.py test-sign). anvil_impersonateAccount is used ONLY for the current rig/voucher
# owners (to move a real rig into the holder on the fork); the holder itself is never impersonated.
#
# usage: ./demo_mining.sh            (env overrides: BSC_PORT XL_PORT BSC_BLOCK XL_BLOCK BSC_FORK XL_FORK
#                                     RIG_A RIG_B RIG_C PROC)
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)          # cli.py + compiled artifact
CLI="python3 $REPO/tools/cli.py"
RX="python3 $HERE/rx.py"
FOUNDRY=${FOUNDRY:-$HOME/.foundry/versions/foundry-rs/foundry/v1.8.3}
CAST=$FOUNDRY/cast
ANVIL=$FOUNDRY/anvil
WORK=$HERE/work; mkdir -p "$WORK"; rm -f "$WORK"/*.json

BSC_PORT=${BSC_PORT:-8601}; XL_PORT=${XL_PORT:-8602}
BSC_FORK=${BSC_FORK:-https://bsc-mainnet.public.blastapi.io}
XL_FORK=${XL_FORK:-https://xlayerrpc.okx.com}
BSC_BLOCK=${BSC_BLOCK:-126455007}   # 2026-10-08, pinned so the run is reproducible (needs an archive RPC)
XL_BLOCK=${XL_BLOCK:-72698700}
B=http://127.0.0.1:$BSC_PORT; X=http://127.0.0.1:$XL_PORT

# ---- mainnet addresses (read from chain in §0 and asserted)
MINING=0x7E2E0DC66a3bD9103E69b766afA62d9f7b697b46
VAULT=0x48D43345656f0f9510dC3c06CBa99dFf597617C2
BEM=0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a
FACTORY=0x68224F668083c29e9800Be2a646d42d18cedF7e2
PROC=${PROC:-0xb1024b89886b9a34aa4ff5f31c411d708b20a14c}   # PoD processor; full address = factory.cpuAt(i)
LENS=0x2243Eaf4Dd308AeA7E243C06d7b95265a90b0134    # client "lensNext": pendingLive(key)
VOUCHER=0x9cfc959cd42B2e1d39a0d850c528210E818AE520
DDP=0x4e59b44847b379578588920cA78FbF26c0B4956C            # deterministic deployment proxy (same on both chains)
RIG_A=${RIG_A:-16607}   # direct path
RIG_B=${RIG_B:-16618}   # vault deposit by its owner with to = holder
RIG_C=${RIG_C:-16606}   # vault deposit by the holder itself
VOUCHER_ID=3

# ---- anvil default accounts (public test keys)
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; A0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
K2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a; A2=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
K3=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6; A3=0x90F79bf6EB2c4f870365E785982E1f101E93b906
RELAYER_KEY=$K2; RELAYER=$A2     # relays every execute()
OUTSIDER_KEY=$K3; OUTSIDER=$A3   # unrelated account: receives BEM, calls permissionless functions

PASS=0; FAIL=0; RXN=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
eq()   { local a b; a=$(echo "$1" | tr 'A-F' 'a-f'); b=$(echo "$2" | tr 'A-F' 'a-f'); if [ "$a" = "$b" ]; then ok "$3 ($1)"; else bad "$3: got '$1' want '$2'"; fi; }
gt()   { if python3 -c "import sys;sys.exit(0 if int('$1')>int('$2') else 1)"; then ok "$3 ($1 > $2)"; else bad "$3: $1 !> $2"; fi; }
num()  { echo "$1" | awk '{print $1}'; }                    # strip cast's " [1.2e3]" suffix
call() { local r=$1; shift; num "$($CAST call -r "$r" "$@" 2>&1)"; }
rpc()  { $CAST rpc -r "$1" "${@:2}" >/dev/null; }
hdr()  { echo; echo "=================== $*"; }

ANVIL_PIDS=()
cleanup() { for p in "${ANVIL_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

start_anvil() { # port fork-url block chain-id
  # env -i: the shell's 127.0.0.1:7890 proxy can stall long forks; anvil gets a clean environment
  env -i HOME="$HOME" PATH=/usr/bin:/bin "$ANVIL" --silent --port "$1" --fork-url "$2" --fork-block-number "$3" \
      --chain-id "$4" >"$WORK/anvil-$1.log" 2>&1 &
  ANVIL_PIDS+=($!)
  for _ in $(seq 1 60); do $CAST chain-id -r "http://127.0.0.1:$1" >/dev/null 2>&1 && return 0; sleep 1; done
  echo "anvil on $1 did not start"; cat "$WORK/anvil-$1.log"; exit 1
}

clean_accounts() { # the anvil test accounts carry EIP-7702 delegations on BSC/X Layer mainnet (sweepers);
                   # clear them on the fork so they behave as plain EOAs, and fund them
  for a in $A0 $A2 $A3; do rpc "$1" anvil_setCode $a 0x; rpc "$1" anvil_setBalance $a 0x21e19e0c9bab2400000; done
}

warp() { rpc "$1" evm_increaseTime "$2"; rpc "$1" anvil_mine 0x20; }   # advance time, then mine 32 blocks
now() { num "$($CAST block -r "$1" latest -f timestamp)"; }

# signed_exec <rpc> <chain id> <target> <value> <data> <callGas> <tip> <label> [dry]
# Builds the exact message with tools/cli.py, checks it byte-for-byte against the holder's own
# callMessage(), signs it with the TEST P2TR key (BIP-322 simple), and has the RELAYER send execute().
# With "dry" it only eth_calls execute() (no state change, nonce not consumed) and prints the result.
signed_exec() {
  local R=$1 CID=$2 TGT=$3 VAL=$4 DATA=$5 GAS=$6 TIP=$7 LABEL=$8 DRY=${9:-}
  local N DL MSG ONCHAIN SIG CD
  N=$(call "$R" "$HOLDER" "nonce()(uint256)")
  DL=$(( $(now "$R") + 3600 ))
  MSG=$($CLI call-message "$BTC" "$CID" "$TGT" "$VAL" "$DATA" "$GAS" "$TIP" "$N" "$DL")
  ONCHAIN=$($CAST call -r "$R" "$HOLDER" "callMessage(address,uint256,bytes,uint256,uint256,uint256,uint64)(bytes)" \
            "$TGT" "$VAL" "$DATA" "$GAS" "$TIP" "$N" "$DL")
  [ "$ONCHAIN" = "0x$(printf '%s' "$MSG" | xxd -p | tr -d '\n')" ] || { bad "$LABEL: cli message != holder.callMessage"; return 1; }
  echo "  signs: \"$MSG\""
  SIG=$($CLI test-sign p2tr "$MSG")
  CD=$($CLI execute-calldata "$TGT" "$VAL" "$DATA" "$GAS" "$TIP" "$DL" "$SIG")
  if [ "$DRY" = dry ]; then
    LAST_DRY=$($CAST call -r "$R" --from "$RELAYER" "$HOLDER" "$CD" --gas-limit $((GAS + 400000)) 2>&1)
    echo "  eth_call execute ($LABEL) -> $LAST_DRY"
    return 0
  fi
  RXN=$((RXN + 1)); LAST_RX=$WORK/rx-$RXN.json
  $CAST send -r "$R" --private-key "$RELAYER_KEY" "$HOLDER" "$CD" --gas-limit $((GAS + 400000)) --json >"$LAST_RX" 2>&1
  if $RX ok "$LAST_RX" >/dev/null; then
    ok "$LABEL: execute() relayed by $RELAYER, nonce $N, gasUsed $($RX field "$LAST_RX" gasUsed)"
  else
    bad "$LABEL: execute() failed: $($RX ok "$LAST_RX"; head -c 600 "$LAST_RX")"
  fi
}

# move an NFT from its current (impersonated) owner into the holder on the fork
owner_moves_in() { # rpc nft id
  local R=$1 NFT=$2 ID=$3 OWN
  OWN=$(call "$R" "$NFT" "ownerOf(uint256)(address)" "$ID")
  rpc "$R" anvil_impersonateAccount "$OWN"; rpc "$R" anvil_setBalance "$OWN" 0x8AC7230489E80000
  $CAST send -r "$R" --unlocked --from "$OWN" "$NFT" "safeTransferFrom(address,address,uint256)" "$OWN" "$HOLDER" "$ID" --json >"$WORK/in.json" 2>&1
  $RX ok "$WORK/in.json" >/dev/null || bad "safeTransferFrom $ID into holder: $(head -c 400 "$WORK/in.json")"
  rpc "$R" anvil_stopImpersonatingAccount "$OWN"
  MOVED_FROM=$OWN
}

T_CLAIMED=$($CAST sig-event "Claimed(bytes32,address,uint256)")
T_TRANSFER=$($CAST sig-event "Transfer(address,address,uint256)")
T_DEPOSITED=$($CAST sig-event "Deposited(uint256,address,uint256,address,address,uint256,bytes32)")
T_HARVESTED=$($CAST sig-event "Harvested(bytes32,uint256[],uint256[])")
T_CALLED=$($CAST sig-event "Called(uint256,address,uint256,bytes32)")
MINER_T="(address,uint64,uint32,uint32,uint32,uint32,uint64,uint32,uint64,uint8,address,uint32,uint32,uint64,uint64,bool,uint64,uint64,uint64,uint128,uint128,uint256)"
status_of() { $CAST call -r "$1" $MINING "getMiner(bytes32)($MINER_T)" "$2" | tr -d '()' | awk -F', ' '{print $10}'; }

# ============================================================================================ setup
hdr "0. build + holder address (TEST P2TR key, publicly known; holds nothing on mainnet)"
( cd $REPO/contracts && $FOUNDRY/forge build --skip test >/dev/null 2>&1 ) \
  && T="~" && echo "  forge build ok (writes ${REPO/#$HOME/$T}/contracts/out only)"
BTC=$($CLI test-address p2tr)
ADDR_OUT=$($CLI address "$BTC")
HOLDER=$(echo "$ADDR_OUT" | awk '/^holder:/{print $2}')
DEPLOY_CD=$(echo "$ADDR_OUT" | tail -1)
echo "  bitcoin address: $BTC"; echo "  holder (CREATE2 via $DDP, salt 0): $HOLDER"

hdr "1. BSC fork: anvil :$BSC_PORT <- $BSC_FORK @ $BSC_BLOCK"
start_anvil "$BSC_PORT" "$BSC_FORK" "$BSC_BLOCK" 56
clean_accounts $B
eq "$($CAST chain-id -r $B)" 56 "chain id"
eq "$(call $B $MINING 'isSealed()(bool)')" true "mining.isSealed()"
eq "$(call $B $MINING 'owner()(address)')" 0x0000000000000000000000000000000000000000 "mining.owner()"
eq "$(call $B $MINING 'token()(address)')" $BEM "mining.token() = BEM"
eq "$(call $B $VAULT 'bem()(address)')" $BEM "vault.bem() = BEM"
eq "$(call $B $VAULT 'mining()(address)')" $MINING "vault.mining()"
echo "  BEM: $($CAST call -r $B $BEM 'symbol()(string)') decimals $(call $B $BEM 'decimals()(uint8)')"
echo "  factory.cpuCount() = $(call $B $FACTORY 'cpuCount()(uint256)')"
eq "$(call $B $FACTORY 'cpuAt(uint256)(address)' 1)" 0x1F5Cb4aeaE1807Bf60c3b9C0D8aDBCC14e91f12C "factory.cpuAt(1) = PoD processor 0x1f5c…f12c"
eq "$(call $B $FACTORY 'cpuAt(uint256)(address)' 30)" $PROC "factory.cpuAt(30) = PoD processor 0xb102…a14c (used here)"
eq "$($CAST code -r $B $HOLDER)" 0x "holder not yet deployed on this BSC block"
$CAST send -r $B --private-key $K0 $DDP "$DEPLOY_CD" --json >"$WORK/deploy-bsc.json" 2>&1
$RX ok "$WORK/deploy-bsc.json" && ok "holder deployed through the deterministic proxy, gasUsed $($RX field "$WORK/deploy-bsc.json" gasUsed)"
eq "$($CAST call -r $B $HOLDER 'scriptPubKey()(bytes)')" "$(echo "$ADDR_OUT" | awk '/^scriptPubKey:/{print $2}')" "holder.scriptPubKey"
# fund the holder with BNB for relayer tips and LayerZero fees (anyone can send it native coin)
$CAST send -r $B --private-key $K0 $HOLDER --value 0.1ether >/dev/null && echo "  funded holder with 0.1 BNB from account 0"

# ============================================================================================ A: direct
hdr "2. Path A — rig #$RIG_A moves into the holder (owner impersonated, fork only)"
KA=$(call $B $MINING "minerKey(address,uint256)(bytes32)" $PROC $RIG_A)
eq "$KA" "$($CAST keccak $($CAST abi-encode --packed 'f(address,uint256)' $PROC $RIG_A))" "minerKey = keccak256(abi.encodePacked(circuits, id))"
eq "$(status_of $B $KA)" 1 "rig #$RIG_A miner status ACTIVE before"
owner_moves_in $B $PROC $RIG_A; OWNER_A=$MOVED_FROM
echo "  previous owner: $OWNER_A (code bytes: $(( ($(echo -n "$($CAST code -r $B $OWNER_A)" | wc -c) - 2) / 2 )))"
eq "$(call $B $PROC 'ownerOf(uint256)(address)' $RIG_A)" $HOLDER "ownerOf(#$RIG_A) = holder"
eq "$(status_of $B $KA)" 1 "miner status still ACTIVE after the NFT transfer (no stop, no re-start needed)"

P0=$(call $B $MINING "pending(bytes32)(uint256)" $KA); L0=$(call $B $LENS "pendingLive(bytes32)(uint256)" $KA)
warp $B 86400   # +1 day
P1=$(call $B $MINING "pending(bytes32)(uint256)" $KA); L1=$(call $B $LENS "pendingLive(bytes32)(uint256)" $KA)
echo "  at transfer: mining.pending $P0, lens.pendingLive $L0 (all accrued under the previous owner; now claimable by the holder)"
echo "  after +1 day: mining.pending $P1, lens.pendingLive $L1 (BEM, 8 decimals)"
echo "  note: mining.pending() is checkpoint-based and does not move with time alone; the client reads lensNext.pendingLive()"
gt "$L1" "$L0" "pendingLive accrues while the holder owns the rig"

hdr "3. Holder collects via execute(mining.claim(key)) — Bitcoin-signed, relayed by account 2, signed tip"
BAL_H0=$(call $B $BEM "balanceOf(address)(uint256)" $HOLDER)
RB0=$(num "$($CAST balance -r $B $RELAYER)")
TIP=1000000000000000   # 0.001 BNB, signed by the Bitcoin key, paid by the holder to msg.sender
signed_exec $B 56 $MINING 0 "$($CAST calldata 'claim(bytes32)' $KA)" 300000 $TIP "claim #$RIG_A"
RB1=$(num "$($CAST balance -r $B $RELAYER)")
GU=$($RX field "$LAST_RX" gasUsed); GP=$($RX field "$LAST_RX" effectiveGasPrice)
eq "$(python3 -c "print($RB1 - $RB0 + $GU * $GP)")" $TIP "relayer received exactly the signed tip (balance delta + gas cost)"
CL=$($RX events "$LAST_RX" $T_CLAIMED $MINING)
echo "  Claimed event: $CL"
eq "0x$(echo "$CL" | awk '{print substr($2,27)}')" "$(echo $HOLDER | tr 'A-F' 'a-f')" "Claimed(to) = holder"
BAL_H1=$(call $B $BEM "balanceOf(address)(uint256)" $HOLDER)
echo "  holder BEM: $BAL_H0 -> $BAL_H1"
CLAIMED=$(python3 -c "print(int('$(echo "$CL" | awk '{print $4}')',16))")
python3 -c "import sys;sys.exit(0 if $CLAIMED >= $L1 else 1)" && ok "claimed $CLAIMED >= pendingLive read one block earlier ($L1)" || bad "claimed $CLAIMED < pendingLive $L1"
gt "$BAL_H1" "$BAL_H0" "BEM arrived at the holder"
eq "$(call $B $HOLDER 'nonce()(uint256)')" 1 "holder.nonce after one call"

hdr "3b. claim() is permissionless: an unrelated account (no signature) claims, BEM still lands at the holder"
warp $B 3600
$CAST send -r $B --private-key $OUTSIDER_KEY $MINING "claim(bytes32)" $KA --json >"$WORK/outsider-claim.json" 2>&1
$RX ok "$WORK/outsider-claim.json" && ok "outsider $OUTSIDER called claim(key) directly"
CL=$($RX events "$WORK/outsider-claim.json" $T_CLAIMED $MINING)
eq "0x$(echo "$CL" | awk '{print substr($2,27)}')" "$(echo $HOLDER | tr 'A-F' 'a-f')" "Claimed(to) = holder (the NFT owner), not the caller"
BAL_H2=$(call $B $BEM "balanceOf(address)(uint256)" $HOLDER)
gt "$BAL_H2" "$BAL_H1" "holder BEM grew without any signature"
echo "  stop()/arm() need the NFT owner (custom error 0xa8ee9629 = Ownr()):"
R=$($CAST call -r $B --from $OUTSIDER $MINING 'stop(bytes32)' $KA 2>&1 | grep -o 'custom error 0x[0-9a-f]*' | head -1)
eq "$R" "custom error 0xa8ee9629" "stop(key) from a non-owner reverts Ownr()"
R=$($CAST call -r $B --from $OUTSIDER $MINING 'arm(address,uint256)' $PROC $RIG_A 2>&1 | grep -o 'custom error 0x[0-9a-f]*' | head -1)
eq "$R" "custom error 0xa8ee9629" "arm(circuits,id) from a non-owner reverts Ownr()"

hdr "4. Holder sends all its BEM to $OUTSIDER (second Bitcoin-signed execute)"
BO0=$(call $B $BEM "balanceOf(address)(uint256)" $OUTSIDER)
signed_exec $B 56 $BEM 0 "$($CAST calldata 'transfer(address,uint256)' $OUTSIDER $BAL_H2)" 100000 0 "BEM.transfer"
eq "$(call $B $BEM 'balanceOf(address)(uint256)' $HOLDER)" 0 "holder BEM = 0"
eq "$(python3 -c "print($(call $B $BEM 'balanceOf(address)(uint256)' $OUTSIDER) - $BO0)")" $BAL_H2 "outsider received the BEM"

hdr "5. Holder moves the rig out (third Bitcoin-signed execute), rig keeps mining for the new owner"
signed_exec $B 56 $PROC 0 "$($CAST calldata 'transferFrom(address,address,uint256)' $HOLDER $OWNER_A $RIG_A)" 200000 0 "transferFrom rig out"
eq "$(call $B $PROC 'ownerOf(uint256)(address)' $RIG_A)" $OWNER_A "ownerOf(#$RIG_A) back to $OWNER_A"
eq "$(status_of $B $KA)" 1 "miner status still ACTIVE"
eq "$(call $B $HOLDER 'nonce()(uint256)')" 3 "holder.nonce = 3"

hdr "5b. Replay / wrong-key checks"
# replay the claim signature with nonce 0 -> BadSignature (the message now carries nonce 3)
N=$(call $B $HOLDER 'nonce()(uint256)'); DL=$(( $(now $B) + 3600 ))
MSG=$($CLI call-message "$BTC" 56 $MINING 0 "$($CAST calldata 'claim(bytes32)' $KA)" 300000 0 0 $DL)
SIG=$($CLI test-sign p2tr "$MSG")
CD=$($CLI execute-calldata $MINING 0 "$($CAST calldata 'claim(bytes32)' $KA)" 300000 0 $DL "$SIG")
R=$($CAST call -r $B --from $RELAYER $HOLDER "$CD" --gas-limit 800000 2>&1 | grep -o 'custom error 0x[0-9a-f]*\|BadSignature()' | head -1)
eq "$R" "custom error $($CAST sig 'BadSignature()')" "stale-nonce signature rejected (BadSignature)"
MSG=$($CLI call-message "$BTC" 56 $MINING 0 "$($CAST calldata 'claim(bytes32)' $KA)" 300000 0 $N $DL)
SIG=$($CLI test-sign p2wpkh "$MSG")     # the OTHER test key
CD=$($CLI execute-calldata $MINING 0 "$($CAST calldata 'claim(bytes32)' $KA)" 300000 0 $DL "$SIG")
R=$($CAST call -r $B --from $RELAYER $HOLDER "$CD" --gas-limit 800000 2>&1 | grep -o 'custom error 0x[0-9a-f]*\|BadSignature()' | head -1)
eq "$R" "custom error $($CAST sig 'BadSignature()')" "signature by a different Bitcoin key rejected"

# ============================================================================================ B: vault
hdr "6. Path B — owner of rig #$RIG_B deposits it into RigVault with to = holder (owner impersonated)"
KB=$(call $B $MINING "minerKey(address,uint256)(bytes32)" $PROC $RIG_B)
eq "$(status_of $B $KB)" 1 "rig #$RIG_B ACTIVE"
OWNER_B=$(call $B $PROC "ownerOf(uint256)(address)" $RIG_B)
PB=$(call $B $LENS "pendingLive(bytes32)(uint256)" $KB)
echo "  owner $OWNER_B, pending $PB (deposit() first claims this to the depositor, then pulls BOND = 10000)"
rpc $B anvil_impersonateAccount $OWNER_B; rpc $B anvil_setBalance $OWNER_B 0x8AC7230489E80000
$CAST send -r $B --unlocked --from $OWNER_B $PROC "approve(address,uint256)" $VAULT $RIG_B >/dev/null
$CAST send -r $B --unlocked --from $OWNER_B $BEM "approve(address,uint256)" $VAULT 10000 >/dev/null
QD=$(call $B $VAULT "quoteDeposit()(uint256)")
DEP0=$(call $B $VAULT "deposits()(uint256)")
$CAST send -r $B --unlocked --from $OWNER_B $VAULT "deposit(address,uint256,address)" $PROC $RIG_B $HOLDER --value $QD --json >"$WORK/depB.json" 2>&1
rpc $B anvil_stopImpersonatingAccount $OWNER_B
$RX ok "$WORK/depB.json" && ok "deposit(circuits, #$RIG_B, to = holder) value $QD wei (LayerZero fee), gasUsed $($RX field "$WORK/depB.json" gasUsed)"
ID_B=$(call $B $VAULT "deposits()(uint256)")
eq "$ID_B" $((DEP0 + 1)) "vault.deposits() incremented -> vault id $ID_B"
DE=$($RX events "$WORK/depB.json" $T_DEPOSITED $VAULT)
echo "  Deposited: $DE"
eq "0x$(echo "$DE" | awk '{print substr($6,25)}')" "$(echo $HOLDER | tr 'A-F' 'a-f')" "Deposited.to (X Layer voucher recipient) = holder"
CELL_B=$(call $B $VAULT "cellOf(bytes32)(address)" $KB)
eq "$(call $B $PROC 'ownerOf(uint256)(address)' $RIG_B)" $CELL_B "ownerOf(#$RIG_B) = the rig's EIP-1167 cell (not the holder)"
echo "  vault.rigs($ID_B) = $($CAST call -r $B $VAULT 'rigs(uint256)(address,uint256)' $ID_B | tr '\n' ' ')  (no depositor/recipient stored on BSC)"
eq "$(status_of $B $KB)" 1 "rig keeps mining inside the cell"
echo "  PacketSent to LayerZero emitted (X Layer delivery is NOT simulated: single-chain fork)."

hdr "7. Holder harvests vault id $ID_B via execute(vault.harvest([id])) with value = quoteHarvest(1)"
warp $B 172800
PCB=$(call $B $LENS "pendingLive(bytes32)(uint256)" $KB)
echo "  pendingLive of the cell's rig after +2 days: $PCB (BOND is 10000; below that the harvester must add BEM)"
QH=$(call $B $VAULT "quoteHarvest(uint256)(uint256)" 1)
BAL_HB0=$(call $B $BEM "balanceOf(address)(uint256)" $HOLDER)
signed_exec $B 56 $VAULT $QH "$($CAST calldata 'harvest(uint256[])' "[$ID_B]")" 900000 0 "harvest([$ID_B])"
HV=$($RX events "$LAST_RX" $T_HARVESTED $VAULT)
echo "  Harvested: $HV"
echo "  Claimed(to) inside harvest: $($RX events "$LAST_RX" $T_CLAIMED $MINING | awk '{print $2}')  (the cell $CELL_B)"
eq "$(call $B $BEM 'balanceOf(address)(uint256)' $HOLDER)" "$BAL_HB0" "holder's BSC BEM unchanged: the yield is bridged to X Layer for the voucher holder"
CB=$(call $B $BEM 'balanceOf(address)(uint256)' $CELL_B); [ "$CB" -lt 100 ] && ok "cell swept into the OFT adapter, dust left in cell: $CB (< DUST=100)" || bad "cell still holds $CB"

hdr "7b. What the holder can NOT do on BSC"
echo "  rescue(id,to) is onlyOwner (3/5 Safe). Holder-signed execute(vault.rescue) eth_call:"
signed_exec $B 56 $VAULT 0 "$($CAST calldata 'rescue(uint256,address)' $ID_B $HOLDER)" 300000 0 "rescue (expected revert)" dry
echo "$LAST_DRY" | grep -q "$($CAST sig 'OwnableUnauthorizedAccount(address)' | cut -c3-)\|OwnableUnauthorizedAccount" \
  && ok "rescue reverts OwnableUnauthorizedAccount(holder)" || bad "rescue did not revert as expected: $LAST_DRY"
echo "  Redeem only exists on X Layer (RigVoucher.redeem by the voucher owner) -> see §9."

# ============================================================================================ C: self-deposit
hdr "8. Path C — the holder deposits a rig it holds into the vault itself (3 signed calls, to = holder)"
KC=$(call $B $MINING "minerKey(address,uint256)(bytes32)" $PROC $RIG_C)
eq "$(status_of $B $KC)" 1 "rig #$RIG_C ACTIVE"
owner_moves_in $B $PROC $RIG_C; OWNER_C=$MOVED_FROM
eq "$(call $B $PROC 'ownerOf(uint256)(address)' $RIG_C)" $HOLDER "ownerOf(#$RIG_C) = holder"
PC=$(call $B $LENS "pendingLive(bytes32)(uint256)" $KC)
gt "$PC" 9999 "pending >= BOND, so deposit()'s own claim() funds the 0.0001 BEM bond"
signed_exec $B 56 $PROC 0 "$($CAST calldata 'approve(address,uint256)' $VAULT $RIG_C)" 100000 0 "approve rig to vault"
signed_exec $B 56 $BEM 0 "$($CAST calldata 'approve(address,uint256)' $VAULT 10000)" 100000 0 "approve BOND to vault"
QD=$(call $B $VAULT "quoteDeposit()(uint256)")
signed_exec $B 56 $VAULT $QD "$($CAST calldata 'deposit(address,uint256,address)' $PROC $RIG_C $HOLDER)" 900000 0 "deposit(#$RIG_C, to = holder)"
DE=$($RX events "$LAST_RX" $T_DEPOSITED $VAULT)
echo "  Deposited: $DE"
eq "0x$(echo "$DE" | awk '{print substr($5,25)}')" "$(echo $HOLDER | tr 'A-F' 'a-f')" "Deposited.from = holder"
eq "0x$(echo "$DE" | awk '{print substr($6,25)}')" "$(echo $HOLDER | tr 'A-F' 'a-f')" "Deposited.to = holder"
eq "$(call $B $PROC 'ownerOf(uint256)(address)' $RIG_C)" "$(call $B $VAULT 'cellOf(bytes32)(address)' $KC)" "rig #$RIG_C now in its cell"
echo "  holder BEM after self-deposit (pending - BOND kept): $(call $B $BEM 'balanceOf(address)(uint256)' $HOLDER)"

# ============================================================================================ X Layer
hdr "9. X Layer fork: anvil :$XL_PORT <- $XL_FORK @ $XL_BLOCK — RIG voucher #$VOUCHER_ID in the SAME holder address"
start_anvil "$XL_PORT" "$XL_FORK" "$XL_BLOCK" 196
clean_accounts $X
eq "$($CAST chain-id -r $X)" 196 "chain id"
eq "$($CAST code -r $X $HOLDER)" 0x "holder not yet deployed on X Layer"
$CAST send -r $X --private-key $K0 $DDP "$DEPLOY_CD" --json >"$WORK/deploy-xl.json" 2>&1
$RX ok "$WORK/deploy-xl.json" && ok "holder deployed on X Layer through the same deterministic proxy"
[ "$($CAST code -r $X $HOLDER)" != 0x ] && ok "code exists at the SAME address $HOLDER on chain 196" || bad "holder address differs on X Layer"
$CAST send -r $X --private-key $K0 $HOLDER --value 0.1ether >/dev/null && echo "  funded holder with 0.1 OKB"
echo "  voucher: $($CAST call -r $X $VOUCHER 'name()(string)') / $($CAST call -r $X $VOUCHER 'symbol()(string)'), rigs($VOUCHER_ID) = $($CAST call -r $X $VOUCHER 'rigs(uint256)(address,uint64,uint256,uint256)' $VOUCHER_ID | tr '\n' ' ')"
owner_moves_in $X $VOUCHER $VOUCHER_ID; OWNER_V=$MOVED_FROM
eq "$(call $X $VOUCHER 'ownerOf(uint256)(address)' $VOUCHER_ID)" $HOLDER "voucher ownerOf($VOUCHER_ID) = holder"
eq "$(call $X $VOUCHER 'payeeAt(uint256,uint256)(address)' $VOUCHER_ID $(now $X))" $HOLDER "payeeAt($VOUCHER_ID, now) = holder (future harvests pay the holder)"
echo "  powerHeld(holder) = $(call $X $VOUCHER 'powerHeld(address)(uint256)' $HOLDER)"
QR=$(call $X $VOUCHER "quoteRedeem()(uint256)")
echo "  redeem dry run: execute(voucher.redeem($VOUCHER_ID, to = holder)) with value quoteRedeem = $QR, eth_call only:"
signed_exec $X 196 $VOUCHER $QR "$($CAST calldata 'redeem(uint256,address)' $VOUCHER_ID $HOLDER)" 600000 0 "redeem (dry)" dry
echo "$LAST_DRY" | grep -q '^0x' && ok "holder-signed redeem would succeed (burn voucher, LayerZero message to the vault, rig to holder on BSC)" \
  || bad "redeem dry run reverted: $LAST_DRY"
signed_exec $X 196 $VOUCHER 0 "$($CAST calldata 'transferFrom(address,address,uint256)' $HOLDER $OWNER_V $VOUCHER_ID)" 200000 0 "voucher out"
eq "$(call $X $VOUCHER 'ownerOf(uint256)(address)' $VOUCHER_ID)" $OWNER_V "voucher back to $OWNER_V"
eq "$(call $X $HOLDER 'nonce()(uint256)')" 1 "X Layer holder nonce = 1 (independent per chain)"

hdr "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
