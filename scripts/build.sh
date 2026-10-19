#!/bin/bash
# Builds NotchIsland.app.
#   --install   copy it to ~/Applications and (re)launch it
#   --release   universal (Apple silicon + Intel), ad-hoc signed, zipped to build/NotchIsland.zip
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-}"
app="build/NotchIsland.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"

if [[ "$mode" == "--release" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  cp .build/apple/Products/Release/NotchIsland "$app/Contents/MacOS/"
  # Releases are signed ad hoc: anyone can rebuild and compare, and no personal certificate ships.
  identity="-"
else
  swift build -c release
  cp .build/release/NotchIsland "$app/Contents/MacOS/"
  # A stable signing identity keeps the Automation permission across rebuilds.
  identity="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
fi
cp Support/Info.plist "$app/Contents/"
codesign --force --sign "${identity:--}" "$app"
echo "Built $app (signed with ${identity:-ad hoc})"

case "$mode" in
  --install)
    pkill -x NotchIsland || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/NotchIsland.app"
    cp -R "$app" "$HOME/Applications/"
    open "$HOME/Applications/NotchIsland.app"
    echo "Installed and launched ~/Applications/NotchIsland.app"
    ;;
  --release)
    rm -f build/NotchIsland.zip
    ditto -c -k --keepParent "$app" build/NotchIsland.zip
    echo "Zipped build/NotchIsland.zip"
    ;;
esac
