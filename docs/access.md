# cid — addresses, identity and access (SSH, no login)

Read with `CLAUDE.md` (invariants, words) and `docs/data-model.md` (the accounts,
keys, access and audit tables).

People reach datasets exactly the way they reach git repositories:

```
cid@cidhub.com:your-org/datasets/person-vehicle
└─┬┘ └───┬───┘ └──────────────┬───────────────┘
 user   host          dataset path (same as the GitLab project path)
```

A trailing `.cid` is accepted and ignored.

Not built yet: rename redirects. The schema has a `dataset_names` table, but no code
reads it; a renamed dataset is reachable only at its new path.

---

## How a command authenticates

The same pattern Git LFS uses over SSH:

1. The CLI runs the system `ssh` program (so `~/.ssh/config`, agents and hardware keys
   all work): `ssh cid@cidhub.com cid-auth <dataset-path> <read|write|maintain>`.
   `read` for clone, pull, checkout, log and diff; `write` for init and push;
   `maintain` for tag, branch and merge (and editing the dataset card).
2. On the server, OpenSSH asks cid which account owns that key
   (`AuthorizedKeysCommand`), and runs only cid's restricted command (forced command:
   no shell, no port forwarding, no terminal).
3. cid checks the `access` table and replies with a short-lived HTTPS token
   (15 minutes, one dataset, one level) and the server's HTTPS URL (`CID_PUBLIC_URL`).
4. The CLI does all transfers over HTTPS with that token (presigned URLs, parallel,
   resumable). A command that outlives its 15-minute token asks for a fresh one and
   retries once.

Every permission decision on a well-formed `cid-auth` request, granted or refused, is
an `auth_events` row. Malformed commands, unknown keys (sshd refuses them before cid
runs) and HTTP 401/403 answers are not logged.

### Overrides: CI, scripts and stored logins

Before trying SSH, a command looks for two other ways in, in this order:

1. **`CID_SERVER` and `CID_TOKEN` in the environment.** They win over everything else.
   This is what CI uses today.
2. **A stored `cid login`.** `echo "$TOKEN" | cid login <server-url>` stores the server
   and token in `~/.config/cid/credentials` (mode 0600, like `~/.netrc`; tokens only,
   never keys; not an OS keychain, which would need a platform C library per OS).
   When present it is used for every dataset, in preference to SSH. `cid logout`
   deletes it.

The token in either can be an SSH-issued one or the server's static token: the
`CID_TOKEN` that `cid admin serve` was started with. **The static token has full
access to every dataset**: it is the one exception to "tokens are scoped to one
dataset", and it also lists datasets across the server. Keep it for administrators and
trusted automation.

## Who you are and what you may do comes from GitLab

Nothing to manage in cid:

- **Identity:** for each dataset, cid reads the members of the GitLab project with the
  same path as the dataset, and the public SSH keys of each member (the same keys
  people already use for `git clone`). A key maps to one GitLab user
  (`gitlab:<user id>`).
- **Permission:** the GitLab role on the dataset's project decides cid access.
  Reporter → read. Developer → write. Maintainer and Owner → maintain ("owner" in
  user-facing text means Maintainer). Each level covers the ones below it. Anyone else
  is refused (exit 5) with a message saying which role each action needs.
- **Sync:** runs only when the server has `CID_GITLAB_TOKEN` set (a token with
  `read_api` scope; `CID_GITLAB_URL` for a GitLab other than gitlab.com). The server
  syncs every `CID_SYNC_INTERVAL_SECS` seconds (default 600), and
  `cid admin sync-gitlab` runs it now. Someone removed from the project, or a key
  removed from their GitLab account, loses cid access at the next sync. Access rows
  granted by hand are left alone; SSH keys are not: a synced account ends up with
  exactly the keys GitLab lists for it.
- **Dashboard:** people sign in with GitLab (OAuth); the same account and role apply
  as over SSH. See "Sign-in" in `docs/dashboard.md`.
- **Other hosts:** where there is no GitLab to sync from, an administrator registers
  keys and access by hand: `cid admin add-key <account> <name> "<public key>"` and
  `cid admin grant <dataset> <account> <read|write|maintain>` (the dataset must exist).
  Not built yet: managing keys and members in the dashboard. (Email one-time-link
  sign-in is **not now**: it would add an SMTP dependency.)

### Known gap: creating a dataset

Creating a dataset (`cid init`, which registers it on the server) needs the server's
static token (`CID_SERVER`/`CID_TOKEN`) or a `cid login` with it. Over SSH alone it is
refused (exit 5): the front door grants only what an `access` row allows, and a dataset
that does not exist yet has no access rows. Who may create datasets over SSH is a
decision still to be made.

## CI, scripts and machines

CI jobs today export `CID_SERVER` and `CID_TOKEN` (see "Overrides" above). A machine
that cannot use SSH at all uses `cid login`.

Not built yet: deploy keys, i.e. an SSH key registered for one dataset (read-only or
read-write) in the dashboard, so CI can use SSH like git does. The `accounts` table
allows source `deploy`, but `access` does not, and nothing creates them.

## Rules

- SSH is used only to authenticate and hand out tokens; data never flows over the SSH
  connection.
- The forced command accepts only `cid-auth` with a dataset path and `read`, `write`
  or `maintain`; anything else is refused (exit 5). Each level is granted only to the
  matching GitLab role or above (Reporter, Developer, Maintainer), and each covers the
  ones below it. A Developer asking to tag is refused at the front door, and a write
  token sent to an owner's route (tag, branch, merge, card edit) gets a 403 that says
  only the dataset's owners (Maintainers of its project) can.
- SSH-issued tokens are scoped to one dataset and one access level, expire in
  15 minutes, and are never written to disk by the CLI (the `cid login` credentials
  file is the one exception, for SSH-less machines). The server's static token is not
  scoped (see "Overrides").
- **Hash-existence privacy:** the push protocol's "do you already have this hash?"
  check is answered truthfully only for hashes already referenced by datasets the
  token can read; otherwise the server requests the upload even when the bytes exist,
  and discards the duplicate. This stops push access from becoming an oracle for
  "does this exact file exist in a restricted dataset?".
- **Restricted datasets** follow the same flow. Today "restricted" is a flag on the
  dataset, enforced by checks in the server: previews are blurred until a logged
  reveal, clear downloads are logged, table rows and text are withheld (counts and
  columns only), the git repository gets counts only, and the activity log is for
  owners only.
  Not built yet: Postgres row-level security and a separate database role
  (invariant 11), and a restricted-dataset access group on top of GitLab membership.

## Deployment

`deploy/sshd/` holds the hardened `sshd_config` snippet for the `cid` user
(AuthorizedKeysCommand, forced command, no pty/forwarding) and its install steps.
HTTPS terminates at a reverse proxy (Caddy or nginx): Nilo's built-in TLS is young and
barely audited, and the Zig standard library has no TLS server, so the proxy is the
supported path. The cid server listens on localhost behind it.
Not built yet: a reverse proxy config in `deploy/`.
