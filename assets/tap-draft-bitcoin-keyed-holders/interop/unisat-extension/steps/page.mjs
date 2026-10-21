import { createWallet } from './mk.mjs';
async function approve(ctx, id, re, W, label) {
  const n = await ctx.newPage(); await n.goto(`chrome-extension://${id}/notification.html`); await n.waitForTimeout(1500);
  const t = await n.locator('body').innerText(); await n.getByText(re).first().click(); await new Promise(r=>setTimeout(r,800)); return t;
}
export default async (ctx, W, id) => {
  await createWallet(ctx, id, process.env.ATYPE||'Taproot (P2TR)');
  const pg = await ctx.newPage();
  pg.on('pageerror', e=>console.log('PAGEERROR', e.message.slice(0,200)));
  pg.on('console', m => console.log('console:', m.text().slice(0,200)));
  await pg.goto('http://127.0.0.1:8766/index.html'); await pg.waitForTimeout(1500);
  pg.on('dialog', d=>{console.log('DIALOG', d.message()); d.accept();});
  await pg.click('#c-unisat'); await pg.waitForTimeout(2500);
  await pg.waitForTimeout(1500);
  console.log('ACCT0', JSON.stringify(await pg.locator('#acct').innerText()), 'hasUnisat', await pg.evaluate(()=>typeof window.unisat));
  await approve(ctx, id, /^Connect$/, W);
  await pg.waitForTimeout(2500);
  console.log('ACCT', JSON.stringify((await pg.locator('#acct').innerText()).slice(0,300)));
  await pg.screenshot({path:`${W}/shots/page1.png`, fullPage:true});
  for (const [k,v] of Object.entries({pProc:'0x1f5cb4aeae1807bf60c3b9c0d8adbcc14e91f12c', pId:'920', pTo:'0x00000000000000000000000000000000000c0b7a', gas:'150000', tip:'0', nonce:'0', deadline:String(Math.floor(Date.now()/1000)+86400*30)})) await pg.fill('#'+k, v).catch(e=>console.log('nofill',k));
  console.log('MODE', await pg.locator('#mode').inputValue().catch(()=>'?'), await pg.locator('#mode option').allInnerTexts());
  await pg.click('#doSign'); await pg.waitForTimeout(1000);
  console.log('MESSAGE', JSON.stringify(await pg.locator('#message').inputValue().catch(async()=>await pg.locator('#message').innerText())));
  await pg.waitForTimeout(1500);
  console.log('APPROVE', JSON.stringify(await approve(ctx, id, /^Sign$/, W).catch(e=>'noapprove '+e.message)).slice(0,300));
  await pg.waitForTimeout(3000);
  console.log('SIGNOUT', JSON.stringify((await pg.locator('#signOut').innerText()).slice(0,900)));
  await pg.screenshot({path:`${W}/shots/page2.png`, fullPage:true});
};
