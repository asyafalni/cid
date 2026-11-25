#!/bin/sh
# Installs the cid command for this user, with no root and no build:
#
#   curl -fsSL https://github.com/asyafalni/cid/releases/latest/download/install.sh | sh
#
# It downloads the archive for this machine from the release, checks it
# against the release's SHA256SUMS, unpacks it under ~/.local/share/cid
# and links ~/.local/bin/cid to it. Running it again upgrades.
#
#   CID_VERSION=v1.2.0   a release other than the latest
#   CID_HOME, CID_BIN    where the files and the link go
#   CID_DOWNLOAD         another place holding the archives and SHA256SUMS
#                        (a mirror, or a folder: file:///path)
set -eu

say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    *) die "cid has no build for $(uname -s) yet (Linux and macOS only)." ;;
esac
case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) die "cid has no build for $(uname -m) yet (x86_64 and arm64 only)." ;;
esac

REPO="https://github.com/asyafalni/cid/releases"
if [ -n "${CID_DOWNLOAD:-}" ]; then base="${CID_DOWNLOAD%/}"
elif [ -n "${CID_VERSION:-}" ]; then base="$REPO/download/$CID_VERSION"
else base="$REPO/latest/download"
fi
HOME_DIR="${CID_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/cid}"
BIN_DIR="${CID_BIN:-$HOME/.local/bin}"
name="cid-$os-$arch.tar.gz"

fetch() { # <url> <file>
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then wget -q "$1" -O "$2"
    else die "needs curl or wget to download. Install one, then run this again."
    fi
}
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    else die "needs sha256sum or shasum to check the download. Install one, then run this again."
    fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
say "Downloading $name"
fetch "$base/$name" "$TMP/$name" || die "could not download $base/$name. Check the address and your connection, then run this again."
fetch "$base/SHA256SUMS" "$TMP/SHA256SUMS" || die "could not download $base/SHA256SUMS, so the archive cannot be checked. Run this again."
want="$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' "$TMP/SHA256SUMS")"
[ -n "$want" ] || die "SHA256SUMS does not list $name; nothing was installed."
got="$(sha256 "$TMP/$name")"
[ "$got" = "$want" ] || die "$name does not match its checksum (got $got, want $want); nothing was installed. Run this again."

# Unpacked beside the old one, then swapped in: a failure part-way leaves
# the cid that was there.
mkdir -p "$(dirname "$HOME_DIR")" "$BIN_DIR"
tar -xzf "$TMP/$name" -C "$TMP"
[ -x "$TMP/cid/bin/cid" ] || die "the archive holds no cid; nothing was installed."
rm -rf "$HOME_DIR.new"
mv "$TMP/cid" "$HOME_DIR.new"
rm -rf "$HOME_DIR.old"
[ ! -e "$HOME_DIR" ] || mv "$HOME_DIR" "$HOME_DIR.old"
mv "$HOME_DIR.new" "$HOME_DIR"
rm -rf "$HOME_DIR.old"
ln -sf "$HOME_DIR/bin/cid" "$BIN_DIR/cid"

say "Installed $("$BIN_DIR/cid" --version) in $HOME_DIR"
case ":$PATH:" in
    *":$BIN_DIR:"*) say "Next: cid help" ;;
    *) say "$BIN_DIR is not on your PATH. Add it (export PATH=\"$BIN_DIR:\$PATH\"), then run 'cid help'." ;;
esac
