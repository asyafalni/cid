# cid dashboard — product spec

**cid · Controlled Iterative Datasets**

The cid dashboard is the web face of cid: browse any dataset, see exactly what is in a
release, compare releases, check quality, and get the data. It must be a better
experience than Hugging Face dataset pages for the people who use our datasets.

Read with `CLAUDE.md` (rules, architecture, invariants). This file is the scope: the
principles and design language are the bar, the page sections are the spec, and each
section says what is built and what is not yet. "Owner" on any page means the GitLab
**Maintainer** role (see `docs/access.md`); "version" means a release or commit, as
shown in the release tape.

Keep cid's core idea visible in the product: **DVC lives inside git; git lives inside
cid.** The dashboard is where datasets live; each dataset's git repository is an
automatic, readable record of its releases, and every dataset page links to it with
"view in git".

**The dashboard is view-only.** It changes no data. Stars are per-person bookmarks, not
data, and a person's SSH keys and tokens are their own identity, not data (invariant
17). Editing the dataset card and making releases from the dashboard are parked
decisions: the server has `GET`/`PUT …/-/card` (owners only for `PUT`), but the
dashboard has no UI for it.

## Status at a glance

**Built:** sign-in (GitLab OAuth or the server token); Datasets home (rows, search,
filters, stars, recently viewed); the dataset page with five tabs (Overview, Browse,
Releases, Files, Activity) and the release tape; the auto card's counts, class table
and split sizes; "Use this dataset" (formats `files`, `jsonl`, `yolo`; split/class
subset; exact size; Python snippet); Browse gallery and table, virtualised, with
path/split/class/type filters in the URL, SVG overlays for box, polygon and points,
masks painted to a canvas, the item drawer with history, table statistics, text,
audio and video; Compare (totals, change list, visual before/after, row-level table
diff); Files tab (folder tree, sizes, download); Activity (owners only); restricted
blur and logged reveal; your SSH keys and personal tokens; the preview worker (ffmpeg
only).

**Not built yet** (the spec below says so where it applies): the health badge, Health
tab and Validator tiles; card completeness and the sample strip; most Browse filters,
histograms and the List view; keyboard shortcuts beyond `g`/`t`; the "Show command"
toggle; the `⌘K` palette; the 404 page; a theme switch; charts and gauges; PDF page
images (`vips`); viewing branches or pinning a commit; the SQL console; semantic
search.

**Parked, needs a decision first:** editing the card and making releases from the
dashboard.

**Known gap:** the Overview card's counts are the head of `main`, whatever release the
page is pinned to (principle 3). The subset size in "Use this dataset" is the pinned
release's.

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

These are the bar every page is held to. Where a page does not meet one yet, its
section in §4 says so.

1. **Never "viewer not available".** Every release has a browse view, whatever its
   size or format. A file cid can't preview shows as a file row with its size and type;
   one broken file affects only that file, and says why in plain words.
2. **Media-native, not table-first.** Images show as a gallery with annotations drawn
   on them. Audio shows a waveform with transcript segments. Video shows a player with a
   timeline of segments and tracks. Text shows spans highlighted. Tables show a real
   table with column statistics. PDFs show page thumbnails.
3. **Always pinned to a version.** Every page shows which release or commit you are
   looking at, with a picker like GitHub's branch picker. Nothing is "latest-ish".
   *Built:* the release tape pins a release. *Known gap:* the Overview card's counts
   show `main`'s head whatever release is pinned.
4. **Every view is a link.** Release, filters, search, sort, selected item and zoom are
   in the URL. Pasting the link shows exactly the same thing. *Built:* tab, release,
   filters, path search, open item, open folder, compare pair and table mode. Sort and
   zoom do not exist yet; when they do, they go in the URL too.
5. **Fast at any size.** Browse data comes from the release manifest (Parquet, queried
   by DuckDB on the server) and pre-built thumbnails, never from scanning raw files.
6. **Changes are visible.** Any two versions can be compared, with before/after pictures
   for annotations and row-level diffs for tables.
7. **Getting the data is one copy-paste.** Every dataset and release shows the exact
   `cid clone` command, plus a Python snippet, with format and subset choices applied.
8. **Cards write themselves.** Counts, classes, splits, sizes, changes and quality
   numbers are filled from the manifest; people add only what a machine can't know
   (purpose, collection method, known gaps, license). *Built so far:* counts, the
   class table and split sizes.
