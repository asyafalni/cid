-- Two more export formats (CLAUDE.md, formats): COCO instances and Pascal
-- VOC, kept like the others.
ALTER TABLE version_files DROP CONSTRAINT version_files_kind_check;
ALTER TABLE version_files ADD CONSTRAINT version_files_kind_check CHECK (kind IN ('state','jsonl','yolo','hf','coco','voc'));
