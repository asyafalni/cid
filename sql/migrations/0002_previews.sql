-- 0002_previews: the preview queue. One row per content hash, ever —
-- ffmpeg work is a function of ingested content, never of dashboard
-- traffic. Request paths only read; the background worker is the only
-- thing that builds, with bounded attempts so a broken file can never
-- burn CPU in a loop.

CREATE TABLE previews (
  item_hash   bytea PRIMARY KEY REFERENCES items(item_hash),
  status      text NOT NULL DEFAULT 'pending'
              CHECK (status IN ('pending','building','done','failed','skipped')),
  attempts    int  NOT NULL DEFAULT 0,
  -- why a failed or skipped item will not be retried, in plain words
  reason      text,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX previews_pending ON previews (updated_at) WHERE status = 'pending';
