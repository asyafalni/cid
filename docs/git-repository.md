# cid — the dataset's git repository

Read with `CLAUDE.md`. This is how "git lives inside cid" works in practice: every
dataset is paired with a git repository that cid writes and people read.

The pairing is set when the dataset is created (`cid init <address> --git <url>`, or
the platform's create-dataset API). When the server has a git writer configured
(`CID_GIT_WORKDIR`), it checks at that moment that it can reach the repository and
push to it: it pushes a throwaway ref, `refs/cid/write-check`, then deletes it;
branches and tags are untouched. If either step fails, the dataset is not created and
the error gives git's own reason and what to fix. A server without a git writer
creates the dataset without the check.

Creation then looks at `main`'s protection, and only ever warns (`cid init` prints
the warning; `--json` and the API return it in `warnings`); cid works with any git
host and never refuses a repository for this (`src/gitrepo/protection.zig`):

- On the GitLab the server syncs from (`CID_GITLAB_URL` and `CID_GITLAB_TOKEN`), it
  asks GitLab's protected-branches API and warns when `main` is not protected or
  allows force pushes (anyone who can push could rewrite the dataset's history), or
  when no one may push to it (the write check passes on its scratch ref, and the first
  release would fail).
  GitLab shows a project's protected branches only to its Maintainers, so the token's
  user needs that role on dataset projects; without it the warning says cid could not
  check.
- On any other host it notes once that it cannot check, and what to protect.
- A local repository (a path) gets nothing.

---

## What cid writes, on every release

One git commit (message `release: <name>`, author `cid`) and one git tag with the
release name. cid's files in each commit are exactly that release's, and cid writes
nothing else: the repository may also hold code, docs or anything people commit beside
the dataset, and a release leaves those exactly as they are. Only the paths below are
cid's, so a hand-written `README.md` is replaced at the next release (put your own
text in another file, or in the dataset card). A file cid stops writing (`files.txt`
once a dataset is restricted or too large) is removed; nothing else ever is.

```
README.md          dataset name; latest release, item count, total size and date;
                   `cid clone <git-url>`; one link to browse this release in the
                   dashboard; then the release's card fields (see below)
CHANGELOG.md       every release in full, newest first: name, date, message, item count,
                   and what changed since the release before it (see below)
release.json       dataset, release, commit (cid commit id), manifest_hash,
                   created_at (date), items, changes_from and changes (the counts
                   below), clone (the git URL), dashboard (server URL)
stats.yaml         release, items, bytes, files_by_extension; for annotated datasets
                   also annotations, annotations_by_class and items_by_split (one
                   value per line, so git diffs between releases read clearly)
classes.yaml       class map (index → name, the yolo export's order), annotated datasets
policy.md          the labelling policy version used, annotated datasets that have one
files.txt          releases under 10,000 items: one line per item, sorted by path,
                   path<TAB>size<TAB>first 12 hex characters of its hash
.cid               marker file: server URL and dataset name, so `cid clone <git-url>` works
```

**What changed, per release.** Each `CHANGELOG.md` entry ends with what changed since
the release before it, for a reader who follows the dataset in git without opening
cid, e.g. `Since v1.2.0: 120 files added, 3 modified, 1 deleted; 540 annotations
added, 12 changed, 4 removed.` (the annotation half for annotated datasets). Files
are matched by path (modified: different bytes) and annotations by id (changed: a
different kind, class, shape or attributes), the comparison `cid diff` makes. The
counts are taken when the release is made and kept with it (`refs.changes`,
`docs/data-model.md`), from the newest earlier release; the first release says so.
`cid diff <a> <b>` and the dashboard's Compare show the changes themselves.

The card fields in `README.md` render from the **release's card snapshot**
(`refs.card`, see `docs/data-model.md`), never from the live card, so editing the card
between releases cannot change what an old release renders. Known fields come first,
in this order: purpose, collection, license, provenance, known gaps; any other text
fields follow, by name. Empty fields are left out.

**Restricted datasets** get counts only: `README.md` without the card, `CHANGELOG.md`
without release messages (the change counts stay, with no names), `stats.yaml` without class or split names (the annotation
total only), `release.json` and `.cid`. No `files.txt`, `classes.yaml` or `policy.md`.

**What cid never writes to git:** data files, previews, the Parquet manifest, and any
content of a restricted dataset beyond counts (no class names, no file names, no
samples, no card, no release messages).

**Size limits.** No file cid writes is over 1 MB, and one release's files together
are at most 5 MB, so a long card or a changelog that grows with every release never
makes the repository heavy. A file over its share is cut at a line end, the largest
first, and ends with a note linking to the whole release on the dashboard
(`CHANGELOG.md` is newest first, so the oldest entries go). The cut is the same every
time, so it makes no new commit. `.cid` and `release.json` are never cut.

## Rules

- **One-way.** cid writes its files; cid never reads data back from git. People read
  cid's files and never edit them (a hand edit is replaced at the next release). (The single exception to "never reads": `cid clone <git-url>` reads the tiny
  `.cid` marker to find the cid server; see below.)
- **Deterministic.** The same release always renders the same files (sorted keys, fixed
  formats, the release's card snapshot, no times except the release's own date), so
  re-running produces no new git commit.
