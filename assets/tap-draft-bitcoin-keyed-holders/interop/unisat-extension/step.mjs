// usage: node step.mjs <W> <name> ; runs ./steps/<name>.mjs default export(ctx, page, W)
import { chromium } from 'playwright';
import path from 'node:path';
const [W, name] = process.argv.slice(2);
const ctx = await chromium.launchPersistentContext(path.join(W, process.env.PROFILE||'profile'), {
  channel: 'chromium', headless: true,
  args: [`--disable-extensions-except=${process.env.EXTDIR}`, `--load-extension=${process.env.EXTDIR}`],
  viewport: { width: 1000, height: 800 },
});
try {
  await new Promise(r=>setTimeout(r,2500));
  const extId = new URL(ctx.serviceWorkers()[0].url()).host;
  const mod = await import(`${W}/steps/${name}.mjs`);
  process.env.EXTDIR = process.env.EXTDIR; await mod.default(ctx, W, extId);
} catch (e) { console.log('STEP ERROR', e.message); }
await ctx.close();
