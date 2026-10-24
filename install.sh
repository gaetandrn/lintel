#!/usr/bin/env bash
# Install or update Lintel. Run with --help for the options.
#   curl -fsSL https://github.com/gaetandrn/lintel/releases/latest/download/install.sh | bash
#   ./install.sh [options]   (from a clone)
set -euo pipefail

REPO=gaetandrn/lintel
BUNDLE_ID=io.github.gaetandrn.lintel
IDENTITY="Lintel Local"
BAR_HEIGHT=28   # BarMetrics.height
RECTANGLE=com.knollsoft.Rectangle
SUPPORT="$HOME/Library/Application Support/Lintel"
RESTORE="$SUPPORT/restore"   # settings to put back on uninstall: domain, key, type, value
SIGNING="$SUPPORT/signing"   # SHA-1 of the certificate this installer created
SIGNING_KEYCHAIN="$SUPPORT/signing.keychain-db"   # holds it, outside the user's keychain list
SIGNING_PASSWORD="$SUPPORT/signing.password"

usage() {
  cat <<'EOF'
Install or update Lintel.

  curl -fsSL https://github.com/gaetandrn/lintel/releases/latest/download/install.sh | bash
  curl -fsSL https://github.com/gaetandrn/lintel/releases/latest/download/install.sh | bash -s -- [options]
  ./install.sh [options]          from a clone

On first install, each option is asked when a terminal is available, otherwise its
default applies. An update keeps Lintel's settings and only applies the options passed:
--no-claude-hooks removes the hooks, but the other --no- options only skip a question
of the first install. Change those settings from Lintel's menu, Rectangle's settings
or System Settings.

  -y, --yes                         take the defaults without asking
  --login, --no-login               open Lintel at login (default: yes)
  --rectangle, --no-rectangle       set Rectangle's top gap to the bar height; without
                                    --title-bar-zoom, also hands title bar double-clicks
                                    to Rectangle and sets macOS's double-click action
                                    to None (default: yes when Rectangle is installed)
  --title-bar-zoom, --no-title-bar-zoom
                                    title bar double-clicks fill the space below the
                                    bar; sets macOS's double-click action to None
                                    (default: yes without Rectangle)
  --claude-hooks, --no-claude-hooks show Claude Code session states on tabs, with hooks
                                    in ~/.claude/settings.json (default: yes when
                                    asked, no otherwise)
  --hide-dock[=SECONDS], --no-hide-dock
                                    hide the Dock automatically; SECONDS is how long the
                                    pointer rests on the edge before it shows (default:
                                    no; 0.3 s). macOS asks to let the terminal control
                                    System Events
  --from-source                     build from this clone instead of downloading
  -h, --help

Environment:
  LINTEL_VERSION=vX.Y.Z   install this release instead of the latest
  LINTEL_ZIP=path         install this Lintel.zip
  LINTEL_DRY_RUN=1        print the commands that change the system, without running them
EOF
}

step() { printf '%s==>%s %s\n' "$bold" "$plain" "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

run() {
  if [ "$dry" = 1 ]; then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

quiet() {
  if [ "$dry" = 1 ]; then run "$@"; else "$@" >/dev/null; fi
}

# This user's processes only: another account's Lintel is not this one.
running() { pgrep -xu "$UID" "$1" >/dev/null; }
gone() { ! running "$1"; }
wait_until() {
  [ "$dry" = 1 ] && return 0
  local _
  for _ in $(seq 50); do "$@" && return 0; sleep 0.1; done
  return 0
}

# LaunchServices refuses for a moment while the previous instance quits (error -600).
open_retry() {
  if [ "$dry" = 1 ]; then run open "$@"; return 0; fi
  local _
  for _ in $(seq 20); do open "$@" 2>/dev/null && return 0; sleep 0.3; done
  open "$@"
}

# Rectangle reads its settings at launch. Never fails: Rectangle is not Lintel.
quit_rectangle() {
  quiet osascript -e 'quit app "Rectangle"' 2>/dev/null || run pkill -xu "$UID" Rectangle || true
  wait_until gone Rectangle
}

# decide VAR DEFAULT QUESTION: a flag already set VAR, or ask, or take DEFAULT.
decide() {
  local var=$1 answer=$2 hint=y/N reply
  [ -n "${!var}" ] && return 0
  if [ "$interactive" = 1 ]; then
    [ "$answer" = 1 ] && hint=Y/n
    printf '%s [%s] ' "$3" "$hint" >/dev/tty
    read -r reply </dev/tty || reply=""
    case $reply in [yY]*) answer=1 ;; [nN]*) answer=0 ;; esac
  fi
  printf -v "$var" %s "$answer"
}

