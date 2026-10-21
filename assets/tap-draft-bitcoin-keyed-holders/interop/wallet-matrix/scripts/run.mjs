// One wallet, end to end: import the public test mnemonic, connect from a plain http://127.0.0.1 page, and for each
// supported address type sign §5.1, two §5.2 and three §5.3 messages of the TAP plus a 4,000-character probe text,
// recording the wallet's raw output, the confirmation page and what tools/cli.py verify / witness say about it.
// usage: EXTDIR=<unpacked extension> PROFILE=<fresh profile dir> LAB=<TAP repository> OUT=<results dir> SHOTS=<dir>
//        [DAPP=http://127.0.0.1:<port>/blank.html] node run.mjs <wallet>
import { chromium } from 'playwright';
import fs from 'node:fs';
import { messages, check, patchPopups, popupSizeRequested, waitPopup, probePopup, save, sleep } from './common.mjs';

const name = process.argv[2];
const W = await import(`./wallets/${name}.mjs`);
const ver = JSON.parse(fs.readFileSync(`${process.env.EXTDIR}/manifest.json`)).version;
const ctx = await chromium.launchPersistentContext(process.env.PROFILE, {
  channel: 'chromium', headless: true,
  args: [`--disable-extensions-except=${process.env.EXTDIR}`, `--load-extension=${process.env.EXTDIR}`],
  viewport: { width: 1000, height: 900 },
});
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
try {
  let sw = ctx.serviceWorkers()[0] || await ctx.waitForEvent('serviceworker', { timeout: 60000 });
  const extId = new URL(sw.url()).host;
  log(name, ver, 'extension id', extId);
  await sleep(2500);
  await W.onboard(ctx, extId);
  log('imported');
  const dapp = await ctx.newPage();
  await dapp.goto(process.env.DAPP || 'http://127.0.0.1:18791/blank.html');
  await sleep(1500);
  await patchPopups(ctx);
  const acc = await W.connect(ctx, extId, dapp);
  log('accounts', JSON.stringify(acc.addresses));
  save(`${name}-${ver}-connect.json`, acc);
  const deadline = Math.floor(Date.now() / 1000) + 86400 * 30;

  async function sign(kind, address, message, label) {
    await patchPopups(ctx);
    const before = ctx.pages().slice();
    const pr = W.request(dapp, { kind, address, message });
    const rec = { message, chars: message.length };
    try {
      const popup = await (W.getPopup ? W.getPopup(ctx, extId, before) : waitPopup(ctx, W.popupRe, before));
      const size = (await popupSizeRequested(ctx)) || W.popupSize;
      Object.assign(rec, await probePopup(ctx, popup, message, `${name}-${label}`, size));
      // wallets that show a collapsed preview first: open the message the way a user would, and look again
      if (W.expand) { await W.expand(popup); rec.expanded = await probePopup(ctx, popup, message, `${name}-${label}-expanded`, size); }
      await W.approve(popup);
    } catch (e) { rec.popupError = String(e.message || e); }
    const r = await Promise.race([pr, sleep(45000).then(() => ({ err: 'no answer within 45 s' }))]);
    rec.raw = r.ok !== undefined ? r.ok : undefined;
    if (r.err !== undefined) rec.result = { err: r.err };
    else {
      const out = W.extract(r.ok);
      rec.result = out.err ? { err: out.err } : { ok: out.sig };
      if (out.sig) Object.assign(rec, check(address, message, out.sig));
    }
    log(label, message.length, 'chars', rec.result.ok ? 'output ' + String(rec.result.ok).slice(0, 24) + '…' : 'ERR ' + JSON.stringify(rec.result.err).slice(0, 200),
        rec.cliVerify || '', rec.rawLen ? rec.rawLen + ' bytes' : '', 'popupFull', rec.popupContainsFullText);
    return rec;
  }

  for (const kind of W.kinds) {
    const a = acc.byKind[kind];
    if (!a) { log('no', kind, 'address'); continue; }
    if (W.beforeKind) await W.beforeKind(ctx, extId, dapp, kind);
    const M = messages(a.address, deadline);
    const single = { wallet: name, atype: kind, ext: ver, accounts: [a.address], publicKey: a.publicKey, exec: M.exec, signs: {} };
    for (const k of ['sign', 'exec', 'call']) {
      single.signs[k] = await sign(kind, a.address, M.single[k], `${kind}-${k}`);
      save(`${name}-${ver}-${kind}.json`, single);
    }
    const batch = { wallet: name, atype: kind, ext: ver, address: a.address, scriptPubKey: M.scriptPubKey, holder: M.holder, cases: {}, probes: {} };
    for (const [k, c] of Object.entries(M.batch)) {
      batch.cases[k] = { ...c, ...(await sign(kind, a.address, c.message, `${kind}-batch-${k}`)) };
      save(`${name}-${ver}-batch-${kind}.json`, batch);
    }
    batch.probes.long4000 = await sign(kind, a.address, M.probe.long4000, `${kind}-probe-long4000`);
    save(`${name}-${ver}-batch-${kind}.json`, batch);
  }
  if (W.extras) {
    const ex = await W.extras(ctx, extId, dapp, { sign, deadline, log, acc });
    save(`${name}-${ver}-extras.json`, ex);
  }
  const sws = ctx.serviceWorkers();
  log('popup creation log', JSON.stringify(await Promise.all(sws.map(s => s.evaluate(() => self.__wlog || []).catch(() => [])))).slice(0, 600));
} catch (e) { log('RUN ERROR', e.stack || e); }
await ctx.close();
