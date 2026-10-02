-- 0004_table_stats: CSV, Parquet and JSONL files get table statistics
-- (row count, per-column type, range, distinct count and nulls, the first
-- rows), built once per content hash by the preview worker in the server
-- build, like a thumbnail. Kept here as a small jsonb value (capped at
-- 64 KB by the worker) so the drawer reads it with no storage round trip.

ALTER TABLE previews ADD COLUMN table_stats jsonb;

-- Tables skipped before this existed get one more pass.
UPDATE previews p SET status = 'pending', attempts = 0, reason = NULL, updated_at = now()
 WHERE p.status = 'skipped'
   AND EXISTS (SELECT 1 FROM item_revisions r
                WHERE r.item_hash = p.item_hash
                  AND lower(r.path) ~ '\.(csv|parquet|jsonl|ndjson)$');
