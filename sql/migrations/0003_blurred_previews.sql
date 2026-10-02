-- 0003_blurred_previews: restricted items are shown blurred until revealed
-- (invariant 20), and the blur is made on the server, never in the
-- browser: a presigned URL to the clear image is the content itself.
--
-- The worker makes the blurred rendition beside every thumbnail, from the
-- same decode, for every visual item: identical bytes can sit in a
-- restricted dataset, and a dataset can become restricted later, so the
-- blur belongs to the content hash like the thumbnail does. `blurred`
-- records that it exists, so a restricted view never presigns one that
-- is missing — and never falls back to the clear thumbnail.

ALTER TABLE previews ADD COLUMN blurred boolean NOT NULL DEFAULT false;

-- Previews built before this migration have no blur: build them once
-- more. Ingest-bound backfill, one ffmpeg decode per content hash, the
-- same rule the queue always followed.
UPDATE previews SET status = 'pending', attempts = 0, reason = NULL, updated_at = now()
 WHERE status = 'done';
