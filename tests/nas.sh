#!/bin/sh
# cid with its files on a network share, as deploy/nas/README.md sets it
# up: the stack of deploy/compose with deploy/nas laid over it, the share a
# real NFS mount (served by a small user-space NFS server of the test's
# own). It checks what that page promises:
#
#   - a push, a release and a clone work, every file hash-checked;
#   - the data files are on the share and the file index is in PostgreSQL;
#   - with the store's local disk lost, the share and PostgreSQL alone
#     bring everything back, and it takes new pushes;
#   - a share that goes away in the middle of a push costs nothing: the
#     push is run again, or carries on by itself, and the data is whole.
#
# Needs docker (which mounts the share itself: no root here), and
# `zig build` done for the CLI (or CID=<a cid binary>).
#
#   sh tests/nas.sh            # builds the images, then tears all down
#   KEEP=1 sh tests/nas.sh     # leaves the stack up
#   NO_BUILD=1 sh tests/nas.sh # uses the cid:local image as it is
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CID="${CID:-$ROOT/zig-out/bin/cid}"
WORK="$(mktemp -d)"
NFS=cid-nas-test-share
export CID_TEST_NFS_PORT=12149
export CID_PORT=17370 CID_S3_PORT=18633
# Small data files, so the test fits a laptop's disk; the share is not asked.
export CID_NAS_DIR=/unused CID_NAS_VOLUME_MB=1024 CID_NAS_MIN_FREE=1GiB
export CID_SERVER="http://127.0.0.1:$CID_PORT" CID_TOKEN='cid-local-token' CID_AUTHOR='user:nas-test'
export XDG_CACHE_HOME="$WORK/cache"
compose() {
    docker compose -p cid-nas-test -f "$ROOT/deploy/compose/docker-compose.yml" \
        -f "$ROOT/deploy/nas/docker-compose.yml" -f "$ROOT/tests/nas/nfs-volume.yml" "$@"
}

fails=0
say() { printf '%s\n' "$*"; }
ok() {
    desc="$1"; shift
    out="$("$@" 2>&1)"; code=$?
    if [ "$code" -ne 0 ]; then
        say "FAIL: $desc"; say "     got: $out"; fails=$((fails+1)); return 1
    fi
    say "ok: $desc"
}
has() {
    desc="$1"; want="$2"; shift 2
    out="$("$@" 2>&1)"
    case "$out" in
        *"$want"*) say "ok: $desc" ;;
        *) say "FAIL: $desc (no '$want')"; say "     got: $out"; fails=$((fails+1)) ;;
    esac
}
# A fresh clone, from an empty cache, compared with the producing folder.
same_clone() {
    rm -rf "$WORK/back" "$WORK/cache-back"
    (cd "$WORK" && XDG_CACHE_HOME="$WORK/cache-back" "$CID" clone "cid@127.0.0.1:nas/datasets/trial" back >/dev/null 2>&1) || return 1
    diff -rq "$WORK/data" "$WORK/back" -x .cid >/dev/null
}
store_up() {
    for _ in $(seq 90); do
        [ "$(docker inspect -f '{{.State.Health.Status}}' "$(compose ps -q seaweedfs)" 2>/dev/null)" = healthy ] && return 0
        sleep 1
    done
    return 1
}

