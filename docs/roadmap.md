# Roadmap

What is left and what is done. Section 0 is the short answer: where the work stands
and what to take next. The tiers below keep the detail: small dashboard pieces (A),
the experience tier that makes the dashboard better than Hugging Face's pages and
checks that it is (U), one-server-change pieces (B), the direction work (C: a
Hugging Face door, models, lineage), and reach (E: what lets someone outside, or an
AI coding agent, pick cid up).
Arranged 2026-11-20. `CLAUDE.md` is still the law; where this file and `CLAUDE.md`
disagree about scope, section 1 below records the newer decision and `CLAUDE.md` is
updated in the change that builds it.

Take one item at a time, as its own change with its tests, and strike it here in the
same change.

## 0. Where the work stands

Everything is on `main`; no branch or pull request is open (rechecked 2026-11-28).
What is left that the code alone can settle is U17 (search as the front door, asked
for 2026-11-28; Tier U) and item 11's local disk (below); the rest
waits on the owner (U11, the first release, the GitHub live check, card editing and
item 11's run on the office staging server), on the annotation platform (the Validator's report
format, its embedder, an item's source) or on a parked decision (U10).

- **Done:** all of Tier A; Tier B except the rest of B6; the Hugging Face door (C1),
  models (C2) and lineage (C3); the first half of U1. The toolchain is Zig 0.17.1
  with nilo v0.8.0. U1 and U2 are done too: every page photographed in both themes at
  1440, 1024 and 390 px, the measured overflow report empty, and every defect found
  fixed.
- **What is left, in the order to take it** (agreed with the owner 2026-11-20):
  1. ~~U3 (no blank waits)~~ (done 2026-11-20: layout shift 0.001–0.074 per page with
     every answer slowed 400 ms; `web/e2e/dashboard.spec.ts`).
  2. ~~A declared key column for row diffs~~ (done 2026-11-21: `.cidkeys`, committed
     with the data; rows changed cell by cell in `cid diff` and the compare).
  3. ~~U4 (the first minute)~~ (done 2026-11-21: what, how big, what kind, whose and
     the clone command all above the fold at 1440×900, checked by an e2e test; a
     dataset with no Maintainer now says "no owner named". What a dataset is *for*
     waits on card editing, a parked decision).
  4. ~~The rest of B6~~ (done 2026-11-21): ~~the attribute filter~~ (done 2026-11-21: index format v4,
     `attr_set`); ~~the List view~~ and ~~the identity filter~~ (done 2026-11-21;
     identities are `attrs.identity`, docs/data-model.md); ~~histograms~~ (done with U6).
  5. ~~U5~~, ~~U6~~, ~~U7~~ and ~~U8~~ (done 2026-11-21); U10 parked (below).
  6. ~~C1's two loose ends~~: ~~the real-client check as an automated test~~ (done
     2026-11-23: `tests/hf_client.sh`, huggingface_hub 2.4.0 and datasets 5.2.0,
     test-only, in CI), and ~~an
     annotated split's file at 1M items~~ (done 2026-11-21: prepared ahead for
     releases, and a release of an already prepared head is queued again).
  7. ~~Small gaps left by finished items~~ (done 2026-11-21): ~~comparing a branch with `main` (B7)~~; actions
     ~~in the `⌘K` palette (B9)~~ (done 2026-11-21: pin, compare, copy the command or a link); ~~per-class change counts in `cid diff` (B5)~~ (done 2026-11-21: counted as the
     diff streams, the 20 most changed classes, and `by_class` in `--json`).
     Found and fixed on the way (2026-11-21): an item moved to another split with its
     bytes unchanged was invisible to `cid diff`, Compare and a release's counts;
     it is now a change of its own (`split`, old → new), migration 0007.
  8. U11 (watch three engineers use it), once U1 to U4 are in: it needs people, so it
     is the user's to run.
  9. The rest of Tier D, each with its own design first. Done 2026-11-22/23: the
     Health tab (cid's own checks; a card shows its marks), the SQL console, PDF
     first pages (`vips`). Waiting: the Validator's tiles (its report format) and
     semantic search (Phase 3, parked 2026-11-23 until the platform's embedder
     exists). Small ones done 2026-11-23: dashboard links written as typed
     (`anns=0`, never `%220%22`). Done 2026-11-24: segments, transcripts and
     text spans, their geometry fixed in `docs/data-model.md` with the owner; keyboard
     shortcuts on every tab (`1`–`6`, `c`, `?`, and `f` in Browse); the
     Activity log as far back as it goes, filtered on the server; the 100k-file
     CLI budgets measured and met (status, commit, push, clone); compare's
     folder tree. Done 2026-11-25: Browse's "changed since a release", size, author and
     labelling policy version filters. Done 2026-11-26: the Files
     tab's preview panel; short video previews; release notes (`cid tag <name> -m
     "..."`, kept with the release, in its history, on the card and in git's changelog);
     numeric attributes as histograms in Browse (`num=`, index format v7); a
     newcomer's pass over the CLI, as a git user types it: `cid tag`/`cid branch` alone
     list (and a name never starts with `-`, after `cid tag -l` made a release "-l"),
     `cid help <command>` and `--help` that never runs the command, `add -A`,
     `remote -v`, `diff --cached`, and a checkout to an older commit no longer counting
     pushed commits as unpushed. Done 2026-11-27: a demo for the one-machine setup
     (`deploy/compose/demo.sh`: fifty real street photos with their boxes and a review
     pass between two releases, a file dataset, a model), loaded and checked by
     `tests/quickstart.sh`; the README's screenshots retaken from it; "A look inside"
     laid out in full rows (it showed seven photos and an orphan); the stack starts
     again after a stop (the bucket step refused a bucket that existed, so after a
     reboot the server never started). And Compare's pictures as a review: a grid
     of pairs, each saying what changed ("truck → car · 5 moved"), opened large as
     a link (`pair=`) with every box's change to the pixel and who made it, the
     arrow keys stepping through; at full size unless the dataset is restricted.
     It was one full-width pair after another, 14,000 pixels for 21 photos.
     Found and fixed 2026-11-27, reading the thumbnail route: `downloads` and
     `thumbs` presigned any hash sent, whichever dataset was named, so a reader of
     one dataset who knew a hash of another (a restricted one included) got its clear
     bytes. Both now answer only for content the named dataset holds (invariant 12),
     as every other hash route already did.
  10. **Tier E, reach** (section 7; direction set 2026-11-25). Everything above that
      can be built is built, so the work turns to who can pick cid up. All four are
      done (E1 to E4, 2026-11-25/26).
  11. **The first trial: a DVC dataset on a NAS** (asked for by the owner,
      2026-11-26; first above everything optional). The dataset is 100 GB to 1 TB
      in DVC, its remote a MinIO on a NAS; cid's store is to be SeaweedFS with its
      data on that NAS, and the import the loop of `docs/coming-from.md` (both the
      owner's choices). Done 2026-11-26: `deploy/nas/` (the data files on the
      share, the file index in PostgreSQL, nothing irreplaceable on the server's
      disk) with `tests/nas.sh` on a real NFS mount (the store's disk lost, the
      share gone mid-push); SeaweedFS pinned at 4.55, which repairs a torn data
      file by itself; a verified upload written into place as it is read, where
      the store's own copy took most of a large push; a store that stalls waited
      out, and a failed push resumed without sending anything twice.
      Also done 2026-11-26: the import itself tried, with DVC's remote in a real
      MinIO and cid's files on the NFS share. The documented loop turned out
      wrong (see E4); `deploy/import-tags.sh` replaces it: every tag a release,
      each compared file by file with DVC's own checkout, stopping loudly and
      carrying on when run again.
      And found by importing a DVC repository set to `cache.type symlink`: cid
      skipped symbolic links in silence, so the import released an empty dataset
      and `cid status` called the folder clean. `cid add` now refuses a link by
      name and `cid status` lists them; the import script switches such a clone
      to hard links. Decided by the owner 2026-11-27: no; cid stores files,
      not links, and the importing machine's twice the data covers DVC's copy.
      Found 2026-11-27, rechecking: the machine that runs a large import needed up
      to three times the data's size free (DVC's cache, the checked-out files, and
      cid's cache), likely the first thing to stop a 1 TB import. Done the same day:
      `deploy/import-tags.sh` checks DVC's files out as hard links and pushes each
      tag in batches (`CID_IMPORT_BATCH_MB`, 10 GB) from a cache of its own,
      emptied after every push, and says where each tag's time went;
      `tests/bench/import_rehearsal.sh` rehearses a whole import at any size
      (DVC in MinIO, cid on an NFS share). At 1 GB: 3.0 times the data on the
      importing machine before, 1.26 after; 208 s, every release DVC's checkout.
      Next, the owner's (agreed 2026-11-27): the rehearsal at a tenth of the real
      size on the office staging server, then 1 TB there. The owner's setup, as
      they described it: NFS; at least twice the data free on the importing
      machine; DVC's cache shared, on the NAS; files of every size. With DVC's
      cache on another disk than the checkout, hard links cannot reach it, so DVC
      copies: the importing machine then holds the data once plus one batch,
      inside the twice it has.
      Left: the numbers on the owner's own NAS (`deploy/nas/README.md` says how to
      take them; the test share is a laptop's), SMB untried, and the owner's own
      import. Decided by the owner 2026-11-27, as invariant 2 stands: each pushed
      byte stays written to the store twice (staged, then into place), so nothing
      is ever at an item's key unchecked; revisited only if the staging run shows
      the NAS's writes are what limits it.
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
| Column histograms, click to filter | Yes | **Level:** a table's rows, each column's distribution above it, a click to filter (U6) |
| Search inside text and string columns | Yes | **Level for tables** (U8): a table's rows across its text columns; text files are not indexed across a version, by decision |
| A link to one row of a table | Yes | **Level** (U7): `row=` opens the table at that row |
| SQL over a version | Yes, in the browser | **Level:** on the server, sandboxed, any size (2026-11-23) |
| Embedding the viewer elsewhere | Yes (iframe) | **Behind**, parked (U10) |
| One line of code to load | `load_dataset(...)` | **Level** since C1: the same line, with `HF_ENDPOINT` set |

Close the "behind" rows without giving up an "ahead" one.

- ~~**U1. Look at every page, and write down what is off.**~~ (done 2026-11-20, with
  U2: every page in both themes at 1440, 1024 and 390 px, `web/e2e/screens.spec.ts`;
  each new page is added to it and read the same way.) A Playwright script that
  takes a screenshot of every page in the e2e fixtures, in both themes, at 1440, 1024
  and 390 pixels wide, into one folder. Read them all against the design language
  (`docs/dashboard.md`, section 3) and its rules (3.4): spacing, alignment, type
  scale, empty states, loading states, long names, narrow screens. The output is a
  list of defects in this file under U2, each with its screenshot; fix nothing in the
  same change.
- ~~**U2. Fix what U1 found**~~ (done 2026-11-20: all twelve below, and what the dark
  theme, 1024 and 390 px added: the Files tab overflowing a phone, "Show command" cut
  off at the end of the tabs, Browse's count adrift mid-toolbar. The measured
  overflow report is empty in both themes at every width; rerun it after any layout
  change.) A second pass (2026-11-23) took the pages added since (Health, the SQL
  console, a PDF and its drawer) and fixed what it found: "1 items"; the class chips
  and overlay slider shown over the SQL console; a PDF tile cropped to its middle; no
  page count in a PDF's drawer; a PDF never leading its card's mosaic; card feet
  wrapping into three ragged lines once they carried health. The first pass read every page in the light theme at 1440 px; the list is
  below. Run
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
- ~~**U3. No blank waits.**~~ (done 2026-11-20; measured in `dashboard.spec.ts`, not the
  1M bench: the test slows every answer instead.) Wherever a page says "Reading…" or shows nothing while it
  loads, show the page's shape instead (the header, the tape, tile placeholders of the
  right size), so nothing jumps when the data arrives. Budget: no layout shift on
  load, measured in `web/e2e/bench.spec.ts`.
- ~~**U4. The first minute.**~~ (done 2026-11-21.) A person who opens a dataset for the first time should
  know within one screen what it is, how big, what kind of data, who owns it, and
  the one command to get it. Test it as a script: open a dataset, read only what is
  above the fold at 1440×900, and answer those five questions. Move what fails.
- ~~**U5. Charts where numbers are compared.**~~ (done 2026-11-21: class balance and
  split sizes as bars on the card, and as before/after dumbbells in compare where a
  count moved; the class palette was already shared through `classColor`.) Class balance and split sizes as bars in
  the card and in compare; a shared class colour palette, so a class has one colour
  in the card, the overlays and the filters (`docs/dashboard.md`, 3.3). No chart
  where a number alone says it.
- ~~**U6. Column histograms and click to filter**~~ (done 2026-11-21, with B6's
  histograms: a table's rows, each column's distribution above it, a click narrowing
  them, in the URL; docs/dashboard.md, the item drawer).
- ~~**U7. A link to one row.**~~ (done 2026-11-21: `row=` opens the rows at the page
  holding it, under any filters, marked and scrolled to; a row's number makes the link.) Opening a table item at a row (`row=` in the URL),
  highlighted and scrolled to.
- ~~**U8. Search inside text.**~~ (done 2026-11-21, as decided that day: tables only.
  A table's rows are searched across its text columns, on request; text files are not
  indexed across a version, since that would widen invariant 15. docs/dashboard.md,
  Search.)
- ~~**U9. Keyboard everywhere, and "Show command"**~~ (done 2026-11-20 with A2 and
  B9: Browse's keys, the command for the view on screen, the `⌘K` palette).
- **U10. Embedding.** *Parked 2026-11-21.* A chrome-less view of Browse and of one item
  (`embed=1`), for wikis and merge requests, under the same access rules, never for a
  restricted dataset. Parked because GitLab strips iframes from merge requests and its
  wikis, and the SameSite=Lax sign-in cookie never reaches a frame on another site, so
  an embed would only work on pages of cid's own site. Decided with it: no other site
  may frame the dashboard at all (`frame-ancestors 'self'`), which closed a
  clickjacking gap. Reopen with an allow-list of origins if a same-site wiki wants it.
- **U11. Ask people.** Once U1 to U4 are in, sit three engineers who use Hugging Face
  in front of a dataset they know, give them four tasks (find an item, see what
  changed in the last release, get a subset onto their machine, say whether the
  labels look right), and watch without helping. What they stumble on goes to the
  top of this tier.

- ~~**U12. The home sidebar.**~~ (built 2026-11-27; `docs/dashboard.md`, 4.1)
  *Decided 2026-11-27 with the owner, who found the home page awkward without one.* Not a rail on every page: cid has four destinations, and
  Browse and Compare need their width. Hugging Face has no sidebar on a dataset's own
  page either; its sidebar is on the listing, and holds the filters. So the home page
  gets a left sidebar in place of its row of dropdowns, and a dataset's page keeps its
  tabs. Reopen as a slim collapsible rail (Starred, Recent) on every page only if
  getting from one dataset to another still feels far once this is in.

  What it holds, top to bottom, and where each must beat Hugging Face's listing:
  1. **Starred** and **Recently viewed**, as links (they are chips above the grid
     today). Hugging Face keeps neither on its listing.
  2. **Groups**: the dataset paths as a tree (`your-org/datasets`, `your-org/models`),
     a count beside each, a click narrowing the grid (`group=`). Hugging Face is flat.
  3. **Kind**, **file type**, **releases**, **restricted** (only when some dataset
     is) and, new, **health** (failing, warnings, passing): find what needs attention,
     which Hugging Face cannot ask. Each is a list, not a dropdown: every choice
     visible without a click.
  4. **Every value carries its count, counted against the other filters**, as
     Browse's facets are; a value that would give nothing is dimmed, never hidden, so
     nobody clicks into an empty page. Hugging Face shows no counts on most filters.

  Around it:
  - **Instant.** The listing is already in the browser: a click filters with no
    request and no reload (Hugging Face reloads its list). One history entry a click;
    back undoes it; everything in the URL, the old links still working.
  - **What is on, said above the grid**: each active filter as a chip with its own
    ×, and "Clear filters". A sort beside the layout switch: newest push (default),
    name, size, items (`sort=`).
  - **Keyboard:** `/` to the search, `f` to the first filter, as in Browse.
  - **Narrow screens:** below 900 px the sidebar is a "Filters" button over the
    grid, saying how many are on; it opens in place, never as an overlay that hides
    the count.
  - **Calm:** a solid panel on the page's ground, sticky under the header, no
    decoration of its own (the sky stays the page's one). It scrolls by itself when
    taller than the window.

  Learned from Hangar's listing (below), which is this design with three flaws to
  avoid: choosing a value there hides its siblings, so a filter cannot be switched
  without first being cleared (here every value stays, with its count); its sidebar
  scrolls away with the page (here it is sticky); nothing above its grid says which
  filters are on (here the chips). Taken from it: a group shows its eight commonest
  values, then "Show all N".

  Done when: at 1440 px the grid still shows three cards a row; a filter change
  repaints in under 100 ms with 500 datasets; axe passes in both themes; every
  control is reachable and operable by keyboard; an e2e test covers a group, a
  facet's counts under another filter, a dimmed empty value, the chips, the sort,
  the old `?kind=` links and the phone layout.

### Hangar, looked at 2026-11-27

[Hangar](https://github.com/hangar-hub/hangar) is a self-hosted hub that speaks the
Hugging Face API, git with LFS, Ollama and LM Studio: a private Hugging Face, models
first ("a home for your arsenal of models"; `/` is the model list), datasets a second
section with a row viewer. A Go server with an embedded React dashboard, SQLite or
Postgres, files on disk or S3, each repository a real git repository. Elastic License
2.0 (source-available). Very young: first commit 2026-10-18, one author, eleven
releases in ten days. Its demo (demo.hangar.page) runs on sample data, so what follows
is its design as seen there at 1440 and 390 px, not its speed.

It is a hub, not version control: a model's or dataset's history is git's commits, and
nothing compares two versions, draws an annotation, checks a dataset's health or
blurs a restricted one. That is where cid stays ahead. Where it is better than cid
today is the hub's own ground: finding one thing among many, and saying how to use it.

| | Hangar | cid | Then |
|---|---|---|---|
| Listing filters | A sidebar of facets with counts, in the URL | Three dropdowns, no counts | **U12**, without its three flaws |
| Sort the listing | Updated, name, size, downloads, likes | None | **U12** (newest push, name, size, items) |
| "Use this" | A tab per client: `datasets`, pandas, Polars, DuckDB, the hub library, its CLI, git | The same as tabs since U13: cid, `datasets`, `huggingface_hub`, an agent | **Level**; DuckDB and pandas tabs wait on a test |
| Work in progress | A Jobs badge and drawer: pulls, indexing, exports, with progress | "git up to date" in the header; a version being prepared says nothing | **U14** |
| How much it is used | Downloads over 30 days, on the card and as a sort | Clones, pulls and checkouts over 30 days, on the card and as a sort (U15) | **Level** |
| Facts beside the card | A right rail: format, licence, task, rows, splits with sizes, used by | In the card itself: types, splits, classes, lineage | Level; licence and task wait on card editing (parked) |
| Search | `/` opens a palette grouped by kind | `Ctrl K`, datasets, tabs, items and actions | **U17**: ranked, grouped, says why, on every page |
| Grid or list | Yes, in the URL | Yes, in the URL | Level |
| Lineage | Model to dataset, on both pages | The same (C3) | Level |
| Compare two versions | No | Files, rows, annotations, pictures | **Ahead** |
| Annotations, media, health, restricted data | A row viewer only | Drawn, played, checked, blurred | **Ahead** |

- ~~**U13. "Use this", one tab per way in.**~~ (built 2026-11-27.) The panel
  stacked the cid command, a Python snippet and a Hugging Face snippet. It is tabs
  now, each paste-ready with this server's address and the pinned version: `cid`
  (the command, its format and subset, as before), `datasets` (or `transformers`
  for a model), `huggingface_hub` (`snapshot_download`: the version's files) and
  an AI agent (the MCP line). Each is something `tests/hf_client.sh` or
  `tests/mcp_client.sh` drives for real. Left out until a test runs them: DuckDB,
  pandas and Polars over the door. A restricted dataset shows the same tabs: both
  doors apply its limits and log its reads themselves.
- **U14. Say what the server is still doing.** *Built 2026-11-27: the header's
  "preparing this version · previews: N to go", from the `pending` route.* A new head is prepared in the
  background (statistics, browse index, items file, export), previews are drawn one
  file at a time, and a release's git copy may be waiting; today only git's state is
  said. In the dataset's header, one quiet line while any of it is pending
  ("preparing this version", "previews: 1,240 of 50,000", "not in git yet"), from
  `version_jobs`, the `previews` queue and the git queue; gone when done. No drawer,
  no page of its own: cid has no jobs a person starts. One read route; about a day.
- ~~**U15. How much a dataset is read.**~~ (built 2026-11-28.) A card shows the
  clones, pulls and checkouts of the last 30 days, and the home page sorts by them.
  Counted per dataset and day (`dataset_reads`, migration 0013) where the server
  hands the CLI a version's items; never who. Not counted, until someone asks:
  reads through the Hugging Face and MCP doors.
- **U16. cid's own icons.** *First pass built 2026-11-27 (35 icons, on the tabs,
  the header, cards, the sidebar, Health and type tiles; `docs/dashboard.md`, 3.5).
  Copy, download and compare's marks followed the same day. Left: the screens
  photographed again (done 2026-11-28: 61 pages, both themes, three widths; two
  phone-width faults found and fixed, the measured report empty).* *Asked for by the owner 2026-11-27: the dashboard has
  few icons, and reads plainer than it should.* Today's marks are type and Unicode
  (`✓`, `!`, `★`, `×`, `?`), which differ from font to font. One small set, drawn
  for cid in the airship's hand (`docs/dashboard.md`, 3: the workshop up close):
  a 20 px grid, 1.5 px strokes in the text's colour, square caps, brass for the one
  accent a drawing may carry. Inline SVG from one file (`web/src/icons.tsx`), no
  icon font and no dependency. Where they go, in the order to draw them:
  1. **What a thing is:** the three kinds (files, annotated, model) on cards, the
     header and the sidebar; file types on a type tile (table, text, sound, video,
     document, archive, weights, unknown), so a tile says more than `.bin`.
  2. **Where you are:** the six tabs, the sidebar's group titles, a folder and a
     file in the Files tab and compare's tree.
  3. **What you can do:** copy, download, star, compare, pin, reveal, open in git,
     clear, show command, sort, the cards and list switch.
  4. **How it is:** pass, warning, fail, restricted, purged, not in git yet,
     preparing (U14); added, changed, removed in a compare.
  Rules: an icon never stands alone where words fit (a label beside it, or an
  accessible name where they do not); never colour alone; none inside a table of
  data or over a picture (3.4, calm data areas); the whole set under 8 KB gzipped,
  inside the first-load budget. Done when every Unicode mark above is replaced,
  the screens are photographed again in both themes (as U1), and axe still passes.
  About two days: the drawing is the work.

- **U17. Search, the front door.** *Asked for by the owner 2026-11-28: once a server
  holds hundreds of datasets and models, search is how anyone gets anywhere, and
  Hugging Face's is good.* What Hugging Face does well: a box on every page that
  answers as you type, results grouped by kind, Enter for the full list, and a
  full-text search of cards. What cid has: a top-bar box that answers only on Enter,
  a home page box that matches a substring of names, classes, types and owners in
  no order, and a `Ctrl K` palette with a flat list of twelve.

  Where cid should end up, and where it beats Hugging Face:
  1. **One engine, three doors.** The top-bar box, the home page and the palette
     ask the same code (`web/src/search.ts`), so a thing found in one is found in
     all, in the same order.
  2. **Ranked, and forgiving.** Words in any order; a name's start beats its
     middle, the last part of a path beats a folder above it, a name beats a class
     beats an owner; one mistyped letter still finds it. Hugging Face matches
     substrings of the repo id.
  3. **It says why.** Each result shows what matched, marked: the part of the
     name, or "class person", "owner Olu", "release v1.2 notes". Hugging Face
     shows the name alone.
  4. **Instant, as you type, on every page**: the top-bar box opens its results
     under itself, grouped (datasets, models, then this dataset's releases and
     items), each with its kind's icon, size and newest release; arrows and Enter;
     `/` reaches it from anywhere. Enter with nothing chosen opens the home page
     with the words as its search. Empty, it offers starred and recently viewed.
  5. **Words that filter**: `kind:model`, `type:.wav`, `class:person`,
     `owner:olu`, `group:org/speech`, `health:fail`, `is:restricted`,
     `has:release`, typed in any box, offered as you type, and shown as the
     sidebar's chips. Hugging Face's quick search has none.
  6. **What is inside, not only names**: classes and file types (now), release
     names and their notes, the newest commit messages. The card's own text waits
     on card editing (parked).
  7. **A file by its path, across every dataset** ("where is `calib-0042.wav`?"):
     the one part that needs the server, since paths live in each version's browse
     index. Its own design first: which versions (heads only), how many datasets a
     query may open, and the budget. Not in the first slice.
  8. **Budgets**: results repaint within 50 ms of a keystroke with 1,000 datasets
     loaded, and the listing they come from answers in under 500 ms at that size
     (measured, with a seeded server; today's listing signs four thumbnails a
     dataset, which will not hold at 1,000 and is part of this item).

  Built 2026-11-28: the engine with ranking, typo tolerance and "why" (2, 3), the
  top-bar box (4), and the home page and the palette on the same engine (1).
  Next, in order: the filter words (5); release notes and messages in the
  listing (6); the 1,000-dataset measurement (8); the design for 7.

Looked at and not taken: discussions and pull requests on a dataset (the paired git
repository's host has them); collections and likes (stars and groups cover it until
someone asks); mirroring from huggingface.co (`deploy/import-tags.sh` and
`docs/coming-from.md` bring a dataset in once, with its history); a scan of model
files for unsafe pickles (cid does not interpret file contents, invariant 15);
uploading and editing files in the browser (invariant 17); storage quotas and an
admin area (dashboard administration is parked); a form to edit card metadata
(card editing is parked, and licence and task facets wait on it).

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
- **B6. More Browse filters:** ~~annotation count~~ (done 2026-11-20: buckets, index
  format v3); ~~attributes~~ (done 2026-11-21: index format v4); ~~identities~~
  (done 2026-11-21: index format v5); ~~the List view~~ (done 2026-11-21);
  ~~changed since a release, size~~ (done 2026-11-25); ~~author and labelling
  policy version~~ (done 2026-11-25: index format v6);
  ~~histograms~~ (done with U6).
- ~~**B7. Branches on the tape and pinning a commit**~~ (done 2026-11-20: `?commit=`,
  `?branch=`). Comparing a branch with `main` came 2026-11-21: on a branch the compare
  pickers offer main's versions too, grouped, and "Compare with main" puts main's head
  and the branch's in the URL.
- ~~**B8. `coco` and `voc` exports**~~ (done 2026-11-20; checked with pycocotools:
  loads, `annToMask` matches every area; migration 0005).
- ~~**B9. "Show command" and the `⌘K` palette**~~ (done 2026-11-20; the palette
  jumps to places; actions in it came 2026-11-21).

- **B10. Cleanup for built files.** *Found and built 2026-11-27: `cid admin gc` takes them
  (`src/core/derived.zig`, docs/data-model.md, "Cleanup").* `cid admin gc` looks at
  items and abandoned uploads only. A version's built files (`exports/`, `states/`,
  `diffs/`) are written again under a new name whenever they change (a provisional
  one made final, the yolo layout of 2026-11-27), and the old object stays in
  storage for good. gc should list those no `version_files` row or kept diff names,
  older than the retention period, and delete them only with `--apply`, as it does
  items (invariant 10).

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
streaming. A split's file is built once and kept. At 1M items its first build takes
58.6 s for an 800,000-item train split, longer than a Hugging Face client waits for
a file's metadata (10 s), so the background worker builds every split's file of an
annotated release ahead of its first reader, and a release is queued again even
when its commit was prepared as a head (2026-11-21: after preparation, 1–4 ms).
Branch heads and commits are still built on a first request.
**Models: done with C2 (2026-11-20),** on `/api/models/…` and at the root.
**Checked by the real clients in CI** (`tests/hf_client.sh`, 2026-11-23): refs, files,
downloads, `snapshot_download`, `load_dataset` (a table's splits, streaming, an annotated
dataset's items with their boxes) and a model's files.

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
  name, so every file is checked again on every run. Each commit has a 40-hex alias
  that maps back without a table: its 32 hex digits, then `00000000` (built).
- **A revision is a release, a branch, or a commit id** (either form), resolved on the
  server in all three routes.
- **Never send an `X-Xet-*` header.** Without one the client downloads over plain
  HTTP with no configuration.
- **A redirect to another origin** (the file store) is handled: the client reads the
  metadata from the 302 itself and drops `Authorization` before following it.
- **Serve over https.** The client maps a 401 to "repository not found" only for
  `https://` endpoints.

What each kind serves: a file dataset or a model, its files as committed; an annotated
dataset, its items at their paths plus `_annotations/<split>.jsonl.gz` and a generated
`README.md` naming those as the splits. A restricted dataset is served under the same
rules as a clone, each read logged as a download.

Fully done when a test drives the real Python clients against `cid admin serve`:
`snapshot_download`, `load_dataset` (a file dataset of Parquet or JSONL, and an
annotated one) and `from_pretrained` (a tiny model), each at a release, with a second
run that downloads nothing. All of these were checked by hand; the automated test
needs Python and those libraries on the test machine: a new test-only dependency, to
be agreed first.

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
not installed for the check). `tests/usability.sh` makes a model, tags it
`--trained-on`, and checks each refusal's hint.

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

