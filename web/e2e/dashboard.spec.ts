import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { gzipSync } from 'node:zlib';
import { mkdtempSync, readFileSync, readdirSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const token = 'e2e-dashboard-token';

// Rewrites the dataset's overview answers. The page asks for several (the
// compare's balance reads each side's); one whose answer is gone by the
// time it is read (the page moved on) passes through as it is.
async function patchOverview(page: import('@playwright/test').Page, name: string, patch: () => Record<string, unknown>) {
  await page.route(`**/v0/datasets/${name}/-/overview*`, async (route) => {
    try {
      const res = await route.fetch();
      await route.fulfill({ response: res, json: { ...(await res.json()), ...patch() } });
    } catch {
      await route.continue().catch(() => {});
    }
  });
}

async function signIn(page: import('@playwright/test').Page) {
  await page.goto('/signin');
  await page.getByLabel(/server token|access token/i).fill(token);
  await page.getByRole('button', { name: 'Open the dashboard' }).click();
  await expect(page.getByRole('heading', { name: 'Datasets' })).toBeVisible();
}

test('the server hands a program its guide, with no sign-in', async ({ request }) => {
  // llms.txt: what an AI coding agent reads before its first cid command.
  const guide = await request.get('/llms.txt');
  expect(guide.status()).toBe(200);
  expect(guide.headers()['content-type']).toContain('text/plain');
  const text = await guide.text();
  expect(text.startsWith('# cid')).toBe(true);
  expect(text).toContain('cid help --json');
});

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
  await expect(page.locator('.dataset-meta')).toContainText('not in git yet: v1.1.0');
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
  // Two image tiles with real thumbnails; a text file shows its first lines.
  await expect(page.locator('.tile img')).toHaveCount(2);
  const readme = page.getByRole('button', { name: /README\.txt/ });
  await expect(readme.locator('.tile-text-lines')).toHaveText('the e2e dataset\n');
  await expect(readme.locator('.tile-text-type')).toHaveText('.txt');
  // The drawer: facts, hash chip, annotations absent on a file dataset.
  await page.getByRole('button', { name: /img-a\.png/ }).click();
  await expect(page).toHaveURL(/item=img/);
  await expect(page.getByText('blake3')).toBeVisible();
  await expect(page.getByRole('link', { name: 'Download the file' })).toBeVisible();
  // Dimensions arrived through sniffing, not from any client claim.
  await expect(page.getByText('200×150')).toBeVisible();
});

test('the header says what the server is still doing, and nothing once it is done', async ({ page }) => {
  await signIn(page);
  let answer = { preparing: true, previews: 1240 };
  await page.route('**/-/pending**', (route) => route.fulfill({ json: answer }));
  await page.goto('/d/e2e/datasets/demo');
  const busy = page.locator('.dataset-meta .server-busy');
  await expect(busy).toHaveText('preparing this version · previews: 1,240 to go');
  // Asked again while busy; once the server is done, the line goes.
  answer = { preparing: false, previews: 0 };
  await expect(busy).toHaveCount(0, { timeout: 10_000 });
});

