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
  // The header says where git stands: v1.1.0 is made but not written there yet.
  await expect(page.locator('.dataset-meta')).toContainText('v1.1.0 not there yet');
  // The tape: both releases as engraved tags, newest pinned by default.
  await expect(page.getByRole('button', { name: 'v1.1.0' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'v1.0.0' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'v1.1.0' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  // The engraved count line and the command.
  const card = page.getByRole('region', { name: 'Dataset card' });
  await expect(card.getByText(/4 items ·/)).toBeVisible();
  // What kind of data it is, counted: never assumed to be images.
  const types = card.getByRole('table', { name: 'Items by type' });
  await expect(types.getByRole('row', { name: /\.png items 2/ })).toBeVisible();
  await expect(types.getByRole('row', { name: /\.txt items 2 33 B/ })).toBeVisible();
  await expect(page.getByText(/cid clone cid@.*e2e\/datasets\/demo --release v1\.1\.0/)).toBeVisible();
  // Picking the older release repins and lands in the URL (every view is a link).
  await page.getByRole('button', { name: 'v1.0.0' }).click();
  await expect(page).toHaveURL(/release=v1\.0\.0/);
  await expect(page.getByText(/--release v1\.0\.0/)).toBeVisible();
  // The card and the header count the pinned release, not main's head.
  await expect(page.getByRole('region', { name: 'Dataset card' }).getByText(/3 items ·/)).toBeVisible();
  await expect(page.locator('.dataset-meta').getByText(/3 items,/)).toBeVisible();
  await expect(types.getByRole('row', { name: /\.txt items 1 16 B/ })).toBeVisible();
  // A type is a way into Browse, filtered, at the same release.
  await types.getByRole('link', { name: 'Browse the .txt items' }).click();
  await expect(page).toHaveURL(/view=browse/);
  await expect(page).toHaveURL(/release=v1\.0\.0/);
  await expect(page.getByLabel('Filter by type')).toHaveValue('.txt');
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
  await expect(page.getByText('blake3')).toBeVisible();
  await expect(page.getByRole('link', { name: 'Download the file' })).toBeVisible();
  // Dimensions arrived through sniffing, not from any client claim.
  await expect(page.getByText('200×150')).toBeVisible();
});

test('a preview missing from storage shows the item as itself, never a broken image', async ({ page }) => {
  await signIn(page);
  // The store answers every thumbnail with a 404, as for a purged or lost
  // preview: each one is a "no preview" tile with its type (principle 1).
  await page.route('**/previews/**', (route) => route.fulfill({ status: 404, body: 'gone' }));
  await page.goto('/d/e2e/datasets/demo?view=browse');
  await expect(page.locator('.tile .thumb-missing')).toHaveCount(2);
  await expect(page.locator('.tile .thumb-missing').first()).toContainText('.png');
  await expect(page.locator('.tile .thumb-missing').first()).toContainText('no preview');
  await expect(page.getByRole('img', { name: 'img-a.png: no preview' })).toBeVisible();
  const broken = await page.evaluate(() => [...document.images].filter((i) => i.complete && i.naturalWidth === 0).length);
  expect(broken).toBe(0);
  // The home page's mosaics too.
  await page.goto('/');
  await expect(page.getByRole('link', { name: 'e2e/datasets/demo' }).first()).toBeVisible();
  await page.waitForLoadState('networkidle');
  expect(await page.evaluate(() => [...document.images].filter((i) => i.complete && i.naturalWidth === 0).length)).toBe(0);
});

test('compare between the two releases reads as a sentence', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/demo?view=releases');
  await expect(page.getByText('1 added, 0 modified, 0 deleted')).toBeVisible();
  await expect(page.locator('.change-verb--added')).toHaveText('added');
  await expect(page.getByText('notes.txt')).toBeVisible();
});

test('the history says what each release holds and changed, and links to the comparison', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/demo?view=releases&a=v1.1.0&b=v1.0.0');
  const history = page.getByRole('region', { name: 'History' });
  await expect(history.locator('.moment--release').filter({ hasText: 'first frames' })).toContainText(
    '3 items · the first release',
  );
  const newest = history.locator('.moment--release').filter({ hasText: 'notes' });
  await expect(newest).toContainText('4 items');
  await newest.getByRole('link', { name: 'since v1.0.0: 1 file added, 0 modified, 0 deleted' }).click();
  await expect(page).toHaveURL(/a=v1\.0\.0&b=v1\.1\.0/);
  // An annotated dataset counts its annotations too.
  await page.goto('/d/e2e/datasets/boxes?view=releases');
  await expect(page.getByRole('region', { name: 'History' }).getByRole('link', { name: /since v1\.0\.0: .* annotations? added/ })).toBeVisible();
});