~~Per-dataset deploy keys~~ (done 2026-11-22: SSH, read or write, owners add them
with `cid deploy-key`; docs/access.md) · the Health tab (~~cid's own checks~~ done
2026-11-22, docs/dashboard.md 4.5) and Validator tiles (wait on the platform's report
format) · ~~the SQL console~~ (done 2026-11-23: on the server, sandboxed; docs/dashboard.md
4.3) · ~~PDF page images~~ (done 2026-11-23: the first page, by `vips`, as the
thumbnail; the first ten pages in the drawer) · ~~access from other git
hosts (GitHub first)~~ (done 2026-11-22: GitHub sync, create check and sign-in, one
host per server; the live check, `tests/github_live.sh`, waits on a real token) · ~~DuckDB pinned for other platforms~~ (done 2026-11-21: Linux
arm64 and macOS, built and tested in CI; Windows not yet) · dashboard Phase 3.

## 7. Tier E: reach

Direction set 2026-11-25, with the owner's brief: cid should serve people the way
git, DVC and Hugging Face do, and the tools that win now are the ones an AI coding
agent can reach and drive. Until this tier, trying cid meant reading `CLAUDE.md`
and assembling a server by hand. In order:

- ~~**E1. cid on your own machine in one command**~~ (done 2026-11-25). An image of
  the server (`Dockerfile`), a compose stack with the database and the file store
  (`deploy/compose/`), a walkthrough from nothing to two releases, a clone and the
  git record, and `tests/quickstart.sh` running that walkthrough word for word, in
  CI. It needed `cid admin serve --host`, and `sslmode` carried through `CID_DB`:
  the first run of the stack could not reach its database, which is on another
  host, without TLS, and nothing said why.
