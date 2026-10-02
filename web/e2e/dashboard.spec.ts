import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { gzipSync } from 'node:zlib';
import { mkdtempSync, readFileSync, readdirSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const token = 'e2e-dashboard-token';

async function signIn(page: import('@playwright/test').Page) {
  await page.goto('/signin');
  await page.getByLabel(/server token|access token/i).fill(token);
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
  await expect(page.getByRole('region', { name: 'Dataset card' }).getByText(/4 items ·/)).toBeVisible();
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

test('the command copied from "Use this dataset" works as pasted, subset and all', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/boxes');
  const panel = page.getByRole('region', { name: 'Use this dataset' });

  await panel.getByRole('radio', { name: 'yolo' }).click();
  await panel.getByRole('group', { name: 'Splits' }).getByRole('button', { name: 'train' }).click();
  await panel.getByRole('group', { name: 'Classes' }).getByRole('button', { name: 'person' }).click();
  // The size line is the sum the command will download, not a guess.
  await expect(panel.getByText(/^1 of 1 items · /)).toBeVisible();
  await expect(panel.locator('pre')).toContainText('boxes/dataset.yaml');

  const command = (await panel.locator('code.command').textContent())!.trim();
  expect(command).toBe(
    'cid clone cid@127.0.0.1:e2e/datasets/boxes --release v1.1.0 --format yolo --split train --class person',
  );

  // docs/dashboard.md §9, literally: run what was copied. Token auth
  // stands in for the SSH key the e2e machine does not have.
  const here = dirname(fileURLToPath(import.meta.url));
  const cid = resolve(here, '../../zig-out/bin/cid');
  const dir = mkdtempSync(resolve(tmpdir(), 'cid-pasted-'));
  execSync(command.replace(/^cid /, `${cid} `), {
    cwd: dir,
    env: { ...process.env, CID_SERVER: 'http://127.0.0.1:7177', CID_TOKEN: token },
    stdio: 'pipe',
  });
  // Only the class it asked for, re-indexed from zero.
  expect(readFileSync(resolve(dir, 'boxes/classes.txt'), 'utf8')).toBe('person\n');
  expect(readFileSync(resolve(dir, 'boxes/labels/frames/street.txt'), 'utf8').trim().split('\n')).toHaveLength(1);
});

test('home: each dataset row is a card, and search reaches classes and types', async ({ page }) => {
  await signIn(page);
  const demo = page.locator('.manifest-row', { has: page.getByRole('link', { name: 'e2e/datasets/demo', exact: true }) });
  // The mosaic is the dataset's own finished previews; the facts line
  // agrees with the dataset card.
  await expect(demo.locator('.mosaic img')).toHaveCount(2);
  await expect(demo.getByText(/4 items · 5\.8 KB · /)).toBeVisible();

  // A class name finds the dataset whose name never says it.
  await page.getByLabel('Search datasets').fill('person');
  await expect(page).toHaveURL(/q=person/);
  await expect(page.getByRole('link', { name: 'e2e/datasets/boxes', exact: true })).toBeVisible();
  await expect(page.getByRole('link', { name: 'e2e/datasets/demo', exact: true })).toHaveCount(0);

  // A file type: the text files live in demo, not in boxes.
  await page.getByLabel('Search datasets').fill('');
  await page.getByLabel('Filter by type').selectOption('.txt');
  await expect(page.getByRole('link', { name: 'e2e/datasets/demo', exact: true })).toBeVisible();
  await expect(page.getByRole('link', { name: 'e2e/datasets/boxes', exact: true })).toHaveCount(0);
});

test('home: a visited dataset appears under Recently viewed', async ({ page }) => {
  await signIn(page);
  await expect(page.getByRole('navigation', { name: 'Recently viewed' })).toHaveCount(0);
  await page.goto('/d/e2e/datasets/boxes');
  await expect(page.getByRole('region', { name: 'Use this dataset' })).toBeVisible();
  await page.goto('/');
  const recent = page.getByRole('navigation', { name: 'Recently viewed' });
  await expect(recent.getByRole('link', { name: 'e2e/datasets/boxes' })).toBeVisible();
});

test('sign in with GitLab: the round trip, the cookie, and only what the role allows', async ({ page, context }) => {
  await page.goto('/');
  await expect(page).toHaveURL(/\/signin/);
  await page.getByRole('link', { name: 'Sign in with GitLab' }).click();

  // Through the (strict) fake GitLab and back: PKCE, state, token, user.
  await expect(page.getByRole('heading', { name: 'Datasets' })).toBeVisible();
  await expect(page.locator('.rail-who')).toHaveText('Rhea Reviewer');

  // The session cookie, exactly as docs/dashboard.md specifies it.
  const cookie = (await context.cookies()).find((c) => c.name === '__Host-session');
  expect(cookie).toBeDefined();
  expect(cookie!.httpOnly).toBe(true);
  expect(cookie!.secure).toBe(true);
  expect(cookie!.sameSite).toBe('Lax');
  const hours = (cookie!.expires * 1000 - Date.now()) / 3_600_000;
  expect(hours).toBeGreaterThan(11.9);
  expect(hours).toBeLessThanOrEqual(12);

  // Rhea's GitLab role reads boxes and nothing else: that is all she sees.
  await expect(page.getByRole('link', { name: 'e2e/datasets/boxes', exact: true })).toBeVisible();
  await expect(page.getByRole('link', { name: 'e2e/datasets/demo', exact: true })).toHaveCount(0);
  await page.goto('/d/e2e/datasets/demo');
  await expect(page.getByRole('alert')).toContainText(/token|signed in|dataset/i);

  // Sign out ends it: the guard sends the next visit to the sign-in page.
  await page.goto('/');
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(page).toHaveURL(/\/signin/);
  await page.goto('/');
  await expect(page).toHaveURL(/\/signin/);
});

test('a signed-in person stars a dataset, finds it under Starred, and finds owners by name', async ({ page }) => {
  await page.goto('/signin');
  await page.getByRole('link', { name: 'Sign in with GitLab' }).click();
  await expect(page.getByRole('heading', { name: 'Datasets' })).toBeVisible();

  // Owners are searchable by name: Olu maintains boxes.
  const row = page.locator('.manifest-row', { has: page.getByRole('link', { name: 'e2e/datasets/boxes', exact: true }) });
  await expect(row.getByText('owned by Olu Owner')).toBeVisible();

  const star = page.getByRole('button', { name: 'Star e2e/datasets/boxes' });
  await star.click();
  await expect(page.getByRole('button', { name: 'Unstar e2e/datasets/boxes' })).toHaveAttribute('aria-pressed', 'true');
  // A star is kept on the server, for this person: a reload still has it.
  await page.reload();
  await expect(page.getByRole('navigation', { name: 'Starred' }).getByRole('link', { name: 'e2e/datasets/boxes' })).toBeVisible();
  await page.getByRole('button', { name: 'Unstar e2e/datasets/boxes' }).click();
  await expect(page.getByRole('navigation', { name: 'Starred' })).toHaveCount(0);

  await page.getByLabel('Search datasets').fill('olu');
  await expect(page.getByRole('link', { name: 'e2e/datasets/boxes', exact: true })).toBeVisible();
});

test('the server token cannot star: a star belongs to a person', async ({ page }) => {
  await signIn(page);
  await expect(page.getByRole('heading', { name: 'Datasets' })).toBeVisible();
  await expect(page.locator('.star')).toHaveCount(0);
});

test('restricted: blurred until a logged reveal, and the log is for owners', async ({ page }) => {
  await signIn(page); // the server token: an owner of everything
  // The home's card shows the blur, never the clear thumbnail.
  const card = page.locator('.manifest-row', { has: page.getByRole('link', { name: 'e2e/datasets/faces', exact: true }) });
  await expect(card.locator('.mosaic img')).toHaveAttribute('src', /blur\.webp/);

  await page.goto('/d/e2e/datasets/faces?view=browse');
  await expect(page.getByText('restricted · blurred until revealed')).toBeVisible();
  await expect(page.locator('.tile img')).toHaveAttribute('src', /blur\.webp/);
  await page.getByRole('button', { name: /person-01\.png/ }).click();
  const drawer = page.getByRole('complementary', { name: 'person-01.png' });
  await expect(drawer.locator('img')).toHaveAttribute('src', /blur\.webp/);
  // No clear bytes until the reveal: not even a download link.
  await expect(drawer.getByRole('link', { name: 'Download the file' })).toHaveCount(0);
  await expect(drawer.getByText('is logged')).toBeVisible();

  await drawer.getByRole('button', { name: 'Reveal this item' }).click();
  await expect(drawer.locator('img')).toHaveAttribute('src', /thumb\.webp/);
  await expect(drawer.getByRole('link', { name: 'Download the file' })).toBeVisible();
  await expect(drawer.getByText('Revealed; this was logged.')).toBeVisible();

  // The owner's log shows it.
  await page.goto('/d/e2e/datasets/faces?view=activity');
  await expect(page.locator('.activity-table')).toContainText('reveal');
  await expect(page.locator('.activity-table')).toContainText('server-token');
});

test('a reader of a restricted dataset cannot read its activity log', async ({ page }) => {
  await page.goto('/signin');
  await page.getByRole('link', { name: 'Sign in with GitLab' }).click();
  await expect(page.getByRole('heading', { name: 'Datasets' })).toBeVisible();
  await page.goto('/d/e2e/datasets/faces?view=activity');
  await expect(page.getByRole('alert')).toContainText("for the dataset's owners");
});

test('a GitLab callback with a forged state is refused, in words', async ({ page }) => {
  await page.goto('/auth/gitlab/callback?code=anything&state=forged-state-value-x');
  await expect(page).toHaveURL(/\/signin\?error=/);
  await expect(page.getByRole('alert')).toContainText('Run the sign-in again');
});

test("the drawer tells an item's history: what changed, by whom, in which release", async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/boxes?view=browse&item=frames/street.png');
  const history = page.getByRole('region', { name: 'History' });
  const moved = history.getByRole('listitem').filter({ hasText: 'box person moved' });
  await expect(moved).toContainText('by user:reviewer');
  await expect(moved).toContainText('x 20 → 45');
  await expect(moved).toContainText('in v1.1.0');
  await expect(history.getByRole('listitem').filter({ hasText: 'file added' })).toContainText('in v1.0.0');
  // Newest first: the move heads the list.
  await expect(history.getByRole('listitem').first()).toContainText('box person moved');
});

