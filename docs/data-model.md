# cid — data model (TimescaleDB)

Read with `CLAUDE.md` (invariants, words). This file is the authoritative schema and
the integrity rules around it.

Migrations: `sql/migrations/NNNN_name.sql`, applied in order. Never edit an applied one.

---

## Datasets and identity

Datasets are identified by a stable surrogate id, never by their path. The path
(`name`) is what people type and what matches the GitLab project; it can be renamed.

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

-- a rename records the old path so old addresses keep working (server-side redirect)
CREATE TABLE dataset_names (
  old_name    text PRIMARY KEY,
  dataset_id  uuid NOT NULL REFERENCES datasets(dataset_id),
  renamed_at  timestamptz NOT NULL DEFAULT now()
);
```

Every other table references `dataset_id`, never `name`.

**Dataset card.** The human-written card fields live in one row; everything countable
is computed from the manifest. Each release snapshots the card (see `refs.card`), so
re-rendering an old release stays deterministic after the card is edited.

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

- **Content** is bytes, stored once globally by SHA-256 (`items`). Content is immutable.
- **Identity** is "this item of this dataset" (`dataset_items.item_id`), and it
  **survives re-encoding**: stripping EXIF, re-compressing or blurring a region gives
  the same `item_id` a new `item_hash`. Annotations attach to `item_id`, so cleaning a
  file never orphans its labels. Two byte-identical files share storage but never
  identity.

```sql
CREATE TABLE items (
  item_hash   bytea PRIMARY KEY,          -- SHA-256, 32 bytes
  size_bytes  bigint NOT NULL,
  media_type  text NOT NULL,              -- MIME type, 'application/octet-stream' if unknown
  meta        jsonb NOT NULL DEFAULT '{}',-- width/height, duration, pages, rows, columns, source…
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE dataset_items (
  item_id     uuid PRIMARY KEY,           -- UUIDv7
  dataset_id  uuid NOT NULL REFERENCES datasets(dataset_id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
```

How bytes get in: **always through the server** (presigned PUT, then the server
verifies the hash before inserting the `items` row). This includes the annotation
platform: its `cid_writer` role INSERTs *revisions* directly, but item bytes and
`items` rows go through the server's upload API, so invariant 2 (verify every upload)
has exactly one enforcement point. The preview worker picks up new items from the
`items` insert.

**Deduplication privacy rule:** when a push asks "do you already have hash X?", the
server answers *yes* only if X is already referenced by a dataset the caller's token
can read. Otherwise it requests the upload even when the bytes exist (and discards the
duplicate). Without this, anyone who can push could confirm whether a known file —
a specific face image, say — exists in a restricted dataset.

---

## Revisions (append-only history)

```sql
-- which item sits at which path, in which split, over time
CREATE TABLE item_revisions (
  rev_id      uuid        NOT NULL,       -- UUIDv7
  ts          timestamptz NOT NULL,       -- the UUIDv7 time
  dataset_id  uuid        NOT NULL REFERENCES datasets(dataset_id),
  branch      text        NOT NULL DEFAULT 'main',
  path        text        NOT NULL,
  op          text        NOT NULL CHECK (op IN ('add','update','delete')),
  item_id     uuid,                       -- null for delete
  item_hash   bytea,                      -- the content at this revision; null for delete
  split       text,                       -- train | val | test | null
  author      text        NOT NULL
);

-- structured annotations, annotated datasets only; attached to item identity
CREATE TABLE annotation_revisions (
  rev_id         uuid        NOT NULL,
  ts             timestamptz NOT NULL,
  dataset_id     uuid        NOT NULL REFERENCES datasets(dataset_id),
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

-- both revision tables: hypertable on ts (7-day chunks), compression after 30 days,
-- index (dataset_id, branch, <path | annotation_id>, rev_id DESC)
```

Writers have INSERT only; a trigger rejects UPDATE/DELETE for every role except the
migration owner (and `cid admin purge`, below).

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
  recorded_at      timestamptz NOT NULL DEFAULT now(),  -- when the server accepted it
  stats            jsonb                  -- counts, change summary vs parent
);

CREATE TABLE refs (
  dataset_id       uuid NOT NULL REFERENCES datasets(dataset_id),
  name             text NOT NULL,         -- 'main', 'cleanup', 'v1.0.0'
  kind             text NOT NULL CHECK (kind IN ('branch','release')),
  commit_id        uuid NOT NULL REFERENCES commits(commit_id),
  start_commit_id  uuid REFERENCES commits(commit_id),
  manifest_path    text,
  manifest_sha256  bytea,
  card             jsonb,                 -- snapshot of dataset_cards.body at release time
  PRIMARY KEY (dataset_id, name)
);
```

**The cutoff race, and the lock that closes it.** A commit is "every revision with
`rev_id <= cutoff_rev`". Revision ids are client-generated UUIDv7, so a slow writer
transaction (or a skewed clock) could land a row *under* an already-recorded cutoff —
silently changing a sealed commit. The rule:

- Every transaction that INSERTs revisions first takes
  `pg_advisory_xact_lock_shared(h)` where `h = hash(dataset_id, branch)`.
- Recording a commit takes the same lock **exclusively**, computes `cutoff_rev` as the
  maximum existing `rev_id`, and inserts the commit, all in that one transaction.

Writers never block each other (shared), and a commit waits for in-flight writes to
land before sealing. `cid admin verify` enforces the invariant from the other side:
any revision found with `rev_id <= cutoff_rev` of an existing commit but absent from
that commit's state is reported as **corruption**, loudly, exit code 3.

**State at a commit** = for each path (and each annotation), the latest change up to
the commit's cutoff, deletes dropped:

```sql
SELECT DISTINCT ON (path) *
FROM item_revisions
WHERE dataset_id = $1 AND branch = 'main' AND rev_id <= $2
ORDER BY path, rev_id DESC;       -- then drop op = 'delete'
```

On a branch: `main` up to the branch's start cutoff, plus the branch's own changes.
Releases are always read from their manifest, never recomputed, except by
`cid admin verify`. Browsing an unreleased branch head at scale uses a materialized
snapshot per head, refreshed on push — the `DISTINCT ON` over compressed chunks does
not meet the dashboard budgets at 1M items.

---

## Manifests are repeatable

`manifest_sha256` is the hash of the **canonical row stream**, not of the Parquet bytes:

- items sorted by `path`; annotations sorted by `(item_id, annotation_id)`;
- fixed field order; UTF-8; hashes hex lower-case; timestamps RFC 3339 UTC;
- every `jsonb` field (`geometry`, `attrs`, `meta`, `card`) serialized with
  **RFC 8785 (JCS)** canonical JSON — without this, float formatting breaks
  repeatability.

Rebuilding a release must reproduce the same hash.

---

## Access, audit, activity

Identities and access are synced from GitLab (or managed in the dashboard); the full
flow is in `docs/access.md`.

```sql
CREATE TABLE accounts (
  account_id    text PRIMARY KEY,        -- 'gitlab:<user id>' | 'local:<id>' | 'deploy:<id>'
  display_name  text NOT NULL,
  source        text NOT NULL CHECK (source IN ('gitlab','dashboard','deploy')),
  synced_at     timestamptz
);
CREATE TABLE ssh_keys (
  fingerprint   text PRIMARY KEY,        -- SHA256:… as OpenSSH prints it
  account_id    text NOT NULL REFERENCES accounts(account_id),
  public_key    text NOT NULL,
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

-- hypertables, 7-day chunks
CREATE TABLE auth_events (               -- every token handed out (or refused) over SSH
  ts           timestamptz NOT NULL,
  account_id   text,
  fingerprint  text,
  dataset_id   uuid,
  level        text,                     -- read | write
  granted      boolean NOT NULL,
  detail       text
);
CREATE TABLE activity_events (           -- push, tag, branch, merge, card-edit, reveal, purge
  ts           timestamptz NOT NULL,
  dataset_id   uuid NOT NULL,
  account_id   text NOT NULL,
  action       text NOT NULL,
  ref          text,                     -- branch/release/item involved
  detail       jsonb
);
```

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

---

## Purge: the one sanctioned exception to append-only

Erasure demands (law or contract, typically on restricted datasets) cannot wait for
retention. `cid admin purge <dataset> <item>` is the only operation allowed to remove
content, and it is loud:

```sql
CREATE TABLE purged_items (
  item_hash   bytea PRIMARY KEY,
  dataset_id  uuid NOT NULL REFERENCES datasets(dataset_id),
  reason      text NOT NULL,
  purged_by   text NOT NULL,
  purged_at   timestamptz NOT NULL DEFAULT now()
);
```

What it does: deletes the bytes from SeaweedFS and all previews, records the
tombstone, and logs an `activity_events` row. What it does **not** do: rewrite
history — revisions, commits and manifests keep their rows and hashes. Every release
referencing a purged item is thereafter reported by `cid admin verify`, the dashboard
and `cid clone` as **"intact except N purged items"**, naming the paths (never the
content). A purged hash can never be re-uploaded without a new purge decision.

---

## Cleanup (gc) and what is rebuildable

Only **releases and branch heads** are guaranteed rebuildable forever. `cid admin gc`
deletes items that are referenced by neither, and are older than the retention period;
showing is the default, deleting needs `--apply`. An old commit that was never
released may therefore lose files after retention — `cid checkout <that commit>` then
fails with a clear message saying so and listing what is gone.

---

## Large tables

A changed file is stored again in full (no chunking — see non-goals). Tell users to
split big tables into partitioned files (e.g. `events/date=2026-03-01/part-0.parquet`),
so a new day adds files instead of rewriting one huge file.
