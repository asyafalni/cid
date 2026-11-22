-- GitHub as the host a server takes access from (docs/access.md, "Other
-- git hosts"): its people are 'github:<id>' accounts, and their access
-- rows and keys come from the GitHub sync, source 'github', which only
-- that sync adds and removes.
ALTER TABLE accounts DROP CONSTRAINT accounts_source_check;
ALTER TABLE accounts ADD CONSTRAINT accounts_source_check CHECK (source IN ('gitlab','github','dashboard','deploy'));
ALTER TABLE ssh_keys DROP CONSTRAINT ssh_keys_source_check;
ALTER TABLE ssh_keys ADD CONSTRAINT ssh_keys_source_check CHECK (source IN ('gitlab','github','dashboard','admin','deploy'));
ALTER TABLE access DROP CONSTRAINT access_source_check;
ALTER TABLE access ADD CONSTRAINT access_source_check CHECK (source IN ('gitlab','github','dashboard','deploy'));