9. **Private by default, private for free.** Restricted datasets show blurred previews
   until the viewer chooses to reveal, and every reveal is logged. No paid tier for
   private viewing.
10. **Keyboard first, mouse friendly.** `j`/`k` or arrows move between items, `/`
    searches, `f` filters, `c` compares, `?` lists shortcuts. *Built so far:* `g`
    (gallery) and `t` (table) in Browse, and every control reachable by Tab; the rest
    are planned.

---

## 3. Design language: "the engineer's airship"

**Mood in one line:** a master engineer's workshop aboard a beautiful airship at dusk.
Every instrument is precise and readable, every surface is crafted, and the sky beyond
is breathtaking. Techy and nerdy up close; beautiful from a distance.

All of it is original. Nothing from Final Fantasy or Square Enix (see the name rule in
`CLAUDE.md`): no logos, characters, fonts, menu windows, cursors, crystals, airship
designs, sounds or music.

This section is the design target. Built so far: the tokens, the three self-hosted
fonts, instrument readouts with copyable hash chips, the blueprint grid on empty
states, the sky band on dataset headers and the sign-in page, the brass release tape,
the tagline in its three places, and the reduced-motion switch. Items marked
*Planned* are not built.

### 3.1 The workshop (techy and nerdy)

- **Instrument readouts.** Numbers, sizes, hashes, IDs and timestamps are in monospace,
  always with units. Hashes appear as short chips (`a3f9c1`) that copy the full hash on
  click.
- **Blueprint layer.** A faint technical grid behind empty canvases (built: empty
  states and the empty tape). *Planned:* the grid behind the Overview header,
  blueprint-style corner marks on hero cards, schematic line icons (1.5 px stroke,
  square caps).
- *Planned:* **Gauges for quality.** Accuracy as an arc gauge, missed objects as a
  meter with a target line. The number is always printed; the gauge only supports it.
  Arrives with the Health tab.
- *Planned:* **Every action shows its command.** A "Show command" toggle on every
  action and page reveals the exact `cid` command that does the same thing, ready to
  copy. It teaches the CLI and makes the dashboard scriptable. Today only "Use this
  dataset" shows a command (its `cid clone` line).
- *Planned:* **Command palette** (`⌘K` / `Ctrl-K`): jump to any dataset, release, item
  or action by typing.
- **Ship's log.** The Activity page reads like telemetry: monospace timestamps, one
  event per line. *Planned:* filtering.
- **Two small easter eggs, no more:** `cid --version` prints a small original ASCII
  airship (built); *planned:* the 404 page is "Lost in the clouds" with an original
  illustration and a search box (today an unknown address has no page of its own).
- **Tagline.** In the product UI, "cid · Controlled Iterative Datasets" appears in
  exactly three places: the sign-in page under the wordmark, the footer (next to the
  version), and the line under the ASCII airship in `cid --version`. (The README and
  docs home also carry it, as text; this rule is about the product.) The wordmark itself is always lower case `cid`,
  set in Fraunces; the tagline is IBM Plex Sans in the muted text color.

### 3.2 The sky (beautiful)

- **Themes:** "Night flight" (dark) and "Daybreak" (light). The theme follows the
  system's colour-scheme preference, and is Night flight when there is none. There is
  no switch in the UI yet (the tokens already honour a `data-theme` attribute on the
  root).
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
- **Motion, airship-smooth:** 180–240 ms ease-out for transitions; focus glow fades in.
  With `prefers-reduced-motion`, all of it is off (built: a global switch that stops
  every animation and transition). *Planned:* a very slow cloud drift on the release
  hero. A "launch" animation for publishing a release waits on the parked decision to
  make releases from the dashboard.
- **Illustrations** (airships, gears, clouds, blueprints) are original, made in-house or
  commissioned.

### 3.3 Tokens

The shipped values, from `web/src/theme/tokens.css`. Change values there and here
together; keep the roles. Contrast is checked by the axe run in the e2e suite (see
§3.4 for which theme).

