// Shared helpers for the wallet runs: popup handling, UI probes, message building and checking with the TAP's tools/cli.py.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

export const LAB = process.env.LAB;              // the TAP repository (read only)
export const OUT = process.env.OUT;              // results directory
export const SHOTS = process.env.SHOTS;          // screenshots directory
export const DAPP = process.env.DAPP || 'http://127.0.0.1:18791/blank.html';
const HERE = path.dirname(new URL(import.meta.url).pathname);
export const sleep = (ms) => new Promise(r => setTimeout(r, ms));
export const MNEMONIC = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
export const PASSWORD = 'Test-only-pass-1';

export function cli(...a) {
  try { return execFileSync('python3', [`${LAB}/tools/cli.py`, ...a], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim(); }
  catch (e) { const o = String(e.stdout || '').trim(); return o || 'ERR ' + String(e.stderr || e.message).trim().split('\n').slice(-1)[0]; }
}
export function messages(addr, deadline) {
  return JSON.parse(execFileSync('python3', [`${HERE}/mkmsgs.py`, addr, LAB, String(deadline)], { encoding: 'utf8' }));
}
// what cli.py verify / witness say about a wallet output, and the decoded bytes
export function check(addr, message, out) {
  const r = { cliVerify: cli('verify', addr, message, out), cliWitness: cli('witness', out) };
  if (/^0x[0-9a-f]+$/.test(r.cliWitness)) {
    const w = Buffer.from(r.cliWitness.slice(2), 'hex');
    r.rawLen = w.length; r.rawHex = w.toString('hex'); r.witnessShape = shape(w);
  }
  return r;
}
// a readable description of a witness stack: item count, item lengths, sighash byte, DER length and low-s
export function shape(w) {
  try {
    let i = 0; const n = w[i++]; const items = [];
    for (let k = 0; k < n; k++) { const l = w[i++]; items.push(w.subarray(i, i + l)); i += l; }
    const s = { items: items.map(x => x.length), trailing: w.length - i };
    if (n === 1) s.sighash = items[0].length === 64 ? 'DEFAULT (64-byte Schnorr)' : '0x' + items[0][64].toString(16).padStart(2, '0');
    if (n === 2) {
      const sig = items[0]; s.sighash = '0x' + sig[sig.length - 1].toString(16).padStart(2, '0'); s.derLen = sig.length - 1;
      const rl = sig[3], sl = sig[5 + rl]; const sv = BigInt('0x' + sig.subarray(6 + rl, 6 + rl + sl).toString('hex'));
      const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n; s.lowS = sv <= N / 2n;
    }
    return s;
  } catch (e) { return { error: String(e) }; }
}

// Headless Chromium has no screen: chrome.windows.create({type:'popup', top, left}) can fail with "Bounds must be at
// least 50% within visible screen space". Retry once without top/left (same size, same type). Logged in self.__wlog.
export async function patchPopups(ctx) {
  for (const sw of ctx.serviceWorkers()) {
    await sw.evaluate(() => {
      self.__wlog = self.__wlog || [];
      if (self.__patched || !chrome.windows) return;
      self.__patched = true;
      const orig = chrome.windows.create.bind(chrome.windows);
      chrome.windows.create = async (opts, cb) => {
        self.__wlog.push(JSON.stringify(opts));
        let w;
        try { w = await orig(opts); }
        catch (e) { self.__wlog.push('retry without top/left: ' + e.message); const o = { ...opts }; delete o.top; delete o.left; w = await orig(o); }
        if (cb) cb(w);
        return w;
      };
    }).catch(() => {});
  }
}
export async function popupSizeRequested(ctx) {
  for (const sw of ctx.serviceWorkers()) {
    const log = await sw.evaluate(() => self.__wlog || []).catch(() => []);
    for (let i = log.length - 1; i >= 0; i--) { try { const o = JSON.parse(log[i]); if (o.width) return { width: o.width, height: o.height }; } catch {} }
  }
  return null;
}

// wait for an extension page whose URL matches re and that was not open before
export async function waitPopup(ctx, re, before, ms = 20000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    const p = ctx.pages().find(p => re.test(p.url()) && !before.includes(p));
    if (p) return p;
    await sleep(250);
  }
  throw new Error('no popup matching ' + re);
}
export async function clickButton(page, re, ms = 15000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    const ok = await page.evaluate((src) => {
      const re = new RegExp(src, 'i');
      const b = [...document.querySelectorAll('button,[role=button]')].find(b => re.test((b.innerText || b.getAttribute('aria-label') || '').trim()) && !b.disabled && b.offsetParent !== null);
      if (!b) return false; b.click(); return true;
    }, re.source).catch(() => false);
    if (ok) return true;
    await sleep(300);
  }
  throw new Error('no enabled button ' + re);
}
export async function waitText(page, re, ms = 30000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    const t = await page.locator('body').innerText().catch(() => '');
    if (re.test(t)) return t;
    await sleep(300);
  }
  throw new Error('text not found ' + re);
}