test('a COCO RLE mask is drawn exactly: 1,200 pixels where the mask says', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/masks?view=browse&item=frames/masked.png');
  const mask = page.locator('.drawer .overlay image.overlay-mask');
  await expect(mask).toHaveCount(1);
  // Decode correctness, not just presence: count the painted pixels and
  // check one inside and one outside the 40×30 rectangle at (40, 30).
  const probe = await mask.evaluate(async (el) => {
    const href = el.getAttribute('href')!;
    const img = new Image();
    img.src = href;
    await img.decode();
    const c = document.createElement('canvas');
    c.width = img.width;
    c.height = img.height;
    const ctx = c.getContext('2d')!;
    ctx.drawImage(img, 0, 0);
    const d = ctx.getImageData(0, 0, c.width, c.height).data;
    let set = 0;
    for (let i = 3; i < d.length; i += 4) if (d[i] > 0) set += 1;
    const at = (x: number, y: number) => d[(y * c.width + x) * 4 + 3];
    return { w: c.width, h: c.height, set, inside: at(50, 40), outside: at(10, 10) };
  });
  expect(probe).toEqual({ w: 200, h: 150, set: 1200, inside: 140, outside: 0 });
});

test('a table file is shown as a table: columns, ranges, nulls and its first rows', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/tables?view=browse&release=v1.0.0&item=people.csv');
  const table = page.getByRole('region', { name: 'Table' });
  await expect(table.getByText('5 rows · 4 columns')).toBeVisible();
  const score = table.locator('.table-columns tr', { hasText: 'score' });
  await expect(score).toContainText('DOUBLE');
  await expect(score).toContainText('64.0 … 91.5');
  await expect(score).toContainText('20%');
  await expect(table.locator('.table-sample')).toContainText('Ana Wijaya');
  // Parquet and JSONL read the same way.
  await page.goto('/d/e2e/datasets/tables?view=browse&item=people.parquet');
  await expect(page.getByRole('region', { name: 'Table' }).getByText('5 rows · 4 columns')).toBeVisible();
  await page.goto('/d/e2e/datasets/tables?view=browse&item=events.jsonl');
  await expect(page.getByRole('region', { name: 'Table' }).getByText('3 rows · 4 columns')).toBeVisible();
});