test('the history marks a release the dataset repository does not have yet', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/demo?view=releases');
  const history = page.getByRole('region', { name: 'History' });
  const waiting = history.locator('.moment').filter({ hasText: 'v1.1.0' });
  await expect(waiting.getByText('not in git yet')).toBeVisible();
  // By its tag: the newer release's line names v1.0.0 too ("since v1.0.0").
  const written = history.locator('.moment').filter({ has: page.locator('.release-tag', { hasText: 'v1.0.0' }) });
  await expect(written).toHaveCount(1);
  await expect(written.getByText('not in git yet')).toHaveCount(0);
});

test('a release written to a GitLab or GitHub repository links to its tag there', async ({ page }) => {
  await signIn(page);
  // The fixtures' repositories are on no real host; answer as if on GitLab, then GitHub.
  let gitUrl = 'git@gitlab.com:your-org/datasets/demo.git';
  await page.route('**/v0/datasets/e2e/datasets/demo/-/overview*', async (route) => {
    const res = await route.fetch();
    await route.fulfill({ response: res, json: { ...(await res.json()), git_url: gitUrl } });
  });
  await page.goto('/d/e2e/datasets/demo?view=releases');
  const history = page.getByRole('region', { name: 'History' });
  // v1.0.0 is in git: linked. v1.1.0 is not there yet: no link to a missing tag.
  await expect(history.getByRole('link', { name: 'v1.0.0 in the git repository' })).toHaveAttribute(
    'href',
    'https://gitlab.com/your-org/datasets/demo/-/tags/v1.0.0',
  );
  await expect(history.getByRole('link', { name: 'v1.1.0 in the git repository' })).toHaveCount(0);
  gitUrl = 'https://ci:secret@github.com/your-org/demo.git';
  await page.reload();
  await expect(history.getByRole('link', { name: 'v1.0.0 in the git repository' })).toHaveAttribute(
    'href',
    'https://github.com/your-org/demo/tree/v1.0.0',
  );
  // A host whose URL form is unknown gets no link, rather than a guess.
  gitUrl = 'git@git.example.org:your-org/demo.git';
  await page.reload();
  await expect(history.locator('.release-tag', { hasText: 'v1.0.0' })).toBeVisible();
  await expect(history.getByRole('link', { name: /in the git repository/ })).toHaveCount(0);
});

test('a release touched by a purge says it is intact except its purged items', async ({ page }) => {
  await signIn(page);
  // A purge is irreversible, so the shared fixtures never get one: the
  // answer is given as if v1.0.0 had lost one item (the server's count is
  // checked by the integration suite).
  await page.route('**/v0/datasets/e2e/datasets/demo/-/overview*', async (route) => {
    const res = await route.fetch();
    await route.fulfill({ response: res, json: { ...(await res.json()), purged: [{ release: 'v1.0.0', items: 1 }] } });
  });
  await page.goto('/d/e2e/datasets/demo?view=releases');
  const history = page.getByRole('region', { name: 'History' });
  const older = history.locator('.moment--release').filter({ has: page.locator('.release-tag', { hasText: 'v1.0.0' }) });
  await expect(older).toContainText('intact except 1 purged item');
  const newer = history.locator('.moment--release').filter({ has: page.locator('.release-tag', { hasText: 'v1.1.0' }) });
  await expect(newer).not.toContainText('purged');
});

test('a model is named a model: on its card, in its header, and in the home filter', async ({ page }) => {
  await signIn(page);
  await page.goto('/?kind=model');
  await expect(page.getByLabel('Filter by kind')).toHaveValue('model');
  await expect(page.getByRole('link', { name: 'e2e/models/tiny-bert' }).first()).toBeVisible();
  await expect(page.getByRole('link', { name: 'e2e/datasets/demo' })).toHaveCount(0);
  await page.goto('/d/e2e/models/tiny-bert');
  await expect(page.locator('.dataset-meta')).toContainText('Model');
  await expect(page.getByRole('region', { name: 'Use this model' })).toContainText('cid clone');
  await expect(page.getByRole('region', { name: 'Model card' })).toContainText('1 item');
});

test('"Use this" shows the same version through Hugging Face libraries', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/demo?release=v1.0.0');
  const ds = page.getByRole('region', { name: 'With Hugging Face libraries' });
  await expect(ds).toContainText('HF_ENDPOINT=http://127.0.0.1:7177');
  await expect(ds).toContainText('load_dataset("e2e/datasets__demo", revision="v1.0.0")');
  await page.goto('/d/e2e/models/tiny-bert');
  const model = page.getByRole('region', { name: 'With Hugging Face libraries' });
  await expect(model).toContainText('AutoModel.from_pretrained("e2e/models__tiny-bert", revision="v1.1.0")');
});

