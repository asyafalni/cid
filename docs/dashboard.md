# cid dashboard — product spec

**cid · Controlled Iterative Datasets**

The cid dashboard is the web face of cid: browse any dataset, see exactly what is in a
release, compare releases, check quality, and get the data. It must be a better
experience than Hugging Face dataset pages for the people who use our datasets.

Read with `CLAUDE.md` (rules, architecture, invariants). This file is the scope.
"Owner" on any page means the GitLab **Maintainer** role (see `docs/access.md`);
"version" means a release or commit, as shown in the version picker.

Keep cid's core idea visible in the product: **DVC lives inside git; git lives inside
cid.** The dashboard is where datasets live; each dataset's git repository is an
automatic, readable record of its releases, and every page links to it with "View in git".

---

## 1. What we learned from existing tools

### Hugging Face dataset pages (the bar to beat)

What they do well, and we must match:
- A viewer on every dataset page, with column histograms, click-to-filter, and text
  search across string columns. [1]
- A SQL console (DuckDB in the browser) and shareable links to individual rows. [1][2]
- Automatic Parquet conversion so data can be queried with pandas, Polars or DuckDB. [1]
- An embeddable viewer (iframe) with filters and selection in the URL. [1]

Where they fall short (our opportunities):

| Gap | Evidence |
|---|---|
| **The viewer often isn't available.** Full sorting/filtering/search only on the first 5 GB; bigger non-Parquet datasets show only 100 preview rows. | [1] |
| **One bad file breaks the whole viewer.** A CSV with a different number of columns, even in another folder, disabled the full viewer, with no clear error; the user had to guess which upload caused it. | [3] |
| **Large datasets crash the conversion job** ("Job manager crashed … missing heartbeats"), leaving an 11.7 GB dataset without a viewer. | [4] |
| **Datasets that need loading code get no viewer at all** ("requires arbitrary Python code execution"). | [5] |
| **Annotations are raw numbers, not pictures.** On WIDER FACE, boxes appear as `'bbox': [[178.0, 238.0, 55.0, 73.0], …]`; users must download and draw them locally. | [5] |
| **Table-first for everything.** Images, audio and text all live in 100-row table pages; there is no gallery, timeline or waveform view. | [1] |
| **No way to see what changed between versions.** History is git commits on files; comparing the data in two versions needs code. | [1] (viewer shows one revision) |
| **Private datasets need a paid plan to get a viewer.** | [1] |
| **Dataset cards are free-form Markdown**, often empty or out of date. | observed |

### Other tools worth borrowing from

| Tool | Idea to borrow |
|---|---|
| **Roboflow Health Check** | Image and annotation counts, missing/null annotations, class balance per split, image size and aspect-ratio chart, **annotation heat map** (where boxes sit in frames), objects-per-image histogram. [6] |
| **Kaggle Datasets** | A **usability score** that rewards complete metadata (description, file and column descriptions, license, provenance, cover image, examples), shown to the owner with what's missing. [7] |
| **DoltHub / Dolt Workbench** | Commit log, table browser, **cell-level diffs** between commits, pull requests with diff comments. [8][9] |
| **FiftyOne / Nomic Atlas** | Embedding maps: similar items cluster together; lasso a region to filter; find near-duplicates and outliers visually. [10][11] |

---

## 2. Principles (each one is testable)

1. **Never "viewer not available".** Every release has a browse view, whatever its
   size or format. A file cid can't preview shows as a file row with its size and type;
   one broken file affects only that file, and says why in plain words.
2. **Media-native, not table-first.** Images show as a gallery with annotations drawn
   on them. Audio shows a waveform with transcript segments. Video shows a player with a
   timeline of segments and tracks. Text shows spans highlighted. Tables show a real
   table with column statistics. PDFs show page thumbnails.
3. **Always pinned to a version.** Every page shows which release or commit you are
   looking at, with a picker like GitHub's branch picker. Nothing is "latest-ish".
