// Renders single frames for review: node stills.mjs out-dir 1.0 9.2 17.0 ...
import { chromium } from 'playwright-core';
import path from 'node:path';
import fs from 'node:fs';

const [out, ...times] = process.argv.slice(2);
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', args: ['--force-color-profile=srgb', '--hide-scrollbars'] });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
page.on('console', m => console.log('console:', m.text()));
page.on('pageerror', e => console.log('pageerror:', e.message));
await page.goto('file://' + path.resolve('index.html') + '#render');
await page.waitForFunction(() => window.READY === true);
for (const t of times) {
  await page.evaluate(t => window.render(t), +t);
  await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
  await page.screenshot({ path: `${out}/t${(+t).toFixed(2).padStart(6, '0')}.jpg`, type: 'jpeg', quality: 80 });
}
await browser.close();
