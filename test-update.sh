#!/bin/bash
# ./test-update.sh — the in-app updater end to end, without GitHub and without touching the installed app or its settings.
#
# Builds the app; makes a "new version" of it (9.9.9), zips and signs that with a throwaway key; serves it, its
# signature and a fake releases/latest feed from a local web server; then runs a COPY of the app from a temp folder
# with `--update-test <feed> <public key> <log>`, which does exactly what Update Now does: check → download → verify
# → stage → swap → relaunch. The relaunched copy (now 9.9.9) checks the feed again, finds nothing newer and exits.
# Then the same with a tampered zip and with the wrong key, both of which must be refused with the copy untouched.
set -euo pipefail
cd "$(dirname "$0")"
APP=JuiceLeft
DOMAIN=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Info.plist)
ORIG=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
./build.sh >/dev/null
W=$(mktemp -d)
PORT=$((20000 + RANDOM % 20000))
SERVER=""
cleanup() { [[ -n "$SERVER" ]] && kill "$SERVER" 2>/dev/null; defaults delete "$DOMAIN.update-test" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
fail() { echo "FAIL: $*"; [[ -f "$W/log.txt" ]] && sed 's/^/     /' "$W/log.txt"; exit 1; }

[[ build/sign-update -nt tools/sign-update.swift ]] || swiftc -O tools/sign-update.swift -o build/sign-update
PUB=$(build/sign-update testkey "$W/key")
OTHER=$(build/sign-update testkey "$W/otherkey")

# The "new version": this build with its version set to 9.9.9, re-signed with the same identity as the build (the
# Info.plist is covered by the signature, and a Developer ID build only accepts updates from the same developer).
SIGN_APP=${CF_SIGN_APP:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application:/ {print $2; exit}')}
mkdir -p "$W/new" "$W/site"
cp -R "build/$APP.app" "$W/new/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 9.9.9" "$W/new/$APP.app/Contents/Info.plist"
codesign --force --sign "${SIGN_APP:--}" --options runtime "$W/new/$APP.app" 2>/dev/null
ditto -c -k --keepParent "$W/new/$APP.app" "$W/site/$APP.app.zip"
build/sign-update sign "$W/site/$APP.app.zip" --key-file "$W/key/private.key" >/dev/null
cat > "$W/site/latest.json" <<EOF
{"tag_name":"v9.9.9","draft":false,"prerelease":false,"html_url":"http://127.0.0.1:$PORT/notes","body":"## Test release\\n- the updater works",
 "assets":[{"name":"$APP.pkg","browser_download_url":"http://127.0.0.1:$PORT/$APP.pkg"},
           {"name":"$APP.app.zip","browser_download_url":"http://127.0.0.1:$PORT/$APP.app.zip"},
           {"name":"$APP.app.zip.sig","browser_download_url":"http://127.0.0.1:$PORT/$APP.app.zip.sig"}]}
EOF
(cd "$W/site" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER=$!
disown
sleep 1

before=$(defaults export "$DOMAIN" - 2>/dev/null || echo none)   # the real settings: must come out identical
fresh_copy() { rm -rf "$W/Apps"; mkdir -p "$W/Apps"; cp -R "build/$APP.app" "$W/Apps/"; : > "$W/log.txt"; }
version() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$W/Apps/$APP.app/Contents/Info.plist"; }
run() { "$W/Apps/$APP.app/Contents/MacOS/$APP" --update-test "http://127.0.0.1:$PORT/latest.json" "$1" "$W/log.txt"; }
wait_log() { for _ in $(seq 1 60); do grep -q "$1" "$W/log.txt" 2>/dev/null && return 0; sleep 0.5; done; fail "waited in vain for '$1' in the log"; }

echo "1. a signed update, $ORIG → 9.9.9, on a copy in $W/Apps"
fresh_copy
run "$PUB" >/dev/null || fail "the app exited with an error"
wait_log "up to date at 9.9.9"          # the relaunched copy, now 9.9.9, checked the feed and found nothing newer
[[ $(version) == 9.9.9 ]] || fail "the copy is $(version), not 9.9.9"
for step in "update available: 9.9.9" "signature OK" "staged " "handing off" "running 9.9.9"; do grep -q "$step" "$W/log.txt" || fail "no '$step' in the log"; done
[[ $(ls -A "$W/Apps") == "$APP.app" ]] || fail "leftovers beside the app: $(ls -A "$W/Apps")"
sleep 1
! pgrep -f "$W/Apps/$APP.app" >/dev/null || fail "the copy is still running"
! xattr -l "$W/Apps/$APP.app/Contents/MacOS/$APP" | grep -q quarantine || fail "the new app is quarantined"
sed 's/^/     /' "$W/log.txt"
echo "ok   detected → downloaded → verified → staged → swapped → relaunched as 9.9.9, nothing left behind"

echo "2. the wrong publisher key"
fresh_copy
! run "$OTHER" >/dev/null 2>&1 || fail "a zip signed with another key was accepted"
grep -q "signature doesn't match" "$W/log.txt" && [[ $(version) == "$ORIG" ]] || fail "wrong key: expected a signature refusal and $ORIG"
echo "ok   refused, copy still $ORIG"

if [[ -n "$SIGN_APP" ]]; then
  echo "3. a properly publisher-signed update whose app is signed by another developer (ad hoc)"
  codesign --force --sign - --options runtime "$W/new/$APP.app" 2>/dev/null
  ditto -c -k --keepParent "$W/new/$APP.app" "$W/site/$APP.app.zip"
  build/sign-update sign "$W/site/$APP.app.zip" --key-file "$W/key/private.key" >/dev/null
  fresh_copy
  ! run "$PUB" >/dev/null 2>&1 || fail "an update from another developer was accepted"
  grep -q "same developer" "$W/log.txt" && [[ $(version) == "$ORIG" ]] && [[ $(ls -A "$W/Apps") == "$APP.app" ]] || fail "other developer: expected a same-developer refusal and $ORIG"
  echo "ok   refused after the publisher-key check, copy still $ORIG, nothing staged"
fi

echo "4. a tampered download"
printf '\0' >> "$W/site/$APP.app.zip"    # one byte: the signature no longer matches
fresh_copy
! run "$PUB" >/dev/null 2>&1 || fail "a tampered zip was accepted"
grep -q "signature doesn't match" "$W/log.txt" && [[ $(version) == "$ORIG" ]] && [[ $(ls -A "$W/Apps") == "$APP.app" ]] || fail "tampered zip: expected a signature refusal and $ORIG"
echo "ok   refused, copy still $ORIG, nothing staged"

[[ "$(defaults export "$DOMAIN" - 2>/dev/null || echo none)" == "$before" ]] || fail "the real $APP settings changed"
echo "ok   the real $APP settings ($DOMAIN) are untouched"
echo "PASS"