# Saves a setting the first time Lintel changes it, so uninstall.sh can put it back.
remember() {
  local domain=$1 key=$2 type value
  if [ -f "$RESTORE" ] && awk -F '\t' -v d="$domain" -v k="$key" \
      '$1 == d && $2 == k { found = 1 } END { exit !found }' "$RESTORE"; then
    return 0
  fi
  if value=$(defaults read "$domain" "$key" 2>/dev/null); then
    type=$(defaults read-type "$domain" "$key")
    type=${type#Type is }
  else
    type=absent value=""
  fi
  if [ "$dry" = 1 ]; then
    printf '[dry-run] save %s %s (%s %s) to %s\n' "$domain" "$key" "$type" "$value" "$RESTORE"
    return 0
  fi
  mkdir -p "$SUPPORT"
  printf '%s\t%s\t%s\t%s\n' "$domain" "$key" "$type" "$value" >>"$RESTORE"
}

identity_hashes() {
  security find-identity -p codesigning "$SIGNING_KEYCHAIN" 2>/dev/null |
    awk -v name="\"$IDENTITY\"" 'index($0, name) { print $2 }' | sort -u
}

# A dry run leaves the keychain as it is, locked.
unlock_keychain() {
  [ "$dry" = 1 ] && return 0
  security unlock-keychain -p "$(cat "$SIGNING_PASSWORD")" "$SIGNING_KEYCHAIN" 2>/dev/null || return 1
  unlocked=1
}

cleanup() {
  if [ "$unlocked" = 1 ]; then security lock-keychain "$SIGNING_KEYCHAIN" 2>/dev/null || true; fi
  if [ -n "$staged" ] && [ "$dry" = 0 ]; then rm -rf "$staged"; fi
  rm -rf "$tmp"
}

# codesign reports "replacing existing signature" even when all is well: its output
# only matters when it fails.
sign() {
  if [ "$dry" = 1 ]; then run codesign --force --options runtime "$@"; return 0; fi
  local out
  out=$(codesign --force --options runtime "$@" 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
}

# The certificate an app is signed with, from its designated requirement.
signed_with() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/.*certificate leaf = H"\([0-9a-fA-F]*\)".*/\1/p' |
    tr '[:lower:]' '[:upper:]'
}

# Sets signer to the certificate to sign with. It lives in Lintel's own keychain: in the
# login keychain, macOS asks for the user's password each time codesign uses it.
# The same certificate on every install keeps the Accessibility permission, even after
# the app went to the Trash; a new one is made only when it is missing (created=1).
# Runs with errexit off (called from an if): each step that matters returns on failure.
ensure_identity() {
  local hash
  if [ -f "$SIGNING" ] && [ -f "$SIGNING_PASSWORD" ] && unlock_keychain; then
    hash=$(cat "$SIGNING")
    if [ -n "$hash" ] && grep -qxF "$hash" <<<"$(identity_hashes)"; then
      signer=$hash
      return 0
    fi
  fi

  local pass keychain_pass
  created=1
  step "Creating a signing certificate for Lintel"
  echo "It stays on this Mac, in a keychain of its own, so updates keep the Accessibility permission."
  if [ "$had_lintel" = 1 ]; then echo "Lintel will need the Accessibility permission again."; fi
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null || return 1
  pass=$(/usr/bin/openssl rand -hex 16) || return 1
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/identity.p12" -passout "pass:$pass" -name "$IDENTITY" || return 1
  rm -f "$tmp/key.pem"
  if [ "$dry" = 1 ]; then
    run security create-keychain -p "<random password>" "$SIGNING_KEYCHAIN"
    run security import "$tmp/identity.p12" -k "$SIGNING_KEYCHAIN" -P "$pass" -T /usr/bin/codesign -x
    signer="$IDENTITY"
    return 0
  fi
  mkdir -p "$SUPPORT" || return 1
  security delete-keychain "$SIGNING_KEYCHAIN" 2>/dev/null || rm -f "$SIGNING_KEYCHAIN"
  # Anything running as the user could read this password, as it could use a key that
  # codesign signs with silently: the price of updates that keep Accessibility.
  keychain_pass=$(/usr/bin/openssl rand -hex 24) || return 1
  (umask 077 && printf '%s\n' "$keychain_pass" >"$SIGNING_PASSWORD") || return 1
  security create-keychain -p "$keychain_pass" "$SIGNING_KEYCHAIN" || return 1
  unlocked=1
  # -x keeps the private key from being exported.
  security import "$tmp/identity.p12" -k "$SIGNING_KEYCHAIN" -P "$pass" -T /usr/bin/codesign -x >/dev/null || return 1
  signer=$(identity_hashes)
  [ -n "$signer" ] && [ "$(printf '%s\n' "$signer" | grep -c .)" = 1 ] || return 1
  printf '%s\n' "$signer" >"$SIGNING" || return 1
}

# /usr/bin/python3 is a stub that pops up the Command Line Tools installer when they are missing.
have_python() {
  local python
  python=$(command -v python3) || return 1
  [ "$python" != /usr/bin/python3 ] || xcode-select -p >/dev/null 2>&1
}

# Everything runs from here, so a partial download or a command reading stdin
# cannot run half the script when piped.
main() {
  login="" rectangle="" zoom="" hooks="" dock="" dock_delay=0.3 from_source=0 yes=0
  local arg
  for arg in "$@"; do
    case $arg in
      -y|--yes) yes=1 ;;
      --login) login=1 ;;
      --no-login) login=0 ;;
      --rectangle) rectangle=1 ;;
      --no-rectangle) rectangle=0 ;;
      --title-bar-zoom) zoom=1 ;;
      --no-title-bar-zoom) zoom=0 ;;
      --claude-hooks) hooks=1 ;;
      --no-claude-hooks) hooks=0 ;;
      --hide-dock) dock=1 ;;
      --hide-dock=*)
        dock=1 dock_delay=${arg#*=}
        [[ $dock_delay =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
          die "--hide-dock takes a number of seconds, as in --hide-dock=0.3."
        ;;
      --no-hide-dock) dock=0 ;;
      --from-source) from_source=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $arg. See --help." ;;
    esac
  done
  [ "$(id -u)" != 0 ] || die "run this without sudo: Lintel installs for your user account."

  dry=0
  case ${LINTEL_DRY_RUN:-0} in 0|"") ;; *) dry=1 ;; esac
  bold="" plain=""
  if [ -t 1 ]; then bold=$'\033[1m' plain=$'\033[0m'; fi
  interactive=0
  if [ "$yes" = 0 ] && (exec </dev/tty) 2>/dev/null; then interactive=1; fi

  # The clone this script runs from; empty when piped.
  local src=""
  if [ -f "${BASH_SOURCE[0]:-}" ]; then
    src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    [ -f "$src/Package.swift" ] && [ -f "$src/scripts/bundle.sh" ] || src=""
  fi
  if [ "$from_source" = 1 ]; then
    [ -n "$src" ] || die "--from-source builds from a clone of the repository:
  git clone https://github.com/$REPO && cd lintel && ./install.sh --from-source"
    [ -z "${LINTEL_ZIP:-}" ] || die "LINTEL_ZIP and --from-source cannot be used together."
  fi

  local os
  os=$(sw_vers -productVersion)
  [ "${os%%.*}" -ge 14 ] || die "Lintel needs macOS 14 or later (this Mac runs $os)."

  # An update stays where Lintel already is.
  local dest="" first_install=1 dir old_version=""
  for dir in /Applications "$HOME/Applications"; do
    if [ -d "$dir/Lintel.app" ]; then dest="$dir/Lintel.app" first_install=0; break; fi
  done
  if [ -z "$dest" ]; then
    dest="$HOME/Applications/Lintel.app"
    if [ -w /Applications ]; then dest=/Applications/Lintel.app; fi
  else
    old_version=$(plutil -extract CFBundleShortVersionString raw -o - "$dest/Contents/Info.plist" 2>/dev/null) ||
      old_version=""
  fi
  # Lintel is or was on this Mac (its app went to the Trash): macOS may still hold an
  # Accessibility permission for it, tied to the certificate it was signed with.
  local had_lintel=0
  if [ "$first_install" = 0 ] || [ -d "$SUPPORT" ] || defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
    had_lintel=1
  fi

  # Flags win; on first install, ask or take the defaults; on update, change nothing.
  local rectangle_app=0 hooks_installed=0 dock_hidden=0
  if [ -d /Applications/Rectangle.app ] || [ -d "$HOME/Applications/Rectangle.app" ]; then rectangle_app=1; fi
  if grep -qsF /Lintel/agent-hook.sh "$HOME/.claude/settings.json"; then hooks_installed=1; fi
  if [ "$(defaults read com.apple.dock autohide 2>/dev/null)" = 1 ]; then dock_hidden=1; fi
  if [ "$first_install" = 1 ]; then
    decide login 1 "Open Lintel at login?"
    if [ "$rectangle_app" = 1 ]; then
      if [ "$zoom" = 1 ]; then
        decide rectangle 1 "Set Rectangle's top gap to $BAR_HEIGHT pt, the bar height?"
      else
        decide rectangle 1 "Set Rectangle's top gap to $BAR_HEIGHT pt, the bar height? (also hands title bar
