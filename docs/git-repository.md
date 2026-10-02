# cid — the dataset's git repository

Read with `CLAUDE.md`. This is how "git lives inside cid" works in practice: every
dataset is paired with a git repository that cid writes and people only read.

The pairing is set when the dataset is created (`cid init <address> --git <url>`, or
the platform's create-dataset API). cid checks at that moment that the repository
exists, is empty or cid-owned, and that the server's git credential can push to it;
if not, the dataset is not created and the error says how to fix it.

---

## What cid writes, on every release

One git commit, one git tag with the release name:

```
README.md          dataset card: summary, counts, classes, splits, known gaps, quality,
                   and links: browse, compare with the previous release, health, clone
CHANGELOG.md       release notes, newest first: the last 50 releases in full, then one
                   line per older release linking to the dashboard (bounded growth)
release.json       dataset, release, commit id, manifest sha256, created at, clone
                   command, dashboard URL
stats.yaml         counts per class, split and media type (one value per line, so git
                   diffs between releases read clearly)
classes.yaml       class map (index → name), annotated datasets
policy.md          the policy version used, annotated datasets
files.txt          file datasets under 10,000 files and 1 MB rendered: sorted list of
                   path + size + short hash; otherwise omitted, README links to the
                   dashboard
.cid               marker file: server URL and dataset name, so `cid clone <git-url>` works
```

The card fields in `README.md` render from the **release's card snapshot**
(`refs.card`, see `docs/data-model.md`), never from the live card — so editing the
card between releases cannot change what an old release renders.

**What cid never writes to git:** data files, previews, the Parquet manifest, anything
over 1 MB per file or 5 MB per release, and any content of a restricted dataset beyond
counts (no class names that reveal identities, no file names, no samples).

## Rules

- **One-way.** cid writes; cid never reads data back from git. Humans get read access
  only; the repository's default branch is protected so only the cid bot can push.
  (The single exception to "never reads": `cid clone <git-url>` reads the tiny `.cid`
  marker to find the cid server — see `CLAUDE.md`, CLI rules.)
- **Deterministic.** The same release always renders the same files (sorted keys, fixed
  formats, the release's card snapshot, no "generated at" times except the release's
  own timestamp), so re-running produces no new git commit.
- **Exact and in order.** Each commit's tree is exactly the release's rendered files
  (a file an earlier release had and this one does not, like `files.txt` once a
  dataset is restricted, is removed). Pending releases are written in release order,
  and a release whose tag the repository already has is never rendered again, so a
  resync can never put an older release's files on top of a newer one.
- **Never blocks a release.** The release is created in cid first; the git write is
  queued (`git_writes`) and retried with backoff. The dashboard and `cid log` show
  "git: pending" until it lands; `cid admin git <dataset>` shows errors and `--resync`
  repairs gaps.
- **History matches.** Git tags equal cid release names; git commit order equals
  release order. If someone force-pushes or deletes a tag, cid reports it and
  `--resync` restores it; cid never rewrites its own earlier commits.
- **Links, not copies.** Anything heavy (browsing items, visual diffs, health) is a
  link into the cid dashboard, pinned to that release.
- **Renames:** renaming a dataset does not move its git repository; cid keeps pushing
  to the configured `git_url` until a Maintainer changes it.

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

---

## On GitLab.com (the default host)

- **One GitLab group** holds all dataset projects, e.g. `your-org/datasets/<dataset>`.
  Projects are **private**; people get Reporter (read) access through the group.
- **Credential: one SSH deploy key** owned by the cid server, enabled with **write
  access** on each dataset project. Deploy keys work on every GitLab tier and can be
  allowed to push to protected branches, so no paid seat or personal token is needed.
- **Protection:** `main` is a protected branch with "Allowed to push and merge" set to
  the cid deploy key only; release tags are protected the same way. `cid init` checks
  that the cid server can reach the repository and push to it (it pushes, then
  deletes, a throwaway `refs/cid/write-check`; branches and tags are untouched) and
  refuses, with git's own reason, when it cannot. The protection settings themselves
  are not checked yet.
- **Optional GitLab Releases:** if the server is also given a token with the `api`
  scope, cid creates a GitLab Release for each tag, with the release notes and links
  to the dashboard. Without a token, cid skips this and everything else still works.
- **What leaves your network:** only the small files above. Keep dataset names, cards
  and release notes free of customer names or anything contractually confidential, and
  restricted datasets never send more than counts.
- **Network:** the cid server needs outbound SSH (port 22, or 443 via
  `altssh.gitlab.com`) to GitLab.com. If it's unreachable, git writes wait in the
  queue.
- Everything here is GitLab-specific configuration only; the git writer itself speaks
  plain git and works with any host (self-hosted GitLab, Gitea, GitHub).

Server config holds one git credential (on GitLab.com: that SSH deploy key) and one
GitLab token with `read_api` scope, used only to read project membership and users'
public SSH keys. Users never handle either.
