# cid — version control for datasets

**cid · Controlled Iterative Datasets**

`cid` gives datasets what git gives code: history, releases, diffs and one-command
downloads. It works for **any kind of data**: images, video clips, audio, text, documents,
tables (CSV, Parquet, JSONL), point clouds, or anything else stored as files, plus the
annotations on them. History lives in **TimescaleDB**, files in **SeaweedFS** (S3 API).

## The core idea: DVC lives inside git. Git lives inside cid.

This is the one sentence that explains cid. Put it first in the README, the docs home
and any talk about cid.

| | **DVC** (and Git LFS) | **cid** |
|---|---|---|
| Where you work | In a git repository | In cid |
| Source of truth for versions | Git commits, holding pointer files | cid itself (TimescaleDB + SeaweedFS) |
| What git holds | Pointer files you must commit, next to every data change | A readable record cid writes by itself: dataset card, release notes, stats |
| Commands per change | Two tools: `dvc add` + `git add`, `git commit`, `dvc push` + `git push` | One tool: `cid add`, `cid commit`, `cid push` |
| Git at scale | Slows down with many data files and pointer files | Never touched by data; one small commit per release |
| What git's web UI shows | Pointer files | The dataset's history, readable, next to your code, with links into the cid dashboard |

**DVC bolts data onto git. cid runs data natively and writes git for you**, so the
people who live in GitLab still see every dataset release there, without git ever
carrying the data or slowing down, and without anyone learning two tools.

When explaining cid in any text (docs, help, errors, dashboard, marketing), keep this
framing: git is an automatic, read-only output of cid, never a requirement for using it.

Why "cid": a tribute to the engineer who builds the airship in every classic JRPG:
the tinkerer who keeps the machine running. Short, easy to say, easy to type:
`cid clone`, `cid pull`, `cid commit`. Always written in lower case.

It also stands for **Controlled Iterative Datasets**, which is what cid does:
- **Controlled**: every change is reviewed, checked against the policy, attributed to
  someone, and tied to a release.
- **Iterative**: datasets grow in loops: annotate, review, fix, release, retrain, feed
  the misses back in. Each loop is a new release.
- **Datasets**: any data, with its annotations.

Use the expansion as the tagline ("cid · Controlled Iterative Datasets") in the README
and docs home; in the product UI it appears in exactly three places (sign-in page,
dashboard footer, `cid --version`). The command and the name in running text stay
lower case `cid`; write "CID" only when spelling out the acronym. Like git's README,
the docs may add playful mood meanings, but every one must be about datasets:
- *Clean, Inspected Datasets*: when a release passes validation.
- *Corrupted Items Detected*: when the validator finds broken files.

The official expansion is always Controlled Iterative Datasets.

**Name and brand rule:** the name is a tribute only. Never use Final Fantasy or Square
Enix names, characters, logos, fonts, icons, art, music or recreated UI elements
(menus, cursors, airship designs) anywhere in the product, docs or marketing. The look
is our own; see "Design language" in `docs/dashboard.md`. In docs, spell out that `cid`
the tool is not an IPFS "CID" (content identifier), since both deal with content hashes.

cid has three faces: the **CLI**, the **server**, and a **web dashboard** for browsing,
comparing and downloading datasets, designed to be a better experience than Hugging Face
dataset pages (`docs/dashboard.md`). The CLI and server are written in **Zig**; the
dashboard is React + TypeScript, built to static files and embedded in the server
binary. The agent-first annotation platform (Go) is one of cid's users, not the only one.

**Every dataset is paired with a git repository** (on GitLab.com by default, or any
other git host). cid writes its own files there: each release lands as one small git
commit and tag (dataset card, release notes, stats, manifest summary); the data itself
and everything heavy link to the cid dashboard. Anything else in the repository,
such as code beside the dataset, is left as it is. Full spec: `docs/git-repository.md`.

---

## Status, scope and license — the decisions on record

- **Internal first, product-shaped.** cid is built for our own datasets and the
  annotation platform, but as a generic open-source tool anyone can self-host — a
  different concept from DVC, worth sharing. Nothing in it may hard-code our org.
- **License: GPL-2.0-only** — exactly git's license (`LICENSE`). The repo goes public
  at the first usable release; until then the schema and protocols may break freely.
- **Explicitly not now** (ideas parked, not rejected; building any of these needs a
  decision first): a hosted "cidhub" cloud and anything multi-tenant; billing;
  email one-time-link sign-in; complex dashboard administration; several git hosts on
  one server (a possible premium feature of that service; one host per server until
  then, `docs/access.md`, "Other git hosts"). When a design choice
  appears that only matters for the hosted cloud, choose the simple internal answer.
- **First milestone ("cid exists") is reached:** the file-dataset round trip against a
  real server, the SSH front door, the git writer, previews and the dashboard all run.
  A GitLab Maintainer of the repository a dataset's `--git` URL names creates it with
  only an SSH key (checked live with GitLab; the repository must be on that GitLab). Restricted datasets are enforced by the
  server inside per-dataset access, by decision: no row-level security (invariant 11).
- **AI stays out of cid.** cid never calls an LLM or judgment API (TypeSafe/Jev
  included) in the CLI or server. The one permitted future exception is advisory-only
  dashboard scoring, Phase 3 at the earliest, decided then (`docs/dashboard.md`). The
  annotation platform is where AI lives; cid's brand is determinism.

---

## The most important rule: as easy as git, or easier

Anyone who knows git must be able to use cid without reading docs. Anyone who does not
must be able to use it after reading `cid help`.

1. **Same verbs, same meaning as git.** `add` stages, `commit` saves locally (instant,
   works offline), `push` uploads, `pull` downloads. A git user's habits must just work.
   Never reuse a git verb for something different.
2. **Everyday use is a handful of commands:** `clone`, `pull`, `checkout`, `status`,
   and for people who produce data, `add`, `commit`, `push`.
