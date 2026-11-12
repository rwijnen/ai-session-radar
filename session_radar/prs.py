"""Open pull requests at a glance, read through the GitHub CLI (`gh`), which holds the sign-in.

Which PRs: every open PR in the repos listed under "pr_repos" in ~/.claude/radar/config.json,
plus every open PR anywhere that involves you (author, reviewer, assignee, mentioned).
One GraphQL call fetches them all; the result is cached in ~/.claude/radar/prs.json, so the
board, the menu and the session cards read the cache and only the app's PR timer calls GitHub.

Each PR is grouped by who has to act:
  you      your review is requested, or your own PR has failed checks, changes requested or a conflict
  others   checks running, or a review pending
  ready    approved, checks green, no conflict
  stale    no activity for "pr_stale_days" (14) days

The AI review is the vcrm-sf:pr-review comment, found by its marker
<!-- vcrm-pr-review sha=<head> verdict=<APPROVE|REQUEST_CHANGES|COMMENT> -->; its GitHub-rendered
HTML is kept so the app can show it as GitHub does.

Review with Claude: a PR that waits on your review can be opened as a new Claude Code Desktop
session in the repo's local checkout, with a review prompt typed in (`radar review <id>`). The
checkout is the folder set in Settings ("pr_checkouts"), else the main checkout of a folder a
Claude session ran in whose `origin` is that repo. The prompt is "pr_review_prompt", else
REVIEW_PROMPT. Desktop types the prompt into a new session; it starts when you press Return.
"""
import calendar
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path
from urllib.parse import quote

from hook import SESSIONS_DIR, STATE_DIR

CONFIG = Path(STATE_DIR) / "config.json"
CACHE = Path(STATE_DIR) / "prs.json"
DEFAULTS = {"prs_enabled": True, "pr_repos": [], "pr_stale_days": 14, "pr_others": True,
            "pr_checkouts": {}, "pr_review_prompt": ""}
FRESH = 60                       # seconds a cache counts as fresh without --refresh

