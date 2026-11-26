#!/bin/sh
# deploy/import-tags.sh against the real tools (docs/coming-from.md): a
# DVC repository and a Git LFS repository, each with several tags, are
# imported into cid, and every release is then compared, file by file,
# with what the old tool itself checks out at the tag of that name.
#
# It checks what a first import depends on:
#   - every tag becomes a release holding exactly that tag's data: files
#     added, changed, renamed and dropped, and a tag that changed only code;
#   - a file a later tag no longer tracks is not carried along;
#   - an import that stops (the old remote unreachable) says so, imports
#     nothing wrong, and carries on when it is run again;
#   - running it once more does nothing.
#
# Needs docker-compose.test.yml up and `zig build` done, plus `dvc` and
# `git lfs` for their halves: one that is missing is skipped with a note
# (and fails the run under CI, where both are installed).
# Run: sh tests/import_tags.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CID="${CID:-$ROOT/zig-out/bin/cid}"
IMPORT="$ROOT/deploy/import-tags.sh"
WORK="$(mktemp -d)"
PORT=$((20000 + $$ % 20000))
export CID_DB='host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test'
export CID_S3_ENDPOINT='http://127.0.0.1:8333'
export CID_S3_ACCESS_KEY='cid-test-key' CID_S3_SECRET_KEY='cid-test-secret'
export CID_TOKEN='import-token' CID_SERVER="http://127.0.0.1:$PORT"
export CID_TOKEN_SECRET='import-secret-import-secret-0123456789'
export CID_AUTHOR='user:importer'
export CID_PUBLIC_URL="http://127.0.0.1:$PORT"
export XDG_CACHE_HOME="$WORK/cache"
# git as the test left it, whatever this machine's own settings are.
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email importer@example.invalid
git config --global user.name importer
git config --global init.defaultBranch main
git config --global advice.detachedHead false
# The cid the script calls is the one under test.
mkdir "$WORK/bin" && ln -s "$CID" "$WORK/bin/cid" && PATH="$WORK/bin:$PATH" && export PATH
RUN="$(date +%s)-$$"

fails=0
say() { printf '%s\n' "$*"; }
ok() {
    desc="$1"; shift
    out="$("$@" 2>&1)"; code=$?
    if [ "$code" -ne 0 ]; then
        say "FAIL: $desc"; say "     got: $out" | tail -6; fails=$((fails+1)); return 1
    fi
    say "ok: $desc"
}
has() {
    desc="$1"; want="$2"; shift 2
    out="$("$@" 2>&1)"
    case "$out" in
        *"$want"*) say "ok: $desc" ;;
        *) say "FAIL: $desc (no '$want')"; say "     got: $out" | tail -6; fails=$((fails+1)) ;;
    esac
}
skip() {
    say "skipped: $1"
    [ -z "${CI:-}" ] || { say "FAIL: under CI nothing may be skipped"; fails=$((fails+1)); }
}
rand() { head -c "$1" /dev/urandom; }
# A commit a day after the one before: tags are imported oldest first, by
# date, and commits made in one second have no order.
day=0
commit() {
    day=$((day+1))
    GIT_AUTHOR_DATE="2026-01-$(printf %02d "$day")T12:00:00Z" GIT_COMMITTER_DATE="2026-01-$(printf %02d "$day")T12:00:00Z" git commit -qm "$1"
}

# Every tag of the repository in the current folder: the old tool's own
# checkout (made by `fetch`, the rest of the arguments) against a clone of
# the cid release of that name. $1 is the dataset.
releases_match() {
    ds="$1"; shift
    for tag in $(git tag --sort=creatordate); do
        git checkout -q "$tag" && git clean -fdq && "$@" >/dev/null 2>&1 || { say "the old tool failed at $tag"; return 1; }
        rm -rf "$WORK/out"
        (cd "$WORK" && "$CID" clone "cid@127.0.0.1:$ds" out --release "$tag" >/dev/null 2>&1) || { say "no release '$tag' to clone"; return 1; }
        diff -rq . "$WORK/out" -x .git -x .dvc -x '*.dvc' -x .gitignore -x .dvcignore -x .gitattributes \
            -x '*.py' -x .cid -x .cidignore || { say "release $tag differs from the tag"; return 1; }
    done
}

if curl -sf "$CID_SERVER/v0/ping" >/dev/null 2>&1; then
    say "import: something already answers on port $PORT. Stop it, then run this again."; exit 1
fi
[ -x "$CID" ] || { say "import: no cid binary at $CID. Run 'zig build', then run this again."; exit 1; }
"$CID" admin serve --port "$PORT" >"$WORK/serve.log" 2>&1 &
SERVE_PID=$!
trap 'kill "$SERVE_PID" 2>/dev/null; wait "$SERVE_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 20); do curl -sf "$CID_SERVER/v0/ping" >/dev/null 2>&1 && break; sleep 0.5; done