| Token | Night flight | Daybreak |
|---|---|---|
| `bg` | `#0B1020` | `#F5F2EA` |
| `panel` | `#121A30` | `#FFFFFF` |
| `panel-raised` | `#19233F` | `#FBF9F4` |
| `line` | `#26314F` | `#D9D3C4` |
| `text` | `#E8ECF6` | `#1A2033` |
| `text-muted` | `#A2ACC6` | `#545B70` |
| `aether` (interactive, focus) | `#5BD8E0` | `#0C717A` (5.1:1 on `bg`) |
| `brass` (releases, craft) | `#D9A845` | `#875D0F` (5.2:1 on `bg`) |
| `sky-1 → sky-2 → sky-3` (gradient) | `#1B2A5A → #6B4E8C → #E08A5B` | `#BFD9F2 → #DCD2E4 → #F6E3C8` |
| `pass` / `warn` / `fail` | `#4CC38A` / `#F2B84B` / `#FF7A66` | `#1E7F52` / `#8A5A00` / `#B3261E` |
| `ann-1` … `ann-8` (overlay classes) | `#5BD8E0` `#FFB454` `#8BE28B` `#FF8FB2` `#B7A5FF` `#FFE066` `#7FB8FF` `#FF9D7A` | `#0C717A` `#A35B00` `#1E7F52` `#B03060` `#5F4BB6` `#8A6D00` `#205FA8` `#B34A22` |

Status colours always come with an icon and a word. Overlay classes map onto the eight
`ann-*` hues deterministically by class name, and the class is always named in a chip
and tooltip, never by colour alone. *Planned:* share one categorical class palette
with the annotation platform, validated with the dataviz validator; the `ann-*` hues
are cid's own for now.

### 3.4 Rules that keep beauty from hurting use

- Data areas are calm: solid panels, no gradients, glow or texture behind images,
  tables or charts.
- At most one decorative element per screen region.
- Decoration never delays content: if an effect adds more than 100 ms to first paint
  or drops scrolling below 60 fps, it goes.
- Both themes pass WCAG 2.2 AA and the axe checks. Today the axe test in
  `web/e2e/dashboard.spec.ts` runs in Playwright's default light colour scheme, so it
  checks Daybreak; Night flight is not yet checked automatically. There is no CI yet;
  the e2e suite runs by hand.

---

## 4. Pages

### 4.1 Datasets (home)
- Cards: thumbnail mosaic (or a type tile for non-visual data), name, kind (file or
  annotated), file types, item and class counts, size, owners, restricted badge, star,
  latest release, date of the last push. Built as rows rather than a grid (a manifest reads downward), each row the
  card.
  The counts come from the head commit's `stats`: one SQL aggregate (items, bytes,
  types, splits, classes, newest policy), computed once per commit and kept on it, so
  the page costs one query however many people open it, at any dataset size. The
  overview and the dataset repository read the same statistics. A restricted
  dataset shows type tiles, never a clear thumbnail.
- Search by name, class, file type and owner. Filters: file type, kind, has releases,
  restricted (shown only when some dataset is restricted). All in the URL.
- "Recently viewed" and "Starred" rows. Recently viewed lives in the viewer's browser;
  a star is a per-person bookmark kept on the server for the signed-in person
  (`stars`), so the server token, which is nobody, cannot star. Owners are the
  Maintainers, shown and searchable by name.
- *Not built yet:* the health badge (it needs the Health tab and the Validator).
  Searching descriptions waits on card editing, which is a parked decision.

### 4.2 Dataset › Overview

Every dataset page (all five tabs) shares one header and the release tape.

- **Header** (built): name, kind (file or annotated), and a plain **"view in git"** link
  to the dataset repository. The `cid clone` command lives in "Use this dataset";
  owners show on the home row; the restricted badge shows in Browse. *Planned:* owners
  and the restricted badge in the header, and the repository's git status (up to date
  or pending).
- **Release tape** (built): the history of `main`, newest 100 commits, oldest on the
  left. Each release is a button that pins the page to it (`?release=` in the URL);
  with none chosen, the newest release is pinned. Commits are ticks that show their
  message and author on hover but cannot be picked. *Not built yet:* pinning a commit,
  and viewing branches (the tape shows `main` only).
- The auto card here and the dataset repository's `README.md` are separate renderers
  that read the same commit statistics (`stats`), so their numbers agree. Every link
  in the git README lands on the dashboard pinned to that release.
- **Auto dataset card.** *Built:* item count and size, class count, the class table
  (with index), split sizes. *Known gap:* these counts are
  `main`'s head, not the pinned release. *Planned:* media types and sizes, policy
  version (annotated datasets), last release notes, and the owners' own words
  (purpose, collection method, known gaps), which wait on card editing, a parked
  decision.
