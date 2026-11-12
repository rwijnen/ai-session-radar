"""Reads the radar: merges the hook state files with Claude Code's own session list.

Two sources:
  ~/.claude/radar/sessions/<id>.json   written by hook.py (what the session is doing)
  ~/.claude/sessions/<pid>.json        written by Claude Code itself (name, app, busy/idle,
                                       process id). Not a documented interface: used only
                                       for names and to tell live sessions from dead ones,
                                       and everything still works if it disappears.
"""
import json
import os
import re
import subprocess
import time
from pathlib import Path

from hook import AGENT_STALE, SESSIONS_DIR, STATE_DIR, running_agents, safe_id

CLAUDE_SESSIONS = Path(os.environ.get("CLAUDE_RADAR_REGISTRY") or os.path.expanduser("~/.claude/sessions"))
SEEN_FILE = Path(STATE_DIR) / "seen.json"

COLUMNS = [
    ("needs", "Needs you"),
    ("review", "Ready to review"),
    ("working", "Working"),
    ("done", "Done"),
]
APP_NAMES = {
    "claude-desktop": "Desktop",
    "claude-vscode": "VS Code",
    "ghostty": "Ghostty",
    "vscode": "VS Code terminal",
    "Apple_Terminal": "Terminal",
    "iTerm.app": "iTerm",
    "WarpTerminal": "Warp",
}
UNTRACKED_GRACE = 15 * 60      # a hook file without a live process stays this long
HANDBACK_GRACE = 2 * 60        # a session waiting for subagents that all stopped is done after this
PRUNE_AFTER = 7 * 24 * 3600    # state files of ended sessions are removed after this


def _read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def _alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except PermissionError:
        return True
    except Exception:
        return False


def registry():
    """Claude Code's own list of running sessions, by session id."""
    found = {}
    for path in CLAUDE_SESSIONS.glob("*.json"):
        entry = _read_json(path)
        if isinstance(entry, dict) and entry.get("sessionId"):
            entry["alive"] = _alive(entry.get("pid", 0))
            found[entry["sessionId"]] = entry
    return found


def git_branch(cwd):
    """The branch checked out in cwd, read from .git without running git."""
    try:
        here = Path(cwd)
        for folder in [here, *here.parents]:
            dot_git = folder / ".git"
            if dot_git.is_file():  # a worktree or submodule: "gitdir: <path>"
                dot_git = Path(dot_git.read_text().split("gitdir:", 1)[1].strip())
                if not dot_git.is_absolute():
                    dot_git = (folder / dot_git).resolve()
            if dot_git.is_dir():
                head = (dot_git / "HEAD").read_text().strip()
                return head.rsplit("/", 1)[-1] if head.startswith("ref:") else head[:8]
    except Exception:
        pass
    return None


def model_name(model_id):
    """`claude-opus-5-5` → `Opus 5.5`; anything unrecognised is returned as it is."""
    m = re.match(r"claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?(\[1m\])?$", model_id or "")
    if not m:
        return model_id
    return f"{m.group(1).title()} {m.group(2)}" + (f".{m.group(3)}" if m.group(3) else "")


def context_window(model_id):
    """The context window, only where the model id states it. Otherwise None: the
    transcript does not record the window, and guessing it would show a wrong %."""
    return 1_000_000 if (model_id or "").endswith("[1m]") else None


def app_name(s):
    entry = s.get("entrypoint") or ""
    if entry in APP_NAMES:
        return APP_NAMES[entry]
    return APP_NAMES.get(s.get("term_program") or "", s.get("term_program") or "Terminal")


def app_key(s):
    """The app family a session runs in, for colour coding: desktop, vscode, ghostty or terminal."""
    entry, term = s.get("entrypoint") or "", s.get("term_program") or ""
    if entry == "claude-desktop":
        return "desktop"
    if entry == "claude-vscode" or term == "vscode":
        return "vscode"
    if term == "ghostty":
        return "ghostty"
    return "terminal"


TITLES_FILE = Path(STATE_DIR) / "titles.json"


def placeholder_name(name, cwd):
    """Claude Code lists VS Code and terminal sessions as "<folder>-<2 hex>" (myapp-62); the
    Desktop app lists its real title. Only a placeholder gives way to the transcript's title."""
    folder = os.path.basename((cwd or "").rstrip("/")).lower().replace(" ", "-")
    return bool(name) and bool(re.fullmatch(re.escape(folder) + r"-[0-9a-f]{2,4}", name))


