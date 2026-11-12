"""Feeds simulated hook events through hook.py and checks where each session lands.

Run: python3 -m unittest discover -s tests
Uses temporary folders for all state; never touches ~/.claude.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOOK = ROOT / "session_radar" / "hook.py"
CLI = ROOT / "bin" / "radar"


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.registry = base / "registry"
        self.registry.mkdir()
        self.settings = base / "settings.json"
        self.env = {**os.environ, "CLAUDE_RADAR_DIR": str(base / "radar"),
                    "CLAUDE_RADAR_REGISTRY": str(self.registry), "CLAUDE_RADAR_SETTINGS": str(self.settings),
                    "CLAUDE_CODE_ENTRYPOINT": "cli", "TERM_PROGRAM": "ghostty"}

    def tearDown(self):
        self.tmp.cleanup()

    def live(self, sid, **extra):
        entry = {"pid": os.getpid(), "sessionId": sid, "cwd": str(ROOT), "kind": "interactive",
                 "entrypoint": "cli", "status": "idle", **extra}
        (self.registry / f"{sid}.json").write_text(json.dumps(entry))

    def fire(self, sid, event, **fields):
        payload = {"session_id": sid, "hook_event_name": event, "cwd": str(ROOT), **fields}
        r = subprocess.run([sys.executable, str(HOOK)], input=json.dumps(payload), text=True,
                           env=self.env, capture_output=True)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")

    def board(self):
        out = subprocess.run([sys.executable, str(CLI), "json"], env=self.env, capture_output=True, text=True, check=True)
        return {r["id"]: r for r in json.loads(out.stdout)["sessions"]}


class RadarTest(Harness):
    def test_turn_that_ends_in_a_question_needs_you(self):
        self.live("s1")
        self.fire("s1", "SessionStart", source="startup")
        self.fire("s1", "UserPromptSubmit", prompt="refactor the parser")
        self.assertEqual(self.board()["s1"]["column"], "working")
        self.fire("s1", "Stop", last_assistant_message="Done with step one.\n\nShall I also update the tests?")
        row = self.board()["s1"]
        self.assertEqual((row["column"], row["kind"]), ("needs", "question"))
        self.assertIn("update the tests", row["detail"])
        self.assertEqual(row["name"], "refactor the parser")
        self.assertEqual(row["app"], "Ghostty")

    def test_permission_request_then_approval(self):
        self.live("s2")
        self.fire("s2", "UserPromptSubmit", prompt="deploy")
        self.fire("s2", "PermissionRequest", tool_name="Bash", tool_input={"command": "sf project deploy start"})
        row = self.board()["s2"]
        self.assertEqual((row["column"], row["kind"]), ("needs", "permission"))
        self.assertIn("sf project deploy start", row["detail"])
        self.fire("s2", "PostToolUse", tool_name="Bash", tool_input={"command": "sf project deploy start"})
        self.assertEqual(self.board()["s2"]["column"], "working")

    def test_written_document_goes_to_review_then_seen(self):
        self.live("s3")
        self.fire("s3", "UserPromptSubmit", prompt="write the design")
        self.fire("s3", "PostToolUse", tool_name="Write", tool_input={"file_path": "/repo/openspec/changes/x/design.md"})
        self.fire("s3", "PostToolUse", tool_name="Write", tool_input={"file_path": "/repo/src/Foo.cls"})
        self.fire("s3", "PostToolUse", tool_name="Write", tool_input={"file_path": "/tmp/a/scratchpad/notes.md"})
        self.fire("s3", "Stop", last_assistant_message="The design is written.")
        row = self.board()["s3"]
        self.assertEqual(row["column"], "review")
        self.assertEqual(row["files"], ["/repo/openspec/changes/x/design.md"])
        subprocess.run([sys.executable, str(CLI), "seen", "s3"], env=self.env, check=True)
        row = self.board()["s3"]
        self.assertEqual((row["column"], row["seen"]), ("done", True))

    def test_desktop_wrap_up_ask_and_plain_done(self):
        self.live("s4", entrypoint="claude-desktop", name="ABC-329 design", hostSessionId="local_abc")
        env = {**self.env, "CLAUDE_CODE_ENTRYPOINT": "claude-desktop"}
        self.env, saved = env, self.env
        self.fire("s4", "UserPromptSubmit", prompt="go")
        self.fire("s4", "PreToolUse", tool_name="mcp__ccd_turn__wrap_up", tool_input={"recap": "Built it.", "ask": "Commit the change?"})
        self.fire("s4", "Stop", last_assistant_message="All built.")
        row = self.board()["s4"]
        self.assertEqual((row["column"], row["detail"], row["app"], row["name"]), ("needs", "Commit the change?", "Desktop", "ABC-329 design"))
        self.fire("s4", "UserPromptSubmit", prompt="no, thanks")
        self.fire("s4", "PreToolUse", tool_name="mcp__ccd_turn__wrap_up", tool_input={"recap": "Left it uncommitted."})
        self.fire("s4", "Stop", last_assistant_message="Fine.")
        row = self.board()["s4"]
        self.assertEqual((row["column"], row["detail"]), ("done", "Left it uncommitted."))
        self.env = saved

    def test_dead_and_ended_sessions_disappear(self):
        self.live("s5", pid=999999)  # no such process
        self.fire("s5", "UserPromptSubmit", prompt="x")
        self.live("s6")
        self.fire("s6", "SessionEnd", reason="exit")
        board = self.board()
        self.assertNotIn("s5", board)
        self.assertNotIn("s6", board)

    def test_untracked_live_session_is_listed(self):
        self.live("s7", status="busy", name="old session")
        row = self.board()["s7"]
        self.assertEqual((row["column"], row["tracked"]), ("working", False))

    def test_app_key_and_injected_prompts_and_markdown(self):
        self.live("s8", entrypoint="claude-vscode")
        self.env["CLAUDE_CODE_ENTRYPOINT"] = "claude-vscode"
        self.fire("s8", "UserPromptSubmit", prompt="review the PR")
        self.fire("s8", "UserPromptSubmit", prompt='<agent-message from="a6ec"> [Subagent hand-back] report')
        row = self.board()["s8"]
        self.assertEqual((row["app_key"], row["last_prompt"], row["prompt_count"]), ("vscode", "review the PR", 1))
        self.fire("s8", "Stop", last_assistant_message="PR [acme/app#149](https://github.com/x) needs **one** `approval`.")
        self.assertEqual(self.board()["s8"]["detail"], "PR acme/app#149 needs one approval.")

    def test_subagents_get_their_own_working_rows(self):
        self.live("s9")
        self.fire("s9", "UserPromptSubmit", prompt="find the trigger handlers")
        self.fire("s9", "PreToolUse", tool_name="Agent",
                  tool_input={"description": "Search the repo for handlers", "subagent_type": "Explore", "run_in_background": True})
        self.fire("s9", "SubagentStart", agent_id="a1", agent_type="Explore")
        self.fire("s9", "PostToolUse", agent_id="a1", agent_type="Explore", tool_name="Grep", tool_input={"pattern": "TriggerHandler"})
        out = json.loads(subprocess.run([sys.executable, str(CLI), "json"], env=self.env, capture_output=True, text=True, check=True).stdout)
        ids = [r["id"] for r in out["sessions"]]
        self.assertEqual(ids.index("s9:a1"), ids.index("s9") + 1)  # right under its parent
        agent = {r["id"]: r for r in out["sessions"]}["s9:a1"]
        self.assertEqual((agent["column"], agent["name"], agent["agent_type"], agent["background"], agent["tools"]),
                         ("working", "Search the repo for handlers", "Explore", True, 1))
        self.assertEqual(agent["detail"], "Grep: TriggerHandler")
        self.assertEqual((out["counts"]["working"], out["counts"]["agents"]), (1, 1))  # sessions and agents apart

        # The parent ends its turn on a question; the background agent keeps going and must not clear it.
        self.fire("s9", "Stop", last_assistant_message="Shall I refactor them?")
        self.fire("s9", "PostToolUse", agent_id="a1", agent_type="Explore", tool_name="Read", tool_input={"file_path": "/x.cls"})
        board = self.board()
        self.assertEqual(board["s9"]["column"], "needs")
        self.assertEqual((board["s9:a1"]["column"], board["s9:a1"]["parent_name"]), ("working", "find the trigger handlers"))

        # A permission prompt inside the agent needs you; its next tool call means it was answered.
        self.fire("s9", "UserPromptSubmit", prompt="yes")
        self.fire("s9", "PermissionRequest", agent_id="a1", agent_type="Explore", tool_name="Bash", tool_input={"command": "ls"})
        self.assertIn("Subagent Explore", self.board()["s9"]["detail"])
        self.fire("s9", "PostToolUse", agent_id="a1", agent_type="Explore", tool_name="Bash", tool_input={"command": "ls"})
        self.assertEqual(self.board()["s9"]["column"], "working")

        self.fire("s9", "SubagentStop", agent_id="a1", agent_type="Explore", agent_transcript_path="/t.jsonl")
        self.assertNotIn("s9:a1", self.board())
        found = subprocess.run([sys.executable, str(CLI), "seen", "s9"], env=self.env, capture_output=True, text=True)
        self.assertEqual(found.returncode, 0)  # a session prefix still finds the session, not its agents

    def state(self, sid, **changes):
        """Rewrites fields in a session's hook state, to make time pass."""
        path = Path(self.env["CLAUDE_RADAR_DIR"]) / "sessions" / f"{sid}.json"
        s = json.loads(path.read_text())
        for key, value in changes.items():
            if key == "agent_last_at":
                for a in s["agents"].values():
                    a["last_at"] = value
            else:
                s[key] = value
        path.write_text(json.dumps(s))

    def test_turn_that_ends_while_a_subagent_runs_stays_working(self):
        self.live("w1")
        self.fire("w1", "UserPromptSubmit", prompt="apply the review fixes")
        # No run_in_background: Claude Code starts subagents in the background by default.
        self.fire("w1", "PreToolUse", tool_name="Agent",
                  tool_input={"description": "Apply PR 202 review fixes", "subagent_type": "vcrm-sf:developer"})
        self.fire("w1", "SubagentStart", agent_id="b1", agent_type="vcrm-sf:developer")
        self.fire("w1", "PostToolUse", tool_name="Write", tool_input={"file_path": "/repo/docs/review.md"})
        self.fire("w1", "Stop", last_assistant_message="The developer agent is applying the fixes.")
        out = json.loads(subprocess.run([sys.executable, str(CLI), "json"], env=self.env, capture_output=True, text=True, check=True).stdout)
        ids = [r["id"] for r in out["sessions"]]
        board = {r["id"]: r for r in out["sessions"]}
        self.assertEqual((board["w1"]["column"], board["w1"]["kind"], board["w1"]["detail"]),
                         ("working", "agents", "Waiting for subagent: Apply PR 202 review fixes"))
        self.assertEqual(ids.index("w1:b1"), ids.index("w1") + 1)  # still linked right under its session
        self.assertTrue(board["w1:b1"]["background"])  # the turn ended while it ran

        # The hand-back starts the next turn; the document from the first turn still goes to review.
        self.fire("w1", "PostToolUse", agent_id="b1", agent_type="vcrm-sf:developer", tool_name="Edit",
                  tool_input={"file_path": "/repo/src/Foo.cls"})
        self.fire("w1", "SubagentStop", agent_id="b1", agent_type="vcrm-sf:developer", agent_transcript_path="/t")
        self.assertEqual(self.board()["w1"]["column"], "working")  # waits for the hand-back
        self.fire("w1", "UserPromptSubmit", prompt='<agent-message from="b1">\n[Subagent hand-back] Fixes applied.')
        self.fire("w1", "Stop", last_assistant_message="All review fixes are applied.")
        row = self.board()["w1"]
        self.assertEqual((row["column"], row["files"], row["prompt_count"]), ("review", ["/repo/docs/review.md"], 1))
        self.assertNotIn("w1:b1", self.board())

    def test_waiting_session_is_done_when_no_hand_back_comes(self):
        self.live("w2")
        self.fire("w2", "UserPromptSubmit", prompt="research it")
        self.fire("w2", "SubagentStart", agent_id="c1", agent_type="Explore")
        self.fire("w2", "Stop", last_assistant_message="Researching in the background.")
        self.fire("w2", "SubagentStop", agent_id="c1", agent_type="Explore", agent_transcript_path="/t")
        self.state("w2", updated_at=time.time() - 300)  # no hand-back for five minutes
        row = self.board()["w2"]
        self.assertEqual((row["column"], row["detail"]), ("done", "Subagents finished"))
        self.assertEqual([h[0] for h in row["history"]], ["working", "done"])

        # A subagent that lost its stop event: the session is done once the subagent goes stale.
        self.live("w3")
        self.fire("w3", "UserPromptSubmit", prompt="look around")
        self.fire("w3", "SubagentStart", agent_id="d1", agent_type="Explore")
        self.fire("w3", "Stop", last_assistant_message="Started a search.")
        self.state("w3", agent_last_at=time.time() - 30 * 60, updated_at=time.time() - 30 * 60)
        self.assertEqual(self.board()["w3"]["column"], "done")
        self.assertNotIn("w3:d1", self.board())

    def test_history_for_the_timeline(self):
        self.live("h1")
        self.fire("h1", "UserPromptSubmit", prompt="go")
        self.fire("h1", "PostToolUse", tool_name="Bash", tool_input={"command": "ls"})  # no state change: no entry
        self.fire("h1", "SubagentStart", agent_id="x1", agent_type="Explore")
        self.fire("h1", "SubagentStop", agent_id="x1", agent_type="Explore", agent_transcript_path="/t")
        self.fire("h1", "Stop", last_assistant_message="Shall I go on?")
        row = self.board()["h1"]
        self.assertEqual([h[0] for h in row["history"]], ["working", "needs_you"])
        self.assertEqual(len(row["agent_history"]), 1)
        kind, _, start, end, background = row["agent_history"][0]
        self.assertEqual((kind, background), ("Explore", False))
        self.assertLessEqual(start, end)
        self.live("h2", status="busy")  # untracked: one span for its current state
        self.assertEqual(self.board()["h2"]["history"][0][0], "working")

    def test_placeholder_names_give_way_to_the_tab_title(self):
        transcript = Path(self.tmp.name) / "t.jsonl"
        lines = [{"type": "user", "message": {"content": "hi"}}, {"type": "ai-title", "aiTitle": "Old title"},
                 {"type": "ai-title", "aiTitle": "Apex test script generation"}]
        transcript.write_text("".join(json.dumps(l) + "\n" for l in lines))
        folder = ROOT.name.lower()
        self.live("v1", name=f"{folder}-a7", entrypoint="claude-vscode")
        self.live("d1", name="Claude activity dashboard", entrypoint="claude-desktop")
        for sid in ("v1", "d1"):
            self.fire(sid, "UserPromptSubmit", prompt="hi", transcript_path=str(transcript))
        board = self.board()
        self.assertEqual(board["v1"]["name"], "Apex test script generation")   # placeholder replaced
        self.assertEqual(board["d1"]["name"], "Claude activity dashboard")     # a real name stays
        # Appended later: only the new part is read, and a /rename wins over everything.
        with transcript.open("a") as f:
            f.write(json.dumps({"type": "custom-title", "customTitle": "My own name"}) + "\n")
        board = self.board()
        self.assertEqual((board["v1"]["name"], board["d1"]["name"]), ("My own name", "My own name"))

    def test_vscode_session_opens_the_window_it_started_in(self):
        sys.path.insert(0, str(ROOT / "session_radar"))
        import core
        from unittest import mock
        transcript = Path(self.tmp.name) / "w.jsonl"
        lines = [{"type": "summary"}, {"type": "attachment", "data": {"cwd": "/elsewhere"}},
                 {"type": "user", "cwd": "/repo/Miele"}, {"type": "user", "cwd": "/repo/Miele-ps3-1"}]
        transcript.write_text("".join(json.dumps(l) + "\n" for l in lines))
        row = {"id": "w1", "app": "VS Code", "entrypoint": "claude-vscode", "cwd": "/repo/Miele-ps3-1",
               "transcript_path": str(transcript)}
        agent = {**row, "id": "w1:a1", "parent_id": "w1", "transcript_path": None}
        done = lambda args, check=False: subprocess.CompletedProcess(args, 0)
        with mock.patch.object(core.subprocess, "run", side_effect=done) as run, mock.patch.object(core, "mark_seen"):
            core.open_session(row)                                  # moved into a worktree: its start folder
            core.open_session(agent, row)                           # a subagent: its session's window
            core.open_session({**row, "transcript_path": None})     # no transcript: the current folder
        calls = [c.args[0] for c in run.call_args_list]
        vscode = ["open", "-b", "com.microsoft.VSCode"]
        self.assertEqual(calls, [vscode + ["/repo/Miele"]] * 2 + [vscode + ["/repo/Miele-ps3-1"]])

    def test_bad_input_never_fails_the_hook(self):
        r = subprocess.run([sys.executable, str(HOOK)], input="not json", text=True, env=self.env, capture_output=True)
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))

    def test_install_keeps_other_hooks_and_uninstall_removes_only_radar(self):
        other = {"matcher": "Write", "hooks": [{"type": "command", "command": "bash other.sh"}]}
        self.settings.write_text(json.dumps({"model": "opus", "hooks": {"PostToolUse": [other]}}))
        for _ in range(2):  # twice: install must not duplicate
            subprocess.run([sys.executable, str(CLI), "install"], env=self.env, check=True, capture_output=True)
        s = json.loads(self.settings.read_text())
        self.assertEqual(len(s["hooks"]["PostToolUse"]), 2)
        self.assertEqual(len(s["hooks"]["Stop"]), 1)
        subprocess.run([sys.executable, str(CLI), "uninstall"], env=self.env, check=True, capture_output=True)
        s = json.loads(self.settings.read_text())
        self.assertEqual(s, {"model": "opus", "hooks": {"PostToolUse": [other]}})

    def status(self, **env):
        out = subprocess.run([sys.executable, str(CLI), "hooks-status"], env={**self.env, **env},
                             check=True, capture_output=True, text=True).stdout
        return json.loads(out)

    def test_hooks_use_the_given_python_and_replace_older_builds(self):
        old = {"hooks": [{"type": "command", "command": 'python3 "/old/claude_radar/hook.py"'}]}
        self.settings.write_text(json.dumps({"hooks": {"Stop": [old], "SessionStart": [old]}}))
        self.assertFalse(self.status()["current"])  # older build's hooks: present but not current
        env = {**self.env, "RADAR_PYTHON": "/opt/homebrew/bin/python3"}
        subprocess.run([sys.executable, str(CLI), "install"], env=env, check=True, capture_output=True)
        s = json.loads(self.settings.read_text())
        self.assertEqual(len(s["hooks"]["Stop"]), 1)  # the old entry is gone, not doubled
        command = s["hooks"]["Stop"][0]["hooks"][0]["command"]
        self.assertTrue(command.startswith('"/opt/homebrew/bin/python3" "') and command.endswith('session_radar/hook.py"'))
        st = self.status(RADAR_PYTHON="/opt/homebrew/bin/python3")
        self.assertTrue(st["current"])
        self.assertEqual(st["missing"], [])
        self.assertFalse(self.status(RADAR_PYTHON="/usr/local/bin/python3")["current"])  # another Python: repair



