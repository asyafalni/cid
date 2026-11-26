#!/bin/sh
# cid as a program or an AI coding agent meets it (docs/roadmap.md, E3):
# a session driven by `--json` output and exit codes alone, never by the
# words a person reads. Every result must be JSON on stdout, every
# failure `{"error", "exit"}` on stderr with the exit code it names and
# the next command in its message, and nothing may wait on stdin.
# tests/usability.sh checks the words; this checks the data.
# Needs docker-compose.test.yml up, `zig build` done, and python3.
# Run: sh tests/agent.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CID="${CID:-$ROOT/zig-out/bin/cid}"
WORK="$(mktemp -d)"
PORT=$((20000 + $$ % 20000))
export CID_DB='host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test'
export CID_S3_ENDPOINT='http://127.0.0.1:8333'
export CID_S3_ACCESS_KEY='cid-test-key' CID_S3_SECRET_KEY='cid-test-secret'
export CID_TOKEN='agent-token' CID_SERVER="http://127.0.0.1:$PORT"
export CID_TOKEN_SECRET='agent-secret-agent-secret-0123456789'
export CID_AUTHOR='user:agent'
export CID_GIT_WORKDIR="$WORK/git-work" CID_PUBLIC_URL="http://127.0.0.1:$PORT"
export XDG_CACHE_HOME="$WORK/cache"
REPO="$WORK/demo.git"
git init -q --bare "$REPO"
DS="agent/datasets/demo-$(date +%s)-$$"

fails=0
say() { printf '%s\n' "$*"; }

# run <want-exit> <description> <python check of `d`, the parsed stdout,
# or of `e`, the parsed stderr, when a failure is wanted> -- <command…>
# stdin is closed: a command that asks a question fails here.
run() {
    want="$1"; desc="$2"; check="$3"; shift 4
    "$@" >"$WORK/out" 2>"$WORK/err" </dev/null; code=$?
    if [ "$code" -ne "$want" ]; then
        say "FAIL (exit $code, want $want): $desc"; sed 's/^/     /' "$WORK/out" "$WORK/err"; fails=$((fails+1)); return
    fi
    if ! WANT="$want" CHECK="$check" python3 - "$WORK/out" "$WORK/err" >"$WORK/why" 2>&1 <<'PY'
import json, os, sys
out, err = open(sys.argv[1]).read(), open(sys.argv[2]).read()
want = int(os.environ["WANT"])
if want == 0:
    # One document (help's is indented), or JSON lines ending in a
    # summary (diff): `d` is the document, or the last line.
    try:
        d = json.loads(out)
    except ValueError:
        d = [json.loads(l) for l in out.splitlines() if l.strip()][-1]
else:
    assert not out.strip(), "a failure wrote to stdout: " + out
    # Warnings may come first; the error is the last line.
    e = json.loads(err.strip().splitlines()[-1])
    assert e["exit"] == want, "the error names exit %r" % e["exit"]
    assert "un '" in e["error"] or "run the command again" in e["error"].lower(), "no next command in: " + e["error"]
assert eval(os.environ["CHECK"]), "check failed: " + os.environ["CHECK"]
PY
    then
        say "FAIL: $desc"; sed 's/^/     /' "$WORK/why" | tail -3; sed 's/^/     out: /' "$WORK/out" | head -5; sed 's/^/     err: /' "$WORK/err" | head -5
        fails=$((fails+1)); return
    fi
    say "ok: $desc"
}

if curl -sf "$CID_SERVER/v0/ping" >/dev/null 2>&1; then
    say "agent: something already answers on port $PORT. Stop it, then run this again."; exit 1
fi
"$CID" admin serve --port "$PORT" >"$WORK/serve.log" 2>&1 &
SERVE_PID=$!
trap 'kill "$SERVE_PID" 2>/dev/null; wait "$SERVE_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 20); do curl -sf "$CID_SERVER/v0/ping" >/dev/null 2>&1 && break; sleep 0.5; done

# --- what the tool says about itself ----------------------------------------
run 0 "help --json lists the commands" \
    "{'clone','pull','checkout','status','log','diff','add','restore','commit','push'} <= {c['name'] for c in d['commands']} and len(d['exit_codes']) == 6" -- "$CID" help --json