def transcript_titles(paths):
    """The newest custom title (/rename) and AI title in each transcript: what the VS Code tab and
    the terminal show. Remembers how far each transcript was read, so a refresh reads only what was
    added since. Returns {path: (custom, ai)}."""
    cache = _read_json(TITLES_FILE, {}) or {}
    out, fresh = {}, {}
    for path in paths:
        entry = cache.get(path) or {"offset": 0, "custom": None, "ai": None}
        try:
            size = os.path.getsize(path)
            if size < entry["offset"]:  # rewritten: start over
                entry = {"offset": 0, "custom": None, "ai": None}
            if size > entry["offset"]:
                with open(path, "rb") as f:
                    f.seek(entry["offset"])
                    chunk = f.read()
                end = chunk.rfind(b"\n") + 1  # leave a half-written last line for next time
                for line in chunk[:end].splitlines():
                    if b'"ai-title"' not in line and b'"custom-title"' not in line:
                        continue
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    if d.get("type") == "custom-title" and d.get("customTitle"):
                        entry["custom"] = d["customTitle"]
                    elif d.get("type") == "ai-title" and d.get("aiTitle"):
                        entry["ai"] = d["aiTitle"]
                entry["offset"] += end
        except OSError:
            pass
        fresh[path] = entry
        out[path] = (entry.get("custom"), entry.get("ai"))
    if fresh != {k: cache.get(k) for k in fresh} or set(cache) - set(fresh):
        try:
            tmp = TITLES_FILE.with_suffix(".tmp")
            tmp.write_text(json.dumps(fresh))
            os.replace(tmp, TITLES_FILE)
        except OSError:
            pass
    return out


def seen():
    return _read_json(SEEN_FILE, {}) or {}


def mark_seen(session_ids):
    marks = seen()
    now = time.time()
    for sid in session_ids:
        marks[sid] = now
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = SEEN_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(marks))
    os.replace(tmp, SEEN_FILE)


def session_name(listed, cwd, titles, first_prompt, sid):
    """A /rename title first, then the name Claude Code lists unless it is a placeholder, then the
    AI title the VS Code tab shows, then the placeholder or the first prompt."""
    custom, ai = titles or (None, None)
    if custom:
        return custom
    if listed and not placeholder_name(listed, cwd):
        return listed
    return ai or listed or first_prompt or os.path.basename(cwd) or sid[:8]


def settle_waiting(s, now):
    """A session whose turn ended while its subagents ran stays in Working (hook.py), because
    their hand-back starts its next turn. Once they have all stopped and no hand-back came
    within HANDBACK_GRACE (the session was closed, or a subagent lost its stop event), the
    session is done, from the moment it was last heard of."""
    if s.get("state") != "working" or s.get("kind") != "agents" or running_agents(s, now):
        return
    last = s.get("updated_at") or now
    if now - last < HANDBACK_GRACE:
        return
    s["state"], s["kind"], s["detail"], s["state_since"] = "done", None, "Subagents finished", last
    s["history"] = (s.get("history") or []) + [["done", round(last, 1)]]