test('a text tile with a long line never widens the page on a phone', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await signIn(page);
  // Whatever a file holds: one line far wider than any screen.
  const long = `{"classes": [${Array.from({ length: 40 }, (_, i) => `"class-${i}"`).join(', ')}]}\n`;
  await page.route('**/-/text?**', (route) =>
    route.fulfill({ json: { text: long, truncated: false, binary: false, size: long.length } }),
  );
  for (const path of ['/d/e2e/models/tiny-bert', '/d/e2e/models/tiny-bert?view=browse&mode=gallery']) {
    await page.goto(path);
    await expect(page.locator('.tile-text-lines').first()).toContainText('class-0');
    expect(await page.evaluate(() => document.documentElement.scrollWidth), path).toBeLessThanOrEqual(390);
  }
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

test('compare walks the folder tree: changed folders with their counts, one level at a time', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/tree?view=releases&a=v1.0.0&b=v1.1.0');
  const folders = page.getByRole('region', { name: 'Changed folders' });
  // At the top: a/ and d/ changed, c/ did not; each says how, in words.
  await expect(folders.getByRole('button', { name: 'a/: 1 added, 1 modified, 1 deleted' })).toBeVisible();
  await expect(folders.getByRole('button', { name: 'd/: 1 added' })).toBeVisible();
  await expect(folders.getByRole('button', { name: /^c\// })).toHaveCount(0);
  await expect(page.locator('.change-list')).toContainText('top.txt');
  // Opened, a/ lists only what changed under it, and its own subfolder.
  await folders.getByRole('button', { name: /^a\// }).click();
  await expect(page).toHaveURL(/dir=a(&|$)/);
  const list = page.locator('.change-list');
  await expect(list).toContainText('a/x.txt');
  await expect(list).toContainText('a/b/new.txt');
  await expect(list).toContainText('a/b/y.txt');
  await expect(list).not.toContainText('top.txt');
  await expect(folders.getByRole('button', { name: 'b/: 1 added, 1 deleted' })).toBeVisible();
  // The summary stays the whole comparison's; the path leads back up.
  await expect(page.getByText('2 added, 2 modified, 1 deleted')).toBeVisible();
  await folders.getByRole('navigation', { name: 'Folder path' }).getByRole('button', { name: 'tree' }).click();
  await expect(page).not.toHaveURL(/dir=/);
  await expect(page.locator('.change-list')).toContainText('top.txt');
});

test('browse filters by size, the buckets a histogram in their own order', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/clips?view=browse&mode=table');
  const size = page.getByRole('combobox', { name: 'Filter by size' });
  // Six seconds of sound against a short note.
  await expect(size.locator('option')).toHaveText(['any', 'under 10 KB (1)', '100 KB–1 MB (1)']);
  await size.selectOption('100KB-1MB');
  await expect(page).toHaveURL(/size=100KB-1MB/);
  await expect(page.getByText('1 of 2 items')).toBeVisible();
  const table = page.locator('.browse-table');
  await expect(table).toContainText('talk/clip.wav');
  await expect(table).not.toContainText('notes.txt');
});

test('browse filters by who made the annotations and under which policy', async ({ page }) => {
  await signIn(page);
  // The latest boxes: an agent drew both boxes, a reviewer then moved one.
  await page.goto('/d/e2e/datasets/boxes?view=browse&mode=table');
  const author = page.getByRole('combobox', { name: 'Filter by author' });
  await expect(author.locator('option')).toHaveText(['any', 'agent:annotator (1)', 'user:reviewer (1)']);
  await expect(page.getByRole('combobox', { name: 'Filter by policy' }).locator('option')).toHaveText(['any', 'p1 (1)']);
  await author.selectOption('user:reviewer');
  await expect(page).toHaveURL(/author=user%3Areviewer/);
  await expect(page.getByText('1 of 1 items')).toBeVisible();
  await expect(page.locator('.browse-table')).toContainText('frames/street.png');
  // Before the reviewer's change, nothing of theirs: the filter kept, at zero.
  await page.goto('/d/e2e/datasets/boxes?view=browse&mode=table&release=v1.0.0&author=user%3Areviewer');
  await expect(page.getByRole('heading', { name: 'No item matches these filters' })).toBeVisible();
  await expect(author.locator('option')).toHaveText(['any', 'agent:annotator (1)', 'user:reviewer (0)']);
  // And the command says the filter has no clone flag.
  await page.getByRole('button', { name: 'Show command' }).click();
  await expect(page.getByRole('region', { name: 'Command' })).toContainText('author, policy and number filters have no clone flag');
});

test('browse narrows to what changed since a release, and says so when no release has the name', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/tree?view=browse&mode=table');
  await expect(page.getByText('5 items', { exact: true })).toBeVisible();
  // v1.1.0 against v1.0.0: two files rewritten, two new; c/z.txt is as it was.
  await page.getByRole('combobox', { name: 'Filter to items changed since a release' }).selectOption('v1.0.0');
  await expect(page).toHaveURL(/since=v1\.0\.0/);
  await expect(page.getByText('4 of 5 items')).toBeVisible();
  const table = page.locator('.browse-table');
  await expect(table).toContainText('a/b/new.txt');
  await expect(table).toContainText('top.txt');
  await expect(table).not.toContainText('c/z.txt');
  // The command lists the same changes.
  await page.getByRole('button', { name: 'Show command' }).click();
  await expect(page.getByRole('region', { name: 'Command' })).toContainText('cid diff v1.0.0 v1.1.0');
  // A name no release has: said, with the way back.
  await page.goto('/d/e2e/datasets/tree?view=browse&mode=table&since=v9');
  await expect(page.getByRole('alert')).toContainText('no release is named v9');
  await page.getByRole('button', { name: 'Show every item' }).click();
  await expect(page).not.toHaveURL(/since=/);
  await expect(page.getByText('5 items', { exact: true })).toBeVisible();
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
  // A release made with notes shows them, its maker's line breaks kept;
  // one made without shows none. The Overview card carries the pinned one's.
  const annotated = page.getByRole('region', { name: 'History' });
  const noted = annotated.locator('.moment--release').filter({ has: page.locator('.release-tag', { hasText: 'v1.1.0' }) });
  await expect(noted.locator('.release-notes')).toHaveText('Review pass: the person box was redrawn.\nNothing else moved.');
  await expect(annotated.locator('.release-notes')).toHaveCount(1);
  await page.goto('/d/e2e/datasets/boxes');
  await expect(page.getByRole('region', { name: 'Dataset card' }).locator('.release-notes')).toContainText('Review pass: the person box was redrawn.');
  await page.goto('/d/e2e/datasets/boxes?release=v1.0.0');
  await expect(page.getByRole('region', { name: 'Dataset card' })).toBeVisible();
  await expect(page.locator('.release-notes')).toHaveCount(0);
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
  await patchOverview(page, 'e2e/datasets/demo', () => ({ git_url: gitUrl }));
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
  await patchOverview(page, 'e2e/datasets/demo', () => ({ purged: [{ release: 'v1.0.0', items: 1 }] }));
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
  await expect(page.getByRole('region', { name: 'Kind' }).getByRole('button', { name: /^model/ })).toHaveAttribute('aria-pressed', 'true');
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
  // One tab per way in; the cid command is the one open.
  const tabs = page.getByRole('tablist', { name: 'Ways to use it' });
  await expect(tabs.getByRole('tab', { name: 'cid', exact: true })).toHaveAttribute('aria-selected', 'true');
  await tabs.getByRole('tab', { name: 'datasets', exact: true }).click();
  const ds = page.getByRole('region', { name: 'With Hugging Face libraries' });
  await expect(ds).toContainText('HF_ENDPOINT=http://127.0.0.1:7177');
  await expect(ds).toContainText('load_dataset("e2e/datasets__demo", revision="v1.0.0")');
  // The arrows move along the tabs: the files as huggingface_hub takes them.
  await page.keyboard.press('ArrowRight');
  await expect(tabs.getByRole('tab', { name: 'huggingface_hub' })).toBeFocused();
  await expect(ds).toContainText('snapshot_download("e2e/datasets__demo", repo_type="dataset", revision="v1.0.0")');
  // And an agent's client, through the MCP door.
  await page.keyboard.press('ArrowRight');
  const agent = page.getByRole('region', { name: 'With an AI agent' });
  await expect(agent).toContainText('claude mcp add --transport http cid http://127.0.0.1:7177/mcp');
  await expect(agent).toContainText('e2e/datasets/demo at v1.0.0');
  await page.goto('/d/e2e/models/tiny-bert');
  await page.getByRole('tab', { name: 'transformers' }).click();
  const model = page.getByRole('region', { name: 'With Hugging Face libraries' });
  await expect(model).toContainText('AutoModel.from_pretrained("e2e/models__tiny-bert", revision="v1.1.0")');
  await page.getByRole('tab', { name: 'huggingface_hub' }).click();
  await expect(model).toContainText('snapshot_download("e2e/models__tiny-bert", revision="v1.1.0")');
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
  await page.getByRole('tab', { name: 'datasets', exact: true }).click();
  await expect(page.getByRole('region', { name: 'With Hugging Face libraries' })).toContainText(
    `revision="${commit.replaceAll('-', '')}00000000"`,
  );
  // Another tab keeps it pinned.
  await page.getByRole('link', { name: 'Browse', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`commit=${commit}`));
  await expect(page.getByText('131 items', { exact: true })).toBeVisible();
  // A release's tag pins the release again, and the commit lets go.
  await page.getByRole('button', { name: 'v1.0.0' }).click();
  await expect(page).not.toHaveURL(/commit=/);
  await expect(page.getByText('130 items', { exact: true })).toBeVisible();
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
  await page.getByRole('tab', { name: 'datasets', exact: true }).click();
  await expect(page.getByRole('region', { name: 'With Hugging Face libraries' })).toContainText('revision="fix"');
  // It stays on the branch from tab to tab, and main is one pick away.
  await page.getByRole('link', { name: 'Files', exact: true }).click();
  await expect(page).toHaveURL(/branch=fix/);
  await page.getByLabel('Branch').selectOption('main');
  await expect(page).not.toHaveURL(/branch=/);
  await expect(page.locator('.dataset-meta')).toContainText('130 items');
});

test('a link to an item this version does not hold says so, and names the releases that do', async ({ page }) => {
  await signIn(page);
  // notes.txt came with v1.1.0: v1.0.0 does not hold it.
  await page.goto('/d/e2e/datasets/demo?view=browse&release=v1.0.0&item=notes.txt');
  const missing = page.getByRole('status', { name: 'Item not in this version' });
  await expect(missing).toContainText('notes.txt is not in this version.');
  await missing.getByRole('link', { name: 'v1.1.0' }).click();
  await expect(page).toHaveURL(/release=v1\.1\.0/);
  await expect(page.getByRole('complementary', { name: 'notes.txt' })).toBeVisible();
  // A path no release ever held says that too, and Close lets it go.
  await page.goto('/d/e2e/datasets/demo?view=browse&item=never.txt');
  await expect(page.getByRole('status', { name: 'Item not in this version' })).toContainText('No release holds it');
  await page.getByRole('button', { name: 'Close' }).click();
  await expect(page).not.toHaveURL(/item=/);
});

test('files with no preview open as a table; the gallery is one click away', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/many?view=browse');
  await expect(page.getByRole('radio', { name: 'table' })).toHaveAttribute('aria-checked', 'true');
  await expect(page.getByRole('cell', { name: 'rows/0001.txt' })).toBeVisible();
  await page.getByRole('radio', { name: 'gallery' }).click();
  await expect(page).toHaveURL(/mode=gallery/);
  await expect(page.getByRole('button', { name: /rows\/0001\.txt/ })).toBeVisible();
  // Pictures still open as pictures.
  await page.goto('/d/e2e/datasets/demo?view=browse');
  await expect(page.getByRole('radio', { name: 'gallery' })).toHaveAttribute('aria-checked', 'true');
});

test('the subset picker shows what is picked', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/boxes');
  const splits = page.getByRole('group', { name: 'Splits' });
  await expect(splits).toContainText('all of them; pick to narrow');
  await splits.getByRole('button', { name: 'train' }).click();
  await expect(splits.getByRole('button', { name: 'train' })).toHaveClass(/subset-chip--on/);
  await expect(splits).toContainText('1 picked');
});

test('the files tab walks the committed tree', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/demo?view=files');
  await expect(page.getByText('README.txt')).toBeVisible();
  // Each file says its type, and its name opens it beside the listing.
  const picture = page.getByRole('row', { name: /img-a\.png/ });
  await expect(picture.getByRole('cell', { name: '.png', exact: true })).toBeVisible();
  // And when it last changed, and by whom (the CLI's author, user:$USER).
  await expect(picture.getByRole('cell', { name: /^\d{4}-\d{2}-\d{2} · user:/ })).toBeVisible();
  await picture.getByRole('link', { name: 'img-a.png' }).click();
  await expect(page).toHaveURL(/view=files/);
  await expect(page).toHaveURL(/item=img-a\.png/);
  const drawer = page.getByRole('complementary', { name: 'img-a.png' });
  await expect(drawer.getByText('200×150')).toBeVisible();
  await expect(drawer.locator('img')).toBeVisible();
  // Text shows as itself, and Escape closes the panel, the listing still there.
  await page.getByRole('row', { name: /README\.txt/ }).getByRole('link', { name: 'README.txt' }).click();
  const readme = page.getByRole('complementary', { name: 'README.txt' });
  await expect(readme).toBeVisible();
  await expect(readme.locator('pre')).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(readme).toBeHidden();
  await expect(page).not.toHaveURL(/item=/);
  await expect(page.getByText('README.txt')).toBeVisible();
  // A link opens it there too, and the panel leads on into Browse.
  await page.goto('/d/e2e/datasets/demo?view=files&item=img-a.png');
  await page.getByRole('complementary', { name: 'img-a.png' }).getByRole('link', { name: 'Open in Browse' }).click();
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
  // A settings file such as .cidkeys is shown last, after the data.
  await page.goto('/d/e2e/datasets/tables');
  await expect(page.getByRole('region', { name: 'A look inside' }).getByRole('link').last()).toHaveAccessibleName(/\.cidkeys/);
  await page.goto('/d/e2e/datasets/media');
  // No release yet: the facts, not an empty tape.
  await expect(page.getByText(/\d+ commits, no releases yet\./)).toBeVisible();

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

test('the annotations filter counts items by how many annotations they have, and finds the unlabelled', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/boxes?view=browse');
  const filter = page.getByLabel('Filter by annotations');
  // The street frame has two boxes: one bucket, "2-4", with one item.
  await expect(filter.locator('option', { hasText: '2-4 (1)' })).toHaveCount(1);
  await filter.selectOption('2-4');
  await expect(page).toHaveURL(/anns=2-4/);
  await expect(page.getByRole('button', { name: /frames\/street\.png/ })).toBeVisible();
  // None with no annotations here: the bucket is offered at zero once asked for.
  await page.goto('/d/e2e/datasets/boxes?view=browse&anns=0');
  await expect(page.getByText('0 of 1 items')).toBeVisible();
  // Written as typed, never JSON-quoted, when the page writes it again;
  // a link made quoted still opens.
  await page.getByLabel('Filter by path').fill('frames');
  await expect(page).toHaveURL(/q=frames/);
  await expect(page).toHaveURL(/[?&]anns=0(&|$)/);
  await page.goto('/d/e2e/datasets/boxes?view=browse&anns=%220%22');
  await expect(page.getByText('0 of 1 items')).toBeVisible();
  // A file dataset has no annotations to count.
  await page.goto('/d/e2e/datasets/demo?view=browse');
  await expect(page.getByLabel('Filter by annotations')).toHaveCount(0);
});

test("the drawer lists an annotation's attributes as filters, and who made it under which policy", async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/attrs2?view=browse&release=v1.0.0&item=street%2Fhidden.png');
  const anns = page.getByRole('complementary', { name: 'street/hidden.png' }).getByRole('region', { name: 'Annotations' });
  await expect(anns).toContainText('by agent:annotator · policy p1');
  // An attribute narrows Browse to the items carrying it.
  await anns.getByRole('button', { name: 'occluded=true' }).click();
  await expect(page).toHaveURL(/attr=occluded(%3D|=)true/);
  await expect(page.getByText('1 of 2 items')).toBeVisible();
  // An identity, to the identity filter.
  await anns.getByRole('button', { name: 'identity=car-0042' }).click();
  await expect(page).toHaveURL(/identity=car-0042/);
});

