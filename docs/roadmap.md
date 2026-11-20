# Roadmap

What is left, in the order to take it: cheapest first, then the direction work
(a Hugging Face door, models, lineage). Arranged 2026-11-20. `CLAUDE.md` is still the
law; where this file and `CLAUDE.md` disagree about scope, section 1 below records the
newer decision and `CLAUDE.md` is updated in the change that builds it.

Take one item at a time, as its own change with its tests, and strike it here in the
same change.

## 0. Where the work stands

- `main` holds the first round of dashboard leftovers (merged 2026-11-20): the
  overview counts the pinned release; file types in the card; per-release counts in
  the history; type and open-in-Browse in the Files tab; reduced-motion and
  malformed-CSV tests; git status in the header and activity filters.
- `model-kind`, a local branch that is not pushed: one WIP commit, the start of item
  C2. It builds; nothing in it is tested. Rebase it onto `main` before continuing.
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
     written `--`: `your-org/datasets--speech-id`. It maps back without a lookup and
     can never be ambiguous, so it is the one cid prints (dashboard snippets, git
     README).
   - **The short form, when it is unambiguous:** `your-org/speech-id`, when exactly
     one dataset (under `datasets/…` routes) or model (under model routes) in
     `your-org` ends in that name. If several do, the answer is `RepoNotFound` with a
     message naming the full forms.
   A path segment may not contain `--`; creating or renaming a dataset to one that
   does is refused from now on.

## 2. Tier A: small, dashboard only (hours each)

- ~~**A1. Policy version in the card**~~ (done 2026-11-20).
- **A2. Keyboard in Browse:** `j`/`k` and arrows between items, `/` to the path
  search, `?` listing the shortcuts (`docs/dashboard.md`, principle 10).
- **A3. A release's git link in the history.** Only where the URL form is known from
  the host; otherwise no link. GitLab first (`/-/tags/<name>`).
- **A4. Words for a model** in the dashboard, once C2 lands: the header label, "Use
  this model", the kind filter on the home page.

## 3. Tier B: one server change each (about a day each)

- **B1. Last change per file** in the Files tab: date and author of the revision that
  put each file there. One query per page over `item_revisions`; measure it at 1M
  items over compressed history (`tests/bench/browse_1m.sh`, `COMPRESS=1`) before
  keeping it.
- **B2. Size per file type** in the card. Needs `stats_version` 3 in
  `src/core/version.zig`; every kept statistic is then recomputed on first read.
- **B3. Purge notice** on a release in the history: "intact except N purged items",
  with the paths (invariant 19).
- **B4. A stable random sample** for "A look inside" instead of the first eight items.
- **B5. Compare, per class:** annotations added, changed and removed by class.
- **B6. More Browse filters:** annotation count, attributes, identities; then
  histograms and the List view.
- **B7. Branches on the tape and pinning a commit.** The server already resolves any
  commit; the tape and the pickers show `main` and releases only.
- **B8. `coco` and `voc` exports**, one file each in `src/export/`.
- **B9. "Show command"** on every action, then the `⌘K` palette.

## 4. Tier C: the direction (in this order)

### C1. The Hugging Face read door

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

### C2. Models (branch `model-kind`)

Done there, untested: migration `0002_model_kind.sql`, the server accepts the kind,
`cid init <address> --git <url> --model`, the help line, the git README's wording.

Still to do: integration test (init, push, release, verify, clone: identical tree);
a line in `tests/usability.sh`; the dashboard's words (A4); `CLAUDE.md` (the kinds
table, Words, the scope section); `docs/data-model.md`; `docs/git-repository.md`.

### C3. Lineage

```
cid tag v1.0.0 --trained-on your-org/datasets/person-vehicle@v4.2.0
Released v1.0.0 (3 items), trained on your-org/datasets/person-vehicle v4.2.0.
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

- A model card and a `from_pretrained` snippet on the model's page; a `load_dataset`
  snippet in "Use this dataset".
- Parquet exports for annotated datasets, if JSONL proves slow to load.

## 5. Tier D: larger, each needs its own design

A declared key column for row diffs · per-dataset deploy keys · the Health tab and
Validator tiles · the SQL console · PDF page images (`vips`) · access from other git
hosts (GitHub first) · DuckDB pinned for other platforms · dashboard Phase 3.

## 6. Parked, not planned

Everything on `CLAUDE.md`'s "explicitly not now" list, card editing and releases from
the dashboard, and from this round: uploads through the Hugging Face API (since
client 1.20.0 they go through Xet with no fallback), mirroring huggingface.co, and
model registry features (stages, approvals, serving, metrics).