3. **No login, just SSH keys, exactly like git.** Datasets have addresses like git
   remotes: `cid@cidhub.com:your-org/datasets/person-vehicle`. The SSH key you already
   use for GitLab is your identity (or one you add on the dashboard's SSH keys page);
   if you can open the dataset's GitLab project, you can clone the dataset. Creating a dataset asks for exactly two addresses: the cid
   address and the dataset's git repository (`cid init <address> --git <git-url>`).
   A cloned folder already knows both. The staging area behaves like git's, and
   `cid commit -a` skips it.
4. **Defaults that just work.** `cid clone` gets the latest release; inside a cloned
   folder no dataset name is needed.
5. **Every error says what to do next**, e.g. `Someone pushed since you pulled.
   Run 'cid pull', then 'cid push' again.`
6. **`cid help` shows only everyday commands.** Server administration lives under
   `cid admin`.
7. **Never more complicated than DVC.** If a feature needs a pipeline file or a second
   tool on the user's machine, it does not belong in cid. Users never run git commands
   for cid to work; cid writes to the dataset's git repository by itself, on the server.

When a design choice trades simplicity for power, choose simplicity and ask first.

---

## Two kinds of dataset

| | **File dataset** | **Annotated dataset** |
|---|---|---|
| What it holds | Any files, in folders, exactly as you put them | Items (images, clips, audio…) plus structured annotations |
| Who changes it | People and scripts, from a folder: `cid add`, `cid commit`, `cid push` | The annotation platform (agents + reviewers), through the server |
| Typical use | Text corpora, audio sets, tables, documents, model inputs, anything | Vision datasets built in the annotation platform |
| Clone gives you | The same folder tree | A ready-to-train export (`yolo`, `jsonl`; `coco` and `voc` planned) |
| Diff shows | Files added/removed/changed; rows added/removed for CSV, Parquet, JSONL | Items and annotations added/removed/changed |

Both kinds share the same history model, releases, storage and commands. Annotations in
a file dataset are just files (e.g. `labels.jsonl`); structured annotations exist only in
annotated datasets.

---

## How people use it

### Anyone reading a dataset

```bash
cid clone cid@cidhub.com:your-org/datasets/speech-id    # no login: your SSH key
# the git URL copied from GitLab works too:
# cid clone git@gitlab.com:your-org/datasets/speech-id.git
cd speech-id
cid log                               # commits newest first, releases named
cid checkout v1.3.0                   # switch release; only changed files download
cid pull                              # get the newest
cid diff v1.2.0 v1.3.0                # what changed
cid status                            # your branch, anything edited or unpushed
```

### Someone producing a file dataset

```bash
cid init cid@cidhub.com:your-org/datasets/call-transcripts \
  --git git@gitlab.com:your-org/datasets/call-transcripts.git
                                      # create the dataset from the current folder,
                                      # paired with its git repository (required),
                                      # on the server's GitLab when it syncs one
cid add .                             # stage every added, changed and deleted file
cid commit -m "Add March calls"       # save locally: instant, works offline
cid push                              # upload; resumes if the connection drops
cid tag v1.0.0                        # make a release (on the server, after push)
cid branch cleanup                    # a draft line of work (starts from main)
cid checkout cleanup                  # work on it: add, commit, push as usual
cid merge cleanup                     # into main; stops and lists conflicts, if any
```

Also as in git: `cid add audio/march/` stages one folder, `cid restore --staged <path>`
unstages, `cid restore <path>` throws away local edits, `cid commit -a` stages every
change to tracked files and commits in one step (new files still need `cid add`).

If someone else pushed since your last pull, `cid push` refuses and tells you to
`cid pull`. `cid pull` then puts your unpushed commits on top of theirs automatically
**only when you changed different files**; if you both changed the same file, it lists
the conflicting paths and stops. You resolve each one with
`cid checkout --mine <path>` or `cid checkout --theirs <path>` (same words as git),
then `cid pull --continue`; `cid merge` conflicts resolve the same way, then
`cid merge --continue`. Nothing is merged silently.

### Annotated datasets (from the annotation platform)

Engineers use the reading commands above.
`cid clone cid@cidhub.com:your-org/datasets/person-vehicle` gives a ready-to-train
folder in the dataset's default format; `--format jsonl` (or `yolo`) for another, and
`--split train --class person` for just part of it. In such a clone,
`cid add` refuses with: `This is an export of an annotated dataset. Annotations change
in the annotation platform; run 'cid pull' to update.` The platform does commits and
releases through the server API, and must give the dataset's git repository URL at
creation, exactly like `cid init --git`.

### Admins

```bash
cid admin setup        # create the database schema (the bucket is the deployment's job)
cid admin migrate      # apply new SQL migrations
cid admin verify <dataset> <release>   # rebuild a release and check its hash
cid admin gc [--days n] [--apply]      # show unreferenced files and abandoned uploads; --apply deletes
cid admin purge <dataset> <path|hash> --reason "why"   # audited erasure (docs/data-model.md)
cid admin serve        # run the cid server (its background loop also drains previews,
                       # syncs GitLab and retries git writes)
cid admin previews     # one pass of the preview worker
cid admin sync-gitlab  # sync members and SSH keys now
cid admin git <dataset>            # git repository status: releases written, errors, and
                                   # whether it still holds what cid wrote (exit 3 if not)
cid admin git <dataset> --resync   # write any pending releases into the repository
cid admin add-key <account> <name> <public-key>   # register a key by hand
cid admin grant <dataset> <account> <read|write|maintain>
cid admin rename <dataset> <new-path> [--git <url>]   # after its GitLab project moved;
                       # rewrites the repository's files to name it, with git;
                       # the same path with --git when only the repository moved
```

### CI and scripts

CI jobs use a personal token, made on the dashboard's Tokens page (acts as its maker,
expires, revocable), in an https address as git takes credentials, or in `CID_TOKEN`:

```bash
cid clone https://ci:$CID_PAT@cidhub.com/your-org/datasets/speech-id
cd speech-id && CID_TOKEN=$CID_PAT cid pull   # a folder never keeps the token
```

Administrators can still use `CID_SERVER` + `CID_TOKEN` with the server's static token
(full access; it wins over everything). The CLI writes no credentials file. Per-dataset
deploy keys are planned, not built.

---

## Goals and non-goals

