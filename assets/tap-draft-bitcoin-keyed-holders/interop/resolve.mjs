#!/usr/bin/env node
// r8-interop: run the UNMODIFIED tapeapi SDK (cloned from github.com/BruceLanLan/tapeapi) against a local anvil fork.
//   node resolve.mjs <target> [--conform] [--rpc http://127.0.0.1:8545]
// Prints one JSON line: { ok: true, ... } on "resolved", or { ok: false, code, status, message } on any other outcome.
import { createTapeAPI } from './tapeapi/sdk/src/index.js'

const args = process.argv.slice(2)
const target = args.find((a) => !a.startsWith('--'))
const conform = args.includes('--conform')
const rpc = args.includes('--rpc') ? args[args.indexOf('--rpc') + 1] : 'http://127.0.0.1:8545'
const warnings = []
const api = createTapeAPI({
  chainId: 56,
  rpcUrls: [rpc],
  quorum: 2, allowSingleNode: true,   // one local node: a "degraded" set, so strict agreement (TAP-10 §5.2) needs 1
  quiet: true,
  rpcTimeoutMs: 120000,               // a fresh fork fetches upstream state lazily
  onWarning: (w) => warnings.push(w),
  ...(conform ? { conform: 'tap10' } : {}),
})
const t0 = Date.now()
const big = (k, v) => typeof v === 'bigint' ? v.toString() : v   // svc.conform / contribution carry BigInt
try {
  const svc = await api.resolve(target)
  console.log(JSON.stringify({
    ok: true, mode: conform ? 'conform:tap10 (TAP-11 §2.2)' : 'default resolve()', target, ms: Date.now() - t0,
    holder: svc.verified.holder, delegation: svc.verified.delegation, signer: svc.manifest.signer,
    expires: svc.manifest.delegation.expires, sigBytes: (svc.manifest.delegation.sig.length - 2) / 2,
    container: svc.container, circuits: svc.manifest.circuits, tokenId: svc.manifest.tokenId,
    pinnedBlock: svc.pinned?.number ?? null, conform: svc.conform ? { status: svc.conform.status, site: svc.conform.site, holder: svc.conform.holder, opened: svc.conform.opened, pinned: svc.conform.pinned?.number } : null, sentinel: svc.sentinel?.container ?? null,
    fileSha256: svc.file?.sha256 ?? svc.file ?? null, warnings,
  }, big))
} catch (e) {
  console.log(JSON.stringify({ ok: false, mode: conform ? 'conform:tap10 (TAP-11 §2.2)' : 'default resolve()', target, ms: Date.now() - t0, code: e.code ?? null, status: e.data?.status ?? null, message: e.message, warnings }, big))
  process.exitCode = 2
}
