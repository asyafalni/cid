# cid — addresses, identity and access (SSH, no login)

Read with `CLAUDE.md` (invariants, words) and `docs/data-model.md` (the accounts,
keys, access and audit tables).

People reach datasets exactly the way they reach git repositories:

```
cid@cidhub.com:your-org/datasets/person-vehicle
└─┬┘ └───┬───┘ └──────────────┬───────────────┘
 user   host          dataset path (same as the GitLab project path)
```

A trailing `.cid` is accepted and ignored. Renamed datasets keep working: the server
redirects old paths (see `dataset_names`) and the CLI prints the new address once.

---

## How a command authenticates

The same pattern Git LFS uses over SSH:

1. The CLI runs the system `ssh` program (so `~/.ssh/config`, agents and hardware keys
   all work): `ssh cid@cidhub.com cid-auth <dataset-path> <read|write>`.
2. On the server, OpenSSH asks cid which account owns that key
   (`AuthorizedKeysCommand`), and runs only cid's restricted command (forced command:
   no shell, no port forwarding, no terminal).
3. cid checks permission and replies with a short-lived HTTPS token (15 minutes) and
   the server's HTTPS URL.
4. The CLI does all transfers over HTTPS with that token (presigned URLs, parallel,
   resumable), and asks for a new token over SSH when it expires.

Every grant and refusal is an `auth_events` row.

## Who you are and what you may do comes from GitLab

Nothing to manage in cid:

- **Identity:** cid syncs the public SSH keys of every member of the datasets group
  from GitLab (the same keys people already use for `git clone`). A key maps to one
  GitLab user.
- **Permission:** GitLab role on the dataset's project decides cid access. Reporter →
  read (clone, pull). Developer → read + write (push). Maintainer → + tag, branch,
  merge, edit the dataset card ("owner" in user-facing text means Maintainer). Anyone
  else is refused, with a message naming the GitLab project to request access to.
- **Sync:** every 10 minutes and on demand (`cid admin sync-gitlab`). Removing someone
  from the GitLab group removes their cid access at the next sync.
- **Dashboard:** people sign in with GitLab (OAuth); the same account and role apply
  as over SSH. See "Sign-in" in `docs/dashboard.md`.
- **Other hosts:** where there is no GitLab to sync from, owners add SSH keys and
  members in the cid dashboard instead. Same checks, different source. (Email
  one-time-link sign-in is **not now**: it would add an SMTP dependency; dashboard-
  managed keys cover the need.)

## CI, scripts and machines

CI jobs use SSH like git does: a deploy key registered for the dataset (read-only or
read-write) in the dashboard — an `accounts` row with source `deploy`. `cid login
<server>` with a token remains available only for machines that cannot use SSH at all.
Its token is stored in `~/.config/cid/credentials`, mode 0600, like `~/.netrc` — not
in an OS keychain (that would need a platform C library per OS; see the dependency
rules in `CLAUDE.md`). The file holds tokens only, never keys, and `cid logout`
deletes it.

## Rules

- SSH is used only to authenticate and hand out tokens; data never flows over the SSH
  connection.
- The forced command accepts only `cid-auth` with a dataset path and `read` or
  `write`; anything else is refused and logged.
- Tokens are scoped to one dataset and one access level, expire in 15 minutes, and
  are never written to disk by the CLI (the `cid login` credentials file is the one
  exception, for SSH-less machines).
- **Hash-existence privacy:** the push protocol's "do you already have this hash?"
  check is answered truthfully only for hashes already referenced by datasets the
  token can read; otherwise the server requests the upload even when the bytes exist,
  and discards the duplicate. This stops push access from becoming an oracle for
  "does this exact file exist in a restricted dataset?".
- Restricted datasets follow the same flow, plus their row-level security and reveal
  logging; GitLab membership alone is not enough unless the project is also marked
  for that restricted dataset's access group.

## Deployment

`deploy/sshd/` holds the hardened `sshd_config` for the `cid` user
(AuthorizedKeysCommand, forced command, no pty/forwarding). HTTPS terminates at a
reverse proxy (Caddy or nginx, config in `deploy/`): Nilo's built-in TLS is young and
barely audited, and the Zig standard library has no TLS server, so the proxy is the
supported path. The cid server listens on localhost behind it.