- *Planned:* **Card completeness** (owner-only): a checklist like Kaggle's usability
  score: purpose, collection method, license, provenance, known gaps, cover image,
  column descriptions. Depends on card editing.
- *Planned:* **Sample strip:** a random but stable sample of items, rendered
  media-native.
- **Use this dataset** (built): format picker (`files`, `jsonl`, `yolo` for annotated
  datasets, `files` only for file datasets; `coco` and `voc` exports do not exist
  yet), split/class subset picker (the same
  `--split`/`--class` flags `cid clone` takes, so the subset is real), and the resulting
  `cid clone …` command; the download size, summed exactly from the pinned release's
  items rather than estimated; and a Python snippet that loads the folder the command
  writes (ultralytics for yolo, `json` for jsonl, `pathlib` for files). cid ships no
  Python package; the snippet is documentation shaped as code. The command uses
  the SSH address, e.g.
  `cid clone cid@cidhub.com:your-org/datasets/person-vehicle --release v5.0.0 --format yolo`,
  so it works as pasted with no login.

### 4.3 Dataset › Browse (the viewer)
- **Views.** *Built:* Gallery (every item: a thumbnail where the worker built one —
  images, video posters, audio waveforms — else a type tile) and Table (any dataset as
  rows), toggled with `g` / `t`; table mode is in the URL. *Planned:* a List view for
  audio and text, on `l`.
- **Annotation overlays.** *Built:* boxes, polygons and points drawn as SVG over the
  media, masks (including COCO RLE) painted once into a canvas in the class colour;
  toggle per class; opacity slider; labels on hover. A shape that does not parse loses
  only itself. *Planned:* identities.
- **Filters.** *Built:* path contains, split, class and file type, each a facet counted
  against the other filters, all in the URL. *Planned:* attributes, annotation count,
  size, source (camera, video, feed), author (agent/human), policy version, changed
  since release X, and histograms as clickable filters, like Hugging Face's, for every
  numeric column and attribute.
- **Search.** *Built:* file paths ("path contains"). *Planned:* text search on text
  fields; semantic search ("forklift at night", or "more like this item") when an
  embedding service is configured (Phase 3).
- **Item drawer.** *Built:* large media with annotations (or the audio player beside
  its waveform, the video player with its poster, a table's statistics and first rows,
  a text file's first 64 KB, or "binary" in words); size, split, dimensions and the
  hash as a copyable chip; the annotation list; and the item's **history** (every
  change to the file and its annotations, by whom, in which release). In a restricted
  dataset the clear media, table rows and text come only after a logged reveal.
  *Planned:* provenance (source video/camera/feed alert, agent or reviewer, policy
  rule) and attribute fields.
- **Virtualised infinite scroll** (built): the next page loads as its button scrolls
  into view; no 100-row pages.
- *Phase 2, not built:* **SQL console**: DuckDB SQL against the release manifest,
  results as a table and, for items, as a gallery. The console is sandboxed, non-negotiably:
  `enable_external_access = false` with the setting locked, only the manifest views
  attached (never raw files, never other datasets), per-query time and memory limits,
  and read-only. Restricted datasets get no SQL console until it obeys the same blur
  and reveal rules as the gallery.

### 4.4 Dataset › Releases & history
- **Timeline.** *Built:* the same `main` commits as the tape, newest first, each with
  its release tag (if any), message, date, author and commit id. *Planned:* release
  notes, counts and quality numbers per release, each release's git commit link and
  git status, and, for a release touched by `cid admin purge`, "intact except N purged
  items" with the affected paths.
