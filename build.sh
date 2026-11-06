#!/usr/bin/env bash
#
# Builds "AI Session Radar.app" without Xcode (the Command Line Tools are enough).
#
#   ./build.sh              build build/AI Session Radar.app
#   ./build.sh --install    also copy it to /Applications and launch it
#   ./build.sh --debug      build the debug configuration
#   ./build.sh --universal  build for Apple silicon and Intel (needs Xcode, not just the CLT)
#   ./build.sh --version X  stamp X as the app version (the release workflow passes the tag)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
NAME="AI Session Radar"
APP="$BUILD_DIR/$NAME.app"
CONFIG=release
BUNDLE_ID=com.robinwijnen.AISessionRadar

DO_INSTALL=0
ARCH_FLAGS=()
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) DO_INSTALL=1 ;;
    --debug) CONFIG=debug ;;
    --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
    --version)
      VERSION="${2:-}"
      [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "--version needs a number like 1.2.0" >&2; exit 64; }
      shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

echo "==> Compiling ($CONFIG${ARCH_FLAGS:+, universal})"
# `${ARCH_FLAGS[@]+...}`: an empty array is an unbound variable under `set -u` in the
# bash 3.2 that macOS ships.
swift build -c "$CONFIG" --product AISessionRadar ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AISessionRadar" "$APP/Contents/MacOS/AISessionRadar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The Python package the hooks and the data layer run. The app copies it to
# ~/.claude/radar/lib whenever its build number changes, and the hooks point at that copy.
RADAR="$APP/Contents/Resources/radar"
mkdir -p "$RADAR/session_radar" "$RADAR/bin"
cp "$ROOT"/session_radar/*.py "$ROOT"/session_radar/*.html "$RADAR/session_radar/"
cp "$ROOT/bin/radar" "$RADAR/bin/radar"
chmod +x "$RADAR/bin/radar"

# A unique build number: the app re-copies the Python package when it changes, and icon
# and Launch Services caches key on it too.
BUILD_NUMBER="$(date +%Y%m%d%H%M%S)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist" >/dev/null
# The in-app updater compares this against the release tag and refuses a download whose
# bundle says anything else, so a release build must carry the tag's version.
if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" >/dev/null
fi
echo "    version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"), build $BUILD_NUMBER"

echo "==> Building icon"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
if swift "$ROOT/Tools/make-icon.swift" "$ICONSET/icon_512x512@2x.png" spectrum >/dev/null 2>&1; then
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    [[ $s -lt 512 ]] && sips -z $((s * 2)) $((s * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" && echo "    AppIcon.icns"
else
  echo "    skipped (icon generation unavailable — the app still builds)"
fi
rm -rf "$ICONSET"

# Prefer a real Apple-issued identity: macOS only allows notifications for an app whose
# signature carries a Team Identifier, and the in-app updater only installs an update signed
# by the same team. A free Apple ID is enough (Xcode > Settings > Accounts > Manage Certificates).
# `|| true`: with `set -e` and `pipefail`, grep finding nothing would abort the script.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"(Apple Development|Apple Distribution|Developer ID Application)[^"]*"' \
  | head -1 | tr -d '"' || true)"

if [[ -n "$IDENTITY" ]]; then
  echo "==> Signing as $IDENTITY"
  if codesign --force --deep --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1; then
    TEAM="$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    echo "    signed (TeamIdentifier=${TEAM:-unknown})"
  else
    echo "    codesign failed; falling back to ad-hoc"
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || true
  fi
else
  echo "==> Signing (ad-hoc — no Apple signing identity found; notifications and updates need one)"
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 \
    && echo "    signed" || echo "    codesign failed; the app will still run locally"
fi

echo "==> Built $APP"

if [[ "$DO_INSTALL" == 1 ]]; then
  TARGET_DIR=/Applications
  if [[ ! -w "$TARGET_DIR" ]]; then
    TARGET_DIR="$HOME/Applications"
    mkdir -p "$TARGET_DIR"
    echo "==> /Applications is not writable; installing to $TARGET_DIR"
  fi
  INSTALLED="$TARGET_DIR/$NAME.app"
  if pgrep -f "$INSTALLED/Contents/MacOS/AISessionRadar" >/dev/null 2>&1; then
    echo "==> Quitting the running copy"
    osascript -e "tell application \"$NAME\" to quit" 2>/dev/null || pkill -x AISessionRadar || true
    sleep 1
  fi
  echo "==> Installing to $INSTALLED"
  rm -rf "$INSTALLED"
  cp -R "$APP" "$INSTALLED"
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$INSTALLED"
  touch "$INSTALLED"
  echo "==> Launching"
  open "$INSTALLED"
  echo
  echo "AI Session Radar is in the menu bar (radar icon). On first launch it opens a welcome window."
fi
