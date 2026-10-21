// OKX Wallet browser extension. Dapp API: window.okxwallet.bitcoin.connect() -> {address, publicKey, compressedPublicKey};
// window.okxwallet.bitcoin.signMessage(message, 'bip322-simple') -> string (the injected provider's own code:
// signMessage(n, o) with o = 'ecdsa' | 'bip322-simple' or {from, type}; type defaults to 'ecdsa').
// The address the dapp sees is the wallet's "preferred address" for BTC (Taproot by default), switched on the BTC
// coin page (popup.html#/coin?coinId=1, the switch icon next to "Receiving address").
import { MNEMONIC, clickButton, waitPopup, probePopup, popupSizeRequested, patchPopups, sleep, check, messages } from '../common.mjs';

export const kinds = ['p2tr', 'p2wpkh'];
export const popupRe = /notification\.html#\/dapp-entry/;
export const popupSize = { width: 360, height: 720 };
const TYPE = { p2tr: 'Taproot', p2wpkh: 'Native SegWit', p2sh: 'Nested SegWit', p2pkh: 'Legacy' };

// the OKX pages put parts of their UI into a sandboxed ses.html iframe; work in whichever frame shows the most text
async function frame(p) {
  let best = p.mainFrame(), bl = -1;
  for (const f of p.frames()) {
    const l = await f.evaluate(() => { let n = 0; for (const e of document.querySelectorAll('body *')) { if (e.tagName === 'SCRIPT' || e.tagName === 'STYLE' || !e.offsetParent) continue; for (const c of e.childNodes) if (c.nodeType === 3) n += c.textContent.trim().length; } return n; }).catch(() => -1);
    if (l > bl) { bl = l; best = f; }
  }
  return best;
}
async function ftext(p) { return (await (await frame(p)).locator('body').innerText().catch(() => '')); }
async function waitF(p, re, ms = 30000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { const t = await ftext(p); if (re.test(t)) return t; await sleep(400); } throw new Error('text not found ' + re); }
// rectangle (page coordinates) of the first visible leaf element whose text matches re, in any frame
async function locate(p, re, ms = 15000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    for (const f of p.frames()) {
      const r = await f.evaluate((src) => { const re = new RegExp(src); const own = (e) => [...e.childNodes].filter(c => c.nodeType === 3).map(c => c.textContent).join('').trim(); const e = [...document.querySelectorAll('body *')].find(e => e.offsetParent && (e.children.length === 0 ? re.test((e.innerText || '').trim()) : re.test(own(e)))); if (!e) return null; const b = e.getBoundingClientRect(); return { x: b.x, y: b.y, w: b.width, h: b.height }; }, re.source).catch(() => null);
      if (r) {
        if (f !== p.mainFrame()) { const b = await (await f.frameElement()).boundingBox(); r.x += b.x; r.y += b.y; }
        return r;
      }
    }
    await sleep(400);
  }
  throw new Error('no element ' + re);
}
// mouse-click the centre of that element
async function clickText(p, re, ms = 15000) {
  const r = await locate(p, re, ms);
  await p.mouse.click(r.x + r.w / 2, r.y + r.h / 2); await sleep(1200); return true;
}

export async function onboard(ctx, id) {
  let p = ctx.pages().find(p => p.url().includes('initialize'));
  if (!p) { p = await ctx.newPage(); await p.goto(`chrome-extension://${id}/notification.html#/initialize`); }
  await p.setViewportSize({ width: 1000, height: 900 });
  await waitF(p, /Import wallet/);
  await clickText(p, /^Import wallet$/);
  await clickText(p, /^Seed phrase or private key$/);
  await sleep(2000);
  // a "Security Reminder" sheet covers the form; its OK button
  await clickText(p, /^OK$/, 8000).catch(() => {});
  const f = p.frames().find(f => /ses\.html/.test(f.url()));
  const w = MNEMONIC.split(' '); const ins = f.locator('input');
  for (let i = 0; i < 12; i++) { await ins.nth(i).focus(); await p.keyboard.insertText(w[i]); }
  await clickText(p, /^Confirm$/);
  await waitF(p, /Secure your wallet/);
  await clickText(p, /^Password$/);
  await clickText(p, /^Next$/);
  await waitF(p, /Set password/);
  const f2 = await frame(p); const pw = f2.locator('input');
  for (let i = 0; i < 2; i++) { await pw.nth(i).focus(); await p.keyboard.insertText('Test-only-pass-1'); }
  await clickText(p, /^Confirm$/);
  await sleep(4000);
  await p.screenshot({ path: `${process.env.SHOTS}/okx-onboard-welcome.png` });
  await clickText(p, /^Start your Web3 journey$/, 20000).catch(() => p.mouse.click(500, 835));
  await sleep(3000);
  // OKX shows dapp requests in an already open notification page instead of a new popup; close its own tabs
  for (const q of ctx.pages()) if (/notification\.html|web3\.okx\.com/.test(q.url())) await q.close().catch(() => {});
}