class ContextTest(Harness):
    """Context size of the latest main-thread reply, read from the end of the transcript."""

    def transcript(self, *entries, junk_kb=0):
        path = Path(self.tmp.name) / "t.jsonl"
        lines = ['{"type": "user", "message": {"content": "' + "x" * 1024 + '"}}'] * junk_kb
        lines += [json.dumps(e) for e in entries]
        path.write_text("\n".join(lines) + "\n")
        return str(path)

    @staticmethod
    def reply(model, cached, fresh=2, created=0, sidechain=False):
        return {"type": "assistant", "isSidechain": sidechain, "message": {"model": model, "usage": {
            "input_tokens": fresh, "cache_creation_input_tokens": created, "cache_read_input_tokens": cached,
            "output_tokens": 500}}}

    def test_latest_main_reply_counts_and_subagents_do_not(self):
        self.live("c1")
        path = self.transcript(self.reply("claude-opus-5-5", 100_000),
                               self.reply("claude-opus-5-5", 330_231, created=1447),
                               self.reply("claude-haiku-4-5", 9_000, sidechain=True),  # a subagent's own context
                               {"type": "assistant", "message": {"model": "<synthetic>", "usage": {"input_tokens": 0}}},
                               junk_kb=1200)  # pushes the start of the file past the first 1 MB read
        self.fire("c1", "UserPromptSubmit", prompt="go", transcript_path=path)
        self.fire("c1", "Stop", last_assistant_message="Done.")
        row = self.board()["c1"]
        self.assertEqual((row["context_tokens"], row["model"], row["context_window"]), (331_680, "Opus 5.5", None))

    def test_window_only_where_the_model_id_states_it(self):
        self.live("c2")
        path = self.transcript(self.reply("claude-sonnet-5-5[1m]", 250_000))
        self.fire("c2", "SessionStart", source="resume", transcript_path=path)
        row = self.board()["c2"]
        self.assertEqual((row["context_tokens"], row["model"], row["context_window"]), (250_002, "Sonnet 5.5", 1_000_000))

    def test_missing_transcript_leaves_no_context(self):
        self.live("c3")
        self.fire("c3", "Stop", last_assistant_message="Done.", transcript_path="/nonexistent/t.jsonl")
        self.assertIsNone(self.board()["c3"]["context_tokens"])


