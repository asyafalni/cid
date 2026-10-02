import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { gzipSync } from 'node:zlib';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const token = 'e2e-dashboard-token';

async function signIn(page: import('@playwright/test').Page) {
  await page.goto('/signin');
  await page.getByLabel('Access token').fill(token);
  await page.getByRole('button', { name: 'Open the dashboard' }).click();
  await expect(page.getByRole('heading', { name: 'Datasets' })).toBeVisible();
}

test('sign-in guards the deck and the token opens it', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveURL(/\/signin/);
  await signIn(page);
  await expect(page.getByText('e2e/datasets/demo')).toBeVisible();
});

test('the overview carries the tape, the card and the paste-ready command', async ({ page }) => {
  await signIn(page);
  await page.getByRole('link', { name: 'e2e/datasets/demo' }).click();
  // The tape: both releases as engraved tags, newest pinned by default.
  await expect(page.getByRole('button', { name: 'v1.1.0' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'v1.0.0' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'v1.1.0' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  // The engraved count line and the command.
  await expect(page.getByText(/4 items ·/)).toBeVisible();
  await expect(page.getByText(/cid clone cid@.*e2e\/datasets\/demo --release v1\.1\.0/)).toBeVisible();
  // Picking the older release repins and lands in the URL (every view is a link).
  await page.getByRole('button', { name: 'v1.0.0' }).click();
  await expect(page).toHaveURL(/release=v1\.0\.0/);
  await expect(page.getByText(/--release v1\.0\.0/)).toBeVisible();
});

test('browse shows thumbnails for images and honest tiles for the rest', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/demo?view=browse');
  // Two image tiles with real thumbnails, one type tile for the text files.
  await expect(page.locator('.tile img')).toHaveCount(2);
  await expect(page.locator('.tile-type').first()).toBeVisible();
  // The drawer: facts, hash chip, annotations absent on a file dataset.
  await page.getByRole('button', { name: /img-a\.png/ }).click();
  await expect(page).toHaveURL(/item=img/);
  await expect(page.getByText('sha-256')).toBeVisible();
  await expect(page.getByRole('link', { name: 'Download the file' })).toBeVisible();
  // Dimensions arrived through sniffing, not from any client claim.
  await expect(page.getByText('200×150')).toBeVisible();
});

test('compare between the two releases reads as a sentence', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/demo?view=releases');
  await expect(page.getByText(/1 added · 0 modified · 0 deleted/)).toBeVisible();
  await expect(page.locator('.change-verb--added')).toHaveText('added');
  await expect(page.getByText('notes.txt')).toBeVisible();
});

test('the files tab walks the committed tree', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/demo?view=files');
  await expect(page.getByText('README.txt')).toBeVisible();
  await expect(page.getByText('img-a.png')).toBeVisible();
});

test('keyboard: the tape is reachable and Enter pins', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/demo');
  await page.getByRole('button', { name: 'v1.0.0' }).focus();
  await page.keyboard.press('Enter');
  await expect(page).toHaveURL(/release=v1\.0\.0/);
});

test('a detection dataset: boxes are drawn in the gallery and the drawer', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/boxes?view=browse');
  // Two boxes on the one frame, from the release's own pixel space.
  await expect(page.locator('.tile .overlay rect')).toHaveCount(2);
  // Toggling a class hides exactly its shapes, and says so on the chip.
  const person = page.getByRole('button', { name: /person/ });
  await expect(person).toHaveAttribute('aria-pressed', 'true');
  await person.click();
  await expect(page.locator('.tile .overlay rect')).toHaveCount(1);
  await person.click();
  await expect(page.locator('.tile .overlay rect')).toHaveCount(2);
  // The opacity control is a labelled input, not a mystery dial.
  await expect(page.getByLabel('Overlay opacity')).toBeVisible();
  // The drawer draws the same shapes at size and names both classes.
  await page.getByRole('button', { name: /street\.png/ }).click();
  await expect(page.locator('.drawer .overlay rect')).toHaveCount(2);
  await expect(page.locator('.drawer .ann-list li')).toHaveCount(2);
});

