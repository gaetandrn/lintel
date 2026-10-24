#!/usr/bin/env bash
# `open` an app, retrying while LaunchServices still sees the previous instance
# quitting (error -600, right after a kill or a quit).
# Usage: scripts/open-retry.sh <app path> [--args ...]
#        scripts/open-retry.sh -a <app name>
set -euo pipefail
for _ in $(seq 20); do
  open "$@" 2>/dev/null && exit 0
  sleep 0.3
done
open "$@"   # last try, with its error message
