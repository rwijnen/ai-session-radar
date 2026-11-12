"""radar: the command line of AI Session Radar, one view of every Claude Code session on this Mac.

  radar                 list sessions, grouped: needs you, ready to review, working, done
  radar json            the same as JSON (used by the menu bar app and the board)
  radar serve [--port N] [--no-browser]
                        the board in the browser, on http://127.0.0.1:7878
  radar open <id>       bring that session's app to the front (id prefix is enough)
  radar seen <id>|all   mark finished sessions as seen, so they stop counting
  radar install         add the radar hooks to ~/.claude/settings.json (with a backup)
  radar uninstall       take them out again
  radar hooks-status    the hook state as JSON (used by the menu bar app)
  radar doctor          show where state is read from and whether the hooks are in place

  radar prs             open pull requests: in the watched repos, and anywhere that involves you
  radar prs-json [--refresh]
                        the same as JSON (used by the menu bar app; cached for a minute)
  radar prs watch|unwatch <owner/repo>
                        add or remove a repo from the watch list
  radar review <owner/repo#number> [--print]
                        open a new Claude Code Desktop session in the repo's local checkout with
                        the review prompt typed in (--print shows the link instead)

"""
import json
import subprocess
import sys
import time

import core
import install as installer

COLOURS = {"needs": "\033[38;5;208m", "review": "\033[38;5;141m", "working": "\033[38;5;39m", "done": "\033[38;5;245m"}
RESET, DIM, BOLD = "\033[0m", "\033[2m", "\033[1m"
# App colours, the same families as the menu bar app and the boards: magenta, green, yellow, slate.
APP_COLOURS = {"desktop": "\033[38;5;169m", "vscode": "\033[38;5;36m", "ghostty": "\033[38;5;178m", "terminal": "\033[38;5;246m"}


