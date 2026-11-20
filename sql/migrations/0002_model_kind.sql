-- A third kind: a model is the files a training run produced (weights,
-- configuration, tokenizer), versioned and released exactly as a file
-- dataset is. Its bytes live in the file store and its history here, like
-- any dataset's; nothing about it is kept in a git host's model registry.
ALTER TABLE datasets DROP CONSTRAINT datasets_kind_check;
ALTER TABLE datasets ADD CONSTRAINT datasets_kind_check CHECK (kind IN ('files','annotated','model'));
