import { expect, test } from '@playwright/test';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

// Every page of the dashboard as a picture: both themes, three widths, one
// folder (docs/roadmap.md, U1). It judges nothing by itself beyond what a
// program can measure (a page wider than its window, a control cut off);
// the pictures are for reading against the design language
// (docs/dashboard.md, section 3). Opt-in, the everyday suite skips it:
//   SCREENS=<folder> pnpm --dir web exec playwright test screens
const out = process.env.SCREENS;
const token = 'e2e-dashboard-token';

test.skip(!out, 'set SCREENS to the folder the pictures go to');

const demo = '/d/e2e/datasets/demo';
const boxes = '/d/e2e/datasets/boxes';
const tables = '/d/e2e/datasets/tables';
const media = '/d/e2e/datasets/media';
const faces = '/d/e2e/datasets/faces';
const many = '/d/e2e/datasets/many';

// The pages, by the name their pictures carry. The fixtures are the e2e
// suite's (web/e2e/setup.ts): never only images.
const pages: [string, string][] = [
  ['home-cards', '/'],
  ['home-list', '/?layout=list'],
  ['home-search-none', '/?q=nothing-is-called-this'],
  ['lost-page', '/no/such/page'],
  ['lost-dataset', '/d/e2e/datasets/nope'],
  ['overview-files', demo],
  ['overview-older-release', `${demo}?release=v1.0.0`],
  ['overview-annotated', boxes],
  ['overview-no-release', media],
  ['overview-restricted', faces],
  ['overview-tables', tables],
  ['browse-gallery-files', `${demo}?view=browse`],
  ['browse-gallery-boxes', `${boxes}?view=browse`],
  ['browse-gallery-many', `${many}?view=browse`],
  ['browse-gallery-restricted', `${faces}?view=browse`],
  ['browse-table', `${many}?view=browse&mode=table`],
  ['browse-filtered-none', `${demo}?view=browse&q=nothing-is-called-this`],
  ['item-image', `${demo}?view=browse&item=img-a.png`],
  ['item-boxes', `${boxes}?view=browse&item=frames/street.png`],
  // A link to an item this version does not hold: what does the page say?
  ['item-missing', `${boxes}?view=browse&item=frames/gone.png`],
  ['item-mask', '/d/e2e/datasets/masks?view=browse&item=frames/masked.png'],
  ['item-table-csv', `${tables}?view=browse&item=people.csv`],
  ['item-table-broken', `${media}?view=browse&item=broken.csv`],
  ['item-audio', `${media}?view=browse&item=tone.wav`],
  ['item-text', `${media}?view=browse&item=notes.txt`],
  ['browse-list', `${media}?view=browse&mode=list`],
  ['item-restricted', `${faces}?view=browse&item=person-01.png`],
  ['files-item-image', `${demo}?view=files&item=img-a.png`],
  ['files-item-audio', `${media}?view=files&item=tone.wav`],
  ['releases-files', `${demo}?view=releases`],
  ['releases-annotated', `${boxes}?view=releases&a=v1.0.0&b=v1.1.0`],
  ['releases-tables', `${tables}?view=releases&a=v1.0.0&b=v1.1.0`],
  ['releases-balance', '/d/e2e/datasets/attrs2?view=releases&a=v1.0.0&b=v1.1.0'],
  ['overview-balance', '/d/e2e/datasets/attrs2?release=v1.1.0'],
  ['health-annotated', '/d/e2e/datasets/attrs2?view=health&release=v1.1.0'],
  ['health-files', `${tables}?view=health`],
  ['sql-table', `${boxes}?view=browse&mode=sql&sql=${encodeURIComponent('SELECT class, count(*) AS boxes FROM annotations GROUP BY class ORDER BY boxes DESC')}`],
  ['sql-items', `${boxes}?view=browse&mode=sql&sql=${encodeURIComponent('SELECT path, hash, annotations FROM items')}`],
  ['sql-refused', `${boxes}?view=browse&mode=sql&sql=${encodeURIComponent('DELETE FROM items')}`],
  ['browse-gallery-pdf', '/d/e2e/datasets/docs?view=browse'],
  ['item-pdf', '/d/e2e/datasets/docs?view=browse&item=page.pdf'],
  ['item-clip', '/d/e2e/datasets/clips?view=browse&item=talk%2Fclip.wav'],
  ['item-spans', '/d/e2e/datasets/clips?view=browse&item=docs%2Fnotes.txt'],
  ['compare-tree', '/d/e2e/datasets/tree?view=releases&a=v1.0.0&b=v1.1.0'],
  ['compare-tree-open', '/d/e2e/datasets/tree?view=releases&a=v1.0.0&b=v1.1.0&dir=a'],
  ['item-attrs', '/d/e2e/datasets/attrs2?view=browse&release=v1.0.0&item=street%2Fhidden.png'],
  ['releases-same', `${demo}?view=releases&a=v1.0.0&b=v1.0.0`],
  ['files-root', `${demo}?view=files`],
  ['files-folder', `${many}?view=files&dir=rows`],
  ['activity', `${faces}?view=activity`],
  ['activity-filtered-none', `${faces}?view=activity&what=nothing`],
  ['keys', '/keys'],
  ['tokens', '/tokens'],
];

