// Leather browser extension. Dapp API (leather.gitbook.io/developers/bitcoin-methods/signmessage):
//   window.LeatherProvider.request('getAddresses')
//   window.LeatherProvider.request('signMessage', {message, paymentType:'p2tr'|'p2wpkh', network:'mainnet'})
//   -> {jsonrpc, id, result:{signature, address, message}}
import { MNEMONIC, clickButton, waitText, waitPopup, probePopup, popupSizeRequested, patchPopups, sleep, check, messages } from '../common.mjs';

export const kinds = ['p2tr', 'p2wpkh'];
export const popupRe = /popup\.html#\/sign-bip322-message/;
export const popupSize = null; // taken from the extension's own chrome.windows.create call
const PASSWORD = 'Test-only-pass-1-Leather-wallet'; // Leather requires a "strong" password

export async function onboard(ctx, id) {
  let p = ctx.pages().find(p => p.url().includes('get-started'));
  if (!p) { p = await ctx.newPage(); await p.goto(`chrome-extension://${id}/index.html#/get-started`); }
  await waitText(p, /Use existing key/);
  await clickButton(p, /^Use existing key$/);
  await waitText(p, /SIGN IN WITH YOUR SECRET KEY/i);
  await p.evaluate(() => [...document.querySelectorAll('a,button')].find(a => /12-word/.test(a.innerText)).click());
  await sleep(800);
  // Playwright's fill() waits forever on these overlaid inputs; focus and insert each word instead
  const w = MNEMONIC.split(' '); const ins = p.locator('input');
  for (let i = 0; i < 12; i++) { await ins.nth(i).focus(); await p.keyboard.insertText(w[i]); }
  await p.evaluate(() => document.querySelector('button[type=submit]').click());
  await waitText(p, /SET A PASSWORD/i);
  await p.evaluate(() => document.querySelector('input[type=password]').focus());
  await p.keyboard.type(PASSWORD, { delay: 10 });
  await waitText(p, /Password strength:\s*Strong/);
  await p.evaluate(() => document.querySelector('button[type=submit]').click());
  await waitText(p, /Total balance/, 60000);
}

export async function connect(ctx, id, dapp) {
  const before = ctx.pages().slice();
  const pr = dapp.evaluate(() => window.LeatherProvider.request('getAddresses').then(r => ({ ok: r }), e => ({ err: e })));
  const p = await waitPopup(ctx, /get-addresses/, before);
  const size = await popupSizeRequested(ctx); if (size) await p.setViewportSize(size);
  await sleep(1500);
  await p.screenshot({ path: `${process.env.SHOTS}/leather-connect.png` });
  const popupText = await p.locator('body').innerText();
  await clickButton(p, /^Confirm$/);
  const r = await pr;
  const addrs = r.ok.result.addresses.filter(a => a.symbol === 'BTC');
  const byKind = {}; for (const a of addrs) byKind[a.type] = a;
  return { raw: r, popupText, addresses: addrs.map(a => a.address), byKind };
}

export function request(dapp, { kind, message, paymentType }) {
  const params = { message, network: 'mainnet' };
  if (paymentType !== null) params.paymentType = paymentType || kind;
  return dapp.evaluate((params) => window.LeatherProvider.request('signMessage', params).then(r => ({ ok: r }), e => ({ err: e })), params);
}
export function extract(raw) {
  if (raw && raw.result && typeof raw.result.signature === 'string') return { sig: raw.result.signature };
  return { err: raw && raw.error ? raw.error : raw };
}
export async function approve(p) { await clickButton(p, /^Sign$/); }

// Extra cells: no paymentType (documented default p2wpkh); paymentType 'p2sh' (not documented: Leather has no
// nested-SegWit account); a text with characters that are special in the URL query Leather puts the message in.
export async function extras(ctx, id, dapp, { deadline, log, acc }) {
  const out = {};
  const one = async (label, message, paymentType, address) => {
    await patchPopups(ctx);
    const before = ctx.pages().slice();
    const pr = request(dapp, { message, paymentType });
    const rec = { paymentType: paymentType === null ? '(none)' : paymentType, message };
    try {
      const p = await waitPopup(ctx, popupRe, before, 8000);
      Object.assign(rec, await probePopup(ctx, p, message, `leather-extra-${label}`, await popupSizeRequested(ctx)));
      await approve(p);
    } catch (e) { rec.popupError = String(e.message || e); }
    const r = await Promise.race([pr, sleep(30000).then(() => ({ err: 'timeout' }))]);
    rec.raw = r.ok; if (r.err) rec.err = r.err;
    const x = extract(r.ok || {});
    if (x.sig) { rec.output = x.sig; rec.signedBy = r.ok.result.address; rec.messageEcho = r.ok.result.message; Object.assign(rec, check(r.ok.result.address, message, x.sig)); }
    log('extra', label, JSON.stringify(rec.err || (rec.raw && rec.raw.result && { address: rec.raw.result.address, sig: rec.output })).slice(0, 300), rec.cliVerify || '', rec.rawLen || '');
    return rec;
  };
  const wp = acc.byKind.p2wpkh.address;
  const M = messages(wp, deadline);
  out['no-paymentType'] = await one('no-paymentType', M.single.sign, null);
  out['paymentType-p2sh'] = await one('paymentType-p2sh', M.single.sign, 'p2sh');
  out['url-special-chars'] = await one('url-special-chars', 'a+b=c&d=%41 #frag', 'p2wpkh');
  return out;
}
