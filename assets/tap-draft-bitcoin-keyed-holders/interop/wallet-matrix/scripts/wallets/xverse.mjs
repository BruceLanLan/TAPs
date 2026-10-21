// Xverse browser extension. Dapp API (Sats Connect docs, docs.xverse.app/sats-connect):
//   window.XverseProviders.BitcoinProvider.request('wallet_connect', {addresses:['ordinals','payment']})
//   window.XverseProviders.BitcoinProvider.request('signMessage', {address, message, protocol:'BIP322'})
//   -> {jsonrpc, id, result:{signature, messageHash, address, protocol}}
import { MNEMONIC, PASSWORD, clickButton, waitText, waitPopup, probePopup, popupSizeRequested, patchPopups, sleep, check, messages } from '../common.mjs';

export const kinds = ['p2tr', 'p2wpkh'];
export const popupRe = /request-popup\.html#\/sign-message-request/;
export const popupSize = { width: 375, height: 600 };

export async function onboard(ctx, id) {
  let p = ctx.pages().find(p => p.url().includes('options.html'));
  if (!p) { p = await ctx.newPage(); await p.goto(`chrome-extension://${id}/options.html#/landing`); }
  await clickButton(p, /^Restore an existing wallet$/);
  await waitText(p, /Authorize data collection/);
  // usage-data collection is pre-ticked; untick it
  await p.locator('input[type=checkbox]').evaluate(e => { if (e.checked) e.click(); });
  await clickButton(p, /^Accept$/);
  await p.locator('input[type=password]').fill(PASSWORD);
  await p.locator('button[type=submit]').click();
  await waitText(p, /Confirm your password/);
  await p.locator('input[type=password]').fill(PASSWORD);
  await p.locator('button[type=submit]').click();
  await waitText(p, /What wallet are you importing/);
  await clickButton(p, /^Xverse$/);
  await waitText(p, /Enter seed phrase/);
  const ins = p.locator('input:not([disabled])'); const w = MNEMONIC.split(' ');
  for (let i = 0; i < 12; i++) await ins.nth(i).fill(w[i]);
  await clickButton(p, /^Continue$/);
  // Xverse looks up balances of two derivation schemes; with none funded it may ask which to restore
  const t = await waitText(p, /Select a wallet to restore|Preferred address type/, 60000);
  if (/Select a wallet to restore/.test(t)) {
    await clickButton(p, /^Wallet 1/);
    await clickButton(p, /^Confirm$/);
    await waitText(p, /Preferred address type/, 60000);
  }
  await p.screenshot({ path: `${process.env.SHOTS}/xverse-onboard-preferred-address-type.png` });
  await clickButton(p, /^Native SegWit/);
  await clickButton(p, /^Continue$/);
  await waitText(p, /Wallet Restored/, 60000);
}

export async function connect(ctx, id, dapp) {
  const before = ctx.pages().slice();
  const pr = dapp.evaluate(() => window.XverseProviders.BitcoinProvider.request('wallet_connect', { addresses: ['ordinals', 'payment'], message: 'TAP wallet matrix test' }).then(r => ({ ok: r }), e => ({ err: e })));
  const p = await waitPopup(ctx, /connection-request/, before);
  await p.setViewportSize(popupSize); await sleep(1500);
  await p.screenshot({ path: `${process.env.SHOTS}/xverse-connect.png` });
  const popupText = await p.locator('body').innerText();
  await clickButton(p, /^Accept$/);
  const r = await pr;
  const addrs = r.ok.result.addresses;
  const byKind = {};
  for (const a of addrs) if (a.addressType === 'p2tr' || a.addressType === 'p2wpkh') byKind[a.addressType] = a;
  return { raw: r, popupText, addresses: addrs.map(a => a.address), byKind };
}

