# The cid SSH front door

What this gives you: `cid clone cid@your-host:org/datasets/x` works for
anyone whose SSH key is registered, with no login — exactly like git.
SSH only authenticates; data moves over HTTPS (invariant 22).

## How a request flows

```
cid CLI ── ssh cid@host "cid-auth <dataset> <read|write>"
   sshd ── AuthorizedKeysCommand → cid-ssh-keys %f
             └─ prints: restrict,command="cid ssh-auth --account=<id>" <key>
   sshd ── runs the forced command; the client's words arrive in
           SSH_ORIGINAL_COMMAND
   cid ssh-auth ── checks the access table, logs to auth_events,
                   prints {token, url, expires_in_secs}
cid CLI ── talks HTTPS to <url> with the token (15 minutes, one
           dataset, one level)
```

## Install

1. Create the system user and the environment file:

   ```sh
   useradd --system --shell /usr/sbin/nologin cid
   install -d -m 750 -o root -g cid /etc/cid
   # /etc/cid/env, mode 640 root:cid — also add CID_TOKEN_SECRET and
   # CID_PUBLIC_URL here for the forced command:
   #   CID_DB='host=… user=… password=… dbname=…'
   #   CID_TOKEN_SECRET='a long random string, same as the server's'
   #   CID_PUBLIC_URL='https://cid.example'
   ```

2. Install the binary and the wrapper, then extend the wrapper's idea to
   the forced command by exporting the same file there (the forced
   command line printed by `cid ssh-keys` runs `cid ssh-auth`, which
   reads CID_DB, CID_TOKEN_SECRET and CID_PUBLIC_URL; set them in the
   `cid` user's PAM environment or wrap the same way):

   ```sh
   install -m 755 cid /usr/local/bin/cid
   install -m 755 cid-ssh-keys /usr/local/bin/cid-ssh-keys
   ```

3. Install the sshd snippet and reload:

   ```sh
   install -m 644 sshd_config.d-cid.conf /etc/ssh/sshd_config.d/cid.conf
   sshd -t && systemctl reload sshd
   ```

4. Register keys and access (until GitLab sync does it for you):

   ```sh
   export CID_DB='…'
   cid admin add-key gitlab:42 "Ada" "ssh-ed25519 AAAA… ada@laptop"
   cid admin grant org/datasets/x gitlab:42 read
   ```

5. Run the server with the same secret: `CID_TOKEN_SECRET=… cid admin serve`.

## Check it

```sh
ssh cid@your-host cid-auth org/datasets/x read   # a JSON grant
ssh cid@your-host                                # refused: no shell
ssh cid@your-host ls                             # refused and logged
```
