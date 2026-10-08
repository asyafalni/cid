# cid behind a reverse proxy

`cid admin serve` speaks plain HTTP on `127.0.0.1:7070` and leaves TLS to a proxy in
front of it. People reach two names through that proxy:

| Name | Goes to | Used by |
|---|---|---|
| `cid.example.com` | the cid server (`127.0.0.1:7070`) | the CLI, the dashboard, the SSH front door's hand-outs |
| `s3.cid.example.com` | the file store's S3 port (SeaweedFS, `127.0.0.1:8333`) | the CLI and browsers, for the files themselves |

Files never pass through the cid server: it signs short-lived URLs and clients fetch or
upload the bytes at the store's name directly. That is why the store needs a public
name too, and why the proxy must hand it the request's `Host` header unchanged: the
signature covers it.

Two ready configs, the same settings in each:

- [`Caddyfile`](Caddyfile): Caddy gets and renews the certificates by itself.
- [`nginx.conf`](nginx.conf): for an nginx you already run; certificates are yours to
  provide (the paths assume certbot).

Replace `cid.example.com` and `s3.cid.example.com` with your names.

## The server's settings

```sh
CID_PUBLIC_URL=https://cid.example.com               # in links, the .cid marker, SSH hand-outs
CID_S3_ENDPOINT=http://127.0.0.1:8333                # how the server itself reaches the store
CID_S3_PUBLIC_ENDPOINT=https://s3.cid.example.com    # the name clients are sent to for files
```

The server signs the URLs it hands out for `CID_S3_PUBLIC_ENDPOINT` and does its own
storage work at `CID_S3_ENDPOINT`, straight to the store, so its traffic never goes
round through the proxy. Leave `CID_S3_PUBLIC_ENDPOINT` out when both are the same
name. Set the same `CID_PUBLIC_URL` in
`/etc/cid/env` for the SSH front door (`deploy/sshd/README.md`): it is the address the
CLI is handed after it signs in with its key.

The GitLab sign-in's redirect URI is `https://cid.example.com/auth/gitlab/callback`.

## What the settings are for

- **Request size.** The API takes bodies up to 64 MB (a push's list of commits). File
  uploads go to the store in pieces of up to 64 MB each; the store's side has no limit.
- **Time.** Some requests take a while: a release of a million items about half a
  minute, the first export of a large version some seconds. Caddy sets no time limit;
  the nginx config allows ten minutes.
- **Streaming.** Downloads can be any size, so the store's side streams in both
  directions instead of buffering to the proxy's disk.
- **Only the proxy is public.** `cid admin serve` listens on `127.0.0.1` by default;
  bind SeaweedFS's S3 port there too (or firewall it), so both are reached only
  through the proxy. SSH (port 22, for `cid@cid.example.com`) is separate
  and does not go through the proxy.

`tests/proxy.sh` checks both configs against a real server and a store that checks
every signature: a push with a file large enough to go up in pieces, a clone of it
elsewhere, a release and the dashboard, all through the proxy. (It caught nginx's
`$host`, which drops the port: the store side uses `$http_host`.)
