import { expect, test } from '@playwright/test';

// The dashboard's budgets in a real browser, at 1M items
// (docs/dashboard.md, performance and quality budgets). Opt-in: it needs
// the dataset tests/bench/browse_1m.sh seeds, so the everyday suite skips
// it. Run against a ReleaseFast build, as a deployment would be:
//   CID_BIN=<release build>/bin/cid BENCH_DATASET=bench/datasets/items-1000000 \
//     pnpm --dir web exec playwright test bench
const dataset = process.env.BENCH_DATASET;
const token = 'e2e-dashboard-token';
const budgetMs = 700;

test.skip(!dataset, 'set BENCH_DATASET to a dataset seeded by tests/bench/browse_1m.sh');

// The gallery renders what is on screen: a screen that shows 60 tiles,
// so "the first 60 thumbnails" are all there to count.
test.use({ viewport: { width: 1920, height: 1600 } });

async function signIn(page: import('@playwright/test').Page) {
  await page.goto('/signin');
  await page.getByLabel(/server token|access token/i).fill(token);
  await page.getByRole('button', { name: 'Open the dashboard' }).click();
  await expect(page.getByRole('heading', { name: 'Datasets' })).toBeVisible();
}

// The 75th percentile of a handful of runs: one slow run is noise, most
// runs being slow is the answer.
function p75(ms: number[]): number {
  const sorted = [...ms].sort((a, b) => a - b);
  return sorted[Math.ceil(sorted.length * 0.75) - 1];
}

test('filter change to the first 60 thumbnails, at the bench dataset', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page);

  await page.goto(`/d/${dataset}?view=browse&release=v1`);
  // A tile's picture, or its "no preview" when the picture fails (the
  // seeded items have no previews in storage): either is the tile drawn.
  const tiles = page.locator('.tile :is(img, .thumb-missing)');
  await expect(tiles.nth(59)).toBeAttached({ timeout: 60_000 });

  // Each filter change, timed from the choice to the 60th thumbnail in the
  // page: the server's query, the page's presigns, and React's render.
  const timings: Record<string, number> = {};
  for (const [label, value] of [
    ['Filter by split', 'val'],
    ['Filter by class', 'truck'],
    ['Filter by split', 'test'],
    ['Filter by class', 'car'],
  ] as const) {
    // Timed in the page, checked every frame: Playwright's own waiting
    // looks at 0, 20, 70, 170 and 270 ms, then every 500 ms, so a tile
    // drawn at 280 ms used to be counted at about 800. A filter change
    // empties the gallery first, so the 60 counted are the new results.
    const drawn = page.evaluate(
      () =>
        new Promise<number>((resolve) => {
          const count = () => document.querySelectorAll('.tile :is(img, .thumb-missing)').length;
          const start = performance.now();
          let emptied = false;
          const check = () => {
            if (!emptied) emptied = count() === 0;
            if (emptied && count() >= 60) resolve(performance.now() - start);
            else requestAnimationFrame(check);
          };
          requestAnimationFrame(check);
        }),
    );
    await page.getByLabel(label).selectOption(value);
    const ms = Math.round(await drawn);
    timings[`${label} = ${value}`] = ms;
  }
  console.log('browse filter → 60 thumbnails (ms):', JSON.stringify(timings));
  for (const [what, ms] of Object.entries(timings)) {
    expect(ms, `${what} took ${ms} ms`).toBeLessThan(budgetMs);
  }
});

// "Overview page, first meaningful paint (p75, office network) < 1.0 s":
// a fresh load of the dataset's page until its card shows the counts.
// Here the network is the machine's own, so this is the server's and the
// browser's share of it.
test('the overview page, loaded fresh, shows its card within the budget', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page);
  await page.goto(`/d/${dataset}`);
  await expect(page.getByRole('region', { name: 'Dataset card' })).toContainText(/\d/, { timeout: 60_000 });
  const runs: number[] = [];
  for (let i = 0; i < 8; i++) {
    const start = Date.now();
    await page.goto(`/d/${dataset}`);
    await expect(page.getByRole('region', { name: 'Dataset card' })).toContainText(/\d/);
    runs.push(Date.now() - start);
  }
  console.log('overview, fresh load to the card (ms):', JSON.stringify(runs), 'p75', p75(runs));
  expect(p75(runs), `p75 ${p75(runs)} ms`).toBeLessThan(1000);
});

