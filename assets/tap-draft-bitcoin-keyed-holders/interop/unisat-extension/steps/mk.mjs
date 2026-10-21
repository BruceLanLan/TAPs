// create wallet from the public test mnemonic with a given address type; env ATYPE
export async function createWallet(ctx, id, atype) {
  const p = await ctx.newPage();
  await p.goto(`chrome-extension://${id}/index.html#/welcome`);
  await p.waitForTimeout(800);
  await p.getByText('I already have a wallet').click();
  await p.waitForTimeout(600);
  let inputs = p.locator('input');
  await inputs.nth(0).fill('Test-only-pass-1'); await inputs.nth(1).fill('Test-only-pass-1');
  await p.getByText('Continue').click(); await p.waitForTimeout(800);
  await p.getByText('UniSat Wallet').click(); await p.waitForTimeout(800);
  const words = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about'.split(' ');
  inputs = p.locator('input:not([type=checkbox])');
  console.log('word inputs', await inputs.count());
  if (await p.locator('textarea').count() === 1) { await p.locator('textarea').click(); await p.keyboard.type(words.join(' ')+' ', {delay: 30}); }
  else for (let i=0;i<12;i++) await inputs.nth(i).fill(words[i]);
  await p.waitForTimeout(500); await p.screenshot({path:'shots/mn.png'});
  await p.getByText('Continue').click(); await p.waitForTimeout(1500);
  await p.getByText(atype).click(); await p.waitForTimeout(500);
  await p.getByText('Continue').click(); await p.waitForTimeout(2500);
  return p;
}