4. **Every view is a link.** Release, filters, search, sort, selected item and zoom are
   in the URL. Pasting the link shows exactly the same thing.
5. **Fast at any size.** Browse data comes from the release manifest (Parquet, queried
   by DuckDB on the server) and pre-built thumbnails, never from scanning raw files.
6. **Changes are visible.** Any two versions can be compared, with before/after pictures
   for annotations and row-level diffs for tables.
7. **Getting the data is one copy-paste.** Every dataset and release shows the exact
   `cid clone` command, plus a Python snippet, with format and subset choices applied.
8. **Cards write themselves.** Counts, classes, splits, sizes, changes and quality
   numbers are filled from the manifest; people add only what a machine can't know
   (purpose, collection method, known gaps, license).
9. **Private by default, private for free.** Restricted datasets show blurred previews
   until the viewer chooses to reveal, and every reveal is logged. No paid tier for
   private viewing.
10. **Keyboard first, mouse friendly.** `j`/`k` or arrows move between items, `/`
    searches, `f` filters, `c` compares, `?` lists shortcuts.

---

## 3. Design language: "the engineer's airship"

**Mood in one line:** a master engineer's workshop aboard a beautiful airship at dusk.
Every instrument is precise and readable, every surface is crafted, and the sky beyond
is breathtaking. Techy and nerdy up close; beautiful from a distance.

All of it is original. Nothing from Final Fantasy or Square Enix (see the name rule in
`CLAUDE.md`): no logos, characters, fonts, menu windows, cursors, crystals, airship
designs, sounds or music.

### 3.1 The workshop (techy and nerdy)

- **Instrument readouts.** Numbers, sizes, hashes, IDs and timestamps are in monospace,
  always with units. Hashes appear as short chips (`a3f9c1`) that copy the full hash on
  click.
- **Blueprint layer.** A faint technical grid behind empty canvases and the Overview
  header; blueprint-style corner marks on hero cards; schematic line icons (1.5 px
  stroke, square caps).
- **Gauges for quality.** Accuracy as an arc gauge, missed objects as a meter with a
  target line. The number is always printed; the gauge only supports it.
- **Every action shows its command.** A "Show command" toggle on every action and page
  reveals the exact `cid` command that does the same thing, ready to copy. It teaches
  the CLI and makes the dashboard scriptable.
- **Command palette** (`⌘K` / `Ctrl-K`): jump to any dataset, release, item or action by
  typing.
- **Ship's log.** The Activity page reads like telemetry: monospace timestamps, one event
  per line, filterable.
- **Two small easter eggs, no more:** `cid --version` prints a small original ASCII
  airship; the 404 page is "Lost in the clouds" with an original illustration and a
  search box.
- **Tagline.** In the product UI, "cid · Controlled Iterative Datasets" appears in
  exactly three places: the sign-in page under the wordmark, the footer (next to the
  version), and the line under the ASCII airship in `cid --version`. (The README and
  docs home also carry it, as text; this rule is about the product.) The wordmark itself is always lower case `cid`,
  set in Fraunces; the tagline is IBM Plex Sans in the muted text color.

### 3.2 The sky (beautiful)

- **Themes:** "Night flight" (dark, the default) and "Daybreak" (light).
- **Sky gradients only where there is no data:** page headers, the release hero, empty
  states, the sign-in page. Never behind images, tables or charts.
- **Glass over sky:** header panels over the sky are slightly translucent with a thin
  luminous top edge; every other panel is solid.
- **Two accents with jobs:** *aether* (cool cyan) for anything interactive and for focus;
  *brass* (warm gold) for releases, badges and crafted details. Neither is ever the only
  carrier of meaning.
- **Type:** a characterful serif for large headings only (Fraunces), a calm sans for UI
  (IBM Plex Sans), monospace for data (JetBrains Mono). Headings are rare and large; UI
  text stays quiet.
- **Motion, airship-smooth:** 180–240 ms ease-out for transitions; focus glow fades in;
  a very slow cloud drift on the release hero; publishing a release plays a short
  "launch" (the badge rises, under 800 ms, skippable). With
  `prefers-reduced-motion`, all of it is off.
