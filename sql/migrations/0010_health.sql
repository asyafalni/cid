-- A version's health (docs/dashboard.md, 4.5): the raw counts its checks
-- read, computed once by one aggregate and kept, like its statistics.
ALTER TABLE commits ADD COLUMN health jsonb;
