#!/usr/bin/env bash
# Run the unit tests. Uses Xcode's toolchain when installed: with the Command Line Tools
# alone, swift-testing builds often fail ("plugin for module 'TestingMacros' not found").
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift test "$@"