cleanup() {
    if [ -z "${KEEP:-}" ]; then
        compose down -v >/dev/null 2>&1
        docker rm -f "$NFS" >/dev/null 2>&1
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

if curl -s -o /dev/null "$CID_SERVER/v0/ping" 2>/dev/null; then
    say "nas: something already answers on port $CID_PORT. Stop it, then run this again."
    exit 1
fi
[ -x "$CID" ] || { say "nas: no cid binary at $CID. Run 'zig build', then run this again."; exit 1; }

# The share.
docker build -q -t cid-test-nfs "$ROOT/tests/nas" >"$WORK/nfs.log" 2>&1 || {
    say "FAIL: the test's NFS server did not build"; tail -20 "$WORK/nfs.log"; exit 1; }
docker rm -f "$NFS" >/dev/null 2>&1
docker run -d --name "$NFS" -p "127.0.0.1:$CID_TEST_NFS_PORT:2049" cid-test-nfs >/dev/null || {
    say "FAIL: the test's NFS server did not start"; exit 1; }
sleep 2

build=--build
[ -z "${NO_BUILD:-}" ] || build=--no-build
compose up -d $build >"$WORK/up.log" 2>&1 || {
    say "FAIL: the stack did not come up"; tail -30 "$WORK/up.log"; exit 1; }
up=
for _ in $(seq 120); do
    curl -sf "$CID_SERVER/v0/ping" >/dev/null 2>&1 && { up=1; break; }
    sleep 1
done
[ -n "$up" ] || { say "FAIL: the server never answered"; compose logs --tail 30 cid seaweedfs; exit 1; }
say "ok: the stack is up, its files on an NFS share"

# A dataset: many small files, and one that goes up in pieces (over 64 MB).
mkdir -p "$WORK/data/small" && cd "$WORK/data" || exit 1
i=0
while [ "$i" -lt 200 ]; do head -c 20000 /dev/urandom > "small/$i.bin"; i=$((i+1)); done
head -c 80000000 /dev/urandom > large.bin
ok "a git repository for the dataset" compose exec -T cid git init -q --bare -b main /git/trial.git
ok "init"   "$CID" init cid@127.0.0.1:nas/datasets/trial --git /git/trial.git
ok "add"    "$CID" add .
ok "commit" "$CID" commit -m "First files"
ok "push"   "$CID" push
ok "tag"    "$CID" tag v1.0.0
ok "a clone holds exactly what was pushed" same_clone

# Where things are: the bytes on the share, their index in PostgreSQL.
has "the store's folder is the NFS mount" " /nas nfs" compose exec -T seaweedfs cat /proc/mounts
ok  "the data files are on the share" compose exec -T seaweedfs sh -c 'ls /nas/*.dat >/dev/null'
ok  "the file index is in PostgreSQL" compose exec -T timescaledb sh -c \
    'test "$(psql -U cid -d seaweedfs -tAc "SELECT count(*) > 200 FROM filemeta")" = t'
ok  "and not in a file beside the store" compose exec -T seaweedfs sh -c 'test -z "$(ls -A /meta/filerldb2 2>/dev/null)"'

# The store's local disk is lost: the share and PostgreSQL are enough.
compose stop seaweedfs >/dev/null 2>&1
ok "the store's local disk is wiped" docker run --rm -v cid-nas-test_files:/meta alpine:3.22 sh -c 'rm -rf /meta/* /meta/.[!.]*; test -z "$(ls -A /meta)"'
compose start seaweedfs >/dev/null 2>&1
ok "the store comes back" store_up
ok "every file is still there, hash-checked" same_clone
head -c 3000000 /dev/urandom > after.bin
ok "and it takes a new push" sh -c "'$CID' add . && '$CID' commit -m 'After the loss' && '$CID' push && '$CID' tag v1.1.0"
ok "which clones back whole" same_clone

# The share goes away in the middle of a push, and comes back.
head -c 200000000 /dev/urandom > outage.bin
"$CID" add . >/dev/null 2>&1 && "$CID" commit -m "During an outage" >/dev/null 2>&1
"$CID" push >"$WORK/push-outage.log" 2>&1 &
pushing=$!
sleep 1
docker stop -t 0 "$NFS" >/dev/null 2>&1
sleep 10
docker start "$NFS" >/dev/null 2>&1
wait "$pushing"
first=$?
if [ "$first" -ne 0 ]; then
    # It said to run it again, and running it again finishes the job.
    has "a push the outage stopped says to run it again" "cid push" cat "$WORK/push-outage.log"
    # The share is back, but the store may take a while to find its files
    # again: try for two minutes, and when it never does, show why.
    pushed=
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do "$CID" push >"$WORK/push-again.log" 2>&1 && { pushed=1; break; }; sleep 10; done
    ok "and running it again finishes it" test -n "$pushed"
    if [ -z "$pushed" ]; then
        tail -5 "$WORK/push-again.log"
        compose logs --tail 30 seaweedfs cid
    fi
else
    say "ok: the push waited the outage out"
fi
ok "tag after the outage" "$CID" tag v1.2.0
ok "nothing was lost or torn" same_clone

if [ "$fails" -eq 0 ]; then say "nas: all passed"; else say "nas: $fails failed"; fi
[ "$fails" -eq 0 ]