export function request(dapp, { address, message, protocol = 'BIP322' }) {
  return dapp.evaluate(([address, message, protocol]) => window.XverseProviders.BitcoinProvider.request('signMessage', protocol ? { address, message, protocol } : { address, message })
    .then(r => ({ ok: r }), e => ({ err: e })), [address, message, protocol]);
}
export function extract(raw) {
  if (raw && raw.result && typeof raw.result.signature === 'string') return { sig: raw.result.signature };
  return { err: raw && raw.error ? raw.error : raw };
}
export async function approve(p) { await clickButton(p, /^Sign$/); }
// the confirmation page shows the message as a one-line preview in a collapsed section; click its header to open it
export async function expand(p) {
  // the chevron at the right end of the "Message" header toggles it; click it with the mouse, as a user does
  const pt = await p.evaluate(() => {
    for (const e of document.querySelectorAll('*')) if (e.scrollTop) e.scrollTop = 0;
    const l = [...document.querySelectorAll('p,span,div,label')].find(e => e.children.length === 0 && (e.innerText || '').trim() === 'Message');
    if (!l) return null;
    const box = l.parentElement.parentElement.getBoundingClientRect(), r = l.getBoundingClientRect();
    return [box.right - 22, r.y + r.height / 2];
  });
  if (!pt) throw new Error('no Message section to expand');
  await p.mouse.click(pt[0], pt[1]);
  await new Promise(r => setTimeout(r, 800));
}

// Extra cells: (1) P2WPKH without `protocol` (the documented default is ECDSA for payment addresses);
// (2) the Nested SegWit (P2SH-P2WPKH) payment address, with protocol BIP322 and without.
export async function extras(ctx, id, dapp, { deadline, log, acc }) {
  const out = {};
  const one = async (label, address, message, protocol) => {
    await patchPopups(ctx);
    const before = ctx.pages().slice();
    const pr = request(dapp, { address, message, protocol });
    const rec = { address, protocol: protocol || '(none)', message };
    try {
      const p = await waitPopup(ctx, popupRe, before);
      const size = (await popupSizeRequested(ctx)) || popupSize;
      Object.assign(rec, await probePopup(ctx, p, message, `xverse-extra-${label}`, size));
      await expand(p); rec.expanded = await probePopup(ctx, p, message, `xverse-extra-${label}-expanded`, size);
      await approve(p);
    } catch (e) { rec.popupError = String(e.message || e); }
    const r = await Promise.race([pr, sleep(45000).then(() => ({ err: 'timeout' }))]);
    rec.raw = r.ok; if (r.err) rec.err = r.err;
    const x = extract(r.ok || {});
    if (x.sig) { rec.output = x.sig; Object.assign(rec, check(address, message, x.sig)); }
    log('extra', label, JSON.stringify(rec.raw && rec.raw.result || rec.err || rec.raw).slice(0, 300), rec.cliVerify, rec.rawLen);
    return rec;
  };
  const wp = acc.byKind.p2wpkh.address;
  const M = messages(wp, deadline);
  out['p2wpkh-no-protocol'] = await one('p2wpkh-no-protocol', wp, M.single.sign, null);
  out['p2tr-no-protocol'] = await one('p2tr-no-protocol', acc.byKind.p2tr.address, messages(acc.byKind.p2tr.address, deadline).single.sign, null);
  // switch the payment address to Nested SegWit in Settings > Advanced > Preferred Bitcoin Address
  const s = await ctx.newPage();
  await s.goto(`chrome-extension://${id}/popup.html#/settings/preferred-address`);
  await waitText(s, /Nested SegWit\s+[\d.]+ BTC\s+3\w{5}/);
  await sleep(1000);
  await clickButton(s, /^Nested SegWit/);
  await sleep(1000);
  // in 2.9.3 the choice may take effect on the click itself, leaving Save disabled; press Save only when it is enabled
  await clickButton(s, /^Save$/, 3000).catch(() => log('Save stayed disabled after choosing Nested SegWit'));
  await sleep(1500);
  await s.screenshot({ path: `${process.env.SHOTS}/xverse-settings-nested-segwit.png` });
  const ga = await dapp.evaluate(() => window.XverseProviders.BitcoinProvider.request('getAddresses', { purposes: ['payment', 'ordinals'] }).then(r => ({ ok: r }), e => ({ err: e })));
  out.getAddressesNested = ga;
  const p2sh = ga.ok.result.addresses.find(a => a.addressType === 'p2sh');
  // the text is the §5.1 message of the P2WPKH holder: no holder exists for a P2SH address, the text only has to be realistic
  out['p2sh-bip322'] = await one('p2sh-bip322', p2sh.address, M.single.sign, 'BIP322');
  out['p2sh-no-protocol'] = await one('p2sh-no-protocol', p2sh.address, M.single.sign, null);
  out.p2shAddress = p2sh;
  return out;
}