test('the attribute filter keeps the items whose annotations carry the value', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/attrs2?view=browse&mode=gallery');
  const filter = page.getByLabel('Filter by attribute');
  await expect(filter.locator('option', { hasText: 'occluded=true (1)' })).toHaveCount(1);
  await expect(filter.locator('option', { hasText: 'occluded=false (1)' })).toHaveCount(1);
  await filter.selectOption('occluded=true');
  await expect(page).toHaveURL(/attr=occluded(%3D|=)true/);
  await expect(page.getByText('1 of 2 items')).toBeVisible();
  await expect(page.getByRole('button', { name: /street\/hidden\.png/ })).toBeVisible();
  await expect(page.getByRole('button', { name: /street\/clear\.png/ })).toHaveCount(0);
  // A dataset whose annotations carry none offers no such filter.
  await page.goto('/d/e2e/datasets/boxes?view=browse');
  await expect(page.getByLabel('Filter by attribute')).toHaveCount(0);
});

test('a numeric attribute is a histogram, and a bar narrows Browse to its range', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/scores?view=browse&mode=table');
  const numbers = page.getByRole('region', { name: 'Numeric attributes' });
  // A boolean is no number: only confidence is offered.
  const pick = numbers.getByRole('combobox', { name: "Show a numeric attribute's histogram" });
  await expect(pick.locator('option')).toHaveText(['pick an attribute', 'confidence']);
  await pick.selectOption('confidence');
  await expect(page).toHaveURL(/num=confidence/);
  const bars = numbers.getByRole('group', { name: 'confidence: distribution' });
  await expect(bars.getByRole('button')).toHaveCount(20);
  await expect(page.getByText('3 items', { exact: true })).toBeVisible(); // a histogram alone filters nothing
  // The lowest bar holds 0.2; pressed, it keeps that item only.
  await bars.getByRole('button', { name: /^confidence 0\.2 to .*: 1 value$/ }).click();
  await expect(page).toHaveURL(/num_from=0\.2/);
  await expect(page.getByText('1 of 3 items')).toBeVisible();
  const table = page.locator('.browse-table');
  await expect(table).toContainText('street/doubtful.png');
  await expect(table).not.toContainText('street/sure.png');
  // The top bar is open-ended, so the highest value is in it.
  await bars.getByRole('button', { name: /to 0\.9: 1 value$/ }).click();
  await expect(page).not.toHaveURL(/num_to=/);
  await expect(table).toContainText('street/sure.png');
  await expect(page.getByText('1 of 3 items')).toBeVisible();
  // Pressed again, it lets go.
  await bars.getByRole('button', { name: /to 0\.9: 1 value$/ }).click();
  await expect(page.getByText('3 items', { exact: true })).toBeVisible();
  // A dataset whose annotations carry no numbers offers none.
  await page.goto('/d/e2e/datasets/boxes?view=browse');
  await expect(page.getByRole('region', { name: 'Numeric attributes' })).toHaveCount(0);
});

test('the identity filter finds an identity by its exact id, and is offered only where identities are', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/attrs2?view=browse&mode=gallery');
  // An identity is not an attribute value: it has a field of its own.
  await expect(page.getByLabel('Filter by attribute').locator('option', { hasText: 'identity=' })).toHaveCount(0);
  const field = page.getByLabel('Filter by identity');
  await field.fill('car-004');
  await field.press('Enter');
  await expect(page).toHaveURL(/identity=car-004(&|$)/);
  await expect(page.getByText('0 of 2 items')).toBeVisible();
  await field.fill('car-0042');
  await field.press('Enter');
  await expect(page.getByText('1 of 2 items')).toBeVisible();
  await expect(page.getByRole('button', { name: /street\/hidden\.png/ })).toBeVisible();
  await page.goto('/d/e2e/datasets/boxes?view=browse');
  await expect(page.getByLabel('Filter by identity')).toHaveCount(0);
});

