# cid — data model (TimescaleDB)

Read with `CLAUDE.md` (invariants, words). This file describes the schema and the
integrity rules around it; the schema itself is `sql/migrations/0001_init.sql`, and
where the two disagree, the migration wins and this file is wrong.

Migrations: `sql/migrations/NNNN_name.sql`, applied in order by `cid admin migrate`,
which records each in `schema_migrations (version, name, applied_at)`. Never edit an
applied one.

---

## Datasets and identity

Datasets are identified by a stable surrogate id, never by their path. The path
(`name`) is what people type and what matches the GitLab project.

```sql
CREATE TABLE datasets (
  dataset_id      uuid PRIMARY KEY,                -- UUIDv7, stable forever
  name            text NOT NULL UNIQUE,            -- dataset path: 'your-org/datasets/person-vehicle'
  kind            text NOT NULL CHECK (kind IN ('files','annotated')),
  restricted      boolean NOT NULL DEFAULT false,
  default_format  text NOT NULL DEFAULT 'files',   -- 'files' | 'yolo' | 'coco' | 'jsonl' …
  git_url         text NOT NULL,                   -- the dataset repository
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE dataset_names (
  old_name    text PRIMARY KEY,
  dataset_id  uuid NOT NULL REFERENCES datasets(dataset_id),
  renamed_at  timestamptz NOT NULL DEFAULT now()
);
```

`dataset_names` is reserved for renames (an old path keeps resolving to its dataset).
Renames are not built yet: no code reads or writes this table, and there is no rename
route.

Tables that belong to a dataset reference `dataset_id`, never `name`. The revision
tables and `activity_events` carry `dataset_id` without a foreign key (see below);
tables keyed by content hash (`items`, `previews`, `row_diffs`, `collected_items`) and
the account tables have no dataset at all.

**Restricted datasets** are the `restricted` flag, enforced by checks in the server:
previews are served blurred until a logged reveal, the dataset repository gets counts
only, row-level diffs give counts and columns, never rows, and every read of their
content lands in `activity_events` (`docs/access.md`). There is no row-level security,
by decision (invariant 11): TimescaleDB refuses it on a hypertable with compression,
which both revision tables use.

**Dataset card.** The human-written card fields live in one row; everything countable
comes from the version's statistics (`commits.stats`). Each release snapshots the card
(see `refs.card`), so re-rendering an old release stays deterministic after the card is
edited.

```sql
CREATE TABLE dataset_cards (
  dataset_id  uuid PRIMARY KEY REFERENCES datasets(dataset_id),
  body        jsonb NOT NULL,       -- purpose, collection method, license, provenance,
                                    -- known gaps, cover item; nothing a machine can count
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  text NOT NULL
);
```

---

## Items: content vs identity

Two different things, deliberately separated:

- **Content** is bytes, stored once globally by its BLAKE3 hash (`items`), shared by every
  dataset that holds them. Content is immutable. BLAKE3 (256 bits, lower-case hex)
  names every item, manifest, version file and diff, in the server and the CLI alike
  (`src/util/hash.zig`); `cid hash-object <file>` prints a file's hash, for writers
  that register items themselves. Protocols keep their own SHA-256: S3 request
  signing, OpenSSH key fingerprints, HMAC tokens.
- **Identity** is "this item of this dataset" (`dataset_items.item_id`), and it
  **survives re-encoding**: stripping EXIF, re-compressing or blurring a region gives
  the same `item_id` a new `item_hash`. Annotations attach to `item_id`, so cleaning a
  file never orphans its labels. Two byte-identical files share storage but never
  identity.

```sql
CREATE TABLE items (
  item_hash   bytea PRIMARY KEY CHECK (octet_length(item_hash) = 32),  -- BLAKE3
  size_bytes  bigint NOT NULL CHECK (size_bytes >= 0),
  media_type  text NOT NULL,              -- MIME type, 'application/octet-stream' if unknown
  meta        jsonb NOT NULL DEFAULT '{}',-- width/height, when known
  created_at  timestamptz NOT NULL DEFAULT now(),
  touched_at  timestamptz NOT NULL DEFAULT now()  -- last push or registration using it (gc)
);

CREATE TABLE dataset_items (
  item_id     uuid PRIMARY KEY,           -- UUIDv7
  dataset_id  uuid NOT NULL REFERENCES datasets(dataset_id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX dataset_items_by_dataset ON dataset_items (dataset_id);
```

