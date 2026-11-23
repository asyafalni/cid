"""The Hugging Face door, read by the real clients (docs/roadmap.md, C1).

Run by tests/hf_client.sh, with HF_ENDPOINT at a cid server and HF_TOKEN
its token: every call here is what code that already uses Hugging Face
makes, unchanged. Each check prints one line; any failure stops it.
"""
import os
import sys

from datasets import load_dataset
from huggingface_hub import HfApi, hf_hub_download, snapshot_download

FILES = "hf/datasets__clients-files"
BOXES = "hf/datasets__clients-boxes"
MODEL = "hf/models__clients-model"
fixtures = sys.argv[1]


def ok(what):
    print(f"ok  {what}")


api = HfApi()

# A file dataset: its releases and branch, its files, one file, all of it.
refs = api.list_repo_refs(FILES, repo_type="dataset")
assert "v1.0.0" in [t.name for t in refs.tags], refs
assert "main" in [b.name for b in refs.branches], refs
ok("list_repo_refs: v1.0.0 and main")
files = sorted(api.list_repo_files(FILES, repo_type="dataset", revision="v1.0.0"))
assert files == ["data/test.csv", "data/train.csv"], files
ok(f"list_repo_files: {files}")
path = hf_hub_download(FILES, "data/train.csv", repo_type="dataset", revision="v1.0.0")
assert open(path, "rb").read() == open(os.path.join(fixtures, "people.csv"), "rb").read()
ok("hf_hub_download: the bytes pushed")
folder = snapshot_download(FILES, repo_type="dataset", revision="v1.0.0")
assert sorted(os.listdir(os.path.join(folder, "data"))) == ["test.csv", "train.csv"]
ok("snapshot_download: the whole release")

# load_dataset over the same release: two splits, the table's rows.
ds = load_dataset(FILES, revision="v1.0.0")
assert set(ds.keys()) == {"train", "test"}, ds
assert ds["train"].num_rows == 5, ds
assert "name" in ds["train"].column_names
ok(f"load_dataset: splits {sorted(ds.keys())}, {ds['train'].num_rows} rows")
first = next(iter(load_dataset(FILES, revision="v1.0.0", split="train", streaming=True)))
assert first["name"] == "Ana Wijaya", first
ok("load_dataset streaming: the first row")

# An annotated dataset: its items and their annotations, by split.
boxes = load_dataset(BOXES, revision="v1.0.0")
assert set(boxes.keys()) == {"train", "val"}, boxes
row = boxes["train"][0]
assert row["annotations"][0]["class"] == "person", row
assert row["width"] == 4 and row["height"] == 3, row
ok(f"load_dataset (annotated): splits {sorted(boxes.keys())}, a person box with its image size")

# A model: its files, on the model routes.
config = hf_hub_download(MODEL, "config.json", revision="v1.0.0")
assert b'"hidden_size"' in open(config, "rb").read()
ok("hf_hub_download (model): config.json")
print("all Hugging Face client checks passed")
