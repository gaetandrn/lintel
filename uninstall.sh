#!/usr/bin/env bash
# Uninstall Lintel and put back the settings it changed. Run with --help for the options.
#   curl -fsSL https://github.com/gaetandrn/lintel/releases/latest/download/uninstall.sh | bash
set -euo pipefail

REPO=gaetandrn/lintel
BUNDLE_ID=io.github.gaetandrn.lintel
RECTANGLE=com.knollsoft.Rectangle
SUPPORT="$HOME/Library/Application Support/Lintel"
RESTORE="$SUPPORT/restore"   # written by install.sh: domain, key, type, value
MARKER=/Lintel/agent-hook.sh
SETTINGS="$HOME/.claude/settings.json"

usage() {
  cat <<'EOF'
Uninstall Lintel: its login item, the app, its permissions, its Claude Code hooks, its
data and settings, and its signing certificate. Puts back the Rectangle, Dock and title
bar double-click settings that the installer or Lintel changed.

  curl -fsSL https://github.com/gaetandrn/lintel/releases/latest/download/uninstall.sh | bash
  ./uninstall.sh                  from a clone

  -h, --help

Environment:
  LINTEL_DRY_RUN=1   print the commands that change the system instead of running them
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

have_python() {
  local python
  python=$(command -v python3) || return 1
  # /usr/bin/python3 is a stub that pops up the Command Line Tools installer when they are missing.
  [ "$python" != /usr/bin/python3 ] || xcode-select -p >/dev/null 2>&1
}

unregister_login_item() {
  local bin="$1/Contents/MacOS/Lintel" pid _
  [ -x "$bin" ] || return 0
  step "Removing the login item"
  if [ "$dry" = 1 ]; then run "$bin" --unregister-login-item; return 0; fi
  "$bin" --unregister-login-item >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  # A build without this flag starts normally: stop it.
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# restore DOMAIN KEY TYPE VALUE, as saved by install.sh (TYPE "absent": the key did not exist).
restore() {
  local domain=$1 key=$2 type=$3 value=$4 flag
  # Only what install.sh changes: the file could have been edited by something else.
  case "$domain $key" in
    "$RECTANGLE screenEdgeGapTop"|"$RECTANGLE screenEdgeGapTopNotch"|"$RECTANGLE doubleClickTitleBar"|\
    "NSGlobalDomain AppleActionOnDoubleClick"|\
    "com.apple.dock autohide"|"com.apple.dock autohide-delay"|"com.apple.dock autohide-time-modifier") ;;
    *) warn "not restoring $domain $key: install.sh never changes it."; return 0 ;;
  esac
  if [ "$domain $key" = "com.apple.dock autohide" ]; then
    local on=false
    [ "$value" = 1 ] && on=true
    # System Events, as in install.sh: it also frees or reserves the Dock's space.
    # Without the Automation permission, the setting alone (the Dock restarts below).
    quiet osascript -e "tell application \"System Events\" to set autohide of dock preferences to $on" 2>/dev/null ||
      run defaults write com.apple.dock autohide -bool "$on"
    return 0
  fi
  case $type in
    absent)
      if defaults read "$domain" "$key" >/dev/null 2>&1; then run defaults delete "$domain" "$key"; fi
      return 0 ;;
    integer) flag=-int ;;
    float) flag=-float ;;
    string) flag=-string ;;
    boolean) flag=-bool; case $value in 1) value=true ;; 0) value=false ;; esac ;;
    *) warn "cannot restore $domain $key ($type), so it was left as is."; return 0 ;;
  esac
  run defaults write "$domain" "$key" "$flag" "$value"
}

main() {
  local arg
  for arg in "$@"; do
    case $arg in
      -y|--yes) ;;   # nothing to confirm any more; still accepted
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $arg. See --help." ;;
    esac
  done
  [ "$(id -u)" != 0 ] || die "run this without sudo: Lintel installs for your user account."

  dry=0
  case ${LINTEL_DRY_RUN:-0} in 0|"") ;; *) dry=1 ;; esac
  bold="" plain=""
  if [ -t 1 ]; then bold=$'\033[1m' plain=$'\033[0m'; fi

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  local apps=() dir app
  for dir in /Applications "$HOME/Applications"; do
    if [ -d "$dir/Lintel.app" ]; then apps+=("$dir/Lintel.app"); fi
  done

  # Read before the app's data and settings are deleted.
  local saved=""
  if [ -f "$RESTORE" ]; then saved=$(cat "$RESTORE"); fi
  local app_double_click="" app_double_click_saved=0
  if app_double_click=$(defaults read "$BUNDLE_ID" previousTitleBarDoubleClick 2>/dev/null); then
    app_double_click_saved=1
  fi

  if running Lintel; then
    step "Quitting Lintel"
    run pkill -xu "$UID" Lintel || true
    wait_until gone Lintel
    if [ "$dry" = 0 ] && running Lintel; then
      pkill -9 -xu "$UID" Lintel || true
      wait_until gone Lintel
    fi
  fi

  for app in ${apps[@]+"${apps[@]}"}; do unregister_login_item "$app"; done

  local hooks_removed=0
  if grep -qsF "$MARKER" "$SETTINGS"; then
    step "Removing the Claude Code hooks from ~/.claude/settings.json"
    # The app's copy matches the installed hooks; otherwise a clone's, or the latest.
    local script="" candidate src=""
    if [ -f "${BASH_SOURCE[0]:-}" ]; then src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); fi
    for app in ${apps[@]+"${apps[@]}"}; do
      candidate="$app/Contents/Resources/agent-hooks.py"
      if [ -z "$script" ] && [ -f "$candidate" ]; then script=$candidate; fi
    done
    if [ -z "$script" ] && [ -n "$src" ] && [ -f "$src/scripts/agent-hooks.py" ]; then script="$src/scripts/agent-hooks.py"; fi
    if [ -z "$script" ]; then
      script="$tmp/agent-hooks.py"
      curl -fsSL -o "$script" "https://github.com/$REPO/releases/latest/download/agent-hooks.py" 2>/dev/null ||
        script=""
    fi
    if [ -n "$script" ] && have_python && quiet python3 "$script" remove; then
      hooks_removed=1
    else
      warn "could not remove the Claude Code hooks from ~/.claude/settings.json.
