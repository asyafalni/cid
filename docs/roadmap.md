# Roadmap

What is left, in the order to take it: cheapest first, an experience tier that runs
beside everything else (making the dashboard better than Hugging Face's pages, and
checking that it is), then the direction work (a Hugging Face door, models, lineage).
Arranged 2026-11-20. `CLAUDE.md` is still the law; where this file and `CLAUDE.md`
disagree about scope, section 1 below records the newer decision and `CLAUDE.md` is
updated in the change that builds it.

Take one item at a time, as its own change with its tests, and strike it here in the
same change.

## 0. Where the work stands

- `main` holds the first round of dashboard leftovers (merged 2026-11-20): the
  overview counts the pinned release; file types in the card; per-release counts in
  the history; type and open-in-Browse in the Files tab; reduced-motion and
  malformed-CSV tests; git status in the header and activity filters.
- Models (C2) and the Hugging Face door (C1) are on `main` (2026-11-20).
- Running the e2e suite needs Playwright's browser:
  `pnpm --dir web exec playwright install chromium`.
- The e2e database is seeded once and kept. A fixture change must be its own
  idempotent step in `web/e2e/setup.ts` (see `seedMediaBroken`), not an edit to an
  existing seed.

## 1. Decisions of 2026-11-20

1. **cid stays the controlled source of truth.** The Hugging Face API becomes one more
   door out of it, as git is. cid is not a Hub clone and does not mirror
   huggingface.co.
2. **The Hugging Face door is read-only.** `HF_ENDPOINT` is the cid server, `HF_TOKEN`
   a cid personal token. Writes stay `cid add`, `commit`, `push`.
3. **No Xet, no chunking.** Whole files by presigned URL; the non-goal stands.
4. **Models are a third kind**, behaving exactly like a file dataset: history,
   releases, push and clone, the dashboard. No stages, approvals, serving, metrics or
   experiment tracking.
5. **Model storage is cid's own.** Weights live in SeaweedFS and history in
   TimescaleDB, like any dataset. cid never uses a git host's model or package
   registry; git gets the small readable record only.
6. **A model release can be tied to dataset releases** (what it was trained on), or
   be weights only. The tie is a link (path, release, manifest hash), never a copy of
   the dataset. It shows in the model's git repository too.
7. **The name stays** cid · Controlled Iterative Datasets. Models are "the models
   trained on those datasets"; addresses follow the git host's path
   (`your-org/models/detector`).
8. **First audience is internal.** Done means unmodified `snapshot_download`,
   `load_dataset` and `from_pretrained` work against a release.

9. **A Hugging Face repo id is a cid path made to fit.** The client allows one `/`
   only, so `your-org/datasets/speech-id` cannot be one as it stands. Two forms, both
   answered:
   - **The full form, always:** the first segment, then the rest with its slashes
     written `__`: `your-org/datasets__speech-id`. It maps back without a lookup and
     can never be ambiguous, so it is the one cid prints (dashboard snippets, git
     README). (Decided as `--` first; changed 2026-11-20 when the real client refused
     it: `validate_repo_id` rejects `--` and `..`, and allows only letters, digits,
     `_`, `-` and `.`, so `__` is the one readable separator left.)
   - **The short form, when it is unambiguous:** `your-org/speech-id`, when exactly
     one dataset (under `datasets/…` routes) or model (under model routes) in
     `your-org` ends in that name. If several do, the answer is `RepoNotFound` with a
     message naming the full forms.
   A path segment may not contain `__`; creating or renaming a dataset to one that
   does is refused (built: the server checks every new path, `api.validDatasetPath`).

## 2. Tier A: small, dashboard only (hours each)

- ~~**A1. Policy version in the card**~~ (done 2026-11-20).
- ~~**A2. Keyboard in Browse**~~ (done 2026-11-20; it also fixed the virtual gallery
  and table measuring their place on the page from the wrong origin).
- ~~**A3. A release's git link in the history**~~ (done 2026-11-20: GitLab and
  GitHub; other hosts get no link).