test('the card draws class balance and split sizes as bars, and compare draws them before and after', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/attrs2?release=v1.1.0');
  const classes = page.getByRole('table', { name: 'Annotations by class' });
  // Most first, a bar per class, the number in words beside it.
  await expect(classes.getByRole('row').nth(0)).toContainText('car');
  await expect(classes.getByRole('row').nth(0)).toContainText('2');
  await expect(classes.locator('.bar')).toHaveCount(2);
  await expect(page.getByRole('table', { name: 'Items by split' }).locator('.bar')).toHaveCount(2);
  // Compare: only what moved is charted, the change said in numbers too.
  await page.goto('/d/e2e/datasets/attrs2?view=releases&a=v1.0.0&b=v1.1.0');
  const balance = page.getByRole('table', { name: /Annotations by class/ });
  await expect(balance).toContainText('v1.0.0');
  await expect(balance.getByRole('row', { name: /truck/ })).toContainText('0 → 1');
  await expect(balance.getByRole('row', { name: /car/ })).toContainText('2');
  await expect(page.getByRole('table', { name: /Items by split/ }).getByRole('row', { name: /val/ })).toContainText('0 → 1');
  // The move itself is a change, listed and counted, though no byte changed.
  await expect(page.locator('.compare-stats')).toContainText('1 moved to another split');
  await expect(page.locator('.change', { hasText: 'street/hidden.png' })).toContainText('train → val');
  // And the history says so under the release.
  await expect(page.locator('.moment-counts').first()).toContainText('1 moved to another split');
  // A version pair whose counts held draws no chart.
  await page.goto('/d/e2e/datasets/boxes?view=releases&a=v1.0.0&b=v1.1.0');
  await expect(page.locator('.dumbbell-table')).toHaveCount(0);
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
  // version had it — dashed for the old, solid for the new — in a card
  // that says what changed.
  const pair = page.getByRole('button', { name: /^frames\/street\.png: 1 moved\. Open it large\.$/ });
  await expect(pair).toBeVisible();
  await expect(pair.locator('img')).toHaveCount(2);
  const before = pair.locator('.overlay--before rect');
  const after = pair.locator('.overlay--after rect');
  // Only the changed shape is drawn: the vehicle that did not move is not.
  await expect(before).toHaveCount(1);
  await expect(after).toHaveCount(1);
  await expect(before).toHaveAttribute('x', '20');
  await expect(after).toHaveAttribute('x', '45');
  await expect(page.getByRole('heading', { name: '1 changed item' })).toBeVisible();

  // Opened large: a link of its own, the change in words to the pixel, and
  // who made it; Escape closes it and the link with it.
  await pair.click();
  await expect(page).toHaveURL(/pair=frames%2Fstreet\.png/);
  const dialog = page.getByRole('dialog', { name: 'frames/street.png, before and after' });
  await expect(dialog.getByText('1 of 1')).toBeVisible();
  const row = dialog.getByRole('row', { name: /person/ });
  await expect(row).toContainText('moved 25 px right');
  await expect(row).toContainText('user:reviewer');
  await expect(dialog.getByText('v1.0.0 · 1 shape')).toBeVisible();
  await expect(dialog.getByText('v1.1.0 · 1 shape')).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(page).not.toHaveURL(/pair=/);
  // The link opens it straight away.
  await page.goto('/d/e2e/datasets/boxes?view=releases&a=v1.0.0&b=v1.1.0&pair=frames%2Fstreet.png');
  await expect(page.getByRole('dialog', { name: 'frames/street.png, before and after' })).toBeVisible();
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
  await expect(page.getByRole('region', { name: 'Command' })).toContainText('The path search and the type, annotations, attribute, identity, size, author, policy and number filters have no clone flag');
  await page.getByRole('link', { name: 'Activity', exact: true }).click();
  await expect(page.getByRole('region', { name: 'Command' })).toContainText('no command shows it');
});

test('Ctrl-K jumps to a dataset, a release, a tab or an item by typing', async ({ page }) => {
  await signIn(page);
  const palette = page.getByRole('dialog', { name: 'Jump to' });
  const field = palette.getByRole('combobox');
  await page.keyboard.press('Control+k');
  await expect(palette).toBeVisible();
  const axe = await new AxeBuilder({ page }).include('.palette').analyze();
  expect(axe.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical')).toEqual([]);
  // A dataset by part of its name.
  await field.fill('boxes');
  await expect(palette.getByRole('option', { name: /e2e\/datasets\/boxes/ })).toBeVisible();
  await field.press('Enter');
  await expect(page).toHaveURL(/\/d\/e2e\/datasets\/boxes$/);
  await expect(palette).toHaveCount(0);
  // On a dataset: its releases…
  await page.keyboard.press('Control+k');
  await field.fill('v1.0');
  await expect(palette.getByRole('option', { name: /v1\.0\.0 release/ })).toHaveAttribute('aria-selected', 'true');
  await field.press('Enter');
  await expect(page).toHaveURL(/release=v1\.0\.0/);
  // …its tabs, at the same release…
  await page.keyboard.press('Control+k');
  await field.fill('files');
  await expect(palette.getByRole('option', { name: 'files tab' })).toHaveAttribute('aria-selected', 'true');
  await field.press('Enter');
  await expect(page).toHaveURL(/view=files/);
  await expect(page).toHaveURL(/release=v1\.0\.0/);
  // …and its items by path, opened in Browse; arrows move between results.
  await page.keyboard.press('Control+k');
  await field.fill('street');
  const item = palette.getByRole('option', { name: /frames\/street\.png item/ });
  await expect(item).toBeVisible();
  await field.press('ArrowDown');
  await field.press('ArrowUp');
  await field.press('Enter');
  await expect(page).toHaveURL(/item=frames(%2F|\/)street\.png/);
  // Escape puts it away without going anywhere.
  await page.keyboard.press('Control+k');
  await field.press('Escape');
  await expect(palette).toHaveCount(0);
});

test('a dataset with one version offers nothing to compare', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/docs?view=releases');
  const compare = page.getByRole('region', { name: 'Compare two versions' });
  await expect(compare).toContainText('Nothing to compare yet: this is the only version.');
  await expect(page.getByRole('combobox', { name: 'Compare from' })).toHaveCount(0);
});

test('on a branch, compare offers main\'s versions too, and compares the branch with main in one click', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/many?view=releases&branch=fix');
  const from = page.getByRole('combobox', { name: 'Compare from' });
  await expect(from.locator('optgroup[label="main"] option').first()).toBeAttached();
  await expect(from.locator('optgroup[label="fix"] option').first()).toBeAttached();
  await page.getByRole('button', { name: 'Compare with main' }).click();
  await expect(page).toHaveURL(/a=[0-9a-f-]{36}/);
  await expect(page).toHaveURL(/b=[0-9a-f-]{36}/);
  await expect(page.locator('.change', { hasText: 'rows/fix.txt' })).toContainText('added');
  // On main, nothing else is offered.
  await page.goto('/d/e2e/datasets/many?view=releases');
  await expect(page.getByRole('combobox', { name: 'Compare from' }).locator('optgroup')).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Compare with main' })).toHaveCount(0);
});

test('the palette runs actions too: pin the version, compare it with the release before, copy its command', async ({ page, context }) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  await signIn(page);
  await page.goto('/d/e2e/datasets/boxes');
  await page.waitForLoadState('networkidle');
  const palette = page.getByRole('dialog', { name: 'Jump to' });
  const field = palette.getByRole('combobox');
  // Unpinned, the page follows the newest release; pinning keeps it there.
  await page.keyboard.press('Control+k');
  await field.fill('pin');
  await expect(palette.getByRole('option', { name: 'Pin the page to v1.1.0 action' })).toHaveAttribute('aria-selected', 'true');
  await field.press('Enter');
  await expect(page).toHaveURL(/release=v1\.1\.0/);
  // Compare the release on screen with the one before it.
  await page.keyboard.press('Control+k');
  await field.fill('compare');
  await expect(palette.getByRole('option', { name: 'Compare v1.0.0 with v1.1.0 action' })).toHaveAttribute('aria-selected', 'true');
  await field.press('Enter');
  await expect(page).toHaveURL(/view=releases/);
  await expect(page).toHaveURL(/a=v1\.0\.0/);
  await expect(page).toHaveURL(/b=v1\.1\.0/);
  // Copy the command for the view on screen: the one Show command shows.
  await page.goto('/d/e2e/datasets/boxes?release=v1.0.0');
  await page.waitForLoadState('networkidle');
  await page.keyboard.press('Control+k');
  await field.fill('copy the command');
  await expect(palette.getByRole('option', { name: 'Copy the command for this view action' })).toBeVisible();
  await field.press('Enter');
  await expect(palette.getByRole('status')).toHaveText('Command copied');
  await expect(palette).toHaveCount(0);
  const copied = await page.evaluate(() => navigator.clipboard.readText());
  expect(copied).toContain('cid clone cid@127.0.0.1:e2e/datasets/boxes --release v1.0.0');
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
  await page.getByRole('region', { name: 'File type' }).getByRole('button', { name: /^\.txt/ }).click();
  await expect(page).toHaveURL(/type=\.txt/);
  await expect(page.getByRole('link', { name: 'e2e/datasets/demo', exact: true })).toBeVisible();
  await expect(page.getByRole('link', { name: 'e2e/datasets/boxes', exact: true })).toHaveCount(0);
});

