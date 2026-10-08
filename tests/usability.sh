#!/bin/sh
# The usability test (CLAUDE.md, tests that must always exist): a scripted
# session using only the everyday commands, with every error message
# checked for a "next command" hint. Needs docker-compose.test.yml up and
# `zig build` done. Run: sh tests/usability.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CID="$ROOT/zig-out/bin/cid"
WORK="$(mktemp -d)"
# A port of its own per run: a server orphaned by an earlier, killed run
# can never answer for this one.
PORT=$((20000 + $$ % 20000))
export CID_DB='host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test'
export CID_S3_ENDPOINT='http://127.0.0.1:8333'
export CID_S3_ACCESS_KEY='cid-test-key' CID_S3_SECRET_KEY='cid-test-secret'
export CID_TOKEN='usability-token' CID_SERVER="http://127.0.0.1:$PORT"
export CID_TOKEN_SECRET='usability-secret-usability-secret-0123'
export CID_AUTHOR='user:usability'
# The server writes each release to the dataset's git repository: here a
# local bare repository stands in for GitLab.
export CID_GIT_WORKDIR="$WORK/git-work" CID_PUBLIC_URL="http://127.0.0.1:$PORT"
REPO="$WORK/demo.git"
git init -q --bare "$REPO"
git init -q --bare "$WORK/readonly.git" && chmod -R a-w "$WORK/readonly.git"
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

# A failing command must exit with the documented code, and still say
# what to run next.
expect_code() {
    want="$1"; desc="$2"; shift 2
    out="$("$@" 2>&1)"; code=$?
    if [ "$code" -ne "$want" ]; then
        say "FAIL (exit $code, want $want): $desc"; say "     got: $out"; fails=$((fails+1)); return
    fi
    case "$out" in
        *"Run '"*|*"run '"*|*"Run the command again"*) ;;
        *) say "FAIL (no next-command hint): $desc"; say "     got: $out"; fails=$((fails+1)); return ;;
    esac
    say "ok (exit $want, hinted): $desc"
}

expect_ok() {
    desc="$1"; shift
    out="$("$@" 2>&1)"; code=$?
    if [ "$code" -ne 0 ]; then
        say "FAIL: $desc"; say "     got: $out"; fails=$((fails+1)); return
    fi
    say "ok: $desc"
}

if curl -sf "$CID_SERVER/v0/ping" >/dev/null 2>&1; then
    say "usability: something already answers on port $PORT (a server left from an earlier run?). Stop it, then run this again."
    exit 1
