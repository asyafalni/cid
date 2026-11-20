-- The Hugging Face door (src/server/hf.zig) serves an annotated dataset's
-- annotations as one plain JSON-lines file per split: an export kind of
-- its own ('hf': the jsonl export's lines, without the CLI's bundle
-- framing), kept like the others.
ALTER TABLE version_files DROP CONSTRAINT version_files_kind_check;
ALTER TABLE version_files ADD CONSTRAINT version_files_kind_check CHECK (kind IN ('state','jsonl','yolo','hf'));