A push inserts an `items` row as `application/octet-stream` with empty `meta`; the
preview worker sniffs the bytes and sets the real `media_type` and the image's
`width`/`height`. The platform's `register-items` may give the media type and
dimensions itself.

Identity is per path. When the server records an add, a path that already holds an
item (on `main`, or on the branch) keeps its `item_id` and the revision is an
`update`; a new path gets a new `item_id`, and the server inserts its
`dataset_items` row. Only the server inserts `dataset_items` rows (push and merge);
`cid_writer` can read the table but not write it.

How bytes get in: **always through the server**. A presigned PUT never writes an
item's final key. It writes to the dataset's staging area, `uploads/<dataset_id>/<hash>`,
or, for a file larger than one piece (64 MB), to numbered pieces
`uploads/<dataset_id>/<hash>.part-NNNNNN`, each its own PUT. Pieces already staged by a
push that stopped are not asked for again. When the push (or `register-items`) is
recorded, the server streams the staged object, or its pieces in order as one stream,
through BLAKE3 and checks the hash and size. Only matching bytes are stored at
`items/blake3/…`, and only if that key is absent. They are put there by a copy inside
the store, never through the server: S3 CopyObject for one staged object, a multipart
upload whose parts are copied from the pieces (UploadPartCopy) for several; a stored object of the wrong size is
damage, and the verified upload overwrites it as a repair. The staged copy is removed
either way, and a verified upload deletes the hash's `collected_items` row (the bytes
are back). A mismatch refuses the whole push before anything is recorded. This
includes the annotation platform: its `cid_writer` role INSERTs *revisions* directly,
but item bytes and `items` rows go through the server's upload API, so invariant 2
(verify every upload) has exactly one enforcement point. Recording an item (push,
merge or `register-items`) also inserts its `previews` queue row.

```sql
CREATE TABLE dataset_hashes (       -- bytes admitted (verified) into each dataset
  dataset_id  uuid  NOT NULL REFERENCES datasets(dataset_id) ON DELETE CASCADE,
  item_hash   bytea NOT NULL REFERENCES items(item_hash),
  PRIMARY KEY (dataset_id, item_hash)
);
```

**Deduplication privacy rule:** when a push asks "do you already have hash X?", the
server answers *yes* only if X was already admitted into **this** dataset
(`dataset_hashes`), is not collected, and its bytes are in storage. Otherwise it hands
out a staging URL even when the bytes exist elsewhere, then verifies the upload and
keeps the one stored copy. Without this, anyone who can push could confirm whether a
known file (a specific face image, say) exists in a restricted dataset.

---

## Revisions (append-only history)

```sql
-- which item sits at which path, in which split, over time
CREATE TABLE item_revisions (
  rev_id      uuid        NOT NULL DEFAULT cid_rev(),          -- UUIDv7, database clock
  ts          timestamptz NOT NULL DEFAULT clock_timestamp(), -- when it landed
  dataset_id  uuid        NOT NULL,       -- no foreign key: it costs a quarter of a bulk
                                          -- import; an unknown id is inert
  branch      text        NOT NULL DEFAULT 'main',
  path        text        NOT NULL,
  op          text        NOT NULL CHECK (op IN ('add','update','delete')),
  item_id     uuid,                       -- may be null for delete
  item_hash   bytea CHECK (item_hash IS NULL OR octet_length(item_hash) = 32),
  split       text,                       -- train | val | test | null
  author      text        NOT NULL,
  CHECK ((op = 'delete') = (item_hash IS NULL)),
  CHECK (op = 'delete' OR item_id IS NOT NULL)  -- the manifest names every live item
);

-- structured annotations, annotated datasets only; attached to item identity
CREATE TABLE annotation_revisions (
  rev_id         uuid        NOT NULL DEFAULT cid_rev(),
  ts             timestamptz NOT NULL DEFAULT clock_timestamp(),
  dataset_id     uuid        NOT NULL,    -- no foreign key, as above
  branch         text        NOT NULL DEFAULT 'main',
  annotation_id  uuid        NOT NULL,
  item_id        uuid        NOT NULL,    -- survives re-encoding of the item
  op             text        NOT NULL CHECK (op IN ('create','update','delete')),
  kind           text,                    -- box|polygon|points|keypoints|mask|transcript|
                                          -- segment|span|class|identity|value
  class          text,
  geometry       jsonb,                   -- shape, time range or text offsets, per kind
  attrs          jsonb,
  author         text        NOT NULL,    -- 'agent:annotator' | 'user:<id>'
  policy_ver     text        NOT NULL,
  parent_rev     uuid
);
```

