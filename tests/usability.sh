#!/bin/sh
# The usability test (CLAUDE.md, tests that must always exist): a scripted
# session using only the everyday commands, with every error message
# checked for a "next command" hint. Needs docker-compose.test.yml up and
# `zig build` done. Run: sh tests/usability.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CID="$ROOT/zig-out/bin/cid"
WORK="$(mktemp -d)"
PORT=7878
export CID_DB='host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test'
export CID_S3_ENDPOINT='http://127.0.0.1:8333'
export CID_S3_ACCESS_KEY='cid-test-key' CID_S3_SECRET_KEY='cid-test-secret'
export CID_TOKEN='usability-token' CID_SERVER="http://127.0.0.1:$PORT"
export CID_AUTHOR='user:usability'
# A dataset of its own per run: the server keeps history forever, so a
# fixed name would meet the previous run's pushes and refuse this one's.
DS="usability/datasets/demo-$(date +%s)-$$"

fails=0
say() { printf '%s\n' "$*"; }

# Every failing command must end by telling you what to run next.
expect_hint() {
    desc="$1"; shift
    out="$("$@" 2>&1)"; code=$?
    if [ "$code" -eq 0 ]; then
        say "FAIL (should have failed): $desc"; fails=$((fails+1)); return
    fi
    case "$out" in
        *"Run '"*|*"run '"*|*"Run the command again"*) ;;
        *) say "FAIL (no next-command hint): $desc"; say "     got: $out"; fails=$((fails+1)); return ;;
    esac
    say "ok (hinted): $desc"
}

expect_ok() {
    desc="$1"; shift
    out="$("$@" 2>&1)"; code=$?
    if [ "$code" -ne 0 ]; then
        say "FAIL: $desc"; say "     got: $out"; fails=$((fails+1)); return
    fi
    say "ok: $desc"
}

"$CID" admin serve --port "$PORT" >"$WORK/serve.log" 2>&1 &
SERVE_PID=$!
trap 'kill $SERVE_PID 2>/dev/null; rm -rf "$WORK"' EXIT
sleep 1

cd "$WORK" && mkdir producer && cd producer
echo "hello" > a.txt

# --- errors before a dataset exists -----------------------------------------
expect_hint "status outside a dataset"        "$CID" status
expect_hint "typo command"                    "$CID" comit
expect_hint "not-built command says so"       "$CID" branch x
expect_hint "init without --git"              "$CID" init cid@h:org/datasets/u
expect_hint "init with a broken address"      "$CID" init not-an-address --git g@h:x.git

# --- the happy everyday loop -------------------------------------------------
expect_ok   "init"    "$CID" init "cid@127.0.0.1:$DS" --git g@h:u.git
expect_hint "init twice"                      "$CID" init cid@h:a/b --git g@h:x.git
expect_hint "add with nothing named"          "$CID" add
expect_hint "add with an unmatched path"      "$CID" add nope.txt
expect_ok   "add ."   "$CID" add .
expect_hint "commit without a message"        "$CID" commit
expect_ok   "commit"  "$CID" commit -m "first"
expect_hint "commit with nothing staged"      "$CID" commit -m "again"
expect_ok   "push"    "$CID" push
expect_ok   "tag"     "$CID" tag v1.0.0
expect_hint "tag the same name again"         "$CID" tag v1.0.0
echo "more" >> a.txt
expect_ok   "diff shows the edit"             "$CID" diff
expect_ok   "restore the edit"                "$CID" restore a.txt
expect_ok   "status clean"                    "$CID" status
expect_ok   "log"     "$CID" log

echo "two" > b.txt
expect_ok   "commit -a" "$CID" commit -am "second"
expect_hint "tag with unpushed commits"       "$CID" tag v1.1.0
expect_ok   "push again" "$CID" push
expect_ok   "tag v1.1.0" "$CID" tag v1.1.0

# --- reading elsewhere -------------------------------------------------------
cd "$WORK"
expect_ok   "clone (gets the newest release)" "$CID" clone "cid@127.0.0.1:$DS" reader
expect_hint "clone onto an existing folder"   "$CID" clone "cid@127.0.0.1:$DS" reader
expect_hint "clone a dataset that is not there" "$CID" clone "cid@127.0.0.1:usability/datasets/nope"
expect_hint "--class on a file dataset"       "$CID" clone "cid@127.0.0.1:$DS" sub1 --class person
expect_hint "a subset that matches nothing"   "$CID" clone "cid@127.0.0.1:$DS" sub2 --split train
if [ -e sub2 ]; then say "FAIL: a refused clone left its folder behind"; fails=$((fails+1)); else say "ok: a refused clone leaves no folder"; fi
expect_hint "--split with no name"            "$CID" clone "cid@127.0.0.1:$DS" sub3 --split
cd reader
expect_ok   "checkout an older release"       "$CID" checkout v1.0.0
expect_hint "checkout something unknown"      "$CID" checkout v9.9.9
expect_ok   "pull back to the newest"         "$CID" pull
expect_hint "restore with nothing matching"   "$CID" restore nothing.txt

# A pull that would actually move refuses to run over staged changes.
cd "$WORK/producer"
echo "third" > c.txt
expect_ok   "third commit" "$CID" commit -am "third"
expect_ok   "third push"   "$CID" push
cd "$WORK/reader"
echo "local edit" >> a.txt
# Editing a checked-out file in place never reaches the shared cache.
h=$(printf 'hello\n' | sha256sum | cut -d' ' -f1)
c="${XDG_CACHE_HOME:-$HOME/.cache}/cid/items/$(printf %.2s "$h")/$h"
if [ "$(sha256sum < "$c" | cut -d' ' -f1)" = "$h" ]; then say "ok: in-place edit leaves the cache intact"
else say "FAIL: in-place edit changed the cached copy"; fails=$((fails+1)); fi
expect_ok   "stage the edit" "$CID" add a.txt
expect_hint "pull over staged changes"        "$CID" pull

# --- piped --version is one parseable line ----------------------------------
lines=$("$CID" --version | wc -l)
if [ "$lines" -eq 1 ]; then say "ok: piped --version is one line"; else say "FAIL: piped --version"; fails=$((fails+1)); fi

say ""
if [ "$fails" -eq 0 ]; then
    say "usability: every command behaved and every error said what to run next."
    exit 0
fi
say "usability: $fails failure(s)."
exit 1
