#!/bin/sh
# A rehearsal of moving a DVC dataset into cid, at a size you choose, before
# the real one: a DVC repository of SIZE_MB (default 1024) over five tags,
# its remote in MinIO, imported by deploy/import-tags.sh into cid with its
# files on an NFS share (deploy/nas). It reports what a real import needs to
# know beforehand:
#
#   - how long each tag took, and the whole import, in MB/s;
#   - the most local disk the import used at once, for each of DVC's cache,
#     the checked-out files and cid's cache, against the data's own size;
#   - how much the share holds when it is done;
#   - that every release holds exactly what DVC checks out at its tag.
#
# The tags are those of a dataset that grows: a first bulk, then more files,
# some changed and removed, a tag that changed only code, and a large file.
# Sizes are random bytes, so nothing compresses or deduplicates by accident.
#
# Needs: docker (MinIO, the NFS server of tests/nas, the cid:local image of
# deploy/compose), `dvc` with its S3 support (pip install "dvc[s3]"), and a
# cid binary (CID=, default zig-out/bin/cid). Disk: about four times SIZE_MB
# free, all of it given back at the end.
#
#   SIZE_MB=1024 sh tests/bench/import_rehearsal.sh
#   KEEP=1 ...   leaves the stack, MinIO and the folders, and says where
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CID="${CID:-$ROOT/zig-out/bin/cid}"
SIZE_MB="${SIZE_MB:-1024}"
WORK="${WORK:-$(mktemp -d)}"
MINIO=cid-rehearsal-minio NFS=cid-rehearsal-share
MINIO_PORT=19190
export CID_TEST_NFS_PORT=12249 CID_PORT=17470 CID_S3_PORT=18733
export CID_NAS_DIR=/unused CID_NAS_VOLUME_MB=1024 CID_NAS_MIN_FREE=1GiB
export CID_SERVER="http://127.0.0.1:$CID_PORT" CID_TOKEN='cid-local-token' CID_AUTHOR='user:rehearsal'
export XDG_CACHE_HOME="$WORK/cid-cache"
export AWS_ACCESS_KEY_ID=rehearsal-key AWS_SECRET_ACCESS_KEY=rehearsal-secret-key
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$WORK/bin" && ln -sf "$CID" "$WORK/bin/cid" && PATH="$WORK/bin:$PATH" && export PATH

compose() {
    docker compose -p cid-rehearsal -f "$ROOT/deploy/compose/docker-compose.yml" \
        -f "$ROOT/deploy/nas/docker-compose.yml" -f "$ROOT/tests/nas/nfs-volume.yml" "$@"
}
say() { printf '%s\n' "$*"; }
die() { say "rehearsal: $*" >&2; exit 1; }
now() { date +%s.%N; }
secs() { echo "$2 - $1" | bc; }
mb_of() { n=$(du -sm "$1" 2>/dev/null | cut -f1); echo "${n:-0}"; }

cleanup() {
    [ -n "${SAMPLER:-}" ] && kill "$SAMPLER" 2>/dev/null
    if [ -n "${KEEP:-}" ]; then say "kept: $WORK, the stack cid-rehearsal, $MINIO, $NFS"; return; fi
    compose down -v >/dev/null 2>&1
    docker rm -f "$MINIO" "$NFS" >/dev/null 2>&1
    chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"
}
trap cleanup EXIT

command -v dvc >/dev/null 2>&1 || die "dvc is not installed: pip install 'dvc[s3]'"
[ -x "$CID" ] || die "no cid binary at $CID. Run 'zig build', then run this again."
git config --global user.email rehearsal@example.invalid
git config --global user.name rehearsal
git config --global init.defaultBranch main
git config --global advice.detachedHead false

# --- the old world: MinIO, and a DVC repository whose remote it is ----------
docker rm -f "$MINIO" >/dev/null 2>&1
docker run -d --name "$MINIO" -p "127.0.0.1:$MINIO_PORT:9000" -e MINIO_ROOT_USER="$AWS_ACCESS_KEY_ID" \
    -e MINIO_ROOT_PASSWORD="$AWS_SECRET_ACCESS_KEY" "${MINIO_IMAGE:-cgr.dev/chainguard/minio:latest}" server /data --address :9000 >/dev/null ||
    die "MinIO did not start"
for _ in $(seq 30); do curl -s -o /dev/null "http://127.0.0.1:$MINIO_PORT/minio/health/live" && break; sleep 1; done

rand() { head -c "$1" /dev/urandom; }
day=0
commit() {
    day=$((day+1)); d="2026-01-$(printf %02d "$day")T12:00:00Z"
    GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" git commit -qm "$1"
}
# SIZE_MB spread over the tags: 60% first, 25% more files, 15% one large file.
unit=$((SIZE_MB * 1024 * 1024 / 100))
small=200000                        # 200 KB files, as images are
first_n=$((unit * 60 / small))
more_n=$((unit * 25 / small))
large=$((unit * 15))

say "Building the DVC repository: $SIZE_MB MB over five tags"
t0=$(now)
mkdir -p "$WORK/old/data/images" && cd "$WORK/old" || exit 1
git init -q . && dvc init -q && dvc remote add -q -d minio s3://dvc/store &&
    dvc remote modify minio endpointurl "http://127.0.0.1:$MINIO_PORT" || die "dvc init failed"
curl -sf --aws-sigv4 "aws:amz:us-east-1:s3" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
    -X PUT "http://127.0.0.1:$MINIO_PORT/dvc" >/dev/null || die "could not create MinIO's bucket"