Both revision tables are hypertables on `ts` with 7-day chunks (`create_hypertable`
also makes its default index on `ts`), plus a lookup index
`(dataset_id, branch, <path | annotation_id>, rev_id DESC)`. Compression:
`segmentby = 'dataset_id, branch'`, `orderby = 'rev_id DESC'`, a compression policy
after 30 days.

**Append-only.** A `BEFORE UPDATE OR DELETE` trigger (`reject_mutation`) on both
tables rejects every change unless the session sets `cid.maintenance = 'on'`, which
only migrations do. It is not role-based. `cid_writer`'s first protection is simpler:
it has no UPDATE or DELETE grant at all. `cid admin purge` never touches revision rows.

**Id functions.** `cid_rev_at(us)` builds a UUIDv7 from a Unix time in microseconds;
`cid_rev()` is `cid_rev_at` of `clock_timestamp()`; `cid_rev_after(floor)` is a fresh id
strictly above `floor` (the random tail is stepped when the clock has not moved);
`cid_rev_time(rev)` reads the millisecond inside an id, so a search for revisions
above an id can start at that moment.

### Geometry, per kind (image annotations)

Coordinates are pixels of the item as stored (its recorded `width` × `height`), origin
top-left. The platform writes these shapes; the dashboard draws them and the exports
read them, so both sides hold to exactly this:

| kind | geometry |
|---|---|
| `box` | `{"x": 10, "y": 20, "w": 30, "h": 40}` — top-left corner, width, height |
| `polygon` | `{"points": [[x, y], …]}` — one ring, closed implicitly |
| `points`, `keypoints` | `{"points": [[x, y], …]}` |
| `mask` | `{"size": [h, w], "counts": "<COCO compressed RLE>"}` — exactly pycocotools' encoding: column-major runs starting with background, `size` in pixels of the item. Also accepted: `counts` as an array of run lengths (COCO's uncompressed RLE) |

COCO RLE was chosen so a mask stays a few hundred bytes of `jsonb` and a COCO export
needs no conversion; every detection tool reads it.

---

## Commits, refs, and the cutoff lock

```sql
CREATE TABLE commits (
  commit_id        uuid PRIMARY KEY,      -- UUIDv7
  dataset_id       uuid NOT NULL REFERENCES datasets(dataset_id),
  branch           text NOT NULL,
  parent_id        uuid REFERENCES commits(commit_id),
  merge_parent_id  uuid REFERENCES commits(commit_id),  -- second parent of a merge
  cutoff_rev       uuid NOT NULL,         -- covers both revision tables
  message          text NOT NULL,
  author           text NOT NULL,
  authored_at      timestamptz NOT NULL,  -- when `cid commit` ran (possibly offline)
  recorded_at      timestamptz NOT NULL DEFAULT clock_timestamp(),  -- when it was sealed
  stats            jsonb                  -- the version's own statistics
);
CREATE INDEX commits_by_branch ON commits (dataset_id, branch, commit_id DESC);

CREATE TABLE refs (
  dataset_id       uuid NOT NULL REFERENCES datasets(dataset_id),
  name             text NOT NULL,         -- 'main', 'cleanup', 'v1.0.0'
  kind             text NOT NULL CHECK (kind IN ('branch','release')),
  commit_id        uuid NOT NULL REFERENCES commits(commit_id),
  start_commit_id  uuid REFERENCES commits(commit_id),
  manifest_path    text,
  manifest_hash    bytea CHECK (manifest_hash IS NULL OR octet_length(manifest_hash) = 32),
  card             jsonb,                 -- snapshot of dataset_cards.body at release time
  changes_from     text,                  -- the previous release; null for the first
  changes          jsonb,                 -- counted since it, at release time
  PRIMARY KEY (dataset_id, name)
);
```

A release keeps what changed since the release before it, counted when it is made
(`version.changes`): files added, modified and deleted by path, and annotations added,
changed and removed by id, the comparison `cid diff` makes. The previous release is
the newest release whose commit is older than this one's; the first release has none,
so it keeps no counts (`changes_from` and `changes` are null). The dataset repository's `CHANGELOG.md` and
`release.json` show it (`docs/git-repository.md`).