// Looks at a confirmation page the way a user would: at the size the wallet asked for, before and after scrolling.
// Returns the page text, whether it contains the whole message, and how the element(s) holding the message are laid out.
export async function probePopup(ctx, page, message, label, size) {
  if (size) await page.setViewportSize(size);
  await sleep(1200);
  await page.screenshot({ path: `${SHOTS}/${label}.png` }).catch(() => {});
  const txt = await page.locator('body').innerText().catch(() => '');
  const norm = (s) => s.replace(/\s+/g, '');
  const head = message.slice(0, 40), tail = message.slice(-40);
  const layout = await page.evaluate(([head, tail, msg]) => {
    const norm = (s) => s.replace(/\s+/g, '');
    const all = [...document.querySelectorAll('body *')];
    const holders = all.filter(e => norm(e.innerText || e.value || '').includes(norm(head)) && ![...e.children].some(c => norm(c.innerText || '').includes(norm(head))));
    const clip = (e) => { const out = []; for (let a = e; a && a !== document.body; a = a.parentElement) { const cs = getComputedStyle(a); if (cs.overflowY !== 'visible' || cs.overflowX !== 'visible' || cs.maxHeight !== 'none') out.push({ tag: a.tagName, overflowY: cs.overflowY, maxHeight: cs.maxHeight, clientHeight: a.clientHeight, scrollHeight: a.scrollHeight }); } return out.slice(0, 4); };
    return holders.slice(0, 4).map(e => {
      const cs = getComputedStyle(e); const r = e.getBoundingClientRect(); const t = e.innerText || e.value || '';
      return { tag: e.tagName, visible: !!(e.offsetParent || cs.position === 'fixed') && r.height > 0 && cs.visibility !== 'hidden' && cs.opacity !== '0',
        textLen: t.length, equalsMessage: norm(t) === norm(msg), containsTail: norm(t).includes(norm(tail)),
        clientHeight: e.clientHeight, scrollHeight: e.scrollHeight, overflowY: cs.overflowY, textOverflow: cs.textOverflow,
        lineClamp: cs.webkitLineClamp, whiteSpace: cs.whiteSpace, wordBreak: cs.wordBreak, rect: [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)],
        clippingAncestors: clip(e) };
    });
  }, [head, tail, message]).catch(e => String(e));
  await page.evaluate(() => { for (const e of document.querySelectorAll('*')) if (e.scrollHeight > e.clientHeight + 2) e.scrollTop = e.scrollHeight; }).catch(() => {});
  await sleep(400);
  await page.screenshot({ path: `${SHOTS}/${label}-bottom.png` }).catch(() => {});
  await page.screenshot({ path: `${SHOTS}/${label}-full.png`, fullPage: true }).catch(() => {});
  return { popupText: txt, popupContainsFullText: norm(txt).includes(norm(message)), popupLayout: layout, popupViewport: size };
}
export function save(name, obj) { fs.writeFileSync(`${OUT}/${name}`, JSON.stringify(obj, null, 1)); }