test('lineage: a model release names what it was trained on, and the dataset names the model', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/models/tiny-bert?release=v1.1.0');
  const trainedOn = page.getByRole('region', { name: 'Trained on' });
  await expect(trainedOn).toContainText('e2e/datasets/demo');
  await expect(trainedOn).toContainText('v1.0.0');
  // The first release named none.
  await page.goto('/d/e2e/models/tiny-bert?release=v1.0.0');
  await expect(page.getByRole('region', { name: 'Trained on' })).toHaveCount(0);
  // From the dataset's side, at that release, and back.
  await page.goto('/d/e2e/models/tiny-bert?release=v1.1.0');
  await page.getByRole('region', { name: 'Trained on' }).getByRole('link', { name: 'e2e/datasets/demo' }).click();
  await expect(page).toHaveURL(/\/d\/e2e\/datasets\/demo\?release=v1\.0\.0/);
  const models = page.getByRole('region', { name: 'Models trained on this release' });
  await expect(models).toContainText('e2e/models/tiny-bert');
  await expect(models).toContainText('v1.1.0');
  await page.goto('/d/e2e/datasets/demo?release=v1.1.0');
  await expect(page.getByRole('region', { name: 'Models trained on this release' })).toHaveCount(0);
});

test('a commit can be pinned: from the history or the tape, and every view and command follows it', async ({ page }) => {
  await signIn(page);
  // The newest commit is not a release: the page shows the release until asked.
  await page.goto('/d/e2e/datasets/many');
  await expect(page.locator('.dataset-meta')).toContainText('130 items');
  await page.goto('/d/e2e/datasets/many?view=releases');
  const unreleased = page.getByRole('region', { name: 'History' }).locator('.moment').filter({ hasText: 'one more row' });
  await unreleased.getByRole('link', { name: /View this version/ }).click();
  await expect(page).toHaveURL(/commit=[0-9a-f-]{36}/);
  const commit = new URL(page.url()).searchParams.get('commit')!;
  await expect(page.locator('.dataset-meta')).toContainText('131 items');
  // Its tick is the needle; no release is pressed.
  await expect(page.getByRole('button', { name: /^Commit .*one more row/ })).toHaveAttribute('aria-pressed', 'true');
  await expect(page.getByRole('button', { name: 'v1.0.0' })).toHaveAttribute('aria-pressed', 'false');
  // The commands reach the same version.
  const use = page.getByRole('region', { name: 'Use this dataset' });
  await expect(use).toContainText(`&& cd many && cid checkout ${commit}`);
  await expect(page.getByRole('region', { name: 'With Hugging Face libraries' })).toContainText(
    `revision="${commit.replaceAll('-', '')}00000000"`,
  );
  // Another tab keeps it pinned.
  await page.getByRole('link', { name: 'Browse', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`commit=${commit}`));
  await expect(page.getByText('131 items')).toBeVisible();
  // A release's tag pins the release again, and the commit lets go.
  await page.getByRole('button', { name: 'v1.0.0' }).click();
  await expect(page).not.toHaveURL(/commit=/);
  await expect(page.getByText('130 items')).toBeVisible();
});

test('a branch can be viewed: its own tape, its head, and commands that check it out', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/many');
  await page.getByLabel('Branch').selectOption('fix');
  await expect(page).toHaveURL(/branch=fix/);
  // Its head: main's 131 rows and the fix.
  await expect(page.locator('.dataset-meta')).toContainText('132 items');
  await expect(page.locator('.tape')).toContainText('on fix');
  await expect(page.getByRole('region', { name: 'Use this dataset' })).toContainText('&& cd many && cid checkout fix');
  await expect(page.getByRole('region', { name: 'With Hugging Face libraries' })).toContainText('revision="fix"');
  // It stays on the branch from tab to tab, and main is one pick away.
  await page.getByRole('link', { name: 'Files', exact: true }).click();
  await expect(page).toHaveURL(/branch=fix/);
  await page.getByLabel('Branch').selectOption('main');
  await expect(page).not.toHaveURL(/branch=/);
  await expect(page.locator('.dataset-meta')).toContainText('130 items');
});

test('the files tab walks the committed tree', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/demo?view=files');
  await expect(page.getByText('README.txt')).toBeVisible();
  // Each file says its type, and its name opens it in Browse at the same release.
  const picture = page.getByRole('row', { name: /img-a\.png/ });
  await expect(picture.getByRole('cell', { name: '.png', exact: true })).toBeVisible();
  // And when it last changed, and by whom (the CLI's author, user:$USER).
  await expect(picture.getByRole('cell', { name: /^\d{4}-\d{2}-\d{2} · user:/ })).toBeVisible();
  await picture.getByRole('link', { name: 'img-a.png' }).click();
  await expect(page).toHaveURL(/view=browse/);
  await expect(page).toHaveURL(/item=img-a\.png/);
  await expect(page.getByText('200×150')).toBeVisible();
});