`commits.stats` holds the version's own statistics, not a change summary: items,
bytes, file types, splits, a few visual items for the cover, annotations, classes and
the newest policy version, with a format version `v`. They are one SQL aggregate over
the version, filled after the commit is recorded (`src/core/version.zig`) and read by
the home page, the overview and the git writer.

**Releases never move** (invariant 5): the `refs_releases_immutable` trigger rejects
any UPDATE or DELETE of a release ref unless `cid.maintenance = 'on'`. Branch refs
move freely.

**The cutoff race, and what closes it.** A commit is "every revision with
`rev_id <= cutoff_rev`". If a writer could choose its own ids, a slow transaction or a
skewed clock could land a row *under* an already-recorded cutoff, silently changing a
sealed commit. Three rules close it:

- **The database mints every id.** `rev_id` defaults to `cid_rev()`, a UUIDv7 from
  the database clock whose 12 bits after the version hold the fraction of the
  millisecond, so ids order to the microsecond; `ts` defaults to the same clock
  (`clock_timestamp()`). The `cid_writer` role may insert every column **except**
  these two (column-level grants), so no writer can choose an id, whatever its own
  clock says. The server's own writes (push, merge) use `cid_rev_after(floor)`,
  strictly above the previous id and the branch's cutoff. Cost: about 4 µs per row
  (measured: 200k rows in 2.4 s against 1.5 s with ids supplied); no trigger runs per
  row.
- **The lock.** Every transaction that INSERTs revisions first takes
  `pg_advisory_xact_lock_shared(h)` where `h = hashtextextended(dataset_id || '/' || branch, 0)`.
  Recording a commit takes the same lock **exclusively** and computes `cutoff_rev` in
  that one transaction: for a push or merge, the last revision it just wrote; for the
  platform's commit, the newest `rev_id` on the branch above the parent's cutoff,
  found among the rows written in the last second before the newest `ts` (two index
  lookups, however much was written). Writers never block each other (shared), and a
  commit waits for in-flight writes to land before sealing, so a row minted before a
  commit is in it, and one minted after is above its cutoff.
- **The backstop.** Each commit records when it was sealed (`recorded_at`, the clock,
  not the transaction start). Before the next commit on that branch is recorded,
  under the exclusive lock, the server checks that no revision with `ts` after the
  head commit's `recorded_at` sits at or under its cutoff; if one does (only a session
  that can set ids itself could do this), nothing more is recorded on the branch and
  the error names it. The check reads only rows written since that commit, through
  the `ts` index.

`cid admin verify` still enforces the invariant from the other side: any revision found
with `rev_id <= cutoff_rev` of an existing commit but absent from that commit's state is
reported as **corruption**, loudly, exit code 3.

**Annotation ids are UUIDv7**, minted by the writer (they are identities, not times:
the platform needs them before it writes). Time-ordered ids keep the
`(dataset_id, branch, annotation_id)` index growing at its end; random ones land all
over it, about 8× slower per batch at 10M rows (measured: 7.7 s against 0.95 s for
30,000 annotations).

**Retry-safe batches.** A platform batch is one transaction, and its rows go in with
its key in **one statement**, so a batch is written whole or not at all, and a
batch already written writes nothing:

```sql
CREATE TABLE revision_batches (
  dataset_id  uuid NOT NULL REFERENCES datasets(dataset_id) ON DELETE CASCADE,
  batch_key   text NOT NULL CHECK (length(batch_key) BETWEEN 1 AND 200),
  written_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (dataset_id, batch_key)
);
```

```sql
BEGIN;
SELECT pg_advisory_xact_lock_shared(hashtextextended($dataset || '/main', 0));
SET LOCAL ROLE cid_writer;
WITH fresh AS (
  INSERT INTO revision_batches (dataset_id, batch_key) VALUES ($dataset, $key)
  ON CONFLICT DO NOTHING RETURNING 1
), items AS (
  INSERT INTO item_revisions (dataset_id, branch, path, op, item_id, item_hash, split, author)
  SELECT … WHERE EXISTS (SELECT 1 FROM fresh)
)
INSERT INTO annotation_revisions (…) SELECT … WHERE EXISTS (SELECT 1 FROM fresh);
COMMIT;
```