- **Compare** any two versions on `main` (releases or commits, picked as A and B; the
  pair is in the URL; by default the two newest releases):
  - Summary (built): items added/modified/deleted and, for annotated datasets,
    annotations added/changed/removed, as totals. *Planned:* the same per class.
  - Change list (built): a flat list of changed paths with their sizes, small
    before/after thumbnails for modified pictures, a page at a time; the first
    annotation changes, with `cid diff` named for the rest. *Planned:* a folder tree
    with added/removed/changed markers for file datasets.
  - Visual diff (built): changed items with before (dashed) and after (solid)
    overlays side by side.
  - Table diff (built): under each modified CSV, Parquet or JSONL file, rows added and
    removed, with the first 20 each way one click away; the same answer `cid diff`
    prints. Whole-row comparison until a dataset can declare a key, so cell-level
    "changed" (like Dolt's cell diffs) waits for that. A restricted dataset gets
    counts and columns, never rows.

### 4.5 Dataset › Health (Phase 2: not built)

There is no Health tab yet. Per-file table statistics already exist (in the drawer,
§4.3); everything below is planned.

- Annotated datasets: class balance per split, objects per item, object size
  distribution, **annotation heat map**, aspect ratios, items without annotations,
  near-duplicates across splits, split leakage (same source in two splits), estimated
  miss rate and audited accuracy (from the Validator — the annotation platform's
  quality-audit service; when no Validator reports exist, those tiles are absent, not
  broken), label-error candidates linked to the item drawer.
- File datasets: file types and sizes, table column stats (nulls, distinct values,
  ranges), schema changes between releases.
- Each check shows pass / warning / fail with an icon and words, never color alone.

### 4.6 Dataset › Files
- *Built:* shown for every dataset, file or annotated. The folder tree exactly as
  committed, one folder at a time: subfolders with their counts, then the folder's
  files a page at a time, each with its size and a download link. The open folder is
  part of the URL.
- *Planned:* file types and last change per file, and a preview panel per file type
  (today, previews open in Browse's drawer).

### 4.7 Activity
- *Built:* the dataset's log, newest first, the last 200 events: when (UTC), who, what
  and which. It records push, commit (server-side, from the annotation platform), tag,
  branch, merge, card-edit (through the API), reveal and purge, and in a restricted
  dataset every read of its content: download, browse (a view opened), compare and
  export (the item list or an export a clone reads). It names who read restricted
  content, so only owners can read it; anyone else is told so in words.
- *Planned:* filtering.

### 4.8 Your SSH keys

- *Built:* `/keys`, linked from the rail under your name. Your keys, one row each: the
  title, the type, the fingerprint as a chip that copies it whole, when it was added,
  and where it came from. A key added here has Remove; a key from GitLab says so and is
  removed in GitLab. Below, the add form: a title and the one line of a `.pub` file,
  with the `ssh-keygen` command for someone who has no key yet. A refused key says why
  and what to paste instead. Signed in with the server token, the page says that token
  has no keys and how to sign in as yourself. See "Your own keys" in `docs/access.md`.

### 4.9 Your tokens

- *Built:* `/tokens`, under SSH keys in the rail: personal tokens for scripts and CI.
  Each row is a token's name, its first characters, when it was last used and when it
  expires (in the warning colour once expired), and Revoke. The form takes a name and
  a lifetime (30, 90, 180 or 365 days; 90 by default). A new token is shown once, in
  one panel with three lines to copy: the token, a `cid clone https://you:<token>@…`
  address for this server, and `export CID_TOKEN=…`. See "CI, scripts and machines"
  in `docs/access.md`.

---

## 5. Out of scope

- Editing annotations in the dashboard (that is the annotation platform's job).
- Changing any data: the dashboard is view-only. Editing the dataset card and making
  releases from the dashboard (owners) are parked decisions, not plans; until they are
  decided, the card is written through `PUT …/-/card` and releases with `cid tag`.
- Social features: likes, trending, follower counts, public community discussions.
- Notebooks, model hosting, training.
- A public hub for other organisations.

---

## 6. Architecture

- **Frontend:** React + Vite + TypeScript, built to static files and **embedded in the
  cid server binary** (`@embedFile`), so deployment stays one binary. TanStack Router
  (URL state) and TanStack Query; TanStack Virtual for the gallery and tables.
  Annotation overlays are SVG over the media, with masks painted once into a canvas;
  no WebGL library. The three fonts are **self-hosted** (Latin subsets, served with
  the dashboard), never fetched from Google Fonts. There are no charts yet; when they
  come, they follow the dataviz rules (one axis, fixed class colours, text never in
  series colour, legend for 2+ series).
- **Design:** tokens and rules from section 3, kept in `web/src/theme/`. The annotation
  platform can adopt the same tokens so both feel like one product. WCAG 2.2 AA.
- **Browse API** (in `cid admin serve`, `GET …/-/browse?commit=…`): one page of a
  version — items with their annotations, total and matched counts, the
  split/class/type facets (each counted against the other filters), the class counts,
  a cursor, and the open item. The server answers with DuckDB from the version's
  browse index, two Parquet files (items in path order; annotations by item, never
  nested into item rows). A release's index is written in the same pass as its
  manifest. A new branch head or release is prepared ahead of its first visitor by
  the server's background worker (`version_jobs`); any other commit's index is built
  from TimescaleDB state-at-commit on first view. Every index, once built, is kept in
  storage and cached on the server's disk by commit id (commits are sealed, so an
  index never goes stale). Media metadata is joined per page, because the worker fills
  it in after ingest. The same index answers `…/browse/size` (the overview's subset
  size), `…/browse/dir` (the Files tab, one folder at a time) and `…/browse/compare`
  (Compare: the summary, item changes a page at a time, the visual diff).
  Thumbnails are asked for per page, `POST …/-/thumbs` with that page's hashes, and
  come back as presigned URLs; the gallery loads the next page as the end scrolls into
  view.
- **Endpoints the dashboard calls** (all under `/v0/datasets/<dataset path>/-/` unless
  shown whole; `web/src/api.ts`):

  | Call | Used for |
  |---|---|
  | `GET …/overview` | header, tape, card counts, "Use this dataset" |
  | `GET …/browse`, `…/browse/size`, `…/browse/dir`, `…/browse/compare` | Browse, subset size, Files, Compare |
  | `POST …/thumbs` | presigned thumbnail URLs for a page |
  | `GET …/history?path=` | the drawer's item history |
  | `GET …/table?hash=`, `GET …/text?hash=` | a table's statistics, a text file's first 64 KB |
  | `POST …/rowdiff` | a modified table's rows in Compare |
  | `POST …/reveal` | logged reveal of a restricted item |
  | `POST …/downloads` | presigned download URLs (logged in a restricted dataset) |
  | `GET …/activity` | Activity (owners) |
  | `PUT` / `DELETE …/star` | the signed-in person's bookmark |
  | `GET /v0/datasets` | home |
  | `GET /v0/me`, `GET /v0/auth/config`, `GET /v0/ping` | who is signed in, sign-in options, server up |
  | `GET`/`POST /v0/me/keys`, `DELETE /v0/me/keys?fingerprint=` | your SSH keys |
  | `GET`/`POST /v0/me/tokens`, `DELETE /v0/me/tokens?id=` | your personal tokens |

  The server also answers `GET …/info`, `GET …/releases` and `GET`/`PUT …/card`; the
  dashboard does not call them.
- **Preview worker** (`cid admin previews`). *Built:* thumbnails (WebP), audio
  waveforms drawn as pictures, video poster frames, blurred renditions for restricted
  items, and per-file table statistics, when items are pushed or registered. It calls
  **ffmpeg** as an external program, so the cid binary itself gains no new C
  libraries. *Planned:* short video previews, and PDF page images through **vips**
  (not wired yet; a PDF shows as a type tile).
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
- *Phase 2, not built:* **Health data** comes from the Validator's reports and from the manifest; the
  dashboard never recomputes heavy statistics on page load.
- *Phase 3, not built:* **Semantic search** calls an external embedding service over HTTP (e.g.
  the annotation platform's embedder); vectors stored with pgvector in TimescaleDB.
  If no service is configured, the feature is hidden, not broken. **Restricted
  datasets are excluded by default**: their items go to no external embedder and
  their vectors are never stored unless an owner explicitly enables it per dataset —
  an embedding of a face is biometric data.

---

## 7. Performance and quality budgets

| Measure | Budget | Measured by |
|---|---|---|
| Overview page, first meaningful paint (p75, office network) | < 1.0 s | not yet measured |
| Browse: first 60 thumbnails visible after filter change | < 700 ms at 1M items | `web/e2e/bench.spec.ts`, opt-in (`BENCH_DATASET`, a dataset seeded by `tests/bench/browse_1m.sh`); last run 0.30 s |
| Gallery scrolling | 60 fps, no blank tiles after 200 ms | not yet measured |
| Item drawer open | < 300 ms | not yet measured |
| Compare two releases, summary visible | < 2 s at 1M annotations | server side only, in `tests/bench/browse_1m.sh`: about 2.4 s the first time a pair is compared (over budget; the release before is prepared in the background, so a release and its predecessor are usually ready), 68 ms after; not yet measured in the browser |
| JS bundle, first load | < 300 KB gzipped | `web/e2e/dashboard.spec.ts`, every e2e run |
| Accessibility | WCAG 2.2 AA; full keyboard navigation | axe (serious and critical findings) on the main pages in `web/e2e/dashboard.spec.ts`, Daybreak only; full keyboard use not yet tested |

There is no CI yet: the e2e suite and the benches run by hand (`CLAUDE.md`, "Build and
test").

---

## 8. Delivery phases

**Phase 1 — useful on day one**
Datasets home · Overview with auto card and "Use this dataset" · Browse for images and
tables (gallery + table, overlays for box/polygon/points/mask, filters, item drawer
with history) · Releases timeline and compare (summary + visual diff) · Files tab ·
shareable URLs · restricted blur and reveal log · preview worker for images and tables.

*Status:* built, except: the auto card is partial (counts, class table and split sizes
only; its counts are `main`'s head, not the pinned release); Browse filters are path,
split, class and type only; the Releases timeline is partial (message, date, author,
id; no release notes, counts, quality, git link or purge notice) and covers `main`
only, and commits cannot be pinned; the Files tab has no types, last change or
preview panel.

*Delivered ahead of Phase 2:* table statistics. A CSV, Parquet or JSONL item opens as a
table in the drawer: rows, per-column type, range, distinct count and nulls, and its
first rows, built once per content hash by the preview worker.
A restricted dataset shows the shape only (rows, names, types, nulls) until a logged
reveal.

**Phase 2 — every media type**
Audio (waveform + transcript segments), video (player + segment/track timeline), text
(span highlights), PDFs · Health tab · row-level table diff · SQL console · card
completeness checklist · keyboard shortcuts everywhere.

*Built:* media-native items. Audio is sniffed (WAV, MP3, FLAC, Ogg, M4A) and its
waveform, drawn by ffmpeg, is its thumbnail, so tiles, mosaics and the blur rules treat
it like a picture; the drawer plays it beside the waveform, and plays video with its
poster. Anything else that is text opens as text: its first 64 KB, read with a ranged
GET (withheld in a restricted dataset until a logged reveal); a binary file says so in
words.

*Not built yet in Phase 2:* transcript segments on audio, the video segment/track
timeline, text span highlights, PDF page images (they wait for `vips` on the worker),
the Health tab, the SQL console, the card completeness checklist (it also needs card
editing, a parked decision), and keyboard shortcuts beyond Browse's `g`/`t`.

*Built:* the row-level table diff. Compare shows, under each modified CSV, Parquet or
JSONL file, its rows added and removed, with the rows themselves one click away (the
first 20 each way); it is the same answer `cid diff` prints. Whole-row comparison
until a dataset can declare a key, so cell-level "changed" waits for that.

**Phase 3 — find anything**
Semantic search and "more like this" · embedding map with lasso filter · near-duplicate
and outlier explorer · saved views. None of it is built.

*Phase 3 maybe, decided then, not now:* advisory AI judgments (TypeSafe/Jev) for
card-quality scoring or ranking label-error candidates — hidden when unconfigured,
advisory only, and never fed restricted content. Nothing in cid's core ever calls an
AI service (see non-goals in `CLAUDE.md`).

---

## 9. Acceptance tests (UX)

Each one is a test in `web/e2e/dashboard.spec.ts` unless marked otherwise.

- A 50 GB dataset with one malformed CSV: browse works; the bad file shows its own
  error; nothing else is affected. *Not yet automated.*
- A detection dataset: boxes are drawn on images in the gallery and drawer.
- Any view's URL, opened in a new browser, shows the same release, filters and item.
- Compare two releases: a changed box shows before and after on the same image.
- The `cid clone` command copied from "Use this dataset" works as pasted.
- For every action, "Show command" gives a `cid` command that does the same thing when
  run in a terminal. *Not yet automated; "Show command" is not built.*
- With reduced motion on, no animation plays; both themes pass contrast checks. *Not
  yet automated* (axe checks contrast in Daybreak only; no reduced-motion test).
- A restricted dataset: previews blurred until revealed; the reveal appears in Activity.
- Every page passes automated accessibility checks (axe) and full keyboard use. The
  axe part is automated for the main pages (serious and critical findings); full
  keyboard use is *not yet automated* (one test checks the tape by keyboard).

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