- ~~**A4. Words for a model**~~ (done 2026-11-20 with C2: header, card, "Use this
  model", the home page's kind filter).

## 3. Tier U: the experience, better than Hugging Face

The dashboard's promise is a better experience than Hugging Face's dataset pages
(`docs/dashboard.md`, section 1). This tier is how that is checked and closed. It runs
beside Tiers B and C, not after them: take U1 right after Tier A, then one U item
between each larger piece.

Where cid stands against Hugging Face today:

| | Hugging Face | cid |
|---|---|---|
| A viewer for every dataset, any size | Often unavailable past 5 GB or for odd formats | **Ahead:** always there |
| One bad file | Can disable the whole viewer | **Ahead:** only that file says so |
| Annotations | Raw numbers in a table | **Ahead:** drawn on the item |
| Media | 100-row table pages | **Ahead:** gallery, waveform, player |
| What changed between versions | Needs code | **Ahead:** compare, with visual and row diffs |
| Private data | Viewer needs a paid plan | **Ahead:** the same for everyone |
| Column histograms, click to filter | Yes | **Behind:** statistics in the drawer only |
| Search inside text and string columns | Yes | **Behind:** paths only |
| A link to one row of a table | Yes | **Behind:** a link to a file, not a row |
| SQL over a version | Yes, in the browser | **Behind:** not built |
| Embedding the viewer elsewhere | Yes (iframe) | **Behind:** not built |
| One line of code to load | `load_dataset(...)` | **Behind** until C1 |

Close the "behind" rows without giving up an "ahead" one.

- **U1. Look at every page, and write down what is off.** A Playwright script that
  takes a screenshot of every page in the e2e fixtures, in both themes, at 1440, 1024
  and 390 pixels wide, into one folder. Read them all against the design language
  (`docs/dashboard.md`, section 3) and its rules (3.4): spacing, alignment, type
  scale, empty states, loading states, long names, narrow screens. The output is a
  list of defects in this file under U2, each with its screenshot; fix nothing in the
  same change.
- **U2. Fix what U1 found**, worst first. The first pass (2026-11-20) read every
  page in the light theme at 1440 px; the list is below. **Still to look at:** the
  dark theme, 1024 and 390 px, and the measured overflow report, none of which were
  taken (the test database was re-created mid-run). Run
  `SCREENS=<folder> pnpm --dir web exec playwright test screens` with nothing else
  using the test database, read the pictures, and add to this list. The page names
  are the picture names in `web/e2e/screens.spec.ts`.

  Says nothing, or says it unclearly:
  1. **A link to an item the version does not hold opens nothing and says nothing**
     (`item-missing`): Browse loads as if no item were asked for. It should say the
     item is not in this version, and offer the versions that have it.
  2. **The header's git status is hard to read** (every dataset page): "v1.1.0,
     v1.0.0 not there yet" sits right after "View in git" with no separator and no
     subject. Say "not in git yet: v1.1.0" and cap a long list ("and 3 more").
  3. **Split and class chips do not show what is chosen** (`overview-annotated`, "Use
     this dataset"): "train" is a dashed chip and "all" is plain text; nothing looks
     selected.
  4. **Activity's "which" column** (`activity`): "…" is added to every value, even
     "v1.0.0"; commit ids are cut and are not links to the version; the caption says
     "the last 200 events" when there are five.

  Data that is not pictures looks like nothing:
  5. **A gallery of files with no preview is a wall of identical tiles**
     (`browse-gallery-many`: 130 tiles reading ".txt"). Open in table mode when
     nothing on the first page has a preview, and let a text tile show its first
     lines.
  6. **Home cards for non-visual datasets are mostly empty** (`home-cards`): a large
     pale tile with one small type label, and the same large tile for an empty
     dataset. A file with no extension shows as "·" in the tile but "file" in the
     line under it.

  Alignment and spacing:
  7. **The Browse "?" button floats mid-toolbar and moves** between pages (740, 588
     and 381 px from the left on three pages). Give it a fixed place at the end.
  8. **Numbers in tables.** Browse's table has sizes bold and left-aligned, with the
     right 40% of the table empty (`browse-table`); compare's by-class header
     "class" does not sit over its column (`releases-annotated`); the card's "Items
     by type" has an unlabelled count floating mid-row (`overview-files`).
  9. **The card's policy line touches the caption below it** (`overview-annotated`).
  10. **The drawer** (every `item-*`): one narrow width whatever it shows, so a
      picture or a table is small beside a mostly empty page; "Download the file"
      sits tight under History.
  11. **Text over the clouds** (`home-cards`, every dataset header): the search hint
      and the tape's legend run across cloud shapes. axe passes; it still reads
      worse than the lines beside it.
  12. **Sign-in** (`signin`): the airship floats alone at the top left, unrelated to
      the panel; the disabled "Open the dashboard" is smaller and paler than the
      button above, and reads as a different kind of control.

  To check, not yet a defect:
  - Type links in the card were two colours on one page (`overview-files`); it may
    only be the visited state.
  - A table item's drawer was not seen with its statistics (the previews had just
    been reset).
- **U3. No blank waits.** Wherever a page says "Reading…" or shows nothing while it
  loads, show the page's shape instead (the header, the tape, tile placeholders of the
  right size), so nothing jumps when the data arrives. Budget: no layout shift on
  load, measured in `web/e2e/bench.spec.ts`.
- **U4. The first minute.** A person who opens a dataset for the first time should
  know within one screen what it is, how big, what kind of data, who owns it, and
  the one command to get it. Test it as a script: open a dataset, read only what is
  above the fold at 1440×900, and answer those five questions. Move what fails.