Remove by hand the hooks whose command ends in $MARKER."
    fi
  fi

  local domain key type value rectangle_changed=0 dock_changed=0 double_click_restored=0
  if [ -n "$saved" ]; then
    step "Restoring the settings changed by the installer"
    while IFS=$'\t' read -r domain key type value; do
      restore "$domain" "$key" "$type" "$value"
      case $domain in
        "$RECTANGLE") rectangle_changed=1 ;;
        com.apple.dock) dock_changed=1 ;;
        NSGlobalDomain) [ "$key" = AppleActionOnDoubleClick ] && double_click_restored=1 ;;
      esac
    done <<<"$saved"
  fi
  if [ "$app_double_click_saved" = 1 ] && [ "$double_click_restored" = 0 ]; then
    step "Restoring the title bar double-click action"
    if [ -n "$app_double_click" ]; then
      run defaults write NSGlobalDomain AppleActionOnDoubleClick -string "$app_double_click"
    else
      restore NSGlobalDomain AppleActionOnDoubleClick absent ""
    fi
  fi
  if [ "$dock_changed" = 1 ]; then run killall Dock || true; fi
  if [ "$rectangle_changed" = 1 ] && running Rectangle; then
    quit_rectangle
    open_retry -a Rectangle || warn "could not relaunch Rectangle. Open it to apply its settings."
  fi

  for app in ${apps[@]+"${apps[@]}"}; do
    step "Removing $app"
    run rm -rf "$app"
  done

  # What is left of Lintel besides the app: its permissions go with the rest.
  local path data=()
  for path in "$SUPPORT" "$HOME/Library/Caches/$BUNDLE_ID" \
      "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
      "$HOME/Library/HTTPStorages/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies"; do
    if [ -e "$path" ]; then data+=("$path"); fi
  done
  local prefs=0
  if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then prefs=1; fi

  if [ ${#apps[@]} -gt 0 ] || [ ${#data[@]} -gt 0 ] || [ "$prefs" = 1 ]; then
    step "Resetting Lintel's permissions"
  fi
  quiet tccutil reset All "$BUNDLE_ID" 2>/dev/null || true

  if [ ${#data[@]} -gt 0 ] || [ "$prefs" = 1 ]; then
    step "Removing Lintel's data and settings"
    # The signing keychain lives in the data folder; delete it through securityd first.
    if [ -f "$SUPPORT/signing.keychain-db" ]; then
      run security delete-keychain "$SUPPORT/signing.keychain-db" || true
    fi
    for path in ${data[@]+"${data[@]}"}; do run rm -rf "$path"; done
    if [ "$prefs" = 1 ]; then run defaults delete "$BUNDLE_ID"; fi
  fi

  if [ ${#apps[@]} -gt 0 ]; then
    step "Lintel is uninstalled"
  elif [ "$hooks_removed" = 1 ] && { [ ${#data[@]} -gt 0 ] || [ "$prefs" = 1 ]; }; then
    step "Lintel was not installed: removed its leftover Claude Code hooks, data and settings"
  elif [ "$hooks_removed" = 1 ]; then
    step "Lintel was not installed: removed its leftover Claude Code hooks"
  elif [ ${#data[@]} -gt 0 ] || [ "$prefs" = 1 ]; then
    step "Lintel was not installed: removed its leftover data and settings"
  else
    step "Lintel is not installed: nothing to remove"
  fi
  if [ "$hooks_removed" = 1 ]; then echo "Restart running Claude Code sessions."; fi
  if [ -f "$SETTINGS.lintel-backup" ]; then
    echo "A copy of the previous Claude Code settings is in ~/.claude/settings.json.lintel-backup."
  fi
}

main "$@"