run 1 "an unknown command" "'help' in e['error']" -- "$CID" comit --json
mkdir "$WORK/a" && cd "$WORK/a" || exit 1
run 1 "status outside a dataset" "'init' in e['error']" -- "$CID" status --json

# --- the producer's loop ----------------------------------------------------
printf 'id,text\n1,hello\n2,world\n' > calls.csv
echo "notes" > notes.txt
run 0 "init"   "d['on_server'] is True and d['dataset'] == '$DS'" -- "$CID" init "cid@127.0.0.1:$DS" --git "$REPO" --json
run 0 "add"    "True" -- "$CID" add . --json
run 0 "commit" "len(d['commit']) > 12 and d['changes'] == 2" -- "$CID" commit -m "First" --json
run 0 "push"   "d['pushed_commits'] == 1 and d['uploaded_files'] == 2" -- "$CID" push --json
run 0 "tag"    "True" -- "$CID" tag v1.0.0 --json
run 2 "tag the same name again" "'never move' in e['error']" -- "$CID" tag v1.0.0 --json
run 0 "status, clean" "d['pull_conflicts'] is None" -- "$CID" status --json
run 0 "log names the release" "'v1.0.0' in json.dumps(d)" -- "$CID" log --json

# --- a reader, then two writers on one file ---------------------------------
cd "$WORK" || exit 1
run 0 "clone" "d['folder'] == 'b' and d['release'] == 'v1.0.0' and d['files'] == 2" -- "$CID" clone "cid@127.0.0.1:$DS" b --json
cd "$WORK/b" || exit 1
printf '3,theirs\n' >> calls.csv
run 0 "commit -a in the clone" "d['changes'] == 1" -- "$CID" commit -a -m "Theirs" --json
run 0 "push from the clone"    "d['pushed_commits'] == 1" -- "$CID" push --json
run 0 "a second release, with its notes" "d['notes'] == 'Adds a call.'" -- "$CID" tag v1.1.0 -m "Adds a call." --json

cd "$WORK/a" || exit 1
printf '3,mine\n' >> calls.csv
run 0 "commit the same file elsewhere" "True" -- "$CID" commit -a -m "Mine" --json
run 2 "a stale push is a conflict, and says to pull" "'cid pull' in e['error']" -- "$CID" push --json
run 2 "pull lists the conflict" "e['conflicts'] == [{'path': 'calls.csv', 'choice': 'undecided'}] and 'checkout' in e['error']" -- "$CID" pull --json
run 0 "status shows it pending" "d['pull_conflicts'] is not None and 'calls.csv' in json.dumps(d['pull_conflicts'])" -- "$CID" status --json
run 0 "decide it" "True" -- "$CID" checkout --theirs calls.csv --json
run 0 "finish the pull" "True" -- "$CID" pull --continue --json
run 0 "push now goes" "True" -- "$CID" push --json

# --- a branch that meets main on one file -----------------------------------
run 0 "branch" "d['branch'] == 'draft'" -- "$CID" branch draft --json
run 0 "checkout the branch" "True" -- "$CID" checkout draft --json
echo "draft notes" > notes.txt
run 0 "commit on the branch" "True" -- "$CID" commit -a -m "Draft" --json
run 0 "push the branch" "True" -- "$CID" push --json
run 0 "back to main" "True" -- "$CID" checkout main --json
echo "main notes" > notes.txt
run 0 "commit on main" "True" -- "$CID" commit -a -m "Main" --json
run 0 "push main" "True" -- "$CID" push --json
run 2 "merge lists the conflict" "e['conflicts'] == [{'path': 'notes.txt', 'choice': 'undecided'}] and 'merge --continue' in e['error']" -- "$CID" merge draft --json
run 0 "decide it" "True" -- "$CID" checkout --theirs notes.txt --json
run 0 "finish the merge" "d['merged'] == 'draft'" -- "$CID" merge --continue --json

# --- reading two versions without downloading either ------------------------
run 0 "diff of two releases ends in a summary" "d['summary']['modified'] == 1" -- "$CID" diff v1.0.0 v1.1.0 --json
run 0 "hash-object" "len(d[0]['hash']) == 64" -- "$CID" hash-object calls.csv --json
run 1 "checkout of a release that does not exist" "True" -- "$CID" checkout v9.9.9 --json

if [ "$fails" -eq 0 ]; then say "agent: all passed"; else say "agent: $fails failed"; exit 1; fi
