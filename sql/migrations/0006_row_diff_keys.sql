-- A table's key (`.cidkeys`) is part of what a row diff answers: the same
-- two contents compared by key 'id' and compared whole are two answers,
-- each kept. '' is a diff by whole rows.
ALTER TABLE row_diffs ADD COLUMN key text NOT NULL DEFAULT '';
ALTER TABLE row_diffs DROP CONSTRAINT row_diffs_pkey;
ALTER TABLE row_diffs ADD PRIMARY KEY (hash_a, hash_b, kind_a, kind_b, key);
