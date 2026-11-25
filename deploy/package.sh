#!/bin/sh
# Packs a built cid as the archive install.sh takes: the binary with the
# DuckDB library it needs beside it, and the license.
#
#   zig build -Doptimize=ReleaseFast -Dversion=1.2.0 --prefix out
#   sh deploy/package.sh out dist        # writes dist/cid-<os>-<arch>.tar.gz
#
# The archive is named for the machine it was built on, never its
# version: a release's page holds one per platform, and
# releases/latest/download/cid-linux-x86_64.tar.gz is then always the
# newest. Prints the archive's path.
set -eu

PREFIX="${1:?usage: sh deploy/package.sh <prefix> <out-dir>}"
OUT="${2:?usage: sh deploy/package.sh <prefix> <out-dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in Linux) os=linux ;; Darwin) os=macos ;; *) echo "package: cid is not built for $(uname -s)" >&2; exit 1 ;; esac
case "$(uname -m)" in x86_64|amd64) arch=x86_64 ;; arm64|aarch64) arch=arm64 ;; *) echo "package: cid is not built for $(uname -m)" >&2; exit 1 ;; esac

[ -x "$PREFIX/bin/cid" ] || { echo "package: no cid in $PREFIX/bin. Run 'zig build -Doptimize=ReleaseFast --prefix $PREFIX' first." >&2; exit 1; }
ls "$PREFIX"/bin/libduckdb.* >/dev/null 2>&1 || { echo "package: no DuckDB library beside $PREFIX/bin/cid" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/cid/bin" "$OUT"
cp "$PREFIX/bin/cid" "$PREFIX"/bin/libduckdb.* "$STAGE/cid/bin/"
cp "$ROOT/LICENSE" "$STAGE/cid/"
name="cid-$os-$arch.tar.gz"
tar -czf "$OUT/$name" -C "$STAGE" cid
echo "$OUT/$name"
