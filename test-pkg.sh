#!/bin/bash
# ./test-pkg.sh — checks build/JuiceLeft.pkg without installing anything: no root, nothing under /Applications touched.
#   - the Distribution XML: well-formed, and the options the install relies on (arm64 only, the minimum macOS, no
#     customising, root volume only, this version, licence + panes + light/dark backgrounds);
#   - the component: installs to /Applications and never relocates; the payload is exactly build/JuiceLeft.app, root-owned,
#     with the app and its helper tools executable;
#   - pre/postinstall run against a temp copy of the app with the system tools shimmed: preinstall must quit the app with a
#     quit event (never a kill unless it hangs); postinstall must hand the app to the console user, run the helper
#     installer for them and open the app — and stand down cleanly with no console user or a failed helper install.
set -euo pipefail
cd "$(dirname "$0")"
APP=JuiceLeft
ID=io.github.cyborgfingers.juiceleft
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Info.plist)
[[ -f "build/$APP.pkg" ]] || ./make-pkg.sh >/dev/null
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok   $*"; }

pkgutil --expand "build/$APP.pkg" "$T/x"
D="$T/x/Distribution"
xmllint --noout "$D" || fail "Distribution isn't well-formed XML"
for want in 'hostArchitectures="arm64"' 'customize="never"' 'rootVolumeOnly="true"' 'enable_localSystem="true"' \
            "<os-version min=\"$MIN_OS\"/>" "<pkg-ref id=\"$ID.pkg\" version=\"$VERSION\"" '<background file="background.png"' \
            '<background-darkAqua file="background-dark.png"' '<license file="license.txt"' '<welcome file="welcome.txt"' '<conclusion file="conclusion.txt"'; do
  grep -qF "$want" "$D" || fail "Distribution lacks $want"
done
for f in background.png background-dark.png welcome.txt license.txt conclusion.txt; do [[ -s "$T/x/Resources/$f" ]] || fail "resource $f missing"; done
cmp -s "$T/x/Resources/license.txt" LICENSE || fail "the licence pane isn't LICENSE"
ok "Distribution: arm64 only, macOS $MIN_OS+, no customising, root volume, $APP $VERSION, licence + panes + light/dark backgrounds"

C="$T/x/$APP-component.pkg"
grep -q 'install-location="/Applications"' "$C/PackageInfo" || fail "the component doesn't install to /Applications"
grep -q 'relocatable="false"' "$C/PackageInfo" || fail "the component is relocatable"
grep -q "<bundle-version>" "$C/PackageInfo" && grep -q "CFBundleShortVersionString=\"$VERSION\"" "$C/PackageInfo" || fail "the component doesn't carry the app's version"
ok "component: /Applications, never relocated, version-checked"
(cd build && find "$APP.app" -not -name .DS_Store | sed 's|^|./|' | sort) > "$T/expected.txt"
lsbom -s "$C/Bom" | grep -v '^\.$' | grep -v '/\._' | sort > "$T/payload.txt"   # ._ entries carry macOS's own provenance attribute
diff "$T/expected.txt" "$T/payload.txt" >/dev/null || fail "the payload isn't exactly build/$APP.app"
! lsbom -p fug "$C/Bom" | awk '$2 != 0 || $3 != 0' | grep -q . || fail "payload files aren't all root:wheel"
pkgutil --check-signature "build/$APP.pkg" | sed -n '2p;5p' | sed 's/^ */     /'
for exe in "Contents/MacOS/$APP" Contents/Resources/juiceleft-helper.sh Contents/Resources/juiceleft-led Contents/Resources/juiceleft-verify; do
  [[ $(lsbom -p fm "$C/Bom" | awk -v p="./$APP.app/$exe" '$1 == p {print $2}') == 100755 ]] || fail "$exe isn't 755 in the payload"
done
ok "payload: $(wc -l < "$T/payload.txt") entries, exactly build/$APP.app, root:wheel, executables 755"

mkdir "$T/s" && cp -R "$C/Scripts/." "$T/s/"   # pkgutil --expand has already unpacked the scripts archive
[[ -x "$T/s/preinstall" && -x "$T/s/postinstall" ]] || fail "pre/postinstall missing or not executable"
cmp -s "$T/s/preinstall" pkg/scripts/preinstall && cmp -s "$T/s/postinstall" pkg/scripts/postinstall || fail "the packaged scripts aren't pkg/scripts"

# The scripts against a temp copy of the app, with every system tool they touch shimmed into $LOG.
mkdir -p "$T/bin" "$T/root/Applications"
cp -R "build/$APP.app" "$T/root/Applications/"
FAKE="$T/root/Applications/$APP.app"
LOG="$T/calls.log"
shim() { printf '#!/bin/sh\necho "%s $*" >> "$LOG"\n%s\n' "$1" "${2:-exit 0}" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
shim chown; shim open; shim osascript; shim pkill
shim launchctl 'shift 2; exec "$@"'   # asuser <uid> <command…>
shim sudo 'shift 2; exec "$@"'        # -u <user> <command…>
shim stat 'echo "${CONSOLE_USER-}"'
shim id 'case "$2" in alice) echo 501 ;; *) exit 1 ;; esac'
shim pgrep '[ -n "${PGREP_ALWAYS-}" ] && exit 0; n=$(cat "$PGREP_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$PGREP_COUNT"; [ $n -le 2 ]'
printf '#!/bin/sh\necho "helper $*" >> "$LOG"\nexit ${HELPER_EXIT:-0}\n' > "$FAKE/Contents/Resources/juiceleft-helper.sh"
export LOG PGREP_COUNT="$T/pgrep.n"
run() { : > "$LOG"; rm -f "$PGREP_COUNT"; PATH="$T/bin:$PATH" PKG_APP="$FAKE" sh "$T/s/$1" "build/$APP.pkg" /Applications / / ; }
logged() { grep -qF "$1" "$LOG" || fail "$2: expected '$1' in: $(tr '\n' ';' < "$LOG")"; }
not_logged() { ! grep -qF "$1" "$LOG" || fail "$2: '$1' must not happen: $(tr '\n' ';' < "$LOG")"; }

CONSOLE_USER=alice run preinstall
logged "osascript -e tell application id \"$ID\" to quit" "preinstall"; not_logged "pkill" "preinstall"
ok "preinstall: asks the running app to quit from the user's session, waits, never kills a copy that quits"
CONSOLE_USER=alice PGREP_ALWAYS=1 PKG_QUIT_TRIES=3 run preinstall
logged "pkill -x $APP" "preinstall (hung app)"
ok "preinstall: a copy that won't quit is killed after the wait"
CONSOLE_USER=alice run postinstall >/dev/null
logged "chown -R alice:staff $FAKE" "postinstall"; logged "helper install alice" "postinstall"
logged "launchctl asuser 501 sudo -u alice open -a $FAKE" "postinstall"
ok "postinstall: app handed to the console user, helper installed for them, app opened in their session"
for user in "" root loginwindow; do
  CONSOLE_USER=$user run postinstall >/dev/null
  not_logged "helper" "postinstall (console user '$user')"; not_logged "chown" "postinstall (console user '$user')"
done
ok "postinstall: no console user (login window, root) → nothing risky, install still succeeds"
CONSOLE_USER=alice HELPER_EXIT=1 run postinstall > "$T/out.txt"
grep -q "helper install failed" "$T/out.txt" && logged "open -a $FAKE" "postinstall (helper failed)" || fail "a failed helper install must be logged and the app still opened"
ok "postinstall: a failed helper install is logged, the install still succeeds and the app opens (its setup card takes over)"
echo "PASS"