fi
"$CID" admin serve --port "$PORT" >"$WORK/serve.log" 2>&1 &
SERVE_PID=$!
# Stops the server as a deployment would, with one SIGTERM, and gives it
# 15 seconds. A server still there by then is a failure, said with what
# it was doing (its threads, the end of its log, the version jobs), and
# then killed: a run never hangs waiting for it.
stop_server() {
    [ -n "$SERVE_PID" ] || return 0
    kill "$SERVE_PID" 2>/dev/null || { SERVE_PID=; return 0; }
    for _ in $(seq 30); do
        kill -0 "$SERVE_PID" 2>/dev/null || { wait "$SERVE_PID" 2>/dev/null; SERVE_PID=; return 0; }
        sleep 0.5
    done
    say "FAIL: the server did not stop within 15 s of SIGTERM. What it was doing:"
    for t in /proc/"$SERVE_PID"/task/*; do printf '     thread %s: %s\n' "$(cat "$t/comm")" "$(cat "$t/wchan")"; done | sort | uniq -c
    say "     version jobs: $(docker compose -f "$ROOT/docker-compose.test.yml" exec -T timescaledb psql -qtA -U cid -d cid_test \
        -c "SELECT string_agg(status || ' ' || n, ', ') FROM (SELECT status, count(*) AS n FROM version_jobs GROUP BY 1) j" 2>/dev/null)"
    tail -20 "$WORK/serve.log" | sed 's/^/     log: /'
    kill -9 "$SERVE_PID" 2>/dev/null; wait "$SERVE_PID" 2>/dev/null; SERVE_PID=
    return 1
}
# Wait for the server to be gone on exit, so a run right after this one
# never meets it on the same port; and for it to answer before starting.
trap 'stop_server; chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -sf "$CID_SERVER/v0/ping" >/dev/null 2>&1 && break
    sleep 0.5
done

cd "$WORK" && mkdir producer && cd producer
echo "hello" > a.txt

# --- errors before a dataset exists -----------------------------------------
expect_hint "status outside a dataset"        "$CID" status
expect_hint "typo command"                    "$CID" comit
expect_hint "branch outside a dataset"         "$CID" branch x
expect_hint "init without --git"              "$CID" init cid@h:org/datasets/u
expect_hint "init with a broken address"      "$CID" init not-an-address --git g@h:x.git

# --- the happy everyday loop -------------------------------------------------
expect_hint "init with a git repository that does not exist" "$CID" init "cid@127.0.0.1:$DS" --git "$WORK/missing.git"
expect_hint "init with a git repository cid cannot push to"  "$CID" init "cid@127.0.0.1:$DS" --git "$WORK/readonly.git"
if [ -e .cid ]; then say "FAIL: a refused init left .cid/ behind"; fails=$((fails+1)); else say "ok: a refused init leaves nothing behind"; fi
expect_ok   "init"    "$CID" init "cid@127.0.0.1:$DS" --git "$REPO"
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
if "$CID" log | grep -q "(release: v1.0.0)"; then say "ok: log names the release at its commit"
else say "FAIL: log does not name release v1.0.0"; fails=$((fails+1)); fi
expect_ok   "remote shows the folder's address" "$CID" remote
if "$CID" remote | grep -q "^address  "; then say "ok: remote prints the address, as git remote -v does"
else say "FAIL: remote does not print the address"; fails=$((fails+1)); fi
expect_code 1 "remote set-url with a git URL in place of the address" "$CID" remote set-url git@example.invalid:x.git
expect_code 1 "remote set-url without an address"                    "$CID" remote set-url
expect_code 1 "remote with an unknown subcommand"                    "$CID" remote add origin x
# A folder whose git URL is not the dataset's: every server command
# warns, with the fix, and still does its job.
right_git=$("$CID" remote | sed -n 's/^git      //p')
expect_ok   "remote set-url --git alone keeps the address" "$CID" remote set-url --git git@example.invalid:elsewhere.git
if "$CID" pull 2>&1 | grep -q "but the server's is .*Run 'cid remote set-url --git "; then say "ok: pull warns that the folder's git URL is not the dataset's"
else say "FAIL: pull does not warn about the folder's git URL"; fails=$((fails+1)); fi
expect_ok   "set the git URL back"                         "$CID" remote set-url --git "$right_git"
if "$CID" pull 2>&1 | grep -q "warning"; then say "FAIL: pull still warns once the git URL matches"; fails=$((fails+1))
else say "ok: no warning once the git URL matches"; fi

echo "two" > b.txt
expect_hint "commit -a leaves new files alone, like git" "$CID" commit -am "second"
expect_ok   "stage the new file" "$CID" add b.txt
echo "hello again" > a.txt
expect_ok   "commit -a" "$CID" commit -am "second"
expect_hint "tag with unpushed commits"       "$CID" tag v1.1.0
expect_ok   "push again" "$CID" push
expect_ok   "tag v1.1.0" "$CID" tag v1.1.0

# --- reading elsewhere -------------------------------------------------------
cd "$WORK"
# The git URL works as an address: its .cid marker names the dataset.
expect_ok   "clone by the git repository's URL" "$CID" clone "$REPO" via-git
if [ "$(cat via-git/b.txt 2>/dev/null)" = "two" ]; then say "ok: the git-URL clone holds the release"
else say "FAIL: the git-URL clone is missing b.txt"; fails=$((fails+1)); fi
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
expect_ok   "stage c.txt"  "$CID" add c.txt
expect_ok   "third commit" "$CID" commit -m "third"
expect_ok   "third push"   "$CID" push
cd "$WORK/reader"
echo "local edit" >> a.txt
# Editing a checked-out file in place never reaches the shared cache.
printf 'hello again\n' > "$WORK/expected.txt"
h=$("$CID" hash-object "$WORK/expected.txt")
c="${XDG_CACHE_HOME:-$HOME/.cache}/cid/items/$(printf %.2s "$h")/$h"
if [ "$("$CID" hash-object "$c")" = "$h" ]; then say "ok: in-place edit leaves the cache intact"
else say "FAIL: in-place edit changed the cached copy"; fails=$((fails+1)); fi
expect_ok   "stage the edit" "$CID" add a.txt
expect_hint "pull over staged changes"        "$CID" pull

# --- SSH keys are the identity ---------------------------------------------
# A stand-in for ssh and the cid host's sshd together: it finds the key
# through cid's AuthorizedKeysCommand, exactly as sshd does, and runs the
# forced command that answers, with the requested command as
# SSH_ORIGINAL_COMMAND. A key cid does not know gets sshd's refusal.
SSHHOME="$WORK/ssh-home"; FAKEBIN="$WORK/fake-bin"
mkdir -p "$SSHHOME/.ssh" "$FAKEBIN"
ssh-keygen -q -t ed25519 -N '' -C reader -f "$SSHHOME/.ssh/id_ed25519"
cat > "$FAKEBIN/ssh" <<FAKE
#!/bin/sh
shift   # the user@host part
fp=\$(ssh-keygen -lf "$SSHHOME/.ssh/id_ed25519.pub" | cut -d' ' -f2)
line=\$("$CID" ssh-keys "--fingerprint=\$fp")
account=\$(printf '%s' "\$line" | sed -n 's/.*--account=\([^"]*\)".*/\1/p')
[ -n "\$account" ] || { echo "cid@127.0.0.1: Permission denied (publickey)." >&2; exit 255; }
SSH_ORIGINAL_COMMAND="\$*" exec "$CID" ssh-auth "--account=\$account"
FAKE
chmod +x "$FAKEBIN/ssh"
# Only a key: no CID_SERVER, no CID_TOKEN, no stored login.
by_key() { env -u CID_SERVER -u CID_TOKEN HOME="$SSHHOME" PATH="$FAKEBIN:$PATH" "$@"; }
cd "$WORK"
expect_code 5 "clone with a key the server does not know" by_key "$CID" clone "cid@127.0.0.1:$DS" by-stranger
if [ -e by-stranger ]; then say "FAIL: a refused clone left its folder"; fails=$((fails+1)); else say "ok: a refused clone leaves no folder"; fi
expect_ok   "register the key (the GitLab sync's job)" "$CID" admin add-key gitlab:9001 "Rina Reporter" "$(cat "$SSHHOME/.ssh/id_ed25519.pub")"
expect_code 5 "clone before being given access"   by_key "$CID" clone "cid@127.0.0.1:$DS" by-stranger
expect_ok   "Reporter access (the GitLab sync's job)" "$CID" admin grant "$DS" gitlab:9001 read
expect_ok   "clone with only an SSH key"         by_key "$CID" clone "cid@127.0.0.1:$DS" by-key
# A personal token in an https address, as git takes credentials. (Made
# here the way the dashboard keeps one: only its hash, for Rina.)
PAT="cidp_usability$(date +%s%N)"
printf '%s' "$PAT" > "$WORK/pat.txt"
docker compose -f "$ROOT/docker-compose.test.yml" exec -T timescaledb psql -qtA -U cid -d cid_test -c \
    "INSERT INTO personal_tokens (token_id, account_id, name, token_hash, prefix, expires_at) VALUES (gen_random_uuid(), 'gitlab:9001', 'usability', decode('$("$CID" hash-object "$WORK/pat.txt")', 'hex'), 'cidp_u', now() + interval '1 day')" >/dev/null
no_env() { env -u CID_SERVER -u CID_TOKEN HOME="$SSHHOME" "$@"; }
HOSTPORT=${CID_SERVER#http://}
expect_ok   "clone with a token in an https address" no_env "$CID" clone "http://rina:$PAT@$HOSTPORT/$DS" by-token
if grep -q "$PAT" by-token/.cid/config.zon; then say "FAIL: the folder kept the token"; fails=$((fails+1)); else say "ok: the folder keeps the address without the token"; fi
cd by-token
expect_code 1 "pull in it with no token"        no_env "$CID" pull
expect_ok   "pull in it with CID_TOKEN"         no_env env CID_TOKEN="$PAT" "$CID" pull
cd "$WORK"
# Creating over SSH needs the front door to ask GitLab for the Maintainer
# role; with no GitLab to ask, it is refused, saying why and what next.
mkdir -p "$WORK/by-key-new" && cd "$WORK/by-key-new"
expect_code 5 "init over SSH with no GitLab to ask" by_key "$CID" init "cid@127.0.0.1:$DS-by-key" --git "$REPO"
if [ -e .cid ]; then say "FAIL: a refused init over SSH left .cid/"; fails=$((fails+1)); else say "ok: a refused init over SSH leaves nothing"; fi
cd "$WORK"
# The forced command is all a key gets: no shell, no other command.
for cmd in "" "bash" "cat /etc/passwd" "cid-auth $DS admin"; do
    out=$(env PATH="$FAKEBIN:$PATH" HOME="$SSHHOME" ssh cid@127.0.0.1 $cmd 2>&1); code=$?
    case "$code:$out" in
        5:*"only answers: cid-auth"*) say "ok: ssh '$cmd' is refused" ;;
        *) say "FAIL: ssh '$cmd' was not refused (exit $code): $out"; fails=$((fails+1)) ;;
    esac
