#!/usr/bin/env bash
# Build Lintel, install it over the installed copy and relaunch it. For contributors.
# Usage: scripts/dev.sh [app arguments...]   e.g. scripts/dev.sh --title-bar-zoom
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/make-cert.sh
app=$(scripts/bundle.sh)

dest="$HOME/Applications/Lintel.app"
[ -d /Applications/Lintel.app ] && dest=/Applications/Lintel.app

pkill -x Lintel 2>/dev/null || true
for _ in $(seq 50); do pgrep -x Lintel >/dev/null || break; sleep 0.1; done
mkdir -p "$(dirname "$dest")"
rm -rf "$dest"
ditto "$app" "$dest"
echo "==> Installed $dest"

if [ $# -gt 0 ]; then
  scripts/open-retry.sh "$dest" --args "$@"
else
  scripts/open-retry.sh "$dest"
fi
