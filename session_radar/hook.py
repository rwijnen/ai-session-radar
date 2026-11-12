#!/usr/bin/env python3
"""Claude Code hook: records what one session is doing, in one small JSON file.

Every Claude Code surface (Desktop Code tab, VS Code extension, CLI in any
terminal) runs the hooks in ~/.claude/settings.json. This script is wired to
those hooks by `radar install`. It reads the hook event from stdin and updates
~/.claude/radar/sessions/<session_id>.json.

Rules for this file: standard library only, fast, and it never fails the hook.
Whatever goes wrong, it exits 0 and prints nothing, so a Claude session is
never blocked or disturbed by the radar.
"""
import fcntl
import json
import os
import re
import sys
import time

STATE_DIR = os.environ.get("CLAUDE_RADAR_DIR") or os.path.expanduser("~/.claude/radar")
SESSIONS_DIR = os.path.join(STATE_DIR, "sessions")

# Files that are worth reviewing when a turn wrote them.
DOC_EXTENSIONS = {".md", ".markdown", ".html", ".htm", ".pdf", ".docx", ".xlsx", ".pptx", ".csv", ".svg"}
# Paths that are working files, not deliverables.
IGNORED_PATH_PARTS = ("/scratchpad/", "/.claude/projects/", "/.claude/plans/", "/node_modules/", "/.git/")
WRITE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
MAX_TEXT = 300


def clip(text, limit=MAX_TEXT):
    text = re.sub(r"\s+", " ", str(text or "")).strip()
    return text if len(text) <= limit else text[: limit - 1] + "…"


def plain(text, limit=MAX_TEXT):
    """Markdown to one plain line: links become their text, emphasis and code marks go."""
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", str(text or ""))
    text = re.sub(r"[*_`]{1,3}([^*_`]+)[*_`]{1,3}", r"\1", text)
    text = re.sub(r"^\s*(#+|[-*]|\d+\.)\s+", "", text, flags=re.M)
    return clip(text, limit)


# Prompts the app or a subagent injects (handbacks, notifications, events), not typed by a person.
AUTOMATED_PROMPT = re.compile(r"^\s*<(agent-message|task-notification|side-sessions-event|ci-monitor-event|"
                              r"system-reminder|command-|local-command|bash-|user-prompt-submit-hook)")


def safe_id(session_id):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", session_id)[:128]


def tool_summary(tool_name, tool_input):
    """One short line saying what a tool call wants to do."""
    if not isinstance(tool_input, dict):
        return tool_name
    for key in ("command", "file_path", "url", "path", "pattern", "description", "query"):
        if tool_input.get(key):
            return f"{tool_name}: {clip(tool_input[key], 120)}"
    return tool_name


def is_document(path):
    if not path or any(part in path for part in IGNORED_PATH_PARTS):
        return False
    return os.path.splitext(path)[1].lower() in DOC_EXTENSIONS


def last_line_is_question(message):
    lines = [line.strip() for line in (message or "").strip().splitlines() if line.strip()]
    if not lines:
        return None
    last = lines[-1].rstrip("*_ `")
    return last if last.endswith("?") else None