test('compare shows a modified table by its rows: counts, then the rows themselves', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/tables?view=releases&a=v1.0.0&b=v1.1.0');
  const change = page.locator('.change', { hasText: 'people.csv' });
  await expect(change).toContainText('modified');
  await expect(change.locator('.row-changes')).toContainText('2 rows added, 2 removed');
  await expect(change.locator('.row-changes')).toContainText('5 → 5 rows');
  await change.getByText('Show the changed rows').click();
  await expect(change.locator('table', { hasText: 'Removed' })).toContainText('Budi');
  await expect(change.locator('table', { hasText: 'Added' })).toContainText('Fajar');
});

test('browse pages through a version: one page, then more on scroll, and links past the first page', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/many?view=browse&mode=table');
  await expect(page.getByText('130 items')).toBeVisible();
  // The table is virtual: it declares every loaded row (and the header)
  // but holds only those near the screen.
  const table = page.locator('.browse-table');
  await expect(table).toHaveAttribute('aria-rowcount', '121');
  const held = await page.locator('.browse-table tbody tr:not(.spacer)').count();
  expect(held).toBeLessThan(120);
  const more = page.getByRole('button', { name: /Show more \(120 of 130 shown\)/ });
  await more.scrollIntoViewIfNeeded();
  await expect(table).toHaveAttribute('aria-rowcount', '131');
  await expect(page.getByRole('button', { name: /Show more/ })).toHaveCount(0);
  // The end is reachable: scrolled down, the last row is on screen.
  await page.mouse.wheel(0, 100_000);
  await expect(page.getByRole('cell', { name: 'rows/0130.txt' })).toBeVisible();
  // Filters run on the server and page the same way.
  await page.goto('/d/e2e/datasets/many?view=browse&mode=table&q=012');
  await expect(page.getByText('11 of 130 items')).toBeVisible();
  // A shared link opens an item no loaded page holds.
  await page.goto('/d/e2e/datasets/many?view=browse&item=rows/0130.txt');
  await expect(page.getByRole('complementary', { name: 'rows/0130.txt' })).toBeVisible();
});

