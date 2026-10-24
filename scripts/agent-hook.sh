#!/bin/sh
# Claude Code hook → Lintel. Declared in ~/.claude/settings.json by scripts/agent-hooks.py.
# Usage: agent-hook.sh running|waiting|done|end   (hook JSON on stdin)
#
# Writes ~/Library/Application Support/Lintel/agents/<session_id>:
#   line 1: "<state> <unix time> <bundle id of the hosting app, or -> <unix time the state began>"
#     (macOS passes __CFBundleIdentifier to everything an app launches, so the app is
#     known even when its shells run under a separate daemon, outside its process tree)
#   line 2: "cwd <git repository holding the session's folder, else that folder>"
#     (found here, where the terminal already has access: Lintel would need
#     Documents or Desktop access to look itself)
#   then one "<pid> <command>" line per ancestor of this hook, nearest first:
#     a fallback to find the app, and how Lintel finds the Claude process to
#     notice when it exits. Never prints anything and always exits 0:
#   it must not affect Claude.

state=$1
dir="$HOME/Library/Application Support/Lintel/agents"
payload=$(cat)
# Top-level fields only: tool_input and tool_response can hold keys with the same names.
field() { printf '%s' "$payload" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }
session=$(field session_id)
case $session in ""|*[!A-Za-z0-9_-]*) exit 0 ;; esac

file="$dir/$session"
if [ "$state" = end ]; then
  rm -f "$file"
  exit 0
fi
case $state in running|waiting|done) ;; *) exit 0 ;; esac

mkdir -p "$dir" 2>/dev/null || exit 0
now=$(date +%s)
# Same state as before (another tool call while running): keep when it began.
since=$now
if [ -f "$file" ] && read -r previous _ _ began _ <"$file" 2>/dev/null; then
  [ "$previous" = "$state" ] && [ -n "$began" ] && since=$began
fi
# One line in the record: a newline in the path must not add lines.
cwd=$(field cwd | tr -d '\n\r')
up=$cwd
while [ -n "$up" ] && [ "$up" != / ]; do
  if [ -e "$up/.git" ]; then cwd=$up; break; fi
  up=${up%/*}
done
tmp="$dir/.$session.$$"
{
  printf '%s %s %s %s\n' "$state" "$now" "${__CFBundleIdentifier:--}" "$since"
  printf 'cwd %s\n' "$cwd"
  ps -A -o pid=,ppid=,comm= | awk -v start=$$ '
    { pid = $1; parent[pid] = $2; cmd = $0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", cmd); command[pid] = cmd }
    END { p = parent[start]; n = 0; while (p > 1 && n < 40) { print p, command[p]; p = parent[p]; n++ } }'
} > "$tmp" 2>/dev/null && mv -f "$tmp" "$file"
rm -f "$tmp" 2>/dev/null
exit 0