MARKER = re.compile(r"<!--\s*vcrm-pr-review\s+sha=([0-9a-f]+)\s+verdict=([A-Z_]+)\s*-->")
JIRA = re.compile(r"\b([A-Z][A-Z0-9]{1,9}-\d+)\b")
FAILED = {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"}
RUNNING = {"QUEUED", "IN_PROGRESS", "WAITING", "PENDING", "REQUESTED", "EXPECTED"}

QUERY = """
query($q1: String!, $q2: String!, $repos: Boolean!) {
  viewer { login }
  watched: search(query: $q1, type: ISSUE, first: 50) @include(if: $repos) { nodes { ...pr } }
  mine: search(query: $q2, type: ISSUE, first: 50) { nodes { ...pr } }
}
fragment pr on PullRequest {
  number title url isDraft createdAt updatedAt additions deletions changedFiles
  baseRefName headRefName headRefOid mergeable reviewDecision
  repository { nameWithOwner }
  author { login }
  assignees(first: 10) { nodes { login } }
  reviewRequests(first: 10) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { name } } } }
  latestReviews(first: 10) { nodes { author { login } state } }
  comments(last: 15) { totalCount nodes { body bodyHTML url createdAt } }
  commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 80) { nodes {
    __typename ... on CheckRun { name status conclusion } ... on StatusContext { context state } } } } } } }
}
"""


def config():
    cfg = dict(DEFAULTS)
    try:
        stored = json.loads(CONFIG.read_text())
        cfg.update({k: v for k, v in stored.items() if k in DEFAULTS})
    except Exception:
        pass
    return cfg


def save_repos(repos):
    save_config(pr_repos=repos)


def save_config(**changes):
    """Writes settings into config.json, keeping every other setting there."""
    try:
        stored = json.loads(CONFIG.read_text())
    except Exception:
        stored = {}
    stored.update(changes)
    os.makedirs(STATE_DIR, exist_ok=True)
    CONFIG.write_text(json.dumps(stored, indent=1) + "\n")


def _iso(ts):
    return calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")) if ts else 0


def checks(node):
    """Checks per name (several workflows can run a job of the same name): failed beats
    running beats passed; a name whose runs were all skipped counts as skipped."""
    commits = (node.get("commits") or {}).get("nodes") or []
    rollup = commits[0]["commit"].get("statusCheckRollup") if commits else None
    by_name = {}
    for c in ((rollup or {}).get("contexts") or {}).get("nodes") or []:
        name = c.get("name") or c.get("context") or "?"
        status, result = c.get("status"), c.get("conclusion") or c.get("state")
        outcome = ("running" if status in RUNNING or result in RUNNING else
                   "failed" if result in FAILED else
                   "skipped" if result in ("SKIPPED", "NEUTRAL", "STALE") else "passed")
        rank = {"failed": 3, "running": 2, "passed": 1, "skipped": 0}
        if rank[outcome] > rank.get(by_name.get(name), -1):
            by_name[name] = outcome
    out = {"passed": 0, "failed": 0, "running": 0, "skipped": 0, "failing": []}
    for name, outcome in sorted(by_name.items()):
        out[outcome] += 1
        if outcome == "failed":
            out["failing"].append(name)
    return out


def ai_review(node):
    """The newest vcrm-sf:pr-review comment: verdict, the commit it reviewed, its HTML."""
    for c in reversed((node.get("comments") or {}).get("nodes") or []):
        m = MARKER.search(c.get("body") or "")
        if m:
            return {"verdict": m.group(2), "sha": m.group(1), "current": m.group(1) == node.get("headRefOid"),
                    "url": c.get("url"), "at": _iso(c.get("createdAt")), "html": c.get("bodyHTML") or ""}
    return None


def summarise(node, me, now, stale_days):
    author = (node.get("author") or {}).get("login") or "ghost"
    requested = [r["requestedReviewer"].get("login") or r["requestedReviewer"].get("name")
                 for r in (node.get("reviewRequests") or {}).get("nodes") or [] if r.get("requestedReviewer")]
    assignees = [a["login"] for a in (node.get("assignees") or {}).get("nodes") or []]
    reviews = {r["author"]["login"]: r["state"] for r in (node.get("latestReviews") or {}).get("nodes") or [] if r.get("author")}
    c = checks(node)
    updated = _iso(node.get("updatedAt"))
    mine = author == me
    pr = {
        "id": f"{node['repository']['nameWithOwner']}#{node['number']}",
        "repo": node["repository"]["nameWithOwner"],
        "repo_name": node["repository"]["nameWithOwner"].split("/")[-1],
        "number": node["number"], "title": node["title"], "url": node["url"],
        "jira": (JIRA.search(node["title"]) or [None, None])[1],
        "author": author, "mine": mine, "draft": node.get("isDraft", False),
        "base": node.get("baseRefName"), "head": node.get("headRefName"), "head_sha": node.get("headRefOid"),
        "created_at": _iso(node.get("createdAt")), "updated_at": updated,
        "additions": node.get("additions", 0), "deletions": node.get("deletions", 0), "files": node.get("changedFiles", 0),
        "mergeable": node.get("mergeable"), "review": node.get("reviewDecision"),
        "requested": requested, "requested_me": me in requested, "assigned_me": me in assignees,
        "reviews": reviews, "comments": (node.get("comments") or {}).get("totalCount", 0),
        "checks": c, "ai_review": ai_review(node),
    }
    pr["group"], pr["reason"] = group(pr, now, stale_days)
    return pr


def group(pr, now, stale_days):
    c = pr["checks"]
    if pr["mine"] and not pr["draft"]:
        if c["failed"]:
            return "you", f"{c['failed']} check{'s' if c['failed'] > 1 else ''} failed"
        if pr["review"] == "CHANGES_REQUESTED":
            return "you", "changes requested"
        if pr["mergeable"] == "CONFLICTING":
            return "you", "merge conflict"
    if pr["requested_me"]:
        return "you", "your review is requested"
    if now - pr["updated_at"] > stale_days * 86400:
        return "stale", f"no activity for {int((now - pr['updated_at']) // 86400)} days"
    if pr["draft"]:
        return "others", "draft"
    if c["running"]:
        return "others", "checks running"
    if pr["review"] == "APPROVED" and not c["failed"] and pr["mergeable"] != "CONFLICTING":
        return "ready", "approved, checks passed"
    if c["failed"]:
        return "others", f"{c['failed']} check{'s' if c['failed'] > 1 else ''} failed"
    return "others", "review pending" if pr["review"] in (None, "REVIEW_REQUIRED") else (pr["review"] or "").lower().replace("_", " ")


ORDER = {"you": 0, "others": 1, "ready": 2, "stale": 3}


def fetch():
    """Ask GitHub, write the cache, return it. Errors are cached too, with the last good PRs."""
    cfg = config()
    if not cfg["prs_enabled"]:
        return _write({"fetched_at": time.time(), "viewer": None, "prs": [], "error": None, "disabled": True})
    gh = shutil.which("gh") or next((p for p in ("/opt/homebrew/bin/gh", "/usr/local/bin/gh") if os.path.exists(p)), None)
    previous = cached() or {}
    result = {"fetched_at": time.time(), "viewer": previous.get("viewer"), "prs": previous.get("prs", []), "error": None}
    if not gh:
        result["error"] = "GitHub CLI (gh) not found"
        return _write(result)
    repos = [r for r in cfg["pr_repos"] if r]
    q1 = "is:pr is:open archived:false " + " ".join(f"repo:{r}" for r in repos)
    args = [gh, "api", "graphql", "-f", f"query={QUERY}", "-f", f"q1={q1}",
            "-f", "q2=is:pr is:open archived:false involves:@me", "-F", f"repos={'true' if repos else 'false'}"]
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=60)
        data = json.loads(p.stdout or "{}")
    except Exception as e:
        result["error"] = f"gh failed: {e}"
        return _write(result)
    if p.returncode != 0 or "data" not in data:
        msg = (data.get("errors") or [{}])[0].get("message") if isinstance(data, dict) else None
        result["error"] = msg or (p.stderr.strip().splitlines() or ["gh failed"])[-1]
        return _write(result)
    me = data["data"]["viewer"]["login"]
    now = time.time()
    seen, prs = set(), []
    for key in ("mine", "watched") if repos else ("mine",):
        for node in ((data["data"].get(key) or {}).get("nodes") or []):
            if not node or "number" not in node:
                continue
            pr = summarise(node, me, now, cfg["pr_stale_days"])
            involved = pr["mine"] or pr["requested_me"] or pr["assigned_me"] or key == "mine"
            if pr["id"] in seen or (not cfg["pr_others"] and not involved):
                continue
            seen.add(pr["id"])
            prs.append(pr)
    prs.sort(key=lambda r: (ORDER[r["group"]], -r["updated_at"]))
    result.update(viewer=me, prs=prs)
    return _write(result)