done
cd by-key
echo "a reporter's edit" > reporter.txt
expect_ok   "a Reporter commits locally"         by_key "$CID" add reporter.txt
expect_ok   "and that is local"                  by_key "$CID" commit -m "reporter"
expect_code 5 "a Reporter cannot push"           by_key "$CID" push
expect_ok   "Developer access"                   "$CID" admin grant "$DS" gitlab:9001 write
expect_ok   "catch up with main (replays the commit)" by_key "$CID" pull
expect_ok   "a Developer pushes"                 by_key "$CID" push
expect_code 5 "a Developer cannot make a release" by_key "$CID" tag v9.0.0
expect_code 5 "a Developer cannot branch"        by_key "$CID" branch dev-branch
expect_ok   "Maintainer access"                  "$CID" admin grant "$DS" gitlab:9001 maintain
expect_ok   "a Maintainer makes a release"       by_key "$CID" tag v9.0.0

# --- offline work, and the exit codes ------------------------------------------
cd "$WORK/producer"
OFF="offline $DS"
printf '%s\n' "$OFF" > off.txt
DOWN='http://127.0.0.1:9'
expect_ok   "add with the server unreachable"    env CID_SERVER="$DOWN" "$CID" add off.txt
expect_ok   "commit with the server unreachable" env CID_SERVER="$DOWN" "$CID" commit -m "offline"
expect_code 4 "push with the server unreachable" env CID_SERVER="$DOWN" "$CID" push
expect_ok   "pull what others pushed meanwhile"  "$CID" pull
expect_ok   "push once the server is back"       "$CID" push
expect_code 5 "a token the server refuses"       env CID_TOKEN=wrong "$CID" pull
# Bytes damaged in storage never reach a folder: a fresh cache downloads,
# the hash check fails, exit 3.
printf '%s\n' "$OFF" > "$WORK/off-copy.txt"
h=$("$CID" hash-object "$WORK/off-copy.txt")
a=$(printf %.2s "$h"); b=$(printf %s "$h" | cut -c3-4)
curl -sf --aws-sigv4 'aws:amz:us-east-1:s3' --user "$CID_S3_ACCESS_KEY:$CID_S3_SECRET_KEY" \
    -X PUT --data-binary 'tampered' "$CID_S3_ENDPOINT/cid/items/blake3/$a/$b/$h" >/dev/null \
    || { say "FAIL: could not tamper with storage for the integrity check"; fails=$((fails+1)); }
