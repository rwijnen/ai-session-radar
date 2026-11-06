"""Adds the radar hooks to ~/.claude/settings.json, or takes them out again.

User-level settings apply to every Claude Code surface: the Desktop Code tab, the
VS Code extension and the CLI. Existing hooks are left exactly as they are; radar
entries are recognised by the path of hook.py in their command.

The menu bar app keeps a copy of this package in ~/.claude/radar/lib and runs it from
there, so the hooks point at that stable copy: moving or updating the app never breaks them.
It also passes the Python it found working (RADAR_PYTHON), which the hooks then use.
"""
import json
import os
import shutil
import time
from pathlib import Path

SETTINGS = Path(os.environ.get("CLAUDE_RADAR_SETTINGS") or os.path.expanduser("~/.claude/settings.json"))
HOOK = Path(__file__).resolve().parent / "hook.py"
MARKER = "session_radar/hook.py"
LEGACY = ("claude_radar/hook.py",)  # earlier private builds; replaced on install

# event -> (matcher or None, async)
EVENTS = {
    "SessionStart": (None, False),
    "UserPromptSubmit": (None, False),
    "PreToolUse": ("AskUserQuestion|ExitPlanMode|Skill|Agent|Task|mcp__ccd_turn__wrap_up", False),
    "SubagentStart": (None, False),
    "SubagentStop": (None, False),
    "PermissionRequest": (None, False),
    "Notification": (None, False),
    "PostToolUse": ("*", True),
    "PostToolUseFailure": ("*", True),
    "PermissionDenied": (None, True),
    "Stop": (None, False),
    "StopFailure": (None, False),
    "SessionEnd": (None, False),
}


def _load():
    if not SETTINGS.exists():
        return {}
    return json.loads(SETTINGS.read_text())


def _is_radar(group):
    return any(m in (h.get("command") or "") for h in group.get("hooks", []) for m in (MARKER, *LEGACY))


def python():
    """The interpreter the hooks run with: the one the app checked, else /usr/bin/python3."""
    return os.environ.get("RADAR_PYTHON") or ("/usr/bin/python3" if os.path.exists("/usr/bin/python3") else "python3")


def _strip(settings):
    hooks = settings.get("hooks", {})
    for event in list(hooks):
        hooks[event] = [g for g in hooks[event] if not _is_radar(g)]
        if not hooks[event]:
            del hooks[event]
    if not hooks:
        settings.pop("hooks", None)
    return settings


def _save(settings):
    if SETTINGS.exists():
        backup = SETTINGS.with_name(f"{SETTINGS.name}.bak.{time.strftime('%Y%m%d%H%M%S')}")
        shutil.copy2(SETTINGS, backup)
        print(f"Backup: {backup}")
    tmp = SETTINGS.with_suffix(".radar.tmp")
    tmp.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
    os.replace(tmp, SETTINGS)


def installed():
    try:
        hooks = _load().get("hooks", {})
    except Exception:
        return []
    return sorted(e for e, groups in hooks.items() if any(_is_radar(g) for g in groups))


def command():
    return f'"{python()}" "{HOOK}"'


def status():
    """For the app: which events have radar hooks, which are missing, and whether every radar
    hook runs this copy with this Python (false after the app moved, or for an older build's hooks)."""
    try:
        hooks = _load().get("hooks", {})
    except Exception:
        hooks = {}
    commands = [h.get("command") for groups in hooks.values() for g in groups if _is_radar(g) for h in g.get("hooks", [])]
    events = installed()
    return {"installed": events, "missing": sorted(set(EVENTS) - set(events)),
            "current": bool(commands) and not (set(EVENTS) - set(events)) and all(c == command() for c in commands),
            "settings": str(SETTINGS), "command": command()}


def install():
    settings = _strip(_load())
    hooks = settings.setdefault("hooks", {})
    for event, (matcher, is_async) in EVENTS.items():
        entry = {"type": "command", "command": command(), "timeout": 5}
        if is_async:
            entry["async"] = True
        group = {"hooks": [entry]}
        if matcher:
            group = {"matcher": matcher, **group}
        hooks.setdefault(event, []).append(group)
    _save(settings)
    print(f"Radar hooks added for {len(EVENTS)} events in {SETTINGS}.")
    print("Sessions pick them up when they start; restart running sessions to track them now.")


def uninstall():
    before = installed()
    if not before:
        print("No radar hooks found; nothing changed.")
        return
    _save(_strip(_load()))
    print(f"Radar hooks removed from {SETTINGS} ({', '.join(before)}).")
