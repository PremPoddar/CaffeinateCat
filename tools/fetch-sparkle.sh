#!/bin/sh
# Downloads the pinned Sparkle release into build/vendor/ (once), verifies its SHA-256 and prints the folder.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/sparkle.conf"

DIR="$ROOT/build/vendor/Sparkle-$SPARKLE_VERSION"
if [ ! -d "$DIR/Sparkle.framework" ]; then
    mkdir -p "$ROOT/build/vendor"
    TARBALL="$ROOT/build/vendor/Sparkle-$SPARKLE_VERSION.tar.xz"
    curl -fsSL -o "$TARBALL" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    echo "$SPARKLE_SHA256  $TARBALL" | shasum -a 256 -c - >&2
    rm -rf "$DIR"
    mkdir -p "$DIR"
    tar -xf "$TARBALL" -C "$DIR"
fi
echo "$DIR"