- ~~**E2. Binaries**~~ (done 2026-11-26). A version tag (`v1.2.0`) becomes a
  release (`.github/workflows/release.yml`): cid built at that version for the four
  platforms, the dashboard embedded, packed with its DuckDB library
  (`deploy/package.sh`), with checksums. `install.sh` installs it for one user with
  no root, checks the download, and upgrades in place. `tests/install.sh` packs and
  installs on every platform on every push, so the release's steps are never run
  for the first time on a tag. No tag has been pushed: the first release is the
  owner's call.
- **E3. cid for agents.** An agent that meets a cid folder or address should be able
  to work it with no document in its context, as it works git. What exists:
  `--json` on every command, exit codes with one meaning each, every error naming
  the next command. To add, in this order:
  1. ~~`cid help --json`~~ (done 2026-11-25): every command, its usage and flags,
     whether it needs the server, what it changes, and what each exit code means,
     as one document. A unit test holds its table and the words `cid help` prints
     to the same commands.
  2. ~~An agent guide~~ (done 2026-11-25): one page, served by every cid server at
     `/llms.txt` with no sign-in (`web/public/llms.txt`): what cid is, the loops
     for reading and changing, getting in without a person, and what not to try.
  3. ~~A check that it works~~ (done 2026-11-25): `tests/agent.sh`, a session
     driven by `--json` output and exit codes alone, stdin closed, in CI. Writing
     it found three places that answered a program in prose: an unknown command, a
     pull stopped on conflicts and a merge stopped on conflicts. All three are JSON
     now, the conflicts as a list of paths and decisions.
  4. ~~An MCP door~~ (done 2026-11-26; docs/access.md, "The MCP door"). Read-only,
     at `POST /mcp` with a personal token: nine tools (datasets, releases, commits,
     a page of items, a folder, a compare, a SQL SELECT, health). It is an adapter
     over the dashboard's read routes, so access, a restricted dataset's limits and
     the logging of its reads are those routes' own; the protocol is written by
     hand over nilo's HTTP, with no new dependency in cid. The official client
     reads it in CI (`tests/mcp_client.sh`, test-only), which is how a `ping`
     answered as a list instead of an object was caught before anyone met it.
     Next for this door, when asked for: the MCP config on the dashboard's Tokens
     page, beside a new token.