test('home: the sidebar narrows by group and by filter, each value counted against the others', async ({ page }) => {
  await signIn(page);
  const side = page.getByRole('complementary', { name: 'Filter datasets' });
  const kind = side.getByRole('region', { name: 'Kind' });
  // A group is a folder of the dataset paths; a click narrows, in the URL.
  await side.locator('.side-value[title="e2e/models"]').click();
  await expect(page).toHaveURL(/group=e2e%2Fmodels|group=e2e\/models/);
  await expect(page.locator('.ds-card')).toHaveCount(1);
  await expect(page.getByRole('link', { name: 'e2e/models/tiny-bert', exact: true })).toBeVisible();
  // The other groups' counts are of this group now: one model, and no
  // annotated dataset, which is said and not offered.
  await expect(kind.getByRole('button', { name: /^model/ })).toContainText('1');
  await expect(kind.getByRole('button', { name: /^annotated/ })).toBeDisabled();
  // A group never counts itself away: its siblings stay, to switch to.
  await expect(side.locator('.side-value[title="e2e/datasets"]')).toBeEnabled();

  // What is on is said above the grid, each with its own way off.
  const chip = page.getByRole('button', { name: 'Remove the filter Groups: e2e/models' });
  await expect(chip).toBeVisible();
  await kind.getByRole('button', { name: /^model/ }).click();
  await expect(page).toHaveURL(/kind=model/);
  // Back undoes one click.
  await page.goBack();
  await expect(page).not.toHaveURL(/kind=/);
  await chip.click();
  await expect(page).not.toHaveURL(/group=/);

  // The sort is a link too; a name settles it.
  await page.goto('/?group=e2e/datasets');
  await page.getByLabel('Sort datasets').selectOption('name');
  await expect(page).toHaveURL(/sort=name/);
  await expect(page.locator('.ds-card-link').first()).toHaveText('e2e/datasets/attrs2');

  // The keyboard: `f` to the first filter, `/` to the search.
  await page.locator('body').click({ position: { x: 1, y: 1 } });
  await page.keyboard.press('f');
  await expect(page.locator('.side-value:focus')).toHaveCount(1);
  await page.locator('body').click({ position: { x: 1, y: 1 } });
  await page.keyboard.press('/');
  await expect(page.getByLabel('Search datasets')).toBeFocused();
});

test('home on a phone: the sidebar folds under a button that says how many filters are on', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await signIn(page);
  await page.goto('/?kind=model');
  const side = page.getByRole('complementary', { name: 'Filter datasets' });
  await expect(side).toBeHidden();
  const toggle = page.getByRole('button', { name: 'Filters (1 on)' });
  await toggle.click();
  await expect(side).toBeVisible();
  await expect(toggle).toHaveAttribute('aria-expanded', 'true');
  // It opens in place: the cards are still on the page beneath it.
  await expect(page.getByRole('link', { name: 'e2e/models/tiny-bert', exact: true })).toBeVisible();
  // Nothing spills past the screen.
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
});

test('home: a visited dataset appears under Recently viewed', async ({ page }) => {
  await signIn(page);
  await expect(page.getByRole('navigation', { name: 'Recently viewed' })).toHaveCount(0);
  await page.goto('/d/e2e/datasets/boxes');
  await expect(page.getByRole('region', { name: 'Use this dataset' })).toBeVisible();
  await page.goto('/');
  const recent = page.getByRole('navigation', { name: 'Recently viewed' });
  await expect(recent.getByRole('link', { name: 'boxes e2e/datasets' })).toBeVisible();
});

test('owners see a dataset\'s deploy keys on its overview; a reader does not', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/faces');
  const section = page.getByRole('region', { name: 'Deploy keys' });
  await expect(section).toContainText('cid deploy-key add');
});

test('a reader does not see a dataset\'s deploy keys', async ({ page }) => {
  // Rhea reads faces (GitLab Reporter): the server refuses her the list.
  await page.goto('/');
  await page.getByRole('link', { name: 'Sign in with GitLab' }).click();
  await expect(page.locator('.account-name')).toHaveText('Rhea Reviewer');
  await page.goto('/d/e2e/datasets/faces');
  await expect(page.getByRole('heading', { name: 'Dataset card' })).toBeVisible();
  await page.waitForLoadState('networkidle');
  await expect(page.getByRole('region', { name: 'Deploy keys' })).toHaveCount(0);
});

test('sign in with GitHub on a server that takes access from GitHub', async ({ page }) => {
  await page.goto('http://127.0.0.1:7179/');
  await expect(page).toHaveURL(/\/signin/);
  // The server's host, named: GitHub's button, not GitLab's.
  await expect(page.getByRole('link', { name: 'Sign in with GitLab' })).toHaveCount(0);
  await page.getByRole('link', { name: 'Sign in with GitHub' }).click();
  // Through the strict fake GitHub and back; a person with no name is their login.
  await expect(page.getByRole('heading', { name: 'Datasets' })).toBeVisible();
  await expect(page.locator('.account-name')).toHaveText('octo');
  const me = await page.evaluate(async () => (await fetch('/v0/me')).json());
  expect(me).toMatchObject({ via: 'github', account: 'github:5353' });
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
  await expect(page.getByRole('navigation', { name: 'Starred' }).getByRole('link', { name: 'boxes e2e/datasets' })).toBeVisible();
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
  // On a phone the time goes under the date; neither is broken across lines.
  await page.setViewportSize({ width: 390, height: 844 });
  for (const part of await page.locator('.activity-when span').first().locator('..').locator('span').all()) {
    expect((await part.boundingBox())!.height).toBeLessThan(30);
  }
  await page.setViewportSize({ width: 1280, height: 720 });
  // A long log shows its newest 200 and says older ones follow; a release
  // it names is a link.
  await expect(page.locator('.activity-table caption')).toContainText('the newest 200 events, older ones below');
  await expect(page.locator('.activity-table tbody tr')).toHaveCount(200);
  // Older pages until the start of the log (the e2e log grows each run).
  const older = page.getByRole('button', { name: 'Show older events' });
  for (let shown = 200; await older.isVisible(); ) {
    await older.click();
    await expect(page.locator('.activity-table tbody tr')).not.toHaveCount(shown);
    shown = await page.locator('.activity-table tbody tr').count();
  }
  await expect(page.locator('.activity-table caption')).toContainText(/all [\d,]+ events\./);
  await expect(page.getByRole('button', { name: 'Show older events' })).toHaveCount(0);
  await expect(page.locator('.activity-table').getByRole('link', { name: 'v1.0.0' }).first()).toHaveAttribute('href', /release=v1\.0\.0/);
  // Narrowed to one action, in the URL: only reveals remain.
  await page.getByLabel('Filter by what').selectOption('reveal');
  await expect(page).toHaveURL(/what=reveal/);
  const chips = page.locator('.activity-table tbody .chip');
  await expect(chips.first()).toHaveText('reveal');
  expect(new Set(await chips.allTextContents())).toEqual(new Set(['reveal']));
  await page.getByRole('button', { name: 'Clear' }).click();
  await expect(page).not.toHaveURL(/what=/);
  // A filter is answered by the server, so it reaches a year back: every
  // one of the old reader's 250 reads, beyond the newest page.
  await page.getByLabel('Filter by who').selectOption('gitlab:old-reader');
  await expect(page.locator('.activity-table caption')).toContainText('the newest 200 events that match');
  await page.getByRole('button', { name: 'Show older events' }).click();
  await expect(page.locator('.activity-table caption')).toContainText('all 250 events that match');
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
  // Its size then and now.
  await expect(change).toContainText('119 B → 120 B');
  await expect(change.locator('.row-changes')).toContainText('2 rows added, 2 removed');
  await expect(change.locator('.row-changes')).toContainText('5 → 5 rows');
  // A table has no picture to set side by side, and a change this small
  // shows its rows without a click.
  await expect(change.locator('.before-after')).toHaveCount(0);
  await expect(change.locator('table', { hasText: 'Removed' })).toContainText('Budi');
  await expect(change.locator('table', { hasText: 'Added' })).toContainText('Fajar');
});

