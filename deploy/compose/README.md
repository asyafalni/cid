# cid on your own machine

One command brings up a whole cid: the server with its dashboard, TimescaleDB for the
history and SeaweedFS for the files. It is for trying cid and for developing against
a real server. Everything listens on localhost only.

You need Docker, and the `cid` command itself (below).

## 1. Start it

```sh
docker compose -f deploy/compose/docker-compose.yml up --build -d
```

The first run builds the image from this repository, which takes a few minutes. Then:

- the server and the dashboard are at <http://127.0.0.1:7070>;
- the dashboard's sign-in page takes the server's token, `cid-local-token`.

## 2. Get the `cid` command

Once cid has a release, `install.sh` gets it (the [README](../../README.md),
"Install"). Until then, on Linux, take it out of the image you just built (the binary and the DuckDB library
it needs beside it):

```sh
docker compose -f deploy/compose/docker-compose.yml cp cid:/opt/cid/bin ./cid-bin
export PATH="$PWD/cid-bin:$PATH"
```

On macOS, or to build it yourself, see "Build" in the [README](../../README.md)
(`zig build` leaves it in `zig-out/bin/`).

Tell it where the server is. This is the administrator's way in, which needs no SSH
key and no git host:

```sh
export CID_SERVER=http://127.0.0.1:7070 CID_TOKEN=cid-local-token
```

## 3. Make a dataset

Every dataset is paired with a git repository, where cid writes one small commit per
release. On a real server that is a project on GitLab or GitHub; here an empty
repository inside the server's container stands in for it:

```sh
docker compose -f deploy/compose/docker-compose.yml exec cid git init --bare -b main /git/demo.git
```

Then, in any folder of files:

```sh
mkdir demo && cd demo
printf 'id,text\n1,hello\n2,world\n' > calls.csv

cid init cid@127.0.0.1:you/datasets/demo --git /git/demo.git
cid add .
cid commit -m "Add the first calls"
cid push
cid tag v1.0.0
```

Change something and release again:

```sh
printf '3,again\n' >> calls.csv
cid commit -a -m "Add a call"
cid push
cid tag v1.1.0
cid diff v1.0.0 v1.1.0        # calls.csv, rows: 1 added, 0 removed
```

## 4. Look at what you have

- **The dashboard:** <http://127.0.0.1:7070>. Browse the release, open the table, and
  compare `v1.0.0` with `v1.1.0`.
- **A clone**, from anywhere on this machine:

  ```sh
  cid clone cid@127.0.0.1:you/datasets/demo copy
  ```

- **Git, written by cid:** each release is one commit and one tag, holding the dataset
  card, the release notes and the statistics, never the data.

  ```sh
  docker compose -f deploy/compose/docker-compose.yml exec cid \
    git --git-dir /git/demo.git log --stat
  ```

## 5. Fill it with the demo

To see every page of the dashboard with something on it, load the demo into a fresh
stack (it needs the network, for the photos):

```sh
sh deploy/compose/demo.sh
```

It makes three datasets, the way their real counterparts are made:

- `demo/datasets/street-scenes`, annotated: fifty street photos with the boxes their
  annotators drew, written as the annotation platform writes them. v1.0 holds a
  detector's mistakes in seven photos (boxes 40 pixels off, cars called trucks, two
  signs that are not there); v1.1 is the review that fixes them, ten more photos, and
  one photo moved to another split. Open Releases to compare the two.
- `demo/datasets/city-sounds`, files: recordings, two clips, a PDF and tables, pushed
  with `cid add`, `commit`, `push`. Between its releases a CSV gains a row and has a
  cell changed; Compare shows both.
- `demo/models/street-detector`, a model, released with
  `--trained-on demo/datasets/street-scenes@v1.1`: each page links to the other.

The photos are from Open Images, CC BY 2.0, fetched from its bucket and checked
against the hashes in [`demo/street-scenes.tsv`](demo/street-scenes.tsv);
[`demo/CREDITS.md`](demo/CREDITS.md) names each author. The README's screenshots are
this demo (`node web/e2e/readme-shots.mjs` retakes them).

## Stopping, and starting over

```sh
docker compose -f deploy/compose/docker-compose.yml down       # stop; the data stays
docker compose -f deploy/compose/docker-compose.yml down -v    # stop and delete everything
```

## When something does not work

- **Port 7070 or 8333 is taken.** Start it on others, and use the same ones in
  `CID_SERVER`: `CID_PORT=7171 CID_S3_PORT=8444 docker compose … up -d`.
- **The build stops with `ResolvConfParseFailed`.** Zig could not read the name
  servers Docker gave the build. Build with the host's network, then start as before:
  `docker build --network host -t cid:local .` and `docker compose … up -d`.
- **Anything else:** `docker compose -f deploy/compose/docker-compose.yml logs cid`.

## From here to a real server

This stack keeps its keys in the compose file and speaks plain HTTP, which is right
for one machine and wrong for anything else. A server other people reach needs:

1. Keys and a token of its own: every `cid-local-…` value in `docker-compose.yml` and
   `seaweedfs-s3.json`.
2. TLS, at a reverse proxy in front of the server and the store:
   [`deploy/proxy/`](../proxy/README.md).
3. People signing in as themselves: the SSH front door
   ([`deploy/sshd/`](../sshd/README.md)) and your git host's roles and sign-in
   ([`docs/access.md`](../../docs/access.md)). The static token then stays with the
   administrators.
4. Real git repositories: the server needs to push to your git host
   ([`docs/git-repository.md`](../../docs/git-repository.md)).