- **Illustrations** (airships, gears, clouds, blueprints) are original, made in-house or
  commissioned.

### 3.3 Starting tokens

Validate contrast (WCAG AA) and run the categorical class palette through the dataviz
validator before shipping; adjust values, keep roles.

| Token | Night flight | Daybreak |
|---|---|---|
| `bg` | `#0B1020` | `#F5F2EA` |
| `panel` | `#121A30` | `#FFFFFF` |
| `panel-raised` | `#19233F` | `#FBF9F4` |
| `line` | `#26314F` | `#D9D3C4` |
| `text` | `#E8ECF6` | `#1A2033` |
| `text-muted` | `#A2ACC6` | `#545B70` |
| `aether` (interactive, focus) | `#5BD8E0` | `#0E7C86` |
| `brass` (releases, craft) | `#D9A845` | `#9A6B12` |
| `sky` (gradient) | `#1B2A5A → #6B4E8C → #E08A5B` | `#BFD9F2 → #F6E3C8` |
| `pass` / `warn` / `fail` | `#4CC38A` / `#F2B84B` / `#FF7A66` | `#1E7F52` / `#8A5A00` / `#B3261E` |

Status colours always come with an icon and a word. Annotation class colours come from
the shared categorical palette (same as the annotation platform), never from the sky or
accent colours.

### 3.4 Rules that keep beauty from hurting use

- Data areas are calm: solid panels, no gradients, glow or texture behind images,
  tables or charts.
- At most one decorative element per screen region.
- Decoration never delays content: if an effect adds more than 100 ms to first paint
  or drops scrolling below 60 fps, it goes.
- Both themes pass WCAG 2.2 AA and the axe checks in CI.

---

## 4. Pages

### 4.1 Datasets (home)
- Cards: thumbnail mosaic (or a type icon for non-visual data), name, kind (file or
  annotated), media types, latest release, size, health badge, last activity.
  Built as rows rather than a grid (a manifest reads downward), each row the card.
  The counts come from the head commit's `stats`: one SQL aggregate (items, bytes,
  types, splits, classes, newest policy), computed once per commit and kept on it, so
  the page costs one query however many people open it, at any dataset size. The
  overview and the dataset repository read the same statistics. A restricted
  dataset shows type tiles, never a clear thumbnail.
- Search by name, description, class, media type, owner. Filters: media type, kind,
  restricted, has releases. All in the URL.
- "Recently viewed" and "Starred" rows. Recently viewed lives in the viewer's browser;
  a star is kept on the server for the signed-in person (`stars`), so the server token,
  which is nobody, cannot star. Owners are the Maintainers, shown and searchable by name.
- *Waiting on other slices, absent rather than broken:* the health badge (Health tab
  and the Validator) and searching descriptions (card editing).

### 4.2 Dataset › Overview
- Header: name, version picker, `cid clone` copy button, owners, restricted badge, and a
  **"View in git"** link to the dataset repository (with its git status: up to date or
  pending).
- The auto dataset card here and the dataset repository's `README.md` come from the same
  renderer, so they never disagree. Every link in the git README lands on the matching
  dashboard page, pinned to that release.
- **Auto dataset card:** summary counts, class table (with index), split sizes, media
  types and sizes, policy version (annotated datasets), last release notes, known gaps.
- **Card completeness** (owner-only): a checklist like Kaggle's usability score: purpose,
  collection method, license, provenance, known gaps, cover image, column descriptions.
- **Sample strip:** a random but stable sample of items, rendered media-native.
- **Use this dataset:** format picker, split/class subset picker (the same
  `--split`/`--class` flags `cid clone` takes, so the subset is real), and the resulting
  `cid clone …` command; the download size, summed exactly from the pinned release's
  items rather than estimated; and a Python snippet that loads the folder the command
  writes (ultralytics for yolo, `json` for jsonl, `pathlib` for files). cid ships no
  Python package; the snippet is documentation shaped as code. The command uses
  the SSH address, e.g.
  `cid clone cid@cidhub.com:your-org/datasets/person-vehicle --release v5.0.0 --format yolo`,
  so it works as pasted with no login.

