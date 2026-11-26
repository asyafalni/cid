# Coming from DVC, Git LFS or Hugging Face

If you already version data with one of these, this page says what each of your
habits becomes in cid, what cid does not do, and how to bring an existing dataset in
with its releases. The loop every recipe shares (check out a git tag, then `cid add`,
`commit`, `push`, `tag`) was run against a real server before it was written down,
including a tag that changed no data. The `dvc`, `git lfs` and `hf` lines are those
tools' own commands and were not run here: check them against your versions.

The one difference behind all three: **DVC and Git LFS live inside git; git lives
inside cid.** You work in cid alone (`add`, `commit`, `push`), the data never touches
git, and cid writes a small readable record of every release into a git repository by
itself. There are no pointer files to commit and no second tool to keep in step.

## From DVC

| You did | In cid |
|---|---|
| `dvc add data/` then `git add data.dvc .gitignore` | `cid add data/` |
| `git commit -m "…"` | `cid commit -m "…"` (local, instant, offline) |
| `dvc push` then `git push` | `cid push` |
| `git pull` then `dvc pull` | `cid pull` |
| `git checkout v1.2.0` then `dvc checkout` | `cid checkout v1.2.0` (only changed files download) |
| `git tag v1.2.0 && git push --tags` | `cid tag v1.2.0` (a release; it never moves) |
| `dvc diff v1 v2` | `cid diff v1 v2`, with rows for CSV, Parquet and JSONL |
| `dvc status` | `cid status` |
| `dvc get` / `dvc import <repo> <path>` | `cid clone <address>` (a whole dataset, or `--split`/`--class` of an annotated one) |
| `dvc remote add` and its credentials | nothing: the address names the server, your SSH key is your identity |
| `dvc gc` | `cid admin gc` (the server's administrator; a release is never collected) |
| `.dvcignore` | `.cidignore` |
| the DVC cache (`.dvc/cache`) | `~/.cache/cid`, shared by every clone on the machine |

What cid does not do, on purpose:

- **Pipelines and experiments** (`dvc repro`, `dvc.yaml`, `dvc exp`, metrics, plots).
  cid versions data and the models trained on it; it does not run anything. Keep DVC,
  or any other runner, for pipelines if you use them, reading its inputs from a
  `cid clone`.
- **Several remotes.** A dataset lives on one cid server.
- **Data in your code repository's history.** A dataset is its own thing with its own
  address; code refers to it by address and release (`…/speech-id` at `v1.3.0`).

What you gain: a server that knows who may read what (your git host's roles), one
command instead of two, releases that can be rebuilt and verified
(`cid admin verify`), a dashboard that shows the data and every change between two
versions, and the same data read by Hugging Face libraries with two environment
variables.

### Bringing a DVC dataset in, with its releases

Each git tag of the old repository becomes a cid release with the same name. Run
this in a clone of the old repository; it never changes that repository's history.
The dataset gets a **new, empty** git repository of its own for cid's record (cid
writes `README.md`, a changelog and one tag per release there, so it must not be the
repository you are importing from).

```sh
cd my-dvc-repo

# What is not data: git and DVC's own files. Add your code folders too.
printf '.git/\n.dvc/\n*.dvc\n.dvcignore\n.gitignore\n.gitattributes\ndvc.yaml\ndvc.lock\n' > .cidignore
printf '.cid/\n.cidignore\n' >> .git/info/exclude        # keep git blind to cid's files

cid init cid@cid.example:your-org/datasets/speech-id \
  --git git@gitlab.com:your-org/datasets/speech-id.git

for tag in $(git tag --sort=creatordate); do
  git checkout -q "$tag" && dvc checkout -q && dvc pull -q
  cid add . && cid commit -m "Import $tag" && cid push && cid tag "$tag"
done
```

Where the files will live matters before a large import: cid's store can keep them
on a NAS ([`deploy/nas`](../deploy/nas/README.md), which also says how much room and
time an import takes), and the loop is best run from a machine on the same network
as both the old remote and the new store. It can be stopped and started again: tags
already imported make no new commit, and a push picks up where it stopped.

A tag that changed no data makes no commit (`cid commit` says "nothing staged") and
so no release; that is the right outcome, and the loop moves on. Files already
uploaded are never sent again, so releases that share most of their data cost only
their difference. When it is done, `cid log` lists the releases, and the old
repository can be archived.

## From Git LFS

| You did | In cid |
|---|---|
| `git lfs track "*.wav"` and commit `.gitattributes` | nothing: every file is stored the same way, whatever its type |
| `git add`, `git commit`, `git push` | `cid add`, `cid commit`, `cid push` |
| `git clone` then `git lfs pull` | `cid clone` |
| `git lfs fetch --all`, `git lfs prune` | nothing: a folder holds one version; others come from the shared cache or the server when you check them out |
| `git diff` on a pointer file | `cid diff v1 v2`: the files that changed, and the rows for tables |
| a storage quota on the git host | your own storage (SeaweedFS, or any S3) |

What cid does not do: **file locking** (`git lfs lock`). Two people changing the same
file get a listed conflict at `cid pull`, and one of them decides
(`cid checkout --mine|--theirs <path>`).

What changes for the better: the git repository stays small for ever (cid writes one
small commit per release, never the data), a clone downloads one version instead of
smudging every file of history you touch, and the data has a dashboard.

### Bringing an LFS dataset in

The same loop as for DVC, without the DVC lines: check out each tag, let LFS fetch
its files, and release it.

```sh
cd my-lfs-repo
printf '.git/\n.gitattributes\n.gitignore\n' > .cidignore
printf '.cid/\n.cidignore\n' >> .git/info/exclude

cid init cid@cid.example:your-org/datasets/scans \
  --git git@gitlab.com:your-org/datasets/scans.git

for tag in $(git tag --sort=creatordate); do
  git checkout -q "$tag" && git lfs pull
  cid add . && cid commit -m "Import $tag" && cid push && cid tag "$tag"
done
```

## From Hugging Face

| You did | In cid |
|---|---|
| `hf upload` / `push_to_hub()` | `cid add`, `cid commit`, `cid push` |
| `load_dataset("org/name", revision="v1")` | the same line, with `HF_ENDPOINT` and `HF_TOKEN` set (below) |
| `snapshot_download(...)`, `hf download` | the same, or `cid clone` |
| `from_pretrained("org/model")` | the same, for a model kept in cid |
| a tag or a branch as `revision` | a release or a branch; a release never moves |
| the dataset viewer | the dashboard: any size, any file type, annotations drawn on the item, every change between two versions |
| a private repository and its plan | your own server, with your git host's roles |

Reading does not change. Code that loads data with Hugging Face libraries reads a cid
dataset as it is:

```sh
export HF_ENDPOINT=https://cid.example HF_TOKEN=$CID_PAT    # a cid personal token
python -c 'from datasets import load_dataset
print(load_dataset("your-org/datasets__speech-id", revision="v1.3.0"))'
```

A Hugging Face repo id holds one `/`, so the inner slashes of a cid path are written
`__`. The door is read-only: uploads are `cid push`.

What cid does not do: a public hub and its community (discussions, Spaces, model
cards as a social page), uploads through the Hugging Face API, and chunk-level
storage (Xet). A changed file is stored again in full, so a large table is better
kept as partitioned files.

### Bringing a Hugging Face dataset in

Download a revision into a folder, and make it the first release. Repeat for each
revision you want to keep, oldest first.

```sh
mkdir speech-id && cd speech-id
cid init cid@cid.example:your-org/datasets/speech-id \
  --git git@gitlab.com:your-org/datasets/speech-id.git
printf '.cache/\n' > .cidignore                 # the downloader's own folder

for rev in v1.0 v1.1 main; do
  hf download your-org/speech-id --repo-type dataset --revision "$rev" --local-dir .
  cid add . && cid commit -m "Import $rev" && cid push && cid tag "$rev"
done
```

`hf download` adds and replaces files but does not remove ones the revision no longer
has; for a revision that dropped files, start it from an empty folder (keep `.cid/`
and `.cidignore`). A branch name such as `main` is a poor release name, since a
release never moves: give it a version (`cid tag v1.2.0`).

## Things that are the same everywhere

- Any file type is accepted and stored as it is. cid reads inside a file only to
  preview it and to diff tables.
- A file is stored once, by its content hash, however many releases hold it.
- Every download is checked against its hash before it appears in the folder.
- `cid help` lists the everyday commands; `cid help --json` gives them to a program.