- **U5. Charts where numbers are compared.** Class balance and split sizes as bars in
  the card and in compare; a shared class colour palette, so a class has one colour
  in the card, the overlays and the filters (`docs/dashboard.md`, 3.3). No chart
  where a number alone says it.
- **U6. Column histograms and click to filter** in table mode: each column's
  distribution above it, a click narrowing the rows. The statistics are already
  built per content hash.
- **U7. A link to one row.** Opening a table item at a row (`row=` in the URL),
  highlighted and scrolled to.
- **U8. Search inside text.** Text files and string columns, per version. Needs an
  index decision first (DuckDB full-text search over the browse index, or not at
  all); write that decision up before building.
- **U9. Keyboard everywhere, and "Show command"** (A2, B9): the two things an
  engineer notices first.
- **U10. Embedding.** A chrome-less view of Browse and of one item (`embed=1`), for
  wikis and merge requests, under the same access rules. Never for a restricted
  dataset.
- **U11. Ask people.** Once U1 to U4 are in, sit three engineers who use Hugging Face
  in front of a dataset they know, give them four tasks (find an item, see what
  changed in the last release, get a subset onto their machine, say whether the
  labels look right), and watch without helping. What they stumble on goes to the
  top of this tier.

Every change here keeps the budgets in `docs/dashboard.md`, section 7, passes axe in
both themes, and works with reduced motion. Beauty never costs a budget.

## 4. Tier B: one server change each (about a day each)

- ~~**B1. Last change per file** in the Files tab~~ (done 2026-11-20; 1–7 ms per
  120-file page at 1M items, 130–150 ms over compressed history).
- ~~**B2. Size per file type** in the card~~ (done 2026-11-20; statistics format 3).
- ~~**B3. Purge notice** on a release in the history~~ (done 2026-11-20; a count
  only: `docs/data-model.md` rules out showing the paths).
- ~~**B4. A stable random sample** for "A look inside"~~ (done 2026-11-20).
- ~~**B5. Compare, per class**~~ (done 2026-11-20; the dashboard only, not `cid diff`).
- **B6. More Browse filters:** annotation count, attributes, identities; then
  histograms and the List view.
- ~~**B7. Branches on the tape and pinning a commit**~~ (done 2026-11-20: `?commit=`,
  `?branch=`). Comparing a branch with `main` across the two is not built: the
  compare pickers list the shown branch's commits.
- ~~**B8. `coco` and `voc` exports**~~ (done 2026-11-20; checked with pycocotools:
  loads, `annToMask` matches every area; migration 0005).
- **B9. "Show command"** on every action, then the `⌘K` palette.

## 5. Tier C: the direction (in this order)

### C1. The Hugging Face read door