test('the overview opens with a look inside: real items, their annotations, each a way into Browse', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/boxes');
  const strip = page.getByRole('region', { name: 'A look inside' });
  const tile = strip.getByRole('link', { name: /frames\/street\.png/ });
  await expect(tile.locator('img')).toBeVisible();
  // Annotations drawn as in Browse.
  await expect(tile.locator('svg rect, svg polygon').first()).toBeVisible();
  await tile.click();
  await expect(page).toHaveURL(/view=browse/);
  await expect(page.getByRole('complementary', { name: 'frames/street.png' })).toBeVisible();

  // Text and sound show as themselves, never a blank square.
  await page.goto('/d/e2e/datasets/media');
  const media = page.getByRole('region', { name: 'A look inside' });
  await expect(media.getByRole('link', { name: /notes\.txt/ }).getByText('.txt', { exact: true })).toBeVisible();
  await expect(media.getByRole('link', { name: /tone\.wav/ }).locator('img')).toBeVisible();
  // No release yet: the facts, not an empty tape.
  await expect(page.getByText('2 commits, no releases yet.')).toBeVisible();

  // Spread over the version, not its first eight files, and the same eight on every visit.
  const sample = async () => {
    await page.goto('/d/e2e/datasets/many');
    const links = page.getByRole('region', { name: 'A look inside' }).getByRole('link', { name: /rows\// });
    await expect(links).toHaveCount(8);
    return (await links.allTextContents()).map((t) => t.match(/rows\/\d+\.txt/)![0]);
  };
  const once = await sample();
  expect(once).not.toEqual(Array.from({ length: 8 }, (_, i) => `rows/${String(i + 1).padStart(4, '0')}.txt`));
  expect(await sample()).toEqual(once);
});

test('lost in the clouds: an unknown address or dataset says so and offers the way back', async ({ page }) => {
  await signIn(page);
  await page.goto('/no/such/page');
  await expect(page.getByRole('heading', { name: 'Lost in the clouds' })).toBeVisible();
  await expect(page.getByText('There is no page at this address.')).toBeVisible();

  await page.goto('/d/e2e/datasets/nope');
  await expect(page.getByRole('heading', { name: 'Lost in the clouds' })).toBeVisible();
  await expect(page.getByText(/No dataset is named e2e\/datasets\/nope/)).toBeVisible();
  // The search on the page leads home, already searching.
  await page.getByRole('main').getByLabel('Search datasets').fill('boxes');
  await page.getByRole('main').getByRole('button', { name: 'Search' }).click();
  await expect(page).toHaveURL(/\/\?q=boxes/);
  await expect(page.getByRole('link', { name: 'e2e/datasets/boxes', exact: true })).toBeVisible();
});

test('keyboard: the tape is reachable and Enter pins', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/demo');
  await page.getByRole('button', { name: 'v1.0.0' }).focus();
  await page.keyboard.press('Enter');
  await expect(page).toHaveURL(/release=v1\.0\.0/);
});