def sessions(include_ended=False):
    """Every session worth showing, as plain dicts, most urgent first."""
    now = time.time()
    reg = registry()
    marks = seen()
    rows = {}
    known = set()  # every session with hook state, shown or not

    for path in Path(SESSIONS_DIR).glob("*.json"):
        s = _read_json(path)
        if not isinstance(s, dict) or not s.get("session_id"):
            continue
        known.add(s["session_id"])
        settle_waiting(s, now)
        entry = reg.get(s["session_id"])
        if entry and not entry["alive"] and s.get("state") != "ended":
            s["state"], s["kind"], s["detail"] = "ended", None, "process gone"
        if not entry and s.get("state") != "ended" and now - s.get("updated_at", 0) > UNTRACKED_GRACE:
            continue  # headless run (claude -p) or a session from before a restart
        if s.get("state") == "ended":
            if now - s.get("updated_at", 0) > PRUNE_AFTER:
                for leftover in (path, Path(str(path) + ".lock")):
                    leftover.unlink(missing_ok=True)
            if not include_ended:
                continue
        if entry and entry.get("kind") not in (None, "interactive"):
            continue
        s["tracked"] = True
        rows[s["session_id"]] = (s, entry)

    # Live sessions with no hook state yet (started before `radar install`).
    for sid, entry in reg.items():
        if sid in known or not entry["alive"] or entry.get("kind") not in (None, "interactive"):
            continue
        busy = entry.get("status") == "busy"
        s = {
            "session_id": sid, "cwd": entry.get("cwd"), "entrypoint": entry.get("entrypoint"),
            "host_session_id": entry.get("hostSessionId"), "tracked": False,
            "state": "working" if busy else "idle",
            "state_since": (entry.get("statusUpdatedAt") or 0) / 1000,
            "detail": None if busy else "Not tracked yet: started before the radar hooks",
        }
        rows[sid] = (s, entry)

    try:
        import prs
        pr_by_branch = prs.by_branch()
    except Exception:
        pr_by_branch = {}

    titles = transcript_titles([s["transcript_path"] for s, _ in rows.values() if s.get("transcript_path")])

    out = []
    for sid, (s, entry) in rows.items():
        entry = entry or {}
        cwd = s.get("cwd") or entry.get("cwd") or ""
        state = s.get("state") or "idle"
        since = s.get("state_since") or s.get("updated_at") or now
        column = {"needs_you": "needs", "review": "review", "working": "working"}.get(state, "done")
        acknowledged = marks.get(sid, 0) >= since
        if column == "review" and acknowledged:
            column = "done"
        out.append({
            "id": sid,
            "name": session_name(entry.get("name"), cwd, titles.get(s.get("transcript_path")), s.get("first_prompt"), sid),
            "app": app_name({**s, "entrypoint": s.get("entrypoint") or entry.get("entrypoint")}),
            "app_key": app_key({**s, "entrypoint": s.get("entrypoint") or entry.get("entrypoint")}),
            "entrypoint": s.get("entrypoint") or entry.get("entrypoint"),
            "cwd": cwd,
            "folder": os.path.basename(cwd.rstrip("/")) or cwd,
            "branch": (branch := git_branch(cwd) if cwd else None),
            "pr": pr_by_branch.get(branch) if branch else None,
            "state": state,
            "kind": s.get("kind"),
            "column": column,
            "detail": s.get("detail"),
            "files": s.get("review_files") or [],
            "last_prompt": s.get("last_prompt"),
            "since": since,
            "waiting_s": int(now - since),
            "seen": acknowledged,
            "tracked": s.get("tracked", False),
            "host_session_id": s.get("host_session_id") or entry.get("hostSessionId"),
            "pid": entry.get("pid"),
            "prompt_count": s.get("prompt_count", 0),
            "transcript_path": s.get("transcript_path"),
            "context_tokens": (s.get("context") or {}).get("tokens"),
            "model": model_name((s.get("context") or {}).get("model")),
            "context_window": context_window((s.get("context") or {}).get("model")),
            "is_agent": False,
            "_agents": s.get("agents") if state != "ended" else None,
            # For the timeline: [state, since] per change, and finished subagents
            # [type, description, start, end, background]. A session without history
            # yet (started before it was recorded) gets its current state as one span.
            "history": s.get("history") or [[state, round(since, 1)]],
            "agent_history": s.get("agent_history") or [],
            "started_at": s.get("started_at"),
        })

    order = {key: i for i, (key, _) in enumerate(COLUMNS)}
    # Waiting on you: longest wait first. Everything else: most recent first.
    out.sort(key=lambda r: (order[r["column"]], -r["waiting_s"] if r["column"] in ("needs", "review") else r["waiting_s"]))
    return _with_agents(out, now)