# --- DVC ---------------------------------------------------------------------
if command -v dvc >/dev/null 2>&1; then
    DS="import/datasets/dvc-$RUN"
    # The old repository: a tracked folder and a separately tracked table,
    # code beside them, its DVC remote a folder.
    mkdir -p "$WORK/dvc-old" && cd "$WORK/dvc-old" || exit 1
    git init -q . && dvc init -q && dvc remote add -q -d old "$WORK/dvc-remote"
    mkdir -p data/images data/audio
    i=0; while [ "$i" -lt 12 ]; do rand 3000 > "data/images/$i.jpg"; i=$((i+1)); done
    rand 50000 > data/audio/a.wav; rand 50000 > data/audio/b.wav
    printf 'id,label\n1,cat\n2,dog\n' > labels.csv
    printf 'print("train")\n' > train.py
    dvc add -q data labels.csv && git add -A && commit "First data" && git tag v1.0 && dvc push -q
    rand 3000 > data/images/12.jpg; rm data/images/3.jpg; printf '3,bird\n' >> labels.csv
    dvc add -q data labels.csv && git add -A && commit "One more image, one fewer, a label" && git tag v1.1 && dvc push -q
    printf 'print("train harder")\n' > train.py
    git add -A && commit "Code only" && git tag v1.1-code
    mv data/audio/a.wav data/audio/first.wav; rand 80000 > data/audio/long.wav
    dvc add -q data && git add -A && commit "A long recording, a rename" && git tag v2.0 && dvc push -q
    git rm -q labels.csv.dvc && rm -f labels.csv && grep -v labels.csv .gitignore > .gitignore.new && mv .gitignore.new .gitignore
    git add -A && commit "Drop the labels" && git tag release/2.1

    # A fresh clone, as the person importing has: no data in it yet.
    git clone -q "$WORK/dvc-old" "$WORK/dvc-new" && cd "$WORK/dvc-new" || exit 1
    git init -q --bare "$WORK/dvc-cid.git"
    ok  "dvc: init" "$CID" init "cid@127.0.0.1:$DS" --git "$WORK/dvc-cid.git"
    has "dvc: the first run writes .cidignore and waits" "then run this again" sh "$IMPORT"
    echo '*.py' >> .cidignore
    has "dvc: nothing was imported yet" "has nothing pushed yet" "$CID" clone "cid@127.0.0.1:$DS" "$WORK/none"

    # The old remote unreachable: the import stops, and imports nothing wrong.
    mv "$WORK/dvc-remote" "$WORK/dvc-remote.away"
    has "dvc: an unreachable remote stops the import, saying what to do" "run this again; it carries on from v1.0" sh "$IMPORT"
    has "dvc: and nothing half-fetched became a release" "has nothing pushed yet" "$CID" clone "cid@127.0.0.1:$DS" "$WORK/none"
    mv "$WORK/dvc-remote.away" "$WORK/dvc-remote"

    ok  "dvc: two tags first" sh "$IMPORT" v1.0 v1.1
    has "dvc: the rest carries on after them" "2 of 5 tags are already releases" sh "$IMPORT"
    has "dvc: once more does nothing" "nothing to do" sh "$IMPORT"
    has "dvc: a tag that changed only code is a release too" "v1.1, v1.1-code" "$CID" log
    has "dvc: a tag cid cannot spell is released under a name it can" "release-2.1" "$CID" log
    has "dvc: a release says which tag it came from" "Imported from git tag v2.0" curl -s -H "Authorization: Bearer $CID_TOKEN" "$CID_SERVER/v0/datasets/$DS/-/overview"

    # Tag by tag, against DVC's own checkout (release/2.1 is checked apart:
    # its name differs).
    cd "$WORK/dvc-old" && git tag -d release/2.1 >/dev/null
    ok "dvc: every release holds exactly its tag's data" releases_match "$DS" dvc checkout -q
    rm -rf "$WORK/out"
    ok "dvc: the dropped table is gone from the last release" sh -c \
        "cd '$WORK' && '$CID' clone 'cid@127.0.0.1:$DS' out --release release-2.1 >/dev/null && test ! -e out/labels.csv && test -e out/data/audio/long.wav"
else
    skip "the DVC half: 'dvc' is not installed (pip install dvc)"
fi

# --- Git LFS -----------------------------------------------------------------
if git lfs version >/dev/null 2>&1; then
    DS="import/datasets/lfs-$RUN"
    git lfs install --skip-repo >/dev/null 2>&1
    git init -q --bare "$WORK/lfs-remote.git"
    mkdir -p "$WORK/lfs-old/scans" && cd "$WORK/lfs-old" || exit 1
    git init -q . && git remote add origin "$WORK/lfs-remote.git" && git lfs track "*.bin" >/dev/null
    rand 30000 > scans/a.bin; rand 30000 > scans/b.bin; echo "notes one" > notes.txt
    git add -A && commit "First scans" && git tag v1
    rand 40000 > scans/c.bin; git rm -q scans/a.bin; echo "notes two" > notes.txt
    git add -A && commit "c in, a out" && git tag v2
    echo 'x = 1' > tool.py && git add -A && commit "Code only" && git tag v2-code
    git push -q origin main --tags >/dev/null 2>&1

    git clone -q "$WORK/lfs-remote.git" "$WORK/lfs-new" >/dev/null 2>&1 && cd "$WORK/lfs-new" || exit 1
    git init -q --bare "$WORK/lfs-cid.git"
    ok  "lfs: init" "$CID" init "cid@127.0.0.1:$DS" --git "$WORK/lfs-cid.git"
    has "lfs: the first run writes .cidignore and waits" "then run this again" sh "$IMPORT"
    echo '*.py' >> .cidignore
    ok  "lfs: every tag imported" sh "$IMPORT"
    has "lfs: once more does nothing" "nothing to do" sh "$IMPORT"
    ok  "lfs: every release holds exactly its tag's data" releases_match "$DS" git lfs pull
else
    skip "the Git LFS half: 'git lfs' is not installed"
fi

if [ "$fails" -eq 0 ]; then say "import: all passed"; else say "import: $fails failed"; fi
[ "$fails" -eq 0 ]
