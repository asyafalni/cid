-- 0001_init: the cid schema, as specified in docs/data-model.md.
-- Applied by `cid admin migrate`; never edit after it has been applied anywhere.

CREATE EXTENSION IF NOT EXISTS timescaledb;

-- Applied-migration bookkeeping (rows written by `cid admin migrate`).
CREATE TABLE schema_migrations (
  version     int PRIMARY KEY,
  name        text NOT NULL,
  applied_at  timestamptz NOT NULL DEFAULT now()
);

---------------------------------------------------------------------------
-- Datasets and identity
---------------------------------------------------------------------------

CREATE TABLE datasets (
  dataset_id      uuid PRIMARY KEY,                -- UUIDv7, stable forever
  name            text NOT NULL UNIQUE,            -- dataset path; renameable
  kind            text NOT NULL CHECK (kind IN ('files','annotated')),
  restricted      boolean NOT NULL DEFAULT false,
  default_format  text NOT NULL DEFAULT 'files',
  git_url         text NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE dataset_cards (
  dataset_id  uuid PRIMARY KEY REFERENCES datasets(dataset_id),
  body        jsonb NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  text NOT NULL
);

---------------------------------------------------------------------------
-- Items: content (global, by hash) vs identity (per dataset)
---------------------------------------------------------------------------

CREATE TABLE items (
  item_hash   bytea PRIMARY KEY CHECK (octet_length(item_hash) = 32),  -- BLAKE3 of the bytes
  size_bytes  bigint NOT NULL CHECK (size_bytes >= 0),
  media_type  text NOT NULL,
  meta        jsonb NOT NULL DEFAULT '{}',
  created_at  timestamptz NOT NULL DEFAULT now(),
  -- last time a push or the platform used these bytes: cleanup (gc) only
  -- takes items untouched for the whole retention period, so it never
  -- deletes bytes a push in flight has just been told the server has
  touched_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE dataset_items (
  item_id     uuid PRIMARY KEY,                    -- UUIDv7; survives re-encoding
  dataset_id  uuid NOT NULL REFERENCES datasets(dataset_id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX dataset_items_by_dataset ON dataset_items (dataset_id);

CREATE TABLE purged_items (
  item_hash   bytea PRIMARY KEY CHECK (octet_length(item_hash) = 32),
  dataset_id  uuid NOT NULL REFERENCES datasets(dataset_id),
  reason      text NOT NULL,
  purged_by   text NOT NULL,
  purged_at   timestamptz NOT NULL DEFAULT now()
);

-- Which datasets have had which bytes admitted (verified by the server,
-- invariant 2). The push dedup check confirms a hash only from here, for
-- the caller's own dataset, so hash existence is never an oracle across
-- datasets (invariant 12).
CREATE TABLE dataset_hashes (
  dataset_id  uuid  NOT NULL REFERENCES datasets(dataset_id) ON DELETE CASCADE,
  item_hash   bytea NOT NULL REFERENCES items(item_hash),
  PRIMARY KEY (dataset_id, item_hash)
);

-- Bytes removed by cleanup (`cid admin gc`): referenced by no release and
-- no branch head, untouched for the retention period. History keeps its
-- rows and hashes; checking out a commit that needs these says so. A
-- verified re-upload brings an item back (its row here goes).
CREATE TABLE collected_items (
  item_hash    bytea PRIMARY KEY REFERENCES items(item_hash),
  collected_at timestamptz NOT NULL DEFAULT now()
);

-- One cleanup run's candidates, refilled by each `cid admin gc` (the
-- TRUNCATE also keeps two runs from interleaving). Scratch: unlogged.
CREATE UNLOGGED TABLE gc_candidates (
  item_hash  bytea PRIMARY KEY
);

---------------------------------------------------------------------------
-- Revisions: append-only history (hypertables)
---------------------------------------------------------------------------

-- Revision ids come from the database clock, never a writer's (invariant
-- 3): a writer cannot mint an id under a sealed cutoff, whatever its own
-- clock says, because it cannot mint one at all (the column grants below).
-- A UUIDv7 whose 12 bits after the version hold the fraction of the
-- millisecond (RFC 9562 §6.2, method 3), so ids order to the microsecond.
CREATE FUNCTION cid_rev_at(us bigint) RETURNS uuid LANGUAGE sql VOLATILE PARALLEL SAFE AS $$
  SELECT encode(
    set_byte(set_byte(
      overlay(uuid_send(gen_random_uuid()) PLACING substring(int8send(us / 1000) FROM 3 FOR 6) FROM 1 FOR 6),
      6, (112 | (((us % 1000) * 4096 / 1000) >> 8))::int),
      7, (((us % 1000) * 4096 / 1000) & 255)::int),
    'hex')::uuid
$$;
CREATE FUNCTION cid_rev() RETURNS uuid LANGUAGE sql VOLATILE PARALLEL SAFE AS $$
  SELECT cid_rev_at(floor(extract(epoch FROM clock_timestamp()) * 1000000)::bigint)
$$;
-- The moment inside an id (its first 48 bits, Unix milliseconds): every
-- revision above an id was written at or after it, so a search for them
-- can start there instead of at the beginning of history.
CREATE FUNCTION cid_rev_time(rev uuid) RETURNS timestamptz LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT to_timestamp(('x' || substr(replace(rev::text, '-', ''), 1, 12))::bit(48)::bigint / 1000.0)
$$;
-- A fresh id strictly above `floor`: the server's own writes, which come in
-- sequence and must order after the branch's cutoff even within one
-- microsecond (the random tail is stepped instead).
CREATE FUNCTION cid_rev_after(floor uuid) RETURNS uuid LANGUAGE sql VOLATILE PARALLEL SAFE AS $$
  SELECT CASE WHEN floor IS NULL OR fresh > floor THEN fresh
    ELSE encode(overlay(uuid_send(floor) PLACING
      int8send(('x' || encode(substring(uuid_send(floor) FROM 9 FOR 8), 'hex'))::bit(64)::bigint + 1) FROM 9 FOR 8), 'hex')::uuid
  END FROM (SELECT cid_rev() AS fresh) f
$$;

CREATE TABLE item_revisions (
  rev_id      uuid        NOT NULL DEFAULT cid_rev(),  -- UUIDv7, database clock
  ts          timestamptz NOT NULL DEFAULT clock_timestamp(), -- when it landed
  -- No foreign key, on purpose: checking one costs a quarter of a bulk
  -- import (2M revisions: 57 s with, 43 s without). A row naming a dataset
  -- that does not exist is inert: commits, states and reads all start from
  -- the datasets table, so nothing ever reaches it.
  dataset_id  uuid        NOT NULL,
  branch      text        NOT NULL DEFAULT 'main',
  path        text        NOT NULL,
  op          text        NOT NULL CHECK (op IN ('add','update','delete')),
  item_id     uuid,                                -- may be null for delete
  item_hash   bytea CHECK (item_hash IS NULL OR octet_length(item_hash) = 32),
  split       text,
  author      text        NOT NULL,
  CHECK ((op = 'delete') = (item_hash IS NULL)),
  -- Every live item has an identity: the manifest names it (canonical.zig).
  CHECK (op = 'delete' OR item_id IS NOT NULL)
);
SELECT create_hypertable('item_revisions', 'ts', chunk_time_interval => INTERVAL '7 days');
CREATE INDEX item_revisions_lookup
  ON item_revisions (dataset_id, branch, path, rev_id DESC);

CREATE TABLE annotation_revisions (
  rev_id         uuid        NOT NULL DEFAULT cid_rev(),
  ts             timestamptz NOT NULL DEFAULT clock_timestamp(),
  dataset_id     uuid        NOT NULL,                -- no foreign key: see item_revisions
  branch         text        NOT NULL DEFAULT 'main',
  annotation_id  uuid        NOT NULL,
  item_id        uuid        NOT NULL,             -- identity, not bytes
  op             text        NOT NULL CHECK (op IN ('create','update','delete')),
  kind           text,
  class          text,
  geometry       jsonb,
  attrs          jsonb,
  author         text        NOT NULL,
  policy_ver     text        NOT NULL,
  parent_rev     uuid
);
SELECT create_hypertable('annotation_revisions', 'ts', chunk_time_interval => INTERVAL '7 days');
CREATE INDEX annotation_revisions_lookup
  ON annotation_revisions (dataset_id, branch, annotation_id, rev_id DESC);

-- Compression after 30 days.
ALTER TABLE item_revisions SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'dataset_id, branch',
  timescaledb.compress_orderby = 'rev_id DESC'
);
SELECT add_compression_policy('item_revisions', INTERVAL '30 days');
ALTER TABLE annotation_revisions SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'dataset_id, branch',
  timescaledb.compress_orderby = 'rev_id DESC'
);
SELECT add_compression_policy('annotation_revisions', INTERVAL '30 days');

