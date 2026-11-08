#!/usr/bin/env bash
#
# Fails a pull request that changes the app without making it a release.
#
#   .github/scripts/check-version-bump.sh <base-ref>
#
# A release follows the version in Resources/Info.plist: merging to main publishes only when
# CFBundleShortVersionString names a version that has no tag yet. So a PR that changes what
# ships must raise that version above the base branch's and give it a CHANGELOG heading.
# Anything else (docs, tests, CI) needs neither, so a README fix does not become a version.
# CFBundleVersion is not checked: build.sh stamps its own on every build.
set -euo pipefail

base="${1:?usage: check-version-bump.sh <base-ref>}"
plist=Resources/Info.plist

changed="$(git diff --name-only "$base"...HEAD)"
app_changes="$(printf '%s\n' "$changed" | grep -E '^(Sources|Resources|session_radar|bin)/|^(build\.sh|Package\.swift)$' || true)"
if [[ -z "$app_changes" ]]; then
  echo "No change to what ships: no release needed."
  exit 0
fi
echo "App files changed:"
printf '%s\n' "$app_changes" | sed 's/^/  /'

read_version() {
  # loads, not load: this reads from a pipe, and plistlib.load needs a stream it can seek.
  python3 -c 'import plistlib, sys; print(plistlib.loads(sys.stdin.buffer.read())["CFBundleShortVersionString"])'
}
base_version="$(git show "$base:$plist" | read_version)"
head_version="$(read_version < "$plist")"
echo "Version: $base_version on the base, $head_version here"

problems=0
highest="$(printf '%s\n%s\n' "$base_version" "$head_version" | sort -V | tail -1)"
if [[ "$head_version" == "$base_version" || "$highest" != "$head_version" ]]; then
  echo "::error file=$plist::This PR changes the app, so CFBundleShortVersionString must go up from $base_version (it is $head_version). Fix: patch, feature: minor, breaking: major. Otherwise merging publishes nothing."
  problems=1
fi
if git rev-parse --verify --quiet "refs/tags/v$head_version" > /dev/null; then
  echo "::error file=$plist::v$head_version is already tagged. Pick the next version."
  problems=1
fi
if ! grep -qE "^## ${head_version}( |$)" CHANGELOG.md; then
  echo "::error file=CHANGELOG.md::CHANGELOG.md has no '## $head_version' heading."
  problems=1
fi

if (( problems )); then
  echo "See 'Publishing a release' in README.md."
  exit 1
fi
echo "Merging this publishes AI Session Radar $head_version."