test('an annotated dataset names the labelling policy its annotations follow; a file dataset does not', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/boxes');
  const card = page.getByRole('region', { name: 'Dataset card' });
  await expect(card.getByText('Annotations made under labelling policy p1.')).toBeVisible();
  await page.goto('/d/e2e/datasets/demo');
  await expect(page.getByRole('region', { name: 'Dataset card' }).getByText(/labelling policy/)).toHaveCount(0);
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
  await expect(page.getByText('0 added, 0 modified, 0 deleted')).toBeVisible();
  await expect(page.getByText('0 added, 1 changed, 0 removed')).toBeVisible();
  // Per class: the person box moved; the vehicle is not listed, it did not change.
  const byClass = page.getByRole('table', { name: 'Annotation changes by class' });
  await expect(byClass.getByRole('row', { name: 'person 0 1 0' })).toBeVisible();
  await expect(byClass.getByRole('row', { name: /vehicle/ })).toHaveCount(0);

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
  await expect(panel.locator('pre').first()).toContainText('boxes/dataset.yaml');

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

test('"Show command" gives the cid command for the view on screen, and it does the same thing when run', async ({ page }) => {
  await signIn(page);
  const here = dirname(fileURLToPath(import.meta.url));
  const cidBin = resolve(here, '../../zig-out/bin/cid');
  const runShown = (command: string) => {
    const dir = mkdtempSync(resolve(tmpdir(), 'cid-shown-'));
    const out = execSync(command.replace(/(^|&& )cid /g, `$1${cidBin} `), {
      cwd: dir,
      env: { ...process.env, CID_SERVER: 'http://127.0.0.1:7177', CID_TOKEN: token },
      stdio: 'pipe',
      shell: '/bin/sh',
    }).toString();
    return { dir, out };
  };
  const shown = async () => (await page.getByRole('region', { name: 'Command' }).locator('code.command').textContent())!.trim();

  // Browse, filtered: the clone of that subset.
  await page.goto('/d/e2e/datasets/boxes?view=browse&split=train&class=person');
  await page.getByRole('button', { name: 'Show command' }).click();
  const subset = await shown();
  expect(subset).toBe('cid clone cid@127.0.0.1:e2e/datasets/boxes --release v1.1.0 --split train --class person');
  const cloned = runShown(subset);
  expect(readFileSync(resolve(cloned.dir, 'boxes/.cid/config.zon'), 'utf8')).toContain('"train"');

  // The toggle stays on from tab to tab; a compare is a diff in the folder.
  await page.getByRole('link', { name: 'Releases', exact: true }).click();
  const diff = await shown();
  expect(diff).toBe('cid clone cid@127.0.0.1:e2e/datasets/boxes --release v1.1.0 && cd boxes && cid diff v1.0.0 v1.1.0');
  expect(runShown(diff).out).toContain('person');

  // A commit that is no release: the clone, then its checkout.
  await page.goto('/d/e2e/datasets/many?view=releases');
  await page.getByRole('region', { name: 'History' }).locator('.moment').filter({ hasText: 'one more row' }).getByRole('link', { name: /View this version/ }).click();
  await page.getByRole('button', { name: 'Show command' }).click();
  const atCommit = await shown();
  expect(atCommit).toMatch(/^cid clone cid@127\.0\.0\.1:e2e\/datasets\/many && cd many && cid checkout [0-9a-f-]{36}$/);
  expect(readFileSync(resolve(runShown(atCommit).dir, 'many/rows/0131.txt'), 'utf8')).toBe('row 131\n');

  // What has no command says so.
  await page.goto('/d/e2e/datasets/demo?view=browse&q=img');
  await page.getByRole('button', { name: 'Show command' }).click();
  await expect(page.getByRole('region', { name: 'Command' })).toContainText('The path search and the type filter have no clone flag');
  await page.getByRole('link', { name: 'Activity', exact: true }).click();
  await expect(page.getByRole('region', { name: 'Command' })).toContainText('no command shows it');
});

test('home: a card per dataset, the same as rows in List, and search reaches classes and types', async ({ page }) => {
  await signIn(page);
  const demo = page.locator('.ds-card', { has: page.getByRole('link', { name: 'e2e/datasets/demo', exact: true }) });
  // The mosaic is the dataset's own finished previews; the facts line
  // agrees with the dataset card.
  await expect(demo.locator('.mosaic img')).toHaveCount(2);
  await expect(demo.getByText(/4 items · 5\.8 KB · /)).toBeVisible();

  // List: the same facts as compact rows, and the layout is a link.
  await page.getByRole('radio', { name: 'list' }).click();
  await expect(page).toHaveURL(/layout=list/);
  const row = page.locator('.manifest-row', { has: page.getByRole('link', { name: 'e2e/datasets/demo', exact: true }) });
  await expect(row.locator('.mosaic img')).toHaveCount(2);
  await expect(row.getByText(/4 items · 5\.8 KB · /)).toBeVisible();
  await page.getByRole('radio', { name: 'cards' }).click();
  await expect(page).not.toHaveURL(/layout=/);

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
  await expect(page.locator('.account-name')).toHaveText('Rhea Reviewer');

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
  await page.locator('.account-name').click();
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
  const row = page.locator('.ds-card', { has: page.getByRole('link', { name: 'e2e/datasets/boxes', exact: true }) });
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

  // The dataset's header names its owners too.
  await page.goto('/d/e2e/datasets/boxes');
  await expect(page.locator('.dataset-meta').getByText('owned by Olu Owner')).toBeVisible();
});

test('the server token cannot star: a star belongs to a person', async ({ page }) => {
  await signIn(page);
  await expect(page.getByRole('heading', { name: 'Datasets' })).toBeVisible();
  await expect(page.locator('.star')).toHaveCount(0);
});

test('restricted: blurred until a logged reveal, and the log is for owners', async ({ page }) => {
  await signIn(page); // the server token: an owner of everything
  // The home's card shows the blur, never the clear thumbnail.
  const card = page.locator('.ds-card', { has: page.getByRole('link', { name: 'e2e/datasets/faces', exact: true }) });
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
  // Narrowed to one action, in the URL: only reveals remain.
  await page.getByLabel('Filter by what').selectOption('reveal');
  await expect(page).toHaveURL(/what=reveal/);
  const chips = page.locator('.activity-table tbody .chip');
  await expect(chips.first()).toHaveText('reveal');
  expect(new Set(await chips.allTextContents())).toEqual(new Set(['reveal']));
  await page.getByRole('button', { name: 'Clear' }).click();
  await expect(page).not.toHaveURL(/what=/);
});

test('a reader of a restricted dataset cannot read its activity log', async ({ page }) => {
  await page.goto('/signin');
  await page.getByRole('link', { name: 'Sign in with GitLab' }).click();
  await expect(page.getByRole('heading', { name: 'Datasets' })).toBeVisible();
  await page.goto('/d/e2e/datasets/faces?view=activity');
  await expect(page.getByRole('alert')).toContainText("for the dataset's owners");
});

test('a signed-in person adds an SSH key, sees a bad one refused, and removes theirs', async ({ page }) => {
  // A fresh key each run: one key belongs to one account, forever.
  const dir = mkdtempSync(resolve(tmpdir(), 'cid-e2e-key-'));
  execSync(`ssh-keygen -q -t ed25519 -N '' -C e2e@cid -f ${dir}/id`);
  const publicKey = readFileSync(`${dir}/id.pub`, 'utf8');
  const fingerprint = execSync(`ssh-keygen -lf ${dir}/id.pub`).toString().split(' ')[1];

  await page.goto('/signin');
  await page.getByRole('link', { name: 'Sign in with GitLab' }).click();
  await expect(page.getByRole('heading', { name: 'Datasets' })).toBeVisible();
  await page.locator('.account-name').click();
  await page.getByRole('link', { name: 'SSH keys' }).click();
  await expect(page.getByRole('heading', { name: 'SSH keys' })).toBeVisible();

  // Not a key: refused, saying what to paste instead.
  await page.getByLabel('Public key').fill('hello');
  await page.getByRole('button', { name: 'Add key' }).click();
  await expect(page.getByRole('alert')).toContainText('not an OpenSSH public key');
  await expect(page.getByRole('alert')).toContainText('.pub');

  await page.getByLabel('Title').fill('e2e laptop');
  await page.getByLabel('Public key').fill(publicKey);
  await page.getByRole('button', { name: 'Add key' }).click();
  const list = page.getByRole('list', { name: 'Your keys' });
  await expect(list.getByText('e2e laptop')).toBeVisible();
  await expect(list.getByRole('button', { name: new RegExp(`^${fingerprint.slice(0, 19).replace(/[+/]/g, '.')}`) })).toBeVisible();
  // Kept on the server: a reload still lists it.
  await page.reload();
  await expect(page.getByRole('list', { name: 'Your keys' }).getByText('e2e laptop')).toBeVisible();
  // The page as a person sees it, a key listed and the form open, is accessible too.
  const found = (await new AxeBuilder({ page }).analyze()).violations.filter(
    (v) => v.impact === 'serious' || v.impact === 'critical',
  );
  expect(found.map((v) => v.id)).toEqual([]);

  await page.getByRole('button', { name: 'Remove key e2e laptop' }).click();
  await expect(page.getByRole('list', { name: 'Your keys' }).getByText('e2e laptop')).toHaveCount(0);
});

test('the server token has no keys, and the keys page says how to get yours', async ({ page }) => {
  await signIn(page);
  await page.goto('/keys');
  await expect(page.getByRole('status')).toContainText('server token');
  await expect(page.getByRole('button', { name: 'Add key' })).toHaveCount(0);
});

test('a personal token: made once, works as git-style credentials, and stops when revoked', async ({ page }) => {
  await page.goto('/signin');
  await page.getByRole('link', { name: 'Sign in with GitLab' }).click();
  await expect(page.getByRole('heading', { name: 'Datasets' })).toBeVisible();
  await page.locator('.account-name').click();
  await page.getByRole('link', { name: 'Tokens' }).click();
  await expect(page.getByRole('heading', { name: 'Tokens' })).toBeVisible();

  const job = `e2e job ${Date.now()}`;
  await page.getByLabel('Name').fill(job);
  await page.getByLabel('Expires after').selectOption('30');
  await page.getByRole('button', { name: 'Make token' }).click();
  const fresh = page.getByRole('status');
  await expect(fresh).toContainText(`${job} is ready`);
  const tokenText = (await fresh.locator('code').first().textContent()) ?? '';
  expect(tokenText).toMatch(/^cidp_/);
  await expect(fresh.locator('code').nth(1)).toContainText(`you:${tokenText}@`);

  // As Rhea, through Basic credentials, the way git sends them: what she
  // may read, and nothing she may not.
  const basic = `Basic ${Buffer.from(`rhea:${tokenText}`).toString('base64')}`;
  const ok = await page.request.get('/v0/datasets/e2e/datasets/boxes/-/info', { headers: { authorization: basic } });
  expect(ok.status()).toBe(200);
  const no = await page.request.get('/v0/datasets/e2e/datasets/demo/-/info', { headers: { authorization: basic } });
  expect([401, 403]).toContain(no.status());

  // Shown once: a reload lists it by name, used, and without the token.
  await page.reload();
  const list = page.getByRole('list', { name: 'Your tokens' });
  const row = list.getByRole('listitem').filter({ hasText: job });
  await expect(row).toContainText('used ');
  await expect(row).toContainText('expires ');
  await expect(page.getByText(tokenText)).toHaveCount(0);
  const found = (await new AxeBuilder({ page }).analyze()).violations.filter(
    (v) => v.impact === 'serious' || v.impact === 'critical',
  );
  expect(found.map((v) => v.id)).toEqual([]);

  await page.getByRole('button', { name: `Revoke token ${job}` }).click();
  await expect(list.getByText(job)).toHaveCount(0);
  const after = await page.request.get('/v0/datasets/e2e/datasets/boxes/-/info', { headers: { authorization: basic } });
  expect(after.status()).toBe(401);
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

test('the keyboard moves through items, searches, and lists its shortcuts', async ({ page }) => {
  const at = (n: string) => new RegExp(`item=rows(%2F|/)${n}\\.txt`);
  await signIn(page);
  await page.goto('/d/e2e/datasets/many?view=browse');
  await expect(page.getByRole('button', { name: /rows\/0001\.txt/ })).toBeVisible();
  // Arrows scroll the page while nothing is open; they never open an item.
  await page.keyboard.press('ArrowDown');
  await expect(page).not.toHaveURL(/item=/);
  // j opens the first item, then moves on; k and the arrows too, once one is open.
  await page.keyboard.press('j');
  await expect(page).toHaveURL(at('0001'));
  await expect(page.getByRole('complementary', { name: 'rows/0001.txt' })).toBeVisible();
  await page.keyboard.press('j');
  await expect(page).toHaveURL(at('0002'));
  await page.keyboard.press('k');
  await expect(page).toHaveURL(at('0001'));
  await page.keyboard.press('ArrowRight');
  await expect(page).toHaveURL(at('0002'));
  await page.keyboard.press('ArrowLeft');
  await expect(page).toHaveURL(at('0001'));
  await page.keyboard.press('Escape');
  await expect(page).not.toHaveURL(/item=/);

  // `/` puts the cursor in the path search, and typing there types.
  await page.keyboard.press('/');
  await expect(page.getByLabel('Filter by path')).toBeFocused();
  await page.keyboard.type('j');
  await expect(page.getByLabel('Filter by path')).toHaveValue('j');
  await expect(page).not.toHaveURL(/item=/);
  await page.getByLabel('Filter by path').fill('');
  await page.locator('body').click({ position: { x: 1, y: 1 } });

  // `?` lists the shortcuts; Escape puts the list away.
  await page.keyboard.press('?');
  const list = page.getByRole('region', { name: 'Keyboard shortcuts' });
  await expect(list).toContainText('next item');
  const axe = await new AxeBuilder({ page }).include('.shortcuts').analyze();
  expect(axe.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical')).toEqual([]);
  await page.keyboard.press('Escape');
  await expect(list).toHaveCount(0);

  // The table: the open item stays in view, and the keys go on past the first page.
  await page.goto('/d/e2e/datasets/many?view=browse&mode=table&item=rows/0060.txt');
  await expect(page.getByRole('row', { name: /rows\/0060\.txt/ })).toBeInViewport();
  for (let i = 0; i < 5; i++) await page.keyboard.press('j');
  await expect(page).toHaveURL(at('0065'));
  await expect(page.getByRole('row', { name: /rows\/0065\.txt/ })).toBeInViewport();
  await page.goto('/d/e2e/datasets/many?view=browse&mode=table&item=rows/0120.txt');
  await expect(page.getByRole('row', { name: /rows\/0120\.txt/ })).toBeVisible();
  await page.keyboard.press('j');
  await expect(page.getByRole('button', { name: /Show more/ })).toHaveCount(0);
  if (at('0120').test(page.url())) await page.keyboard.press('j');
  await expect(page).toHaveURL(at('0121'));
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

// Invariant 18: one bad file never breaks a view.
test('a malformed CSV shows its own error, in words, and the rest of the dataset stays browsable', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/media?view=browse');
  // Its neighbours are all there, as themselves.
  await expect(page.locator('.tile img[alt="tone.wav"]')).toBeVisible();
  await expect(page.getByRole('button', { name: /notes\.txt/ })).toBeVisible();
  // The bad file opens too, and says what is wrong with it; it can still be downloaded.
  await page.getByRole('button', { name: /broken\.csv/ }).click();
  const drawer = page.getByRole('complementary', { name: 'broken.csv' });
  await expect(drawer.getByText(/No table view: /)).toBeVisible();
  await expect(drawer.getByRole('link', { name: 'Download the file' })).toBeVisible();
  await expect(page.getByRole('alert')).toHaveCount(0);
  // And the other views of the same version.
  await page.goto('/d/e2e/datasets/media?view=files');
  await expect(page.getByRole('row', { name: /broken\.csv/ }).getByRole('cell', { name: '.csv', exact: true })).toBeVisible();
  await expect(page.getByRole('row', { name: /tone\.wav/ })).toBeVisible();
});

const axePages = ['/no/such/page', '/d/e2e/datasets/nope', '/', '/d/e2e/datasets/demo', '/d/e2e/datasets/demo?view=browse', '/d/e2e/datasets/boxes?view=browse', '/d/e2e/datasets/demo?view=browse&type=.txt&mode=table', '/d/e2e/datasets/boxes?view=releases&a=v1.0.0&b=v1.1.0', '/d/e2e/datasets/boxes', '/?type=.txt', '/d/e2e/datasets/faces?view=browse&item=person-01.png', '/d/e2e/datasets/tables?view=browse&release=v1.0.0&item=people.csv', '/d/e2e/datasets/tables?view=releases&a=v1.0.0&b=v1.1.0', '/d/e2e/datasets/media?view=browse&item=tone.wav', '/d/e2e/datasets/media?view=browse&item=notes.txt', '/keys', '/tokens'];

// Both themes: Daybreak as Playwright's default light scheme, Night flight
// as the dark one. Each must pass on its own (docs/dashboard.md §3.4).
for (const scheme of ['light', 'dark'] as const) {
  test(`accessibility: no serious or critical axe findings (${scheme === 'light' ? 'Daybreak' : 'Night flight'})`, async ({ page }) => {
    await page.emulateMedia({ colorScheme: scheme });
    await signIn(page);
    for (const path of axePages) {
      await page.goto(path);
      await page.waitForLoadState('networkidle');
      const results = await new AxeBuilder({ page }).analyze();
      const bad = results.violations.filter(
        (v) => v.impact === 'serious' || v.impact === 'critical',
      );
      expect(bad, `${path}: ${bad.map((v) => v.id).join(', ')}`).toEqual([]);
    }
  });
}

// Motion is decoration here (drifting clouds, the airship, transitions):
// someone who asks for less gets none, on every page (docs/dashboard.md §9).
test('with reduced motion on, no animation or transition runs on any page', async ({ page }) => {
  await signIn(page);
  const running = () =>
    page.evaluate(() => document.getAnimations().filter((a) => a.playState === 'running').length);
  // The control: the dataset's sky does move for everyone else.
  await page.goto('/d/e2e/datasets/demo');
  await page.waitForLoadState('networkidle');
  expect(await running()).toBeGreaterThan(0);

  await page.emulateMedia({ reducedMotion: 'reduce' });
  for (const path of axePages) {
    await page.goto(path);
    await page.waitForLoadState('networkidle');
    expect(await running(), path).toBe(0);
  }
  // A transition would start on a change, not on load: pin another release.
  await page.goto('/d/e2e/datasets/demo');
  await page.getByRole('button', { name: 'v1.0.0' }).click();
  await expect(page).toHaveURL(/release=v1\.0\.0/);
  expect(await running()).toBe(0);
});

test('the theme switch pins a theme across pages and reloads, and System lets go', async ({ page }) => {
  await page.emulateMedia({ colorScheme: 'light' });
  await signIn(page);
  const root = page.locator('html');
  await expect(root).not.toHaveAttribute('data-theme', /.*/);
  await page.getByRole('radio', { name: 'Theme: Night flight' }).click();
  await expect(root).toHaveAttribute('data-theme', 'night');
  await expect(page.getByRole('radio', { name: 'Theme: Night flight' })).toHaveAttribute('aria-checked', 'true');
  const dark = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  expect(dark).toBe('rgb(11, 16, 32)');

  // Pinned before the first paint of the next page.
  await page.goto('/d/e2e/datasets/demo');
  await expect(root).toHaveAttribute('data-theme', 'night');
  await page.reload();
  await expect(root).toHaveAttribute('data-theme', 'night');

  await page.getByRole('radio', { name: 'Theme: follow the system' }).click();
  await expect(root).not.toHaveAttribute('data-theme', /.*/);
  expect(await page.evaluate(() => getComputedStyle(document.body).backgroundColor)).toBe('rgb(244, 247, 251)');
});

test('budget: first-load JS stays under 300 KB gzipped', () => {
  const assets = resolve(dirname(fileURLToPath(import.meta.url)), '../dist/assets');
  let total = 0;
  for (const name of readdirSync(assets)) {
    if (name.endsWith('.js')) total += gzipSync(readFileSync(resolve(assets, name))).length;
  }
  expect(total).toBeLessThan(300 * 1024);
});