cd "$WORK"
export XDG_CACHE_HOME="$WORK/fresh-cache"
expect_ok   "clone with an empty cache"          "$CID" clone "cid@127.0.0.1:$DS" damaged
cd damaged
expect_code 3 "checkout of a damaged file"       "$CID" checkout main
if [ -e off.txt ]; then say "FAIL: a damaged file reached the folder"; fails=$((fails+1)); else say "ok: the damaged file stayed out"; fi
unset XDG_CACHE_HOME

# A damaged version file (the manifest the CLI downloads) or release
# manifest is an integrity failure: exit 3, nothing half-written.
s3put() {  # <key> <bytes>
    curl -sf --aws-sigv4 'aws:amz:us-east-1:s3' --user "$CID_S3_ACCESS_KEY:$CID_S3_SECRET_KEY" \
        -X PUT --data-binary "$2" "$CID_S3_ENDPOINT/cid/$1" >/dev/null \
        || { say "FAIL: could not tamper with $1"; fails=$((fails+1)); }
}
api() { curl -sf -H "Authorization: Bearer $CID_TOKEN" "$CID_SERVER/v0/datasets/$DS/-/$1"; }
V1=$(api releases | jq -r '.releases[] | select(.name == "v1.0.0") | .commit')
STATE_URL=$(api "version/$V1" | jq -r '.url')
STATE_KEY=${STATE_URL#*/cid/}; STATE_KEY=${STATE_KEY%%\?*}
DSID=$(printf %s "$STATE_KEY" | cut -d/ -f2)
cd "$WORK"
expect_ok   "verify a release"                   "$CID" admin verify "$DS" v1.0.0
s3put "$STATE_KEY" 'not the version file'
expect_code 3 "clone a release whose version file is damaged" env XDG_CACHE_HOME="$WORK/cache-3" "$CID" clone "cid@127.0.0.1:$DS" damaged-manifest --release v1.0.0
if [ -e damaged-manifest ]; then say "FAIL: a damaged clone left its folder"; fails=$((fails+1)); else say "ok: the damaged clone left nothing"; fi
s3put "manifests/$DSID/$V1.manifest" 'not the manifest'
expect_code 3 "verify a release whose manifest is damaged" "$CID" admin verify "$DS" v1.0.0

# --- two people, one dataset: replays, conflicts, decisions -----------------
# Everything through the commands a person types: a stale push, a pull that
# replays, a same-file conflict decided file by file, a branch merge whose
# conflict is decided the same way. Exit 2 for every conflict, with the
# next command named.
cd "$WORK"
expect_ok   "Alice clones"                       "$CID" clone "cid@127.0.0.1:$DS" alice
expect_ok   "Bob clones"                         "$CID" clone "cid@127.0.0.1:$DS" bob
(cd alice && "$CID" pull >/dev/null) ; (cd bob && "$CID" pull >/dev/null)
cd "$WORK/alice"; echo "alice one" > shared.txt
expect_ok   "Alice adds shared.txt"              "$CID" add shared.txt
expect_ok   "Alice commits"                      "$CID" commit -m "shared, by Alice"
expect_ok   "Alice pushes"                       "$CID" push
cd "$WORK/bob"; echo "only Bob's" > bob.txt
expect_ok   "Bob adds his own file"              "$CID" add bob.txt
expect_ok   "Bob commits"                        "$CID" commit -m "Bob's file"
expect_code 2 "Bob's push is behind Alice's"     "$CID" push
expect_ok   "Bob pulls: his commit replays on top" "$CID" pull
expect_ok   "Bob pushes after the replay"        "$CID" push
# The same file, changed by both.
cd "$WORK/alice"; "$CID" pull >/dev/null; echo "alice two" > shared.txt
expect_ok   "Alice changes shared.txt and pushes" sh -c "'$CID' commit -am 'Alice again' >/dev/null && '$CID' push"
cd "$WORK/bob"; echo "bob two" > shared.txt
expect_ok   "Bob changes shared.txt too"         "$CID" commit -am "Bob's take"
expect_code 2 "Bob's pull lists the conflict"    "$CID" pull
expect_code 1 "the conflict is not merged silently" "$CID" pull --keep-mine
expect_ok   "Bob takes Alice's version"          "$CID" checkout --theirs shared.txt
expect_ok   "the pull finishes"                  "$CID" pull --continue
if [ "$(cat shared.txt)" = "alice two" ]; then say "ok: shared.txt holds the version Bob chose"
else say "FAIL: shared.txt holds '$(cat shared.txt)' after taking theirs"; fails=$((fails+1)); fi
# A branch, and a merge that conflicts with main.
cd "$WORK/alice"; "$CID" pull >/dev/null
expect_ok   "Alice opens a branch"               "$CID" branch rework
expect_ok   "Alice switches to it"               "$CID" checkout rework
echo "from the branch" > shared.txt
expect_ok   "Alice commits and pushes on it"     sh -c "'$CID' commit -am 'rework shared' >/dev/null && '$CID' push"
cd "$WORK/bob"; "$CID" pull >/dev/null; echo "main moved" > shared.txt
expect_ok   "main moves meanwhile"               sh -c "'$CID' commit -am 'main shared' >/dev/null && '$CID' push"
cd "$WORK/alice"
expect_code 2 "the merge lists the conflict"     "$CID" merge rework
expect_code 2 "--continue refuses while undecided" "$CID" merge --continue
expect_ok   "Alice takes the branch's version"   "$CID" checkout --theirs shared.txt
expect_ok   "the merge finishes"                 "$CID" merge --continue
cd "$WORK/bob"
expect_ok   "Bob pulls the merge"                "$CID" pull
if [ "$(cat shared.txt)" = "from the branch" ]; then say "ok: main holds the branch's shared.txt"
else say "FAIL: main holds '$(cat shared.txt)' after the merge"; fails=$((fails+1)); fi

# --- --json: machine output that parses, errors with their exit code ---------
cd "$WORK/bob"
for cmd in "status" "log" "diff" "pull" "push"; do
    if "$CID" $cmd --json 2>/dev/null | tail -1 | jq -e . >/dev/null; then say "ok: '$cmd --json' is JSON"
    else say "FAIL: '$cmd --json' is not JSON: $("$CID" $cmd --json 2>&1 | head -3)"; fails=$((fails+1)); fi
done
if "$CID" status --json | jq -e '.status.branch == "main"' >/dev/null; then say "ok: status --json carries the branch"
else say "FAIL: status --json lacks .status.branch"; fails=$((fails+1)); fi
err=$("$CID" checkout v0.0.0-none --json 2>&1 >/dev/null); code=$?
if [ "$code" -eq 1 ] && printf '%s' "$err" | jq -e '.exit == 1 and (.error | test("cid log"))' >/dev/null; then say "ok: an error under --json is JSON with its exit code and next step"
else say "FAIL: error under --json (exit $code): $err"; fails=$((fails+1)); fi

# --- piped --version is one parseable line ----------------------------------
lines=$("$CID" --version | wc -l)
if [ "$lines" -eq 1 ]; then say "ok: piped --version is one line"; else say "FAIL: piped --version"; fails=$((fails+1)); fi

# --- the server stops when asked ---------------------------------------------
if stop_server; then say "ok: the server stops on SIGTERM"; else fails=$((fails+1)); fi

say ""
if [ "$fails" -eq 0 ]; then
    say "usability: every command behaved and every error said what to run next."
    exit 0
fi
say "usability: $fails failure(s)."
exit 1