**Goals, in order:** correct (a release can always be rebuilt exactly), simple, fast,
cheap (every file stored once, compressed history, no extra database), and pleasant to
browse (a dashboard that never says "viewer not available", shows media as media, and
makes every change between versions visible).

**Non-goals** (do not build without an explicit decision):
- Editing structured annotations from a local folder. They change only in the platform.
- Splitting files into chunks for partial-change storage. A changed file is stored
  again in full; large tables should be split into partitioned files.
- Nested branches, user-facing rebase, cherry-pick, rewriting pushed history,
  multiple remotes. (Pull replaying unpushed commits is internal, not a rebase command.)
- Automatic conflict resolution. A person always decides.
- Pipelines, experiment tracking, training, or running models.
- AI/LLM calls anywhere in the CLI or server (see "Status, scope and license").
- Everything on the "explicitly not now" list above.

---

## Words (use exactly these, in code, CLI and docs)

| Word | Meaning |
|---|---|
| **dataset** | A versioned collection: a **file dataset** or an **annotated dataset**. Identified internally by a stable `dataset_id`; its path can be renamed |
| **item** | One item of a dataset, identified by `item_id`, which **survives re-encoding**; its current content is a file stored once by its BLAKE3 hash (`item_hash`) |
| **path** | Where an item sits in the dataset's folder tree, e.g. `audio/2026-03/call-0012.wav` |
| **annotation** | Structured information on an item, in annotated datasets: box, polygon, points, mask, transcript, time segment, text span, class, identity, value. Attached to `item_id`, not to the bytes |
| **change** | One add/update/delete of an item path or an annotation. Never edited afterwards |
| **staged** | Changes chosen with `cid add` for the next commit (kept in `.cid/index`) |
| **commit** | A saved point: "all changes up to here". Copies nothing. Made locally by `cid commit`, or on the server by the annotation platform |
| **local commit** | A commit not yet pushed; lives only in `.cid/` until `cid push` |
| **push** | Uploading local commits and their new files; accepted only on top of the server's latest commit |
| **branch** | A draft line of work. Always starts from `main` |
| **release** | A tag on a commit, e.g. `v4.2.0`. Never moves. Has a manifest |
| **manifest** | The canonical listing of every item (path, item_id, hash, size, split) and annotation in a release, hashed (`manifest_hash`) and stored as `manifests/<dataset_id>/<commit_id>.manifest` |
| **dataset path** | The dataset's full name, like a GitLab project path: `your-org/datasets/person-vehicle` |
| **address** | Where to reach a dataset, git-style: `cid@cidhub.com:your-org/datasets/person-vehicle` (a trailing `.cid` is accepted and ignored) |
| **dataset repository** | The git repository paired with a dataset. cid writes one git commit and tag per release, to its own files only; anything else there is left alone |
| **owner** | Anyone with the Maintainer role on the dataset (tag, branch, merge, edit the card) |
| **version** | A release or commit, as shown in a version picker |
| **purge** | The audited, logged erasure of one content's bytes and previews — the single exception to "items are immutable"; history rows stay |
| **Validator** | The annotation platform's quality-audit service; cid only stores and shows its reports |

In user-facing text say "release", not "tag", except in the `cid tag` command itself.

---

## Architecture

```
  Annotation platform (Go)       people and scripts          readers
  item bytes via server API;     (cid push)                  (cid clone / pull)
  revisions via INSERT                │ token                    │ token
          ▼                           ▼                          ▼
  ┌──────────────────────┐    ┌───────────────────────────────────────┐
  │ TimescaleDB          │◀──▶│ cid server: commits, releases, diffs, │
  │  item_revisions      │    │ manifests, uploads, presigned URLs    │
  │  annotation_revisions│    └───────────┬───────────────┬───────────┘
  │  items, commits,     │                │               │ on each release:
  │  refs, policies      │                ▼               ▼ git commit + tag
  └──────────────────────┘    ┌─────────────────┐  ┌──────────────────────────┐
                              │ SeaweedFS (S3)  │  │ GitLab.com (or any git   │
                              └─────────────────┘  │ host): one repository    │
                                                   │ per dataset, small files │
                                                   │ only, links back to cid  │
                                                   └──────────────────────────┘
```

- **TimescaleDB** holds all history; both revision tables are compressed hypertables.
  Schema and integrity rules: `docs/data-model.md`.
- **SeaweedFS** holds items and everything derived from them (see Storage layout).
  Clients reach it only through short-lived presigned URLs handed out by the server,
  never with their own credentials.
- **The cid server** is the only thing users talk to: SSH to prove who they are, then
  HTTPS with a short-lived token for everything else (`docs/access.md`). HTTP serving,
  Postgres and S3 all go through **Nilo** (see Zig conventions); TLS terminates at a
  reverse proxy in front of both the server and the file store (`deploy/proxy/`: a
  Caddyfile and an nginx config, checked by `tests/proxy.sh`). The dashboard also
  signs people in with GitLab (OAuth: `CID_GITLAB_OAUTH_ID`, `CID_GITLAB_OAUTH_SECRET`,
  `CID_PUBLIC_URL`, `CID_SESSION_SECRET`).
- **DuckDB** (C API, in-process on the server) answers every question asked of a
  version: browse pages, subset sizes, folder listings, comparing two versions, table
  statistics and row-level diffs. It is **always linked** (`src/store/duck.zig`):
  libduckdb is a pinned dependency, linked dynamically and installed beside the binary.
  `cid admin serve` opens **one** database for browse queries, confined to its browse
  folder (`CID_BROWSE_DIR`) with a locked configuration, two threads and one memory
  ceiling; every query takes a connection to it, so their memory is bounded however
  many run at once. Index builds and row diffs run one at a time each, in a one-thread
  database of their own (one thread keeps a 1M-item conversion near 250 MB, two near
  600 MB), in `CID_WORK_DIR` / the browse folder. Long calls go to nilo's blocking
  pool (`nilo.blocking`, its ADR 013) so no request thread waits on them. The preview
  worker opens its own.