def _write(result):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = CACHE.with_suffix(".tmp")
    tmp.write_text(json.dumps(result, ensure_ascii=False))
    os.replace(tmp, CACHE)
    return result


def cached():
    try:
        return json.loads(CACHE.read_text())
    except Exception:
        return None


def load(refresh=False):
    c = cached()
    if refresh or not c or time.time() - c.get("fetched_at", 0) > FRESH:
        return fetch()
    return c


def by_branch():
    """PRs keyed by head branch, for linking a session to its PR. Small: no HTML."""
    out = {}
    for pr in (cached() or {}).get("prs", []):
        slim = {k: pr[k] for k in ("id", "repo", "number", "title", "url", "group", "reason", "review", "checks")}
        slim["ai_verdict"] = (pr.get("ai_review") or {}).get("verdict")
        # Sessions know their branch without its folder ("feature/x" reads as "x").
        out.setdefault((pr["head"] or "").rsplit("/", 1)[-1], slim)
    return out


# --- Review with Claude -------------------------------------------------------------------

REVIEW_PROMPT = """\
Run a read-only architecture review of pull request {url} ({repo}#{number}, {head} → {base}): {title}

Use the vcrm-sf:technical-architect skill.

- Read the PR with `gh pr view {number} --repo {repo} --comments` and `gh pr diff {number} --repo {repo}`.
- Judge the design choices: fit with the Salesforce Well-Architected framework, governor limits, the integration pattern, and sharing and security.
- Check that the change fits its openspec/changes/<change>/design.md, the capability's SD-*.md and the DR-<n> records that SD cites. Read them as they are on the PR's branch, for example with `gh api -H "Accept: application/vnd.github.raw" "repos/{repo}/contents/<path>?ref={head}"`.
- The CI has already posted a release review on the PR (the comment with the vcrm-pr-review marker). Read it instead of redoing its release checks.
- Stay read-only: don't check out the branch, don't post anything to GitHub, and don't touch any Salesforce org.

End with your findings ranked by severity, each with its file and line, and a `Confidence:` line.
"""
PLACEHOLDER = re.compile(r"\{(url|repo|number|title|head|base)\}")
PROMPT_LIMIT = 14336             # Claude Desktop cuts a deep-link prompt at this many characters
REMOTE = re.compile(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?/*$")


def review_prompt(pr, template=None):
    """The template with the PR's values filled in. Only the six known placeholders are
    replaced, so other braces in a custom prompt stay as they are."""
    template = template if (template or "").strip() else REVIEW_PROMPT
    return PLACEHOLDER.sub(lambda m: str(pr.get(m.group(1)) or ""), template)


def review_link(folder, prompt):
    """Claude Desktop's deep link for a new Code session in `folder` with `prompt` typed in.
    Undocumented, like the claude://code/continue link core.open_session uses."""
    return ("claude://code/new?folder=" + quote(folder, safe="")
            + "&prompt=" + quote(prompt[:PROMPT_LIMIT], safe=""))


def _git_dirs(folder):
    """(worktree root, git dir, common git dir) of the checkout around `folder`, read from .git
    without running git. A linked worktree's common dir is the main checkout's .git."""
    try:
        here = Path(folder)
        for root in [here, *here.parents]:
            dot_git = root / ".git"
            if dot_git.is_file():  # a linked worktree or a submodule: "gitdir: <path>"
                # normpath, not resolve: the folder keeps the path you know it by, symlinks and all.
                git_dir = Path(os.path.normpath(root / dot_git.read_text().split("gitdir:", 1)[1].strip()))
            elif dot_git.is_dir():
                git_dir = dot_git
            else:
                continue
            common = git_dir
            if (git_dir / "commondir").is_file():
                common = Path(os.path.normpath(git_dir / (git_dir / "commondir").read_text().strip()))
            return root, git_dir, common
    except (OSError, IndexError):
        pass
    return None


def origin_repo(git_dir):
    """`owner/name` of the `origin` remote in a git dir's config, or None."""
    try:
        text = (Path(git_dir) / "config").read_text()
    except OSError:
        return None
    section = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("["):
            section = line
        elif section and re.fullmatch(r'\[remote\s+"origin"\]', section) and line.startswith("url"):
            m = REMOTE.search(line.split("=", 1)[1].strip())
            return f"{m.group(1)}/{m.group(2)}" if m else None
    return None


def checkout_of(folder):
    """(checkout folder, owner/name) for a folder inside a git checkout. A linked worktree
    (a change's own worktree, `.claude/worktrees/...`) counts as its main checkout, which
    outlives it."""
    dirs = _git_dirs(folder)
    if not dirs:
        return None, None
    root, git_dir, common = dirs
    repo = origin_repo(common)
    if common != git_dir and common.name == ".git" and common.parent.is_dir():
        root = common.parent
    return str(root), repo


def session_folders():
    """Folders Claude sessions ran in, newest first: the radar's session files (kept a week
    after a session ends) and Claude Code's list of running sessions."""
    import core
    found = {}
    for path in Path(SESSIONS_DIR).glob("*.json"):
        s = core._read_json(path)
        if isinstance(s, dict) and s.get("cwd"):
            found[s["cwd"]] = max(found.get(s["cwd"], 0), s.get("updated_at") or 0)
    for path in core.CLAUDE_SESSIONS.glob("*.json"):
        e = core._read_json(path)
        if isinstance(e, dict) and e.get("cwd"):
            found[e["cwd"]] = max(found.get(e["cwd"], 0), (e.get("updatedAt") or e.get("startedAt") or 0) / 1000)
    return sorted(found, key=lambda f: -found[f])


def found_checkouts():
    """{owner/name (lower case): checkout folder} from the folders sessions ran in; for a repo
    with several clones, the one used most recently."""
    out, roots = {}, set()
    for folder in session_folders():
        if not os.path.isdir(folder):
            continue
        root, repo = checkout_of(folder)
        if root in roots:
            continue
        roots.add(root)
        if repo:
            out.setdefault(repo.lower(), root)
    return out


def checkout(repo, cfg=None, found=None):
    """(folder, source) a review of `repo` runs in: the folder set in Settings ("setting"),
    else one found from sessions ("session"), else (None, None)."""
    cfg = cfg or config()
    for name, folder in (cfg.get("pr_checkouts") or {}).items():
        if folder and name.lower() == repo.lower():
            return folder, "setting"
    folder = (found if found is not None else found_checkouts()).get(repo.lower())
    return (folder, "session") if folder else (None, None)


def with_checkouts(data):
    """Adds what the app needs for its Review with Claude button: the checkout found from
    sessions for every repo it may ask about (watched, with PRs, or set in Settings; the
    setting itself the app reads from config.json) and the built-in prompt."""
    cfg = config()
    repos = {}
    for r in [*cfg["pr_repos"], *(p["repo"] for p in data.get("prs") or []), *(cfg["pr_checkouts"] or {})]:
        repos.setdefault(r.lower(), r)
    found = found_checkouts()
    data["checkouts"] = {r: found.get(key) for key, r in repos.items()}
    data["review_prompt_default"] = REVIEW_PROMPT
    return data


def review_link_for(pr_id):
    """The deep link that reviews the cached PR `owner/name#number`. Raises LookupError with a
    message for the user when the PR or its checkout is unknown."""
    pr = next((p for p in (cached() or {}).get("prs", []) if p["id"].lower() == pr_id.lower()), None)
    if not pr:
        raise LookupError(f"No open pull request {pr_id} in the radar's list. Run `radar prs` to refresh it.")
    cfg = config()
    folder, source = checkout(pr["repo"], cfg)
    if not folder:
        raise LookupError(f"No local checkout of {pr['repo']} is known. Set its folder under Settings › "
                          "Pull requests, or run a Claude session in it once.")
    if not os.path.isdir(folder):
        raise LookupError(f"The checkout of {pr['repo']} ({folder}) does not exist. Change it under Settings › Pull requests.")
    return review_link(folder, review_prompt(pr, cfg["pr_review_prompt"]))
