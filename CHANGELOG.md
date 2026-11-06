# Changelog

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
