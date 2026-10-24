#!/usr/bin/env python3
"""Add or remove Lintel's Claude Code hooks in ~/.claude/settings.json.

Usage: agent-hooks.py add|remove

Only touches hook entries whose command runs Lintel's agent-hook.sh: other hooks are
left exactly as they are. Before a change, copies the file to settings.json.lintel-backup.
Running "add" again changes nothing.
"""
import json
import os
import shlex
import shutil
import stat
import sys
import tempfile

SETTINGS = os.path.expanduser("~/.claude/settings.json")
HOOK = os.path.expanduser("~/Library/Application Support/Lintel/agent-hook.sh")

# event -> (matcher, state). None: the event takes no matcher.
EVENTS = {
    "UserPromptSubmit": (None, "running"),
    "PreToolUse": ("*", "running"),
    "PostToolUse": ("*", "running"),
    "PostToolUseFailure": ("*", "running"),
    "PermissionRequest": ("*", "waiting"),
    "Notification": ("permission_prompt", "waiting"),
    "Stop": (None, "done"),
    "SessionEnd": (None, "end"),
}

# Recognized by the end of the path, so entries still match if the home folder moves.
MARKER = "/Lintel/agent-hook.sh"


def without_ours(group):
    """The group minus Lintel's hooks, or None when nothing else is left in it."""
    if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
        return group
    others = [h for h in group["hooks"] if not (isinstance(h, dict) and MARKER in str(h.get("command", "")))]
    return {**group, "hooks": others} if others else None


def shown(path):
    """The path as the user knows it, with ~ for the home folder."""
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path.startswith(home + os.sep) else path


def reject_constant(name):
    # json.load accepts NaN and Infinity, then json.dump writes them back: invalid JSON.
    raise ValueError(f"{name} is not valid JSON")


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    if action not in ("add", "remove"):
        sys.exit(__doc__)

    try:
        with open(SETTINGS, encoding="utf-8") as f:
            settings = json.load(f, parse_constant=reject_constant)
    except FileNotFoundError:
        settings = {}
    except OSError as error:
        # One line, no traceback: the installer explains what happens next.
        sys.exit(f"could not read {shown(SETTINGS)}: {error.strerror or error}.")
    except ValueError as error:
        sys.exit(f"could not read {shown(SETTINGS)}: {error}.")
    hooks = settings.get("hooks", {}) if isinstance(settings, dict) else None
    if not isinstance(hooks, dict) or not all(isinstance(groups, list) for groups in hooks.values()):
        sys.exit(f"{shown(SETTINGS)} has an unexpected layout: left unchanged.")
    before = json.dumps(settings, sort_keys=True)

    settings["hooks"] = hooks
    for event in list(hooks):
        hooks[event] = [g for g in map(without_ours, hooks[event]) if g is not None]
        if not hooks[event]:
            del hooks[event]

    if action == "add":
        command = f"{shlex.quote(HOOK)} "
        for event, (matcher, state) in EVENTS.items():
            group = {"hooks": [{"type": "command", "command": command + state, "async": True, "timeout": 10}]}
            if matcher is not None:
                group = {"matcher": matcher, **group}
            hooks.setdefault(event, []).append(group)
    if not hooks:
        del settings["hooks"]

    if json.dumps(settings, sort_keys=True) == before:
        print("Claude Code hooks: already up to date.")
        return

    if os.path.exists(SETTINGS):
        backup = SETTINGS + ".lintel-backup"
        shutil.copy2(SETTINGS, backup)
        print(f"Backup: {backup}")
    # Write through a symlink (dotfiles repositories) instead of replacing it,
    # keeping the file's permissions (it can hold API keys).
    target = os.path.realpath(SETTINGS)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    mode = stat.S_IMODE(os.stat(target).st_mode) if os.path.exists(target) else 0o644
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target), prefix=".settings.", suffix=".lintel-tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(settings, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.chmod(tmp, mode)
        os.replace(tmp, target)
    except BaseException:
        os.unlink(tmp)
        raise
    print("Claude Code hooks: " + ("added." if action == "add" else "removed."))


if __name__ == "__main__":
    try:
        main()
    except OSError as error:
        sys.exit(f"could not update {shown(SETTINGS)}: {error.strerror or error}.")
