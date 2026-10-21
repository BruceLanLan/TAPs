import { createWallet } from './mk.mjs';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
const CLI = new URL('../../../tools/cli.py', import.meta.url).pathname;
const py = (...a) => execFileSync('python3', [CLI, ...a], {encoding:'utf8'}).trim();
async function approve(ctx, id, btnRegex, label, W) {
  const n = await ctx.newPage();
  await n.goto(`chrome-extension://${id}/notification.html`);
  await n.waitForTimeout(1500);
  const txt = await n.locator('body').innerText();
  await n.screenshot({path:`${W}/shots/${label}.png`}).catch(()=>{});
  await n.getByRole('button',{name:btnRegex}).first().click().catch(async()=>{ await n.getByText(btnRegex).first().click(); });
  await new Promise(r=>setTimeout(r,800));
  return txt;
}
export default async (ctx, W, id) => {
  const atype = process.env.ATYPE||'Taproot (P2TR)';
  await createWallet(ctx, id, atype);
  const dapp = await ctx.newPage();
  await dapp.goto('http://127.0.0.1:8765/blank.html');
  await dapp.waitForTimeout(800);
  const out = { atype, ext: JSON.parse(fs.readFileSync(`${process.env.EXTDIR}/manifest.json`)).version };
  const acc = dapp.evaluate(()=>window.unisat.requestAccounts());
  await dapp.waitForTimeout(1000);
  await approve(ctx, id, /^Connect$/, 'connect', W);
  out.accounts = await acc;
  const addr = out.accounts[0];
  out.publicKey = await dapp.evaluate(()=>window.unisat.getPublicKey());
  out.network = await dapp.evaluate(()=>window.unisat.getNetwork());
  console.log('addr', addr, 'net', out.network);
  const digest = '0x' + 'ab'.repeat(32);
  const target = '0x00000000000000000000000000000000000000aa';
  const holder = py('address', addr).split('\n').find(l=>l.startsWith('holder:')).split(/\s+/)[1];
  const NFT = '0x1f5cb4aeae1807bf60c3b9c0d8adbcc14e91f12c', RECIP = '0x00000000000000000000000000000000000c0b7a';
  const xdata = execFileSync(process.env.CAST||'cast', ['calldata','transferFrom(address,address,uint256)',holder,RECIP,'920'],{encoding:'utf8'}).trim();
  const deadline = Math.floor(Date.now()/1000)+86400*30;
  out.exec = { holder, nft: NFT, recipient: RECIP, tokenId: 920, data: xdata, callGas: 150000, tip: 0, deadline };
  const msgs = {
    exec: py('call-message', addr, '56', NFT, '0', xdata, '150000', '0', '0', String(deadline)),
    sign: py('sign-message', addr, '56', digest),
    call: py('call-message', addr, '56', target, '0', '0x', '0', '0', '1', String(Math.floor(Date.now()/1000)+86400*30)),
  };
  out.signs = {};
  for (const [k, m] of Object.entries(msgs)) {
    const pr = dapp.evaluate((m)=>window.unisat.signMessage(m,'bip322-simple').then(s=>({ok:s}),e=>({err:String(e&&e.message||e)})), m);
    await dapp.waitForTimeout(1000);
    const t = await approve(ctx, id, /^Sign$/, 'sign-'+k, W);
    const r = await pr;
    out.signs[k] = { message: m, popup: t, result: r };
    if (r.ok) {
      const raw = Buffer.from(r.ok.replace(/^smp/,''), 'base64');
      out.signs[k].rawLen = raw.length; out.signs[k].rawHex = raw.toString('hex');
      try { out.signs[k].cliVerify = py('verify', addr, m, r.ok); } catch(e) { out.signs[k].cliVerify = 'ERR ' + (e.stderr||e.message).toString().split('\n').slice(-2).join(' '); }
      try { out.signs[k].cliWitness = py('witness', r.ok); } catch(e) { out.signs[k].cliWitness = 'ERR ' + (e.stderr||e.message).toString().split('\n').slice(-2).join(' '); }
    }
    console.log(k, JSON.stringify(out.signs[k]).slice(0,900));
  }
  fs.writeFileSync(`${W}/result-${atype.replace(/\W+/g,'_')}.json`, JSON.stringify(out,null,1));
};
