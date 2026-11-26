# Coming from DVC, Git LFS or Hugging Face

If you already version data with one of these, this page says what each of your
habits becomes in cid, what cid does not do, and how to bring an existing dataset in
with its releases. The DVC and Git LFS imports are one script,
`deploy/import-tags.sh`, run against real DVC and Git LFS repositories at every change
(`tests/import_tags.sh`; and once, by hand, against a DVC remote in MinIO with cid's
files on an NFS share). The Hugging Face recipe's `hf` lines are that tool's own
commands and were not run here: check them against your version.

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

Each git tag of the old repository becomes a cid release of the same name, holding
exactly the data that tag had. [`deploy/import-tags.sh`](../deploy/import-tags.sh)
does it; run it in a **fresh clone** of the old repository. It never changes that
repository's history, only what is checked out in the clone. The dataset gets a
**new, empty** git repository of its own for cid's record (cid writes `README.md`, a
changelog and one tag per release there, so it must not be the repository you are
importing from).

```sh
git clone git@gitlab.com:your-org/old-speech-repo.git && cd old-speech-repo

cid init cid@cid.example:your-org/datasets/speech-id \
  --git git@gitlab.com:your-org/datasets/speech-id.git

# deploy/import-tags.sh, from cid's repository: one file of plain sh
sh import-tags.sh        # writes .cidignore and stops: add your code folders to it
sh import-tags.sh        # imports every tag, oldest first
```

```
[1/4] v1.0
Pushed 1 commit (55 files uploaded) to cid@cid.example:your-org/datasets/speech-id.
[2/4] v1.1
Pushed 1 commit (21 files uploaded) to cid@cid.example:your-org/datasets/speech-id.
[3/4] v1.1-code
Everything up to date.
[4/4] v2.0
Pushed 1 commit (1 file uploaded) to cid@cid.example:your-org/datasets/speech-id.

Imported. 'cid log' lists the releases; the folder is left at the last tag.
```

What it does for each tag: checks the tag out, lets DVC fetch that tag's files
(`dvc pull`, with whatever credentials your DVC remote needs, as you already have
them), stages and commits what changed, pushes, and makes the release, with a note
naming the tag and its date. What to know:

- **It stops at the first thing that fails**, says what, and imports nothing after
  it. Run it again and it carries on after the last tag that is already a release.
  A release is only ever made from a tag whose files were all fetched.
- **Every tag becomes a release**, also one that changed only code: it is a second
  name for the same data, so every version your old code refers to exists.
- **Files are sent once.** A file that many tags share goes up with the first; a
  renamed file is not sent again.
- A file a later tag stopped tracking is not carried along.
- `sh import-tags.sh v1.0 v1.1` imports only those, in that order.
- A tag whose name cid cannot spell (`release/2.1`) is released with `-` in place of
  the characters it cannot hold (`release-2.1`), and says so.
- A commit's author in cid is whoever runs the import (`CID_AUTHOR`); the release's
  note carries the tag's date and message.

Where the files will live matters before a large import: cid's store can keep them
on a NAS ([`deploy/nas`](../deploy/nas/README.md), which also says how much room and
time an import takes), and the import is best run from a machine on the same network
as both the old remote and the new store. `tests/import_tags.sh` runs this against a
real DVC repository at every change, and compares every release with DVC's own
checkout of its tag.

Why a script and not a loop in this page: the short loop that used to be here
(`git checkout`, `dvc checkout`, `dvc pull`, then `cid add`, `commit`, `push`, `tag`)
was wrong in a way that hid itself. In a fresh clone `dvc checkout` fails before
`dvc pull` ever runs, and the loop went on to release the nearly empty folder.

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

The same script as for DVC ([above](#bringing-a-dvc-dataset-in-with-its-releases)):
it sees that the repository uses LFS and lets LFS fetch each tag's files
(`git lfs pull`) before releasing it.

```sh
git clone git@gitlab.com:your-org/old-scans-repo.git && cd old-scans-repo

cid init cid@cid.example:your-org/datasets/scans \
  --git git@gitlab.com:your-org/datasets/scans.git

# deploy/import-tags.sh, from cid's repository: one file of plain sh
sh import-tags.sh        # writes .cidignore and stops: add your code folders to it
sh import-tags.sh        # imports every tag, oldest first
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
