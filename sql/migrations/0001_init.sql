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

CREATE TABLE dataset_names (
  old_name    text PRIMARY KEY,
  dataset_id  uuid NOT NULL REFERENCES datasets(dataset_id),
  renamed_at  timestamptz NOT NULL DEFAULT now()
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
  item_hash   bytea PRIMARY KEY CHECK (octet_length(item_hash) = 32),
  size_bytes  bigint NOT NULL CHECK (size_bytes >= 0),
  media_type  text NOT NULL,
  meta        jsonb NOT NULL DEFAULT '{}',
  created_at  timestamptz NOT NULL DEFAULT now()
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

---------------------------------------------------------------------------
-- Revisions: append-only history (hypertables)
---------------------------------------------------------------------------

CREATE TABLE item_revisions (
  rev_id      uuid        NOT NULL,                -- UUIDv7
  ts          timestamptz NOT NULL,                -- the UUIDv7 time
  dataset_id  uuid        NOT NULL REFERENCES datasets(dataset_id),
  branch      text        NOT NULL DEFAULT 'main',
  path        text        NOT NULL,
  op          text        NOT NULL CHECK (op IN ('add','update','delete')),
  item_id     uuid,                                -- null for delete
  item_hash   bytea CHECK (item_hash IS NULL OR octet_length(item_hash) = 32),
  split       text,
  author      text        NOT NULL,
  CHECK ((op = 'delete') = (item_hash IS NULL))
);
SELECT create_hypertable('item_revisions', 'ts', chunk_time_interval => INTERVAL '7 days');
CREATE INDEX item_revisions_lookup
  ON item_revisions (dataset_id, branch, path, rev_id DESC);

CREATE TABLE annotation_revisions (
  rev_id         uuid        NOT NULL,
  ts             timestamptz NOT NULL,
  dataset_id     uuid        NOT NULL REFERENCES datasets(dataset_id),
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
  recorded_at      timestamptz NOT NULL DEFAULT now(),
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
  manifest_sha256  bytea CHECK (manifest_sha256 IS NULL OR octet_length(manifest_sha256) = 32),
  card             jsonb,                          -- card snapshot at release time
  PRIMARY KEY (dataset_id, name)
);

-- Releases never move (invariant 5): a release ref may be inserted, never changed.
CREATE FUNCTION reject_release_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (TG_OP = 'DELETE' AND OLD.kind = 'release')
     OR (TG_OP = 'UPDATE' AND OLD.kind = 'release') THEN
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

CREATE TABLE ssh_keys (
  fingerprint   text PRIMARY KEY,   -- SHA256:… as OpenSSH prints it
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
-- Roles
---------------------------------------------------------------------------

-- The annotation platform's INSERT-only role (docs/data-model.md).
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'cid_writer') THEN
    CREATE ROLE cid_writer NOLOGIN;
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO cid_writer;
GRANT INSERT ON item_revisions, annotation_revisions TO cid_writer;
GRANT SELECT ON datasets, dataset_items, items, policy_versions TO cid_writer;
