#!/usr/bin/env bash
# Build .build/Lintel.app and print its path.
# Usage: scripts/bundle.sh [--universal] [--adhoc]
#   --universal  arm64 + x86_64 binary
#   --adhoc      sign ad-hoc even if the "Lintel Local" identity exists
#   VERSION=1.2.3 (or v1.2.3) sets the bundle version
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Lintel Local"
APP=.build/Lintel.app

universal=0 adhoc=0
for arg in "$@"; do
  case $arg in
    --universal) universal=1 ;;
    --adhoc) adhoc=1 ;;
    -h|--help) sed -n '2,6s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "error: unknown option $arg" >&2; exit 1 ;;
  esac
done

# Build output goes to stderr: stdout is only the .app path.
flags=(-c release)
[ "$universal" = 1 ] && flags+=(--arch arm64 --arch x86_64)
swift build "${flags[@]}" >&2
# Universal builds land in .build/apple/Products/Release or .build/out/Products/Release,
# depending on the SwiftPM version.
bin="$(swift build "${flags[@]}" --show-bin-path)/Lintel"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$bin" "$APP/Contents/MacOS/Lintel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
for dir in Resources/*.lproj; do
  [ -d "$dir" ] && cp -R "$dir" "$APP/Contents/Resources/"
done
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# The installer takes the Claude Code hook scripts from the app, so they match its version.
cp scripts/agent-hook.sh scripts/agent-hooks.py "$APP/Contents/Resources/"

if [ -n "${VERSION:-}" ]; then
  version=${VERSION#v}
  plutil -replace CFBundleShortVersionString -string "$version" "$APP/Contents/Info.plist"
  # CFBundleVersion only takes numbers and dots: drop any pre-release suffix.
  plutil -replace CFBundleVersion -string "${version%%-*}" "$APP/Contents/Info.plist"
fi

# Sign with the identity make-cert.sh or install.sh created, by its SHA-1: another
# identity with the same name may come from another program.
identity=- keychain=()
support="$HOME/Library/Application Support/Lintel"
# Unlocked below, and locked again on the way out, even when signing fails.
if [ "$adhoc" = 0 ] && [ -f "$support/signing.password" ]; then
  trap 'security lock-keychain "$support/signing.keychain-db" 2>/dev/null || true' EXIT
fi
if [ "$adhoc" = 0 ] && [ -f "$support/signing" ] && [ -f "$support/signing.password" ] &&
    security unlock-keychain -p "$(cat "$support/signing.password")" "$support/signing.keychain-db" 2>/dev/null &&
    [[ $(security find-identity -p codesigning "$support/signing.keychain-db") == *"$(cat "$support/signing") \"$IDENTITY\""* ]]; then
  identity=$(cat "$support/signing")
  keychain=(--keychain "$support/signing.keychain-db")
elif [ "$adhoc" = 0 ]; then
  echo "warning: no \"$IDENTITY\" identity (scripts/make-cert.sh): signing ad-hoc, Accessibility resets on every build" >&2
fi
# The hardened runtime stops other programs from loading code into Lintel.
codesign --force --options runtime ${keychain[@]+"${keychain[@]}"} --sign "$identity" "$APP" >&2

echo "$PWD/$APP"