double-clicks to Rectangle and sets macOS's double-click action to None)"
      fi
    fi
    if [ "${rectangle:-0}" = 0 ]; then
      decide zoom 1 "Make title bar double-clicks fill the space below the bar? (replaces the macOS double-click action)"
    fi
    if [ -d "$HOME/.claude" ] && have_python; then
      decide hooks "$interactive" "Show Claude Code session states on tabs? (adds hooks to ~/.claude/settings.json)"
    fi
    if [ "$dock_hidden" = 0 ]; then
      decide dock 0 "Hide the Dock automatically? (macOS asks to let the terminal control System Events)"
    fi
  fi
  # Keeps the hook script in step with the app.
  if [ "$hooks_installed" = 1 ] && [ -z "$hooks" ]; then hooks=1; fi

  tmp=$(mktemp -d) unlocked=0 staged=""
  trap cleanup EXIT

  local app
  if [ "$from_source" = 1 ]; then
    if ! xcode-select -p >/dev/null 2>&1; then
      run xcode-select --install || true
      die "building needs the Command Line Tools. Finish their installation, then run this again."
    fi
    step "Building"
    app=$("$src/scripts/bundle.sh" --adhoc)   # signed below
  else
    local zip
    if [ -n "${LINTEL_ZIP:-}" ]; then
      zip=$LINTEL_ZIP
      [ -f "$zip" ] || die "LINTEL_ZIP points to $zip, which does not exist."
    else
      local url="https://github.com/$REPO/releases/latest/download/Lintel.zip" hint expected actual
      hint="Check the connection, then run the command again."
      if [ -n "${LINTEL_VERSION:-}" ]; then
        url="https://github.com/$REPO/releases/download/v${LINTEL_VERSION#v}/Lintel.zip"
        hint="Check that Lintel v${LINTEL_VERSION#v} exists, then run the command again."
      fi
      step "Downloading $url"
      zip="$tmp/Lintel.zip"
      curl -fSL --progress-bar -o "$zip" "$url" || die "could not download Lintel. $hint"
      expected=$(curl -fsSL "$url.sha256") || die "could not download the checksum of Lintel. $hint"
      expected=${expected%% *}
      actual=$(shasum -a 256 "$zip")
      actual=${actual%% *}
      [ "$expected" = "$actual" ] ||
        die "the download is damaged (checksum mismatch). Nothing was changed: run the command again."
    fi
    ditto -x -k --noqtn "$zip" "$tmp/unzipped" || die "could not unpack $zip."
    app="$tmp/unzipped/Lintel.app"
    [ -d "$app" ] || die "$zip does not contain Lintel.app."
  fi
  local version
  version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")

  # The same certificate on every install keeps the Accessibility permission across
  # updates. The hardened runtime stops other programs from loading code into Lintel.
  local signer="" created=0 regrant=0
  if ensure_identity; then
    # The permission macOS holds for Lintel belongs to the certificate it was signed with.
    if [ "$created" = 1 ] && [ "$had_lintel" = 1 ]; then regrant=1; fi
    if [ "$first_install" = 0 ] && [ "$(signed_with "$dest")" != "$signer" ]; then regrant=1; fi
    step "Signing Lintel"
    sign --keychain "$SIGNING_KEYCHAIN" --sign "$signer" "$app" || die "could not sign Lintel."
  else
    warn "could not set up the signing certificate, so Lintel is signed ad hoc.
