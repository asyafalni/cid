# cid with its files on a NAS

The stack of [`deploy/compose`](../compose/README.md), with one change: SeaweedFS
keeps the dataset files on a network share (NFS, or anything else the machine has
mounted as a folder) instead of on the machine's own disk. Read that page first; this
one only says what differs.

```sh
CID_NAS_DIR=/mnt/nas/cid docker compose \
  -f deploy/compose/docker-compose.yml -f deploy/nas/docker-compose.yml up --build -d
```

`CID_NAS_DIR` is a folder on the mounted share that cid may fill. Everything else,
the ports, the token, the walkthrough, is as on the other page (add the second `-f`
to every `docker compose` command there).

## What goes where, and why

| What | Where | If it is lost |
|---|---|---|
| The files' bytes (SeaweedFS's data files, `*.dat`, up to 30 GB each) | the share, `CID_NAS_DIR` | the files are gone: back the share up, or let the NAS mirror it |
| The file index (which bytes are which object) | PostgreSQL, a database `seaweedfs` beside cid's own | the bytes cannot be told apart again: back PostgreSQL up, as you must for cid's history anyway |
| Each data file's own index, and the store's notes about itself | this machine's disk (the `files` volume) | nothing: SeaweedFS rebuilds them from the share when it starts |

So two things hold everything: **the share and PostgreSQL**. This machine's disk can
be lost and the stack brought up again on another machine with the same share
mounted and the same database. `tests/nas.sh` does exactly that on a real NFS mount
at every change: it wipes the store's local disk, restarts it, clones every file back
hash-checked, and pushes again.

The file index is in PostgreSQL, not on the share, for a reason. SeaweedFS's default
is an embedded database (LevelDB) in a folder, which needs file locks that network
shares keep poorly, and its author says the index cannot be rebuilt from the data
files. PostgreSQL is already here and already has to be backed up.

## Mounting the share

Mount it on the machine before starting the stack, the way your NAS documents, and
make sure it is mounted again after a reboot (`/etc/fstab`). For NFS:

```
nas.example:/volume1/cid  /mnt/nas  nfs  hard,_netdev  0  0
```

- **`hard`, never `soft`.** With `hard`, a share that goes away makes the store wait
  until it is back. With `soft` a write can come back short, which is how files get
  torn. (`hard` is the default; the point is not to override it.)
- The folder must be writable by the store, which runs as root in its container. A
  NAS that maps root to another user ("root squash") needs the folder owned by that
  user, or the mapping turned off for this machine.
- NFS is what is tested (version 3, by `tests/nas.sh`). SMB has not been tried:
  prefer NFS when the NAS offers both.
- One store per folder. Two SeaweedFS servers must never share one `CID_NAS_DIR`.

## Space

- **Room for another data file, always.** SeaweedFS fills data files of up to 30 GB
  and opens the next when the share has room for it beyond `CID_NAS_MIN_FREE`
  (10 GiB unless you say otherwise). When it has not, writes are refused and
  `cid push` fails with "an upload failed"; SeaweedFS's log says "no free volumes
  left". Free space on the share, then run `cid push` again.
- **A first import needs about twice its size for a while.** Every pushed file is
  first staged, then written into place once its hash is checked, and the staged copy
  deleted. SeaweedFS gives deleted space back when it compacts a data file, in the
  background, some minutes later. Pushing 2 GB left 4.5 GB on the share just after.
  For a 1 TB import, have 2 TB free, or import release by release and let it settle.

## A slow or absent share

A share that stalls for a few seconds under a large import is normal, and one that
goes away for a while happens. Neither loses anything:

- While the share is away the store waits (`hard`). A push in flight waits with it;
  the server asks the store again after 2, 5 and 15 seconds before giving up on a
  file.
- A push that does give up says so and what to run: `cid push` again. Nothing that
  already went up is sent twice, and nothing is recorded until every file's hash has
  been checked.
- SeaweedFS repairs a data file whose last write was cut short when it next starts
  (version 4.49 and later; this stack pins 4.55).

`tests/nas.sh` takes the share away in the middle of a push and checks the data is
whole afterwards.

## How fast

The share's own write speed is the ceiling, and each pushed byte is written to it
twice (staged, then into place) and read from it once (the hash). So expect a push to
move at somewhat under half the speed of a plain copy to the share. Measure yours
before a large import:

```sh
dd if=/dev/zero of=/mnt/nas/cid/speed-test bs=1M count=2000 conv=fsync && rm /mnt/nas/cid/speed-test
```

At 100 MB/s (a NAS on gigabit Ethernet), 1 TB is about three hours to copy, so
plan most of a working day for cid to import it, and run it from a machine on the
same network as the NAS. A push can be stopped and run again at any point.

What was measured here (2026-11-26) is only a floor: the test's share is a small
user-space NFS server on a laptop's disk, which writes at about 70 MB/s and stalls
under load. On it, 2 GB (5,000 small files and four large ones) pushed in 204 to
255 s, with the server waiting out several stalls, and cloned back identical. On the
machine's own disk the same push took 127 s before large files were written into
place as they are read, the change that came with this page; a 1 GB file's landing
went from 34-48 s to 22 s.

## Settings

| Variable | Default | What it is |
|---|---|---|
| `CID_NAS_DIR` | none, required | the folder on the mounted share |
| `CID_NAS_MIN_FREE` | `10GiB` | space SeaweedFS leaves free on the share |
| `CID_NAS_VOLUME_MB` | `30000` | how large one data file may grow, in MB |

The database password and the keys are the local ones of `deploy/compose`; change
them there and in [`filer.toml`](filer.toml) before other machines may reach this one.
