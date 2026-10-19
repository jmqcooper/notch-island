#!/bin/bash
# Installs the latest NotchIsland release into ~/Applications and opens it:
#   curl -fsSL https://raw.githubusercontent.com/jmqcooper/notch-island/main/install.sh | bash
# Set NOTCH_ISLAND_DIR to install somewhere else.
set -euo pipefail

url="https://github.com/jmqcooper/notch-island/releases/latest/download/NotchIsland.zip"
dest="${NOTCH_ISLAND_DIR:-$HOME/Applications}"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "NotchIsland runs on macOS only." >&2
  exit 1
fi
if (( $(sw_vers -productVersion | cut -d. -f1) < 14 )); then
  echo "NotchIsland needs macOS 14 or later." >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Downloading $url"
curl -fsSL "$url" -o "$tmp/NotchIsland.zip"
ditto -x -k "$tmp/NotchIsland.zip" "$tmp"

pkill -x NotchIsland || true
mkdir -p "$dest"
rm -rf "$dest/NotchIsland.app"
ditto "$tmp/NotchIsland.app" "$dest/NotchIsland.app"
open "$dest/NotchIsland.app"
echo "Installed $dest/NotchIsland.app. Hover the notch to open it; the gear menu has Open at Login."