macOS will ask for the Accessibility permission again after each update."
    regrant=1
    step "Signing Lintel"
    sign --sign - "$app" || die "could not sign Lintel."
  fi

  # Copied next to the installed app first: a failure here leaves Lintel as it was.
  [ -d "${dest%/*}" ] || run mkdir -p "${dest%/*}"
  staged="${dest%/*}/.Lintel.app.new"
  run rm -rf "$staged"
  run ditto "$app" "$staged"

  if running Lintel; then
    step "Quitting Lintel"
    run pkill -xu "$UID" Lintel || true
    wait_until gone Lintel
    if [ "$dry" = 0 ] && running Lintel; then
      pkill -9 -xu "$UID" Lintel || true
      wait_until gone Lintel
    fi
  fi

  if [ "$first_install" = 1 ]; then
    step "Installing Lintel $version in ${dest%/*}"
  elif [ "$old_version" = "$version" ]; then
    step "Reinstalling Lintel $version"
  elif [ -n "$old_version" ]; then
    step "Updating Lintel $old_version to $version"
  else
    step "Updating Lintel to $version"
  fi
  run rm -rf "$dest"
  run mv "$staged" "$dest"
  staged=""

  # From here on, the optional steps warn instead of stopping: Lintel is already replaced.
  if [ "${rectangle:-0}" = 1 ]; then
    step "Setting Rectangle's top gap to $BAR_HEIGHT pt"
    remember "$RECTANGLE" screenEdgeGapTop
    remember "$RECTANGLE" screenEdgeGapTopNotch
    run defaults write "$RECTANGLE" screenEdgeGapTop -int "$BAR_HEIGHT"
    # Notched screens use this one instead.
    run defaults write "$RECTANGLE" screenEdgeGapTopNotch -int "$BAR_HEIGHT"
    if [ "${zoom:-0}" = 0 ]; then
      # Rectangle zooms on title bar double-clicks, within the gap, and macOS must not zoom too.
      remember "$RECTANGLE" doubleClickTitleBar
      run defaults write "$RECTANGLE" doubleClickTitleBar -int 3   # WindowAction.maximize + 1
      # The app keeps its own backup when its title bar zoom changed this first.
      if ! defaults read "$BUNDLE_ID" previousTitleBarDoubleClick >/dev/null 2>&1; then
        remember NSGlobalDomain AppleActionOnDoubleClick
      fi
      run defaults write NSGlobalDomain AppleActionOnDoubleClick -string None
    fi
    if running Rectangle; then
      quit_rectangle
      open_retry -a Rectangle || warn "could not relaunch Rectangle. Open it to apply the gap."
    fi
  fi

  local res="$app/Contents/Resources" hooks_added=0
  if [ "${hooks:-0}" = 1 ]; then
    if [ "$hooks_installed" = 1 ]; then
      step "Updating the Claude Code hooks"
    else
      step "Adding the Claude Code hooks to ~/.claude/settings.json"
    fi
    if [ ! -f "$res/agent-hooks.py" ]; then
      warn "this version of Lintel has no Claude Code hooks, so they were skipped."
    elif ! have_python; then
      warn "the Claude Code hooks need python3, so they were skipped.