if __name__ == "__main__":
    unittest.main()


def pr_node(number, title, author, head, **extra):
    """A pull request as GitHub's GraphQL search returns it (only the fields radar reads)."""
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    node = {
        "number": number, "title": title, "url": f"https://github.com/acme/app/pull/{number}", "isDraft": False,
        "createdAt": now, "updatedAt": now, "additions": 10, "deletions": 2, "changedFiles": 3,
        "baseRefName": "stage", "headRefName": head, "headRefOid": f"abcd000{number}", "mergeable": "MERGEABLE",
        "reviewDecision": "REVIEW_REQUIRED", "repository": {"nameWithOwner": "acme/app"}, "author": {"login": author},
        "assignees": {"nodes": []}, "reviewRequests": {"nodes": []}, "latestReviews": {"nodes": []},
        "comments": {"totalCount": 0, "nodes": []},
        "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS", "contexts": {"nodes": []}}}}]},
    }
    node.update(extra)
    return node


def check_runs(*runs):
    return {"nodes": [{"commit": {"statusCheckRollup": {"state": "X", "contexts": {"nodes": [
        {"__typename": "CheckRun", "name": n, "status": s, "conclusion": c} for n, s, c in runs]}}}}]}


class PullRequestTest(Harness):
    def setUp(self):
        super().setUp()
        review = ("## PR Review\n\n| a | b |\n|---|---|\n| x | y |\n\n"
                  "<!-- vcrm-pr-review sha=abcd0002 verdict=REQUEST_CHANGES -->")
        old = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 30 * 86400))
        nodes = [
            # Mine, one check failed: waits on me.
            pr_node(1, "ABC-101: my change", "me", "feature/my-change",
                    commits=check_runs(("Validate", "COMPLETED", "SUCCESS"), ("Validate", "COMPLETED", "SKIPPED"),
                                       ("Analyzer", "COMPLETED", "FAILURE"))),
            # Someone else's, my review requested, AI review on the current head.
            pr_node(2, "ABC-102 their change", "alice", "feature/other",
                    reviewRequests={"nodes": [{"requestedReviewer": {"__typename": "User", "login": "me"}}]},
                    comments={"totalCount": 2, "nodes": [
                        {"body": review, "bodyHTML": "<h2>PR Review</h2><table></table>", "url": "u", "createdAt": old}]}),
            # Approved, green, mine: ready. AI review of an older commit.
            pr_node(3, "Ready one", "me", "feature/ready", reviewDecision="APPROVED",
                    comments={"totalCount": 1, "nodes": [
                        {"body": "<!-- vcrm-pr-review sha=0123abc verdict=APPROVE -->", "bodyHTML": "", "url": "u", "createdAt": old}]}),
            # Someone else's, checks still running.
            pr_node(4, "Busy", "bob", "feature/busy", commits=check_runs(("Validate", "IN_PROGRESS", None))),
            # Nobody touched it for a month.
            pr_node(5, "Old one", "carol", "feature/old", updatedAt=old, createdAt=old),
        ]
        response = {"data": {"viewer": {"login": "me"}, "mine": {"nodes": nodes[:3]}, "watched": {"nodes": nodes}}}
        bindir = Path(self.tmp.name) / "bin"
        bindir.mkdir()
        (bindir / "response.json").write_text(json.dumps(response))
        gh = bindir / "gh"
        gh.write_text(f"#!/bin/sh\necho \"$@\" > {bindir}/args.txt\ncat {bindir}/response.json\n")
        gh.chmod(0o755)
        self.bindir = bindir
        self.env["PATH"] = f"{bindir}:{self.env['PATH']}"
        (Path(self.env["CLAUDE_RADAR_DIR"])).mkdir(parents=True, exist_ok=True)

    def prs(self):
        out = subprocess.run([sys.executable, str(CLI), "prs-json", "--refresh"], env=self.env, capture_output=True, text=True, check=True)
        return json.loads(out.stdout)

    def test_groups_checks_and_ai_review(self):
        subprocess.run([sys.executable, str(CLI), "prs", "watch", "acme/app"], env=self.env, capture_output=True, check=True)
        data = self.prs()
        self.assertIsNone(data["error"])
        by = {p["number"]: p for p in data["prs"]}
        self.assertEqual(len(by), 5)  # PRs found by both searches appear once
        self.assertEqual((by[1]["group"], by[1]["reason"]), ("you", "1 check failed"))
        self.assertEqual(by[1]["checks"]["failing"], ["Analyzer"])
        self.assertEqual(by[1]["checks"]["passed"], 1)  # skipped run of the same name does not count twice
        self.assertEqual(by[1]["jira"], "ABC-101")
        self.assertEqual((by[2]["group"], by[2]["requested_me"]), ("you", True))
        self.assertEqual((by[2]["ai_review"]["verdict"], by[2]["ai_review"]["current"]), ("REQUEST_CHANGES", True))
        self.assertIn("<table>", by[2]["ai_review"]["html"])
        self.assertEqual(by[3]["group"], "ready")
        self.assertFalse(by[3]["ai_review"]["current"])
        self.assertEqual((by[4]["group"], by[4]["reason"]), ("others", "checks running"))
        self.assertEqual(by[5]["group"], "stale")
        self.assertEqual([p["group"] for p in data["prs"]], ["you", "you", "others", "ready", "stale"])
        args = (self.bindir / "args.txt").read_text()
        self.assertIn("repo:acme/app", args)
        self.assertIn("involves:@me", args)

    def test_only_involved_prs_when_others_are_off(self):
        Path(self.env["CLAUDE_RADAR_DIR"], "config.json").write_text(json.dumps({"pr_repos": ["acme/app"], "pr_others": False}))
        self.assertEqual(sorted(p["number"] for p in self.prs()["prs"]), [1, 2, 3])

    def test_session_on_the_pr_branch_carries_the_pr(self):
        self.prs()
        # A checkout of its own: CI runs pull requests on a detached HEAD, so this repo may be on no branch.
        checkout = Path(self.tmp.name) / "checkout"
        (checkout / ".git").mkdir(parents=True)
        (checkout / ".git" / "HEAD").write_text("ref: refs/heads/feature/my-change\n")
        self.live("s9", cwd=str(checkout))
        self.fire("s9", "UserPromptSubmit", cwd=str(checkout), prompt="fix the analyzer finding")
        pr = self.board()["s9"]["pr"]
        self.assertEqual((pr["number"], pr["group"], pr["checks"]["failed"]), (1, "you", 1))

    def test_switched_off_reads_nothing_and_clears_the_list(self):
        self.prs()
        Path(self.env["CLAUDE_RADAR_DIR"], "config.json").write_text(json.dumps({"prs_enabled": False}))
        (self.bindir / "args.txt").unlink()
        data = self.prs()
        self.assertEqual((data["prs"], data.get("disabled")), ([], True))
        self.assertFalse((self.bindir / "args.txt").exists())  # gh was not called

    def test_gh_failure_keeps_the_last_list(self):
        self.prs()
        (self.bindir / "gh").write_text("#!/bin/sh\necho 'HTTP 401: Bad credentials' >&2\nexit 1\n")
        data = self.prs()
        self.assertIn("Bad credentials", data["error"])
        self.assertEqual(len(data["prs"]), 3)