test('a table\'s rows: each column\'s distribution above it, a click narrows the rows, and the URL keeps it', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/tables?view=browse&release=v1.1.0&item=people.csv');
  const rows = page.getByRole('region', { name: 'Rows' });
  await expect(rows).toContainText('5 rows');
  // A value of a text column narrows to its rows.
  await rows.getByRole('button', { name: /^city = Medan: 1 row$/ }).click();
  await expect(page).toHaveURL(/rows=/);
  await expect(rows).toContainText('1 of 5 rows');
  await expect(rows.getByRole('row', { name: /Fajar/ })).toBeVisible();
  await expect(rows.getByRole('row', { name: /Citra/ })).toHaveCount(0);
  // The link holds it: a reload shows the same rows.
  await page.reload();
  await expect(page.getByRole('region', { name: 'Rows' })).toContainText('1 of 5 rows');
  // Removed with its chip; then a number column's top bin.
  await page.getByRole('button', { name: 'Remove the filter city = Medan' }).click();
  await expect(page.getByRole('region', { name: 'Rows' })).toContainText('5 rows');
  const bins = page.getByRole('group', { name: 'score: distribution' }).getByRole('button', { name: /^score .*: 1 row$/ });
  await bins.last().click();
  await expect(page.getByRole('region', { name: 'Rows' })).toContainText('1 of 5 rows');
});

test('searching a table\'s rows finds the words in any text column, ignoring case', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/tables?view=browse&release=v1.1.0&item=people.csv');
  const rows = page.getByRole('region', { name: 'Rows' });
  const box = rows.getByLabel("Search the rows' text");
  await box.fill('BANDUNG');
  await box.press('Enter');
  await expect(rows).toContainText('2 of 5 rows');
  await expect(rows.getByRole('row', { name: /Eko/ })).toHaveCount(0);
  await expect(page).toHaveURL(/rows=/);
  // Gone with its chip.
  await rows.getByRole('button', { name: 'Remove the filter contains “BANDUNG”' }).click();
  await expect(rows).toContainText('5 rows');
});

test('a link to one row opens the table there, marked, and a row\'s number makes that link', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/tables?view=browse&release=v1.1.0&item=people.csv');
  const rows = page.getByRole('region', { name: 'Rows' });
  await rows.getByRole('button', { name: 'Link to row 4' }).click();
  await expect(page).toHaveURL(/row=4/);
  // The link, opened afresh: that row, marked as the current one.
  await page.reload();
  const linked = page.getByRole('region', { name: 'Rows' }).locator('tr[aria-current="true"]');
  await expect(linked).toContainText('Eko');
  await expect(linked).toBeInViewport();
  // Under a filter that leaves it out, the page says so.
  await page.getByRole('button', { name: /^city = Medan: 1 row$/ }).click();
  await expect(page.getByRole('region', { name: 'Rows' })).toContainText('Row 4 is not among these rows');
});

test('a video tile plays its short clip while pointed at, and stops after', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/video?view=browse&mode=gallery');
  const tile = page.getByRole('button', { name: /street\.mp4/ });
  // Its poster, and no clip fetched until someone points at it.
  await expect(tile.locator('img')).toBeVisible();
  await expect(tile.locator('video')).toHaveCount(0);
  await tile.hover();
  const clip = tile.locator('video');
  await expect(clip).toHaveAttribute('src', /clip\.webm/);
  // It really plays: silent, looping, time moving.
  await expect.poll(() => clip.evaluate((v: HTMLVideoElement) => v.currentTime), { timeout: 5000 }).toBeGreaterThan(0);
  await expect(clip).toHaveJSProperty('muted', true);
  await page.mouse.move(0, 0);
  await expect(tile.locator('video')).toHaveCount(0);
  // The keyboard reaches it too.
  await tile.focus();
  await expect(tile.locator('video')).toHaveCount(1);
});

test('a video clip never plays for someone who asked for reduced motion', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await signIn(page);
  await page.goto('/d/e2e/datasets/video?view=browse&mode=gallery');
  const tile = page.getByRole('button', { name: /street\.mp4/ });
  await expect(tile.locator('img')).toBeVisible();
  await tile.hover();
  await page.waitForTimeout(300);
  await expect(tile.locator('video')).toHaveCount(0);
});

test('a PDF shows its first page, drawn on the server', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/docs?view=browse&mode=gallery');
  const tile = page.getByRole('button', { name: /page\.pdf/ });
  await expect(tile.locator('img')).toBeVisible();
  await tile.click();
  const drawer = page.getByRole('complementary', { name: 'page.pdf' });
  // Its pages, drawn by the worker, each said which it is.
  const pages = drawer.getByRole('region', { name: 'Pages' });
  await expect(pages.getByRole('img', { name: 'page.pdf, page 1', exact: true })).toBeVisible();
  await expect(pages).toContainText('page 1 of 1');
  // Its page count, never dimensions: a PDF is not an image.
  await expect(drawer.locator('dt', { hasText: 'pages' })).toBeVisible();
  await expect(drawer.locator('dt', { hasText: 'dimensions' })).toHaveCount(0);
  // The page leads the dataset's card, as a picture would.
  await page.goto('/');
  await expect(page.locator('.ds-card', { hasText: 'e2e/datasets/docs' }).locator('.mosaic img')).toHaveCount(1);
  // One item is one item.
  await page.goto('/d/e2e/datasets/docs?view=browse');
  await expect(page.getByText('1 item', { exact: true })).toBeVisible();
});

test('a clip shows its segments and transcript on a timeline, and a note its spans', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/clips?view=browse&item=talk%2Fclip.wav');
  const drawer = page.getByRole('complementary', { name: 'talk/clip.wav' });
  const timeline = drawer.getByRole('region', { name: 'Timeline' });
  // One lane per class, each segment where it falls, named in words.
  await expect(timeline.getByRole('button', { name: 'speech, 0:00.5 to 0:02.0' })).toBeVisible();
  await expect(timeline.getByRole('button', { name: 'music, 0:03.0 to 0:05.5' })).toBeVisible();
  // A segment whose end comes first is said, and breaks nothing else.
  await expect(timeline).toContainText('One time annotation could not be read');
  // The transcript, as lines; a line plays from where it starts.
  const transcript = timeline.getByRole('list', { name: 'Transcript' });
  await expect(transcript.getByRole('listitem')).toHaveCount(2);
  await transcript.getByRole('button', { name: /and then a tune/ }).click();
  await expect
    .poll(() => drawer.locator('audio').evaluate((a: HTMLAudioElement) => a.currentTime))
    .toBeGreaterThanOrEqual(3);
  // The list beside them says when.
  await expect(drawer.getByRole('region', { name: 'Annotations' })).toContainText('0:00.5–0:02.0');

  // A note's span marks exactly its five code points, "naïve".
  await page.goto('/d/e2e/datasets/clips?view=browse&item=docs%2Fnotes.txt');
  const note = page.getByRole('complementary', { name: 'docs/notes.txt' });
  await expect(note.locator('mark')).toHaveText('naïve');
  await expect(note.locator('mark')).toHaveAttribute('title', 'word');
  await expect(note).toContainText('One span lies past the part shown');
});