Run xcode-select --install, then run this command again with --claude-hooks."
    elif run mkdir -p "$SUPPORT" && run install -m 755 "$res/agent-hook.sh" "$SUPPORT/agent-hook.sh" &&
        quiet python3 "$res/agent-hooks.py" add; then
      [ "$hooks_installed" = 1 ] || hooks_added=1
    else
      warn "could not add the Claude Code hooks. ~/.claude/settings.json was left unchanged."
    fi
  elif [ "$hooks" = 0 ] && [ "$hooks_installed" = 1 ]; then
    # Running sessions keep calling agent-hook.sh until they restart: it stays.
    step "Removing the Claude Code hooks from ~/.claude/settings.json"
    if ! { [ -f "$res/agent-hooks.py" ] && have_python && quiet python3 "$res/agent-hooks.py" remove; }; then
      warn "could not remove the Claude Code hooks from ~/.claude/settings.json.
Remove by hand the hooks whose command ends in /Lintel/agent-hook.sh."
    fi
  fi

  if [ "${dock:-0}" = 1 ]; then
    step "Hiding the Dock automatically (delay $dock_delay s)"
    remember com.apple.dock autohide
    remember com.apple.dock autohide-delay
    remember com.apple.dock autohide-time-modifier
    # Through System Events, like System Settings: `defaults write` and `killall Dock`
    # hide the Dock but keep its space reserved. Needs the Automation permission.
    if quiet osascript -e 'tell application "System Events" to set autohide of dock preferences to true' 2>/dev/null; then
      run defaults write com.apple.dock autohide-delay -float "$dock_delay"
      run defaults write com.apple.dock autohide-time-modifier -float 0
      run killall Dock || true
    else
      warn "could not hide the Dock.
