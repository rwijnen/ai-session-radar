# Changelog

## 1.2.0

- The Timeline has a fourth range, Custom, with a menu to pick how far back it looks: 1 to 24
  hours. The hook keeps a day of history, so 24 hours is as far back as there is anything to show.
- On longer ranges the time axis marks every 2 or 3 hours on whole local hours, so it keeps eight
  labels or fewer, and shows the weekday at midnight.

## 1.1.0

- Every row in Pull requests has a button that opens the PR in your default browser, and the
  same in its right-click menu. Double-clicking the row still works too.

## 1.0.1

- Opening a VS Code session no longer starts a second VS Code. The folder goes to the running
  VS Code through `open` instead of the `code` command, which on macOS always started an extra
  VS Code process that closed itself again.
- Opening a VS Code session that moved into a git worktree focuses the window it started in,
  instead of opening a new window on the worktree.

## 1.0.0

First public release.

- Every Claude Code session on the Mac (Desktop app, VS Code extension, terminals) in one menu
  bar app, sorted by who has to act: Needs you, Ready to review, Working, Done.
- Board, Graph, Timeline and Pull requests views; subagents shown under their session.
- Open pull requests through the GitHub CLI, grouped by who has to act, with checks, reviews and
  the AI review comment in a hover popover.
- Alerts: the menu bar icon jumps and a notification appears when something waits on you.
- First-run window that checks Python, installs the Claude Code hooks (with a backup of
  settings.json) and checks the GitHub CLI; Settings to switch every optional feature off.
- Updates itself from GitHub Releases, installing only builds signed by the same Apple team.
