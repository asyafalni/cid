import { expect, test } from '@playwright/test';

// The browse budget in a real browser (docs/dashboard.md: "Browse: first
// 60 thumbnails visible after filter change < 700 ms at 1M items").
// Opt-in: it needs the dataset tests/bench/browse_1m.sh seeds, so the
// everyday suite skips it.
//   BENCH_DATASET=bench/datasets/items-1000000 pnpm --dir web exec playwright test bench
const dataset = process.env.BENCH_DATASET;
const token = 'e2e-dashboard-token';
const budgetMs = 700;

test.skip(!dataset, 'set BENCH_DATASET to a dataset seeded by tests/bench/browse_1m.sh');

// The gallery renders what is on screen: a screen that shows 60 tiles,
// so "the first 60 thumbnails" are all there to count.
test.use({ viewport: { width: 1920, height: 1600 } });

test('filter change to the first 60 thumbnails, at the bench dataset', async ({ page }) => {
  test.setTimeout(120_000);
  await page.goto('/signin');
  await page.getByLabel(/server token|access token/i).fill(token);
  await page.getByRole('button', { name: 'Open the dashboard' }).click();
  await expect(page.getByRole('heading', { name: 'Datasets' })).toBeVisible();

  await page.goto(`/d/${dataset}?view=browse&release=v1`);
  const tiles = page.locator('.tile img');
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
    const before = await page.locator('.browse-bar [aria-live]').textContent();
    const start = Date.now();
    await page.getByLabel(label).selectOption(value);
    await expect(page.locator('.browse-bar [aria-live]')).not.toHaveText(before ?? '');
    await expect(tiles.nth(59)).toBeAttached();
    timings[`${label} = ${value}`] = Date.now() - start;
  }
  console.log('browse filter → 60 thumbnails (ms):', JSON.stringify(timings));
  for (const [what, ms] of Object.entries(timings)) {
    expect(ms, `${what} took ${ms} ms`).toBeLessThan(budgetMs);
  }
});