This is the form `tests/bench/ingest_10m.sh` uses. A plain `INSERT` of the key, without
`ON CONFLICT`, is also safe: a duplicate key fails the transaction and nothing is
written twice. An import that stops (a crash, a lost connection, an acknowledgement
that never arrived) is resumed by sending every batch again, or by reading which keys
are done: the ones already in write nothing. Several writers may run at once, each on
its own connection: the write lock is shared between writers, and only a commit waits
for them.

**State at a commit** = for each path (and each annotation), the latest change up to
the commit's cutoff, deletes dropped:

```sql
SELECT DISTINCT ON (path) *
FROM item_revisions
WHERE dataset_id = $1 AND branch = 'main' AND rev_id <= $2
ORDER BY path, rev_id DESC;       -- then drop op = 'delete'
```

On a branch: `main` up to the branch's start cutoff, plus the branch's own changes.

Every version, release or not, is read from history: clone, pull, checkout, export,
statistics and browse indexes all come from one streamed pass (`version.pass`, over
temporary tables built by `version.materialize`), which is exact because the cutoff
is sealed. The stored manifest is read only by `cid admin verify`, to prove history
and manifest still agree. What makes this fast is derived files, built once per
version and kept:

- a **browse index** per version (`items.parquet` + `anns.parquet`, read by DuckDB),
  prepared ahead of the first visitor by the `version_jobs` background worker
  (`api.prepareNext`), cached locally under `CID_BROWSE_DIR`, and kept in storage at
  `manifests/<dataset_id>/<commit_id>.{items,anns}.parquet`;
- the version's **items file** and **exports** as the CLI downloads them
  (`version_files`), and **diffs** between two versions (`version_diffs`).

---

## Manifests are repeatable

A release's manifest is a canonical tab-separated text stream, stored as is at
`manifests/<dataset_id>/<commit_id>.manifest` (`src/core/release.zig`,
`src/manifest/canonical.zig`). `manifest_hash` is the BLAKE3 of exactly those bytes.
One format serves both kinds of dataset, and it is frozen at the first public release:

```
cid-manifest 1\n
item\t<path>\t<item_id>\t<hash>\t<size>\t<split>\n         one per item
ann\t<item_id>\t<annotation_id>\t<kind>\t<class>\t<geometry>\t<attrs>\t<author>\t<policy_ver>\n
```

- every item row names the item's identity as well as its content, so a release
  records which item each path is (a rename or a re-encode shows), and every `ann`
  row points at an item row; a file dataset has no `ann` rows;
- items sorted by `path`, bytewise (`COLLATE "C"`); all item rows first, then
  annotation rows sorted by `(item_id, annotation_id)`;
- UTF-8; hashes lower-case hex; size in decimal; `-` for a null field;
- `geometry` and `attrs` serialized with **RFC 8785 (JCS)** canonical JSON — without
  this, float formatting breaks repeatability;
- no timestamps, no `items.meta`, no card: only what the commit seals;
- a tab or newline in an annotation's text field is an error, never a silent mangling.

Rebuilding a release must reproduce the same hash.

---

## Access, audit, activity

Identities and access are synced from GitLab (or granted by hand with
`cid admin grant`); the full flow is in `docs/access.md`.