def _with_agents(rows, now):
    """Adds one Working row per running subagent: right after its parent when the parent is
    in Working too, otherwise at the end of the Working column (a background agent whose
    parent already finished its turn)."""
    placed, orphans = [], []
    for parent in rows:
        agents = parent.pop("_agents", None) or {}
        placed.append(parent)
        children = []
        for agent_id, a in sorted(agents.items(), key=lambda kv: kv[1].get("started", 0)):
            if now - a.get("last_at", a.get("started", now)) > AGENT_STALE:
                continue  # lost its stop event (a crash or a killed session)
            started = a.get("started", now)
            children.append({
                **{k: parent[k] for k in ("app", "app_key", "entrypoint", "cwd", "folder", "branch", "host_session_id", "pid")},
                "id": f"{parent['id']}:{agent_id}", "parent_id": parent["id"], "parent_name": parent["name"],
                "is_agent": True, "agent_type": a.get("type") or "agent", "background": a.get("background", False),
                "name": a.get("description") or a.get("type") or "Subagent",
                "state": "working", "kind": "agent", "column": "working",
                "detail": a.get("last_tool"), "tools": a.get("tools", 0),
                "files": [], "last_prompt": None, "since": started, "waiting_s": int(now - started),
                "seen": False, "tracked": True, "prompt_count": 0, "transcript_path": None,
                "context_tokens": None, "model": None, "context_window": None,
                "history": [], "agent_history": [], "started_at": started,
            })
        if parent["column"] == "working":
            placed.extend(children)
        else:
            orphans.extend(children)
    if not orphans:
        return placed
    # Rows are sorted by column, so Working ends after the last needs/review/working row.
    end = max((i for i, r in enumerate(placed) if r["column"] in ("needs", "review", "working")), default=-1) + 1
    return placed[:end] + orphans + placed[end:]


def summary(rows):
    """Counts sessions per column (subagents are counted apart, under `agents`)."""
    counts = {key: 0 for key, _ in COLUMNS}
    counts["agents"] = 0
    for r in rows:
        if r.get("is_agent"):
            counts["agents"] += 1
        elif not (r["column"] == "done" and r["seen"]):
            counts[r["column"]] += 1
    return counts


def find(rows, prefix):
    """A session (or subagent) by exact id, else by a unique session-id prefix."""
    exact = [r for r in rows if r["id"] == prefix]
    if exact:
        return exact[0]
    hits = [r for r in rows if not r.get("is_agent")
            and (r["id"].startswith(prefix) or (r.get("host_session_id") or "").startswith(prefix))]
    return hits[0] if len(hits) == 1 else None


def start_folder(row):
    """The folder the session started in. A VS Code session starts in its window's folder and can
    move away later (EnterWorktree into a git worktree, a `cd` that sticks), so its current folder
    may be one no window has open. The first transcript line with a cwd still holds the start."""
    path = row.get("transcript_path")
    if path:
        try:
            with open(path, "rb") as f:
                for n, line in enumerate(f):
                    if n >= 50:
                        break
                    if b'"cwd"' not in line:
                        continue
                    try:
                        cwd = json.loads(line).get("cwd")
                    except (ValueError, AttributeError):
                        continue
                    if cwd:
                        return cwd
        except OSError:
            pass
    return row.get("cwd")


def open_session(row, session=None):
    """Bring the session's app to the front, as close to the session as each app allows.
    `session` is the parent row when `row` is a subagent."""
    session = session or row
    entry = row.get("entrypoint")
    host = row.get("host_session_id") or ""
    if entry == "claude-desktop":
        if host.startswith("local_"):
            # Undocumented desktop deep link; it falls back to the app if the link is refused.
            subprocess.run(["open", f"claude://code/continue?session={host}&source=url_external"], check=False)
        else:
            subprocess.run(["open", "-b", "com.anthropic.claudefordesktop"], check=False)
    elif entry == "claude-vscode" or row["app"].startswith("VS Code"):
        # Handing the folder to the running VS Code focuses the window that has it open. Not
        # `code <folder>`: on macOS that starts a second VS Code (`open -n`) that passes the folder
        # on and quits, and with a folder no window has open it adds a window.
        folder = start_folder(session)
        if not folder or subprocess.run(["open", "-b", "com.microsoft.VSCode", folder], check=False).returncode != 0:
            subprocess.run(["open", "-b", "com.microsoft.VSCode"], check=False)
    else:
        bundle = {"Ghostty": "com.mitchellh.ghostty", "Terminal": "com.apple.Terminal",
                  "iTerm": "com.googlecode.iterm2", "Warp": "dev.warp.Warp-Stable"}.get(row["app"])
        if bundle:
            subprocess.run(["open", "-b", bundle], check=False)
    mark_seen([row["id"]])


def state_file(session_id):
    return Path(SESSIONS_DIR) / (safe_id(session_id) + ".json")
