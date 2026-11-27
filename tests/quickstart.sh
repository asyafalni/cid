#!/bin/sh
# The quickstart, as deploy/compose/README.md tells it: the compose stack
# up, a dataset created, pushed and released, cloned back identical, its
# release read out of the git repository cid wrote, the dashboard served.
# Needs docker, and `zig build` done for the CLI (or CID=<a cid binary>).
#
#   sh tests/quickstart.sh          # builds the image, then tears all down
#   KEEP=1 sh tests/quickstart.sh   # leaves the stack up
#   NO_BUILD=1 sh tests/quickstart.sh   # uses the cid:local image as it is
#   NO_DEMO=1 sh tests/quickstart.sh    # without the demo (it needs the network)
#
# A project (cid-quickstart) and ports of its own, so it runs beside the
# test services and beside a stack someone is using.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CID="${CID:-$ROOT/zig-out/bin/cid}"
WORK="$(mktemp -d)"
COMPOSE="docker compose -p cid-quickstart -f $ROOT/deploy/compose/docker-compose.yml"
export CID_PORT=17070 CID_S3_PORT=18333
export CID_SERVER="http://127.0.0.1:$CID_PORT" CID_TOKEN='cid-local-token' CID_AUTHOR='user:quickstart'

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

cleanup() {
    [ -n "${KEEP:-}" ] || $COMPOSE down -v >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

if curl -s -o /dev/null "$CID_SERVER/v0/ping" 2>/dev/null; then
    say "quickstart: something already answers on port $CID_PORT. Stop it, then run this again."
    exit 1
fi
[ -x "$CID" ] || { say "quickstart: no cid binary at $CID. Run 'zig build', then run this again."; exit 1; }

build=--build
[ -z "${NO_BUILD:-}" ] || build=--no-build
$COMPOSE up -d $build >"$WORK/up.log" 2>&1 || {
    say "FAIL: the stack did not come up"; tail -30 "$WORK/up.log"; exit 1; }
up=
for _ in $(seq 120); do
    curl -sf "$CID_SERVER/v0/ping" >/dev/null 2>&1 && { up=1; break; }
    sleep 1
done
[ -n "$up" ] || { say "FAIL: the server never answered"; $COMPOSE logs --tail 30 cid; exit 1; }
say "ok: the stack is up"

# The README's session, word for word.
ok  "a git repository for the dataset" $COMPOSE exec -T cid git init -q --bare -b main /git/demo.git
mkdir "$WORK/demo" && cd "$WORK/demo" || exit 1
printf 'id,text\n1,hello\n2,world\n' > calls.csv
mkdir notes && echo "first notes" > notes/march.txt
ok  "init"   "$CID" init cid@127.0.0.1:you/datasets/demo --git /git/demo.git
ok  "add"    "$CID" add .
ok  "commit" "$CID" commit -m "Add the first calls"
ok  "push"   "$CID" push
ok  "tag"    "$CID" tag v1.0.0
printf '3,again\n' >> calls.csv
ok  "commit -a" "$CID" commit -a -m "Add a call"
ok  "push again" "$CID" push
ok  "tag again"  "$CID" tag v1.1.0
has "diff names the row added" "rows: 1 added" "$CID" diff v1.0.0 v1.1.0

cd "$WORK" || exit 1
ok  "clone" "$CID" clone cid@127.0.0.1:you/datasets/demo copy
ok  "the clone is the folder" diff -r -x .cid "$WORK/demo" "$WORK/copy"
has "log names the releases" "v1.1.0" sh -c "cd '$WORK/copy' && '$CID' log"

# Git, written by cid: one commit and tag per release.
git_ok=
for _ in $(seq 30); do
    $COMPOSE exec -T cid git --git-dir /git/demo.git tag 2>/dev/null | grep -q '^v1.1.0$' && { git_ok=1; break; }
    sleep 1
done
[ -n "$git_ok" ] && say "ok: both releases are in the git repository" || { say "FAIL: v1.1.0 never reached the git repository"; fails=$((fails+1)); }
has "git holds the dataset card" "README.md" $COMPOSE exec -T cid git --git-dir /git/demo.git ls-tree --name-only v1.1.0

has "the dashboard is served" "<title>" curl -sf "$CID_SERVER/"
has "the store answers where clients are sent" "HTTP/" sh -c "curl -s -o /dev/null -D - http://127.0.0.1:$CID_S3_PORT | head -1"

# The demo (README.md, step 5), loaded as that page says. It fetches its
# photos from Open Images' bucket: NO_DEMO=1 leaves it out when offline.
if [ -z "${NO_DEMO:-}" ]; then
    overview() { curl -sf -H "Authorization: Bearer $CID_TOKEN" "$CID_SERVER/v0/datasets/$1/-/overview"; }
    ok  "the demo loads" env COMPOSE="$COMPOSE" PATH="$(dirname "$CID"):$PATH" sh "$ROOT/deploy/compose/demo.sh"
    has "demo: fifty photos in the annotated dataset" '"items":50' overview demo/datasets/street-scenes
    has "demo: its second release is the pinned one" '"pinned_release":"v1.1"' overview demo/datasets/street-scenes
    has "demo: the review changed boxes, counted" '"ann_changed":' overview demo/datasets/street-scenes
    has "demo: the file dataset has its releases" '"pinned_release":"v1.1"' overview demo/datasets/city-sounds
    has "demo: the model names what it was trained on" 'street-scenes' overview demo/models/street-detector
    has "demo: loading it twice is refused, in words" "already here" sh "$ROOT/deploy/compose/demo.sh"
fi

if [ "$fails" -eq 0 ]; then say "quickstart: all passed"; else say "quickstart: $fails failed"; exit 1; fi