```sql
CREATE TABLE accounts (
  account_id    text PRIMARY KEY,        -- 'gitlab:<user id>' | 'local:<id>'
  display_name  text NOT NULL,
  source        text NOT NULL CHECK (source IN ('gitlab','dashboard','deploy')),
  synced_at     timestamptz
);
CREATE TABLE ssh_keys (                -- one key, one account: a registered key is refused
  fingerprint   text PRIMARY KEY,        -- SHA256:… as OpenSSH prints it
  account_id    text NOT NULL REFERENCES accounts(account_id),
  public_key    text NOT NULL,
  title         text NOT NULL DEFAULT '',
  source        text NOT NULL DEFAULT 'gitlab' -- gitlab (the sync replaces these) |
                CHECK (source IN ('gitlab','dashboard','admin')), -- dashboard (its owner removes them) | admin
  added_at      timestamptz NOT NULL DEFAULT now(),
  synced_at     timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE access (
  dataset_id    uuid NOT NULL REFERENCES datasets(dataset_id),
  account_id    text NOT NULL REFERENCES accounts(account_id),
  level         text NOT NULL CHECK (level IN ('read','write','maintain')),
  source        text NOT NULL CHECK (source IN ('gitlab','dashboard')),
  PRIMARY KEY (dataset_id, account_id)
);
CREATE TABLE stars (
  account_id    text NOT NULL REFERENCES accounts(account_id),
  dataset_id    uuid NOT NULL REFERENCES datasets(dataset_id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, dataset_id)
);
CREATE TABLE personal_tokens (           -- made on the dashboard; act as their maker
  token_id      uuid PRIMARY KEY,
  account_id    text NOT NULL REFERENCES accounts(account_id),
  name          text NOT NULL,
  token_hash    bytea NOT NULL UNIQUE,   -- BLAKE3 of the token; the token is shown once
  prefix        text NOT NULL,           -- its first characters, to recognise it by
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,    -- required: 90 days unless chosen, at most 365
  last_used_at  timestamptz              -- revoking deletes the row
);

-- hypertables, 7-day chunks
CREATE TABLE auth_events (               -- every token handed out (or refused) over SSH
  ts           timestamptz NOT NULL,
  account_id   text,
  fingerprint  text,
  dataset_id   uuid,
  level        text,                     -- read | write | maintain
  granted      boolean NOT NULL,
  detail       text
);
CREATE TABLE activity_events (           -- push, commit, tag, branch, merge, card-edit,
  ts           timestamptz NOT NULL,     -- reveal, purge, …
  dataset_id   uuid NOT NULL,
  account_id   text NOT NULL,
  action       text NOT NULL,
  ref          text,                     -- branch/release/item involved
  detail       jsonb
);
CREATE INDEX activity_by_dataset ON activity_events (dataset_id, ts DESC);
```

Not built yet: deploy keys. The `'deploy'` value of `accounts.source` is reserved for
them; nothing creates such accounts.

Restricted-dataset reveals are `activity_events` rows with `action = 'reveal'`; the
Activity page and the owners' reveal log read from here.

```sql
CREATE TABLE policy_versions (             -- annotated datasets
  dataset_id  uuid NOT NULL REFERENCES datasets(dataset_id),
  version     text NOT NULL,
  body        jsonb NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (dataset_id, version)
);
```

**The writer role.** `cid_writer` is `NOLOGIN`; the platform connects as its own role
and uses `SET ROLE cid_writer` (or `SET LOCAL ROLE`). Its grants, all of them:
`USAGE` on the schema; column-level `INSERT` on both revision tables, every column
except `rev_id` and `ts`; `INSERT, SELECT` on `revision_batches`; `SELECT` on
`datasets`, `dataset_items`, `items` and `policy_versions`. It cannot read the
revision tables.

---

## Derived tables: queues and caches

Built from content or from sealed versions, so never stale; each row is written once.

- `git_writes (dataset_id, release, status pending|done|failed, git_commit, attempts,
  last_error, updated_at)`: the dataset repository's write queue, one row per release.
  See `docs/git-repository.md`.
- `previews (item_hash PK, status pending|building|done|failed|skipped, attempts,
  reason, blurred, table_stats, updated_at)`: the preview queue, one row per content
  hash, ever, inserted when an item is recorded (push, merge, `register-items`) and
  drained only by the preview worker (`cid admin previews`), with bounded attempts.
  `blurred` says the blurred rendition exists; `table_stats` holds CSV, Parquet and
  JSONL statistics and first rows. Index `previews_pending (updated_at) WHERE status = 'pending'`.
- `row_diffs (hash_a, hash_b, kind_a, kind_b, status done|unreadable, result, reason)`:
  the row-level diff of two table contents, computed the first time anyone asks and
  kept; an unreadable table is an answer too, never retried.
- `version_files (commit_id, kind state|jsonl|yolo, subset, file_hash, final, built_at)`:
  a version's items file (`state`) or an export, whole or narrowed to a subset
  (canonical JSON of sorted splits and classes), as a gzip file in storage. `final` is
  false while any item still waits for its media metadata; such a file is written
  again later.
- `version_jobs (commit_id PK, dataset_id, status pending|building|done|skipped|failed,
  reason, queued_at, updated_at)`: versions to prepare ahead of their first visitor
  (statistics, browse index, items file, default export), queued after each push,
  commit, merge and release. Index `version_jobs_pending (queued_at) WHERE status IN
  ('pending','building')`.
- `version_diffs (dataset_id, commit_a, commit_b, file_hash, summary)`: what changed
  between two versions, as a gzip file in storage plus its summary.

---

## Storage layout

All in the one bucket, `cid`:

| Key | What |
|---|---|
| `items/blake3/<aa>/<bb>/<hex>` | an item's bytes, stored once |
| `uploads/<dataset_id>/<hash>`, `….part-NNNNNN` | staged uploads (whole, or 64 MB pieces) until verified |
| `previews/<aa>/<hex>/thumb.webp`, `…/blur.webp` | thumbnail and blurred rendition |
| `manifests/<dataset_id>/<commit_id>.manifest` | a release's canonical manifest |
| `manifests/<dataset_id>/<commit_id>.items.parquet`, `.anns.parquet` | a version's browse index |
| `states/<dataset_id>/<commit>-<subset>-<hash>.jsonl.gz` | a version's items file, as the CLI downloads it |
| `exports/<dataset_id>/<commit>/<format>-<subset>-<hash>.jsonl.gz` | an export, as a bundle of files |
| `diffs/<dataset_id>/<a>-<b>-<hash>.jsonl.gz` | what changed between two versions, for `cid diff` |
| `diffs/<dataset_id>/<a>-<b>.items.parquet`, `.anns.parquet` | the same compare, for the dashboard |

`<subset>` and `<hash>` are the first 16 hex characters of the BLAKE3 of the subset
key and of the file.

---

## Purge: the one sanctioned exception to append-only

Erasure demands (law or contract, typically on restricted datasets) cannot wait for
retention. `cid admin purge <dataset> <item>` is the only operation allowed to remove
content, and it is loud. `<item>` is a content hash, or a path, meaning that path's
newest content on `main`.

```sql
CREATE TABLE purged_items (
  item_hash   bytea PRIMARY KEY CHECK (octet_length(item_hash) = 32),
  dataset_id  uuid NOT NULL REFERENCES datasets(dataset_id),  -- where it was purged from
  reason      text NOT NULL,
  purged_by   text NOT NULL,
  purged_at   timestamptz NOT NULL DEFAULT now()
);
```

Purge is **global by hash**: bytes are stored once for every dataset, so purging them
from one dataset removes them from every dataset that holds the same content, and the
tombstone is keyed by hash alone.

What it does: records the tombstone and an `activity_events` row first (so a failed
deletion is finished by running it again), then deletes the bytes, the preview objects
(`thumb.webp`, `blur.webp`) and the hash's `previews` row. What it does **not** do:
rewrite history — revisions, commits and manifests keep their rows and hashes.
`cid admin verify` then reports each affected release as **"intact except N purged
items"**, a count, never paths or content. A purged hash can never be uploaded again,
to any dataset: push, `check-hashes` and `register-items` refuse it.

---

## Cleanup (gc) and what is rebuildable

Only **releases and branch heads** are guaranteed rebuildable forever. `cid admin gc`
shows by default; deleting needs `--apply`. The retention period is 30 days by
default (`--days <n>`).

```sql
CREATE TABLE collected_items (           -- bytes cleanup took; history keeps the rows
  item_hash    bytea PRIMARY KEY REFERENCES items(item_hash),
  collected_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNLOGGED TABLE gc_candidates (    -- one run's candidates, scratch
  item_hash  bytea PRIMARY KEY
);
```

- **Kept, always:** every item in the state of any release or branch head of any
  dataset, and every item a revision named within the retention period (work in
  flight, the platform's newest writes).
- **Taken:** other items that no push or registration has touched
  (`items.touched_at`) for the whole period, and are not purged or already collected.
  Their bytes, preview objects and `previews` row go, and `collected_items` records
  the hash. History keeps every row.
- **Also taken:** staged uploads (`uploads/<dataset_id>/…`) never recorded within
  the period, i.e. abandoned pushes.

Each run refills `gc_candidates` (its `TRUNCATE` also keeps two runs from
interleaving).

An old commit that was never released may therefore lose files after retention.
Checking it out then fails with exit code 3, saying how many of its files were
cleaned up and to check out a release or a branch instead. A verified upload of the
same content brings it back, and the push dedup check never claims a collected hash.

Racing a push is safe by lock order. Each gc batch locks its `items` rows, re-checks
`touched_at` under the lock, records the collection and deletes the bytes before
committing. A push or registration upserts the same row (so it waits), then refuses
a hash collected meanwhile. The client's retry uploads it again.

---

## Large tables

A changed file is stored again in full (no chunking — see non-goals). Tell users to
split big tables into partitioned files (e.g. `events/date=2026-03-01/part-0.parquet`),
so a new day adds files instead of rewriting one huge file.