test('media opens as media: a sound plays with its waveform, a note reads as text', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/media?view=browse&item=tone.wav');
  const drawer = page.getByRole('complementary', { name: 'tone.wav' });
  await expect(drawer.getByRole('img', { name: 'tone.wav waveform' })).toBeVisible();
  await expect(drawer.locator('audio')).toHaveAttribute('src', /http/);
  // The gallery tile shows the waveform too.
  await expect(page.locator('.tile img[alt="tone.wav"]')).toBeVisible();
  await page.goto('/d/e2e/datasets/media?view=browse&item=notes.txt');
  const note = page.getByRole('complementary', { name: 'notes.txt' });
  await expect(note.getByRole('region', { name: 'Text' })).toContainText('UTF-8 is fine');
});

test('accessibility: no serious or critical axe findings', async ({ page }) => {
  await signIn(page);
  for (const path of ['/', '/d/e2e/datasets/demo', '/d/e2e/datasets/demo?view=browse', '/d/e2e/datasets/boxes?view=browse', '/d/e2e/datasets/demo?view=browse&type=.txt&mode=table', '/d/e2e/datasets/boxes?view=releases&a=v1.0.0&b=v1.1.0', '/d/e2e/datasets/boxes', '/?type=.txt', '/d/e2e/datasets/faces?view=browse&item=person-01.png', '/d/e2e/datasets/tables?view=browse&release=v1.0.0&item=people.csv', '/d/e2e/datasets/tables?view=releases&a=v1.0.0&b=v1.1.0', '/d/e2e/datasets/media?view=browse&item=tone.wav', '/d/e2e/datasets/media?view=browse&item=notes.txt']) {
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
