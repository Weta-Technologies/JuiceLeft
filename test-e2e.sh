#!/bin/bash
# ./test-e2e.sh [dir] — every user-facing function end to end (E2E.swift, E2ESteps.swift), on a throwaway copy of build/JuiceLeft.app:
# its own bundle id (io.github.cyborgfingers.juiceleft.e2e — so the installed JuiceLeft, its settings, its helper and its
# notification permission are never involved), no URL-scheme registration, ad-hoc signed; inside, the Mac is behind fakes
# (screen, keyboard, helper, charge limit, light, the battery item's preferences, notifications, login item, accessories, update feed).
# Prints one row per function and exits 0 only when every row passed. The copy and its defaults domain go afterwards.
set -euo pipefail
cd "$(dirname "$0")"
APP=JuiceLeft
ID=io.github.cyborgfingers.juiceleft.e2e
[[ -n "${SKIP_BUILD:-}" ]] || ./build.sh >/dev/null
OUT=${1:-$(mktemp -d)}
mkdir -p "$OUT"
T=$(mktemp -d)
cleanup() { rm -r "$T"; defaults delete "$ID" >/dev/null 2>&1 || true; defaults delete "$ID.settings" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cp -R "build/$APP.app" "$T/"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Delete :CFBundleURLTypes" "$T/$APP.app/Contents/Info.plist"
codesign --force --sign - --options runtime "$T/$APP.app" 2>/dev/null
"$T/$APP.app/Contents/MacOS/$APP" --e2e "$OUT"
