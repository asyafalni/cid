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

**Renames work as in git.** Access follows the repository the dataset's git URL
names, so when a project moves, an administrator moves its dataset to match:
`cid admin rename <dataset> <new-path> [--git <new-git-url>]`. The old address then
answers "not found", exactly as a moved git remote does, and nothing redirects. The
dataset repository's own files are rewritten to name the new path, by git
(`docs/git-repository.md`). Each
folder points itself at the new one with `cid remote set-url <address> [--git <url>]`,
git's own command; its local commits, staged changes and cache stay.

---

## How a command authenticates

The same pattern Git LFS uses over SSH:

1. The CLI runs the system `ssh` program (so `~/.ssh/config`, agents and hardware keys
   all work): `ssh cid@cidhub.com cid-auth <dataset-path> <read|write|maintain|create>`.
   `read` for clone, pull, checkout, log and diff; `write` for push;
   `maintain` for tag, branch and merge (and editing the dataset card); `create` for
   init (see "Creating a dataset").
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

### Overrides: CI and scripts

Before trying SSH, a command looks for two other ways in, in this order:

1. **`CID_SERVER` and `CID_TOKEN` in the environment.** They win over everything else.
2. **An https address**, `https://<name>:<token>@<host>/<dataset path>`, as git takes
   credentials (`http://` too, for a server on the same machine). The server is the
   scheme and host; the token is the password (the name is not read), or `CID_TOKEN`
   when the address has none. A folder keeps its address **without** the token
   (`.cid/config.zon` is copied and zipped along with the folder), so commands in a
   folder cloned this way read `CID_TOKEN`, and say so when it is missing.

The CLI writes no credentials file: a token lives in the environment or in the
address given to one command.

The token can be a personal token, an SSH-issued one, or the server's static token
(the `CID_TOKEN` that `cid admin serve` was started with). **The static token has full
access to every dataset**: it is the one exception to "tokens are scoped to one
dataset", and it also lists datasets across the server. Keep it for administrators and
trusted automation.

## Who you are and what you may do comes from GitLab

Nothing to manage in cid:

- **Identity:** for each dataset, cid reads the members of the GitLab project its git
  URL names (`datasets.git_url`: `git@gitlab.example:org/x.git` is the project
  `org/x`), and the public SSH keys of each member (the same keys people already use
  for `git clone`). A key maps to one GitLab user (`gitlab:<user id>`). The dataset's
  own path and its repository's path usually match, but nothing requires it.
- **Permission:** the GitLab role on the dataset's project decides cid access.
  Reporter → read. Developer → write. Maintainer and Owner → maintain ("owner" in
  user-facing text means Maintainer). Each level covers the ones below it. Anyone else
  is refused (exit 5) with a message saying which role each action needs.
- **Sync:** runs only when the server has `CID_GITLAB_TOKEN` set (a token with
  `read_api` scope; `CID_GITLAB_URL` for a GitLab other than gitlab.com). The server
  syncs every `CID_SYNC_INTERVAL_SECS` seconds (default 600), and
  `cid admin sync-gitlab` runs it now. Someone removed from the project, or a key
  removed from their GitLab account, loses cid access at the next sync. Access rows
  granted by hand are left alone, and so are keys added on the dashboard; the keys
  that came from GitLab end up exactly the ones GitLab lists.
- **Your own keys:** a signed-in person adds and removes SSH keys on the dashboard's
  SSH keys page (`/keys`; `GET`/`POST /v0/me/keys`, `DELETE /v0/me/keys?fingerprint=`),
  for a machine whose key is not in GitLab. A key works over SSH as soon as it is
  added. One key belongs to one account: a key already registered, by anyone, is
  refused, so nobody can claim someone else's public key; GitLab's sync still wins a
  key it lists. Keys from GitLab are listed there too and removed in GitLab. Accepted
  types: ed25519 and ECDSA (security keys included), and RSA of 2048 bits or more.
- **Dashboard:** people sign in with GitLab (OAuth); the same account and role apply
  as over SSH. See "Sign-in" in `docs/dashboard.md`.