i=0; while [ "$i" -lt "$first_n" ]; do rand "$small" > "data/images/$i.jpg"; i=$((i+1)); done
printf 'id,label\n' > labels.csv; i=0; while [ "$i" -lt 1000 ]; do printf '%d,c%d\n' "$i" $((i % 7)) >> labels.csv; i=$((i+1)); done
printf 'print("train")\n' > train.py
dvc add -q data labels.csv && git add -A && commit "First bulk" && git tag v1.0 && dvc push -q || die "v1.0 failed"
i=0; while [ "$i" -lt "$more_n" ]; do rand "$small" > "data/images/more-$i.jpg"; i=$((i+1)); done
i=0; while [ "$i" -lt 20 ]; do rand "$small" > "data/images/$i.jpg"; rm -f "data/images/$((i + 20)).jpg"; i=$((i+1)); done
printf '1000,c0\n' >> labels.csv
dvc add -q data labels.csv && git add -A && commit "More images; some redone, some dropped" && git tag v1.1 && dvc push -q || die "v1.1 failed"
printf 'print("train harder")\n' > train.py && git add -A && commit "Code only" && git tag v1.1-code
mkdir -p data/video && rand "$large" > data/video/long.mp4
dvc add -q data && git add -A && commit "A long recording" && git tag v2.0 && dvc push -q || die "v2.0 failed"
mv data/images/0.jpg data/images/first.jpg
dvc add -q data && git add -A && commit "A rename" && git tag v2.1 && dvc push -q || die "v2.1 failed"
data_mb=$(mb_of "$WORK/old/data")
say "  built in $(secs "$t0" "$(now)") s: the last tag holds $data_mb MB"

# --- the new world: cid with its files on an NFS share ----------------------
docker build -q -t cid-test-nfs "$ROOT/tests/nas" >/dev/null 2>&1 || die "the NFS server image did not build"
docker rm -f "$NFS" >/dev/null 2>&1
docker run -d --name "$NFS" -p "127.0.0.1:$CID_TEST_NFS_PORT:2049" cid-test-nfs >/dev/null || die "the NFS server did not start"
sleep 2
compose up -d --no-build >"$WORK/up.log" 2>&1 || { tail -20 "$WORK/up.log"; die "the cid stack did not come up (build cid:local first)"; }
for _ in $(seq 120); do curl -sf "$CID_SERVER/v0/ping" >/dev/null 2>&1 && break; sleep 1; done
curl -sf "$CID_SERVER/v0/ping" >/dev/null 2>&1 || die "the cid server never answered"
compose exec -T cid git init -q --bare -b main /git/rehearsal.git

# --- the import, as a person runs it, with the disk watched -----------------
git clone -q "$WORK/old" "$WORK/new" && cd "$WORK/new" || exit 1
dvc_cache="$WORK/new/.dvc/cache"
# cid's cache: the import's own, inside .git (deploy/import-tags.sh), or
# the user's when an older script ran.
cid_cache="$WORK/new/.git/cid-import-cache"
peaks="$WORK/peaks"
: > "$peaks"
# The whole clone in one du, so a file hard-linked from DVC's cache into
# the checkout counts once: what the disk really holds.
( while :; do
      printf '%s %s %s\n' "$(mb_of "$dvc_cache")" "$(( $(mb_of "$cid_cache") + $(mb_of "$XDG_CACHE_HOME") ))" \
          "$(mb_of "$WORK/new")" >> "$peaks"
      sleep 2
  done ) &
SAMPLER=$!

cid init "cid@127.0.0.1:rehearsal/datasets/import" --git /git/rehearsal.git >/dev/null || die "cid init failed"
sh "$ROOT/deploy/import-tags.sh" >/dev/null
echo '*.py' >> .cidignore
t0=$(now)
sh "$ROOT/deploy/import-tags.sh" 2>&1 | while IFS= read -r line; do
    case "$line" in "["*) printf '  %s  at %.0f s\n' "$line" "$(secs "$t0" "$(now)")" ;; *fetched*|*stopped*|*failed*) say "  $line" ;; esac
done
took=$(secs "$t0" "$(now)")
kill "$SAMPLER" 2>/dev/null; SAMPLER=
sleep 1

# --- the answers -------------------------------------------------------------
max() { awk -v c="$1" 'BEGIN{m=0} {if ($c+0 > m) m=$c+0} END{print m}' "$peaks"; }
share_mb=$(compose exec -T seaweedfs du -sm /nas 2>/dev/null | cut -f1)
say ""
say "Import of $data_mb MB (the last tag) over five tags: $took s, $(echo "scale=1; $data_mb / $took" | bc) MB/s"
say "Most local disk at once (MB):"
say "  DVC's cache                                $(max 1)"
say "  cid's cache                                $(max 2)"
say "  the whole clone, each file counted once    $(max 3)   ($(echo "scale=1; $(max 3) / $data_mb" | bc) times the data)"
say "On the share when done: $share_mb MB"

bad=0
cd "$WORK/old" || exit 1
for tag in $(git tag --sort=creatordate); do
    git checkout -q "$tag" && git clean -fdq && dvc checkout -q >/dev/null 2>&1
    rm -rf "$WORK/out"
    (cd "$WORK" && XDG_CACHE_HOME="$WORK/verify-cache" cid clone "cid@127.0.0.1:rehearsal/datasets/import" out --release "$tag" >/dev/null 2>&1) ||
        { say "FAIL: release $tag could not be cloned"; bad=$((bad+1)); continue; }
    if diff -rq . "$WORK/out" -x .git -x .dvc -x '*.dvc' -x .gitignore -x .dvcignore -x '*.py' -x .cid -x .cidignore >/dev/null; then
        say "ok: release $tag is exactly DVC's checkout"
    else
        say "FAIL: release $tag differs from DVC's checkout"; bad=$((bad+1))
    fi
done
[ "$bad" -eq 0 ]