// "Item drawer open < 300 ms": a tile clicked, until the drawer shows the
// item's facts.
test('an item opens in the drawer within the budget', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page);
  await page.goto(`/d/${dataset}?view=browse&release=v1`);
  const tiles = page.locator('.gallery .tile');
  await expect(tiles.nth(20)).toBeAttached({ timeout: 60_000 });
  const runs: number[] = [];
  for (let i = 0; i < 8; i++) {
    const start = Date.now();
    await tiles.nth(i * 2).click();
    await expect(page.locator('.drawer .drawer-facts')).toBeVisible();
    runs.push(Date.now() - start);
    await page.locator('.drawer-close').click();
    await expect(page.locator('.drawer')).toHaveCount(0);
  }
  console.log('drawer open (ms):', JSON.stringify(runs), 'p75', p75(runs));
  expect(p75(runs), `p75 ${p75(runs)} ms`).toBeLessThan(300);
});

// "Gallery scrolling: 60 fps, no blank tiles after 200 ms": scrolled a
// screen at a time through several pages of items, frames counted as the
// browser paints them. Blank is a tile in view still without its
// thumbnail's address, or the next page still on its way in view. (The
// bench's thumbnails are recorded but not stored, so images themselves
// never arrive; what is measured is everything cid does before them.)
test('the gallery scrolls at 60 fps with no blank tiles 200 ms after each stop', async ({ page }) => {
  test.setTimeout(180_000);
  await signIn(page);
  await page.goto(`/d/${dataset}?view=browse&release=v1`);
  await expect(page.locator('.gallery .tile').nth(59)).toBeAttached({ timeout: 60_000 });

  await page.evaluate(() => {
    const w = window as unknown as { frames_: number[]; recording: boolean };
    w.frames_ = [];
    w.recording = true;
    let last = performance.now();
    const tick = (now: number) => {
      if (!w.recording) return;
      w.frames_.push(now - last);
      last = now;
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });

  const blanks: number[] = [];
  for (let step = 0; step < 30; step++) {
    await page.mouse.wheel(0, 900);
    await page.waitForTimeout(200);
    blanks.push(
      await page.evaluate(() => {
        const inView = (el: Element) => {
          const r = el.getBoundingClientRect();
          return r.bottom > 0 && r.top < innerHeight;
        };
        const tiles = [...document.querySelectorAll('.gallery .tile')].filter(inView);
        const noThumb = tiles.filter((t) => {
          const img = t.querySelector('img');
          return img !== null && !img.getAttribute('src');
        }).length;
        const more = document.querySelector('.more-items');
        const waiting = more !== null && inView(more) && (more as HTMLButtonElement).disabled ? 1 : 0;
        return noThumb + waiting;
      }),
    );
  }
  const frames = await page.evaluate(() => {
    const w = window as unknown as { frames_: number[]; recording: boolean };
    w.recording = false;
    return w.frames_.slice(1);
  });
  const sorted = [...frames].sort((a, b) => a - b);
  const fps = 1000 / (frames.reduce((a, b) => a + b, 0) / frames.length);
  const p95 = sorted[Math.floor(sorted.length * 0.95)];
  console.log('gallery scroll:', `${fps.toFixed(1)} fps average, p95 frame ${p95.toFixed(1)} ms,`, 'blank after 200 ms per step:', JSON.stringify(blanks));
  expect(fps, `${fps.toFixed(1)} fps`).toBeGreaterThanOrEqual(55);
  expect(blanks.every((b) => b === 0), `blank tiles: ${JSON.stringify(blanks)}`).toBe(true);
});