def ago(seconds):
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h{(seconds % 3600) // 60:02d}"
    return f"{seconds // 86400}d"


def tokens(n):
    """950 → 950, 12_300 → 12k, 1_200_000 → 1.2M (same as the app)."""
    if n < 1000:
        return str(n)
    if n < 1_000_000:
        return f"{round(n / 1000)}k"
    return f"{n / 1_000_000:.1f}M"


def cmd_list(rows):
    tty = sys.stdout.isatty()
    paint = (lambda c, t: f"{c}{t}{RESET}") if tty else (lambda c, t: t)
    if not rows:
        print("No Claude sessions running.")
        return
    for key, title in core.COLUMNS:
        group = [r for r in rows if r["column"] == key]
        if not group:
            continue
        sessions = [r for r in group if not r.get("is_agent")]
        agents = len(group) - len(sessions)
        print(paint(BOLD + COLOURS[key], f"{title} ({len(sessions)}" + (f" + {agents} subagents)" if agents else ")")))
        for r in group:
            if r.get("is_agent"):
                # Under its parent when the parent is in this column; otherwise say whose it is.
                where = "" if any(g["id"] == r["parent_id"] for g in group) else " · in " + r["parent_name"][:40]
                bg = " · background" if r.get("background") else ""
                meta = "{}{} · {} · {} tools{}".format(r["agent_type"], bg, ago(r["waiting_s"]), r["tools"], where)
                print("    {} {}  {}".format(paint(COLOURS[key], "↳"), r["name"][:56], paint(DIM, meta)))
                if r["detail"]:
                    print(f"      {paint(DIM, r['detail'][:120])}")
                continue
            where = r["folder"] + (f" · {r['branch']}" if r["branch"] else "")
            seen = " ✓" if r["column"] == "done" and r["seen"] else ""
            label = paint(BOLD + APP_COLOURS.get(r.get("app_key"), ""), "● " + r["app"])
            context = " · {} ctx".format(tokens(r["context_tokens"])) if r.get("context_tokens") else ""
            meta = "{} · {}{}{}  {}".format(where, ago(r["waiting_s"]), context, seen, r["id"][:8])
            print(f"  {r['name'][:60]}  {label}  {paint(DIM, meta)}")
            if r["detail"] and key in ("needs", "review"):
                print(f"    {paint(COLOURS[key], '→')} {r['detail'][:140]}")
        print()


def cmd_doctor():
    events = installer.installed()
    print(f"Hook state:     {core.SESSIONS_DIR}")
    print(f"Claude sessions:{' '}{core.CLAUDE_SESSIONS}")
    print(f"Settings:       {installer.SETTINGS}")
    print(f"Hooks in place: {', '.join(events) if events else 'none — run `radar install`'}")
    missing = sorted(set(installer.EVENTS) - set(events))
    if events and missing:
        print(f"Missing:        {', '.join(missing)} — run `radar install` again")
    rows = core.sessions()
    untracked = [r for r in rows if not r["tracked"]]
    print(f"Sessions:       {len(rows)} live, {len(untracked)} not tracked yet (started before the hooks)")



PR_GROUPS = [("you", "Waits on you", "\033[38;5;208m"), ("others", "Waits on others", "\033[38;5;39m"),
             ("ready", "Ready to merge", "\033[38;5;36m"), ("stale", "Stale", "\033[38;5;245m")]


def cmd_prs():
    import prs
    data = prs.load(refresh=True)
    if data.get("error"):
        print(f"{DIM}GitHub: {data['error']}{RESET}")
    watched = prs.config()["pr_repos"]
    print(f"{DIM}Watching {', '.join(watched) or 'no repos'}, plus every PR that involves {data.get('viewer') or 'you'}{RESET}")
    for key, title, colour in PR_GROUPS:
        group = [p for p in data.get("prs", []) if p["group"] == key]
        if not group:
            continue
        print(f"\n{colour}{BOLD}{title}{RESET} {DIM}{len(group)}{RESET}")
        for p in group:
            c = p["checks"]
            checks = (f"\033[31m✗ {c['failed']}{RESET} " if c["failed"] else "") + (f"◌ {c['running']} " if c["running"] else "") + f"✓ {c['passed']}"
            ai = (p.get("ai_review") or {}).get("verdict")
            print(f"  {p['repo_name']} #{p['number']}  {p['title'][:70]}")
            print(f"    {DIM}{p['author']} → {p['base']} · {p['reason']} · {checks}{RESET}{DIM} · +{p['additions']} −{p['deletions']}"
                  f"{' · AI review ' + ai.lower().replace('_', ' ') if ai else ''} · updated {ago(int(time.time() - p['updated_at']))} ago{RESET}")


def main(argv):
    cmd = argv[0] if argv else "list"
    if cmd in ("-h", "--help", "help"):
        print(__doc__.strip())
    elif cmd in ("list", "ls"):
        cmd_list(core.sessions())
    elif cmd == "json":
        rows = core.sessions()
        print(json.dumps({"generated_at": time.time(), "counts": core.summary(rows), "sessions": rows}, ensure_ascii=False))
    elif cmd == "serve":
        import server
        port = int(argv[argv.index("--port") + 1]) if "--port" in argv else 7878
        server.serve(port, open_browser="--no-browser" not in argv)
    elif cmd in ("open", "seen"):
        if len(argv) < 2:
            sys.exit(f"usage: radar {cmd} <session id>{'|all' if cmd == 'seen' else ''}")
        rows = core.sessions()
        if cmd == "seen" and argv[1] == "all":
            core.mark_seen([r["id"] for r in rows if r["column"] in ("review", "done")])
            return
        row = core.find(rows, argv[1])
        if not row:
            sys.exit(f"No single session matches '{argv[1]}'.")
        if cmd == "open":
            parent = next((r for r in rows if r["id"] == row.get("parent_id")), None)
            core.open_session(row, parent)
        else:
            core.mark_seen([row["id"]])
    elif cmd == "install":
        installer.install()
    elif cmd == "hooks-status":
        print(json.dumps(installer.status()))
    elif cmd == "uninstall":
        installer.uninstall()
    elif cmd == "doctor":
        cmd_doctor()
    elif cmd == "prs" and len(argv) >= 3 and argv[1] in ("watch", "unwatch"):
        import prs
        repos = [r for r in prs.config()["pr_repos"] if r != argv[2]] + ([argv[2]] if argv[1] == "watch" else [])
        prs.save_repos(repos)
        print("Watching: " + (", ".join(repos) or "no repos (only PRs that involve you)"))
    elif cmd == "prs":
        cmd_prs()
    elif cmd == "prs-json":
        import prs
        print(json.dumps(prs.with_checkouts(prs.load(refresh="--refresh" in argv)), ensure_ascii=False))
    elif cmd == "review":
        import prs
        if len(argv) < 2:
            sys.exit("Usage: radar review <owner/repo#number> [--print]")
        try:
            link = prs.review_link_for(argv[1])
        except LookupError as e:
            sys.exit(str(e))
        if "--print" in argv:
            print(link)
        else:
            subprocess.run(["open", link], check=False)
    else:
        sys.exit(f"Unknown command '{cmd}'. Try `radar help`.")


if __name__ == "__main__":
    main(sys.argv[1:])
