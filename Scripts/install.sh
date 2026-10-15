#!/bin/sh
# Installs the `bleat` command from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/partofinc/bleat-apple/main/Scripts/install.sh | sh
#
# Linux (aarch64, x86_64) and macOS. Installs into ~/.local/bin, or
# $BLEAT_INSTALL_DIR. Pick a release with BLEAT_VERSION=1.0.0.
# BLEAT_DOWNLOAD_BASE replaces the release URL, e.g. file:///tmp/dist to
# test a release before publishing it. POSIX sh on purpose: it is piped into
# whatever `sh` the host has.
set -eu

repo=partofinc/bleat-apple
dir=${BLEAT_INSTALL_DIR:-$HOME/.local/bin}

case $(uname -s) in
    Linux)
        case $(uname -m) in
            aarch64|arm64) asset=bleat-linux-aarch64 ;;
            x86_64|amd64)  asset=bleat-linux-x86_64 ;;
            *) echo "bleat: no build for $(uname -m) Linux (aarch64 and x86_64 only)" >&2; exit 1 ;;
        esac ;;
    Darwin) asset=bleat-macos-universal ;;
    *) echo "bleat: no build for $(uname -s)" >&2; exit 1 ;;
esac

if [ -n "${BLEAT_DOWNLOAD_BASE:-}" ]; then
    base=$BLEAT_DOWNLOAD_BASE
elif [ -n "${BLEAT_VERSION:-}" ]; then
    base=https://github.com/$repo/releases/download/cli-$BLEAT_VERSION
else
    base=https://github.com/$repo/releases/latest/download
fi

fetch() {    # fetch <url> <file>
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then wget -q "$1" -O "$2"
    else echo "bleat: needs curl or wget" >&2; exit 1; fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

echo "Downloading $asset..."
fetch "$base/$asset.tar.gz" "$tmp/$asset.tar.gz"
fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS"

expected=$(awk -v f="$asset.tar.gz" '$2 == f { print $1 }' "$tmp/SHA256SUMS")
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$tmp/$asset.tar.gz" | cut -d' ' -f1)
else
    actual=$(shasum -a 256 "$tmp/$asset.tar.gz" | cut -d' ' -f1)
fi
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    echo "bleat: checksum mismatch for $asset.tar.gz; nothing installed" >&2
    exit 1
fi

tar -xzf "$tmp/$asset.tar.gz" -C "$tmp" bleat
mkdir -p "$dir"
# Into place by rename, so a running `bleat pair` keeps its old binary.
mv "$tmp/bleat" "$dir/bleat.new"
chmod 755 "$dir/bleat.new"
mv "$dir/bleat.new" "$dir/bleat"

echo "Installed bleat $("$dir/bleat" --version) to $dir/bleat"
case ":$PATH:" in
    *":$dir:"*) ;;
    *) echo "Note: $dir is not on your PATH. Add it, for example:"
       echo "  echo 'export PATH=\"$dir:\$PATH\"' >> ~/.profile" ;;
esac
echo "Next: run 'bleat pair' and scan the code with the Bleat app."