def context_usage(path):
    """Context size of the session's latest reply, read from the end of its transcript.

    The context a reply was given is its input tokens, cached and uncached together.
    Subagent replies (isSidechain) are skipped: they have their own context.
    """
    for tail in (1 << 20, 8 << 20):  # 1 MB is usually enough; a huge tool result may need more
        try:
            with open(path, "rb") as f:
                f.seek(0, 2)
                size = f.tell()
                f.seek(max(0, size - tail))
                lines = f.read().splitlines()
        except Exception:
            return None
        for raw in reversed(lines):
            if b'"usage"' not in raw:
                continue
            try:
                entry = json.loads(raw)
            except Exception:
                continue  # the first line, cut by the seek
            message = entry.get("message") or {}
            usage = message.get("usage") or {}
            if entry.get("type") != "assistant" or entry.get("isSidechain"):
                continue
            tokens = sum(usage.get(k) or 0 for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
            if tokens:  # an error placeholder reply carries zero usage
                return {"tokens": tokens, "output": usage.get("output_tokens") or 0, "model": message.get("model")}
        if size <= tail:
            break
    return None


def refresh_context(s, now, every=0):
    if s.get("transcript_path") and now - s.get("context_at", 0) >= every:
        usage = context_usage(s["transcript_path"])
        if usage:
            s["context"] = usage
        s["context_at"] = now


HISTORY_SECONDS = 24 * 3600  # how far back the timeline view can look


def set_state(s, state, kind, detail, now):
    if s.get("state") != state or s.get("kind") != kind:
        s["state_since"] = now
    if s.get("state") != state:
        # State history for the timeline: [state, since], one entry per change, the last day only.
        history = [h for h in s.get("history", []) if now - h[1] < HISTORY_SECONDS]
        history.append([state, round(now, 1)])
        s["history"] = history[-300:]
    s["state"] = state
    s["kind"] = kind
    s["detail"] = clip(detail) if detail else None


AGENT_TOOLS = {"Agent", "Task"}  # the tool that starts a subagent (renamed from Task to Agent)
AGENT_STALE = 20 * 60  # a subagent with no activity this long has lost its stop event


def running_agents(s, now):
    """The session's subagents that are still running: started, not stopped, and active lately."""
    return {agent_id: a for agent_id, a in (s.get("agents") or {}).items()
            if now - a.get("last_at", a.get("started", now)) <= AGENT_STALE}


def waiting_text(agents):
    """`Waiting for subagent: <task>`, or `Waiting for 3 subagents` when there are several."""
    if len(agents) == 1:
        a = next(iter(agents.values()))
        return "Waiting for subagent: " + (a.get("description") or a.get("type") or "agent")
    return f"Waiting for {len(agents)} subagents"


def track_file(s, tool, tool_input):
    """Remembers a document this turn wrote, for the Ready to review column."""
    path = None
    if tool in WRITE_TOOLS:
        path = tool_input.get("file_path") or tool_input.get("notebook_path")
    elif tool == "Artifact" and tool_input.get("action", "publish") == "publish" and not tool_input.get("asset"):
        path = tool_input.get("file_path")
    if path and (tool == "Artifact" or is_document(path)):
        files = s.setdefault("turn_files", [])
        if path not in files:
            files.append(path)
            del files[:-10]


def apply_subagent_event(s, ev, event, now):
    """Events that start, stop or come from inside a subagent. Returns True when handled.

    Every event fired inside a subagent carries agent_id; those update the subagent's own
    record and never move the parent session, except a permission prompt, which needs you.
    """
    agents = s.setdefault("agents", {})
    agent_id = ev.get("agent_id")
    tool = ev.get("tool_name") or ""
    tool_input = ev.get("tool_input") or {}

    if event == "PreToolUse" and tool in AGENT_TOOLS and not agent_id:
        # The main thread starts a subagent: its description arrives here, its id at SubagentStart.
        launches = [l for l in s.get("agent_launches", []) if now - l["at"] < 600]
        launches.append({"type": tool_input.get("subagent_type") or "general-purpose",
                         "description": clip(tool_input.get("description") or tool_input.get("prompt"), 120),
                         "background": bool(tool_input.get("run_in_background")), "at": now})
        s["agent_launches"] = launches[-20:]
        return False  # the parent's own handling still applies (nothing to do for this tool)

    if event == "SubagentStart" and agent_id:
        kind = ev.get("agent_type") or "agent"
        launches = s.get("agent_launches", [])
        match = next((l for l in launches if l["type"] == kind), launches[0] if launches else None)
        if match:
            launches.remove(match)
        agents[agent_id] = {"type": kind, "description": (match or {}).get("description"),
                            "background": (match or {}).get("background", False),
                            "started": now, "last_at": now, "last_tool": None, "tools": 0}
        return True

    if event == "SubagentStop" and agent_id:
        done = agents.pop(agent_id, None)
        if done:
            # Finished subagents stay a day for the timeline: [type, description, start, end, background].
            spans = [a for a in s.get("agent_history", []) if now - a[3] < HISTORY_SECONDS]
            spans.append([done.get("type"), done.get("description"), round(done.get("started", now), 1),
                          round(now, 1), bool(done.get("background"))])
            s["agent_history"] = spans[-100:]
        if s.get("permission_agent") == agent_id:
            s.pop("permission_agent", None)
        return True

    if not agent_id:
        return False

    # From inside a subagent.
    agent = agents.setdefault(agent_id, {"type": ev.get("agent_type") or "agent", "description": None,
                                         "background": False, "started": now, "tools": 0})
    agent["last_at"] = now
    if event == "PermissionRequest":
        set_state(s, "needs_you", "permission",
                  f"Subagent {agent['type']}: allow " + tool_summary(tool, tool_input) + "?", now)
        s["permission_agent"] = agent_id
    elif event in ("PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied"):
        agent["last_tool"] = clip(tool_summary(tool, tool_input), 120)
        if event != "PreToolUse":
            agent["tools"] = agent.get("tools", 0) + 1
        if s.get("permission_agent") == agent_id and s.get("state") == "needs_you" and s.get("kind") == "permission":
            set_state(s, "working", None, None, now)
            s.pop("permission_agent", None)
        if event == "PostToolUse" and s.get("state") == "working":
            track_file(s, tool, tool_input)  # a subagent's document is part of the turn's output
    elif event == "Notification" and ev.get("notification_type") == "permission_prompt" and s.get("kind") != "permission":
        set_state(s, "needs_you", "permission", ev.get("message") or "Permission needed", now)
        s["permission_agent"] = agent_id
    return True


def apply_event(s, ev, now):
    event = ev.get("hook_event_name") or ""
    tool = ev.get("tool_name") or ""
    tool_input = ev.get("tool_input") or {}

    # Who and where: refreshed on every event, so a moved or resumed session stays right.
    s["session_id"] = ev.get("session_id")
    s["cwd"] = ev.get("cwd") or s.get("cwd")
    s["transcript_path"] = ev.get("transcript_path") or s.get("transcript_path")
    for key, env in (("entrypoint", "CLAUDE_CODE_ENTRYPOINT"), ("term_program", "TERM_PROGRAM"),
                     ("host_session_id", "CLAUDE_CODE_HOST_SESSION_ID"), ("term_session", "TERM_SESSION_ID")):
        if os.environ.get(env):
            s[key] = os.environ[env]
    s.setdefault("started_at", now)
    s["updated_at"] = now
    s["last_event"] = event

    if apply_subagent_event(s, ev, event, now):
        return

    # A session that picked up the hooks mid-turn has no state yet: tool activity means it works.
    if s.get("state") in (None, "idle") and event in ("PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied"):
        set_state(s, "working", None, None, now)

    if event == "SessionStart":
        refresh_context(s, now)  # a resumed or compacted session already has a context
        if not s.get("state") or s.get("state") == "ended":
            set_state(s, "idle", None, None, now)

    elif event == "UserPromptSubmit":
        raw = str(ev.get("prompt") or "")
        automated = AUTOMATED_PROMPT.match(raw)
        if not automated:  # an injected handback still starts work, but is not a prompt
            prompt = clip(raw, 200)
            s.setdefault("first_prompt", prompt)
            s["last_prompt"] = prompt
            s["prompt_count"] = s.get("prompt_count", 0) + 1
        # A subagent's hand-back continues the turn that waited for it: that turn's documents
        # still count when the work is finally done.
        if not (automated and s.get("kind") == "agents"):
            s["turn_files"] = []
        s["pending_ask"] = None
        set_state(s, "working", None, None, now)

    elif event == "PreToolUse":
        if tool == "AskUserQuestion":
            questions = tool_input.get("questions") or [{}]
            set_state(s, "needs_you", "question", questions[0].get("question") or "Claude asks a question", now)
        elif tool == "ExitPlanMode":
            set_state(s, "needs_you", "plan", "Plan ready for your approval", now)
        elif tool.endswith("ccd_turn__wrap_up"):
            # Desktop Code tab: the end-of-turn box. An `ask` means the turn ends on a question.
            s["pending_ask"] = plain(tool_input.get("ask")) or None
            s["recap"] = plain(tool_input.get("recap")) or None

    elif event == "PermissionRequest":
        set_state(s, "needs_you", "permission", "Allow " + tool_summary(tool, tool_input) + "?", now)

    elif event == "Notification":
        kind = ev.get("notification_type")
        if kind == "permission_prompt" and s.get("kind") != "permission":
            set_state(s, "needs_you", "permission", ev.get("message") or "Permission needed", now)
        elif kind == "elicitation_dialog":
            set_state(s, "needs_you", "question", ev.get("message") or "Input needed", now)
        # idle_prompt only repeats that the session waits; the Stop event already said so.

    elif event in ("PostToolUse", "PostToolUseFailure", "PermissionDenied"):
        # The permission or question was answered: back to work.
        if s.get("state") == "needs_you" and s.get("kind") in ("permission", "question", "plan") \
                and now >= s.get("state_since", 0):
            set_state(s, "working", None, None, now)
        if event == "PostToolUse" and s.get("state") == "working":
            track_file(s, tool, tool_input)
        refresh_context(s, now, every=15)  # the context grows during a turn; this hook runs async

    elif event == "Stop":
        refresh_context(s, now)
        message = ev.get("last_assistant_message") or ""
        s["last_message"] = clip(message, 500) or None
        files = s.get("turn_files") or []
        question = s.get("pending_ask") or last_line_is_question(message)
        running = running_agents(s, now)
        for a in running.values():
            a["background"] = True  # the turn ended while it ran, so it runs in the background
        if question or not running:
            s["review_files"] = files
        if question:
            set_state(s, "needs_you", "question", plain(question), now)
        elif running:
            # The turn ended, but the subagents it started still work and will hand back to the
            # session, which then carries on: the work is not finished yet. turn_files stays for
            # the turn that ends after the hand-back.
            set_state(s, "working", "agents", waiting_text(running), now)
        elif files:
            names = ", ".join(os.path.basename(f) for f in files[:3]) + (" …" if len(files) > 3 else "")
            set_state(s, "review", "files", names, now)
        else:
            set_state(s, "done", None, s.get("recap") or plain(message), now)
        s["pending_ask"] = None
        s["recap"] = None

    elif event == "StopFailure":
        set_state(s, "needs_you", "error", ev.get("error") or ev.get("message") or "The turn failed", now)

    elif event == "SessionEnd":
        set_state(s, "ended", None, ev.get("reason"), now)
        s["agents"] = {}


def main():
    if os.environ.get("CLAUDE_RADAR_SKIP"):
        return  # set by a caller that runs Claude Code headless and does not want it tracked
    now = time.time()
    try:
        ev = json.load(sys.stdin)
    except Exception:
        return
    session_id = ev.get("session_id") if isinstance(ev, dict) else None
    if not session_id:
        return
    os.makedirs(SESSIONS_DIR, exist_ok=True)
    path = os.path.join(SESSIONS_DIR, safe_id(session_id) + ".json")
    with open(path + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(path) as f:
                state = json.load(f)
        except Exception:
            state = {}
        apply_event(state, ev, now)
        tmp = f"{path}.{os.getpid()}.tmp"
        with open(tmp, "w") as f:
            json.dump(state, f, ensure_ascii=False, indent=1)
        os.replace(tmp, path)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
