-- Deploy keys (docs/access.md): an SSH key a dataset's owners register so a
-- machine (CI) reaches that dataset as itself, never as a person. A key is
-- an account of its own ('deploy:<fingerprint>', source 'deploy') with one
-- SSH key, and access rows at read or write, source 'deploy', which the
-- GitLab sync never touches. A key may serve several datasets, named per
-- dataset here.
ALTER TABLE ssh_keys DROP CONSTRAINT ssh_keys_source_check;
ALTER TABLE ssh_keys ADD CONSTRAINT ssh_keys_source_check CHECK (source IN ('gitlab','dashboard','admin','deploy'));
-- When the front door last handed this key a token (deploy keys show it).
ALTER TABLE ssh_keys ADD COLUMN last_used_at timestamptz;

ALTER TABLE access DROP CONSTRAINT access_source_check;
ALTER TABLE access ADD CONSTRAINT access_source_check CHECK (source IN ('gitlab','dashboard','deploy'));

CREATE TABLE deploy_keys (
  dataset_id  uuid NOT NULL REFERENCES datasets(dataset_id),
  name        text NOT NULL CHECK (name ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
  account_id  text NOT NULL REFERENCES accounts(account_id),
  added_by    text NOT NULL,
  added_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (dataset_id, name),
  UNIQUE (dataset_id, account_id)
);