- **Other hosts:** where there is no GitLab to sync from, an administrator registers
  keys and access by hand: `cid admin add-key <account> <name> "<public key>"` and
  `cid admin grant <dataset> <account> <read|write|maintain>` (the dataset must exist).
  Not built yet: managing members in the dashboard. (Email one-time-link sign-in is
  **not now**: it would add an SMTP dependency.)

### Creating a dataset

`cid init <address> --git <url>` over SSH asks the front door for
`cid-auth <dataset> create`. A dataset that does not exist yet has no `access` rows:
the front door hands a GitLab account a 15-minute maintain token for that one name,
and the server decides when the dataset is created, where the git URL is known. On a
server that takes access from GitLab:

- **The repository must be on that GitLab** (exit 1 otherwise: "this server takes
  access from gitlab.example, and … is not a repository there"), so cid and git agree
  from the start. This holds for every way a dataset is made, the server's own token
  and the platform's API included, and for `cid admin rename --git`.
- **The person must hold Maintainer or Owner on that repository's project**, asked of
  GitLab live (directly or through a group, `members/all`), the role that will own the
  dataset anyway. They are recorded as its owner at once rather than at the next sync.

Refused, each with its reason and the next step: the dataset already exists (exit 1);
not a Maintainer of that project, or it does not exist yet (exit 5); not a GitLab
account, or the front door has no GitLab to ask (`CID_GITLAB_TOKEN` unset in
`/etc/cid/env`) (exit 5); GitLab did not answer (exit 4, run `cid init` again in a
moment). An administrator can always create a dataset with the server's static token
(`CID_SERVER`/`CID_TOKEN`); the repository must still be on the server's GitLab.

## Other git hosts (planned)

GitLab is the first host cid takes access from, not the only target: GitHub, Gitea,
SourceForge or a plain git server should all work. The dataset repository already
does (it is plain git, `docs/git-repository.md`). Access is the part git cannot do,
having no members or roles, so it comes from a host's API through an adapter. Decided
2026-10-08; built when a team on another host needs it, GitHub first.

- **One host per server.** A deployment takes access from one host, set by that
  host's own variables (`CID_GITLAB_*` today, `CID_GITHUB_*` later); the server refuses
  to start with more than one set. Several hosts on one server is parked, for a
  possible multi-tenant service (`CLAUDE.md`, explicitly not now).
- **An adapter does four things**, exactly what the GitLab code does now:
  1. a repository's members, each with a level (the sync);
  2. one person's level on a repository, asked live (creating a dataset);
  3. a person's public SSH keys (the sync);
  4. sign-in: an OAuth authorize URL, the token exchange, and who signed in, as
     `<host>:<user id>` with a display name.
  Whatever a host cannot do falls back to the manual tier below.
- **Levels.** cid has three, read, write and maintain ("owner"); each adapter maps
  its host's roles onto them:

  | cid | GitLab | GitHub |
  |---|---|---|
  | read | Reporter | read, triage |
  | write | Developer | write |
  | maintain | Maintainer, Owner | maintain, admin |

- **Which repository:** the one the dataset's git URL names, on every host (a GitHub
  repository is always `owner/name`, so a dataset's own path cannot stand for it).
- **Accounts** stay `<host>:<user id>` (`gitlab:42`, `github:42`).
- **The manual tier is supported, not a fallback:** with no adapter configured, any
  host works. An administrator grants access (`cid admin grant`), people add keys on
  the dashboard's SSH keys page (or `cid admin add-key`), and the dashboard signs in
  with a token. This is how SourceForge, Gitolite or a bare git server are used.
- **When the second adapter is built,** user-facing text moves from GitLab's role
  names to cid's levels, each adapter adding its host's name ("needs maintain access
  (Maintainer on GitLab)").

## CI, scripts and machines

**Personal tokens** are what scripts and CI use. A signed-in person makes one on the
dashboard's Tokens page (`/tokens`; `GET`/`POST /v0/me/tokens`,
`DELETE /v0/me/tokens?id=`), names it after what will use it, and copies it once:
only its BLAKE3 hash is kept (`personal_tokens`). It acts as its maker, with their
access from the `access` table, until it expires (90 days unless chosen, at most 365)
or is revoked. It is sent as `Authorization: Bearer cidp_…`, or as the password of
Basic credentials, which is what `https://name:token@host/…` becomes:

```bash
cid clone https://ci:$CID_PAT@cid.example/your-org/datasets/speech-id
cd speech-id && CID_TOKEN=$CID_PAT cid pull
```

A token cannot make tokens, add SSH keys (a key would outlive the token) or create
datasets: those need the person, signed in, or their SSH key. Up to 50 per person.
Revoked or expired, it is refused with a pointer to the Tokens page.

The server's static token (`CID_SERVER`/`CID_TOKEN`, see "Overrides" above) still
works, for administrators and trusted automation.

Not built yet: deploy keys, i.e. an SSH key registered for one dataset (read-only or
read-write) in the dashboard, so CI can use SSH like git does. The `accounts` table
allows source `deploy`, but `access` does not, and nothing creates them.

## Rules

- SSH is used only to authenticate and hand out tokens; data never flows over the SSH
  connection.
- The forced command accepts only `cid-auth` with a dataset path and `read`, `write`,
  `maintain` or `create`; anything else is refused (exit 5). Each level is granted only to the
  matching GitLab role or above (Reporter, Developer, Maintainer), and each covers the
  ones below it. A Developer asking to tag is refused at the front door, and a write
  token sent to an owner's route (tag, branch, merge, card edit) gets a 403 that says
  only the dataset's owners (Maintainers of its project) can.
- SSH-issued tokens are scoped to one dataset and one access level, expire in
  15 minutes, and are never written to disk by the CLI; nor is a personal token, which
  lives in an address or in `CID_TOKEN`. The server's static token is not
  scoped (see "Overrides").
- **Hash-existence privacy:** the push protocol's "do you already have this hash?"
  check is answered truthfully only for hashes already referenced by datasets the
  token can read; otherwise the server requests the upload even when the bytes exist,
  and discards the duplicate. This stops push access from becoming an oracle for
  "does this exact file exist in a restricted dataset?".
- **Restricted datasets** follow the same flow: only people whose GitLab role lets them
  in reach one at all. "Restricted" is then a flag on the dataset, enforced by the
  server: previews are blurred until a logged reveal, table rows and text are withheld
  (counts and columns only), the git repository gets counts only, the activity log is
  for owners only, and every read of the dataset's content is an activity event naming
  who and which version: clear downloads (`download`, each batch), opening a browse
  view (`browse`, its first page), comparing two versions (`compare`, in the dashboard
  or for `cid diff`), and the item list or export a clone, pull or checkout reads
  (`export`). There is no Postgres row-level security, by decision (invariant 11):
  TimescaleDB refuses it on the compressed revision tables, and on a private
  deployment the database's only other users are its administrators.
  Who may read a restricted dataset at all is its GitLab project's membership, the
  same as any dataset: a project member can clone and browse it, so keep a restricted
  dataset's project to the people who may see its data. cid keeps no second list of
  readers on top of that.

## Deployment

`deploy/sshd/` holds the hardened `sshd_config` snippet for the `cid` user
(AuthorizedKeysCommand, forced command, no pty/forwarding) and its install steps.
HTTPS terminates at a reverse proxy (Caddy or nginx): Nilo's built-in TLS is young and
barely audited, and the Zig standard library has no TLS server, so the proxy is the
supported path. The cid server listens on localhost behind it. `deploy/proxy/` holds a
Caddyfile and an nginx config for it and for the file store, which clients reach
directly through presigned URLs (so it needs a public name, `CID_S3_PUBLIC_ENDPOINT`
when the server reaches it at another, and the proxy must keep the Host header the
URLs were signed for); `tests/proxy.sh` runs both against a
store that checks every signature.
