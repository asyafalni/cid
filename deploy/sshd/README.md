# The cid SSH front door

What this gives you: `cid clone cid@your-host:org/datasets/x` works for
anyone whose SSH key is registered, with no login — exactly like git.
SSH only authenticates; data moves over HTTPS (invariant 22).

## How a request flows

```
cid CLI ── ssh cid@host "cid-auth <dataset> <read|write|maintain>"
   sshd ── AuthorizedKeysCommand → cid-ssh-keys %f
             └─ prints: restrict,command="cid ssh-auth --account=<id>" <key>
   sshd ── runs the forced command through the cid user's shell; the
           client's words arrive in SSH_ORIGINAL_COMMAND
   cid ssh-auth ── checks the access table, logs the decision to
                   auth_events, prints {token, url, expires_in_secs}
cid CLI ── talks HTTPS to <url> with the token (15 minutes, one
           dataset, one level)
```

## Install

1. Create the system user and the environment file:

   ```sh
   useradd --system --shell /bin/sh cid
   install -d -m 750 -o root -g cid /etc/cid
   # /etc/cid/env, mode 640 root:cid:
   #   CID_DB='host=… user=… password=… dbname=…'
   #   CID_TOKEN_SECRET='a long random string, same as the server's'
   #   CID_PUBLIC_URL='https://cid.example'
   ```

   The `cid` user needs a real shell: sshd runs the forced command
   with `/bin/sh -c`, so `nologin` would refuse every request. It
   still gets no interactive use: the per-key `restrict` option and
   the forced command allow nothing but `cid ssh-auth`.

2. Install the binary (with libduckdb beside it) and two wrappers.
   sshd passes the forced command almost no environment, and
   `/bin/sh -c` reads no profile, so `cid ssh-auth` would not see
   CID_DB, CID_TOKEN_SECRET or CID_PUBLIC_URL. A small wrapper at
   `/usr/local/bin/cid` loads them, the same way `cid-ssh-keys`
   does for the key lookup:

   ```sh
   install -d /usr/local/lib/cid
   install -m 755 cid /usr/local/lib/cid/cid
   install -m 644 libduckdb.so /usr/local/lib/cid/
   cat > /usr/local/bin/cid <<'SH'
   #!/bin/sh
   # Load the server settings when this user may read them.
   if [ -r /etc/cid/env ]; then set -a; . /etc/cid/env; set +a; fi
   exec /usr/local/lib/cid/cid "$@"
   SH
   chmod 755 /usr/local/bin/cid
   install -m 755 cid-ssh-keys /usr/local/bin/cid-ssh-keys
   ```

   The forced command names `cid` without a path, so `/usr/local/bin`
   must be on sshd's default PATH (it is on Debian and Ubuntu; "Check
   it" below shows whether it works).

3. Install the sshd snippet and reload:

   ```sh
   install -m 644 sshd_config.d-cid.conf /etc/ssh/sshd_config.d/cid.conf
   sshd -t && systemctl reload sshd
   ```

4. Register keys and access. With GitLab, let the sync do it: run the
   server with `CID_GITLAB_TOKEN` (a token with `read_api` scope;
   `CID_GITLAB_URL` for a GitLab other than gitlab.com) and it syncs
   every 10 minutes, or run `cid admin sync-gitlab` now. Without
   GitLab, register them by hand; the dataset must already exist for
   `grant`:

   ```sh
   export CID_DB='…'
   cid admin add-key gitlab:42 "Ada" "ssh-ed25519 AAAA… ada@laptop"
   cid admin grant org/datasets/x gitlab:42 read
   ```

   With sync on, a key added by hand to a `gitlab:<id>` account is
   removed at the next sync unless GitLab lists it for that user.
   Access granted by hand is kept.

5. Run the server with the same secret. It needs CID_DB,
   CID_S3_ENDPOINT, CID_S3_ACCESS_KEY, CID_S3_SECRET_KEY,
   CID_TOKEN_SECRET and CID_PUBLIC_URL, plus CID_GIT_WORKDIR for the
   git writer; `cid admin` with no arguments lists the storage and
   dashboard settings:

   ```sh
   cid admin serve
   ```

## Check it

```sh
ssh cid@your-host cid-auth org/datasets/x read   # a JSON grant
ssh cid@your-host                                # refused: no shell
ssh cid@your-host ls                             # refused
```
