#!/bin/sh
# A release as someone installs it: a built cid packed by
# deploy/package.sh, then installed by install.sh from a folder standing
# in for the release page. The installed command must run from its link,
# finding its DuckDB library; installing again must upgrade in place; an
# archive that does not match its checksum must install nothing.
#
#   zig build -Doptimize=ReleaseFast --prefix out && sh tests/install.sh out
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${1:?usage: sh tests/install.sh <prefix of a built cid>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0
say() { printf '%s\n' "$*"; }
check() { desc="$1"; shift; if "$@" >"$WORK/log" 2>&1; then say "ok: $desc"; else say "FAIL: $desc"; sed 's/^/     /' "$WORK/log"; fails=$((fails+1)); fi; }

archive="$(sh "$ROOT/deploy/package.sh" "$PREFIX" "$WORK/release")" || { say "FAIL: packaging"; exit 1; }
say "ok: packed $(basename "$archive")"
sums() {
    if command -v sha256sum >/dev/null 2>&1; then (cd "$WORK/release" && sha256sum cid-*.tar.gz > SHA256SUMS)
    else (cd "$WORK/release" && shasum -a 256 cid-*.tar.gz > SHA256SUMS); fi
}
sums
install() { CID_DOWNLOAD="file://$WORK/release" CID_HOME="$WORK/home" CID_BIN="$WORK/bin" sh "$ROOT/install.sh"; }

check "install" install
check "the command runs from its link" "$WORK/bin/cid" --version
want="$("$PREFIX/bin/cid" hash-object "$ROOT/tests/fixtures/people.parquet")"
got="$("$WORK/bin/cid" hash-object "$ROOT/tests/fixtures/people.parquet" 2>&1)"
if [ "$got" = "$want" ] && [ -n "$got" ]; then say "ok: it hashes as the build does"; else say "FAIL: hashes differ: $got"; fails=$((fails+1)); fi
check "help --json is JSON" sh -c "'$WORK/bin/cid' help --json | grep -q '\"commands\"'"
check "installing again upgrades in place" install
[ ! -e "$WORK/home.old" ] && [ ! -e "$WORK/home.new" ] && say "ok: nothing left over" || { say "FAIL: leftovers beside the install"; fails=$((fails+1)); }

# A download that is not what the release says: refused, the old one kept.
echo tampered >> "$archive"
if install >"$WORK/log" 2>&1; then say "FAIL: a tampered archive installed"; fails=$((fails+1))
elif grep -q "does not match its checksum" "$WORK/log"; then say "ok: a tampered archive is refused, and says why"
else say "FAIL: refused without saying why"; sed 's/^/     /' "$WORK/log"; fails=$((fails+1)); fi
check "the cid that was there still runs" "$WORK/bin/cid" --version

if [ "$fails" -eq 0 ]; then say "install: all passed"; else say "install: $fails failed"; exit 1; fi