Turn on System Settings > Desktop & Dock > Automatically hide and show the Dock."
    fi
  fi

  # The permission granted to the previous certificate no longer applies: clear it, so
  # System Settings does not show Lintel as allowed. Lintel asks for it at launch.
  if [ "$regrant" = 1 ]; then quiet tccutil reset Accessibility "$BUNDLE_ID" || true; fi

  step "Launching Lintel"
  local args=()
  if [ "${login:-0}" = 1 ]; then args+=(--launch-at-login); fi
  if [ "${zoom:-0}" = 1 ]; then args+=(--title-bar-zoom); fi
  if [ ${#args[@]} -gt 0 ]; then
    open_retry "$dest" --args "${args[@]}"
  else
    open_retry "$dest"
  fi
  wait_until running Lintel
  [ "$dry" = 1 ] || running Lintel || die "Lintel did not start. Open $dest to see why."

  echo "Lintel $version is installed."
  # After the Trash, the same certificate keeps the permission granted before.
  if [ "$had_lintel" = 0 ] || [ "$regrant" = 1 ]; then
    echo "Last step: allow Lintel in System Settings > Privacy & Security > Accessibility."
  fi
  if [ "$hooks_added" = 1 ]; then
    echo "Restart running Claude Code sessions to see their states on tabs."
  fi
}

main "$@"