// switch the BTC preferred address (what okxwallet.bitcoin exposes to dapps)
export async function setPreferred(ctx, id, kind) {
  const p = await ctx.newPage();
  await p.setViewportSize({ width: 360, height: 600 });
  await p.goto(`chrome-extension://${id}/popup.html#/coin?coinId=1`);
  await waitF(p, /Receiving address/);
  await locate(p, /^Receiving address/);
  // the switch icon (data-testid ...set-default-address-button) next to "Receiving address", then the address type
  const sel = async (f, q) => { const r = await f.evaluate((q) => { const e = document.querySelector(q); if (!e) return null; const b = e.getBoundingClientRect(); return { x: b.x + b.width / 2, y: b.y + b.height / 2 }; }, q).catch(() => null); if (r && f !== p.mainFrame()) { const b = await (await f.frameElement()).boundingBox(); r.x += b.x; r.y += b.y; } return r; };
  let pt = null; for (const f of p.frames()) if ((pt = await sel(f, '[data-testid$="set-default-address-button"]'))) break;
  if (!pt) throw new Error('no set-default-address button');
  await p.mouse.click(pt.x, pt.y); await sleep(1500);
  await locate(p, /^Switch preferred address$/);
  await clickText(p, new RegExp('^' + TYPE[kind] + '$'));
  await sleep(1500);
  await p.screenshot({ path: `${process.env.SHOTS}/okx-preferred-${kind}.png` });
  await p.close();
}
export async function beforeKind(ctx, id, dapp, kind) { await setPreferred(ctx, id, kind); }

export async function connect(ctx, id, dapp) {
  const before = ctx.pages().slice();
  const pr = dapp.evaluate(() => window.okxwallet.bitcoin.connect().then(r => ({ ok: r }), e => ({ err: String(e && e.message || e) })));
  const p = await waitPopup(ctx, /notification\.html#\/connect/, before);
  await p.setViewportSize(popupSize); await sleep(2000);
  await p.screenshot({ path: `${process.env.SHOTS}/okx-connect.png` });
  const popupText = await ftext(p);
  await clickText(p, /^Connect$/);
  const r = await pr;
  const byKind = { p2tr: { address: r.ok.address, publicKey: r.ok.compressedPublicKey } };
  await setPreferred(ctx, id, 'p2wpkh');
  const r2 = await dapp.evaluate(() => window.okxwallet.bitcoin.connect());
  byKind.p2wpkh = { address: r2.address, publicKey: r2.compressedPublicKey };
  await setPreferred(ctx, id, 'p2tr');
  return { raw: [r, r2], popupText, addresses: [byKind.p2tr.address, byKind.p2wpkh.address], byKind };
}

export function request(dapp, { message, type = 'bip322-simple' }) {
  return dapp.evaluate(([m, t]) => (t ? window.okxwallet.bitcoin.signMessage(m, t) : window.okxwallet.bitcoin.signMessage(m))
    .then(r => ({ ok: r }), e => ({ err: String(e && e.message || e) })), [message, type]);
}
export function extract(raw) { return typeof raw === 'string' ? { sig: raw } : { err: raw }; }
// the confirmation page shows only "Data >"; the message opens in a sheet
export async function expand(p) { await clickText(p, /^Data$/); await sleep(800); }
export async function approve(p) {
  // close the Data sheet if it is open, then Confirm
  await p.evaluate(() => { for (const e of document.querySelectorAll('*')) if (e.scrollTop) e.scrollTop = 0; });
  await clickButton(p, /^Confirm$/);
}

// Extra cells: Nested SegWit (P2SH-P2WPKH) and Legacy (P2PKH) as preferred address with 'bip322-simple';
// the default type ('ecdsa') for Native SegWit.
export async function extras(ctx, id, dapp, { deadline, log, acc }) {
  const out = {};
  const one = async (label, kind, type) => {
    await setPreferred(ctx, id, kind);
    const address = (await dapp.evaluate(() => window.okxwallet.bitcoin.getAccounts()))[0];
    const message = messages(acc.byKind.p2wpkh.address, deadline).single.sign; // a realistic §5.1 text
    await patchPopups(ctx);
    const before = ctx.pages().slice();
    const pr = request(dapp, { message, type });
    const rec = { kind, address, type: type || '(none: ecdsa default)', message };
    try {
      const p = await waitPopup(ctx, popupRe, before, 10000);
      const size = (await popupSizeRequested(ctx)) || popupSize;
      Object.assign(rec, await probePopup(ctx, p, message, `okx-extra-${label}`, size));
      await expand(p); rec.expanded = await probePopup(ctx, p, message, `okx-extra-${label}-expanded`, size);
      await approve(p);
    } catch (e) { rec.popupError = String(e.message || e); }
    const r = await Promise.race([pr, sleep(30000).then(() => ({ err: 'timeout' }))]);
    rec.raw = r.ok; if (r.err) rec.err = r.err;
    if (typeof r.ok === 'string') { rec.output = r.ok; Object.assign(rec, check(address, message, r.ok)); }
    log('extra', label, address, JSON.stringify(rec.err || rec.output).slice(0, 200), rec.cliVerify || '', rec.rawLen || '');
    return rec;
  };
  out['p2wpkh-default-ecdsa'] = await one('p2wpkh-default-ecdsa', 'p2wpkh', null);
  out['p2sh-bip322-simple'] = await one('p2sh-bip322-simple', 'p2sh', 'bip322-simple');
  out['p2pkh-bip322-simple'] = await one('p2pkh-bip322-simple', 'p2pkh', 'bip322-simple');
  await setPreferred(ctx, id, 'p2tr');
  return out;
}
