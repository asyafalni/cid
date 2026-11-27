-- The yolo export changed its layout (images under images/, the lists
-- naming them there, no `path:` in dataset.yaml): the tools that read it
-- find a label by swapping an image path's /images/ for /labels/. Exports
-- built before are forgotten here and built again when next asked for;
-- version_files is a cache of what storage holds, never history.
DELETE FROM version_files WHERE kind = 'yolo';
