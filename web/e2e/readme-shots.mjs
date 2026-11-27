// The README's screenshots (docs/screenshots/), taken from the demo of
// deploy/compose/demo.sh on a running one-machine stack, so they show the
// dashboard as anyone who runs the demo sees it:
//
//   docker compose -f deploy/compose/docker-compose.yml up --build -d
//   sh deploy/compose/demo.sh
//   node web/e2e/readme-shots.mjs            # from the repository's top
//
// CID_SERVER and CID_TOKEN say where and how, as for the cid command.
import { chromium } from '@playwright/test';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const out = join(dirname(fileURLToPath(import.meta.url)), '../../docs/screenshots');
const base = process.env.CID_SERVER ?? 'http://127.0.0.1:7070';
const token = process.env.CID_TOKEN ?? 'cid-local-token';
const street = '/d/demo/datasets/street-scenes';
const sounds = '/d/demo/datasets/city-sounds';

const browser = await chromium.launch();

async function session(scheme, size) {
  const context = await browser.newContext({ viewport: size, colorScheme: scheme });
  const page = await context.newPage();
  await page.goto(`${base}/signin`);
  return { context, page };
}
async function signIn(page) {
  await page.getByLabel(/server token|access token/i).fill(token);
  await page.getByRole('button', { name: 'Open the dashboard' }).click();
  await page.getByRole('heading', { name: 'Datasets' }).waitFor();
}
// A page, settled: its requests done and its pictures decoded.
async function open(page, path) {
  await page.goto(base + path);
  await page.waitForLoadState('networkidle');
  await page.evaluate(() => Promise.all([...document.images].map((i) => i.decode().catch(() => {}))));
}
const shot = (page, name) => page.screenshot({ path: join(out, `${name}.png`) });

// The sign-in page, before signing in.
{
  const { context, page } = await session('light', { width: 1280, height: 720 });
  await page.getByRole('button', { name: 'Open the dashboard' }).waitFor();
  await shot(page, 'signin');
  await context.close();
}

for (const [scheme, theme] of [['dark', 'night'], ['light', 'daybreak']]) {
  const { context, page } = await session(scheme, { width: 1440, height: 900 });
  await signIn(page);

  await open(page, '/');
  await shot(page, `home-${theme}`);

  // Browse, with an item open in the drawer.
  await open(page, `${street}?view=browse&item=frames/frame-007.jpg`);
  await page.getByRole('complementary', { name: 'frames/frame-007.jpg' }).locator('img').first().waitFor();
  // The open tile is kept in view, which scrolls the header away: back up.
  await page.waitForTimeout(400);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(200);
  await shot(page, `browse-${theme}`);

  if (scheme === 'light') {
    await open(page, street);
    await shot(page, 'overview');

    // Compare: one photo of the review pass opened large, every box's
    // change in words beneath it.
    await open(page, `${street}?view=releases&a=v1.0&b=v1.1&pair=frames%2Fframe-007.jpg`);
    await page.getByRole('dialog').waitFor();
    await page.waitForLoadState('networkidle');
    await page.evaluate(() => Promise.all([...document.images].map((i) => i.decode().catch(() => {}))));
    await shot(page, 'compare-annotations');

    // Compare a table: the rows that changed, cell by cell.
    await open(page, `${sounds}?view=releases&a=v1.0&b=v1.1`);
    // A small diff opens by itself; a larger one waits for a click.
    const rows = page.locator('details', { has: page.getByText('Show the changed rows') }).first();
    if (!(await rows.evaluate((d) => d.open))) await rows.locator('summary').click();
    await page.waitForLoadState('networkidle');
    await shot(page, 'compare-table-rows');

    await open(page, '/no/such/page');
    await shot(page, 'lost-in-the-clouds');
  }
  await context.close();
}
await browser.close();
console.log(`wrote the screenshots to ${out}`);