- **The dashboard** is served by the cid server. Its browse API (`src/server/browse/`)
  answers from each version's browse index — its items in path order and its
  annotations by item, two Parquet files — with one DuckDB query per request: a page
  (items with annotations, counts, facets counted against the other filters, a
  cursor), a subset's size, a folder's listing, or the compare of two versions.
  Filters and facets read only the light columns; only the page's rows fetch hashes
  and annotations. A release's index is written in the same pass as its manifest;
  every built index is kept in storage and in a bounded local cache. A new branch
  head or release is prepared ahead of its first visitor by the server's background
  worker (`version_jobs`, `api.prepareNext`): its statistics, browse index, items file
  and default export, through the same code a request takes.
  An index holds only what the commit seals; media metadata (image dimensions) is
  joined per page. It never scans raw files on page load. Every index, once built, is
  kept in storage as well, so a restart or another server fetches it.

  Measured at 1M items and 1.5M boxes (`tests/bench/browse_1m.sh` and
  `web/e2e/bench.spec.ts`, ReleaseFast, 2026-10-08), server memory never above 410 MB:
  release 33 s, with its change counts (only the paths and annotations written
  since the release before are compared); a new head prepared in the background in
  about 60 s, after which its overview, items file and default export answer in
  1–5 ms; browse pages 0.20–0.37 s; filter change to 60 thumbnails in the browser
  0.30 s; subset size 53 ms; a folder 27–129 ms; compare 1.0 s the first time a pair
  is compared and 51 ms after (the
  pair's diff is kept beside the indexes, and a release's diff with the release before
  it is prepared in the background); `cid diff` 0.43 s, with a 19 MB client.
- **The preview worker** builds thumbnails, audio waveforms, video posters and table
  statistics, sniffing each file's real type and image dimensions as it goes, by
  calling `ffmpeg` as an external program (PDF page images, which need `vips`, are not
  built yet). **ffmpeg never scales with users**: the `previews` queue holds one row
  per content hash, filled at ingest (push, register-items) and drained only by the
  worker — `cid admin serve`'s background loop, or one pass of `cid admin previews` —
  one file at a time, nice -19, -threads 1, hard timeouts, size guards, bounded
  attempts then a recorded skip. Request paths only hand out presigned URLs to previews
  that already exist; a missing preview renders as a placeholder, never a generation.
  Previews are stored in SeaweedFS by item hash; restricted items also get a blurred
  rendition (see `docs/dashboard.md`).
- **The git writer** (`src/gitrepo/`) renders each release's small files and pushes a
  commit and tag to the dataset repository, using the `git` program on the server. It
  runs when `CID_GIT_WORKDIR` is set (otherwise releases queue for
  `cid admin git --resync`); creating a dataset then first proves it can push
  (a throwaway `refs/cid/write-check`). It is plain git only, so every host (GitHub,
  GitLab, Gitea, a path) behaves the same; `cid admin git <dataset>` reads the
  repository back and names any tag or `main` rewritten since cid wrote it (exit 3,
  never repaired). Restricted datasets render counts only.
- **SSH front door:** OpenSSH `sshd` on the cid host accepts only the user `cid`, looks
  up keys through cid, and runs cid's restricted command. SSH only authenticates and
  hands out short-lived HTTPS credentials; data moves over HTTPS in parallel.
- **The annotation platform** uploads item bytes through the server API (hash-verified),
  inserts revision rows directly with the INSERT-only role `cid_writer` (under the
  per-branch write lock; the database mints `rev_id` and `ts`), and uses the server API
  for commit, release, branch, merge, diff and export.

Deep dives: `docs/data-model.md` · `docs/access.md` · `docs/git-repository.md` ·
`docs/dashboard.md`.

---

## Invariants — never break these

1. **Changes are append-only.** No `UPDATE`/`DELETE` on `item_revisions` or
   `annotation_revisions`; writers have INSERT only, and a trigger rejects UPDATE/DELETE
   for everyone unless the maintenance setting `cid.maintenance` is on (migrations
   only). Purge never touches these rows (invariant 19).
2. **Items are immutable and stored by hash.** Write only if absent; all bytes enter
   through the server, which verifies the hash of every upload before recording it.
3. **Commits are sealed.** The database mints every revision's `rev_id` and `ts`
   (`cid_rev()`; writers cannot set them), and revision writes and commit recording
   serialize on the per-(dataset, branch) advisory lock, so no revision can land under
   an existing cutoff. Each commit first checks none did (the backstop refuses to record
   past one), and `cid admin verify` treats such a row as corruption (exit 3).
4. **Annotations attach to item identity** (`item_id`), never to bytes; re-encoding an
   item must never orphan its annotations.
5. **Releases never move.** Tagging an existing name is an error.
6. **Manifests are repeatable.** `manifest_hash` hashes the canonical row stream
   (sorted, fixed encoding, RFC 8785 for JSON fields — `docs/data-model.md`).
   Rebuilding a release from history reproduces the same hash.
7. **Pushes only move forward.** The server accepts a push only if its first commit's
   parent is the server's latest commit on that branch; otherwise it refuses (pull
   first). A push is all-or-nothing: files uploaded first, then commits recorded in
   one transaction. Pushed history is never rewritten.
8. **Branches start from `main` only** and record where they started.
9. **Merges and pulls never resolve conflicts silently.** They list conflicts; a person
   decides.
10. **Cleanup deletes only unreferenced items**: not in any release, not in any branch
    head, older than the retention period. Showing is the default; deleting needs
    `--apply`. Only releases and branch heads are guaranteed rebuildable forever.