### 4.3 Dataset › Browse (the viewer)
- **Views:** Gallery (images, video, PDFs), List (audio, text), Table (tabular and any
  dataset as rows). Toggle with `g` / `l` / `t`.
- **Annotation overlays:** boxes, polygons, points/keypoints, masks, identities, drawn on
  the media; toggle per class; opacity slider; labels on hover.
- **Filters:** class, split, attributes, annotation count, size, source (camera, video,
  feed), author (agent/human), policy version, changed since release X. Histograms are
  clickable filters, like Hugging Face's, for every numeric column and attribute.
- **Search:** text search on text fields and file paths; semantic search ("forklift at
  night", or "more like this item") when an embedding service is configured.
- **Item drawer:** large media with annotations, all fields, file path and hash,
  provenance (source video/camera/feed alert, agent or reviewer, policy rule), and the
  item's **history** (every change, with before/after).
- **Virtualised infinite scroll**; no 100-row pages.
- **SQL console** (Phase 2): DuckDB SQL against the release manifest, results as a
  table and, for items, as a gallery. The console is sandboxed, non-negotiably:
  `enable_external_access = false` with the setting locked, only the manifest views
  attached (never raw files, never other datasets), per-query time and memory limits,
  and read-only. Restricted datasets get no SQL console until it obeys the same blur
  and reveal rules as the gallery.

### 4.4 Dataset › Releases & history
- Timeline of releases and commits (release notes, author, counts, quality numbers),
  each release with its git commit link and git status. A release touched by
  `cid admin purge` shows "intact except N purged items", with the affected paths.
- **Compare** any two versions:
  - Summary: items added/removed/changed, annotations added/removed/changed, per class.
  - Visual diff: gallery of changed items with before/after overlays side by side.
  - Table diff: row-level added/removed/changed cells for CSV, Parquet, JSONL (like
    Dolt's cell diffs).
  - Files diff for file datasets: tree with added/removed/changed markers.

### 4.5 Dataset › Health
- Annotated datasets: class balance per split, objects per item, object size
  distribution, **annotation heat map**, aspect ratios, items without annotations,
  near-duplicates across splits, split leakage (same source in two splits), estimated
  miss rate and audited accuracy (from the Validator — the annotation platform's
  quality-audit service; when no Validator reports exist, those tiles are absent, not
  broken), label-error candidates linked to the item drawer.
- File datasets: file types and sizes, table column stats (nulls, distinct values,
  ranges), schema changes between releases.
- Each check shows pass / warning / fail with an icon and words, never color alone.

### 4.6 Dataset › Files (file datasets)
- Folder tree with sizes, types and last change; preview panel per file type; download
  link per file; path is part of the URL.

### 4.7 Activity
- Who pushed, tagged, merged or changed what, per dataset. Restricted-data reveals are
  listed for owners.

---

## 5. Out of scope

- Editing annotations in the dashboard (that is the annotation platform's job). The
  dashboard only edits dataset cards and creates releases (owners).
- Social features: likes, trending, follower counts, public community discussions.
- Notebooks, model hosting, training.
- A public hub for other organisations.

---

## 6. Architecture

- **Frontend:** React + Vite + TypeScript, built to static files and **embedded in the
  cid server binary** (`@embedFile`), so deployment stays one binary. TanStack Router
  (URL state) and TanStack Query; TanStack Virtual for the gallery and tables; a
  WebGL canvas (PixiJS) for dense annotation overlays, **lazy-loaded** on first use so
  it stays out of the first-load bundle; the three fonts are **self-hosted** (subset,
  embedded), never fetched from Google Fonts; charts follow the dataviz rules
  (one axis, fixed class colours shared with the annotation platform, text never in
  series colour, legend for 2+ series).
- **Design:** tokens and rules from section 3, kept in `web/src/theme/`. The annotation
  platform can adopt the same tokens so both feel like one product. WCAG 2.2 AA.
- **Browse API** (in `cid serve`, `GET …/-/browse?commit=…`): one page of a version —
  items with their annotations, total and matched counts, the split/class/type facets
  (each counted against the other filters), the class counts, a cursor, and the open
  item. The server build answers with DuckDB from the version's browse index, two
  Parquet files (items in path order; annotations by item, never nested into item
  rows): written in the same pass as a release's manifest and kept in storage beside
  it, built from TimescaleDB state-at-commit on first view for any other commit, cached
  on the server's disk by commit id (commits are sealed, so an index never goes stale). Media
  metadata is joined per page, because the worker fills it in after ingest. The CLI
  build answers the same contract from state rows. Thumbnails come per page, as
  presigned URLs; the gallery loads the next page as the end scrolls into view.
- **Preview worker** (`cid admin previews`): builds thumbnails (WebP), audio waveform
  peaks, video poster frames and short previews, PDF page thumbnails, and per-file
  table statistics, when items are pushed or registered. It calls **ffmpeg** and
  **libvips** as external programs, so the cid binary itself gains no new C libraries.
  **Generation is ingest-driven, never request-driven**: a page view can only read
  previews that exist (or show a placeholder), so a thousand concurrent viewers cost
  object reads, not ffmpeg runs. The queue is keyed by content hash — one build per
  item ever, bounded retries, broken files skipped with the reason on record.
  Previews are stored in SeaweedFS by item hash and never re-built. For restricted
  items the worker **also stores a blurred rendition**, and that is the only preview
  the browse API will presign until the viewer hits the reveal endpoint — which logs
  the reveal (`activity_events`) and only then returns the clear URL. Client-side
  blur is forbidden: a presigned URL to the clear image *is* the content.
- **Sign-in:** "Sign in with GitLab" (OAuth, scope `read_user`, PKCE), the same
  `gitlab:<id>` account and roles the SSH front door uses, so the dashboard and the CLI
  always agree on who may see what. The session holds identity only; every request is
  checked against the `access` table, so a person sees exactly the datasets their
  GitLab role lets them read. Session cookie: nilo's sealed `__Host-session`, HttpOnly,
  Secure, SameSite=Lax, 12-hour expiry sealed inside it, nothing stored on the server.
  Configure with `CID_GITLAB_OAUTH_ID`, `CID_GITLAB_OAUTH_SECRET`, `CID_PUBLIC_URL`
  (the GitLab application's redirect URI is `<it>/auth/gitlab/callback`) and
  `CID_SESSION_SECRET` (32 bytes, base64). Where there is no GitLab, the server token
  signs in (email one-time links are "not now", `docs/access.md`).
- **Health data** comes from the Validator's reports and from the manifest; the
  dashboard never recomputes heavy statistics on page load.
- **Semantic search** (Phase 3) calls an external embedding service over HTTP (e.g.
  the annotation platform's embedder); vectors stored with pgvector in TimescaleDB.
  If no service is configured, the feature is hidden, not broken. **Restricted
  datasets are excluded by default**: their items go to no external embedder and
  their vectors are never stored unless an owner explicitly enables it per dataset —
  an embedding of a face is biometric data.

---

## 7. Performance and quality budgets

| Measure | Budget |
|---|---|
| Overview page, first meaningful paint (p75, office network) | < 1.0 s |
| Browse: first 60 thumbnails visible after filter change | < 700 ms at 1M items |
| Gallery scrolling | 60 fps, no blank tiles after 200 ms |
| Item drawer open | < 300 ms |
| Compare two releases, summary visible | < 2 s at 1M annotations |
| JS bundle, first load | < 300 KB gzipped |
| Accessibility | WCAG 2.2 AA; full keyboard navigation |

Measured in CI with Playwright against a seeded dataset of 1M items.

---

## 8. Delivery phases

**Phase 1 — useful on day one**
Datasets home · Overview with auto card and "Use this dataset" · Browse for images and
tables (gallery + table, overlays for box/polygon/points/mask, filters, item drawer
with history) · Releases timeline and compare (summary + visual diff) · Files tab ·
shareable URLs · restricted blur and reveal log · preview worker for images and tables.

*Delivered ahead of Phase 2:* table statistics. A CSV, Parquet or JSONL item opens as a
table in the drawer: rows, per-column type, range, distinct count and nulls, and its
first rows, built once per content hash by the preview worker in the server build.
A restricted dataset shows the shape only (rows, names, types, nulls) until a logged
reveal; a CLI-build server says the view needs the server build.

**Phase 2 — every media type**
Audio (waveform + transcript segments), video (player + segment/track timeline), text
(span highlights), PDFs · Health tab · row-level table diff · SQL console · card
completeness checklist · keyboard shortcuts everywhere.

*Built:* the row-level table diff. Compare shows, under each modified CSV, Parquet or
JSONL file, its rows added and removed, with the rows themselves one click away (the
first 20 each way); it is the same answer `cid diff` prints. Whole-row comparison
until a dataset can declare a key, so cell-level "changed" waits for that.

**Phase 3 — find anything**
Semantic search and "more like this" · embedding map with lasso filter · near-duplicate
and outlier explorer · saved views.

*Phase 3 maybe, decided then, not now:* advisory AI judgments (TypeSafe/Jev) for
card-quality scoring or ranking label-error candidates — hidden when unconfigured,
advisory only, and never fed restricted content. Nothing in cid's core ever calls an
AI service (see non-goals in `CLAUDE.md`).

---

## 9. Acceptance tests (UX)

- A 50 GB dataset with one malformed CSV: browse works; the bad file shows its own
  error; nothing else is affected.
- A detection dataset: boxes are drawn on images in the gallery and drawer.
- Any view's URL, opened in a new browser, shows the same release, filters and item.
- Compare two releases: a changed box shows before and after on the same image.
- The `cid clone` command copied from "Use this dataset" works as pasted.
- For every action, "Show command" gives a `cid` command that does the same thing when
  run in a terminal.
- With reduced motion on, no animation plays; both themes pass contrast checks.
- A restricted dataset: previews blurred until revealed; the reveal appears in Activity.
- Every page passes automated accessibility checks (axe) and full keyboard use.

---

## Sources

Competitor claims (the 5 GB viewer limit, 100-row previews, paid private viewers) were
checked in 2025–2026 and move over time — **re-verify against the live products before
using any of them in marketing or docs.**

1. Hugging Face, Data Studio / Dataset Viewer docs — https://huggingface.co/docs/hub/data-studio ,
   https://huggingface.co/docs/hub/datasets-viewer
2. Hugging Face, SQL Console — https://huggingface.co/docs/hub/datasets-viewer-sql-console
3. HF forum: "The full dataset viewer is not available … only showing a preview" —
   https://discuss.huggingface.co/t/the-full-dataset-viewer-is-not-available-click-to-read-why-only-showing-a-preview-of-the-rows/153590
4. huggingface/datasets issue #8178 — https://github.com/huggingface/datasets/issues/8178
5. CUHK-CSE/wider_face on the Hub — https://huggingface.co/datasets/CUHK-CSE/wider_face
6. Roboflow, Dataset Health Check — https://docs.roboflow.com/datasets/versions/dataset-health-check
7. Kaggle, Usability Rating — https://www.kaggle.com/product-feedback/93922 ,
   https://www.kaggle.com/product-feedback/372061
8. DoltHub, Pull Requests — https://docs.dolthub.com/concepts/dolthub/prs
9. DoltHub, Dolt Workbench — https://www.dolthub.com/blog/2023-11-29-dolt-workbench/
10. Voxel51, FiftyOne App — https://docs.voxel51.com/user_guide/app.html
11. Nomic Atlas, visualizing embeddings —
    https://docs.nomic.ai/atlas/embeddings-and-retrieval/guides/how-to-visualize-embeddings