test('the SQL console runs a SELECT over the version, keeps it in the link, and shows items as tiles', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/boxes?view=browse');
  await page.getByRole('radio', { name: 'sql' }).click();
  const console_ = page.getByRole('region', { name: 'SQL console' });
  const input = console_.getByLabel('SQL query');
  await input.fill("SELECT path, hash, annotations FROM items WHERE path LIKE 'frames/%'");
  await input.press('Control+Enter');
  await expect(page).toHaveURL(/mode=sql/);
  await expect(page).toHaveURL(/sql=/);
  await expect(console_.getByRole('status')).toContainText('1 row');
  await expect(console_.getByRole('table')).toContainText('frames/street.png');
  // The link opens the same query, already run.
  await page.reload();
  await expect(page.getByRole('region', { name: 'SQL console' }).getByRole('table')).toContainText('frames/street.png');
  // Rows naming items, as tiles; a tile opens its item.
  await page.getByRole('radio', { name: 'gallery' }).last().click();
  await page.getByRole('region', { name: 'SQL console' }).getByRole('button', { name: /frames\/street\.png/ }).click();
  await expect(page).toHaveURL(/item=frames(%2F|\/)street\.png/);
  // Only a SELECT: anything else is refused in words.
  await page.goto('/d/e2e/datasets/boxes?view=browse&mode=sql&sql=DELETE%20FROM%20items');
  await expect(page.getByRole('alert')).toContainText('only a single SELECT');
  // A restricted dataset has no console.
  await page.goto('/d/e2e/datasets/faces?view=browse');
  await expect(page.getByRole('radio', { name: 'sql' })).toHaveCount(0);
});

test('the Health tab marks each check, names what it found, and links to it', async ({ page }) => {
  await signIn(page);
  // attrs2 holds one picture twice: at v1.0.0 both in train (a duplicate),
  // at v1.1.0 one moved to val (the same content in two splits).
  await page.goto('/d/e2e/datasets/attrs2?view=health&release=v1.1.0');
  const checks = page.getByRole('list', { name: 'Checks' });
  const leakage = checks.getByRole('listitem').filter({ hasText: 'Splits kept apart' });
  await expect(leakage).toContainText('fail');
  await expect(leakage).toContainText('in more than one split');
  await expect(page.getByRole('status')).toContainText('1 failed');
  // What needs a look comes first.
  await expect(checks.getByRole('listitem').first()).toContainText('Splits kept apart');
  await leakage.getByRole('link', { name: /street\/clear\.png/ }).click();
  await expect(page).toHaveURL(/view=browse/);
  await expect(page).toHaveURL(/item=street(%2F|\/)clear\.png/);
  await expect(page).toHaveURL(/release=v1\.1\.0/);
  await page.goto('/d/e2e/datasets/attrs2?view=health&release=v1.0.0');
  await expect(checks.getByRole('listitem').filter({ hasText: 'Splits kept apart' })).toContainText('pass');
  await expect(checks.getByRole('listitem').filter({ hasText: 'No duplicate files' })).toContainText('warning');
  // Where the boxes sit, as a table with its counts.
  await expect(page.getByRole('table', { name: /Box centres/ })).toBeVisible();
  // A file dataset gets the file checks only; a table the worker could
  // not read is named, and one it read is not.
  await page.goto('/d/e2e/datasets/tables?view=health');
  await expect(checks.locator('.health-check')).toHaveCount(4);
  await page.goto('/d/e2e/datasets/media?view=health');
  const tables = checks.locator('.health-check').filter({ hasText: 'Tables read' });
  await expect(tables).toContainText('warning');
  await expect(tables).toContainText('1 table could not be read as its file name says.');
  await expect(tables.getByRole('link')).toHaveText(['broken.csv']);
  await page.getByRole('button', { name: 'Show command' }).click();
  await expect(page.getByRole('region', { name: 'Command' })).toContainText('no command shows it');
});

test('a dataset card says how its checks went, once kept, and links to them', async ({ page }) => {
  await signIn(page);
  // Kept by the visit (or by the background preparation before it).
  await page.goto('/d/e2e/datasets/media?view=health');
  await expect(page.getByRole('list', { name: 'Checks' })).toBeVisible();
  await page.goto('/');
  const card = page.locator('.ds-card', { hasText: 'e2e/datasets/media' }).first();
  const mark = card.getByRole('link', { name: /^Health: / });
  await expect(mark).toHaveText(/1 warning/);
  await mark.click();
  await expect(page).toHaveURL(/\/d\/e2e\/datasets\/media\?.*view=health/);
});

test('a declared key turns a removed-and-added pair into one row changed, cell by cell', async ({ page }) => {
  await signIn(page);
  // Without .cidkeys: an edit is one removed and one added, and the page says how to see it changed.
  await page.goto('/d/e2e/datasets/tables?view=releases&a=v1.0.0&b=v1.1.0');
  const before = page.locator('.change', { hasText: 'people.csv' });
  await expect(before).toContainText('2 rows added, 2 removed');
  await expect(before).toContainText('name the table\'s key in .cidkeys');
  // With people.csv keyed by id: Budi removed, Fajar added, Citra changed.
  await page.goto('/d/e2e/datasets/tables?view=releases&a=v1.0.0&b=v1.2.0');
  const keyed = page.locator('.change', { hasText: 'people.csv' });
  await expect(keyed).toContainText('1 row added, 1 removed, 1 changed');
  await expect(keyed).toContainText('paired by id');
  const changed = keyed.locator('table', { hasText: 'Changed' });
  await expect(changed.getByRole('row', { name: /3 score 77(\.0)? 79(\.0)?/ })).toBeVisible();
});

test('browse pages through a version: one page, then more on scroll, and links past the first page', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/many?view=browse&mode=table');
  await expect(page.getByText('130 items', { exact: true })).toBeVisible();
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

test('the List view plays sound in place and reads text\'s opening line', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/media?view=browse');
  await page.waitForLoadState('networkidle');
  // `l` switches to it, and the URL says so.
  await page.keyboard.press('l');
  await expect(page).toHaveURL(/mode=list/);
  const list = page.getByRole('list', { name: 'Items' });
  const tone = list.getByRole('listitem').filter({ hasText: 'tone.wav' });
  const notes = list.getByRole('listitem').filter({ hasText: 'notes.txt' });
  await expect(notes).toContainText('A note on this dataset.');
  // Nothing is fetched until asked: a play button, then the player.
  await expect(tone.locator('audio')).toHaveCount(0);
  await tone.getByRole('button', { name: 'Play tone.wav' }).click();
  await expect(tone.locator('audio')).toHaveAttribute('src', /^http/);
  // The row's words open the drawer, as everywhere else.
  await notes.getByRole('button', { name: 'Open notes.txt' }).click();
  await expect(page).toHaveURL(/item=notes\.txt/);
  await expect(page.getByRole('complementary', { name: 'notes.txt' })).toBeVisible();
});

test('a text file\'s gallery tile shows its first lines, a binary one its type', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/media?view=browse&mode=gallery');
  const note = page.locator('.tile', { hasText: 'notes.txt' });
  await expect(note.locator('.tile-text-lines')).not.toBeEmpty();
  await expect(note.locator('.tile-text-type')).toHaveText('.txt');
});

test('the tab bar has no scrollbar of its own, and each tab carries its icon beside its name', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/boxes');
  const tabs = page.getByRole('navigation', { name: 'Dataset views' });
  // Nothing hangs out of the bar: it has nothing to scroll, up or down.
  expect(await tabs.evaluate((n) => n.scrollHeight - n.clientHeight)).toBe(0);
  // The icon is decoration: the tab is still named by its word alone.
  const health = tabs.getByRole('link', { name: 'Health', exact: true });
  await expect(health.locator('svg.icon')).toHaveAttribute('aria-hidden', 'true');
  // A file with no preview is drawn as its kind, with its type in words.
  await page.goto('/d/e2e/datasets/media?view=browse&mode=gallery');
  const tile = page.locator('.tile', { hasText: 'broken.csv' }).locator('.tile-type');
  await expect(tile.locator('svg.icon')).toHaveCount(1);
  await expect(tile).toHaveText('.csv');
});

test('a version without splits shows no split filter or column', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/tables?view=browse&mode=table');
  await expect(page.getByRole('row', { name: /people\.csv/ })).toBeVisible();
  await expect(page.getByLabel('Filter by split')).toHaveCount(0);
  await expect(page.getByRole('columnheader', { name: 'split' })).toHaveCount(0);
  await page.goto('/d/e2e/datasets/boxes?view=browse&mode=table');
  await expect(page.getByLabel('Filter by split')).toBeVisible();
  await expect(page.getByRole('columnheader', { name: 'split' })).toBeVisible();
});