11. **Restricted datasets** (e.g. `face-id`) are a flag the server enforces, inside the
    same per-dataset access as every dataset: only people the GitLab role lets in reach
    them at all. On top of that, previews are blurred until a logged reveal, table rows
    and text are withheld, the git repository gets counts only, the activity log is for
    owners only, and every read of their content is logged: clear bytes (downloads),
    browse views, compares, and the item lists and exports a clone reads. cid never logs
    their contents or annotations, at any log level, and never sends their items to any
    external service by default. Decided 2026-10-08: no Postgres row-level security
    (TimescaleDB refuses it on compressed history, and on a private deployment the
    database's only other users are its administrators).
12. **Hash existence is never an oracle.** The push dedup check confirms a hash only if
    this dataset already holds those bytes (`dataset_hashes`); anything else must be
    uploaded and verified again, so a hash learned elsewhere opens nothing.
13. **Stream, never load.** Whole-dataset work streams with bounded memory. On the
    server that means `src/core/version.zig`: a version is read through cursors,
    5,000 rows a batch, each batch freed before the next; manifests are hashed as
    they are written and uploaded from a file; statistics are one SQL aggregate,
    kept on the commit. The CLI reads a version (clone, pull, checkout, diff) as
    a gzip file of JSON lines the same pass writes once into storage, through a
    presigned URL, hash-checked as it streams; it is provisional, and written
    again after ten minutes, while any item still waits for its media metadata.
    `tests/bench/browse_1m.sh` measures all of it at 1M items.
14. **Downloads verify everything.** Every file is hash-checked before it appears in
    the folder; a mismatch fails the command.
15. **cid never interprets file contents except** to read media metadata (the preview
    worker, after upload) and to diff and summarise tabular files. Unknown file types
    are always accepted and stored as-is.
16. **Local state is recoverable.** An interrupted `push`, `pull` or `checkout` leaves
    `.cid/` consistent; running the same command again finishes the job.
17. **The dashboard changes no data** (a person's own stars, SSH keys and tokens aside). Card editing and making
    releases there are parked decisions; annotations are edited only in the annotation
    platform.
18. **One bad file never breaks a view.** If an item can't be previewed or parsed, only
    that item shows an error, in plain words; the rest of the dataset stays browsable.
19. **Purge is loud, logged and minimal.** `cid admin purge` removes bytes and previews
    only, for every dataset holding that content; history keeps its rows and hashes,
    `cid admin verify` reports each affected release "intact except N purged items",
    the hash can never be uploaded again, and the purge itself is an audited activity
    event.
20. **Restricted previews are blurred on the server until revealed**, and every reveal
    is logged. A presigned URL to clear restricted content exists only after the
    logged reveal.
21. **Every dataset has a git repository**, and cid is the only writer of its own files
    there (`render.owned_paths`): one commit and tag per release (plus one untagged
    commit when the dataset is renamed, naming its new path), small text files only,
    never data, never restricted content. Files cid did not write are never changed or
    removed. A git failure delays the git copy; it never blocks or changes a release.
22. **SSH only authenticates.** No data, no shell, no forwarding over SSH; the forced
    command hands out short-lived, single-dataset HTTPS tokens and nothing else.

If a change would weaken any of these, stop and ask.

---

## Storage layout (SeaweedFS)

```
<bucket>/
  items/blake3/<aa>/<bb>/<hex>                any file, stored once, named by its BLAKE3
  uploads/<dataset_id>/<hex>[.part-NNNNNN]    staged uploads (pieces over 64 MB),
                                              verified then stored, or cleaned by gc
  previews/<aa>/<hex>/thumb.webp, blur.webp   thumbnails/waveforms, blurred renditions
  manifests/<dataset_id>/<commit_id>.manifest the release's hashed canonical manifest
  manifests/<dataset_id>/<commit_id>.items.parquet, .anns.parquet
                                              a version's browse index (any version built)
  states/<dataset_id>/<commit>-<subset>-<hash>.jsonl.gz        a version's items, as the CLI downloads them
  exports/<dataset_id>/<commit>/<format>-<subset>-<hash>.jsonl.gz  an export, as a bundle of files
  diffs/<dataset_id>/<a>-<b>-<hash>.jsonl.gz        what changed between two versions
  diffs/<dataset_id>/<a>-<b>.items.parquet, .anns.parquet     the pair's compare, kept
```

S3 client rules for SeaweedFS: path-style addressing, SigV4, real payload hash,
multipart for files over 64 MB (all via nilo_s3), the bucket always named `cid` and
created by the deployment, SeaweedFS version pinned in the test compose file.

Local cache on user machines: `~/.cache/cid/items/<aa>/<hex>` (or under
`$XDG_CACHE_HOME`), shared by every clone and release. Working folders get copies (copy-on-write clones where the filesystem has
them), never hard links: editing a file in place must never change the cached bytes.

Local repository state in each folder's `.cid/`:

```
.cid/
  config.zon        address, git URL, dataset kind, clone format and subset
                    (written by clone/init only)
  HEAD              current branch and commit
  index             staged changes: path, hash, size, mtime (like git's index)
  tracked           the tree as of the last commit: path, hash, size, mtime
  commits/          local commits not yet pushed, one small file each
  last-pushed       the server commit the local commits sit on
  pull-state        a pull stopped on conflicts: each path and its decision
  merge-state       a merge stopped on conflicts: the branch, each path and decision
```

Files added with `cid add` are hashed and copied into the local cache at `add` time, so
`cid commit` is instant and works offline. `cid push` uploads only files the server does
not have (checked by hash, under invariant 12), then records the commits. A file over
64 MB goes up in 64 MB pieces, each its own presigned PUT to
`uploads/<dataset_id>/<hash>.part-NNNNNN`; when the push is recorded the server
streams the pieces in order through BLAKE3 as one file, then copies the verified bytes
into place inside the store (S3 CopyObject, or a multipart copy joining the pieces),
so nothing passes through the server's disk. Resuming needs no local state: re-running `cid push`
asks the server what it still lacks, whole files and pieces alike, and sends only that.

---

## Formats

- **`files`** (default for file datasets): the folder tree exactly as committed.
- **Annotated datasets:** `yolo` (images) and `jsonl` (universal: one line per item with
  its annotations; works for audio, text and anything else). `coco` and `voc` are
  planned, not built; `cid clone` refuses other names.
- Each format is one file in `src/export/`, a streaming writer fed an item at a time
  (with its annotations) by `src/export/bundle.zig`, which reads the version once on
  the server, narrowed in SQL to any `--split`/`--class` subset. An export reaches the
  CLI as a bundle of files (gzip JSON lines, a file's chunks together) that it writes
  into the folder as it streams, hash-checked; the CLI never holds a version's
  annotations. Adding a format never touches `core/`.

**Row-level diff** (`cid diff`) for `.csv`, `.parquet` and `.jsonl`: rows added and
removed, by whole-row comparison (declaring a key column, to see rows changed, is not
built). Row-level diffs are computed **on the server** (where DuckDB lives); the
CLI itself never reads a table. Comparing two versions is the server's job too: DuckDB
joins their browse indexes (annotations compared as stored jsonb text, so formatting
never counts, through a digest the index keeps, so only changed rows are read whole) and the changes are written once to storage as gzip JSON lines, which
`cid diff` prints as they stream in; the dashboard's compare pages through the same
join. A merge reads only the paths
the branch touched; every other path is the base's by construction. Other files are
compared by hash only everywhere. Until a dataset can declare a key column, an edited
row shows as one removed plus one added; when the columns changed, the column change
is the answer and rows are not compared. Each pair of contents is diffed once, ever
(`row_diffs`), one at a time, files up to 128 MB; a restricted dataset gets counts and
columns, never rows.

---

## CLI reference

Everyday (shown by `cid help`):

| Command | Does |
|---|---|
| `cid clone <address\|git-url> [--release v] [--format f] [--split s] [--class c]` | Download into a new folder. No login: your SSH key is your identity. `--split`/`--class` (repeatable) keep only matching items — and, for classes, only those classes' annotations; the folder remembers the subset, `pull` keeps it, and it is read-only |
| `cid pull [--continue]` | Get new commits; replays unpushed commits on top, or lists conflicts (`--continue` once decided) |
| `cid checkout <release\|branch\|commit>` | Switch the folder; `--mine`/`--theirs <path>` decides a listed conflict of the pull or merge in progress |
| `cid status` | Branch, staged and unstaged changes, unpushed commits, subset, pending conflicts (offline) |
| `cid log` | The folder's branch, newest first: unpushed commits marked, then the server's, releases named (and marked "not in git yet" until the dataset repository has them) |
| `cid diff [<a>] [<b>]` | What changed; no arguments = unstaged edits, `--staged` = staged |
| `cid add <path>...` | Stage added, changed and deleted files (`cid add .` for everything) |
| `cid restore [--staged] <path>` | Unstage (`--staged`) or throw away local edits |
| `cid commit -m <msg> [-a]` | Save staged changes as a local commit; `-a` first stages every change to tracked files (new files need `add`, as in git) |
| `cid push` | Upload local commits and their new files; resumes if interrupted |

For dataset owners (`cid help --all`): `init <address> --git <url>` (both required),
`tag`, `branch`, `merge [--continue]`, and `remote` (the folder's address and git URL;
`remote set-url [<address>] [--git <url>]` after a rename, as in git: the old address
stops answering, nothing redirects; server commands warn when the folder's git URL is
not the dataset's). Without SSH (scripts, CI), any address may be
`https://you:TOKEN@host/<dataset>` with a personal token (except for `init`: creating
a dataset needs SSH or the server's static token). Plumbing, in no help:
`cid hash-object <file>...` prints each file's content hash (BLAKE3), as git's does.
`tag`, `branch` and `merge` act on the server and need everything pushed first; they
say so and suggest `cid push` when there are local commits.
Admins: `cid admin setup|migrate|verify|gc|purge|serve|previews|sync-gitlab|git|add-key|grant|rename`.

Rules for every command:
- Inside a cloned folder the dataset is implied; outside, it is the first argument.
- `.cidignore` excludes files from `cid add`: a small subset of `.gitignore` (exact
  paths, `dir/`, `*.ext`, `#` comments).
- `--json` anywhere on the line: the result as one JSON document on stdout (`diff`:
  one line per change, then a summary); errors as `{"error", "exit"}` on stderr.
- Exit codes: 0 ok, 1 wrong usage (or no server configured), 2 conflict, 3 integrity
  failure, 4 server or network, 5 access denied.
- The author of a commit is `CID_AUTHOR`, else `user:$USER`.
- Progress bars for anything over a second; quiet when not attached to a terminal.
- Errors end with the command to run next. Never print tokens or keys.
- `cid --version` prints the version, plus a small original ASCII airship when attached
  to a terminal (plain version only when piped, so scripts can parse it).
- Permissions come from the GitLab role on the dataset's project (`docs/access.md`):
  Reporter = read, Developer = push, Maintainer (= owner) = tag, branch, merge (token
  levels read, write, maintain). Anyone can `add` and `commit` locally; the server
  checks permission at `push`.

There is no user config to write. SSH settings come from the user's normal
`~/.ssh/config`; a folder's `.cid/config.zon` (written by `clone`/`init`) holds its
address and git URL, never a token. An https address carries a personal token for
the command it is given to; in a folder, `CID_TOKEN` does. `CID_SERVER` + `CID_TOKEN`
in the environment override both. A token from the SSH front door lives 15 minutes; a longer
command asks for a fresh one and retries.

`cid clone <git-url>` (a URL ending in `.git`) works by reading the `.cid` marker file
from the dataset repository: the CLI runs the system `git` program for exactly this one
step (a depth-1 clone of `main` into a temporary folder), then proceeds over SSH +
HTTPS as usual. This is the only git invocation the CLI ever makes.

---

## Repository layout

```
build.zig, build.zig.zon     pinned Zig version (minimum_zig_version)
LICENSE                      GPL-2.0-only, exactly like git
src/main.zig                 entry point, argument parsing, exit codes
src/cli/                     one file per command, thin
src/core/                    version.zig (state at a commit, one streamed pass), release
                             (manifest, verify), gc, purge, migrate; commit, branch and
                             merge recording live in src/server/api.zig
src/client/                  server calls, local cache, folder scan, ignore rules
src/client/index.zig         staging area (.cid/index) and the tracked tree
src/client/local.zig         local commits, HEAD, last-pushed
src/client/sync.zig          push, pull, replaying unpushed commits, conflicts, merge state
src/server/                  api.zig (every route, tokens and permissions, presigned URLs,
                             uploads), serve.zig (Nilo app), signin.zig (GitLab OAuth)
src/store/db.zig             TimescaleDB via nilo_sql (pg.zig native driver, pooled)
src/store/blob.zig           S3 via nilo_s3: one Bucket ('cid'), the storage rules
src/manifest/                canonical manifest rows, RFC 8785 JSON (jcs.zig)
src/media/                   media type sniffing and image dimensions
src/tabular/                 row diffs and table statistics for CSV, Parquet, JSONL (DuckDB)
src/export/                  bundle.zig (the streamed version), jsonl.zig, yolo.zig
src/server/browse/           dashboard API: manifest queries, facets, cursors, compare
src/preview/                 preview worker: calls ffmpeg, stores by item hash
src/gitrepo/                 dataset repository: render release files, queue, push, resync,
                             read back (writer.inspect), all plain git
src/access/                  key lookup and forced-command checks (auth.zig), tokens,
                             GitLab member and key sync; their CLI entry points are
                             src/cli/sshcmd.zig (cid ssh-keys, cid ssh-auth)
deploy/sshd/                 hardened sshd_config and setup
deploy/proxy/                reverse proxy configs (Caddy, nginx) for the server and the store
web/                         dashboard: React + Vite + TypeScript (see docs/dashboard.md)
web/e2e/                     Playwright tests: UX budgets, accessibility (axe), keyboard
docs/                        data-model.md, access.md, git-repository.md, dashboard.md
src/util/                    hash (BLAKE3, the one content hash), uuid7, progress
sql/migrations/
tests/                       integration tests against real TimescaleDB + SeaweedFS;
                             usability.sh (the scripted CLI session); bench/ (1M browse,
                             10M ingest)
tests/fixtures/              small image, audio, text, CSV, Parquet, JSONL, PDF, binary
docker-compose.test.yml      timescaledb + seaweedfs, pinned versions
```

---

## Build and test

```bash
zig build                          # debug; links DuckDB (beside the binary)
zig build -Doptimize=ReleaseFast   # release
zig build test                     # unit tests, no services
docker compose -f docker-compose.test.yml up -d
zig build integration              # needs the services

sh tests/usability.sh              # the scripted CLI session (services + `zig build`)
sh tests/proxy.sh                  # deploy/proxy/ configs carry a push, clone, release (docker)

pnpm --dir web install
pnpm --dir web dev                 # dashboard dev server, proxies /v0 to cid serve
pnpm --dir web build               # builds web/dist, embedded by `zig build`
pnpm --dir web test:e2e            # Playwright, against zig-out/bin/cid

tests/bench/browse_1m.sh           # 1M items: release, browse, compare (ReleaseFast)
tests/bench/ingest_10m.sh          # 10M revisions through the platform's path
```

Integration tests, the usability script and the benchmarks share the test database:
run them one at a time (the integration suite resets the schema).

Dashboard changes must pass `pnpm --dir web lint`, `pnpm --dir web typecheck` and the
e2e suite, and meet the budgets and acceptance tests in `docs/dashboard.md`.

Known toolchain quirk (Zig 0.16.0): `zig build integration` sometimes fails or
stalls with no failing test named, right after a recompile. Run the printed
test binary directly to see the truth; re-check when a 0.16.x patch lands.

Before finishing any change: `zig fmt --check build.zig src tests` (never `.`:
`zig-pkg/` holds unpacked dependencies), `zig build test`, and
`zig build integration` when touching `store/`, `core/`, `client/`, `server/`,
`manifest/`, `tabular/` or SQL.

**Tests that must always exist and pass**
- Release round trip, for both dataset kinds: changes → commit → release →
  `cid admin verify` matches the hash.
- Clone round trip: `clone`, `checkout`, `pull` produce exactly the manifest's files,
  each hash-checked, for every fixture type.
- File dataset round trip: `init`, edit/add/delete files, `add`, `commit`, `push`,
  clone elsewhere, identical tree.
- Staging behaves like git: only staged changes are committed; `restore --staged`
  unstages; `commit -a` includes all tracked changes.
- Offline: `add` and `commit` work with the server unreachable; `push` later succeeds.
- Resume: a push killed halfway is finished by running `cid push` again, with no file
  uploaded twice and no half-recorded commits on the server.
- Stale push refused; `pull` replays unpushed commits when files don't overlap, and
  lists same-file conflicts without merging them; `checkout --mine/--theirs` then
  `--continue` resolves them.
- Append-only: UPDATE/DELETE on revision tables fail for writer roles.
- Cutoff lock: a revision writer racing a commit never lands under the sealed cutoff;
  `verify` flags a manually injected late row as corruption.
- Item identity: re-encoding an item (new hash) keeps its annotations; two identical
  files at different paths do not share annotations.
- State-at-commit correctness: random change sequences vs an in-memory model.
- Row-level diff correctness for CSV, Parquet and JSONL fixtures.
- Unknown binary files are stored and restored byte-for-byte.
- Dataset repository: `init` fails with a clear message when the git URL is unreachable
  or not writable; each release produces exactly one git commit and tag; rendering the
  same release twice produces no new commit (including after a card edit); a git outage
  leaves the release intact and `--resync` fills the gap; no restricted content ever
  appears in a rendered file; `cid clone <git-url>` works.
- Access: clone works with only an SSH key registered in GitLab; Reporter can read but
  not push; a removed member loses access after sync; any command other than `cid-auth`
  over SSH is refused; tokens expire and are scoped to one dataset; `ssh cid@host`
  without a command gives no shell; the hash-existence check reveals nothing across
  access boundaries.
- Purge: bytes and previews gone, history intact, release reports "intact except…",
  re-upload of a purged hash refused, event logged.
- Corrupted item or manifest → exit code 3; permission refusal → exit code 5.
- Cleanup never deletes anything referenced by a release or branch head.
- **Usability:** a scripted session using only the everyday commands, with every error
  message checked for a "next command" hint.
- All unit tests use `std.testing.allocator` (no leaks).

---

## Zig conventions

- **Pin the Zig version** in `build.zig.zon` and CI. Upgrade Zig only in its own change.
- **Explicit allocators** everywhere; an arena per command or request. No globals.
- **Errors:** explicit error sets at module boundaries, `errdefer` for cleanup, never
  `catch unreachable` on I/O, parsing, network or database results. Map errors to exit
  codes and friendly messages only at the top: `main.zig` and the command files in
  `src/cli/`.
- **No global state:** the CLI passes `common.Context` (arena, gpa, io, out, env,
  json), the server `api.Deps` (db, s3, io, gpa, folders, …). Each takes the allocator
  it is given (tests pass `std.testing.allocator`, which catches leaks). One sanctioned
  exception: the last database problem message, kept for `cid admin` errors.
- **Streaming I/O** with bounded buffers; hash files while uploading; batch DB work
  (about 5,000 rows).
- **C libraries allowed:** DuckDB only. BLAKE3, SHA-256, HMAC, JSON, UUIDv7 and media
  metadata come from the Zig standard library or our own small code. New dependencies
  need a written reason.
- **HTTP, Postgres and S3: Nilo** (`nevindra/nilo`), server side only. The written
  reason: it is Zig-native (zio fibers), fast, and we maintain it ourselves.
  Guardrails: depend on a **pinned commit** (it is pre-1.0 and breaks; the hash in
  build.zig.zon is the lock, and upstream now hash-pins its own `zio`);
  `.sql = true` brings nilo_sql — the native pooled Postgres driver all of
  cid queries through (src/store/db.zig; libpq is gone) — and nilo_fetch
  carries the server's outbound calls (GitLab). Client code imports no nilo
  module (main.zig takes only nilo's `std_options`); TLS stays at the
  reverse proxy.
  serve.zig keeps `api.handle` as the one dispatcher behind two catch-all
  routes, so the API stays HTTP-free and directly testable; handlers take
  the request's Ctx as the query Scope, admin commands and tests a Run.
  S3 goes through nilo_s3 the same way (a Bucket is a Service; presignGet
  and presignPut for the push flow, get/put, head, delete, list,
  `putMultipart` for files over 64 MB, and `copyObject`/`compose` to land
  verified uploads inside the store), wrapped in src/store/blob.zig.
  nilo's ADR 059 compiles the bucket name into the type and cid ships one
  static binary, so **the bucket is always named `cid`**: deployments
  create it (docker-compose.test.yml shows how; creation is never cid's
  job), CID_S3_BUCKET does not exist, and CID_S3_REGION is optional
  (default us-east-1). `cid admin serve` refuses to start without the
  bucket, naming the fix. `CID_S3_PUBLIC_ENDPOINT`, when set, is the name
  presigned URLs are signed for (where clients reach the store behind a
  proxy, `deploy/proxy/`); a second Store that only signs (`blob.Signer`).
- **External programs allowed:** on the server, `ffmpeg` (preview worker; `vips` when
  PDF page images arrive),
  `git` (dataset repository writer) and OpenSSH `sshd` (front door, runs as its own
  service). In the CLI, the system `ssh` client, exactly as git uses it, plus the
  system `git` for the one `.cid`-marker fetch in `cid clone <git-url>`.
  Call them with explicit arguments, never through a shell, with timeouts and memory
  limits; treat their output as untrusted.
- **One binary, DuckDB beside it**: client and server are one `cid`, always linked
  against libduckdb (shipped next to it). Only the Linux x86-64 library is pinned
  today; other platforms need theirs pinned in `build.zig.zon`. No build conditions: a
  feature never asks whether DuckDB is there. Client code never imports DuckDB, so a
  client-only target could be added later without one. No keychain libraries.
- `zig fmt`; `snake_case` functions and variables, `PascalCase` types.
- `std.log` with scoped loggers; no secrets, no restricted-dataset content.

---

## Performance budgets

| Operation | Budget |
|---|---|
| `cid status` on 100k files | < 1 s, no network (cached hashes, re-hash only files whose size/mtime changed) |
| `cid add` | limited by disk read speed (hashing), 100k small files < 30 s |
| `cid commit` | < 100 ms, no network |
| Platform migration, 10M revisions (4 writers, batches as `cid_writer`, server commit per 1M) | < 10 min with progress, resumable (`tests/bench/ingest_10m.sh`: 257 s) |
| `cid push` | limited by upload speed; server-side recording < 1 s for small files; a large file costs one read of its bytes (the hash) plus a copy inside the store: 1 GB in 21 s on SeaweedFS, which copies the bytes; S3 copies without reading them |
| `cid tag` (write manifest), 1M items or annotations | < 60 s |
| `cid diff` of two releases, 1M rows each | < 10 s |
| `cid checkout` between releases | only changed files transferred |
| Memory, any command | < 512 MB, independent of dataset size |
| Dashboard: filter change → first 60 thumbnails, 1M items | < 700 ms |
| Dashboard: compare two releases, summary visible, 1M annotations | < 2 s |

Full dashboard budgets are in `docs/dashboard.md`.

---

## Working with the annotation platform

- The platform uploads item bytes through the server API (presigned PUT, named by
  their BLAKE3 hash, which `cid hash-object` prints; server-side hash verification —
  invariant 2 has one enforcement point), then writes item paths and annotation
  changes directly with the `cid_writer` role (INSERT only, never `rev_id` or `ts`:
  the database mints both), holding the shared per-branch write lock
  for each transaction and inserting a `revision_batches` key with each batch so a
  retry never writes twice (`docs/data-model.md`).
- For commit, release, branch, merge, diff and export it calls the cid server API
  (`src/server/api.zig` lists every route).
- It commits when a batch finishes a pipeline stage and tags when someone publishes a
  release in the web app.
- Restricted datasets go through the same roles; the server enforces restriction, and
  the platform must not send their items to any external service either.

---

## Working style for Claude in this repo

- Read this file and the relevant `src/core/` module before changing behaviour; read
  the matching `docs/*.md` before changing the schema, access, the git writer or the
  dashboard.
- Before any dashboard work, read `docs/dashboard.md`; build in its phase order and
  check each page against its principles (never "viewer not available", media-native,
  pinned to a version, every view is a link) and its design language ("the engineer's
  airship": techy workshop up close, beautiful sky from afar, calm data areas).
- For any user-facing change, first write the exact command and its output, and check
  it against "as easy as git, or easier".
- Never assume data is images. Test new behaviour with the non-image fixtures too.
- Small changes, with tests in the same change. No features "for later". No new
  dependencies without asking.
- Commit messages: imperative, summary under 72 characters, body explains why.
  **No AI attribution or Co-Authored-By lines in commits to this repo.**