- ~~**E4. Coming from DVC, Git LFS or Hugging Face**~~ (done 2026-11-26:
  `docs/coming-from.md`). What each habit becomes, what cid does not do (pipelines,
  file locking, a public hub), and a loop that brings an existing dataset in with
  each of its git tags as a release. Corrected 2026-11-26: the five-line DVC loop
  written here first was never run against DVC, and was wrong (in a fresh clone
  `dvc checkout` fails before `dvc pull` runs, so it released nearly empty
  folders, silently). The DVC and Git LFS imports are now one script,
  `deploy/import-tags.sh`, with `tests/import_tags.sh` against both real tools.

- **E5. FiftyOne, with no glue code.** *Asked for by the owner 2026-11-27.*
  [FiftyOne](https://voxel51.com/fiftyone) is where many vision teams look at a
  dataset and hunt its label mistakes. cid versions the dataset; FiftyOne should
  open any version of it in one line, and nothing here duplicates its app. cid
  already writes what FiftyOne reads (COCO, YOLO, VOC folders, and the Hugging
  Face door), so most of this is proving it and closing the gaps the proof finds.
  In order:
  0. **Tried by hand, 2026-11-27** (FiftyOne 1.22.1 in a container with a MongoDB
     beside it, on the demo's street-scenes v1.1: 50 photos, 226 boxes), before any
     test was written:
     - **COCO loads, with two arguments**: `data_path=<folder>` and
       `labels_path=<folder>/annotations/instances_<split>.json`, a split at a
       time (39 + 6 + 5 samples, 179 + 25 + 22 boxes: cid's own counts). With no
       arguments it looks for `data/` and `labels.json` and refuses. It needs
       `pycocotools`, which FiftyOne does not install.
     - **VOC loads, with two arguments**: `data_path=<folder>`,
       `labels_path=<folder>/Annotations` (50 samples, 226 boxes). With none it
       looks for `data/`.
     - **YOLO was refused, and that was cid's fault** (fixed 2026-11-27):
       "YOLOv5 image paths must contain '/images/', which is replaced with
       '/labels/'". cid wrote a photo at its own path (`frames/a.jpg`) and its
       label at `labels/frames/a.txt`. Ultralytics finds labels by the same
       replacement and, run for real (8.x, in a container), refused the old
       folder too: `path: .` in `dataset.yaml` is read from where the trainer
       runs, not from the file. The export now keeps photos under
       `images/<path>`, names them `./images/<path>` in the split lists, and
       writes no `path:` line; a `--format yolo` clone places its files there,
       and one made before is moved the next time a command opens it
       (`.cid/layout`), still clean to `cid status`. Checked by hand against
       both tools: FiftyOne loads it with no arguments but the split
       (`dataset_type=fo.types.YOLOv5Dataset, split="train"`), and Ultralytics
       builds its training set from it (39 photos, 179 boxes: cid's counts).
       Left to say on the page: Ultralytics wants a `train` and a `val` split,
       and a dataset with only one gets a `dataset.yaml` it refuses; cid lists
       the splits a dataset has and invents none.
  1. ~~**Prove the folders load.**~~ (done 2026-11-27: `tests/fiftyone_client.sh`,
     FiftyOne 1.22.1, test-only, in CI.) One release cloned as yolo, coco and
     voc, each loaded as a person would: yolo with the split alone, coco and voc
     with `data_path` and `labels_path`; the box is where cid has it. FiftyOne
     keeps its datasets in MongoDB, so the test starts a throwaway one in docker.
     Ultralytics was run by hand only (it brings PyTorch, too heavy for every
     push).
  2. ~~**One line from the hub door.**~~ *Looked at 2026-11-28 and not built.*
     FiftyOne's hub loader (`fiftyone.utils.huggingface.load_from_hub`, 1.22.1,
     read in its source) cannot be served well from cid's side:
     - it uses `revision` only to find `fiftyone.yml`; the data is then
       downloaded with no revision at all ("for now don't support multiple
       revisions storage"), so a release asked for by name would show `main`'s
       data under it, silently;
     - its other path, for Parquet repos, asks a hard-coded
       `datasets-server.huggingface.co` for rows, whatever `HF_ENDPOINT` says: it
       would send the dataset's name to Hugging Face and get nothing;
     - what is left is FiftyOne's own dataset format (`samples.json`), private to
       it and tied to its version: the FiftyOne-only format this item ruled out.
     The way in that pins a release is the one built: `cid clone --format yolo`,
     then `fo.Dataset.from_dir`. Reopen if FiftyOne's loader learns revisions.
  3. ~~**Say it on the page**~~ (done 2026-11-27): a FiftyOne tab in "Use this"
     on annotated datasets: the yolo clone at the pinned release, then the lines
     that open it, a split at a time.
  4. **Keep where it came from.** Each FiftyOne sample carries the cid item id,
     path and release it was loaded from (the jsonl export has them), so a view
     made in FiftyOne (the suspected mistakes, a hard slice) can be named back to
     cid as item paths: `cid clone --items <file>` or the Browse link for them.
     This needs a design first: a clone narrowed by a list of paths is new.
  Not in it: writing labels from FiftyOne into an annotated dataset (annotations
  change only in the annotation platform, a non-goal), running FiftyOne on the
  server, or its plugins. A restricted dataset is never offered to it through the
  dashboard's snippets; the door's own rules already hold. Left: item 4, which waits on its design.

Left in this tier, each waiting on something outside the code: the first release
(the owner pushes the tag), and the MCP config shown beside a new token on the
dashboard's Tokens page.

## 8. Parked, not planned

Everything on `CLAUDE.md`'s "explicitly not now" list, card editing and releases from
the dashboard, and from this round: uploads through the Hugging Face API (since
client 1.20.0 they go through Xet with no fallback), mirroring huggingface.co, and
model registry features (stages, approvals, serving, metrics).