- **Exact and in order.** cid's files in each commit are exactly the release's
  rendered files (one an earlier release had and this one does not, like `files.txt`
  once a dataset is restricted or reaches 10,000 items, is removed); files cid does
  not write are left as they are. Pending releases are
  written in release order, and a release whose tag the repository already has is
  never rendered again, so a resync can never put an older release's files on top of
  a newer one.
- **Never blocks a release.** The release is created in cid first; the git write is
  queued (`git_writes`). With `CID_GIT_WORKDIR` set, it is attempted right away at tag
  time and, if it fails, retried on every background tick (`CID_SYNC_INTERVAL_SECS`,
  default 600 seconds). Without it, writes wait in the queue for
  `cid admin git <dataset> --resync`. `cid admin git <dataset>` shows each release's
  status, attempts and last error; `--resync` writes whatever is pending or failed.
  Until a release is written, readers are told: `cid log` decorates its commit
  `(release: v1.2.0; not in git yet)` and the dashboard's history marks it.
- **History matches.** Git tags equal cid release names; git commit order equals
  release order. cid never rewrites its own earlier commits.
  Not built yet: noticing a force-push or a deleted tag and restoring it.
- **Links, not copies.** Anything heavy (browsing items, comparing releases) is a link
  into the cid dashboard, pinned to that release.
- **Renames:** cid never moves a repository on its host (no git command does; that is
  the host's own setting). After a move there, `cid admin rename <dataset> <new-path>
  [--git <new-url>]` first checks it can push to a new URL (the write check `init`
  makes, and nothing is renamed if it fails), renames, then, with plain git, renders
  the newest release in the repository again under the new name and URL and pushes it
  to `main` as one commit, `dataset: now <new-path>`. That rewrites the `.cid` marker
  (which `cid clone <git-url>` reads) and the README. No tag moves: old releases keep
  the files they were made with. If the push fails, the rename stands and
  `cid admin git <dataset> --resync` retries it; it never commits twice for one rename.

The write queue:

```sql
-- one row per release written (or to be written) to the dataset repository
CREATE TABLE git_writes (
  dataset_id    uuid NOT NULL REFERENCES datasets(dataset_id),
  release       text NOT NULL,
  status        text NOT NULL CHECK (status IN ('pending','done','failed')),
  git_commit    text,                    -- sha in the dataset repository, when done
  attempts      int  NOT NULL DEFAULT 0,
  last_error    text,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (dataset_id, release)
);
```

## Server settings

- `CID_GIT_WORKDIR`: where the server keeps one clone per dataset repository. Without
  it there is no git writer: no check at creation, and releases queue their git copy.
- `CID_PUBLIC_URL`: the server address written into the README's browse link,
  `release.json` and the `.cid` marker.
- Credentials: the writer runs the `git` program as the server's own user, so it uses
  that user's SSH setup (`~/.ssh/config`, keys). cid holds no git credential of its own.
- cid always writes the branch `main`.

## `cid clone <git-url>`

An address ending in `.git` is taken as a dataset repository. The CLI runs
`git clone --depth 1 --branch main` of it into a temporary folder, reads the `.cid`
marker (server and dataset), deletes the folder, and continues over SSH and HTTPS as
for any cid address. This is the only time the CLI runs git.

---

## On GitLab.com (the default host)

This section is advice for administrators; cid does not configure GitLab.

- **One GitLab group** holds all dataset projects, e.g. `your-org/datasets/<dataset>`.
  Projects are **private**; people get Reporter (read) access through the group.
- **Membership is cid access.** cid reads a dataset's permissions from the members of
  its GitLab project (Reporter reads, Developer pushes, Maintainer owns;
  `docs/access.md`), so onboarding someone to a dataset means adding them to the
  project, and every cid user can also read its repository. The reverse does not
  hold: to let people **watch a dataset's releases in git without cid access**, make
  its project **internal** (visible to everyone signed in to your GitLab) and do not
  add them as members. They can read and `git pull` the repository (card, release
  notes, stats; counts only for a restricted dataset) but cannot clone the data or
  open it on the dashboard. Guest membership does not do this: a Guest cannot read a
  private project's repository, and gets no cid access either.
- **Credential: one SSH deploy key** for the cid server's user, enabled with **write
  access** on each dataset project. Deploy keys work on every GitLab tier and can be
  allowed to push to protected branches, so no paid seat or personal token is needed.
- **Protection:** make `main` a protected branch with "Allowed to push and merge" set
  to the cid deploy key only, and protect release tags the same way. (To keep code
  beside the dataset in the same repository, let its maintainers merge to `main` too;
  cid leaves their files alone, but then it warns at creation that others can push.) cid warns at
  creation when `main` is unprotected, allows force pushes or lets no one push (see
  above); it does not check tags.
- **What leaves your network:** only the small files above. Keep dataset names, cards
  and release notes free of customer names or anything contractually confidential, and
  restricted datasets never send more than counts.
- **Network:** the cid server needs outbound SSH (port 22, or 443 via
  `altssh.gitlab.com`) to GitLab.com. If it's unreachable, git writes wait in the
  queue.
- Everything here is GitLab-specific configuration only; the git writer itself speaks
  plain git and works with any host (self-hosted GitLab, Gitea, GitHub).

Not built yet: GitLab Releases (a GitLab Release per tag, with the release notes).

The GitLab token with `read_api` scope (`CID_GITLAB_TOKEN`) is separate from the git
writer: it is used only to read project membership and users' public SSH keys
(`docs/access.md`). Users never handle either.
