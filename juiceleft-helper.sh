#!/bin/sh
# JuiceLeft energy-mode helper — the only part that runs as root.
#   juiceleft-helper.sh install <user>   one-time, from the app's admin prompt
#   juiceleft-helper.sh uninstall        sudo, from ./build.sh uninstall
#   juiceleft-helper.sh                  launchd: apply the app's request
#
# Energy modes (Low Power / Automatic / High Power) are `pmset -b|-c powermode 1|0|2`, and only root can set them.
# The app writes one line to $REQ — "b 1" (battery, low power), "c 0" (adapter, automatic), … — and launchd runs
# this on every write. Nothing but exactly {b,c} × {0,1,2} ever reaches pmset. A request is applied once: its
# modification time is remembered, so a reboot or a re-run never re-imposes an old choice over one made elsewhere.
set -u
LABEL=io.github.cyborgfingers.juiceleft.power
DIR="${JUICELEFT_DIR:-/Library/Application Support/JuiceLeft}"   # overrides exist only for test-helper.sh
PMSET="${JUICELEFT_PMSET:-/usr/bin/pmset}"
REQ="$DIR/powermode"    # user-owned file in a root-owned dir: the app can rewrite it, never swap it for a link
DONE="$DIR/applied"     # marker carrying the modification time of the request last applied
BIN=/Library/PrivilegedHelperTools/$LABEL.sh
PLIST=/Library/LaunchDaemons/$LABEL.plist

apply() {
  [ -f "$REQ" ] && [ ! -L "$REQ" ] || exit 0
  if [ -e "$DONE" ] && [ ! "$REQ" -nt "$DONE" ]; then exit 0; fi   # already applied
  req=$(head -c 8 "$REQ" 2>/dev/null | head -n 1)   # the whole first line, and nothing after it
  case "$req" in
    "b 0"|"b 1"|"b 2") "$PMSET" -b powermode "${req#b }" ;;
    "c 0"|"c 1"|"c 2") "$PMSET" -c powermode "${req#c }" ;;
    *) ;;   # anything else is ignored
  esac
  touch -r "$REQ" "$DONE"
}

install_helper() {
  install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools "$DIR"
  install -o root -g wheel -m 755 "$0" "$BIN"
  [ -f "$REQ" ] || : > "$REQ"
  chown "$1" "$REQ"
  chmod 644 "$REQ"
  touch -r "$REQ" "$DONE"   # whatever is in the file now is not a new request
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key><array><string>/bin/sh</string><string>$BIN</string></array>
	<key>WatchPaths</key><array><string>$REQ</string></array>
	<key>ThrottleInterval</key><integer>1</integer>
	<key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
  chown root:wheel "$PLIST"
  chmod 644 "$PLIST"
  launchctl bootout system/$LABEL 2>/dev/null
  launchctl bootstrap system "$PLIST"
}

uninstall_helper() {
  launchctl bootout system/$LABEL 2>/dev/null
  rm -rf "$DIR" "$BIN" "$PLIST"
}

case "${1:-}" in
  install) install_helper "$2" ;;
  uninstall) uninstall_helper ;;
  *) apply ;;
esac
