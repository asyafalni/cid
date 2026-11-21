-- A kept diff records the format it was built in (browse.diff_format):
-- d2 counts an item moved between splits as a change, which d1 missed.
-- A diff kept in another format is rebuilt on its next request.
ALTER TABLE version_diffs ADD COLUMN format text NOT NULL DEFAULT 'd1';
