-- How much a dataset is read (roadmap U15): one row per dataset and day,
-- counting the times a clone, pull or checkout fetched one of its versions.
-- A count only, never who: the activity log is where a restricted
-- dataset's reads are named (invariant 11), and it has its own rules.
CREATE TABLE dataset_reads (
  dataset_id    uuid NOT NULL REFERENCES datasets(dataset_id),
  day           date NOT NULL,
  reads         bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (dataset_id, day)
);
