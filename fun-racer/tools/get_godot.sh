#!/usr/bin/env bash
# Downloads the pinned Godot editor binary into tools/bin/godot (idempotent).
set -euo pipefail
VERSION="4.7.2-stable"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/tools/bin"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/fun-racer/godot-$VERSION"
if [[ -x "$BIN/godot" ]]; then exit 0; fi
mkdir -p "$BIN"
# Shared cache so every git worktree doesn't re-download the editor.
if [[ -x "$CACHE" ]]; then ln -sf "$CACHE" "$BIN/godot"; exit 0; fi
URL="https://github.com/godotengine/godot/releases/download/${VERSION}/Godot_v${VERSION}_linux.x86_64.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading Godot $VERSION..."
curl -fsSL "$URL" -o "$TMP/godot.zip"
python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$TMP/godot.zip" "$TMP"
mkdir -p "$(dirname "$CACHE")"
mv "$TMP"/Godot_v${VERSION}_linux.x86_64 "$CACHE"
chmod +x "$CACHE"
ln -sf "$CACHE" "$BIN/godot"
"$BIN/godot" --version
