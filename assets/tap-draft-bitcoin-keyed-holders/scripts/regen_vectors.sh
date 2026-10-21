#!/bin/sh
# Rebuilds every file that depends on the holder's creation code, in dependency order:
#   forge build --force -> bip322-js signatures of the single-call messages (sign.mjs) -> make_vectors.py
#   -> make_text_corpus.py -> make_batch_vectors.py -> bip322-js signatures of the batch messages (sign-batch.mjs)
#   -> make_batch_vectors.py again (it embeds those signatures) -> forge build --force.
# usage: sh scripts/regen_vectors.sh <directory where `npm ci` was run with tools/wallet-lib-check/package*.json>
# The JavaScript signers are copied into that directory and run there (they resolve their packages next
# to themselves); their result files are copied back. Any change to contracts/src restarts the chain.
set -eu
NM=$(cd "${1:?directory with node_modules for tools/wallet-lib-check}" && pwd)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${FOUNDRY_BIN:-$HOME/.foundry/bin}
W=$ROOT/tools/wallet-lib-check

(cd "$ROOT/contracts" && "$BIN/forge" build --force >/dev/null)
cp "$W/sign.mjs" "$W/sign-batch.mjs" "$NM/"
(cd "$NM" && node sign.mjs "$ROOT" >/dev/null)
cp "$NM/results.json" "$W/results.json"
python3 "$ROOT/tools/make_vectors.py"
python3 "$ROOT/tools/make_text_corpus.py"
python3 "$ROOT/tools/make_batch_vectors.py"
(cd "$NM" && node sign-batch.mjs "$ROOT" > "$W/sign-batch.log")
tail -1 "$W/sign-batch.log"
cp "$NM/results-batch.json" "$W/results-batch.json"
python3 "$ROOT/tools/make_batch_vectors.py"
python3 "$ROOT/tools/make_wallet_matrix_vectors.py" 2>/dev/null || echo "wallet-matrix results are for another build: those vectors were left as they were"
python3 "$ROOT/tools/make_wallet_vectors.py" 2>/dev/null || echo "real-wallet results are for another build: tools/make_wallet_vectors.py left the vectors as they were"
echo 'if the creation code changed, the real-wallet vectors must be signed again with each wallet'
(cd "$ROOT/contracts" && "$BIN/forge" build --force >/dev/null)
echo "regenerated: vectors/vectors.json, vectors/creation-code.hex, vectors/batch-vectors.json,"
echo "  vectors/text-corpus.json, contracts/test/GeneratedVectors.sol, contracts/test/batch/GeneratedBatchVectors.sol,"
echo "  contracts/test/batch/GeneratedTextCorpus.sol, vectors/wallet-unisat-1.7.22*.json (from the wallet results),"
echo "  tools/wallet-lib-check/results.json, results-batch.json, sign-batch.log"
