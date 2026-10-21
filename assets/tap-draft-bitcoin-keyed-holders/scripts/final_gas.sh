#!/bin/sh
# Measures the standard cases (scripts/final_gas.py) for one or more holder creation codes, each on its own
# fresh plain anvil node (chain id 56, shanghai, no fork). Nothing is sent to any public network.
# usage: sh scripts/final_gas.sh <outdir> <label>=<creation code hex file> ...
# Needs Foundry (anvil, cast; FOUNDRY_BIN or ~/.foundry/bin) and a built contracts/ (forge build --force).
set -eu
OUTDIR=${1:?output directory}; shift
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=${FOUNDRY_BIN:-$HOME/.foundry/bin}
PORT=${PORT:-8551}
mkdir -p "$OUTDIR"
for spec in "$@"; do
  label=${spec%%=*}; file=${spec#*=}
  "$BIN/anvil" --chain-id 56 --hardfork shanghai --port "$PORT" --silent > "$OUTDIR/anvil-$label.log" 2>&1 &
  APID=$!
  trap 'kill $APID 2>/dev/null || true' EXIT
  i=0
  until env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      "$BIN/cast" chain-id --rpc-url "http://127.0.0.1:$PORT" > /dev/null 2>&1; do
    i=$((i + 1)); [ $i -gt 60 ] && { echo "anvil did not start"; exit 1; }; sleep 1
  done
  FOUNDRY_BIN=$BIN python3 "$HERE/final_gas.py" --rpc "http://127.0.0.1:$PORT" --code "$file" --label "$label" \
    > "$OUTDIR/final-gas-$label.json"
  kill $APID; wait $APID 2>/dev/null || true
  trap - EXIT
  echo "$label done"
done
