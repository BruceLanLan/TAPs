// Signs batch messages (TAP §5.3, TAP-draft-bitcoin-keyed-holders.md) in UniSat: run as step.mjs <W> batch with LAB=<this repository>, ATYPE, EXTDIR, PROFILE.
import { createWallet } from './mk.mjs';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
const LAB = process.env.LAB;
const py = (...a) => execFileSync('python3', a, {encoding:'utf8'}).trim();
async function approve(ctx, id, btnRegex, label, W) {
  const n = await ctx.newPage();
  await n.goto(`chrome-extension://${id}/notification.html`);
  await n.waitForTimeout(1500);
  const txt = await n.locator('body').innerText();
  await n.screenshot({path:`${W}/shots/${label}.png`, fullPage: true}).catch(()=>{});
  // how the message box is laid out: is the full text inside a scrollable element?
  const layout = await n.evaluate(() => {
    const els = [...document.querySelectorAll('div,span,p,pre,textarea')].filter(e => (e.innerText||'').includes('makes') && e.children.length === 0);
    return els.slice(0,3).map(e => ({tag: e.tagName, clientHeight: e.clientHeight, scrollHeight: e.scrollHeight, overflowY: getComputedStyle(e).overflowY, textLen: (e.innerText||'').length}));
  }).catch(e => String(e));
  // scroll to bottom, then screenshot again
  await n.evaluate(() => { for (const e of document.querySelectorAll('*')) if (e.scrollHeight > e.clientHeight) e.scrollTop = e.scrollHeight; });
  await n.screenshot({path:`${W}/shots/${label}-bottom.png`, fullPage: true}).catch(()=>{});
  await n.getByRole('button',{name:btnRegex}).first().click().catch(async()=>{ await n.getByText(btnRegex).first().click(); });
  await new Promise(r=>setTimeout(r,800));
  return {txt, layout};
}
export default async (ctx, W, id) => {
  const atype = process.env.ATYPE;
  await createWallet(ctx, id, atype);
  const dapp = await ctx.newPage();
  await dapp.goto('http://127.0.0.1:8765/blank.html');
  await dapp.waitForTimeout(800);
  const out = { atype, ext: JSON.parse(fs.readFileSync(`${process.env.EXTDIR}/manifest.json`)).version };
  const acc = dapp.evaluate(()=>window.unisat.requestAccounts());
  await dapp.waitForTimeout(1000);
  await approve(ctx, id, /^Connect$/, 'connect-'+atype.replace(/\W+/g,'_'), W);
  out.accounts = await acc;
  const addr = out.accounts[0];
  Object.assign(out, JSON.parse(py(`${LAB}/interop/unisat-extension/batch/mkmsgs.py`, addr, LAB)));
  for (const [k, c] of Object.entries(out.cases)) {
    const m = c.message;
    const pr = dapp.evaluate((m)=>window.unisat.signMessage(m,'bip322-simple').then(s=>({ok:s}),e=>({err:String(e&&e.message||e)})), m);
    await dapp.waitForTimeout(1000);
    const label = 'sign-'+atype.replace(/\W+/g,'_')+'-'+k;
    const {txt, layout} = await approve(ctx, id, /^Sign$/, label, W);
    const r = await pr;
    c.popupContainsFullText = txt.replace(/\s+/g,' ').includes(m);
    c.popupLayout = layout;
    c.result = r;
    if (r.ok) { try { c.cliVerify = py(`${LAB}/tools/cli.py`, 'verify', addr, m, r.ok); } catch(e) { c.cliVerify = 'INVALID'; }
                c.witness = py(`${LAB}/tools/cli.py`, 'witness', r.ok); }
    console.log(k, c.chars, 'popupFull', c.popupContainsFullText, 'verify', c.cliVerify, JSON.stringify(layout));
  }
  fs.writeFileSync(`${W}/result-batch-${atype.replace(/\W+/g,'_')}.json`, JSON.stringify(out,null,1));
};
