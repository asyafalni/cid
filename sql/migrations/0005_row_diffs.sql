-- 0005_row_diffs: row-level diffs of table files (CSV, Parquet, JSONL),
-- computed by the server build with DuckDB the first time anyone asks and
-- kept here, so a comparison of two contents costs DuckDB work once, ever.
-- The answer is a function of the two contents and how each is read; an
-- unreadable table is an answer too ('unreadable'), never retried.

CREATE TABLE row_diffs (
  hash_a     bytea NOT NULL REFERENCES items(item_hash),
  hash_b     bytea NOT NULL REFERENCES items(item_hash),
  kind_a     text  NOT NULL CHECK (kind_a IN ('csv','parquet','jsonl')),
  kind_b     text  NOT NULL CHECK (kind_b IN ('csv','parquet','jsonl')),
  status     text  NOT NULL CHECK (status IN ('done','unreadable')),
  -- the diff ({rows_a, rows_b, columns_*, added, removed, samples}),
  -- or why it could not be read, in plain words
  result     jsonb,
  reason     text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (hash_a, hash_b, kind_a, kind_b)
);