**File datasets: done (2026-11-20, `src/server/hf.zig`).** Checked with the real
`huggingface_hub` 2.4.0 and `datasets` 5.2.0 against `cid admin serve`:
`dataset_info`, `hf_hub_download`, `snapshot_download` (a second run downloads
nothing), `list_repo_refs`, `load_dataset` (train and test splits found with no
configuration, and streaming), the short form, and each error as the client's own
exception. The integration suite covers the routes (`the Hugging Face door: …`); the
real-client check is not automated (it needs Python: still a dependency to agree).
**Annotated datasets: done (2026-11-20).** Their items are served at their paths,
and their annotations as one gzip JSON-lines file per split under `_annotations/`
(the jsonl export's lines: export kind `hf`, migration 0003), named as splits by a
generated `README.md` (`configs:`): `train`, `val`, …, `unsplit` for items with
none, or one `train` when there are no splits. Checked with the real clients:
`snapshot_download`, `load_dataset` (each split, rows with their boxes) and
streaming. A split's file is built on its first request and kept; at 1M items that
first request waits for the build (not measured yet; the background worker does not
prepare it ahead).
**Still to do:** models once C2 lands (`/api/models/…` routes are answered; the root
`/{ns}/{name}/resolve/…` route is not registered yet).

Facts read from `huggingface_hub` 2.4.0, `datasets` 5.2.0 and `transformers` 5.23.0
on 2026-11-20. Check them against the versions current when building.

Routes, all read-only, all answered from what cid already has:

| Route | Notes |
|---|---|
| `HEAD`/`GET /{datasets/}{ns}/{name}/resolve/{rev}/{path}` | Must send `X-Repo-Commit` and `ETag`; `X-Linked-Size` for the size; a 302 to the presigned GET. The BLAKE3 hash is a fine ETag. Honour `Range`. |
| `GET /api/{models\|datasets}/{id}` and `/revision/{rev}` | `{id, sha}` is enough. |
| `GET /api/{type}s/{id}/tree/{rev}[/{path}]` | `type`, `path`, `size`, `oid` per entry; `recursive`; pages by a `Link: rel="next"` header. |
| `POST /api/{type}s/{id}/paths-info/{rev}` | Form fields `paths`, `expand`; `datasets` needs it. |
| `GET /api/{type}s/{id}/refs` | Branches and releases as `branches` and `tags`. |

Rules the client imposes:

- **Errors are read from the `X-Error-Code` header:** `RepoNotFound`,
  `RevisionNotFound`, `EntryNotFound`, `GatedRepo`. A plain 404 for a missing file
  breaks `load_dataset`, which probes for files that are not there. Send
  `X-Repo-Commit` on that 404 too.
- **Commit ids should look like git's.** A UUIDv7 works but is treated as a branch
  name, so every file is checked again on every run. Give each commit a 40-hex alias
  that maps back without a table: its 32 hex digits, then `00000000`.
- **A revision is a release, a branch, or a commit id** (either form), resolved on the
  server in all three routes.
- **Never send an `X-Xet-*` header.** Without one the client downloads over plain
  HTTP with no configuration.
- **A redirect to another origin** (the file store) is handled: the client reads the
  metadata from the 302 itself and drops `Authorization` before following it.
- **Serve over https.** The client maps a 401 to "repository not found" only for
  `https://` endpoints.

What each kind serves: a file dataset or a model, its files as committed; an annotated
dataset, its `jsonl` export, one file per split (`train.jsonl`, …), which
`load_dataset` reads with no README. A restricted dataset is served under the same
rules as a clone, each read logged as a download.

Done when a test drives the real Python clients against `cid admin serve`:
`snapshot_download`, `load_dataset` (a file dataset of Parquet or JSONL, and an
annotated one) and `from_pretrained` (a tiny model), each at a release, with a second
run that downloads nothing. That test needs Python and those libraries on the test
machine: a new test-only dependency, to be agreed first.

Known and accepted: `hf cache verify` compares SHA-256 and git SHA-1 and will report
mismatches against BLAKE3 names.

### C2. Models

**Done (2026-11-20).** Migration `0002_model_kind.sql`; `cid init <address> --git
<url> --model`; the git README calls it a model; the dashboard names it (A4); the
Hugging Face door serves it on `/api/models/…` and at the root
(`/{ns}/{name}/resolve/…`), never on the dataset routes. Integration test: created
as a model, pushed, released, verified, cloned back identical, served to model
clients. Checked with the real clients: `model_info`, `snapshot_download` and
`transformers`' `AutoConfig.from_pretrained` (a BERT config; weights need PyTorch,
not installed for the check). Not done: a line in `tests/usability.sh`.

### C3. Lineage

**Done (2026-11-20).** `release_sources` (migration 0004, immutable like a release);
`cid tag --trained-on`; the overview's `trained_on` / `trained_models` /
`lineage_unseen`; the card's "Trained on" and "Models trained on this release"; the
model's README, `release.json` and CHANGELOG. Tested in the integration suite (each
refusal, the unreadable source counted not named, immutability), the renderer's unit
tests and e2e (both pages, the links between them).

```
cid tag v1.1.0 --trained-on your-org/datasets/person-vehicle@v4.2.0
Release v1.1.0 created at 01a1f943-ff94: 2 items, manifest fa054ccbe9f8…
Trained on your-org/datasets/person-vehicle v4.2.0.
```

- `--trained-on` repeats; leaving it out releases weights only.
- The server checks the caller can read that dataset and that the release exists,
  and keeps its path, release name and manifest hash with the model's release.
- It is a model's option only. A release never moves, so the tie is set once.
- Shown on the model's page (linking to the dataset at that release), on the
  dataset's page ("models trained on this release"), and in the model's git
  repository: README, `release.json`, CHANGELOG.
- A restricted dataset is named by path and release, nothing more.

### C4. After the door works

- ~~A `from_pretrained` snippet on the model's page; a `load_dataset` snippet in "Use
  this dataset"~~ (done 2026-11-20). The model's page says "Model card"; what owners
  write in it waits on card editing, a parked decision.
- Parquet exports for annotated datasets, if JSONL proves slow to load.

## 6. Tier D: larger, each needs its own design

A declared key column for row diffs · per-dataset deploy keys · the Health tab and
Validator tiles · the SQL console · PDF page images (`vips`) · access from other git
hosts (GitHub first) · DuckDB pinned for other platforms · dashboard Phase 3.

## 7. Parked, not planned

Everything on `CLAUDE.md`'s "explicitly not now" list, card editing and releases from
the dashboard, and from this round: uploads through the Hugging Face API (since
client 1.20.0 they go through Xet with no fallback), mirroring huggingface.co, and
model registry features (stages, approvals, serving, metrics).
