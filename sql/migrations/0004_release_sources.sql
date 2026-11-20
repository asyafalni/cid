-- Lineage (docs/roadmap.md, C3): the dataset releases a model release was
-- trained on, named at `cid tag --trained-on`. A link, never a copy: the
-- source dataset, its release name, and the commit and manifest hash that
-- release had, so the record still says exactly what was meant if the
-- source is renamed. Written with the release, never changed: a release
-- never moves (invariant 5), and neither does what it says it came from.
CREATE TABLE release_sources (
  dataset_id         uuid  NOT NULL REFERENCES datasets(dataset_id),   -- the model
  release            text  NOT NULL,
  source_dataset_id  uuid  NOT NULL REFERENCES datasets(dataset_id),
  source_release     text  NOT NULL,
  source_commit_id   uuid  NOT NULL REFERENCES commits(commit_id),
  manifest_hash      bytea NOT NULL CHECK (octet_length(manifest_hash) = 32),
  PRIMARY KEY (dataset_id, release, source_dataset_id, source_release)
);
CREATE INDEX release_sources_by_source ON release_sources (source_dataset_id, source_release);

CREATE FUNCTION reject_release_source_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF current_setting('cid.maintenance', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'cid: what release ''%'' was trained on never changes (invariant 5)', OLD.release;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER release_sources_immutable
  BEFORE UPDATE OR DELETE ON release_sources
  FOR EACH ROW EXECUTE FUNCTION reject_release_source_change();