test('filters narrow browse, count their options, and live in the URL', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/demo?view=browse');
  await expect(page.getByText('4 items', { exact: true })).toBeVisible();

  // Non-image data first: the text files, by type.
  await page.getByLabel('Filter by type').selectOption('.txt');
  await expect(page).toHaveURL(/type=\.txt/);
  await expect(page.getByText('2 of 4 items')).toBeVisible();
  await expect(page.locator('.tile')).toHaveCount(2);

  // Path search composes with it, after the debounce, as one URL change.
  await page.getByLabel('Filter by path').fill('notes');
  await expect(page).toHaveURL(/q=notes/);
  await expect(page.getByText('1 of 4 items')).toBeVisible();

  // A filter that matches nothing says so and offers the way back.
  await page.getByLabel('Filter by path').fill('nothing-is-called-this');
  await expect(page.getByRole('heading', { name: 'No item matches these filters' })).toBeVisible();
  await page.getByRole('button', { name: 'Clear filters' }).first().click();
  await expect(page.getByText('4 items', { exact: true })).toBeVisible();

  // `t` switches to the table, into the URL; `g` back.
  await page.locator('body').press('t');
  await expect(page).toHaveURL(/mode=table/);
  await expect(page.locator('.browse-table')).toBeVisible();
  await page.locator('body').press('g');
  await expect(page.locator('.gallery')).toBeVisible();
});

test('a view opened from its URL in a new browser shows the same release, filters and item', async ({
  page,
  browser,
}) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/demo?view=browse&release=v1.0.0&type=.png&item=img-a.png');
  await expect(page.getByText('2 of 3 items')).toBeVisible();
  const url = page.url();

  // docs/dashboard.md §9, literally: a fresh browser, the URL, nothing else.
  const fresh = await browser.newContext();
  const other = await fresh.newPage();
  await signIn(other);
  await other.goto(url);
  // The release: v1.0.0 has no notes.txt, so three items, two of them png.
  await expect(other.getByRole('button', { name: 'v1.0.0' })).toHaveAttribute('aria-pressed', 'true');
  await expect(other.getByText('2 of 3 items')).toBeVisible();
  await expect(other.getByLabel('Filter by type')).toHaveValue('.png');
  // The item: its drawer open, at that release.
  await expect(other.getByRole('complementary', { name: 'img-a.png' })).toBeVisible();
  await fresh.close();
});

test('a class filter keeps the items that carry the class', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/boxes?view=browse');
  await page.getByLabel('Filter by class').selectOption('person');
  await expect(page).toHaveURL(/class=person/);
  await expect(page.getByText('1 of 1 items')).toBeVisible();
});

test('compare: a changed box shows before and after on the same image', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/boxes?view=releases&a=v1.0.0&b=v1.1.0');
  // The sentence: no file changed, one annotation did.
  await expect(page.getByText(/0 added · 0 modified · 0 deleted/)).toBeVisible();
  await expect(page.getByText(/annotations: 0 added · 1 changed · 0 removed/)).toBeVisible();

  // docs/dashboard.md §9: the same image twice, the box where each
  // version had it — dashed for the old, solid for the new.
  const pair = page.locator('.visual-diff-item');
  await expect(pair).toHaveCount(1);
  await expect(pair.locator('img')).toHaveCount(2);
  const before = pair.locator('.overlay--before rect');
  const after = pair.locator('.overlay--after rect');
  await expect(before).toHaveCount(1);
  await expect(after).toHaveCount(1);
  await expect(before).toHaveAttribute('x', '20');
  await expect(after).toHaveAttribute('x', '45');
  // Only the changed shape is drawn: the vehicle that did not move is not.
  await expect(pair.getByText('v1.0.0 · 1 shape')).toBeVisible();
  await expect(pair.getByText('v1.1.0 · 1 shape')).toBeVisible();
});

test('accessibility: no serious or critical axe findings', async ({ page }) => {
  await signIn(page);
  for (const path of ['/', '/d/e2e/datasets/demo', '/d/e2e/datasets/demo?view=browse', '/d/e2e/datasets/boxes?view=browse', '/d/e2e/datasets/demo?view=browse&type=.txt&mode=table', '/d/e2e/datasets/boxes?view=releases&a=v1.0.0&b=v1.1.0']) {
    await page.goto(path);
    await page.waitForLoadState('networkidle');
    const results = await new AxeBuilder({ page }).analyze();
    const bad = results.violations.filter(
      (v) => v.impact === 'serious' || v.impact === 'critical',
    );
    expect(bad, `${path}: ${bad.map((v) => v.id).join(', ')}`).toEqual([]);
  }
});

test('budget: first-load JS stays under 300 KB gzipped', () => {
  const assets = resolve(dirname(fileURLToPath(import.meta.url)), '../dist/assets');
  let total = 0;
  for (const name of readdirSync(assets)) {
    if (name.endsWith('.js')) total += gzipSync(readFileSync(resolve(assets, name))).length;
  }
  expect(total).toBeLessThan(300 * 1024);
});
