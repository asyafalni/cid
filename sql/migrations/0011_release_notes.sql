-- A release's own words (`cid tag <name> -m "..."`, as git's annotated
-- tags carry a message): given once when the release is made and, like the
-- release, never changed (invariant 5). Null for a release made without.
ALTER TABLE refs ADD COLUMN notes text;