-- Append-only (invariant 1): UPDATE and DELETE are rejected for everyone.
-- The single escape hatch is the maintenance GUC, settable only by a
-- superuser-controlled path (migrations); `cid admin purge` does NOT use it:
-- purge removes bytes in SeaweedFS, never rows here.
CREATE FUNCTION reject_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF current_setting('cid.maintenance', true) IS DISTINCT FROM 'on' THEN
    -- TG_TABLE_NAME would show an unhelpful chunk name on hypertables.
    RAISE EXCEPTION 'cid: % on revision history is forbidden: append-only (invariant 1)',
      TG_OP;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER item_revisions_append_only
  BEFORE UPDATE OR DELETE ON item_revisions
  FOR EACH ROW EXECUTE FUNCTION reject_mutation();
CREATE TRIGGER annotation_revisions_append_only
  BEFORE UPDATE OR DELETE ON annotation_revisions
  FOR EACH ROW EXECUTE FUNCTION reject_mutation();

---------------------------------------------------------------------------
-- Commits and refs
---------------------------------------------------------------------------

CREATE TABLE commits (
  commit_id        uuid PRIMARY KEY,               -- UUIDv7
  dataset_id       uuid NOT NULL REFERENCES datasets(dataset_id),
  branch           text NOT NULL,
  parent_id        uuid REFERENCES commits(commit_id),
  merge_parent_id  uuid REFERENCES commits(commit_id),
  cutoff_rev       uuid NOT NULL,                  -- covers both revision tables
  message          text NOT NULL,
  author           text NOT NULL,
  authored_at      timestamptz NOT NULL,           -- when `cid commit` ran
  -- the moment it was sealed (the clock, not the transaction's start):
  -- a revision landing later at or under cutoff_rev is refused at the
  -- next commit (api.sealedIntact)
  recorded_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  -- the version's statistics, one aggregate, computed once (core/version.zig)
  stats            jsonb
);
CREATE INDEX commits_by_branch ON commits (dataset_id, branch, commit_id DESC);

CREATE TABLE refs (
  dataset_id       uuid NOT NULL REFERENCES datasets(dataset_id),
  name             text NOT NULL,                  -- 'main', 'cleanup', 'v1.0.0'
  kind             text NOT NULL CHECK (kind IN ('branch','release')),
  commit_id        uuid NOT NULL REFERENCES commits(commit_id),
  start_commit_id  uuid REFERENCES commits(commit_id),
  manifest_path    text,
  manifest_hash    bytea CHECK (manifest_hash IS NULL OR octet_length(manifest_hash) = 32),
  card             jsonb,                          -- card snapshot at release time
  changes_from     text,                           -- the release `changes` counts from
  changes          jsonb,                          -- files and annotations added/changed/removed since it
  PRIMARY KEY (dataset_id, name)
);

-- Releases never move (invariant 5): a release ref may be inserted, never changed.
CREATE FUNCTION reject_release_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF ((TG_OP = 'DELETE' AND OLD.kind = 'release')
      OR (TG_OP = 'UPDATE' AND OLD.kind = 'release'))
     AND current_setting('cid.maintenance', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'cid: release ''%'' never moves (invariant 5)', OLD.name;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER refs_releases_immutable
  BEFORE UPDATE OR DELETE ON refs
  FOR EACH ROW EXECUTE FUNCTION reject_release_change();

CREATE TABLE policy_versions (
  dataset_id  uuid NOT NULL REFERENCES datasets(dataset_id),
  version     text NOT NULL,
  body        jsonb NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (dataset_id, version)
);

---------------------------------------------------------------------------
-- The dataset repository write queue
---------------------------------------------------------------------------

CREATE TABLE git_writes (
  dataset_id    uuid NOT NULL REFERENCES datasets(dataset_id),
  release       text NOT NULL,
  status        text NOT NULL CHECK (status IN ('pending','done','failed')),
  git_commit    text,
  attempts      int  NOT NULL DEFAULT 0,
  last_error    text,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (dataset_id, release)
);

---------------------------------------------------------------------------
-- Accounts, keys, access, audit
---------------------------------------------------------------------------

CREATE TABLE accounts (
  account_id    text PRIMARY KEY,   -- 'gitlab:<id>' | 'local:<id>' | 'deploy:<id>'
  display_name  text NOT NULL,
  source        text NOT NULL CHECK (source IN ('gitlab','dashboard','deploy')),
  synced_at     timestamptz
);

-- One key, one account: a key already registered is refused, so nobody
-- can claim another person's (public) key. Where it came from decides who
-- may remove it: the GitLab sync replaces only its own, a person removes
-- what they added in the dashboard.
CREATE TABLE ssh_keys (
  fingerprint   text PRIMARY KEY,   -- SHA256:… as OpenSSH prints it
  account_id    text NOT NULL REFERENCES accounts(account_id),
  public_key    text NOT NULL,
  title         text NOT NULL DEFAULT '',
  source        text NOT NULL DEFAULT 'gitlab' CHECK (source IN ('gitlab','dashboard','admin')),
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

-- Personal access tokens, made on the dashboard for scripts and CI: a
-- token acts as the person who made it, with their access, until it
-- expires or is revoked (deleted). Only its hash is kept; the token itself
-- is shown once.
CREATE TABLE personal_tokens (
  token_id      uuid PRIMARY KEY,
  account_id    text NOT NULL REFERENCES accounts(account_id),
  name          text NOT NULL,
  token_hash    bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),  -- BLAKE3
  prefix        text NOT NULL,          -- its first characters, to recognise it by
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  last_used_at  timestamptz
);
CREATE INDEX personal_tokens_by_account ON personal_tokens (account_id);

CREATE TABLE auth_events (
  ts           timestamptz NOT NULL,
  account_id   text,
  fingerprint  text,
  dataset_id   uuid,
  level        text,
  granted      boolean NOT NULL,
  detail       text
);
SELECT create_hypertable('auth_events', 'ts', chunk_time_interval => INTERVAL '7 days');

CREATE TABLE activity_events (
  ts           timestamptz NOT NULL,
  dataset_id   uuid NOT NULL,
  account_id   text NOT NULL,
  action       text NOT NULL,      -- push|tag|branch|merge|card-edit|reveal|purge|…
  ref          text,
  detail       jsonb
);
SELECT create_hypertable('activity_events', 'ts', chunk_time_interval => INTERVAL '7 days');
CREATE INDEX activity_by_dataset ON activity_events (dataset_id, ts DESC);

---------------------------------------------------------------------------
-- Derived from content, once per content hash: previews and table diffs
---------------------------------------------------------------------------

-- The preview queue. One row per content hash, ever: ffmpeg work is a
-- function of ingested content, never of dashboard traffic. Request paths
-- only read; the background worker is the only thing that builds, with
-- bounded attempts so a broken file can never burn CPU in a loop.
CREATE TABLE previews (
  item_hash   bytea PRIMARY KEY REFERENCES items(item_hash),
  status      text NOT NULL DEFAULT 'pending'
              CHECK (status IN ('pending','building','done','failed','skipped')),
  attempts    int  NOT NULL DEFAULT 0,
  -- why a failed or skipped item will not be retried, in plain words
  reason      text,
  -- the blurred rendition exists beside the thumbnail (invariant 20): a
  -- restricted view presigns only this, never the clear one
  blurred     boolean NOT NULL DEFAULT false,
  -- CSV, Parquet and JSONL: rows, per-column type, range, distinct count
  -- and nulls, the first rows (at most 64 KB; the server build's worker)
  table_stats jsonb,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX previews_pending ON previews (updated_at) WHERE status = 'pending';

-- Row-level diffs of table files, computed the first time anyone asks and
-- kept: a comparison of two contents costs DuckDB work once, ever. An
-- unreadable table is an answer too ('unreadable'), never retried.
CREATE TABLE row_diffs (
  hash_a     bytea NOT NULL REFERENCES items(item_hash),
  hash_b     bytea NOT NULL REFERENCES items(item_hash),
  kind_a     text  NOT NULL CHECK (kind_a IN ('csv','parquet','jsonl')),
  kind_b     text  NOT NULL CHECK (kind_b IN ('csv','parquet','jsonl')),
  status     text  NOT NULL CHECK (status IN ('done','unreadable')),
  result     jsonb,
  reason     text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (hash_a, hash_b, kind_a, kind_b)
);

-- A version as the CLI downloads it (export/bundle.zig): its items, or an
-- export of it, whole or narrowed to a subset — a gzip file in storage,
-- named by its own BLAKE3. Final once no item waits for media metadata;
-- until then provisional, and written again after a while.
CREATE TABLE version_files (
  commit_id  uuid NOT NULL REFERENCES commits(commit_id),
  kind       text NOT NULL CHECK (kind IN ('state','jsonl','yolo')),
  subset     text NOT NULL,             -- canonical JSON: sorted splits, sorted classes
  file_hash  text NOT NULL,
  final      boolean NOT NULL,
  built_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (commit_id, kind, subset)
);

-- Versions to prepare ahead of their first visitor: a new head's
-- statistics, browse index, items file and default export, built by the
-- server's background worker right after the commit (api.prepareNext).
CREATE TABLE version_jobs (
  commit_id  uuid PRIMARY KEY REFERENCES commits(commit_id),
  dataset_id uuid NOT NULL REFERENCES datasets(dataset_id),
  status     text NOT NULL DEFAULT 'pending'
             CHECK (status IN ('pending','building','done','skipped','failed')),
  reason     text,
  queued_at  timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX version_jobs_pending ON version_jobs (queued_at) WHERE status IN ('pending', 'building');

-- What changed between two versions, as the CLI reads it: a gzip file of
-- JSON lines in storage, written once by the server (both versions are
-- sealed, so a diff never changes).
CREATE TABLE version_diffs (
  dataset_id uuid  NOT NULL REFERENCES datasets(dataset_id),
  commit_a   uuid  NOT NULL REFERENCES commits(commit_id),
  commit_b   uuid  NOT NULL REFERENCES commits(commit_id),
  file_hash  text  NOT NULL,
  summary    jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (commit_a, commit_b)
);

---------------------------------------------------------------------------
-- Roles
---------------------------------------------------------------------------

-- The annotation platform's INSERT-only role (docs/data-model.md).
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'cid_writer') THEN
    CREATE ROLE cid_writer NOLOGIN;
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO cid_writer;
-- Every column but rev_id and ts: those the database sets, so a writer's
-- clock never decides where a revision falls against a sealed cutoff.
GRANT INSERT (dataset_id, branch, path, op, item_id, item_hash, split, author) ON item_revisions TO cid_writer;
GRANT INSERT (dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, attrs, author, policy_ver, parent_rev)
  ON annotation_revisions TO cid_writer;
-- Retry-safe batches: a writer inserts its batch's key in the same
-- transaction as the batch. A retry of a batch that did commit (its
-- acknowledgement lost) fails on the key and writes nothing twice; a
-- resumed import reads which keys are done.
CREATE TABLE revision_batches (
  dataset_id  uuid NOT NULL REFERENCES datasets(dataset_id) ON DELETE CASCADE,
  batch_key   text NOT NULL CHECK (length(batch_key) BETWEEN 1 AND 200),
  written_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (dataset_id, batch_key)
);
GRANT INSERT, SELECT ON revision_batches TO cid_writer;
GRANT SELECT ON datasets, dataset_items, items, policy_versions TO cid_writer;