const widths = [1440, 1024, 390] as const;
const themes = ['light', 'dark'] as const;

type Finding = { page: string; theme: string; width: number; what: string };

// What a program can see is wrong: the page scrolls sideways, or something
// a person is meant to read or press reaches past the window's edge.
async function measure(page: import('@playwright/test').Page): Promise<string[]> {
  return page.evaluate(() => {
    const found: string[] = [];
    const wide = document.documentElement.scrollWidth - window.innerWidth;
    if (wide > 1) found.push(`the page is ${wide}px wider than the window`);
    const seen = new Set<string>();
    for (const el of document.querySelectorAll<HTMLElement>('a, button, select, input, h1, h2, th, td, p, label')) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      if (el.closest('.visually-hidden') || el.classList.contains('visually-hidden')) continue;
      // Inside something that scrolls sideways on purpose (a wide table).
      let scroller = el.parentElement;
      let scrolls = false;
      while (scroller) {
        const overflow = getComputedStyle(scroller).overflowX;
        if (overflow === 'auto' || overflow === 'scroll') scrolls = true;
        scroller = scroller.parentElement;
      }
      if (scrolls) continue;
      if (r.right > window.innerWidth + 1 || r.left < -1) {
        const name = `${el.tagName.toLowerCase()}${el.className ? `.${String(el.className).split(' ')[0]}` : ''}`;
        const text = (el.textContent ?? '').trim().slice(0, 40);
        const key = `${name} "${text}"`;
        if (!seen.has(key)) {
          seen.add(key);
          found.push(`${key} reaches ${Math.round(r.right - window.innerWidth)}px past the right edge`);
        }
      }
    }
    return found.slice(0, 8);
  });
}

// One test per theme and width, so a run cut short keeps what it took and
// says which sets are missing.
for (const theme of themes) {
  for (const width of widths) {
    test(`every page: ${theme}, ${width}px`, async ({ browser }) => {
      test.setTimeout(10 * 60_000);
      mkdirSync(out!, { recursive: true });
      const findings: Finding[] = [];
      const context = await browser.newContext({
        viewport: { width, height: 900 },
        colorScheme: theme,
        // Pictures of a page at rest: the sky does not drift between two shots.
        reducedMotion: 'reduce',
      });
      const page = await context.newPage();

      // Signed out first: the door itself.
      await page.goto('/signin');
      await page.waitForLoadState('networkidle');
      await page.screenshot({ path: join(out!, `signin.${theme}.${width}.png`), fullPage: true });
      for (const what of await measure(page)) findings.push({ page: 'signin', theme, width, what });

      await page.getByLabel(/server token|access token/i).fill(token);
      await page.getByRole('button', { name: 'Open the dashboard' }).click();
      await expect(page.getByRole('heading', { name: 'Datasets' })).toBeVisible();

      for (const [name, path] of pages) {
        await page.goto(path);
        await page.waitForLoadState('networkidle');
        // Pictures still arriving would be drawn as their placeholders. Lazy
        // ones below the fold never start on their own, so they are asked
        // for now; and no wait outlasts ten seconds.
        await page.evaluate(() => {
          const images = [...document.images];
          for (const i of images) if (i.loading === 'lazy') i.loading = 'eager';
          const loaded = Promise.all(
            images.filter((i) => !i.complete).map((i) => new Promise((done) => (i.onload = i.onerror = done))),
          );
          return Promise.race([loaded, new Promise((done) => setTimeout(done, 10_000))]);
        });
        await page.screenshot({ path: join(out!, `${name}.${theme}.${width}.png`), fullPage: true });
        for (const what of await measure(page)) findings.push({ page: name, theme, width, what });
      }
      await context.close();
      writeFileSync(join(out!, `measured.${theme}.${width}.json`), `${JSON.stringify(findings, null, 2)}\n`);
    });
  }
}