test('every tab answers the keyboard: numbers switch tabs, c compares, f filters, ? lists them', async ({ page }) => {
  await signIn(page);
  await page.goto('/d/e2e/datasets/boxes?view=overview');
  await expect(page.getByRole('link', { name: 'Overview', exact: true })).toHaveAttribute('aria-current', 'page');
  // A number is a tab, in the order they are drawn.
  await page.keyboard.press('2');
  await expect(page).toHaveURL(/view=browse/);
  // `f` puts the cursor on the first filter.
  await expect(page.getByLabel('Filter by split')).toBeVisible();
  await page.keyboard.press('f');
  await expect(page.getByLabel('Filter by split')).toBeFocused();
  await page.locator('body').click({ position: { x: 1, y: 1 } });
  // Browse lists its own keys and every tab's.
  await page.keyboard.press('?');
  const list = page.getByRole('region', { name: 'Keyboard shortcuts' });
  await expect(list).toContainText('next item');
  await expect(list).toContainText('compare this release with the one before');
  await page.keyboard.press('Escape');
  await expect(list).toHaveCount(0);
  await page.keyboard.press('4');
  await expect(page).toHaveURL(/view=health/);
  // Any other tab lists every tab's keys too.
  await page.keyboard.press('?');
  await expect(list).toContainText('Overview, Browse, Releases, Health, Files, Activity');
  const axe = await new AxeBuilder({ page }).include('.shortcuts').analyze();
  expect(axe.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical')).toEqual([]);
  await page.keyboard.press('Escape');
  await expect(list).toHaveCount(0);
  // `c`: the release on screen against the one before it.
  await page.keyboard.press('c');
  await expect(page).toHaveURL(/view=releases/);
  await expect(page).toHaveURL(/a=v1\.0\.0/);
  await expect(page).toHaveURL(/b=v1\.1\.0/);
  // Typed into a field, a key is only a letter.
  await page.goto('/d/e2e/datasets/boxes?view=browse');
  await page.getByLabel('Filter by path').fill('3');
  await expect(page).toHaveURL(/view=browse/);
});

test('the keyboard moves through items, searches, and lists its shortcuts', async ({ page }) => {
  const at = (n: string) => new RegExp(`item=rows(%2F|/)${n}\\.txt`);
  await signIn(page);
  await page.goto('/d/e2e/datasets/many?view=browse&mode=gallery');
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
  await expect(drawer.getByText(/No column statistics: /)).toBeVisible();
  await expect(drawer.getByText(/Rows are not browsable: not a readable table/)).toBeVisible();
  await expect(drawer.getByRole('link', { name: 'Download the file' })).toBeVisible();
  await expect(page.getByRole('alert')).toHaveCount(0);
  // And the other views of the same version.
  await page.goto('/d/e2e/datasets/media?view=files');
  await expect(page.getByRole('row', { name: /broken\.csv/ }).getByRole('cell', { name: '.csv', exact: true })).toBeVisible();
  await expect(page.getByRole('row', { name: /tone\.wav/ })).toBeVisible();
});

const axePages = ['/no/such/page', '/d/e2e/datasets/nope', '/', '/d/e2e/datasets/demo', '/d/e2e/datasets/demo?view=browse', '/d/e2e/datasets/scores?view=browse&num=confidence&num_from=0.2&num_to=0.235', '/d/e2e/datasets/demo?view=files&item=img-a.png', '/d/e2e/datasets/boxes?view=browse', '/d/e2e/datasets/demo?view=browse&type=.txt&mode=table', '/d/e2e/datasets/boxes?view=releases&a=v1.0.0&b=v1.1.0', '/d/e2e/datasets/boxes?view=releases&a=v1.0.0&b=v1.1.0&pair=frames%2Fstreet.png', '/d/e2e/datasets/boxes', '/?type=.txt', '/d/e2e/datasets/faces?view=browse&item=person-01.png', '/d/e2e/datasets/tables?view=browse&release=v1.0.0&item=people.csv', '/d/e2e/datasets/tables?view=releases&a=v1.0.0&b=v1.1.0', '/d/e2e/datasets/media?view=browse&item=tone.wav', '/d/e2e/datasets/media?view=browse&item=notes.txt', '/d/e2e/datasets/media?view=browse&mode=list', '/d/e2e/datasets/attrs2?view=health&release=v1.1.0', '/d/e2e/datasets/boxes?view=browse&mode=sql&sql=SELECT%20split%2C%20count(*)%20FROM%20items%20GROUP%20BY%20split', '/keys', '/tokens'];

// Both themes: Daybreak as Playwright's default light scheme, Night flight
// as the dark one. Each must pass on its own (docs/dashboard.md §3.4).
for (const scheme of ['light', 'dark'] as const) {
  test(`accessibility: no serious or critical axe findings (${scheme === 'light' ? 'Daybreak' : 'Night flight'})`, async ({ page }) => {
    // One test walks every page in the list: give it time for all of them,
    // not one page's worth (it passed under 30 s on an idle machine only).
    test.setTimeout(90_000);
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

// U3: no blank waits. With every answer slowed, each page shows its own
// shape first, so nothing jumps when the data arrives: the summed layout
// shift stays under 0.1 (the web's "good").
test('pages hold their shape while their data arrives: layout shift under 0.1', async ({ page }) => {
  await signIn(page);
  await page.route('**/v0/**', async (route) => {
    await new Promise((done) => setTimeout(done, 400));
    await route.continue();
  });
  const shifted = async (path: string) => {
    await page.goto(path);
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(300);
    return page.evaluate(
      () =>
        new Promise<number>((done) => {
          let sum = 0;
          new PerformanceObserver((list) => {
            for (const e of list.getEntries() as unknown as { value: number; hadRecentInput: boolean }[])
              if (!e.hadRecentInput) sum += e.value;
          }).observe({ type: 'layout-shift', buffered: true });
          setTimeout(() => done(sum), 100);
        }),
    );
  };
  for (const path of [
    '/',
    '/d/e2e/datasets/demo',
    '/d/e2e/datasets/boxes?view=browse',
    '/d/e2e/datasets/demo?view=files',
    '/d/e2e/datasets/boxes?view=releases',
    '/d/e2e/datasets/faces?view=activity',
  ]) {
    const value = await shifted(path);
    console.log(`layout shift ${path}: ${value.toFixed(3)}`);
    expect(value, path).toBeLessThan(0.1);
  }
});

// U4: the first minute. Opened for the first time at 1440×900, a dataset
// answers five questions without a scroll: what it is, how big, what kind
// of data, who owns it, and the one command to get it.
test('the first screen of a dataset answers what, how big, what kind, whose, and how to get it', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await signIn(page);
  for (const [path, owner] of [
    ['/d/e2e/datasets/boxes', 'Olu Owner'],
    ['/d/e2e/datasets/tables', null],
    ['/d/e2e/models/tiny-bert', null],
  ] as const) {
    await page.goto(path);
    await page.waitForLoadState('networkidle');
    const above = async (what: string, locator: import('@playwright/test').Locator) => {
      await expect(locator, `${path}: ${what}`).toBeVisible();
      const box = (await locator.boundingBox())!;
      expect(box.y + box.height, `${path}: ${what} is below the fold`).toBeLessThanOrEqual(900);
    };
    const meta = page.locator('.dataset-meta');
    await above('what it is', meta.getByText(/Annotated dataset|File dataset|Model/));
    await above('how big', meta.getByText(/\d[\d,]* items?, [\d.]+ (B|KB|MB|GB)/));
    await above('what kind of data', page.getByRole('table', { name: 'Items by type' }).getByRole('row').nth(1));
    await above('who owns it', meta.getByText(owner ? `owned by ${owner}` : 'no owner named'));
    await above('the one command', page.locator('code.command').first());
  }
});

test('no other site may frame the dashboard', async ({ page }) => {
  for (const path of ['/', '/tokens', '/d/e2e/datasets/demo?view=browse']) {
    const response = await page.goto(path);
    expect(response!.headers()['content-security-policy'], path).toBe("frame-ancestors 'self'");
    expect(response!.headers()['x-frame-options'], path).toBe('SAMEORIGIN');
  }
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
